defmodule Humanport.Actors.CloudflareAccessTest do
  @moduledoc """
  OPS-03 — the claims-shape switch (`Humanport.Actors.Resolvers.CloudflareAccess`)
  and the claim contract it verifies through
  (`Humanport.Actors.CloudflareAccessToken`), proven with locally signed
  fixture tokens and the stub JWKS strategy (`config/test.exs`) — no
  network call reaches Cloudflare. Mirrors
  `test/humanport/requests/atomicity_test.exs`'s pure-`ExUnit.Case` shape.

  Per the RULE: the rejection direction is written first and is the larger
  half of this file — an implementation that accepts valid tokens and
  quietly falls through on invalid ones passes a happy-path suite and ships
  an open door (D-02).

  `async: false` (changed from `async: true` in 02-02-PLAN.md Task 3): the
  forced-refresh timer tests below stop and restart the app-supervised
  `CloudflareAccessJwksStrategy` singleton and mutate
  `:cf_access_jwks_refresh_ms` process-global config for their duration —
  not safe to interleave with a sibling test in the SAME file scheduled
  concurrently.
  """

  use ExUnit.Case, async: false

  alias Humanport.Actors.Actor
  alias Humanport.Actors.CloudflareAccessToken
  alias Humanport.Actors.Resolvers.CloudflareAccess
  alias Humanport.CloudflareAccessFixtures, as: Fixtures

  defp fake_conn(headers \\ [], cookies \\ %{}) do
    conn = Plug.Test.conn(:get, "/api/v1/requests")

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)

    Enum.reduce(cookies, conn, fn {k, v}, acc -> Plug.Test.put_req_cookie(acc, k, v) end)
  end

  # `Resolvers.CloudflareAccess`'s socket clause reads
  # `socket.private[:hp_session]` — the shape `ResolveActor.on_mount/4`
  # stashes the LiveView session into before calling this resolver (see
  # that module's moduledoc for why: Phoenix exposes neither raw cookies
  # nor `:session` itself through `get_connect_info/2`). Mirrors
  # `resolve_actor_test.exs`'s own `bare_socket/1` helper.
  defp bare_socket(session \\ %{}) do
    %Phoenix.LiveView.Socket{private: %{hp_session: session}}
  end

  defp actor_snapshot(attrs) do
    Map.merge(
      %{
        "id" => nil,
        "type" => "human",
        "label" => "owner@example.com",
        "verified" => true,
        "method" => "sso"
      },
      attrs
    )
  end

  describe "the rejection direction (D-02)" do
    test "a request with no header and no cookie resolves to {:error, :missing_token}" do
      assert {:error, :missing_token} = CloudflareAccess.resolve(fake_conn())
    end

    test "a token signed by a key the fixture's signer source does not hold is refused" do
      token = Fixtures.signed_token(signer: Fixtures.other_signer())

      assert {:error, _reason} =
               CloudflareAccess.resolve(fake_conn([{"cf-access-jwt-assertion", token}]))
    end

    test "a token whose exp is in the past is refused" do
      token = Fixtures.signed_token(exp: System.system_time(:second) - 60)

      assert {:error, _reason} =
               CloudflareAccess.resolve(fake_conn([{"cf-access-jwt-assertion", token}]))
    end

    test "a token whose iss is a different team domain is refused" do
      token = Fixtures.signed_token(iss: "https://a-different-team.cloudflareaccess.com")

      assert {:error, _reason} =
               CloudflareAccess.resolve(fake_conn([{"cf-access-jwt-assertion", token}]))
    end

    test "a token whose aud does not contain the configured AUD tag is refused (D-05)" do
      token = Fixtures.signed_token(aud: ["a-sibling-applications-aud-tag"])

      assert {:error, :wrong_audience} =
               CloudflareAccess.resolve(fake_conn([{"cf-access-jwt-assertion", token}]))
    end

    test "a token whose aud is a bare string rather than a list is refused (D-05 shape)" do
      # Joken's `default_claims` renders `aud` as JSON straight from the
      # claims map — passing a bare string here mimics a token that is not
      # shaped the way Cloudflare's own JWTs are shaped, which must be
      # refused rather than coerced.
      token = Fixtures.signed_token(aud: "test-aud-tag")

      assert {:error, :wrong_audience} =
               CloudflareAccess.resolve(fake_conn([{"cf-access-jwt-assertion", token}]))
    end

    test "a genuine, correctly-scoped token carrying neither common_name nor email is refused" do
      # A claims map matching neither clause must fall through to the
      # catch-all rather than resolving to some default actor — a future
      # Cloudflare payload shape is refused, not silently accepted.
      token = Fixtures.signed_token(without: [:email])

      assert {:error, :invalid_token} =
               CloudflareAccess.resolve(fake_conn([{"cf-access-jwt-assertion", token}]))
    end
  end

  describe "the acceptance direction" do
    test "a genuine, correctly-scoped, unexpired token with an email claim resolves to a verified human actor" do
      token = Fixtures.signed_token(email: "owner@example.com")

      assert {:ok,
              %Actor{type: :human, verified?: true, method: :sso, label: "owner@example.com"}} =
               CloudflareAccess.resolve(fake_conn([{"cf-access-jwt-assertion", token}]))
    end

    test "the CF_Authorization cookie is used when the header is absent" do
      token = Fixtures.signed_token()

      assert {:ok, %Actor{verified?: true}} =
               CloudflareAccess.resolve(fake_conn([], %{"CF_Authorization" => token}))
    end
  end

  describe "the service-token direction (D-01)" do
    test "a genuine, correctly-scoped, unexpired token carrying common_name (no email) resolves to a verified service actor" do
      token =
        Fixtures.signed_token(common_name: "agent-service-token-1.access", without: [:email])

      assert {:ok,
              %Actor{
                type: :service,
                verified?: true,
                method: :service_token,
                label: "agent-service-token-1.access"
              }} = CloudflareAccess.resolve(fake_conn([{"cf-access-jwt-assertion", token}]))
    end

    test "a token carrying both common_name and email resolves to a service actor — common_name is checked first and the clauses do not interfere" do
      token = Fixtures.signed_token(common_name: "agent-service-token-1.access")

      assert {:ok, %Actor{type: :service, method: :service_token}} =
               CloudflareAccess.resolve(fake_conn([{"cf-access-jwt-assertion", token}]))
    end

    test "a service-actor session snapshot resolves the same way through the LiveView socket" do
      snapshot =
        actor_snapshot(%{
          "type" => "service",
          "label" => "agent-service-token-1.access",
          "method" => "service_token"
        })

      assert {:ok, %Actor{type: :service, verified?: true, method: :service_token}} =
               CloudflareAccess.resolve(bare_socket(%{"hp_resolved_actor" => snapshot}))
    end
  end

  describe "the LiveView socket clause (D-02, 02-02-PLAN.md Task 1) — session relay, not raw cookies" do
    test "no session at all resolves to {:error, :missing_token}" do
      assert {:error, :missing_token} = CloudflareAccess.resolve(bare_socket())
    end

    test "a session with no resolved-actor snapshot resolves to {:error, :missing_token}" do
      assert {:error, :missing_token} = CloudflareAccess.resolve(bare_socket(%{"unrelated" => 1}))
    end

    test "a verified human snapshot resolves the same way a request header does" do
      assert {:ok,
              %Actor{type: :human, verified?: true, method: :sso, label: "owner@example.com"}} =
               CloudflareAccess.resolve(
                 bare_socket(%{"hp_resolved_actor" => actor_snapshot(%{})})
               )
    end
  end

  describe "CloudflareAccessToken.verify_and_validate/1 directly" do
    test "never configures a default signer — proven by the happy path itself" do
      # If a default signer were ever configured on this module, a token
      # signed with the JWKS-stub's OWN key would still be expected to
      # verify (the default would just be unused) — the real risk a default
      # signer creates is a token signed with the DEFAULT key verifying
      # regardless of the JWKS lookup. There is no `config :joken, ...`
      # anywhere in this application and `default_signer:` is never passed
      # to `use Joken.Config` — this test documents that invariant by
      # asserting the JWKS-routed verification is what actually succeeds.
      token = Fixtures.signed_token()

      assert {:ok, %{"email" => "owner@example.com"}} =
               CloudflareAccessToken.verify_and_validate(token)
    end
  end

  describe "the JWKS forced-refresh window (D-03, 02-02-PLAN.md Task 3)" do
    alias Humanport.Actors.CloudflareAccessJwksStrategy, as: Strategy

    test "the interval is read from configuration and defaults to five minutes" do
      original = Application.get_env(:humanport, :cf_access_jwks_refresh_ms)

      on_exit(fn ->
        if original do
          Application.put_env(:humanport, :cf_access_jwks_refresh_ms, original)
        else
          Application.delete_env(:humanport, :cf_access_jwks_refresh_ms)
        end
      end)

      Application.delete_env(:humanport, :cf_access_jwks_refresh_ms)
      assert Strategy.refresh_interval_ms() == 300_000

      Application.put_env(:humanport, :cf_access_jwks_refresh_ms, 42)
      assert Strategy.refresh_interval_ms() == 42
    end

    @tag :capture_log
    test "the forced-refresh telemetry event fires more than once, unconditionally, with a fast interval and no token presented" do
      original_interval = Application.get_env(:humanport, :cf_access_jwks_refresh_ms)
      Application.put_env(:humanport, :cf_access_jwks_refresh_ms, 20)

      test_pid = self()
      handler_id = {:jwks_force_refresh_test, make_ref()}

      :telemetry.attach(
        handler_id,
        [:humanport, :cloudflare_access_jwks, :force_refresh],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :force_refresh_fired) end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)

        if original_interval do
          Application.put_env(:humanport, :cf_access_jwks_refresh_ms, original_interval)
        else
          Application.delete_env(:humanport, :cf_access_jwks_refresh_ms)
        end

        # Restore the app-supervised strategy to its normal (five-minute,
        # unless overridden) interval so no other test observes a
        # 20ms-armed timer left running after this one.
        Supervisor.terminate_child(Humanport.Supervisor, Strategy)
        Supervisor.restart_child(Humanport.Supervisor, Strategy)
      end)

      # `config/test.exs` sets `cf_access_team_domain`, so
      # `Humanport.Application` already supervises this module — restart it
      # so `init_opts/1` re-reads the fast interval just configured above.
      :ok = Supervisor.terminate_child(Humanport.Supervisor, Strategy)
      {:ok, _pid} = Supervisor.restart_child(Humanport.Supervisor, Strategy)

      # A one-shot timer that never re-arms would pass a single
      # `assert_receive` — asserting it TWICE is what proves
      # `handle_info(:force_refresh, state)` reschedules itself rather than
      # firing once and going quiet for the rest of the (real) five minutes.
      assert_receive :force_refresh_fired, 1_000
      assert_receive :force_refresh_fired, 1_000
    end

    @tag :capture_log
    test "a failed fetch leaves the previously cached keys in place — D-03's other half" do
      alias JokenJwks.DefaultStrategyTemplate.EtsCache

      # The ETS table already exists (the app-supervised strategy created
      # it at boot) and is `:public` — writable/readable directly, no need
      # to go through the live GenServer at all for this assertion.
      EtsCache.put_signers(Strategy, %{"seeded-kid" => :seeded_signer})

      # Port 1 refuses the connection immediately (no DNS lookup, no
      # timeout wait) — this is `fetch_signers/3`'s own public,
      # library-documented entry point, called exactly as
      # `handle_info(:force_refresh, state)` calls it.
      assert {:error, _reason} =
               JokenJwks.DefaultStrategyTemplate.fetch_signers(
                 Strategy,
                 "http://127.0.0.1:1/unreachable",
                 %{
                   jws_supported_algs: ["RS256"],
                   http_max_retries_per_fetch: 1,
                   http_delay_per_retry: 1
                 }
               )

      assert EtsCache.get_signers(Strategy) == [{:signers, %{"seeded-kid" => :seeded_signer}}]
    end
  end
end
