defmodule Humanport.Actors.CloudflareAccessJwksStrategy do
  @moduledoc """
  D-03 — the JWKS cache backing `Humanport.Actors.CloudflareAccessToken`'s
  verification.

  `JokenJwks.DefaultStrategyTemplate`'s own `time_interval` only throttles a
  DEMAND-triggered re-fetch: its polling loop calls `fetch_signers/3` only
  after an unrecognised `kid` arrives on a real token (verified by reading
  `deps/joken_jwks/lib/joken_jwks/default_strategy_template.ex` directly —
  `check_fetch/3` re-fetches only when its ETS counter is nonzero, and the
  counter is only ever incremented by `match_signer_for_kid/3` seeing a
  `kid` it doesn't recognise). A key Cloudflare simply removes — a
  revocation with no replacement key introduced — produces no unknown
  `kid`, so that loop alone never notices, and the cached (now revoked) key
  stays trusted indefinitely. `@force_refresh_ms` is an additional,
  UNCONDITIONAL timer calling the template's own public, documented
  `fetch_signers/3` regardless of demand — this is what actually bounds
  D-03's revocation window, not `time_interval` alone.

  Five minutes, chosen deliberately rather than defaulted: Cloudflare's own
  default key-rotation cadence is six weeks with a 7-day overlap for the
  previous key, so this interval only has to be short relative to a
  genuine, out-of-band revocation, not relative to routine rotation. The
  accepted cost, stated plainly: a compromised/revoked Access key can still
  authenticate for up to five minutes after revocation.

  `first_fetch_sync: false` is deliberate, not an oversight — `true` would
  block application start on a network call to Cloudflare. The alternative
  it buys (the Endpoint accepting requests before the first JWKS fetch
  completes, so the earliest requests during boot get a correct-but-early
  401 rather than a delayed boot) is D-02's fail-closed intent working as
  designed, not a gap.

  Supervised only when `HUMANPORT_CF_ACCESS_TEAM_DOMAIN` is configured
  (`Humanport.Application`); this module raises if it is ever started
  without a team domain configured, so a mis-wired supervision entry fails
  loudly here rather than fetching from a JWKS URL built out of `nil`.
  """

  use JokenJwks.DefaultStrategyTemplate

  # D-03 — the accepted revocation-exposure window. See the moduledoc.
  @force_refresh_ms 5 * 60 * 1_000

  # Placed immediately after `use`, before any other function definition in
  # this module, so this clause stays grouped with the template's own
  # macro-injected `handle_info(:check_fetch, state)` clause (the
  # `__using__` block ends with that clause) — Elixir's "clauses for the
  # same def should be grouped together" is a hard error under
  # `mix compile --warnings-as-errors` (the `precommit` alias) if any other
  # function definition is placed between two clauses of `handle_info/2`.
  # `start_link/1` and `init/1` are NOT `defoverridable` in the template
  # (only `init_opts/1` is, verified by reading the template's source
  # directly — see the moduledoc) — so the forced-refresh timer is armed
  # from `init_opts/1`, the one documented, overridable seam, rather than
  # from either of those.
  @doc false
  def handle_info(:force_refresh, state) do
    _ = JokenJwks.DefaultStrategyTemplate.fetch_signers(__MODULE__, state[:jwks_url], state)
    Process.send_after(__MODULE__, :force_refresh, @force_refresh_ms)
    {:noreply, state}
  end

  @doc false
  def init_opts(opts) do
    team_domain =
      Application.get_env(:humanport, :cf_access_team_domain) ||
        raise "HUMANPORT_CF_ACCESS_TEAM_DOMAIN is not configured — " <>
                "#{inspect(__MODULE__)} must not be supervised without it " <>
                "(see Humanport.Application)."

    # `init_opts/1` runs in the CALLER's process (the Supervisor), before
    # `GenServer.start_link(__MODULE__, opts, name: __MODULE__)` registers
    # this module's name — so `self()` here is not the future GenServer.
    # `Process.send_after/3` resolves an atom destination AT DELIVERY TIME,
    # not at scheduling time (confirmed against elixir.hexdocs.pm/1.20.1's
    # own docs: "Timers are not automatically cancelled when dest is an
    # atom [because] resolution is done on delivery"), so scheduling
    # against `__MODULE__` here — before the process holding that name
    # exists — is safe: by the time this timer fires, five minutes later,
    # the GenServer has long since registered.
    Process.send_after(__MODULE__, :force_refresh, @force_refresh_ms)

    Keyword.merge(opts,
      jwks_url: jwks_url(team_domain),
      first_fetch_sync: false,
      time_interval: 60_000,
      http_max_retries_per_fetch: 3,
      http_delay_per_retry: 500
    )
  end

  defp jwks_url(team_domain),
    do: Humanport.Actors.CloudflareAccessToken.issuer(team_domain) <> "/cdn-cgi/access/certs"
end
