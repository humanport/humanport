defmodule HumanportWeb.McpControllerTest do
  @moduledoc """
  02.1-02-PLAN.md Task 1 — the tracer: one real MCP `tools/call` for `ask`,
  posted to the real `/mcp` route through the real pipeline, reaching
  `Humanport.Requests.submit/2` exactly as `RequestController.create/2`
  does. Every wire payload is validated against the vendored official
  schema (`Humanport.McpSchema`) rather than against a hand-written
  expectation of what the schema says (`02.1-CONTEXT.md` D-08a).

  `async: false` — two describe blocks below swap
  `config :humanport, :actor_resolver` for the duration of a test via
  `Application.put_env/3` (the same pattern `resolve_actor_test.exs`
  already uses), which is process-global state.
  """

  use HumanportWeb.ConnCase, async: false

  alias Humanport.CloudflareAccessFixtures, as: CfFixtures
  alias Humanport.McpFixtures
  alias Humanport.McpSchema
  alias Humanport.Repo
  alias Humanport.Requests

  describe "server/discover" do
    test "returns 200 and a result that validates against DiscoverResult", %{conn: conn} do
      body = McpFixtures.discover_request("discover-1")
      resp = post_mcp(conn, body)

      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "DiscoverResult")

      assert response["result"]["supportedVersions"] == ["2026-07-28"]
      assert response["result"]["resultType"] == "complete"
      assert response["result"]["capabilities"]["tools"]
      assert response["id"] == "discover-1"
    end
  end

  describe "tools/list" do
    test "returns 200 with exactly one tool named ask", %{conn: conn} do
      body = McpFixtures.list_tools_request("list-1")
      resp = post_mcp(conn, body)

      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "ListToolsResult")

      assert [%{"name" => "ask"}] = response["result"]["tools"]
      assert response["result"]["resultType"] == "complete"
    end
  end

  describe "tools/call ask — the tracer" do
    test "creates exactly one HumanRequest through Requests.submit/2", %{conn: conn} do
      body =
        McpFixtures.call_tool_request("call-1", "ask", %{"title" => "Which changelog entry?"})

      resp = post_mcp(conn, body)

      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "CallToolResult")

      assert response["result"]["isError"] == false
      assert response["id"] == "call-1"

      assert {:ok, [request]} = Requests.list_requests()
      assert request.type == :ask
      assert request.title == "Which changelog entry?"

      expected =
        %{request: request}
        |> HumanportWeb.RequestJSON.show()
        |> Jason.encode!()
        |> Jason.decode!()

      assert response["result"]["structuredContent"] == expected
    end

    test "the structured payload is byte-identical to RequestJSON.show/1, by value comparison", %{
      conn: conn
    } do
      body =
        McpFixtures.call_tool_request("call-1a", "ask", %{
          "title" => "Ship 1.4?",
          "context" => %{"pr" => 42},
          "risk" => "high"
        })

      resp = post_mcp(conn, body)
      response = json_response(resp, 200)

      assert {:ok, [request]} = Requests.list_requests()

      expected =
        %{request: request}
        |> HumanportWeb.RequestJSON.show()
        |> Jason.encode!()
        |> Jason.decode!()

      assert response["result"]["structuredContent"] == expected
      assert expected["risk"] == "high"
      assert expected["context"] == %{"pr" => 42}
    end

    test "the acting identity records as a verified service-token actor, not unverified", %{
      conn: conn
    } do
      with_cloudflare_access_resolver()

      token =
        CfFixtures.signed_token(common_name: "agent-service-token-1.access", without: [:email])

      body = McpFixtures.call_tool_request("call-2", "ask", %{"title" => "Deploy to prod?"})

      resp =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post_mcp(body)

      response = json_response(resp, 200)
      request_id = response["result"]["structuredContent"]["id"]

      %Postgrex.Result{rows: [[actor_verified, actor_method]]} =
        Repo.query!(
          "SELECT actor_verified, actor_method FROM audit_events WHERE request_id = $1 AND event_type = 'request.created'",
          [Ecto.UUID.dump!(request_id)]
        )

      assert actor_verified == true
      assert actor_method == "service_token"
    end

    test "source is passed through untouched and the audit event's source_protocol stays nil", %{
      conn: conn
    } do
      body =
        McpFixtures.call_tool_request("call-3", "ask", %{
          "title" => "x",
          "source" => "claude-code/gsd"
        })

      resp = post_mcp(conn, body)
      response = json_response(resp, 200)
      request_id = response["result"]["structuredContent"]["id"]

      assert response["result"]["structuredContent"]["source"] == "claude-code/gsd"

      %Postgrex.Result{rows: [[source_protocol]]} =
        Repo.query!(
          "SELECT source_protocol FROM audit_events WHERE request_id = $1 AND event_type = 'request.created'",
          [Ecto.UUID.dump!(request_id)]
        )

      assert is_nil(source_protocol)
    end

    test "no resolvable identity is refused 401 before any request row is created", %{conn: conn} do
      with_cloudflare_access_resolver()

      body = McpFixtures.call_tool_request("call-4", "ask", %{"title" => "x"})
      resp = post_mcp(conn, body)

      json_response(resp, 401)
      assert {:ok, []} = Requests.list_requests()
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
