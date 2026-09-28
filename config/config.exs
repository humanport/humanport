# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :humanport,
  ecto_repos: [Humanport.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [Humanport.Requests, Humanport.Audit],
  # D-09 — the actor-resolver seam. Phase 2 swaps this for
  # Humanport.Actors.Resolvers.CloudflareAccess without touching a write path.
  actor_resolver: Humanport.Actors.Resolvers.Env,
  # D-05 — never accepted from the wire. A stable default UUID, overridable
  # per environment in config/runtime.exs.
  default_tenant_id: "00000000-0000-0000-0000-000000000001",
  # D-09c (02.1-CONTEXT.md) — the MCP surface. The advertised revision list
  # is fixed by the owner's decision recorded in priv/mcp/README.md, not
  # read from the environment: widening it is a protocol decision, not a
  # deploy knob. mcp_allowed_origins defaults to empty (refuses every
  # browser-originated request); HUMANPORT_MCP_ALLOWED_ORIGINS overrides it
  # at runtime (config/runtime.exs).
  mcp_supported_versions: ["2026-07-28"],
  mcp_allowed_origins: [],
  # 02.1-03-PLAN.md Task 1 Part D — the MCP `await` tool's own ceiling,
  # expressed in milliseconds so `HumanportWeb.MCP.Timeouts.await_timeout_ms/0`
  # never has to multiply at read time. Equal to the long-poll ceiling's own
  # default (50s, config/runtime.exs) — the two are independently
  # configurable (HUMANPORT_MCP_AWAIT_TIMEOUT_SECONDS below vs
  # HUMANPORT_LONG_POLL_MAX_WAIT_SECONDS), but ship with the same default so
  # `await` behaves like the HTTP `?wait=` surface out of the box.
  mcp_await_timeout_ms: 50_000,
  # The SSE keep-alive comment-line cadence `await.ex` writes at — well
  # under any named intermediary idle bound and far under the ceiling above.
  mcp_keep_alive_interval_ms: 15_000

# Configure the endpoint
config :humanport, HumanportWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HumanportWeb.ErrorHTML, json: HumanportWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Humanport.PubSub,
  live_view: [signing_salt: "emDSLLzX"],
  # D-01a / T-02.1-15 (02.1-03-PLAN.md Task 1) — set EXPLICITLY, comfortably
  # above the MCP await ceiling above (50_000ms), so a future
  # Bandit/ThousandIsland default change can never silently shorten every
  # wait. FINDING, recorded in full in HumanportWeb.MCP.Timeouts' own
  # moduledoc and in priv/mcp/TRANSPORT.md: `read_timeout` is a
  # `thousand_island_options` key (NOT `http_1_options`, despite this
  # project's own earlier runtime.exs comment naming it that way), and per
  # deps/thousand_island's own Handler moduledoc it bounds the IDLE time
  # BETWEEN handler callbacks waiting for MORE client-sent data — not how
  # long a single Plug invocation may hold a response open once the request
  # has been fully read. It therefore does not, in practice, bound
  # `await`'s SSE write loop at all; set here anyway as a defensive
  # explicit value, and asserted (not merely hoped) by
  # `HumanportWeb.MCP.Timeouts.verify!/0` at boot.
  http: [thousand_island_options: [read_timeout: 90_000]]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  humanport: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  humanport: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# OPS-03 (02-02-PLAN.md Task 3 deviation, Rule 1) — `joken_jwks`'s
# `HttpFetcher` (`deps/joken_jwks/lib/joken_jwks/http_fetcher.ex`) hardcodes
# its OWN fallback default as `Tesla.Adapter.Hackney`, NOT Tesla's actual
# library-wide default (`Tesla.Adapter.Httpc`) — `02-RESEARCH.md` conflated
# the two and concluded no adapter config was needed. `hackney` is not, and
# per AGENTS.md's Phase 2 note must not become, a dependency of this
# project, so every real JWKS fetch attempt (the demand-triggered
# `time_interval` check, and `CloudflareAccessJwksStrategy`'s forced
# refresh) would crash with `UndefinedFunctionError` the first time it ran
# — including in production, where it would mean the JWKS cache never
# populates and the owner locks himself out the moment Access is
# configured. This line makes Tesla's OWN default (`Httpc`, ships with
# Tesla, uses OTP's `:httpc`/`:inets`/`:ssl` — see `mix.exs`
# `extra_applications`) the one `joken_jwks` actually picks up, with zero
# new dependencies.
config :tesla, adapter: Tesla.Adapter.Httpc

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
