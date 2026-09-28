defmodule HumanportWeb.Plugs.McpTransportGuardTest do
  @moduledoc """
  02.1-02-PLAN.md Task 2 — `HumanportWeb.Plugs.McpTransportGuard`'s own two
  refusals, isolated from the rest of the `/mcp` validation chain:
  POST-only (405, no body, actor resolver never invoked) and the Origin
  allowlist (403 by default; 200 once the origin is explicitly allowed) —
  the DNS-rebinding defence `T-02.1-06` names.

  `async: false` — the second describe block mutates
  `config :humanport, :mcp_allowed_origins`, process-global state, for the
  duration of one test.
  """

  use HumanportWeb.ConnCase, async: false

  alias Humanport.McpFixtures

  describe "POST-only" do
    test "GET is refused 405 with no body, and the actor resolver never runs", %{conn: conn} do
      resp = get(conn, ~p"/mcp")

      assert resp.status == 405
      assert resp.resp_body == ""
      assert resp.assigns[:actor] == nil
    end

    test "DELETE is refused 405 with no body, and the actor resolver never runs", %{conn: conn} do
      resp = delete(conn, ~p"/mcp")

      assert resp.status == 405
      assert resp.resp_body == ""
      assert resp.assigns[:actor] == nil
    end
  end

  describe "Origin allowlist (T-02.1-06)" do
    test "a browser-style Origin header is refused 403 against the default empty allowlist", %{
      conn: conn
    } do
      body = McpFixtures.discover_request("origin-1")

      resp =
        conn
        |> put_headers(McpFixtures.headers_for(body))
        |> put_req_header("origin", "https://evil.example")
        |> post(~p"/mcp", Jason.encode!(body))

      assert resp.status == 403
      assert resp.resp_body == ""
    end

    test "the same Origin succeeds once explicitly added to the allowlist", %{conn: conn} do
      original = Application.fetch_env!(:humanport, :mcp_allowed_origins)
      Application.put_env(:humanport, :mcp_allowed_origins, ["https://allowed.example"])
      on_exit(fn -> Application.put_env(:humanport, :mcp_allowed_origins, original) end)

      body = McpFixtures.discover_request("origin-2")

      resp =
        conn
        |> put_headers(McpFixtures.headers_for(body))
        |> put_req_header("origin", "https://allowed.example")
        |> post(~p"/mcp", Jason.encode!(body))

      json_response(resp, 200)
    end
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end
end
