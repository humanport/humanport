defmodule HumanportWeb.HealthControllerTest do
  @moduledoc """
  OPS-06 (D-06/D-07, 02-03-PLAN.md Task 1) — `/health` and `/ready`, reached
  through the `:health` router pipeline that carries no
  `HumanportWeb.Plugs.ResolveActor`. Neither test below assigns an actor to
  `conn` first, matching the fact these endpoints must keep answering even
  when the actor resolver itself is what is broken.

  `/health`'s "makes no database call" claim is proved with a `:telemetry`
  handler on `Humanport.Repo`'s own query event
  (`[:humanport, :repo, :query]`, `lib/humanport_web/telemetry.ex`'s
  `humanport.repo.query.*` metrics confirm this prefix) rather than by
  assertion alone — and the same handler is proved capable of catching a
  query at all by asserting it FIRES for `/ready`, which does read the
  database.
  """

  use HumanportWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns 200 with a small JSON body and makes no database call", %{conn: conn} do
      test_pid = self()
      handler_id = "health-no-db-call-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:humanport, :repo, :query],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :db_query_fired) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      conn = get(conn, ~p"/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
      refute_received :db_query_fired
    end
  end

  describe "GET /ready" do
    test "returns 200 when the database answers and every migration is applied", %{conn: conn} do
      conn = get(conn, ~p"/ready")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end

    test "does read the database — proving the /health handler above would have caught it", %{
      conn: conn
    } do
      test_pid = self()
      handler_id = "ready-fires-db-call-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:humanport, :repo, :query],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :db_query_fired) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      get(conn, ~p"/ready")

      assert_received :db_query_fired
    end
  end
end
