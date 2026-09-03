defmodule Humanport.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.

  `migrate/0` and `rollback/2` below are unchanged from the `mix
  phx.gen.release` template. `ready?/0` and `healthcheck!/0` (OPS-06,
  D-06/D-07, `02-RESEARCH.md` §Pattern 3) are this phase's addition, and they
  deliberately do NOT copy `migrate/0`'s own pattern
  (`Ecto.Migrator.with_repo/3`) — that is a considered deviation, not an
  oversight, explained on `ready?/0` itself.
  """
  @app :humanport

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  OPS-06, D-06. `/ready` reports ready only once the database answers AND
  every known migration is applied. Migrations run at container start on
  this deployment (`ops/server/README.md` D2-04), so their completion — not
  a bare connection — is the readiness signal that means something; anything
  earlier is a promise the application cannot keep.

  **Deliberately does NOT use `Ecto.Migrator.with_repo/3`, unlike `migrate/0`
  above — read that as intentional, not a miss.** `with_repo/3` starts and
  later stops a SECOND repository process on every call. That is correct
  exactly once, at container boot, when no repo is running yet (`migrate/0`'s
  own case). It is wrong here: this function is called by an HTTP request
  (`/ready`) and, via `healthcheck!/0`, by the Compose healthcheck every few
  seconds against a release whose `Humanport.Repo` is already up — starting
  and stopping a connection pool on that cadence would be its own kind of
  load. Ask the already-running repo instead.

  **`migration_lock: false` is passed explicitly to
  `Ecto.Migrator.migrations/3` below and is load-bearing, not a tuning
  knob.** The migration-status call takes a PostgreSQL advisory lock by
  default (`Ecto.Migrator.migrated_versions/2`,
  `deps/ecto_sql/lib/ecto/migrator.ex`, read 2026-09-03 for this task). This
  probe runs every few seconds during precisely the window
  `rel/overlays/bin/migrate` is trying to take that SAME lock to run a real
  migration — a redeploy. A healthcheck that contends with the migration it
  exists to watch is worse than no healthcheck at all, which is why this is
  the one option in this function that changes behaviour under load rather
  than under failure.
  """
  @spec ready? :: :ok | {:error, term()}
  def ready? do
    with :ok <- db_reachable?(),
         :ok <- migrations_up?(),
         :ok <- access_verifier_armed?() do
      :ok
    end
  end

  @doc false
  # D-06, extended on 2026-09-03 by measuring the thing rather than trusting
  # it. On an instance running the Cloudflare Access resolver, the key set is
  # fetched ASYNCHRONOUSLY at startup and took ~60 seconds on the reference
  # host. `/ready` answered 200 throughout that window while every
  # service-token request was refused `:no_signers_fetched` — so readiness
  # was making a promise the application could not yet keep, which is the
  # exact wording the moduledoc above uses for why migrations are part of
  # this check. `ops/server/redeploy-ohne-verlust.sh` waits for `/ready` and
  # then immediately goes in through the front door; it could not pass, and
  # the failure looked like a broken agent path rather than a young one.
  #
  # Scoped narrowly on purpose: an instance on the environment resolver
  # (self-hosting, OPS-01) has no key set to wait for and is unaffected —
  # this must not turn a plain `docker compose up` into a deployment that
  # never reports ready.
  def access_verifier_armed? do
    if Application.get_env(:humanport, :actor_resolver) ==
         Humanport.Actors.Resolvers.CloudflareAccess do
      case JokenJwks.DefaultStrategyTemplate.EtsCache.get_signers(
             Humanport.Actors.CloudflareAccessJwksStrategy
           ) do
        [signers: signers] when is_map(signers) and map_size(signers) > 0 -> :ok
        _ -> {:error, :access_key_set_not_fetched}
      end
    else
      :ok
    end
  rescue
    # `get_signers/1` is `:ets.lookup/2`, which RAISES ArgumentError when the
    # table does not exist rather than returning an empty result — and the
    # table is created by the JWKS strategy's own start-up. So the one state
    # this check exists to detect, "the key set is not there", has a variant
    # that would crash `ready?/0` instead of answering it: an Access-configured
    # instance whose strategy never started at all would turn a 503 with a
    # reason into a 500 with a stack trace, on the endpoint an operator reads
    # to find out what is wrong. Not-armed is not-armed either way.
    ArgumentError -> {:error, :access_key_set_not_fetched}
  end

  @doc """
  D-06's "are they all applied" judgment, split out as a pure function over
  the `{status, version, name}` tuple list `Ecto.Migrator.migrations/3`
  returns — public so the pending branch can be exercised as pure logic
  (`test/humanport/release_test.exs`) rather than by genuinely leaving a
  migration unapplied against the shared test database, which would break
  every `Humanport.DataCase` run that follows it (`02-VALIDATION.md`'s own
  Wave 0 note).
  """
  @spec all_migrated?([{:up | :down, integer(), String.t()}]) :: boolean()
  def all_migrated?(migration_statuses) do
    Enum.all?(migration_statuses, fn {status, _version, _name} -> status == :up end)
  end

  @doc """
  D-07's entry point for the Compose healthcheck, called through the
  release's own `rpc` command
  (`/app/bin/humanport rpc "Humanport.Release.healthcheck!()"`, wired in
  `compose.yaml`) rather than an HTTP request — the runner image's final
  stage installs exactly `libstdc++6 openssl libncurses6 locales
  ca-certificates` (`Dockerfile`, read 2026-09-03 for this task); neither
  `curl` nor `wget` is in it, so the most common Docker healthcheck idiom
  (fetch a URL) cannot run inside this container at all.

  `ready?/0` is D-06 exactly — database plus migrations — and that is
  everything `/ready` itself reports, because anything reaching `/ready`
  over HTTP has already proved the HTTP listener works by arriving over it.
  `rpc` does not arrive over HTTP: it reaches in through the release's own
  Erlang distribution port, which proves nothing about whether Bandit is
  still accepting connections on ITS configured port. Closing that gap
  without adding anything to the runner image: open and immediately close a
  bare TCP connection to the endpoint's own configured port, addressed BY
  NAME (`~c"localhost"`) rather than a hard-coded address tuple — production
  binds the IPv6 any-address (`config/runtime.exs`,
  `ip: {0, 0, 0, 0, 0, 0, 0, 0}`) and `mix test` binds IPv4 loopback
  (`config/test.exs`, `ip: {127, 0, 0, 1}`), and an address tuple that is
  right for one is wrong for the other, while `"localhost"` resolves
  correctly under both. This STILL does not prove the router itself answers
  200 for any given path — only that something is listening on the port.
  The outside-in script in 02-04 is what proves that.

  **Raises rather than halting — this must never call `System.halt/1`.** The
  release's `rpc` command does not evaluate its expression locally: it
  performs a genuine Erlang RPC call against the ALREADY-RUNNING production
  node, in a process spawned there
  (`elixir.hexdocs.pm/1.20.1/releases.md`, read 2026-09-03 for this task —
  `bin/RELEASE rpc EXPR` is documented as connecting to the running system,
  distinct from `bin/RELEASE eval EXPR`, which `migrate/0` above is invoked
  through and which boots its own short-lived instance instead).
  `System.halt/1` inside that expression would stop the actual server this
  healthcheck was merely trying to ask about — the symptom in production is
  the whole container disappearing when the healthcheck wanted to report a
  no, not merely a `docker compose ps` state flip. A raised exception, by
  contrast, only crashes the transient process the RPC call spawned for this
  one call; it does not touch the target node's own supervision tree, and
  the CLI's own documented exit-status rule
  (`elixir.hexdocs.pm/1.20.1/index.html`, "CLI exits") turns that non-normal
  exit into an OS exit status of 1 — precisely the nonzero signal
  `compose.yaml`'s `healthcheck:` needs.
  """
  @spec healthcheck! :: :ok
  def healthcheck! do
    with :ok <- ready?(),
         :ok <- listener_reachable?() do
      :ok
    else
      {:error, reason} -> raise "not ready: #{inspect(reason)}"
    end
  end

  defp db_reachable? do
    Ecto.Adapters.SQL.query(Humanport.Repo, "SELECT 1", [], timeout: 2_000)
    :ok
  rescue
    e -> {:error, {:db_unreachable, Exception.message(e)}}
  end

  # Rule 1 fix (found during this task's own human-check, docker compose
  # stopped underneath a live probe): `db_reachable?/0`'s cheap `SELECT 1`
  # can succeed on an already-checked-out pool connection a moment before
  # the database genuinely goes away, leaving `Ecto.Migrator.migrations/3`
  # below to hit the actual failure — observed live as an unhandled
  # `DBConnection.ConnectionError` propagating out of this function. Without
  # this `rescue`, that reaches `ready?/0` uncaught: `/ready` would crash
  # with a 500 instead of composing the 503 D-06 promises, and
  # `healthcheck!/0`'s "raise a clean 'not ready' message" contract would be
  # broken by an exception it never got to compose. `:migration_check_failed`
  # is a distinct reason from `db_reachable?/0`'s own `:db_unreachable` on
  # purpose — same underlying cause in practice (the database disappearing
  # mid-probe), but naming where the check actually failed.
  defp migrations_up? do
    path = Ecto.Migrator.migrations_path(Humanport.Repo)

    Humanport.Repo
    |> Ecto.Migrator.migrations([path], migration_lock: false)
    |> all_migrated?()
    |> case do
      true -> :ok
      false -> {:error, :migrations_pending}
    end
  rescue
    e -> {:error, {:migration_check_failed, Exception.message(e)}}
  end

  defp listener_reachable? do
    case :gen_tcp.connect(~c"localhost", listener_port(), [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, {:listener_unreachable, reason}}
    end
  end

  defp listener_port do
    :humanport
    |> Application.get_env(HumanportWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4000)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
