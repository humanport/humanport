defmodule HumanportWeb.HealthController do
  @moduledoc """
  OPS-06, D-06/D-07 — `/health` and `/ready`, the two endpoints the Compose
  healthcheck in `compose.yaml` (through `Humanport.Release.healthcheck!/0`)
  and any future outside-in check ask instead of guessing.

  Deliberately outside the `plain-v1` error envelope
  `HumanportWeb.RequestController`'s own moduledoc names — no
  `action_fallback HumanportWeb.FallbackController` here.
  `FallbackController`'s `map_error/1` clauses match Ash error shapes; a
  not-ready instance and a malformed API request are not the same kind of
  event, and forcing the former into the latter's envelope would tell a
  client otherwise. Both actions below render their own small
  `%{status: ...}` map inline instead.

  Reached through the `:health` router pipeline (`router.ex`), which carries
  only `plug :accepts, ["json"]` — deliberately NOT
  `HumanportWeb.Plugs.ResolveActor`. These endpoints must keep answering even
  when the actor resolver itself is what is broken (D-07): putting
  `ResolveActor` in front of them would mean the in-container healthcheck
  receives 401 from `Resolvers.CloudflareAccess` onward, the container is
  marked unhealthy while the application is fine, and every debugging hour
  spent on it would be spent on the wrong subsystem. D-07 also explicitly
  declined a Cloudflare Access bypass rule for this path — these routes are
  reached only from inside the host (the Compose healthcheck via `rpc`),
  never over the tunnel.
  """

  use HumanportWeb, :controller

  @doc """
  Liveness only — the BEAM is up and the router is dispatching requests. No
  database call: that is the entire distinction between this action and
  `ready/2`. A liveness check that queries the database reports the runtime
  as dead whenever the database merely is, which is exactly the distinction
  `/health` and `/ready` exist to draw.
  """
  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @doc """
  D-06 — ready only once the database answers AND every migration is
  applied. `reason`, when present, is always the machine-readable
  atom/tagged-tuple `Humanport.Release.ready?/0` itself returns — rendered
  through `inspect/1` for the wire, never hand-formatted prose — so a caller
  can branch on which half failed without parsing a sentence.
  """
  def ready(conn, _params) do
    case Humanport.Release.ready?() do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "not_ready", reason: inspect(reason)})
    end
  end
end
