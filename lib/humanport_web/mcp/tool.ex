defmodule HumanportWeb.MCP.Tool do
  @moduledoc """
  D-09b (`02.1-CONTEXT.md`) — the contract every MCP tool module implements.

  `name/0` is the wire name used in a `tools/list` result and matched
  against a `tools/call` request's `params.name` (see
  `HumanportWeb.MCP.Tools.fetch/1`). `definition/0` is the `Tool` object
  (per the vendored schema, `priv/mcp/schema-2026-07-28.json`) returned in a
  `tools/list` result. `call/2` receives the decoded `arguments` map and the
  `%Humanport.Actors.Actor{}` `HumanportWeb.Plugs.ResolveActor` already
  resolved, and returns `{:ok, map()}` or `{:error, term()}` — it never
  renders a response itself; `HumanportWeb.McpController` does that.

  ## `streams?/0` and `stream/3` — optional, 02.1-03-PLAN.md Task 3

  Two OPTIONAL callbacks a tool module implements INSTEAD of relying on the
  ordinary `call/2` JSON path when its response is a deferred SSE stream
  rather than an immediate result — `HumanportWeb.MCP.Tools.Await` is the
  first (and, as of this plan, only) example. `streams?/0` is a pure
  predicate; `HumanportWeb.MCP.Tools.streaming?/1` calls it (falling back to
  `false` for a module that does not implement it at all, via
  `function_exported?/3` — most tools never need to). `stream/3` receives
  the connection (headers not yet sent), the decoded `arguments` map and the
  resolved actor, and returns the connection AFTER the response stream has
  terminated — it owns the ENTIRE response lifecycle from header-send
  through the final SSE event, exactly as `call/2` owns an ordinary JSON
  result. `HumanportWeb.McpController` branches to `stream/3` purely by
  asking `HumanportWeb.MCP.Tools.streaming?/1` — no tool name ever appears
  in the controller for this decision, matching how `fetch/1` already
  dispatches by name lookup rather than a literal `case` on tool names.
  """

  alias Humanport.Actors.Actor

  @callback name() :: String.t()
  @callback definition() :: map()
  @callback call(arguments :: map(), actor :: Actor.t()) :: {:ok, map()} | {:error, term()}
  @callback streams?() :: boolean()
  @callback stream(conn :: Plug.Conn.t(), arguments :: map(), actor :: Actor.t()) ::
              Plug.Conn.t()

  @optional_callbacks streams?: 0, stream: 3
end
