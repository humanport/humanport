defmodule HumanportWeb.McpControllerTest do
  @moduledoc """
  02.1-02-PLAN.md Task 1 — the tracer: one real MCP `tools/call` for `ask`,
  posted to the real `/mcp` route through the real pipeline, reaching
  `Humanport.Requests.submit/2` exactly as `RequestController.create/2`
  does. Every wire payload is validated against the vendored official
  schema (`Humanport.McpSchema`) rather than against a hand-written
  expectation of what the schema says (`02.1-CONTEXT.md` D-08a).

  Task 2 — the refusal taxonomy: every protocol-level error code taken
  from the vendored schema's own definitions, and the domain-level split
  (malformed vs already-decided vs not-found) reported as a tool-originated
  result rather than a JSON-RPC error, per the spec's own rule that an
  error found IN a tool belongs in the result so the model can self-correct.

  `async: false` — several tests below swap `config :humanport,
  :actor_resolver` for the duration of a test via `Application.put_env/3`
  (the same pattern `resolve_actor_test.exs` already uses), which is
  process-global state.
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
    # 02.1-03-PLAN.md Task 2 registered `check` and `approve` alongside
    # `ask` (test/humanport_web/mcp/retrieval_tools_test.exs covers their
    # own definitions in full) — this test only needs to keep proving `ask`
    # is still IN the list, not that it is the only entry.
    test "returns 200 with ask among the registered tools", %{conn: conn} do
      body = McpFixtures.list_tools_request("list-1")
      resp = post_mcp(conn, body)

      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "ListToolsResult")

      names = Enum.map(response["result"]["tools"], & &1["name"])
      assert "ask" in names
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

    test "a malformed ask call (missing the required title) is a tool-originated error, not a JSON-RPC error",
         %{conn: conn} do
      body = McpFixtures.call_tool_request("malformed-1", "ask", %{})
      resp = post_mcp(conn, body)

      response = json_response(resp, 200)
      McpSchema.assert_valid!(response["result"], "CallToolResult")

      refute Map.has_key?(response, "error")
      assert response["result"]["isError"] == true
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert text =~ "title"

      assert {:ok, []} = Requests.list_requests()
    end
  end

  describe "the refusal taxonomy — protocol-level errors" do
    test "a protocol-version header that disagrees with the body's _meta is refused 400/-32020",
         %{
           conn: conn
         } do
      body = McpFixtures.discover_request("mismatch-1")

      resp =
        conn
        |> put_headers(McpFixtures.headers_for(body))
        |> put_req_header("mcp-protocol-version", "9999-01-01")
        |> post(~p"/mcp", Jason.encode!(body))

      response = json_response(resp, 400)
      assert response["error"]["code"] == -32020
      assert response["error"]["message"] =~ "mcp-protocol-version"
    end

    test "a missing mcp-method header is refused 400/-32020", %{conn: conn} do
      body = McpFixtures.discover_request("missing-method-1")
      headers = Enum.reject(McpFixtures.headers_for(body), fn {k, _} -> k == "mcp-method" end)

      resp =
        conn
        |> put_headers(headers)
        |> post(~p"/mcp", Jason.encode!(body))

      response = json_response(resp, 400)
      assert response["error"]["code"] == -32020
      assert response["error"]["message"] =~ "mcp-method"
    end

    test "a tools/call missing the mcp-name header is refused 400/-32020", %{conn: conn} do
      body = McpFixtures.call_tool_request("missing-name-1", "ask", %{"title" => "x"})
      headers = Enum.reject(McpFixtures.headers_for(body), fn {k, _} -> k == "mcp-name" end)

      resp =
        conn
        |> put_headers(headers)
        |> post(~p"/mcp", Jason.encode!(body))

      response = json_response(resp, 400)
      assert response["error"]["code"] == -32020
      assert response["error"]["message"] =~ "mcp-name"

      assert {:ok, []} = Requests.list_requests()
    end

    test "an unsupported protocol version is refused 400/-32022 naming what is requested and supported",
         %{conn: conn} do
      body = raw_request("unsupported-version-1", "server/discover", "2024-11-05")

      resp =
        conn
        |> put_headers(McpFixtures.headers_for(body))
        |> post(~p"/mcp", Jason.encode!(body))

      response = json_response(resp, 400)
      assert response["error"]["code"] == -32022
      assert response["error"]["data"]["requested"] == "2024-11-05"
      assert response["error"]["data"]["supported"] == ["2026-07-28"]
    end

    test "an unimplemented JSON-RPC method is refused 404/-32601 (never 400 or 405)", %{
      conn: conn
    } do
      body = raw_request("unknown-method-1", "prompts/list", "2026-07-28")

      resp =
        conn
        |> put_headers(McpFixtures.headers_for(body))
        |> post(~p"/mcp", Jason.encode!(body))

      response = json_response(resp, 404)
      assert response["error"]["code"] == -32601
    end

    test "a tools/call naming an unregistered tool is refused 400/-32602", %{conn: conn} do
      body = McpFixtures.call_tool_request("unregistered-tool-1", "not-a-real-tool", %{})
      resp = post_mcp(conn, body)

      response = json_response(resp, 400)
      assert response["error"]["code"] == -32602

      assert {:ok, []} = Requests.list_requests()
    end
  end

  describe "statelessness — an older client's session/stream headers change nothing" do
    test "a session-id and last-event-id header produce the identical response, and no session-id header comes back",
         %{conn: conn} do
      body = McpFixtures.discover_request("stateless-1")

      bare_resp = post_mcp(conn, body)
      bare_body = json_response(bare_resp, 200)

      stateful_resp =
        conn
        |> put_headers(McpFixtures.headers_for(body))
        |> put_req_header("mcp-session-id", "a-session-id-from-an-older-client")
        |> put_req_header("last-event-id", "42")
        |> post(~p"/mcp", Jason.encode!(body))

      stateful_body = json_response(stateful_resp, 200)

      assert bare_body == stateful_body
      assert get_resp_header(bare_resp, "mcp-session-id") == []
      assert get_resp_header(stateful_resp, "mcp-session-id") == []
    end
  end

  defp raw_request(id, method, protocol_version) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => protocol_version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
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
