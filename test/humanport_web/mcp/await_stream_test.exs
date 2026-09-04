defmodule HumanportWeb.MCP.AwaitStreamTest do
  @moduledoc """
  02.1-03-PLAN.md Task 3 — the LOAD-BEARING real-socket proof. A `ConnCase`
  connection test has no socket (`Plug.Adapters.Test.Conn.chunk/2` always
  returns `{:ok, _, _}`, never `{:error, _}`) — it cannot prove anything
  about keep-alive cadence, closure-as-cancellation, or a transport bound
  failing to truncate a long wait. This file proves all three against a
  REAL Bandit server, started for this module on an EPHEMERAL port
  (discovered at runtime via `ThousandIsland.listener_info/1`, never
  hardcoded — the test environment configures the endpoint with its own
  server disabled, which is why one is started explicitly here), driven
  with a raw `:gen_tcp` client so the test controls exactly when the
  connection closes.

  Runs on `Humanport.UnsandboxedCase` — the server's own connection-handling
  process needs a REAL, independent database connection to read/write the
  request this test creates while the raw socket test drives it
  concurrently; under the ordinary sandbox that process would have no
  connection allowed to it at all. Every row this module creates is deleted
  in `on_exit`.

  Every test here mutates application-global configuration (the keep-alive
  interval, and the long-wait test's own `wait_seconds`) — forced low (a
  FRACTION of a second, per `HumanportWeb.MCP.Timeouts`' own moduledoc: this
  is exactly why `mcp_keep_alive_interval_ms` is read from config rather
  than compiled in) so the cancellation and cadence proofs run in a second
  or two rather than twenty-plus, and restored in `on_exit`.
  """

  use Humanport.UnsandboxedCase

  import Humanport.Fixtures, only: [request_fixture: 1, default_actor: 0]

  alias Humanport.McpFixtures
  alias Humanport.Requests

  @keep_alive_ms 250

  setup_all do
    {:ok, bandit_pid} =
      Bandit.start_link(plug: HumanportWeb.Endpoint, port: 0, startup_log: false)

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit_pid)

    on_exit(fn ->
      try do
        Supervisor.stop(bandit_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    %{port: port}
  end

  setup do
    original_keep_alive = Application.get_env(:humanport, :mcp_keep_alive_interval_ms)
    Application.put_env(:humanport, :mcp_keep_alive_interval_ms, @keep_alive_ms)

    on_exit(fn ->
      Application.put_env(:humanport, :mcp_keep_alive_interval_ms, original_keep_alive)
    end)

    :ok
  end

  test "keep-alives arrive at the configured cadence, no later than the interval plus a stated tolerance",
       %{port: port} do
    request = request_fixture(%{type: :ask, title: "Nobody answers — keep-alive cadence"})
    cleanup_request(request.id)

    socket = connect(port)
    send_request(socket, request.id, wait_seconds: 3)

    session = read_until(socket, fn s -> length(s.comment_times) >= 3 end, 4_000)
    :gen_tcp.close(socket)

    assert session.status == 200
    assert session.headers["content-type"] == "text/event-stream"
    assert session.headers["x-accel-buffering"] == "no"
    assert length(session.comment_times) >= 3

    # The interval between successive comment lines, measured on the wire,
    # is at most the configured interval plus a generous tolerance for
    # polling granularity and scheduler jitter — a keep-alive that is
    # CONFIGURED but never WRITTEN is exactly the failure this proves.
    tolerance_ms = 400

    session.comment_times
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] ->
      interval = b - a

      assert interval <= @keep_alive_ms + tolerance_ms,
             "keep-alive interval #{interval}ms exceeded #{@keep_alive_ms + tolerance_ms}ms tolerance"
    end)
  end

  test "the final event arrives when the request is answered mid-wait, and the stream terminates",
       %{port: port} do
    request = request_fixture(%{type: :ask, title: "Answered mid-wait — real socket"})
    cleanup_request(request.id)

    socket = connect(port)
    send_request(socket, request.id, wait_seconds: 10)

    answer_task =
      Task.async(fn ->
        Process.sleep(300)
        Requests.answer(request, "the real socket answer", default_actor())
      end)

    session = read_until(socket, fn s -> stream_finished?(s.body) end, 5_000)
    {:ok, _} = Task.await(answer_task, 5_000)
    :gen_tcp.close(socket)

    payload = final_event_payload(session.body)

    assert payload["result"]["structuredContent"]["status"] == "completed"
    assert payload["result"]["structuredContent"]["result"]["answer"] == "the real socket answer"
    assert payload["result"]["_meta"]["app.humanport/wait"]["waited_ms"] > 0
    refute Regex.match?(~r/^id: /m, session.body)
  end

  test "closing the socket mid-wait fires the cancellation telemetry event, and nothing further is written",
       %{port: port} do
    request = request_fixture(%{type: :ask, title: "Cancelled mid-wait"})
    cleanup_request(request.id)

    ref = :telemetry_test.attach_event_handlers(self(), [[:humanport, :mcp, :await, :cancelled]])

    socket = connect(port)
    send_request(socket, request.id, wait_seconds: 5)

    # Wait for at least one keep-alive so we know the stream is genuinely
    # open before we close it — closing before any bytes arrive would
    # prove nothing about a wait IN PROGRESS.
    _session = read_until(socket, fn s -> length(s.comment_times) >= 1 end, 3_000)

    :gen_tcp.close(socket)

    assert_receive {[:humanport, :mcp, :await, :cancelled], ^ref, %{count: 1},
                    %{request_id: request_id}},
                   5_000

    assert request_id == request.id
    :telemetry.detach(ref)

    # Answering afterwards must not raise — the subscription was already
    # released, so this is only proving the server did not crash trying to
    # write to a socket it already knows is gone.
    {:ok, _} = Requests.answer(request, "answered after cancellation", default_actor())
  end

  test "two concurrent await calls on one request are independent — closing one does not disturb the other",
       %{port: port} do
    request = request_fixture(%{type: :ask, title: "Two concurrent awaits"})
    cleanup_request(request.id)

    socket_a = connect(port)
    send_request(socket_a, request.id, wait_seconds: 8)

    socket_b = connect(port)
    send_request(socket_b, request.id, wait_seconds: 8)

    # Both streams open before either is disturbed.
    _session_a = read_until(socket_a, fn s -> length(s.comment_times) >= 1 end, 3_000)
    session_b = read_until(socket_b, fn s -> length(s.comment_times) >= 1 end, 3_000)

    :gen_tcp.close(socket_a)

    answer_task =
      Task.async(fn ->
        Process.sleep(300)
        Requests.answer(request, "the surviving answer", default_actor())
      end)

    # RESUME from socket_b's own already-accumulated session — a fresh
    # session here would try to re-parse an HTTP status line out of
    # whatever arrives NEXT on the socket (mid-stream bytes), not the real
    # response start (see read_until/4's own moduledoc note).
    session_b = read_until(socket_b, session_b, fn s -> stream_finished?(s.body) end, 5_000)
    {:ok, _} = Task.await(answer_task, 5_000)
    :gen_tcp.close(socket_b)

    payload = final_event_payload(session_b.body)
    assert payload["result"]["structuredContent"]["result"]["answer"] == "the surviving answer"
  end

  # 02.1-03-PLAN.md Task 3 — thirty seconds is the plug default the
  # research found in the library that was NOT adopted (D-08); the hazard
  # class is identical for this hand-written pipeline. Tagged `:slow`,
  # excluded by default (test/test_helper.exs), and included explicitly in
  # this task's own <verify> so the no-truncation claim keeps getting
  # proven rather than quietly stopping.
  @tag :slow
  @tag timeout: 60_000
  test "an await configured beyond thirty seconds is still open and still emitting keep-alives past thirty-one seconds",
       %{port: port} do
    request = request_fixture(%{type: :ask, title: "The long wait — nobody ever answers"})
    cleanup_request(request.id)

    socket = connect(port)
    started_at = System.monotonic_time(:millisecond)
    send_request(socket, request.id, wait_seconds: 35)

    session =
      read_until(
        socket,
        fn _s -> System.monotonic_time(:millisecond) - started_at >= 31_000 end,
        40_000
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    :gen_tcp.close(socket)

    assert session.status == 200
    assert elapsed_ms >= 31_000

    assert length(session.comment_times) >= 2,
           "expected the stream to still be emitting keep-alives past 31s, saw #{inspect(session.comment_times)}"
  end

  # --- helpers ---------------------------------------------------------

  defp cleanup_request(id) do
    on_exit(fn ->
      Repo.query!("DELETE FROM human_requests WHERE id = $1", [Ecto.UUID.dump!(id)])
    end)
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    socket
  end

  defp send_request(socket, request_id, opts) do
    arguments =
      %{"id" => request_id}
      |> maybe_put_wait_seconds(Keyword.get(opts, :wait_seconds))

    id = "await-stream-#{System.unique_integer([:positive])}"
    body = McpFixtures.call_tool_request(id, "await", arguments)
    json = Jason.encode!(body)
    headers = McpFixtures.headers_for(body)

    header_lines = headers |> Enum.map(fn {k, v} -> "#{k}: #{v}\r\n" end) |> Enum.join()

    request =
      "POST /mcp HTTP/1.1\r\n" <>
        "host: 127.0.0.1\r\n" <>
        "content-length: #{byte_size(json)}\r\n" <>
        header_lines <>
        "\r\n" <>
        json

    :ok = :gen_tcp.send(socket, request)
  end

  defp maybe_put_wait_seconds(arguments, nil), do: arguments
  defp maybe_put_wait_seconds(arguments, n), do: Map.put(arguments, "wait_seconds", n)

  # Reads from `socket`, accumulating raw bytes, until `stop_fun.(session)`
  # returns true or `timeout_ms` elapses. `session` is a map with `:status`
  # (the HTTP status code, once the header block has arrived — `nil`
  # before that), `:headers` (a downcased header-name => value map),
  # `:body` (everything received AFTER the header block) and
  # `:comment_times` (one `System.monotonic_time(:millisecond)` reading per
  # NEWLY-observed `:\r\n` keep-alive line, in the order observed — a
  # short, 100ms polling granularity, which is what the cadence test's
  # tolerance accounts for).
  defp read_until(socket, stop_fun, timeout_ms) do
    read_until(socket, fresh_session(), stop_fun, timeout_ms)
  end

  # The 4-arg form RESUMES from a session a PRIOR `read_until` call already
  # returned — `:gen_tcp.recv/3` never "rewinds," so a second call that
  # started fresh (`fresh_session/0`) on the SAME socket would try to
  # re-parse an HTTP status line and headers out of whatever bytes happen
  # to arrive NEXT (mid-stream keep-alive/event bytes), not the real
  # response start. Every test in this file that reads the same socket
  # more than once threads the returned session forward for exactly this
  # reason.
  defp read_until(socket, %{} = session, stop_fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_read_until(socket, session, stop_fun, deadline)
  end

  defp fresh_session, do: %{raw: "", status: nil, headers: %{}, body: "", comment_times: []}

  defp do_read_until(socket, session, stop_fun, deadline) do
    cond do
      stop_fun.(session) ->
        session

      System.monotonic_time(:millisecond) >= deadline ->
        session

      true ->
        remaining = deadline - System.monotonic_time(:millisecond)

        case :gen_tcp.recv(socket, 0, min(remaining, 100)) do
          {:ok, data} ->
            session
            |> Map.put(:raw, session.raw <> data)
            |> parse_session()
            |> then(&do_read_until(socket, &1, stop_fun, deadline))

          {:error, :timeout} ->
            do_read_until(socket, session, stop_fun, deadline)

          {:error, _reason} ->
            session
        end
    end
  end

  defp parse_session(%{status: nil, raw: raw} = session) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [head, body] ->
        {status, headers} = parse_headers(head)
        update_comment_times(%{session | status: status, headers: headers, body: body})

      [_incomplete] ->
        session
    end
  end

  defp parse_session(%{status: status} = session) when not is_nil(status) do
    [_head, body] = String.split(session.raw, "\r\n\r\n", parts: 2)
    update_comment_times(%{session | body: body})
  end

  defp parse_headers(head) do
    [status_line | header_lines] = String.split(head, "\r\n")
    [_http_version, status_code, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.reduce(header_lines, %{}, fn line, acc ->
        case String.split(line, ": ", parts: 2) do
          [k, v] -> Map.put(acc, String.downcase(k), v)
          _ -> acc
        end
      end)

    {String.to_integer(status_code), headers}
  end

  defp update_comment_times(session) do
    now = System.monotonic_time(:millisecond)
    observed = comment_count(session.body)
    already = length(session.comment_times)

    if observed > already do
      added = List.duplicate(now, observed - already)
      %{session | comment_times: session.comment_times ++ added}
    else
      session
    end
  end

  defp comment_count(body), do: body |> String.split(":\r\n") |> length() |> Kernel.-(1)

  defp stream_finished?(body), do: String.ends_with?(body, "0\r\n\r\n")

  defp final_event_payload(body) do
    [_, json_str] = Regex.run(~r/data: (.+)\n\n/s, body)
    Jason.decode!(json_str)
  end
end
