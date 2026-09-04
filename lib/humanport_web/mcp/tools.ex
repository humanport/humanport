defmodule HumanportWeb.MCP.Tools do
  @moduledoc """
  D-09b (`02.1-CONTEXT.md`) — the ordered tool registry. `all/0` is what a
  `tools/list` result enumerates; `fetch/1` maps a wire tool name to its
  module for `tools/call` dispatch, returning `:error` for an unregistered
  name (the controller turns that into JSON-RPC code `-32602` — an unknown
  tool name is invalid params, not an unknown method).

  Adding a tool means adding its module to `@tools` here — nowhere else in
  the MCP surface needs to know the full list.
  """

  alias HumanportWeb.MCP.Tools.Approve
  alias HumanportWeb.MCP.Tools.Ask
  alias HumanportWeb.MCP.Tools.Await
  alias HumanportWeb.MCP.Tools.Check

  @tools [Ask, Check, Approve, Await]

  @doc "The ordered list of tool modules — what a `tools/list` result enumerates."
  def all, do: @tools

  @doc "Maps a wire tool name to its module, or `:error` if no tool is registered under it."
  def fetch(name) when is_binary(name) do
    Enum.find_value(@tools, :error, fn module ->
      if module.name() == name, do: {:ok, module}
    end)
  end

  def fetch(_name), do: :error

  @doc """
  02.1-03-PLAN.md Task 3 — whether `module` answers a `tools/call` with a
  deferred SSE response stream (`HumanportWeb.MCP.Tool`'s optional
  `streams?/0`/`stream/3` callbacks) rather than the ordinary immediate
  JSON path. `false` for a module that does not implement `streams?/0` at
  all — most tools never need to, and `function_exported?/3` (not a bare
  call) is what makes that safe rather than an `UndefinedFunctionError`.
  """
  def streaming?(module) do
    function_exported?(module, :streams?, 0) and module.streams?()
  end
end
