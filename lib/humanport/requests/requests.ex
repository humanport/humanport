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
  alias Humanport.Requests.ContentHash
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
  def submit(_params, %Actor{type: :agent, role: :responder}), do: role_error(:responder, :submit)

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
               metadata: %{content_hash: request.content_hash}
             }),
           {:ok, _job} <- schedule_expiry(request) do
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
  rather than letting the mismatch reach the atomic `:answer` action and
  turning a type mismatch into a conflict result.
  """
  @spec answer(Ash.Resource.record(), String.t(), Actor.t(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def answer(request, answer, actor, opts \\ [])

  def answer(_request, _answer, %Actor{type: :agent, role: :requester}, _),
    do: role_error(:requester, :decide)

  def answer(%HumanRequest{requester_agent_key_id: id}, _answer, %Actor{type: :agent, id: id}, _)
      when is_binary(id),
      do: self_answer_error()

  def answer(%HumanRequest{type: :approve}, _answer, %Actor{}, _opts) do
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

  def answer(%HumanRequest{} = request, answer, %Actor{} = actor, opts) do
    with :ok <- check_deadline(request),
         {:ok, content_hash} <- bind_content(request, opts) do
      Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
        with {:ok, answered} <-
               do_answer(request, %{answer: answer, content_hash: content_hash}, actor: actor),
             {:ok, _event} <-
               Humanport.Audit.record("request.responded", %{
                 tenant_id: answered.tenant_id,
                 request_id: answered.id,
                 resource_type: "human_request",
                 resource_id: answered.id,
                 previous_state: request.state,
                 new_state: answered.state,
                 actor: actor,
                 metadata: %{content_hash: content_hash}
               }) do
          answered
        else
          {:error, error} -> Ash.DataLayer.rollback(HumanRequest, error)
        end
      end)
    end
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
  @spec approve(Ash.Resource.record(), Actor.t(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def approve(request, actor, opts \\ [])

  def approve(_request, %Actor{type: :agent, role: :requester}, _),
    do: role_error(:requester, :decide)

  def approve(%HumanRequest{requester_agent_key_id: key_id}, %Actor{type: :agent, id: key_id}, _)
      when is_binary(key_id),
      do: self_answer_error()

  def approve(%HumanRequest{type: :ask}, %Actor{}, _opts) do
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

  def approve(%HumanRequest{} = request, %Actor{} = actor, opts) do
    with :ok <- check_deadline(request),
         {:ok, content_hash} <- bind_content(request, opts) do
      Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
        with {:ok, approved} <- do_approve(request, %{content_hash: content_hash}, actor: actor),
             {:ok, _event} <-
               Humanport.Audit.record("request.approved", %{
                 tenant_id: approved.tenant_id,
                 request_id: approved.id,
                 resource_type: "human_request",
                 resource_id: approved.id,
                 previous_state: request.state,
                 new_state: approved.state,
                 actor: actor,
                 metadata: %{content_hash: content_hash}
               }) do
          approved
        else
          {:error, error} -> Ash.DataLayer.rollback(HumanRequest, error)
        end
      end)
    end
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
  @spec choose(Ash.Resource.record(), map(), Actor.t(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def choose(request, selection, actor, opts \\ [])

  def choose(_request, _selection, %Actor{type: :agent, role: :requester}, _),
    do: role_error(:requester, :decide)

  def choose(
        %HumanRequest{requester_agent_key_id: key_id},
        _selection,
        %Actor{type: :agent, id: key_id},
        _opts
      )
      when is_binary(key_id),
      do: self_answer_error()

  def choose(%HumanRequest{type: type}, _selection, %Actor{}, _opts) when type != :choose do
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

  def choose(%HumanRequest{} = request, selection, %Actor{} = actor, opts) do
    with :ok <- check_deadline(request),
         :ok <- validate_selection(request, selection),
         {:ok, content_hash} <- bind_content(request, opts) do
      selected_option_ids = Map.get(selection, :selected_option_ids, [])
      free_text = Map.get(selection, :free_text)

      Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
        with {:ok, chosen} <-
               do_choose(
                 request,
                 %{
                   selected_option_ids: selected_option_ids,
                   free_text: free_text,
                   content_hash: content_hash
                 },
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
                   free_text_given: not is_nil(free_text),
                   content_hash: content_hash
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
  @spec reject(Ash.Resource.record(), Actor.t(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def reject(request, actor, opts \\ [])

  def reject(_request, %Actor{type: :agent, role: :requester}, _),
    do: role_error(:requester, :decide)

  def reject(%HumanRequest{requester_agent_key_id: key_id}, %Actor{type: :agent, id: key_id}, _)
      when is_binary(key_id),
      do: self_answer_error()

  def reject(%HumanRequest{type: :ask}, %Actor{}, _opts) do
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

  def reject(%HumanRequest{} = request, %Actor{} = actor, opts) do
    with :ok <- check_deadline(request),
         {:ok, content_hash} <- bind_content(request, opts) do
      Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
        with {:ok, rejected} <- do_reject(request, %{content_hash: content_hash}, actor: actor),
             {:ok, _event} <-
               Humanport.Audit.record("request.rejected", %{
                 tenant_id: rejected.tenant_id,
                 request_id: rejected.id,
                 resource_type: "human_request",
                 resource_id: rejected.id,
                 previous_state: request.state,
                 new_state: rejected.state,
                 actor: actor,
                 metadata: %{content_hash: content_hash}
               }) do
          rejected
        else
          {:error, error} -> Ash.DataLayer.rollback(HumanRequest, error)
        end
      end)
    end
  end

  @doc """
  ROUTE-* — expires a pending request whose deadline passed, and writes the
  `request.expired` audit event in one transaction. Called only by the
  scheduled `Humanport.Requests.Workers.ExpireRequest` job; the acting actor
  is the system itself, recorded as such.
  """
  @spec expire(Ash.Resource.record()) :: {:ok, Ash.Resource.record()} | {:error, term()}
  def expire(%HumanRequest{} = request) do
    actor = %Actor{id: nil, type: :system, label: "deadline", verified?: false, method: nil}

    Ash.transaction([HumanRequest, Humanport.Audit.Event], fn ->
      with {:ok, expired} <-
             request
             |> Ash.Changeset.for_update(:expire, %{}, actor: actor)
             |> Ash.update(),
           {:ok, _event} <-
             Humanport.Audit.record("request.expired", %{
               tenant_id: expired.tenant_id,
               request_id: expired.id,
               resource_type: "human_request",
               resource_id: expired.id,
               previous_state: request.state,
               new_state: expired.state,
               actor: actor,
               metadata: %{deadline_at: request.deadline_at}
             }) do
        expired
      else
        {:error, error} -> Ash.DataLayer.rollback(HumanRequest, error)
      end
    end)
  end

  # ROUTE-* — inserted in the same transaction as the request, so a request
  # with a deadline never exists without the job that ends it.
  defp schedule_expiry(%HumanRequest{deadline_at: nil}), do: {:ok, nil}

  defp schedule_expiry(%HumanRequest{id: id, deadline_at: deadline_at}) do
    %{"request_id" => id}
    |> Humanport.Requests.Workers.ExpireRequest.new(scheduled_at: deadline_at)
    |> Oban.insert()
  end

  # ROUTE-* — a decision after the deadline is refused even if the expiry
  # job has not run yet. `deadline_at` never changes after submit, so the
  # caller's loaded copy is authoritative; no atomic form is needed.
  defp check_deadline(%HumanRequest{deadline_at: nil}), do: :ok

  defp check_deadline(%HumanRequest{deadline_at: deadline_at}) do
    if DateTime.compare(DateTime.utc_now(), deadline_at) == :lt do
      :ok
    else
      {:error,
       Ash.Error.Invalid.exception(
         errors: [Humanport.Requests.Errors.DeadlinePassed.exception([])]
       )}
    end
  end

  @doc """
  SEC-08 — re-checks a request's content against every fingerprint recorded
  for it: `content_hash` (taken at submit), the `request.created` audit
  event's copy of it (append-only), and `decided_content_hash` once decided.
  `:ok` when the content as stored today is exactly the content that was
  fingerprinted and decided on; `{:error, :content_mismatch}` when anything
  differs — the content, or a stored fingerprint, was altered outside the
  domain. `{:error, :no_content_hash}` for a request created before SEC-08.
  """
  @spec verify_content(Ash.Resource.record()) ::
          :ok | {:error, :no_content_hash | :content_mismatch}
  def verify_content(%HumanRequest{content_hash: nil}), do: {:error, :no_content_hash}

  def verify_content(%HumanRequest{} = request) do
    fingerprint = ContentHash.compute(request)

    recorded =
      Enum.reject(
        [request.content_hash, request.decided_content_hash, created_event_hash(request.id)],
        &is_nil/1
      )

    if Enum.all?(recorded, &(&1 == fingerprint)), do: :ok, else: {:error, :content_mismatch}
  end

  defp created_event_hash(request_id) do
    {:ok, events} = Humanport.Audit.list_events_for_request(request_id)

    Enum.find_value(events, fn event ->
      event.event_type == "request.created" &&
        (event.metadata["content_hash"] || event.metadata[:content_hash])
    end)
  end

  # SEC-08 / §54.8 — binds a decision to the content the decider was shown.
  # `shown` is the decider's own loaded copy, so by default the fingerprint
  # presented is the one of what they were looking at; a boundary that
  # carries the fingerprint separately (HTTP's `content_hash` field) passes
  # it in `opts`. The request is re-read here and refingerprinted: a decision
  # goes through only when the presented fingerprint, the fingerprint of the
  # content as stored now, and the fingerprint taken at submit all agree.
  # Content is never changed by any action, so a mismatch means it was
  # altered outside the domain, or the decider named other content — either
  # way nothing is recorded. Checked before the transaction opens, like the
  # guards above, so no decision action loses its atomicity.
  defp bind_content(%HumanRequest{content_hash: nil}, _opts), do: {:ok, nil}

  defp bind_content(%HumanRequest{} = shown, opts) do
    presented = Keyword.get(opts, :content_hash) || shown.content_hash

    with {:ok, current} <- get_request(shown.id) do
      fingerprint = ContentHash.compute(current)

      if presented == fingerprint and current.content_hash == fingerprint do
        {:ok, fingerprint}
      else
        {:error,
         Ash.Error.Invalid.exception(
           errors: [Humanport.Requests.Errors.ContentChanged.exception([])]
         )}
      end
    end
  end

  # SEC-04/05 — an agent key may answer other requests, never its own: a key
  # that could approve what it asked for would make the approval meaningless.
  # Checked before any transaction opens, like the type guards above — the
  # requester never changes on a request, so this is a caller error, not a
  # race, and needs no atomic form.
  # SEC-02 — an agent key acts only within its role (see
  # `Humanport.Actors.Actor`). Checked first, before any other guard or
  # transaction, so a key that may not act learns nothing else.
  defp role_error(role, operation) do
    {:error,
     Ash.Error.Forbidden.exception(
       errors: [
         Humanport.Requests.Errors.RoleNotPermitted.exception(role: role, operation: operation)
       ]
     )}
  end

  defp self_answer_error do
    {:error,
     Ash.Error.Forbidden.exception(errors: [Humanport.Requests.Errors.SelfAnswer.exception([])])}
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

  defp do_approve(request, params, opts) do
    request
    |> Ash.Changeset.for_update(:approve, params, opts)
    |> Ash.update()
  end

  defp do_choose(request, params, opts) do
    request
    |> Ash.Changeset.for_update(:choose, params, opts)
    |> Ash.update()
  end

  defp do_reject(request, params, opts) do
    request
    |> Ash.Changeset.for_update(:reject, params, opts)
    |> Ash.update()
  end
end
