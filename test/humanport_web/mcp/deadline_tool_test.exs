defmodule HumanportWeb.MCP.DeadlineToolTest do
  @moduledoc """
  ROUTE-* — `deadline_at` on the three creating MCP tools. Every wire payload
  is validated against the vendored official schema (`Humanport.McpSchema`),
  never against a hand-written expectation of it.
  """

  use HumanportWeb.ConnCase, async: true
  use Oban.Testing, repo: Humanport.Repo

  alias Humanport.McpFixtures
  alias Humanport.McpSchema

  defp post_mcp(conn, body) do
    conn =
      Enum.reduce(McpFixtures.headers_for(body), conn, fn {k, v}, acc ->
        put_req_header(acc, k, v)
      end)

    post(conn, ~p"/mcp", Jason.encode!(body))
  end

  test "ask, approve and choose each declare deadline_at as an optional date-time", %{conn: conn} do
    response = conn |> post_mcp(McpFixtures.list_tools_request("list-1")) |> json_response(200)
    McpSchema.assert_valid!(response["result"], "ListToolsResult")

    tools = Map.new(response["result"]["tools"], &{&1["name"], &1})

    for name <- ~w(ask approve choose) do
      schema = tools[name]["inputSchema"]
      assert schema["properties"]["deadline_at"]["format"] == "date-time"
      refute "deadline_at" in (schema["required"] || [])
    end
  end

  test "an ask with deadline_at creates a request scheduled to expire", %{conn: conn} do
    deadline_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    body =
      McpFixtures.call_tool_request("call-1", "ask", %{
        "title" => "Which region?",
        "deadline_at" => deadline_at
      })

    response = conn |> post_mcp(body) |> json_response(200)
    McpSchema.assert_valid!(response["result"], "CallToolResult")

    assert response["result"]["isError"] == false
    created = response["result"]["structuredContent"]
    assert created["deadline_at"]

    assert_enqueued(
      worker: Humanport.Requests.Workers.ExpireRequest,
      args: %{"request_id" => created["id"]}
    )
  end

  test "a deadline in the past is a tool error result, not a transport error", %{conn: conn} do
    body =
      McpFixtures.call_tool_request("call-2", "ask", %{
        "title" => "Too late",
        "deadline_at" => "2020-01-01T00:00:00Z"
      })

    response = conn |> post_mcp(body) |> json_response(200)
    McpSchema.assert_valid!(response["result"], "CallToolResult")
    assert response["result"]["isError"] == true
  end
end
