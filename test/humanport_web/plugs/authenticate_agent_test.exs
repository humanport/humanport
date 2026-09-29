defmodule HumanportWeb.Plugs.AuthenticateAgentTest do
  @moduledoc """
  SEC-04/05 over the real `/api/v1` and `/mcp` pipelines: a valid key makes
  the requester verified and named by its key, a bad or revoked key is 401
  every time, no key is accepted unless HUMANPORT_REQUIRE_AGENT_KEY is on,
  and a key may answer other requests but never its own (403).

  `async: false` — the "required" tests flip `:require_agent_key`, which is
  process-global application config.
  """

  use HumanportWeb.ConnCase, async: false

  import Humanport.Fixtures

  alias Humanport.Actors.Actor
  alias Humanport.Agents
  alias Humanport.McpFixtures
  alias Humanport.McpSchema

  @cli %Actor{id: nil, type: :system, label: "release-cli", verified?: false, method: nil}

  defp issue(label, role \\ :requester) do
    {:ok, key, token} = Agents.issue_key(label, @cli, role)
    {key, token}
  end

  defp with_key(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp create_request(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/requests", Jason.encode!(params))
  end

  describe "creating a request over /api/v1" do
    test "with a valid key, the requester is verified and named by the key", %{conn: conn} do
      {_key, token} = issue("deploy-bot")

      body =
        conn
        |> with_key(token)
        |> create_request(%{type: "ask", title: "Ship it?", requester_label: "i-am-root"})
        |> json_response(201)

      assert body["requester_verified"] == true
      assert body["requester_label"] == "deploy-bot"
    end

    test "without a key, the request is accepted and unverified", %{conn: conn} do
      body =
        conn
        |> create_request(%{type: "ask", title: "Ship it?", requester_label: "some-agent"})
        |> json_response(201)

      assert body["requester_verified"] == false
      assert body["requester_label"] == "some-agent"
    end

    test "a wrong, unknown or malformed key is 401, never a downgrade", %{conn: conn} do
      {key, _token} = issue("deploy-bot")

      for token <- ["hp_#{key.prefix}_wrong", "hp_000000000000_x", "garbage"] do
        resp = conn |> with_key(token) |> create_request(%{type: "ask", title: "Ship it?"})

        assert json_response(resp, 401)["error"]["code"] == "unauthorized"
        assert get_resp_header(resp, "www-authenticate") == ["Bearer"]
      end

      assert {:ok, []} = Humanport.Requests.list_requests()
    end

    test "a revoked key is 401", %{conn: conn} do
      {key, token} = issue("deploy-bot")
      {:ok, _} = Agents.revoke_key(key, @cli)

      resp = conn |> with_key(token) |> create_request(%{type: "ask", title: "Ship it?"})
      assert json_response(resp, 401)["error"]["code"] == "unauthorized"
    end

    test "another Authorization scheme counts as no key", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> create_request(%{type: "ask", title: "Ship it?"})

      assert json_response(resp, 201)["requester_verified"] == false
    end
  end

  describe "when HUMANPORT_REQUIRE_AGENT_KEY is on" do
    setup do
      Application.put_env(:humanport, :require_agent_key, true)
      on_exit(fn -> Application.put_env(:humanport, :require_agent_key, false) end)
    end

    test "a request without a key is 401", %{conn: conn} do
      resp = create_request(conn, %{type: "ask", title: "Ship it?"})
      assert json_response(resp, 401)["error"]["code"] == "unauthorized"
    end

    test "a request with a valid key goes through", %{conn: conn} do
      {_key, token} = issue("deploy-bot")

      resp = conn |> with_key(token) |> create_request(%{type: "ask", title: "Ship it?"})
      assert json_response(resp, 201)["requester_verified"] == true
    end

    test "the human inbox is not affected", %{conn: conn} do
      assert html_response(get(conn, ~p"/requests"), 200)
    end
  end

  describe "answering with a key" do
    test "a key cannot answer, approve, reject or choose on its own request", %{conn: conn} do
      # An admin key may both create and answer, so the only thing refusing
      # it here is the self-answer rule.
      {_key, token} = issue("deploy-bot", :admin)

      for {params, body} <- [
            {%{type: "ask", title: "Which one?"}, %{answer: "this one"}},
            {%{type: "approve", title: "Ship it?"}, %{decision: "approve"}},
            {%{type: "approve", title: "Ship it?"}, %{decision: "reject"}},
            {%{type: "choose", title: "Pick", options: [%{id: "a", label: "A"}]},
             %{selected_option_ids: ["a"]}}
          ] do
        id =
          conn |> with_key(token) |> create_request(params) |> json_response(201) |> Map.get("id")

        resp =
          conn
          |> with_key(token)
          |> put_req_header("content-type", "application/json")
          |> post(~p"/api/v1/requests/#{id}/respond", Jason.encode!(body))

        error = json_response(resp, 403)["error"]
        assert error["code"] == "forbidden"
        assert error["message"] =~ "created itself"
        assert {:ok, %{state: :pending}} = Humanport.Requests.get_request(id)
      end
    end

    test "a different key can answer, and is recorded as a verified agent", %{conn: conn} do
      {_asker, asker_token} = issue("deploy-bot")
      {_answerer, answerer_token} = issue("review-bot", :responder)

      id =
        conn
        |> with_key(asker_token)
        |> create_request(%{type: "approve", title: "Ship it?"})
        |> json_response(201)
        |> Map.get("id")

      body =
        conn
        |> with_key(answerer_token)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/requests/#{id}/respond", Jason.encode!(%{decision: "approve"}))
        |> json_response(200)

      assert body["result"]["decision"] == "approved"
      assert body["result"]["decided_by"]["type"] == "agent"
      assert body["result"]["decided_by"]["verified"] == true
      assert body["result"]["decided_by"]["method"] == "api_key"
      assert body["result"]["decided_by"]["label"] == "review-bot"
    end

    test "a key can answer a request nobody's key created", %{conn: conn} do
      {_key, token} = issue("review-bot", :responder)
      request = request_fixture(%{type: :approve, title: "Ship it?"})

      resp =
        conn
        |> with_key(token)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/requests/#{request.id}/respond", Jason.encode!(%{decision: "reject"}))

      assert json_response(resp, 200)["result"]["decision"] == "rejected"
    end
  end

  describe "roles (SEC-02)" do
    test "a requester key cannot answer, approve, reject or choose", %{conn: conn} do
      {_key, token} = issue("deploy-bot", :requester)

      for {type, body} <- [
            {:ask, %{answer: "this one"}},
            {:approve, %{decision: "approve"}},
            {:approve, %{decision: "reject"}},
            {:choose, %{selected_option_ids: ["opt-a"]}}
          ] do
        request =
          if type == :choose,
            do: choose_request_fixture(),
            else: request_fixture(%{type: type, title: "Ship it?"})

        error =
          conn
          |> with_key(token)
          |> put_req_header("content-type", "application/json")
          |> post(~p"/api/v1/requests/#{request.id}/respond", Jason.encode!(body))
          |> json_response(403)
          |> Map.fetch!("error")

        assert error["code"] == "forbidden"
        assert error["message"] =~ "requester role cannot answer"
        assert {:ok, %{state: :pending}} = Humanport.Requests.get_request(request.id)
      end
    end

    test "a responder key cannot create requests", %{conn: conn} do
      {_key, token} = issue("review-bot", :responder)

      error =
        conn
        |> with_key(token)
        |> create_request(%{type: "ask", title: "Ship it?"})
        |> json_response(403)
        |> Map.fetch!("error")

      assert error["code"] == "forbidden"
      assert error["message"] =~ "responder role cannot create"
      assert {:ok, []} = Humanport.Requests.list_requests()
    end

    test "a responder key can still read a request", %{conn: conn} do
      {_key, token} = issue("review-bot", :responder)
      request = request_fixture(%{title: "Ship it?"})

      assert conn
             |> with_key(token)
             |> get(~p"/api/v1/requests/#{request.id}")
             |> json_response(200)
             |> Map.fetch!("id") == request.id
    end

    test "over MCP, a responder key's ask is a tool error, not a transport error", %{conn: conn} do
      {_key, token} = issue("review-bot", :responder)
      body = McpFixtures.call_tool_request("call-1", "ask", %{"title" => "Which region?"})

      response =
        conn
        |> with_key(token)
        |> put_mcp_headers(body)
        |> post(~p"/mcp", Jason.encode!(body))
        |> json_response(200)

      McpSchema.assert_valid!(response["result"], "CallToolResult")
      assert response["result"]["isError"] == true
      assert [%{"text" => text}] = response["result"]["content"]
      assert text =~ "responder role cannot create"
      assert {:ok, []} = Humanport.Requests.list_requests()
    end
  end

  describe "over /mcp" do
    test "tools/call ask with a valid key creates a verified request", %{conn: conn} do
      {_key, token} = issue("mcp-bot")
      body = McpFixtures.call_tool_request("call-1", "ask", %{"title" => "Which region?"})

      response =
        conn
        |> with_key(token)
        |> put_mcp_headers(body)
        |> post(~p"/mcp", Jason.encode!(body))
        |> json_response(200)

      McpSchema.assert_valid!(response["result"], "CallToolResult")
      assert response["result"]["isError"] == false
      assert response["result"]["structuredContent"]["requester_verified"] == true
      assert response["result"]["structuredContent"]["requester_label"] == "mcp-bot"
    end

    test "a bad key is 401 before any JSON-RPC handling", %{conn: conn} do
      body = McpFixtures.call_tool_request("call-1", "ask", %{"title" => "Which region?"})

      resp =
        conn
        |> with_key("hp_000000000000_nope")
        |> put_mcp_headers(body)
        |> post(~p"/mcp", Jason.encode!(body))

      assert json_response(resp, 401)["error"]["code"] == "unauthorized"
      assert {:ok, []} = Humanport.Requests.list_requests()
    end
  end

  defp put_mcp_headers(conn, body) do
    Enum.reduce(McpFixtures.headers_for(body), conn, fn {k, v}, acc ->
      put_req_header(acc, k, v)
    end)
  end
end
