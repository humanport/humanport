defmodule HumanportWeb.McpJSON do
  @moduledoc """
  D-09c (`02.1-CONTEXT.md`) — the JSON-RPC 2.0 envelope and the three
  mandatory result fields revision `2026-07-28` requires (`resultType`,
  `cacheScope`, `ttlMs`). `resultType` is set to the completed value on
  every result this module builds — the schema marks it required, and its
  absence is how an older server is recognised, so omitting it would make
  this server look like one.

  `discover_result/0` and `list_tools_result/1` both set `cacheScope` to
  `"private"` and `ttlMs` to `0`, deliberately: this endpoint sits behind
  Cloudflare Access, an intermediary must never serve one identity's
  response to another, and a tool list this small buys nothing by being
  cached.
  """

  @result_type "complete"
  @cache_scope_private "private"

  @discover_instructions "HumanPort turns an agent's question, approval " <>
                           "request or choice into a request a human " <>
                           "answers outside the agent's own terminal. " <>
                           "See the ask tool for the interaction " <>
                           "currently implemented."

  @doc "Wraps `result` as a JSON-RPC 2.0 success response for request `id`."
  def result(result, id) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  @doc "Wraps `code`/`message`/optional `data` as a JSON-RPC 2.0 error response for request `id`."
  def error(code, message, id, data \\ nil) do
    error_object =
      %{"code" => code, "message" => message}
      |> maybe_put("data", data)

    %{"jsonrpc" => "2.0", "id" => id, "error" => error_object}
  end

  @doc "The `server/discover` result — supported versions, capabilities, server identity."
  def discover_result do
    %{
      "supportedVersions" => supported_versions(),
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "instructions" => @discover_instructions,
      "cacheScope" => @cache_scope_private,
      "ttlMs" => 0,
      "resultType" => @result_type,
      "_meta" => %{
        "io.modelcontextprotocol/serverInfo" => %{
          "name" => "humanport",
          "version" => server_version()
        }
      }
    }
  end

  @doc "The `tools/list` result for the given ordered list of tool modules."
  def list_tools_result(tool_modules) do
    %{
      "tools" => Enum.map(tool_modules, & &1.definition()),
      "cacheScope" => @cache_scope_private,
      "ttlMs" => 0,
      "resultType" => @result_type
    }
  end

  @doc """
  The `tools/call` `CallToolResult`. `attrs` carries `:content` (required),
  and optionally `:structured_content` and `:is_error`.
  """
  def tool_result(attrs) do
    %{"content" => Map.fetch!(attrs, :content), "resultType" => @result_type}
    |> maybe_put("isError", Map.get(attrs, :is_error))
    |> maybe_put("structuredContent", Map.get(attrs, :structured_content))
  end

  defp supported_versions, do: Application.get_env(:humanport, :mcp_supported_versions, [])

  defp server_version do
    case Application.spec(:humanport, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
