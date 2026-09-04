import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/humanport start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :humanport, HumanportWeb.Endpoint, server: true
end

config :humanport, HumanportWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Blank means absent — the precondition for every variable `compose.yaml`
# hands to the container. Compose delivers them with `${VAR:-}`
# interpolation, which is the only form that reads a value out of
# `--env-file` (the bare `KEY:` form resolves from the deploying shell's own
# environment instead, and `--env-file` values "are never directly injected
# into containers", so it cannot carry the documented deploy command). That
# form renders an unconfigured variable as the EMPTY STRING, and `""` is
# truthy in Elixir — so every reader below must be told that blank and
# absent are the same thing, or shipping a variable in `compose.yaml` turns
# a default into a boot crash (`String.to_integer("")`) or, worse, into a
# silently empty setting.
#
# This is the general rule the 2026-09-03 Access finding produced, not a
# special case: a variable may not be added to `compose.yaml` until its
# reader here is blank-safe.
blank_to_nil = fn
  nil -> nil
  value -> if String.trim(value) == "", do: nil, else: value
end

# D-05 — environment override for the stable tenant default set in
# config/config.exs. Still never accepted from the wire.
if tenant_id = blank_to_nil.(System.get_env("HUMANPORT_DEFAULT_TENANT_ID")) do
  config :humanport, default_tenant_id: tenant_id
end

# OPS-03 (02-RESEARCH.md Pitfall 5) — the actor-resolver fork. Deliberately
# a TOP-LEVEL `if`, not nested inside the `config_env() == :prod` block
# below: nesting it there would tie a deployment concern (is Cloudflare
# Access in front of this instance?) to a build-environment concern that
# has other reasons to differ, and would make the fork untestable under
# `mix test`. `compose.yaml` is the one artifact a bare `docker compose up`
# (self-hosting, OPS-01/D-12) and this application's production deployment
# share (`compose.yaml`'s own comment says so) — it declares the Access
# variables but leaves them blank unless the deployment supplies them, and
# `config/config.exs`'s compile-time default
# (`actor_resolver: Humanport.Actors.Resolvers.Env`) is NEVER touched here.
# Only when `HUMANPORT_CF_ACCESS_TEAM_DOMAIN` holds a NON-BLANK value does
# this override fire — so a plain `docker compose up` with nothing exported
# keeps producing byte-for-byte the Phase 1 behaviour, proved by running the
# whole suite with both variables explicitly unset AND explicitly blank
# (02-01-PLAN.md's own verify command, extended by the blank case that
# `${VAR:-}` interpolation made reachable).
if team_domain = blank_to_nil.(System.get_env("HUMANPORT_CF_ACCESS_TEAM_DOMAIN")) do
  aud_tag =
    blank_to_nil.(System.get_env("HUMANPORT_CF_ACCESS_AUD")) ||
      raise """
      environment variable HUMANPORT_CF_ACCESS_AUD is missing.

      HUMANPORT_CF_ACCESS_TEAM_DOMAIN is set, which means this instance is
      about to start verifying Cloudflare Access tokens — but without an
      AUD tag it would accept a valid token minted for ANY Access
      application in the account, not just this one (D-05). Half-configured
      must be loud, never lenient: copy the AUD tag from the Cloudflare
      dashboard for THIS Access application and set it here.
      """

  config :humanport,
    actor_resolver: Humanport.Actors.Resolvers.CloudflareAccess,
    cf_access_team_domain: team_domain,
    cf_access_aud: aud_tag,
    # D-03 (02-02-PLAN.md Task 3) — the accepted revocation-exposure window
    # for the forced JWKS refresh (`CloudflareAccessJwksStrategy`), read at
    # runtime rather than compiled in, following the same
    # `System.get_env(...) |> String.to_integer()` idiom already used for
    # `HUMANPORT_LONG_POLL_MAX_WAIT_SECONDS` below. Five minutes by default,
    # stated in `CloudflareAccessJwksStrategy`'s own moduledoc.
    # Read through `blank_to_nil` for the same reason as the two above:
    # `compose.yaml` declares this variable as `${VAR:-}`, and
    # `System.get_env(var, "300")` returns the EMPTY STRING rather than its
    # default when a variable is set-but-blank — `String.to_integer("")`
    # would then raise at boot on an instance that simply never configured
    # a refresh interval.
    cf_access_jwks_refresh_ms:
      String.to_integer(
        blank_to_nil.(System.get_env("HUMANPORT_CF_ACCESS_JWKS_REFRESH_SECONDS")) || "300"
      ) * 1_000
end

# D-01/D-02 — the `?wait=` long-poll ceiling. 50s sits under all three known
# bounds (Bandit/Thousand Island's 60s read_timeout, Cloudflare's 125s proxy
# read timeout, and the tunnel's own unbounded response time) with margin.
# Lives in runtime config, not compile-time config, specifically so Phase 2
# can lower it from the environment without a code change.
config :humanport,
  long_poll_max_wait_seconds:
    String.to_integer(
      blank_to_nil.(System.get_env("HUMANPORT_LONG_POLL_MAX_WAIT_SECONDS")) || "50"
    )

# D-09c (02.1-CONTEXT.md) — the /mcp Origin allowlist (McpTransportGuard).
# Blank-safe for the same `${VAR:-}` reason as every other compose.yaml-
# declared variable above: an unset or blank HUMANPORT_MCP_ALLOWED_ORIGINS
# must leave the compile-time empty-list default in place, never become a
# list containing one empty string.
if origins = blank_to_nil.(System.get_env("HUMANPORT_MCP_ALLOWED_ORIGINS")) do
  config :humanport,
    mcp_allowed_origins: origins |> String.split(",") |> Enum.map(&String.trim/1)
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :humanport, HumanportWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/humanport_web/router\.ex$"E,
        ~r"lib/humanport_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :humanport, Humanport.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(blank_to_nil.(System.get_env("POOL_SIZE")) || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :humanport, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :humanport, HumanportWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :humanport, HumanportWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :humanport, HumanportWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
