defmodule Humanport.MixProject do
  use Mix.Project

  def project do
    [
      app: :humanport,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Humanport.Application, []},
      # :inets/:ssl — OPS-03 (02-02-PLAN.md Task 3 deviation): required by
      # Tesla.Adapter.Httpc (config/config.exs's `config :tesla, adapter:`),
      # which `joken_jwks`'s JWKS fetch uses over HTTPS. Neither starts
      # automatically as a transitive dependency's own extra_application.
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # DEV-01: link (not inline) the Ash family's usage rules into AGENTS.md, below
  # the hand-written HumanPort section. `usage_rules` 1.2.7 dropped the CLI
  # positional-args/--link-to-folder form the research assumed (`mix help
  # usage_rules.sync` confirmed it now raises on task-specific args); this
  # project-config form is the current API. `ash_state_machine` ships no
  # usage-rules.md and `petal_components` ships `rules.md` instead of
  # `usage-rules.md`, so neither is picked up here — the AGENTS.md hand-written
  # section and a manual reference to `deps/petal_components/rules.md` cover them.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [
        {:ash, link: :markdown},
        {:ash_postgres, link: :markdown},
        {:ash_phoenix, link: :markdown}
      ]
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ash_state_machine, "~> 0.2"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:petal_components, "~> 4.16"},
      {:usage_rules, "~> 1.2", only: [:dev], runtime: false},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # OPS-03 — Cloudflare Access JWT verification (02-RESEARCH.md § Standard
      # Stack). Pulls `tesla` in transitively as `joken_jwks`'s hard HTTP
      # client dependency — see AGENTS.md "Phase 2 additions" for why that is
      # an accepted exception to the project's `:req`-only rule rather than a
      # violation of it.
      {:joken, "~> 2.7"},
      {:joken_jwks, "~> 1.8"},
      # D-08a (02.1-CONTEXT.md) — the MCP surface is hand-written, so "follows
      # the spec" has to be a passing test rather than a claim. This validates
      # contract-test payloads against the vendored official schema
      # (priv/mcp/schema-2026-07-28.json). Test-only: never enters a `mix
      # release` artifact. Approved by the owner from its Hex registry page on
      # 2026-09-03 (02.1-01-PLAN.md Task 1) — the named fallback (`xema` +
      # `json_xema`) was NOT approved and must not be substituted silently.
      {:ex_json_schema, "~> 0.11", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind humanport", "esbuild humanport"],
      "assets.deploy": [
        "tailwind humanport --minify",
        "esbuild humanport --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
