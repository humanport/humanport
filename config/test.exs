import Config
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# OPS-03 Wave 0 test seam (02-VALIDATION.md) — the fixture's own team
# domain/AUD tag, so `Humanport.Actors.CloudflareAccessToken.token_config/0`
# (which reads these via `Application.get_env/2`) validates against exactly
# what `Humanport.CloudflareAccessFixtures.signed_token/1` signs against.
# `cf_access_jwks_strategy` is read at COMPILE time
# (`Application.compile_env/3` in `CloudflareAccessToken`) — pointing it at
# the stub means no network call ever reaches Cloudflare in a test run.
config :humanport,
  cf_access_team_domain: "test-team",
  cf_access_aud: "test-aud-tag",
  cf_access_jwks_strategy: Humanport.CloudflareAccessFixtures.StubJwksStrategy

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
#
# Credentials come from the environment — see config/dev.exs for why.
config :humanport, Humanport.Repo,
  username: System.get_env("DATABASE_USERNAME", "humanport"),
  password: System.get_env("DATABASE_PASSWORD", "humanport"),
  hostname: System.get_env("DATABASE_HOSTNAME", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  database:
    System.get_env("DATABASE_NAME", "humanport_test#{System.get_env("MIX_TEST_PARTITION")}"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :humanport, HumanportWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "h3U3J/8HyYrSkzSWiP1lSdOiwnP3q5PEY/Co2RiSrLT5VygJP77XbVap23Wzl0JW",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
