defmodule Humanport.ReleaseTest do
  @moduledoc """
  OPS-06 (D-06/D-07, 02-03-PLAN.md Task 1) — `Humanport.Release.ready?/0`'s
  two composed checks and `all_migrated?/1`, the pure "are they all applied"
  predicate the pending-migration branch is tested through. The pending
  branch is deliberately NOT exercised by genuinely leaving a migration
  unapplied against the shared test database — `02-VALIDATION.md`'s own Wave
  0 note names that as the thing that breaks every `Humanport.DataCase` run
  that follows it.

  `async: false` for the whole module: the `healthcheck!/0` tests below
  temporarily mutate the GLOBAL `Application.get_env(:humanport,
  HumanportWeb.Endpoint)` to point the listener-reachability check at a
  throwaway socket, which would race any concurrently-running async test
  that reads the same config.
  """

  use Humanport.DataCase, async: false

  describe "all_migrated?/1 — the pure predicate the pending branch is tested through" do
    test "true when every entry is :up" do
      assert Humanport.Release.all_migrated?([
               {:up, 20_260_101_000_000, "one"},
               {:up, 20_260_102_000_000, "two"}
             ])
    end

    test "false for a single unapplied entry" do
      refute Humanport.Release.all_migrated?([{:down, 20_260_101_000_000, "one"}])
    end

    test "false when any entry among several is :down" do
      refute Humanport.Release.all_migrated?([
               {:up, 20_260_101_000_000, "one"},
               {:down, 20_260_102_000_000, "two"},
               {:up, 20_260_103_000_000, "three"}
             ])
    end

    test "true for an empty list — no known migration, nothing pending" do
      assert Humanport.Release.all_migrated?([])
    end
  end

  describe "ready?/0 — the happy path, against the real sandboxed database" do
    test "returns :ok when the database answers and every migration is applied" do
      assert Humanport.Release.ready?() == :ok
    end
  end

  describe "healthcheck!/0 — raises rather than halting; also proves the listener accepts a connection" do
    test "returns :ok when the database, migrations, and a real bound listener are all reachable" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)

      with_endpoint_port(port, fn ->
        on_exit(fn -> :gen_tcp.close(listener) end)
        assert Humanport.Release.healthcheck!() == :ok
      end)
    end

    test "raises with a listener-unreachable reason, and the calling process survives" do
      # Bind a throwaway socket purely to reserve a genuinely free port, then
      # close it immediately — nothing is listening there for the duration
      # of the assertion below.
      {:ok, probe} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, free_port} = :inet.port(probe)
      :gen_tcp.close(probe)

      with_endpoint_port(free_port, fn ->
        assert_raise RuntimeError, ~r/listener_unreachable/, fn ->
          Humanport.Release.healthcheck!()
        end
      end)

      # The RuntimeError above only crashed the assertion's own anonymous
      # function — proving the point `healthcheck!/0`'s own moduledoc makes
      # about raising vs. `System.halt/1`: this test process, and by
      # extension the "node" it stands in for, is still here to say so.
      assert Process.alive?(self())
    end
  end

  # Temporarily overrides the configured Endpoint port for the duration of
  # `fun`, then restores the original value — `listener_port/0` (private in
  # `Humanport.Release`) reads this same key, so this is the seam
  # `healthcheck!/0`'s listener check can be exercised through without a
  # live Bandit listener in the test environment (`config/test.exs` sets
  # `server: false`).
  defp with_endpoint_port(port, fun) do
    original = Application.get_env(:humanport, HumanportWeb.Endpoint)
    http = Keyword.put(original[:http] || [], :port, port)
    overridden = Keyword.put(original, :http, http)

    Application.put_env(:humanport, HumanportWeb.Endpoint, overridden)

    try do
      fun.()
    after
      Application.put_env(:humanport, HumanportWeb.Endpoint, original)
    end
  end
end
