defmodule HumanportWeb.RequestController do
  @moduledoc """
  PROTO-01 — the agent-facing HTTP surface, fixed by the Task 1 checkpoint
  decision (`plain-v1`): plain Phoenix JSON controllers under `/api/v1`, no
  envelope imposed on the body.

  `POST /api/v1/requests` → 201 with the full request object.

  `GET /api/v1/requests/:id[?wait=N]` → 200 with `status`, `state` and
  `result` (`result` is null while pending). Without `?wait=`, returns
  immediately. With `?wait=N`, holds the connection open — via the
  connection process the web server already spawned, holding no waiter
  registry, no ETS table and no persisted term anywhere — until the request
  is answered or `N` seconds elapse (clamped to the configured ceiling, see
  `config/runtime.exs`), then returns a fresh database read either way. A
  wait holds a process only for the duration of its own timeout, never for
  the lifetime of the pending request (D-02). The wait mechanics themselves
  live in `HumanportWeb.RequestWaiting` (02.1-03-PLAN.md Task 1) — this
  controller subscribes/unsubscribes and delegates; it holds no mailbox loop
  of its own. `HumanportWeb.MCP.Tools.Await` calls the exact same module.

  `POST /api/v1/requests/:id/respond` → 200, or 409 conflict / 422 invalid /
  404 not found. Body carries `"answer"` for an `ask` request,
  `"decision": "approve" | "reject"` for an `approve` request, or
  `"selected_option_ids"` (a list, possibly empty) and/or `"free_text"` for
  a `choose` request (CORE-04) — a body naming a selection is dispatched
  ahead of a free-text-only body, so a body carrying both goes through
  `Humanport.Requests.choose/3` with both fields exactly as sent. Sending
  the wrong shape for the request's type is a 422, not a 409 — see
  `HumanportWeb.FallbackController`.

  Errors render as `{"error": {"code", "message", "details"}}` with the code
  set `not_found | conflict | invalid | not_implemented | internal`.

  This surface is unauthenticated in Phase 1 by design (D-09/D-11) — it
  resolves an actor (via `HumanportWeb.Plugs.ResolveActor`) so writes carry a
  recorded, unverified identity, but nothing here checks a token or a
  session. It MUST NOT be reachable from the internet until the Cloudflare
  Access gate (Phase 2, OPS-03) sits in front of it; that gate, not this
  module, is the compensating control (T-01-22).

  Every action calls `Humanport.Requests` — never builds a changeset and
  never decides a transition itself (§5.2, §54.12).
  """

  use HumanportWeb, :controller

  action_fallback HumanportWeb.FallbackController

  alias Humanport.Requests
  alias HumanportWeb.RequestWaiting

  def create(conn, params) do
    with {:ok, request} <- Requests.submit(params, conn.assigns.actor) do
      conn
      |> put_status(:created)
      |> render(:show, request: request)
    end
  end

  def show(conn, %{"id" => id} = params) do
    wait = RequestWaiting.parse_wait(Map.get(params, "wait"))
    topic = RequestWaiting.topic(id)

    # D-01/D-02, Pattern 6 — subscribe BEFORE reading. Reading first opens a
    # window in which the answer commits and broadcasts before the
    # subscription exists, and the caller then waits out the full timeout
    # for an event that already happened. Only subscribe at all when a wait
    # was actually requested — an immediate read never needs it.
    if wait > 0, do: HumanportWeb.Endpoint.subscribe(topic)

    result =
      with {:ok, request} <- Requests.get_request(id) do
        RequestWaiting.await(id, topic, request, wait)
      end

    if wait > 0, do: HumanportWeb.Endpoint.unsubscribe(topic)

    with {:ok, request} <- result do
      render(conn, :show, request: request)
    end
  end

  def respond(conn, %{"id" => id} = params) do
    with {:ok, request} <- Requests.get_request(id),
         {:ok, responded} <- dispatch_respond(request, params, conn.assigns.actor) do
      render(conn, :show, request: responded)
    end
  end

  defp dispatch_respond(request, %{"decision" => decision}, actor) do
    case decision do
      "approve" -> Requests.approve(request, actor)
      "reject" -> Requests.reject(request, actor)
      _ -> invalid_field_error(:decision, "decision must be \"approve\" or \"reject\"")
    end
  end

  defp dispatch_respond(request, %{"answer" => answer}, actor) do
    Requests.answer(request, answer, actor)
  end

  # CORE-04 — a body naming a selection is dispatched ahead of the
  # free-text-only clause below, so a body carrying BOTH (the case this
  # controller's own test file pins explicitly) always goes through
  # `Requests.choose/3` with both fields it was sent, never ambiguously.
  # `selected_option_ids` may be `[]` — a choose request's free-text-only
  # answer, when a caller sends the key explicitly rather than omitting it.
  defp dispatch_respond(request, %{"selected_option_ids" => selected_option_ids} = params, actor)
       when is_list(selected_option_ids) do
    Requests.choose(
      request,
      %{selected_option_ids: selected_option_ids, free_text: Map.get(params, "free_text")},
      actor
    )
  end

  # A caller who omits `selected_option_ids` entirely and sends only
  # `free_text` — the choose request's free-text-only answer, in its
  # shortest form.
  defp dispatch_respond(request, %{"free_text" => free_text}, actor) when is_binary(free_text) do
    Requests.choose(request, %{selected_option_ids: [], free_text: free_text}, actor)
  end

  defp dispatch_respond(_request, _params, _actor) do
    invalid_field_error(
      :body,
      "request body must include \"answer\", \"decision\", or \"selected_option_ids\""
    )
  end

  defp invalid_field_error(field, message) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)]
     )}
  end
end
