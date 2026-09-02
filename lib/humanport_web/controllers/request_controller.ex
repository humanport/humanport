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
  404 not found.

  Errors render as `{"error": {"code", "message", "details"}}` with the code
  set `not_found | conflict | invalid | not_implemented | internal`.

  Every action calls `Humanport.Requests` — never builds a changeset and
  never decides a transition itself (§5.2, §54.12).
  """

  use HumanportWeb, :controller

  alias Humanport.Requests

  @terminal_states [:answered, :approved, :rejected]

  def create(conn, params) do
    case Requests.submit(params, conn.assigns.actor) do
      {:ok, request} ->
        conn
        |> put_status(:created)
        |> render(:show, request: request)

      {:error, error} ->
        render_error(conn, error)
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

    case result do
      {:ok, request} -> render(conn, :show, request: request)
      {:error, error} -> render_error(conn, error)
    end
  end

  def respond(conn, %{"id" => id} = params) do
    answer = Map.get(params, "answer")

    with {:ok, request} <- Requests.get_request(id),
         {:ok, answered} <- Requests.answer(request, answer, conn.assigns.actor) do
      render(conn, :show, request: answered)
    else
      {:error, error} -> render_error(conn, error)
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

  defp render_error(conn, error) do
    {status, code, message} = map_error(error)

    conn
    |> put_status(status)
    |> render(:error, code: code, message: message, details: %{})
  end

  # Pattern 7 — inspect the *contained* error, not only the class: both "you
  # sent nonsense" and "someone beat you to it" arrive as Ash.Error.Invalid.
  defp map_error(%Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) ->
        {:not_found, "not_found", "Request not found."}

      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        {:conflict, "conflict", "This request was already answered."}

      Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)) ->
        {:conflict, "conflict", "This request was already answered."}

      Enum.any?(errors, &not_implemented_type?/1) ->
        {:unprocessable_entity, "not_implemented",
         "This request type cannot be created in this version."}

      true ->
        {:unprocessable_entity, "invalid", Ash.Error.error_descriptions(errors)}
    end
  end

  defp map_error(%Ash.Error.Forbidden{errors: errors}) do
    {:forbidden, "invalid", Ash.Error.error_descriptions(errors)}
  end

  defp map_error(_error) do
    {:internal_server_error, "internal", "Your answer could not be saved."}
  end

  defp not_implemented_type?(%Ash.Error.Changes.InvalidAttribute{field: :type, message: message}) do
    is_binary(message) and String.contains?(message, "not implemented")
  end

  defp not_implemented_type?(_), do: false
end
