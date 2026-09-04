defmodule HumanportWeb.MCP.ChooseToolTest do
  @moduledoc """
  02.1-05-PLAN.md Task 1 — the `choose` tool, the third creation tool,
  driven through the real `/mcp` route with `Humanport.McpFixtures` bodies
  and headers, exactly like `retrieval_tools_test.exs`'s `approve` describe
  block. Every response is validated through
  `Humanport.McpSchema.assert_valid!/2` against the definition the
  behaviour line names, never against a hand-written expectation.

  The cross-surface parity case (a request created here and one created
  over `POST /api/v1/requests` are field-by-field indistinguishable) lives
  in `parity_test.exs`'s established unsandboxed shape, not here — one
  place where cross-surface equality is asserted, extended, is better than
  two that can drift (the plan's own instruction).

  `async: false` — `with_cloudflare_access_resolver/0` swaps
  `config :humanport, :actor_resolver` for the duration of a test, process-
  global state, exactly like `retrieval_tools_test.exs`.
  """

  use HumanportWeb.ConnCase, async: false

  alias Humanport.CloudflareAccessFixtures, as: CfFixtures
  alias Humanport.McpFixtures
  alias Humanport.McpSchema
  alias Humanport.Repo
  alias Humanport.Requests

  @three_options [
    %{"id" => "opt-a", "label" => "Roll back", "description" => "Revert to the last release"},
    %{"id" => "opt-b", "label" => "Roll forward", "recommended" => true},
    %{"id" => "opt-c", "label" => "Do nothing"}
  ]

  describe "choose — the third creation tool" do
    test "creates exactly one pending choose request, options stored verbatim in the submitted order",
         %{conn: conn} do
      body =
        McpFixtures.call_tool_request("choose-1", "choose", %{
          "title" => "Which way for the failed deploy?",
          "options" => @three_options
        })

      resp = post_mcp(conn, body)
      response = json_response(resp, 200)

      McpSchema.assert_valid!(response["result"], "CallToolResult")
      assert response["result"]["isError"] == false

      request_id = response["result"]["structuredContent"]["id"]
      {:ok, request} = Requests.get_request(request_id)

      assert request.type == :choose
      assert request.state == :pending

      # By value, against the exact list sent — not field by field (the
      # plan's own instruction).
      assert Enum.map(request.options, fn opt ->
               %{
                 "id" => opt.id,
                 "label" => opt.label,
                 "description" => opt.description,
                 "recommended" => opt.recommended
               }
             end) ==
               [
                 %{
                   "id" => "opt-a",
                   "label" => "Roll back",
                   "description" => "Revert to the last release",
                   "recommended" => nil
                 },
                 %{
                   "id" => "opt-b",
                   "label" => "Roll forward",
                   "description" => nil,
                   "recommended" => true
                 },
                 %{
                   "id" => "opt-c",
                   "label" => "Do nothing",
                   "description" => nil,
                   "recommended" => nil
                 }
               ]

      # The verbatim round trip is observable in the very response that
      # created the options, not only by re-reading the row.
      response_options = response["result"]["structuredContent"]["options"]
      assert length(response_options) == 3
      assert Enum.at(response_options, 0)["id"] == "opt-a"
      assert Enum.at(response_options, 1)["recommended"] == true
    end

    test "an option with no description and no advisory flag comes back with both still absent",
         %{conn: conn} do
      body =
        McpFixtures.call_tool_request("choose-2", "choose", %{
          "title" => "Bare option",
          "options" => [%{"id" => "only", "label" => "The only path"}]
        })

      resp = post_mcp(conn, body)
      response = json_response(resp, 200)

      request_id = response["result"]["structuredContent"]["id"]
      {:ok, request} = Requests.get_request(request_id)

      assert [%{id: "only", label: "The only path", description: nil, recommended: nil}] =
               request.options

      [wire_option] = response["result"]["structuredContent"]["options"]
      assert wire_option["description"] == nil
      assert wire_option["recommended"] == nil
    end

    test "the free-text flag and max_selections pass through unchanged; omitting yields the attributes' own defaults",
         %{conn: conn} do
      body =
        McpFixtures.call_tool_request("choose-3", "choose", %{
          "title" => "With free text and a higher cap",
          "options" => @three_options,
          "allow_free_text" => true,
          "max_selections" => 2
        })

      resp = post_mcp(conn, body)
      response = json_response(resp, 200)

      request_id = response["result"]["structuredContent"]["id"]
      {:ok, request} = Requests.get_request(request_id)

      assert request.allow_free_text == true
      assert request.max_selections == 2

      default_body =
        McpFixtures.call_tool_request("choose-4", "choose", %{
          "title" => "Defaults",
          "options" => @three_options
        })

      default_resp = post_mcp(conn, default_body)
      default_response = json_response(default_resp, 200)
      default_id = default_response["result"]["structuredContent"]["id"]
      {:ok, default_request} = Requests.get_request(default_id)

      assert default_request.allow_free_text == false
      assert default_request.max_selections == 1
    end

    test "with no options, is refused as a tool-originated error carrying the domain's own field-level message",
         %{conn: conn} do
      body = McpFixtures.call_tool_request("choose-5", "choose", %{"title" => "Nothing to pick"})

      resp = post_mcp(conn, body)
      response = json_response(resp, 200)

      McpSchema.assert_valid!(response["result"], "CallToolResult")

      refute Map.has_key?(response, "error")
      assert response["result"]["isError"] == true
      assert [%{"type" => "text", "text" => text}] = response["result"]["content"]
      assert text =~ "must offer at least one option"
    end

    test "with a genuine Cloudflare Access service-token identity, the audit event records it verified",
         %{conn: conn} do
      with_cloudflare_access_resolver()

      token =
        CfFixtures.signed_token(
          common_name: "agent-service-token-choose.access",
          without: [:email]
        )

      body =
        McpFixtures.call_tool_request("choose-6", "choose", %{
          "title" => "Verified path",
          "options" => @three_options
        })

      resp =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post_mcp(body)

      response = json_response(resp, 200)
      request_id = response["result"]["structuredContent"]["id"]

      %Postgrex.Result{rows: [[verified, method, source_protocol, correlation_id]]} =
        Repo.query!(
          "SELECT actor_verified, actor_method, source_protocol, correlation_id " <>
            "FROM audit_events WHERE request_id = $1 AND event_type = 'request.created'",
          [Ecto.UUID.dump!(request_id)]
        )

      assert verified == true
      assert method == "service_token"

      # No channel marker anywhere an audit event can be read from.
      assert source_protocol == nil
      assert correlation_id == nil
    end
  end

  describe "tools/list — the advisory flag's description states advice, never a default" do
    test "the choose tool's recommended field description names the flag as advice only", %{
      conn: conn
    } do
      body = McpFixtures.list_tools_request("list-choose")
      resp = post_mcp(conn, body)
      response = json_response(resp, 200)

      McpSchema.assert_valid!(response["result"], "ListToolsResult")

      choose_def = Enum.find(response["result"]["tools"], &(&1["name"] == "choose"))
      refute is_nil(choose_def)

      recommended_description =
        choose_def["inputSchema"]["properties"]["options"]["items"]["properties"]["recommended"][
          "description"
        ]

      assert recommended_description =~ "Advice"
      assert recommended_description =~ "NEVER a default"
      assert recommended_description =~ "NEVER"
    end

    test "tools/list now advertises exactly five entries, choose among them", %{conn: conn} do
      body = McpFixtures.list_tools_request("list-choose-count")
      resp = post_mcp(conn, body)
      response = json_response(resp, 200)

      McpSchema.assert_valid!(response["result"], "ListToolsResult")

      names = Enum.map(response["result"]["tools"], & &1["name"])
      assert length(names) == 5
      assert "choose" in names
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
