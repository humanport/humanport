defmodule Humanport.Requests.DurabilityTest do
  @moduledoc """
  CORE-01 — durability follows from three rules that must be *checked*, not
  assumed: the only writes are Ash actions against PostgreSQL, no BEAM
  process holds request state, and every wake re-reads the database. This
  test checks the first directly: a pending request is unchanged, field for
  field, across a repository connection drop and re-establish.

  Runs OUTSIDE the Ecto sandbox (`Humanport.UnsandboxedCase`) — a sandboxed
  test wraps everything in one transaction, and forcing the connection to
  drop mid-test would roll back the very row this test creates. This is the
  in-VM counterpart to the `docker compose restart app` proof scripted in
  plan 01-06.

  The connection is dropped with PostgreSQL's own `pg_terminate_backend/1`,
  called from a second, throwaway `Postgrex` connection opened directly
  (bypassing Ecto and the sandbox entirely) against the exact backend PID our
  own connection reports via `pg_backend_pid()`. This is deliberately
  surgical: two mechanisms that touch the *pool itself* were tried and
  rejected because they can corrupt other concurrently-running tests'
  isolation on a shared suite —
  `Ecto.Adapters.SQL.disconnect_all/2` isn't reachable at all in
  `MIX_ENV=test` (`DBConnection.Ownership.Manager` doesn't implement the
  `:disconnect_all` call it sends, sandbox mode notwithstanding), and
  restarting the `Humanport.Repo` supervision child works in isolation but is
  flaky under the full suite — it also tears down and rebuilds the pool every
  *other* test's sandbox ownership depends on. Terminating one backend PID at
  the PostgreSQL level touches only the single physical connection our own
  query used, and DBConnection reconnects it transparently on next use.
  """

  use Humanport.UnsandboxedCase

  import Humanport.Fixtures

  alias Humanport.Requests

  test "a pending request is unchanged after its PostgreSQL connection is dropped and re-established" do
    request =
      request_fixture(%{
        title: "Survive a restart",
        context: %{"pr" => 42},
        risk: :medium,
        reversible: "true",
        source: "claude-code/gsd",
        external_correlation: "run-restart"
      })

    on_exit(fn ->
      Repo.query!("DELETE FROM human_requests WHERE id = $1", [Ecto.UUID.dump!(request.id)])
    end)

    terminate_own_backend_connection!()

    # The termination is asynchronous at the socket level: the very next
    # checkout can still land on the connection mid-death before the pool
    # notices and replaces it. Retry briefly rather than racing it.
    {:ok, reloaded} = get_request_with_retry(request.id)

    assert reloaded.id == request.id
    assert reloaded.state == request.state
    assert reloaded.type == request.type
    assert reloaded.title == request.title
    assert reloaded.context == request.context
    assert reloaded.risk == request.risk
    assert reloaded.reversible == request.reversible
    assert reloaded.source == request.source
    assert reloaded.external_correlation == request.external_correlation
    assert DateTime.compare(reloaded.inserted_at, request.inserted_at) == :eq
  end

  defp terminate_own_backend_connection! do
    config = Humanport.Repo.config()

    {:ok, admin} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port],
        username: config[:username],
        password: config[:password],
        database: config[:database]
      )

    %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    Postgrex.query!(admin, "SELECT pg_terminate_backend($1)", [backend_pid])
    GenServer.stop(admin)
  end

  defp get_request_with_retry(id, attempts_left \\ 10)

  defp get_request_with_retry(_id, 0), do: {:error, :exhausted_retries}

  defp get_request_with_retry(id, attempts_left) do
    case Requests.get_request(id) do
      {:ok, request} ->
        {:ok, request}

      {:error, _still_reconnecting} ->
        Process.sleep(50)
        get_request_with_retry(id, attempts_left - 1)
    end
  end
end
