defmodule HumanportWeb.MCP.RetrievalToolsTest do
  @moduledoc """
  02.1-03-PLAN.md Task 2 — `check` (the immediate glance) and `approve` (the
  second creation tool), driven through the real `/mcp` route with
  `Humanport.McpFixtures` bodies and headers. Every response is validated
  through `Humanport.McpSchema.assert_valid!/2` against the definition the
  behaviour line names, never against a hand-written expectation.

  02.1-03-PLAN.md Task 3 extends this file with `await`'s connection-level
  behaviour (headers, chunk framing, the pending-window result, the
  already-terminal shortcut) — everything a `ConnCase` connection test can
  observe honestly. The real-socket proof (keep-alives, closure-is-cancellation,
  the thirty-one-second wait) lives in `await_stream_test.exs`, which needs a
  real listening socket this test's connection stub does not have.

  `async: false` — `with_cloudflare_access_resolver/0` swaps
  `config :humanport, :actor_resolver` for the duration of a test via
  `Application.put_env/3` (the same pattern `mcp_controller_test.exs` and
  `resolve_actor_test.exs` already use), which is process-global state.
  """

  use HumanportWeb.ConnCase, async: false

  import Humanport.Fixtures, only: [default_actor: 0]

  alias Humanport.CloudflareAccessFixtures, as: CfFixtures
  alias Humanport.McpFixtures
  alias Humanport.McpSchema
  alias Humanport.Requests

  describe "check — the immediate glance" do
    test "on a pending request returns a CallToolResult with waited_ms 0 and structuredContent equal to RequestJSON.show/1",
         %{conn: conn} do
      {:ok, request} = Requests.submit(%{type: :ask, title: "Which entry?"}, default_actor())

      body = McpFixtures.call_tool_request("check-1", "check", %{"id" => request.id})
      resp = post_mcp(conn, body)

      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "CallToolResult")

      assert response["result"]["isError"] == false

      {:ok, fresh} = Requests.get_request(request.id)

      expected =
        %{request: fresh}
        |> HumanportWeb.RequestJSON.show()
        |> Jason.encode!()
        |> Jason.decode!()

      assert response["result"]["structuredContent"] == expected
      assert response["result"]["_meta"]["app.humanport/wait"]["waited_ms"] == 0
      assert response["result"]["_meta"]["app.humanport/wait"]["pending_for_ms"] >= 0
    end

    test "on an already-answered request also returns waited_ms 0", %{conn: conn} do
      {:ok, request} = Requests.submit(%{type: :ask, title: "Answered already"}, default_actor())
      {:ok, _} = Requests.answer(request, "the answer", default_actor())

      body = McpFixtures.call_tool_request("check-2", "check", %{"id" => request.id})
      resp = post_mcp(conn, body)
      response = json_response(resp, 200)

      assert response["result"]["structuredContent"]["status"] == "completed"
      assert response["result"]["_meta"]["app.humanport/wait"]["waited_ms"] == 0
      assert response["result"]["_meta"]["app.humanport/wait"]["pending_for_ms"] != nil
    end

    test "never waits — returns promptly regardless of the request's state", %{conn: conn} do
      {:ok, request} = Requests.submit(%{type: :ask, title: "Timing check"}, default_actor())
      body = McpFixtures.call_tool_request("check-3", "check", %{"id" => request.id})

      started_at = System.monotonic_time(:millisecond)
      resp = post_mcp(conn, body)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      json_response(resp, 200)
      assert elapsed_ms < 500, "check must never wait, took #{elapsed_ms}ms"
    end

    test "naming a missing id returns a tool-originated error, not a JSON-RPC error", %{
      conn: conn
    } do
      missing_id = Ecto.UUID.generate()
      body = McpFixtures.call_tool_request("check-4", "check", %{"id" => missing_id})
      resp = post_mcp(conn, body)

      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "CallToolResult")

      refute Map.has_key?(response, "error")
      assert response["result"]["isError"] == true
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert text =~ "not found"
    end
  end

  describe "approve — the second creation tool" do
    test "creates exactly one pending HumanRequest of type approve, decision and completed_at null",
         %{conn: conn} do
      body = McpFixtures.call_tool_request("approve-1", "approve", %{"title" => "Ship 1.4?"})
      resp = post_mcp(conn, body)

      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "CallToolResult")
      assert response["result"]["isError"] == false

      request_id = response["result"]["structuredContent"]["id"]
      {:ok, request} = Requests.get_request(request_id)

      assert request.type == :approve
      assert request.state == :pending
      assert request.decision == nil
      assert request.completed_at == nil
    end

    test "with a genuine Cloudflare Access service-token identity, still only creates — never decides",
         %{conn: conn} do
      with_cloudflare_access_resolver()

      token =
        CfFixtures.signed_token(common_name: "agent-service-token-1.access", without: [:email])

      body =
        McpFixtures.call_tool_request("approve-2", "approve", %{"title" => "Deploy to prod?"})

      resp =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post_mcp(body)

      response = json_response(resp, 200)
      request_id = response["result"]["structuredContent"]["id"]
      {:ok, request} = Requests.get_request(request_id)

      assert request.state == :pending
      assert request.decision == nil
    end
  end

  describe "tools/list — exactly five entries" do
    # Widened from four to five by 02.1-05-PLAN.md Task 1, which registers
    # `choose` as the third creation tool — a stale-test site the plan
    # itself did not enumerate (Rule 1: found by this task's own full-suite
    # run, not by the plan's own drift-check).
    test "returns ask, check, approve, await and choose, and validates against ListToolsResult",
         %{conn: conn} do
      body = McpFixtures.list_tools_request("list-1")
      resp = post_mcp(conn, body)

      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "ListToolsResult")

      names = Enum.map(response["result"]["tools"], & &1["name"])
      assert length(names) == 5
      assert "ask" in names
      assert "check" in names
      assert "approve" in names
      assert "await" in names
      assert "choose" in names
    end
  end

  describe "await — connection-level behaviour a stub adapter can observe honestly" do
    test "on an already-terminal request, answers as plain JSON with waited_ms 0 — no stream opened",
         %{conn: conn} do
      {:ok, request} = Requests.submit(%{type: :ask, title: "Already answered"}, default_actor())
      {:ok, _} = Requests.answer(request, "done", default_actor())

      body = McpFixtures.call_tool_request("await-1", "await", %{"id" => request.id})
      resp = post_mcp(conn, body)

      assert get_resp_header(resp, "content-type") == ["application/json; charset=utf-8"]
      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "CallToolResult")

      assert response["result"]["isError"] == false
      assert response["result"]["_meta"]["app.humanport/wait"]["waited_ms"] == 0
      assert response["result"]["structuredContent"]["status"] == "completed"
    end

    test "naming a missing id returns a tool-originated error as plain JSON — no stream opened",
         %{conn: conn} do
      missing_id = Ecto.UUID.generate()
      body = McpFixtures.call_tool_request("await-2", "await", %{"id" => missing_id})
      resp = post_mcp(conn, body)

      assert get_resp_header(resp, "content-type") == ["application/json; charset=utf-8"]
      response = json_response(resp, 200)

      refute Map.has_key?(response, "error")
      assert response["result"]["isError"] == true
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert text =~ "not found"
    end

    test "on a pending request, opens an event-stream response with the no-buffering header",
         %{conn: conn} do
      {:ok, request} = Requests.submit(%{type: :ask, title: "Nobody answers"}, default_actor())

      body =
        McpFixtures.call_tool_request("await-3", "await", %{
          "id" => request.id,
          "wait_seconds" => 1
        })

      resp = post_mcp(conn, body)

      assert resp.status == 200
      assert get_resp_header(resp, "content-type") == ["text/event-stream"]
      assert get_resp_header(resp, "x-accel-buffering") == ["no"]
      assert get_resp_header(resp, "mcp-session-id") == []

      raw = response(resp, 200)
      assert String.contains?(raw, ":\r\n") or raw =~ ~r/data: /
    end

    test "a window that closes with no answer terminates the stream with a pending CallToolResult, isError false",
         %{conn: conn} do
      {:ok, request} =
        Requests.submit(%{type: :ask, title: "Nobody answers, ever"}, default_actor())

      body =
        McpFixtures.call_tool_request("await-4", "await", %{
          "id" => request.id,
          "wait_seconds" => 1
        })

      resp = post_mcp(conn, body)
      raw = response(resp, 200)

      [_, json_str] = Regex.run(~r/data: (.+)\n\n\z/s, raw)
      payload = Jason.decode!(json_str)

      McpSchema.assert_valid!(payload["result"], "CallToolResult")
      assert payload["id"] == "await-4"
      refute Regex.match?(~r/^id: /m, raw)
      assert payload["result"]["isError"] == false
      assert payload["result"]["structuredContent"]["status"] == "pending"
      assert payload["result"]["_meta"]["app.humanport/wait"]["waited_ms"] > 0
    end

    test "answered mid-wait, the stream's final event carries the answer and waited_ms > 0",
         %{conn: conn} do
      {:ok, request} = Requests.submit(%{type: :ask, title: "Answered mid-wait"}, default_actor())

      body =
        McpFixtures.call_tool_request("await-5", "await", %{
          "id" => request.id,
          "wait_seconds" => 10
        })

      wait_task =
        Task.async(fn ->
          conn
          |> put_headers(McpFixtures.headers_for(body))
          |> post(~p"/mcp", Jason.encode!(body))
        end)

      Process.sleep(150)
      {:ok, _} = Requests.answer(request, "the real answer", default_actor())

      resp = Task.await(wait_task, 5_000)
      raw = response(resp, 200)

      [_, json_str] = Regex.run(~r/data: (.+)\n\n\z/s, raw)
      payload = Jason.decode!(json_str)

      McpSchema.assert_valid!(payload["result"], "CallToolResult")
      assert payload["result"]["structuredContent"]["status"] == "completed"
      assert payload["result"]["structuredContent"]["result"]["answer"] == "the real answer"
      assert payload["result"]["_meta"]["app.humanport/wait"]["waited_ms"] > 0
    end
  end

  defp post_mcp(conn, body) do
    conn
    |> put_headers(McpFixtures.headers_for(body))
    |> post(~p"/mcp", Jason.encode!(body))
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  defp with_cloudflare_access_resolver do
    original_resolver = Application.fetch_env!(:humanport, :actor_resolver)
    Application.put_env(:humanport, :actor_resolver, Humanport.Actors.Resolvers.CloudflareAccess)
    on_exit(fn -> Application.put_env(:humanport, :actor_resolver, original_resolver) end)
    :ok
  end
end
