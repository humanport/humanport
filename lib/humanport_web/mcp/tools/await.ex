defmodule HumanportWeb.MCP.Tools.Await do
  @moduledoc """
  02.1-03-PLAN.md Task 3 — D-01a. Wire name `await`. The deferred-response
  half of the same primitive `check` (Task 2) uses for its immediate half:
  both read through `Humanport.Requests.get_request/1`, and both render the
  SAME result shape (`HumanportWeb.MCP.Tools.Check.wait_meta/2`, reused
  here) — `await` differs only in holding the connection open, as an SSE
  response stream with periodic keep-alives, until the request is answered
  or its own ceiling elapses.

  Framing and every load-bearing claim about what this stream may and must
  do is pinned, quoted verbatim from the specification, in
  `priv/mcp/TRANSPORT.md` — this module writes exactly those bytes, not an
  invented shape: a bare `:\r\n` comment line as keep-alive, and
  `data: <json>\n\n` for every JSON-RPC message (no `event:` field — this
  revision's own spec text never prescribes one — and no `id:` field,
  because resumable streams are not supported here).

  ## Why the outer loop calls the shared primitive, rather than threading a
  callback into it

  `HumanportWeb.RequestWaiting.await/4` waits on the CALLING PROCESS's own
  mailbox — the subscription this module makes BEFORE its first read
  (`open/4`) lives OUTSIDE that function's call, for the connection
  process's entire lifetime until this module unsubscribes. That is what
  makes it safe to call `RequestWaiting.await/4` repeatedly, once per
  keep-alive interval, in a loop here (`loop/6`): a broadcast that arrives
  while a keep-alive comment is being WRITTEN is not lost — it simply sits
  in the process's mailbox, and the very next `RequestWaiting.await/4` call
  picks it up immediately (its own `receive` cannot "miss" a message
  already sitting in the mailbox). This is also exactly why
  `RequestWaiting` itself needs no knowledge of streaming at all — it stays
  a pure function of its four arguments, serving the HTTP long-poll and
  this loop identically.

  ## Cancellation IS the disconnect (D-01a, `priv/mcp/TRANSPORT.md`)

  This revision defines no `notifications/cancelled` on Streamable HTTP.
  Every `Plug.Conn.chunk/2` write in this module is checked; the first one
  that reports the peer is gone (`{:error, _}`) fires
  `[:humanport, :mcp, :await, :cancelled]` (with the request id in its
  metadata), unsubscribes from the topic, halts the connection, and writes
  nothing further — per the pinned rule that closing the stream MUST be
  treated as cancellation and the server MUST NOT send any further
  messages for that request.

  ## D-02 holds unchanged

  A window that closes without an answer is an ordinary result carrying
  `state: pending` — never an error, never an `isError` result, and no
  timeout branch of any kind exists anywhere in this module (grep for
  `isError.*true` intersecting a timeout/deadline branch and find none).
  Many agent runtimes treat a tool error as grounds to abort a run; a run
  aborted because a human had not answered yet is precisely the failure
  this phase exists to remove.
  """

  @behaviour HumanportWeb.MCP.Tool

  import Plug.Conn

  alias Humanport.Actors.Actor
  alias Humanport.Requests
  alias HumanportWeb.AshErrorMapper
  alias HumanportWeb.MCP.Timeouts
  alias HumanportWeb.MCP.Tools.Check
  alias HumanportWeb.McpJSON
  alias HumanportWeb.RequestWaiting

  @cancelled_event [:humanport, :mcp, :await, :cancelled]
  # priv/mcp/TRANSPORT.md's pinned keep-alive line, verbatim.
  @keep_alive_comment ":\r\n"
  @terminal_states [:answered, :approved, :rejected]

  @impl true
  def name, do: "await"

  @impl true
  def streams?, do: true

  @impl true
  def definition do
    %{
      "name" => name(),
      "title" => "Await a request's answer",
      "description" =>
        "Holds the connection open — as a Server-Sent Events response stream with " <>
          "periodic keep-alives, per this revision's Streamable HTTP transport rules " <>
          "— until the named request is answered or the wait elapses. A window that " <>
          "closes without an answer returns an ordinary pending result, never an error.",
      "annotations" => %{
        "title" => "Await a request's answer",
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      },
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "The request's id."},
          "wait_seconds" => %{
            "type" => "integer",
            "description" =>
              "How long to hold the connection open, in seconds. Clamped to the " <>
                "server's configured ceiling."
          }
        },
        "required" => ["id"]
      }
    }
  end

  @impl true
  def call(_arguments, %Actor{}) do
    # This tool answers ONLY through stream/3 —
    # HumanportWeb.MCP.Tools.streaming?/1 routes every `tools/call await`
    # there before call/2 could ever be reached (mcp_controller.ex).
    # HumanportWeb.MCP.Tool still requires call/2 as a mandatory callback;
    # reaching this clause at all would itself be a controller-dispatch
    # bug, not a normal outcome.
    {:error, :not_streamable}
  end

  @impl true
  def stream(conn, arguments, %Actor{}) when is_map(arguments) do
    rpc_id = conn.assigns[:mcp_request_id]

    case Map.get(arguments, "id") do
      id when is_binary(id) -> open(conn, rpc_id, id, arguments)
      _ -> respond_tool_error(conn, rpc_id, missing_id_error())
    end
  end

  defp open(conn, rpc_id, request_id, arguments) do
    topic = RequestWaiting.topic(request_id)

    # Step 1 — subscribe BEFORE the first read (Pattern 6): reading first
    # opens a window in which the answer commits and broadcasts before the
    # subscription exists, and the caller then waits out the whole window
    # for an event that already happened.
    HumanportWeb.Endpoint.subscribe(topic)

    case Requests.get_request(request_id) do
      # Step 2 — a missing request is a tool-originated error, reported as
      # an ordinary JSON result. Do NOT open a stream to report it — a
      # stream that opens only to close is harder for a client to
      # interpret than a plain result.
      {:error, error} ->
        HumanportWeb.Endpoint.unsubscribe(topic)
        respond_tool_error(conn, rpc_id, error)

      # Step 3 — already terminal: answer immediately as a plain JSON
      # result. There is nothing to stream.
      {:ok, %{state: state} = request} when state in @terminal_states ->
        HumanportWeb.Endpoint.unsubscribe(topic)
        respond_success(conn, rpc_id, request, 0)

      {:ok, request} ->
        run(conn, rpc_id, request_id, topic, request, clamp_wait_seconds(arguments))
    end
  end

  # Step 4 — send the stream headers, begin the chunked response, then
  # loop until the deadline.
  defp run(conn, rpc_id, request_id, topic, request, wait_seconds) do
    started_at = System.monotonic_time(:millisecond)
    deadline_ms = started_at + round(:timer.seconds(wait_seconds))

    conn
    |> put_resp_header("x-accel-buffering", "no")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_content_type("text/event-stream", nil)
    |> send_chunked(200)
    |> loop(rpc_id, request_id, topic, request, deadline_ms, started_at)
  end

  defp loop(conn, rpc_id, request_id, topic, request, deadline_ms, started_at) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)
    slice_ms = remaining_ms |> min(Timeouts.keep_alive_interval_ms()) |> max(0)

    # Call the SAME shared primitive the HTTP long-poll uses, for a slice
    # of at most one keep-alive interval (or whatever remains, whichever
    # is shorter) — see this module's own moduledoc for why a slice can
    # never lose a wakeup that arrives while a keep-alive is being written.
    case RequestWaiting.await(request_id, topic, request, slice_ms / 1_000) do
      {:ok, %{state: state} = fresh} when state in @terminal_states ->
        # Step 5 — terminate the stream with the final response event.
        waited_ms = System.monotonic_time(:millisecond) - started_at
        finish(conn, rpc_id, topic, request_id, fresh, waited_ms)

      {:ok, fresh} when remaining_ms <= 0 ->
        # The OVERALL deadline (not merely this slice's) has passed —
        # D-02: a closed window with no answer is an ordinary pending
        # result, not an error and not a timeout branch.
        waited_ms = System.monotonic_time(:millisecond) - started_at
        finish(conn, rpc_id, topic, request_id, fresh, waited_ms)

      {:ok, fresh} ->
        write_or_cancel(conn, topic, request_id, @keep_alive_comment, fn conn ->
          loop(conn, rpc_id, request_id, topic, fresh, deadline_ms, started_at)
        end)

      # A DEFENSIVE clause, not a normal outcome: nothing in this domain
      # ever deletes a HumanRequest row, so `Requests.get_request/1`
      # returning not-found for an id this same process already read
      # successfully in `open/4` should never happen through ordinary
      # application code. It IS reachable — a raw SQL delete bypassing the
      # domain entirely, exactly like `human_request.ex`'s own terminal-row
      # trigger defends against. The stream is already open by this point
      # (headers sent), so this cannot become a plain JSON error the way
      # `open/4`'s pre-stream not-found case does — it terminates the
      # stream with a tool-originated error EVENT instead, reusing the
      # SAME classifier every other boundary error in this codebase uses.
      {:error, error} ->
        finish_error(conn, rpc_id, topic, request_id, error)
    end
  end

  defp finish(conn, rpc_id, topic, request_id, request, waited_ms) do
    HumanportWeb.Endpoint.unsubscribe(topic)
    event = final_event(rpc_id, request, waited_ms)
    write_or_cancel(conn, topic, request_id, event, & &1)
  end

  defp finish_error(conn, rpc_id, topic, request_id, error) do
    HumanportWeb.Endpoint.unsubscribe(topic)
    {_kind, message} = AshErrorMapper.classify(error)

    result =
      McpJSON.tool_result(%{content: [%{"type" => "text", "text" => message}], is_error: true})

    payload = McpJSON.result(result, rpc_id)
    event = "data: " <> Jason.encode!(payload) <> "\n\n"
    write_or_cancel(conn, topic, request_id, event, & &1)
  end

  # Every chunk write in this module — a keep-alive comment or the final
  # response event — is checked the same way: on success, continue with
  # `on_success.(conn)`; on the peer being gone, fire the cancellation
  # telemetry event, unsubscribe (a no-op if `finish/5` already did),
  # halt, and write nothing further.
  defp write_or_cancel(conn, topic, request_id, data, on_success) do
    case chunk(conn, data) do
      {:ok, conn} ->
        on_success.(conn)

      {:error, _reason} ->
        :telemetry.execute(@cancelled_event, %{count: 1}, %{request_id: request_id})
        HumanportWeb.Endpoint.unsubscribe(topic)
        halt(conn)
    end
  end

  defp final_event(rpc_id, request, waited_ms) do
    result = McpJSON.tool_result(result_attrs(waited_ms, request))
    payload = McpJSON.result(result, rpc_id)
    # priv/mcp/TRANSPORT.md's pinned framing FINDING: bare `data:`, no
    # `event:`, no `id:` — this revision's spec text prescribes neither,
    # and an `id:` would invite a resumption this server cannot honour.
    "data: " <> Jason.encode!(payload) <> "\n\n"
  end

  defp respond_success(conn, rpc_id, request, waited_ms) do
    result = McpJSON.tool_result(result_attrs(waited_ms, request))

    conn
    |> put_status(:ok)
    |> Phoenix.Controller.json(McpJSON.result(result, rpc_id))
  end

  defp respond_tool_error(conn, rpc_id, error) do
    {_kind, message} = AshErrorMapper.classify(error)

    result =
      McpJSON.tool_result(%{content: [%{"type" => "text", "text" => message}], is_error: true})

    conn
    |> put_status(:ok)
    |> Phoenix.Controller.json(McpJSON.result(result, rpc_id))
  end

  defp result_attrs(waited_ms, request) do
    %{
      content: [
        %{
          "type" => "text",
          "text" => "req/#{HumanportWeb.RequestLive.short_id(request.id)} is #{request.state}."
        }
      ],
      structured_content: HumanportWeb.RequestJSON.show(%{request: request}),
      is_error: false,
      meta: Check.wait_meta(waited_ms, request)
    }
  end

  defp clamp_wait_seconds(arguments) do
    ceiling_seconds = Timeouts.await_timeout_ms() / 1_000

    case Map.get(arguments, "wait_seconds") do
      n when is_integer(n) and n > 0 -> min(n, ceiling_seconds)
      _ -> ceiling_seconds
    end
  end

  defp missing_id_error do
    Ash.Error.Invalid.exception(
      errors: [
        Ash.Error.Changes.InvalidAttribute.exception(field: :id, message: "id is required")
      ]
    )
  end
end
