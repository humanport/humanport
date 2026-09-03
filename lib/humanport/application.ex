defmodule Humanport.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        HumanportWeb.Telemetry,
        Humanport.Repo,
        {DNSCluster, query: Application.get_env(:humanport, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Humanport.PubSub}
        # Start a worker by calling: Humanport.Worker.start_link(arg)
        # {Humanport.Worker, arg},
      ] ++
        cloudflare_access_jwks_strategy_child() ++
        [
          # Start to serve requests, typically the last entry
          HumanportWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Humanport.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HumanportWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # OPS-03/D-03 — supervised ONLY when `config/runtime.exs` configured
  # `:cf_access_team_domain` (itself gated on `HUMANPORT_CF_ACCESS_TEAM_DOMAIN`
  # — see that file). Reads APPLICATION config here, never the OS
  # environment directly (02-RESEARCH.md Pitfall 5's own warning: two
  # places reading the environment for the same fact is how a boot ends up
  # with a resolver configured and no JWKS cache started, or the reverse)
  # — `config/runtime.exs` is the only place that reads these variables
  # from the environment. The tuple is OMITTED entirely rather
  # than started as a no-op (contrast `DNSCluster`'s `:ignore`-value
  # pattern above) — a bare `docker compose up` with no Cloudflare
  # configuration starts no extra process and makes no network call at
  # boot, matching OPS-01/D-12 byte-for-byte.
  #
  # Placed immediately before `HumanportWeb.Endpoint`, which this module's
  # own comment already names as the last entry — `first_fetch_sync: false`
  # (`Humanport.Actors.CloudflareAccessJwksStrategy`) means this never
  # blocks the Endpoint from starting; ordering here is about supervision
  # tree shutdown order, not about blocking boot on a network call.
  defp cloudflare_access_jwks_strategy_child do
    if Application.get_env(:humanport, :cf_access_team_domain) do
      [Humanport.Actors.CloudflareAccessJwksStrategy]
    else
      []
    end
  end
end
