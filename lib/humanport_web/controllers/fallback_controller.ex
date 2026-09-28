defmodule HumanportWeb.FallbackController do
  @moduledoc """
  Pattern 7 — maps the *contained* Ash error, not merely its class, to an
  HTTP status and the plain-v1 `{"error": {"code", "message", "details"}}`
  envelope. Both "you sent nonsense" and "someone beat you to it" arrive as
  `Ash.Error.Invalid`, and the split between them is the whole point: 409
  tells an agent to stop retrying and read the answer; 422 tells it its
  request was malformed. Collapsing the two makes the agent retry a request
  that is already decided, forever.

  The classification itself lives in `HumanportWeb.AshErrorMapper`
  (02.1-02-PLAN.md Task 2) — this module only maps that classification to
  an HTTP status and the plain-v1 envelope's `code` string.
  `HumanportWeb.McpController` reuses the same classifier for the MCP
  surface's tool-originated errors, so there is exactly one taxonomy, not
  two that drift.

  Wired via `action_fallback` on `HumanportWeb.RequestController` — every
  controller action there returns either a rendered `conn` or a bare
  `{:error, term()}`, and Phoenix dispatches the latter here.
  """

  use HumanportWeb, :controller

  alias HumanportWeb.AshErrorMapper

  def call(conn, {:error, error}) do
    {status, code, message, details} = map_error(error)

    conn
    |> put_status(status)
    |> put_view(json: HumanportWeb.RequestJSON)
    |> render(:error, code: code, message: message, details: details)
  end

  defp map_error(error) do
    {kind, message} = AshErrorMapper.classify(error)

    case kind do
      :not_found -> {:not_found, "not_found", message, %{}}
      :conflict -> {:conflict, "conflict", message, %{}}
      :not_implemented -> {:unprocessable_entity, "not_implemented", message, %{}}
      :invalid -> {:unprocessable_entity, "invalid", message, AshErrorMapper.details(error)}
      :forbidden -> {:forbidden, "invalid", message, %{}}
      :internal -> {:internal_server_error, "internal", message, %{}}
    end
  end
end
