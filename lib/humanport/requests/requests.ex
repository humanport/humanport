defmodule Humanport.Requests do
  @moduledoc """
  `Ash.Domain` for `HumanRequest` — the only sanctioned writer. `submit/2`,
  `answer/3`, `approve/2`, `choose/3` (CORE-04) and `reject/2` are the
  public API; each opens ONE `Ash.transaction/3` spanning the state change
  and its own `Humanport.Audit` write, rolling back with
  `Ash.DataLayer.rollback/2` on any error. `Ash.transaction/3` accepts a
  list of resources and opens a single data-layer transaction across them,
  and preserves the post-commit notification property: notifications
  accumulate during the transaction and are dispatched only after it commits.

  Controllers and LiveViews call `submit/2` / `answer/3` / `approve/2` /
  `choose/3` / `reject/2` — never `Ash.create(HumanRequest, ...)` or
  `Ash.update(request, ...)` directly, and never a changeset built outside
  this module (§5.2, §54.12).
  """

  use Ash.Domain

  alias Humanport.Actors.Actor
  alias Humanport.Requests.HumanRequest

  resources do
    resource HumanRequest do
      define :get_request, action: :read, get_by: [:id]
      define :list_requests, action: :read
      # D-16 — the inbox's single toggle. The tenant/state/waiting split
      # lives in these two read actions (see human_request.ex), not as a
      # filter InboxLive builds inline.
      define :list_open_requests, action: :open
      define :list_answered_requests, action: :answered
    end
  end

  @doc """
  Creates a `HumanRequest` and writes the `request.created` audit event in
  one transaction.
  """
  @spec submit(map(), Actor.t()) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def submit(params, %Actor{} = actor) do
    Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
      with {:ok, request} <- do_submit(params, actor),
           {:ok, _event} <-
             Humanport.Audit.record("request.created", %{
               tenant_id: request.tenant_id,
               request_id: request.id,
               resource_type: "human_request",
               resource_id: request.id,
               previous_state: nil,
               new_state: request.state,
               actor: actor,
               metadata: %{}
             }) do
        request
      else
        {:error, error} -> Ash.DataLayer.rollback(HumanRequest, error)
      end
    end)
  end

  @doc """
  Answers a `HumanRequest` and writes the `request.responded` audit event in
  one transaction.

  Guards the type/action pairing before opening the transaction: answering an
  `:approve` request with free text is a caller error, not a race (the type
  never changes), so it returns a plain error the HTTP boundary maps to 422
  rather than widening the atomic `filter` on `:answer` and turning a type
  mismatch into a conflict result.
  """
  @spec answer(Ash.Resource.record(), String.t(), Actor.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def answer(%HumanRequest{type: :approve}, _answer, %Actor{}) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :type,
           message: "this request type cannot be answered with a free-text answer"
         )
       ]
     )}
  end

  def answer(%HumanRequest{} = request, answer, %Actor{} = actor) do
    Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
      with {:ok, answered} <- do_answer(request, %{answer: answer}, actor: actor),
           {:ok, _event} <-
             Humanport.Audit.record("request.responded", %{
               tenant_id: answered.tenant_id,
               request_id: answered.id,
               resource_type: "human_request",
               resource_id: answered.id,
               previous_state: request.state,
               new_state: answered.state,
               actor: actor,
               metadata: %{}
             }) do
        answered
      else
        {:error, error} -> Ash.DataLayer.rollback(HumanRequest, error)
      end
    end)
  end

  @doc """
  Approves a `HumanRequest` and writes the `request.approved` audit event in
  one transaction.

  Guards the type/action pairing before opening the transaction, exactly like
  `answer/3`: approving an `:ask` request is a caller error, not a race (the
  type never changes on a request), so it returns a plain `Ash.Error.Invalid`
  the HTTP boundary maps to 422 rather than letting the mismatch reach the
  atomic `:approve` action, where it would surface as a `NoMatchingTransition`
  conflict and tell an agent to stop retrying something that was merely
  malformed.
  """
  @spec approve(Ash.Resource.record(), Actor.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def approve(%HumanRequest{type: :ask}, %Actor{}) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :type,
           message: "this request type cannot be approved or rejected"
         )
       ]
     )}
  end

  def approve(%HumanRequest{} = request, %Actor{} = actor) do
    Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
      with {:ok, approved} <- do_approve(request, actor: actor),
           {:ok, _event} <-
             Humanport.Audit.record("request.approved", %{
               tenant_id: approved.tenant_id,
               request_id: approved.id,
               resource_type: "human_request",
               resource_id: approved.id,
               previous_state: request.state,
               new_state: approved.state,
               actor: actor,
               metadata: %{}
             }) do
        approved
      else
        {:error, error} -> Ash.DataLayer.rollback(HumanRequest, error)
      end
    end)
  end

  @doc """
  Chooses one or more options on a `HumanRequest` and writes the
  `request.chosen` audit event in one transaction (CORE-04).

  `selection` is a map with `:selected_option_ids` (a list of strings,
  required — may be empty only when free text is given and permitted) and
  an optional `:free_text` string.

  Guards the type/action pairing before opening the transaction, exactly
  like `answer/3`/`approve/2`: choosing on a non-`:choose` request is a
  caller error, not a race (the type never changes on a request), so it
  returns a plain `Ash.Error.Invalid` the HTTP boundary maps to 422 rather
  than letting the mismatch reach the atomic `:choose` action, where it
  would surface as a `NoMatchingTransition` conflict and tell an agent to
  stop retrying something that was merely malformed.

  Then, still before the transaction opens, validates the selection against
  the request's own stored options and its own limits — by **exact string
  equality only**, no trimming, no case folding, no normalisation, no
  mapping (locked decision 2): every submitted id must be a member of the
  request's option ids, no id may appear twice, the count may not exceed
  the request's own `max_selections`, free text is permitted only when the
  request's `allow_free_text` is true, and the selection may be empty only
  when free text is present and permitted. Each failure is a plain invalid
  error with a field-level message, mapped to the malformed (422) status,
  not the conflict (409) status.

  These checks live here, in the domain function, rather than as
  validations on the `:choose` action **on purpose**: a custom validation
  without an atomic form would force the action's atomicity requirement
  off, which is the same landmine documented on `HumanRequest`'s moduledoc,
  by a different door.

  The audit entry's metadata carries, for every selected id, a pair of that
  id and **the label as it stands on the request at this moment** — read
  out of `request.options` (the caller's own already-loaded copy, never
  re-resolved later) rather than from anything the `:choose` action itself
  wrote — plus a boolean recording whether free text was given (D-13). The
  audit table is append-only: an entry written without the label cannot be
  back-filled, because the label it showed no longer exists anywhere once
  the caller renames it.
  """
  @spec choose(Ash.Resource.record(), map(), Actor.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def choose(%HumanRequest{type: type}, _selection, %Actor{}) when type != :choose do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :type,
           message: "this request type has no options to choose from"
         )
       ]
     )}
  end

  def choose(%HumanRequest{} = request, selection, %Actor{} = actor) do
    with :ok <- validate_selection(request, selection) do
      selected_option_ids = Map.get(selection, :selected_option_ids, [])
      free_text = Map.get(selection, :free_text)

      Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
        with {:ok, chosen} <-
               do_choose(
                 request,
                 %{selected_option_ids: selected_option_ids, free_text: free_text},
                 actor: actor
               ),
             {:ok, _event} <-
               Humanport.Audit.record("request.chosen", %{
                 tenant_id: chosen.tenant_id,
                 request_id: chosen.id,
                 resource_type: "human_request",
                 resource_id: chosen.id,
                 previous_state: request.state,
                 new_state: chosen.state,
                 actor: actor,
                 metadata: %{
                   selected_options: selected_options_metadata(request, selected_option_ids),
                   free_text_given: not is_nil(free_text)
                 }
               }) do
          chosen
        else
          {:error, error} -> Ash.DataLayer.rollback(HumanRequest, error)
        end
      end)
    end
  end

  defp validate_selection(%HumanRequest{} = request, selection) do
    selected_option_ids = Map.get(selection, :selected_option_ids, [])
    free_text = Map.get(selection, :free_text)
    offered_ids = Enum.map(request.options || [], & &1.id)

    cond do
      not is_nil(free_text) and not request.allow_free_text ->
        invalid(:free_text, "free text is not permitted on this request")

      selected_option_ids == [] and is_nil(free_text) ->
        invalid(:selected_option_ids, "nothing was chosen and no free text was given")

      Enum.uniq(selected_option_ids) != selected_option_ids ->
        invalid(:selected_option_ids, "the same option id was chosen more than once")

      (unoffered = Enum.reject(selected_option_ids, &(&1 in offered_ids))) != [] ->
        invalid(
          :selected_option_ids,
          "the following option ids were not offered by this request: #{Enum.join(unoffered, ", ")}"
        )

      length(selected_option_ids) > request.max_selections ->
        invalid(
          :selected_option_ids,
          "#{length(selected_option_ids)} options were selected, but this request allows at most #{request.max_selections}"
        )

      true ->
        :ok
    end
  end

  defp invalid(field, message) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)]
     )}
  end

  # D-13 — the label as it stood on the request at the moment of the
  # decision, read from the caller's own already-loaded `request.options`
  # (never re-resolved from the freshly-updated record), since options are
  # stored opaquely and an id cannot be resolved back to its text later.
  defp selected_options_metadata(%HumanRequest{options: options}, selected_option_ids) do
    options_by_id = Map.new(options || [], &{&1.id, &1})

    Enum.map(selected_option_ids, fn id ->
      option = Map.fetch!(options_by_id, id)
      %{id: option.id, label: option.label}
    end)
  end

  @doc """
  Rejects a `HumanRequest` and writes the `request.rejected` audit event in
  one transaction. See `approve/2` for the type/action guard rationale.
  """
  @spec reject(Ash.Resource.record(), Actor.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def reject(%HumanRequest{type: :ask}, %Actor{}) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :type,
           message: "this request type cannot be approved or rejected"
         )
       ]
     )}
  end

  def reject(%HumanRequest{} = request, %Actor{} = actor) do
    Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
      with {:ok, rejected} <- do_reject(request, actor: actor),
           {:ok, _event} <-
             Humanport.Audit.record("request.rejected", %{
               tenant_id: rejected.tenant_id,
               request_id: rejected.id,
               resource_type: "human_request",
               resource_id: rejected.id,
               previous_state: request.state,
               new_state: rejected.state,
               actor: actor,
               metadata: %{}
             }) do
        rejected
      else
        {:error, error} -> Ash.DataLayer.rollback(HumanRequest, error)
      end
    end)
  end

  defp do_submit(params, actor) do
    HumanRequest
    |> Ash.Changeset.for_create(:submit, params, actor: actor)
    |> Ash.create()
  end

  defp do_answer(request, params, opts) do
    request
    |> Ash.Changeset.for_update(:answer, params, opts)
    |> Ash.update()
  end

  defp do_approve(request, opts) do
    request
    |> Ash.Changeset.for_update(:approve, %{}, opts)
    |> Ash.update()
  end

  defp do_choose(request, params, opts) do
    request
    |> Ash.Changeset.for_update(:choose, params, opts)
    |> Ash.update()
  end

  defp do_reject(request, opts) do
    request
    |> Ash.Changeset.for_update(:reject, %{}, opts)
    |> Ash.update()
  end
end
