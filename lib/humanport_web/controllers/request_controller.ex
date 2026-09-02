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
  the lifetime of the pending request (D-02).

  `POST /api/v1/requests/:id/respond` → 200, or 409 conflict / 422 invalid /
  404 not found. Body carries `"answer"` for an `ask` request or
  `"decision": "approve" | "reject"` for an `approve` request; sending the
  wrong shape for the request's type is a 422, not a 409 — see
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

  @terminal_states [:answered, :approved, :rejected]

  def create(conn, params) do
    with {:ok, request} <- Requests.submit(params, conn.assigns.actor) do
      conn
      |> put_status(:created)
      |> render(:show, request: request)
    end
  end

  def show(conn, %{"id" => id} = params) do
    wait = parse_wait(Map.get(params, "wait"))
    topic = topic(id)

    # D-01/D-02, Pattern 6 — subscribe BEFORE reading. Reading first opens a
    # window in which the answer commits and broadcasts before the
    # subscription exists, and the caller then waits out the full timeout
    # for an event that already happened. Only subscribe at all when a wait
    # was actually requested — an immediate read never needs it.
    if wait > 0, do: HumanportWeb.Endpoint.subscribe(topic)

    result =
      with {:ok, request} <- Requests.get_request(id) do
        await(id, topic, request, wait, deadline(wait))
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

  defp topic(id), do: "request:#{id}"

  defp deadline(wait), do: System.monotonic_time(:millisecond) + :timer.seconds(wait)

  # Already terminal — return immediately regardless of the wait parameter.
  defp await(_id, _topic, %{state: state} = request, _wait, _deadline)
       when state in @terminal_states do
    {:ok, request}
  end

  # No wait requested — return the immediate (possibly pending) read as-is.
  defp await(_id, _topic, request, wait, _deadline) when wait <= 0 do
    {:ok, request}
  end

  defp await(id, topic, _request, wait, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      # Timeout — re-read anyway. A dropped or cross-node broadcast then
      # costs latency, not an answer; correctness never depends on the
      # message arriving.
      Requests.get_request(id)
    else
      receive do
        %Phoenix.Socket.Broadcast{topic: ^topic} ->
          # The broadcast proves something changed; the database proves
          # what. Never render from the message payload — always re-read.
          with {:ok, fresh} <- Requests.get_request(id) do
            # If still non-terminal, keep waiting with the REMAINING budget
            # (`deadline` is unchanged — `remaining` is recomputed from it
            # on the next call), never a restarted full timeout.
            await(id, topic, fresh, wait, deadline)
          end
      after
        remaining ->
          Requests.get_request(id)
      end
    end
  end

  defp parse_wait(nil), do: 0

  defp parse_wait(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> n |> max(0) |> min(max_wait())
      _ -> 0
    end
  end

  defp parse_wait(_), do: 0

  defp max_wait, do: Application.get_env(:humanport, :long_poll_max_wait_seconds, 50)

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

  defp dispatch_respond(_request, _params, _actor) do
    invalid_field_error(:body, "request body must include either \"answer\" or \"decision\"")
  end

  defp invalid_field_error(field, message) do
    {:error,
     Ash.Error.Invalid.exception(
       errors: [Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)]
     )}
  end
end
