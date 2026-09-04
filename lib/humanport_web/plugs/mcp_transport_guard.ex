defmodule HumanportWeb.Plugs.McpTransportGuard do
  @moduledoc """
  D-09c (`02.1-CONTEXT.md`) — the first plug in the `:mcp` pipeline, ahead of
  actor resolution, enforcing two things neither the controller nor
  `HumanportWeb.Plugs.ResolveActor` should have to know about:

  1. **POST only.** Revision `2026-07-28` removed the standalone GET event
     stream and the session-delete verb (`02.1-CLIENT-REVISION.md`) — this
     transport defines no meaning for `GET` or `DELETE` on `/mcp`. Either is
     refused with a bare 405, no body, before the actor resolver runs.
  2. **Origin allowlist (T-02.1-06).** A hostile page in a visitor's browser
     can issue a cross-origin request to a reachable localhost/LAN endpoint
     (DNS rebinding). An `Origin` header present but not in
     `Application.get_env(:humanport, :mcp_allowed_origins)` (default:
     empty) is refused with 403. An ABSENT `Origin` header passes — that is
     the ordinary shape of a non-browser agent runtime's request (no
     browser, no `Origin` header at all), and this guard must never refuse
     the one caller `/mcp` exists for.

  MUST NOT read the request body — both checks above have to hold before
  `Plug.Parsers` does any work a wrong-method or wrong-origin request does
  not deserve.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin | _] ->
        if origin in allowed_origins() do
          conn
        else
          conn |> send_resp(:forbidden, "") |> halt()
        end
    end
  end

  def call(conn, _opts) do
    conn |> send_resp(:method_not_allowed, "") |> halt()
  end

  defp allowed_origins, do: Application.get_env(:humanport, :mcp_allowed_origins, [])
end
