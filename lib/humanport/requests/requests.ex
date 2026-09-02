defmodule Humanport.Requests do
  @moduledoc """
  `Ash.Domain` for `HumanRequest` — the only sanctioned writer. `submit/2` and
  `answer/3` are the public API; each opens ONE `Ash.transaction/3` spanning
  the state change and the `Humanport.Audit.record/2` write, rolling back
  with `Ash.DataLayer.rollback/2` on any error. `Ash.transaction/3` accepts a
  list of resources and opens a single data-layer transaction across them,
  and preserves the post-commit notification property: notifications
  accumulate during the transaction and are dispatched only after it commits.

  Controllers and LiveViews call `submit/2` / `answer/3` — never
  `Ash.create(HumanRequest, ...)` or `Ash.update(request, ...)` directly, and
  never a changeset built outside this module (§5.2, §54.12).
  """

  use Ash.Domain

  alias Humanport.Actors.Actor
  alias Humanport.Requests.HumanRequest

  resources do
    resource HumanRequest do
      define :get_request, action: :read, get_by: [:id]
      # InboxLive's list — narrowed with `query: [filter: ..., sort: ...]` by
      # the caller (D-16's open/answered toggle is plan 01-05's job; Task 2
      # only needs the open list).
      define :list_requests, action: :read
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
end
