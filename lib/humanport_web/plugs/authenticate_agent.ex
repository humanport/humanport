defmodule HumanportWeb.Plugs.AuthenticateAgent do
  @moduledoc """
  SEC-04/05 — agent keys on the agent-facing surfaces (`/api/v1`, `/mcp`).
  Runs AFTER `HumanportWeb.Plugs.ResolveActor`, never instead of it: the
  configured resolver (and with it the Cloudflare Access gate, when one is
  configured) still decides whether the request gets in at all. A valid key
  then replaces the resolved actor with the key's verified agent actor
  (`Humanport.Agents.actor_for/1`).

  - `Authorization: Bearer <token>` with a valid, unrevoked key → the key's
    agent actor.
  - A bearer token that is malformed, unknown, wrong or revoked → 401,
    always. Presenting a credential that does not work is never quietly
    downgraded to an anonymous request.
  - No bearer token → unchanged, unless `HUMANPORT_REQUIRE_AGENT_KEY` is set
    (`config :humanport, :require_agent_key`), in which case 401. Any other
    `Authorization` scheme counts as no bearer token, so a reverse proxy's
    own Basic auth passes through.

  Every refusal uses the same response body as `ResolveActor`'s, and the
  reason is logged server-side only (see `ResolveActor.log_refusal/2`).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  alias Humanport.Agents

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case bearer_token(conn) do
      {:ok, token} ->
        case Agents.authenticate(token) do
          {:ok, key} -> assign(conn, :actor, Agents.actor_for(key))
          {:error, reason} -> refuse(conn, reason)
        end

      :none ->
        if Application.get_env(:humanport, :require_agent_key, false),
          do: refuse(conn, :agent_key_required),
          else: conn
    end
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> Enum.find_value(:none, fn value ->
      case String.split(value, " ", parts: 2) do
        [scheme, token] -> if String.downcase(scheme) == "bearer", do: {:ok, String.trim(token)}
        _ -> nil
      end
    end)
  end

  defp refuse(conn, reason) do
    Logger.warning(
      "agent key refused (HTTP #{conn.method} #{conn.request_path}): #{inspect(reason)}"
    )

    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(:unauthorized)
    |> json(
      HumanportWeb.RequestJSON.error(%{
        code: "unauthorized",
        message: "Identity could not be resolved.",
        details: %{}
      })
    )
    |> halt()
  end
end
