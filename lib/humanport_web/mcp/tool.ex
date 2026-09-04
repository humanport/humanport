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
  """

  alias Humanport.Actors.Actor

  @callback name() :: String.t()
  @callback definition() :: map()
  @callback call(arguments :: map(), actor :: Actor.t()) :: {:ok, map()} | {:error, term()}
end
