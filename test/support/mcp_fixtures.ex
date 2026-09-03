defmodule Humanport.McpFixtures do
  @moduledoc """
  `02.1-01-PLAN.md` Task 3 Part C. Well-formed MCP `2026-07-28` request
  bodies and their matching HTTP headers, reused by every later contract
  test in this phase.

  ## Source of truth

  These bodies are shaped after the traffic actually captured from the
  Claude Code CLI (`2.1.259`) in
  `.planning/phases/02.1-humanport-in-the-loop/02.1-CLIENT-REVISION.md`
  (`02.1-01-PLAN.md` Task 3 Part A) — not reconstructed from the schema
  alone. A fixture built only against the schema can be schema-valid and
  still unlike anything the runtime actually sends; the capture is what it
  actually sends.

  ## The owner's revision decision

  The owner decided on 2026-09-04, from that captured evidence, that
  `server/discover` advertises `2026-07-28` only (see `02.1-CLIENT-REVISION.md`
  "Owner's decision" and the one-line note in `priv/mcp/README.md`). These
  fixtures exist for that one revision and no other.

  ## No handshake

  Revision `2026-07-28` defines no handshake request or its paired
  notification — the capture confirms the real client never sends either.
  No fixture in this module may construct one.
  """

  @protocol_version "2026-07-28"

  @doc "The protocol revision every fixture in this module is built for: `\"2026-07-28\"`."
  def protocol_version, do: @protocol_version

  @doc """
  A `server/discover` JSON-RPC 2.0 request body, `id` given by the caller.
  Validates against `Humanport.McpSchema`'s `DiscoverRequest` definition.
  """
  def discover_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "server/discover",
      "params" => %{"_meta" => request_meta()}
    }
  end

  @doc """
  A `tools/list` JSON-RPC 2.0 request body, `id` given by the caller.
  Validates against `Humanport.McpSchema`'s `ListToolsRequest` definition.
  """
  def list_tools_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/list",
      "params" => %{"_meta" => request_meta()}
    }
  end

  @doc """
  A `tools/call` JSON-RPC 2.0 request body for `tool_name` with `arguments`,
  `id` given by the caller. Validates against `Humanport.McpSchema`'s
  `CallToolRequest` definition.
  """
  def call_tool_request(id, tool_name, arguments \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "_meta" => request_meta(),
        "name" => tool_name,
        "arguments" => arguments
      }
    }
  end

  @doc """
  The Streamable HTTP headers a well-formed client sends alongside `body`,
  derived FROM `body` rather than hardcoded a second time — a fixture and
  its headers cannot drift apart this way.

  `MCP-Protocol-Version` mirrors `body`'s `_meta` protocol-version value.
  `Mcp-Method` mirrors `body["method"]`. For a `tools/call` body only,
  `Mcp-Name` also mirrors `body["params"]["name"]`.
  """
  def headers_for(%{"method" => method, "params" => %{"_meta" => meta}} = body) do
    base = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", Map.fetch!(meta, "io.modelcontextprotocol/protocolVersion")},
      {"mcp-method", method}
    ]

    case body do
      %{"method" => "tools/call", "params" => %{"name" => name}} ->
        base ++ [{"mcp-name", name}]

      _ ->
        base
    end
  end

  defp request_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => @protocol_version,
      "io.modelcontextprotocol/clientCapabilities" => %{
        "roots" => %{"listChanged" => true},
        "elicitation" => %{}
      }
    }
  end
end
