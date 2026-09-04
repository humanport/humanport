defmodule HumanportWeb.McpController do
  @moduledoc """
  D-09/D-09c (`02.1-CONTEXT.md`) — the single Streamable HTTP entry point
  for the MCP surface: JSON-RPC envelope validation, the mirrored-header
  rules revision `2026-07-28` requires, protocol-version negotiation
  against `Application.get_env(:humanport, :mcp_supported_versions)`, and
  method dispatch to `server/discover`, `tools/list` and `tools/call`.

  ## Scope boundary — this is NOT `PROTO-04`

  This is a single-node endpoint. Retrieval is by a request's own primary
  id against this instance's own database. Multi-node operation and
  correlation-ID retrieval across instances is `PROTO-04` and is Phase 3's
  concern — not implemented here, and not accidentally acquired merely
  because this endpoint is stateless: revision `2026-07-28` is stateless by
  construction (that is a property of the protocol), which is not evidence
  that multi-node retrieval exists (`02.1-CONTEXT.md` D-09a/D-09d).

  An inbound session-id header from an older client is ignored; this
  module mints and echoes none — protocol-level sessions are gone under
  this revision. An inbound `Last-Event-ID` header is likewise ignored:
  response streams from this endpoint are not resumable. Both are what
  revision `2026-07-28` requires of a server that speaks only it
  (`02.1-CONTEXT.md` D-01b, D-09c).

  Every write this controller can reach goes through
  `Humanport.Requests` — never a changeset or an `Ash.*` call built here
  (PROTO-09).
  """

  use HumanportWeb, :controller

  alias HumanportWeb.MCP.Tools
  alias HumanportWeb.McpJSON

  @required_meta_keys [
    "io.modelcontextprotocol/protocolVersion",
    "io.modelcontextprotocol/clientCapabilities"
  ]

  def handle(conn, _params) do
    body = conn.body_params

    case validate(conn, body) do
      :notification ->
        send_resp(conn, :accepted, "")

      {:ok, id, method, rpc_params} ->
        dispatch(conn, id, method, rpc_params)

      {:error, status, code, message, data} ->
        respond_error(conn, status, code, message, data, envelope_id(body))
    end
  end

  @doc """
  Named so the router has an action for the catch-all `/mcp` route.
  `HumanportWeb.Plugs.McpTransportGuard` halts a non-POST request before it
  is ever reached — this exists only as the fallback if that guard is ever
  bypassed, and returns the same bare 405 the guard would have.
  """
  def method_not_allowed(conn, _params) do
    send_resp(conn, :method_not_allowed, "")
  end

  defp validate(conn, body) when is_map(body) do
    with :ok <- validate_envelope(body) do
      case Map.get(body, "id") do
        nil -> :notification
        id -> validate_request(conn, body, id)
      end
    end
  end

  defp validate(_conn, _body) do
    {:error, :bad_request, -32600, "request body must be a JSON object", nil}
  end

  # -32600 — InvalidRequestError (schema definition `InvalidRequestError`).
  defp validate_envelope(body) do
    cond do
      Map.get(body, "jsonrpc") != "2.0" ->
        {:error, :bad_request, -32600, "jsonrpc must be \"2.0\"", nil}

      not is_binary(Map.get(body, "method")) ->
        {:error, :bad_request, -32600, "method must be a string", nil}

      true ->
        :ok
    end
  end

  defp validate_request(conn, body, id) do
    method = Map.fetch!(body, "method")
    rpc_params = Map.get(body, "params", %{})
    meta = Map.get(rpc_params, "_meta", %{})

    with :ok <- validate_required_meta(meta),
         :ok <- validate_mirrored_headers(conn, method, rpc_params, meta),
         :ok <- validate_supported_version(meta) do
      {:ok, id, method, rpc_params}
    end
  end

  # -32600 — InvalidRequestError. `RequestMetaObject`'s own `required` list.
  defp validate_required_meta(meta) when is_map(meta) do
    if Enum.all?(@required_meta_keys, &Map.has_key?(meta, &1)) do
      :ok
    else
      {:error, :bad_request, -32600,
       "params._meta must carry io.modelcontextprotocol/protocolVersion and " <>
         "io.modelcontextprotocol/clientCapabilities", nil}
    end
  end

  defp validate_required_meta(_meta) do
    {:error, :bad_request, -32600, "params._meta is required", nil}
  end

  defp validate_mirrored_headers(conn, method, rpc_params, meta) do
    with :ok <-
           check_mirrored_header(
             conn,
             "mcp-protocol-version",
             Map.get(meta, "io.modelcontextprotocol/protocolVersion")
           ),
         :ok <- check_mirrored_header(conn, "mcp-method", method) do
      check_name_header(conn, method, rpc_params)
    end
  end

  defp check_name_header(conn, "tools/call", rpc_params) do
    check_mirrored_header(conn, "mcp-name", Map.get(rpc_params, "name"))
  end

  defp check_name_header(_conn, _method, _rpc_params), do: :ok

  # -32020 — HeaderMismatchError (schema definition `HeaderMismatchError`).
  defp check_mirrored_header(_conn, header, expected) when not is_binary(expected) do
    {:error, :bad_request, -32020,
     "#{header} could not be verified: the request body carries no value to mirror it against",
     %{"header" => header}}
  end

  defp check_mirrored_header(conn, header, expected) do
    case get_req_header(conn, header) do
      [^expected] ->
        :ok

      [] ->
        {:error, :bad_request, -32020, "missing required header: #{header}",
         %{"header" => header}}

      _other ->
        {:error, :bad_request, -32020, "#{header} header does not match the request body",
         %{"header" => header}}
    end
  end

  # -32022 — UnsupportedProtocolVersionError (schema definition
  # `UnsupportedProtocolVersionError`).
  defp validate_supported_version(meta) do
    requested = Map.get(meta, "io.modelcontextprotocol/protocolVersion")
    supported = supported_versions()

    if requested in supported do
      :ok
    else
      {:error, :bad_request, -32022, "unsupported protocol version",
       %{"requested" => requested, "supported" => supported}}
    end
  end

  defp dispatch(conn, id, "server/discover", _rpc_params) do
    respond_result(conn, id, McpJSON.discover_result())
  end

  defp dispatch(conn, id, "tools/list", _rpc_params) do
    respond_result(conn, id, McpJSON.list_tools_result(Tools.all()))
  end

  defp dispatch(conn, id, "tools/call", rpc_params) do
    name = Map.get(rpc_params, "name")

    case Tools.fetch(name) do
      {:ok, tool_module} ->
        arguments = Map.get(rpc_params, "arguments", %{})

        case tool_module.call(arguments, conn.assigns.actor) do
          {:ok, result} ->
            respond_result(conn, id, McpJSON.tool_result(result))

          {:error, error} ->
            respond_tool_error(conn, id, error)
        end

      # -32602 — InvalidParamsError. An unknown tool name is invalid
      # params, not an unknown method.
      :error ->
        respond_error(conn, :bad_request, -32602, "unknown tool: #{inspect(name)}", nil, id)
    end
  end

  # -32601 — MethodNotFoundError, HTTP 404 (not 400 — this is what lets a
  # client distinguish this endpoint from a legacy server that does not
  # host it at all; the spec is explicit about the distinction).
  defp dispatch(conn, id, _other_method, _rpc_params) do
    respond_error(conn, :not_found, -32601, "method not found", nil, id)
  end

  # Task 1's minimal mapping — 02.1-02-PLAN.md Task 2 replaces this with
  # the full not-found/already-decided/malformed split reused from
  # HumanportWeb.FallbackController.
  defp respond_tool_error(conn, id, error) do
    message =
      if is_exception(error) do
        Exception.message(error)
      else
        inspect(error)
      end

    respond_result(
      conn,
      id,
      McpJSON.tool_result(%{content: [%{"type" => "text", "text" => message}], is_error: true})
    )
  end

  defp respond_result(conn, id, result) do
    conn |> put_status(:ok) |> json(McpJSON.result(result, id))
  end

  defp respond_error(conn, status, code, message, data, id) do
    conn |> put_status(status) |> json(McpJSON.error(code, message, id, data))
  end

  defp envelope_id(body) when is_map(body), do: Map.get(body, "id")
  defp envelope_id(_body), do: nil

  defp supported_versions, do: Application.get_env(:humanport, :mcp_supported_versions, [])
end
