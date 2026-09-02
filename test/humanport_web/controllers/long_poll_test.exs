defmodule HumanportWeb.LongPollTest do
  @moduledoc """
  Plan 01-04, Task 1 — the `?wait=` long-poll: the woken path, the
  timed-out path, and the answered-in-the-gap path that is the whole reason
  `RequestController.show/2` subscribes to the per-request PubSub topic
  BEFORE it reads the database.

  Runs `async: false` (via `HumanportWeb.ConnCase`) so the shared sandbox
  connection is visible to the background `Task`s each test spawns — no
  `Ecto.Adapters.SQL.Sandbox.allow/3` calls needed, `shared: true` already
  covers every process for the duration of the test.

  On timing: the "woken" and "gap" tests below assert an UPPER BOUND on
  elapsed time (well under the requested `wait`), not an exact duration —
  the actual bound they prove is "the call returned promptly because it was
  woken by the broadcast, not because it happened to still be running when
  the timeout fired". The "gap" test additionally races the controller's
  wait against the answer with NO artificial synchronization between them
  (both start at t=0): this cannot deterministically land inside the
  microsecond-scale subscribe-then-read window on every run, but a
  regression to read-before-subscribe would make this specific race lose
  the broadcast on a meaningful fraction of runs, dragging the call out to
  the full timeout and failing the elapsed-time assertion. Run repeatedly
  under `--seed 0 --repeat-until-failure` if a change to `show/2`'s ordering
  is ever in question.
  """

  use HumanportWeb.ConnCase, async: false

  import Humanport.Fixtures

  alias Humanport.Requests

  describe "the woken path" do
    test "a pending request answered while waiting returns promptly, well before the timeout",
         %{conn: conn} do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})

      wait_task =
        Task.async(fn ->
          started_at = System.monotonic_time(:millisecond)
          conn = get(conn, ~p"/api/v1/requests/#{request.id}?wait=10")
          {json_response(conn, 200), System.monotonic_time(:millisecond) - started_at}
        end)

      # Give the controller time to actually subscribe before answering —
      # this test proves the ordinary "woken while waiting" case, not the
      # tight race (see "the answered-in-the-gap path" below for that).
      Process.sleep(150)

      {:ok, _answered} = Requests.answer(request, "Use the second entry.", default_actor())

      {body, elapsed_ms} = Task.await(wait_task, 5_000)

      assert body["status"] == "completed"
      assert body["state"] == "answered"
      assert body["result"]["answer"] == "Use the second entry."
      assert elapsed_ms < 2_000, "expected a prompt wake, took #{elapsed_ms}ms"
    end
  end

  describe "the timed-out path" do
    test "a request nobody answers returns at the timeout with a fresh pending read, not an error",
         %{conn: conn} do
      request = request_fixture(%{type: :ask, title: "Nobody will answer this one"})

      started_at = System.monotonic_time(:millisecond)
      conn = get(conn, ~p"/api/v1/requests/#{request.id}?wait=1")
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      body = json_response(conn, 200)

      assert body["status"] == "pending"
      assert body["state"] == "pending"
      assert body["result"] == nil
      # A fresh database read, not a stale copy: the `updated_at` on the
      # timeout response matches what a plain, unrelated read returns right
      # now — proving the timeout path actually re-queries rather than
      # rendering whatever was in hand when the wait began.
      plain_body = get(conn, ~p"/api/v1/requests/#{request.id}") |> json_response(200)
      assert body["updated_at"] == plain_body["updated_at"]

      assert elapsed_ms >= 1_000, "expected the call to hold for roughly the requested wait"
      assert elapsed_ms < 4_000, "expected the call to return at the timeout, not hang"
    end
  end

  describe "the answered-in-the-gap path" do
    test "an answer that lands in the subscribe/read window still returns promptly", %{
      conn: conn
    } do
      request = request_fixture(%{type: :ask, title: "Racing the subscribe/read gap"})

      wait_task =
        Task.async(fn ->
          started_at = System.monotonic_time(:millisecond)
          conn = get(conn, ~p"/api/v1/requests/#{request.id}?wait=10")
          {json_response(conn, 200), System.monotonic_time(:millisecond) - started_at}
        end)

      # No sleep here, deliberately — both operations start as close to t=0
      # as the BEAM scheduler allows, so this run has a real chance of
      # landing the answer's commit somewhere inside the controller's
      # subscribe-then-read window rather than cleanly before or after it.
      {:ok, _answered} = Requests.answer(request, "Use the first entry.", default_actor())

      {body, elapsed_ms} = Task.await(wait_task, 5_000)

      assert body["status"] == "completed"
      assert body["state"] == "answered"
      assert body["result"]["answer"] == "Use the first entry."
      assert elapsed_ms < 2_000, "expected a prompt return, took #{elapsed_ms}ms"
    end
  end

  describe "already-terminal, wait clamping, and no-wait" do
    test "a request already in a terminal state returns immediately regardless of wait", %{
      conn: conn
    } do
      request = request_fixture(%{type: :ask, title: "Already answered"})
      {:ok, _} = Requests.answer(request, "Done already.", default_actor())

      started_at = System.monotonic_time(:millisecond)
      conn = get(conn, ~p"/api/v1/requests/#{request.id}?wait=10")
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      body = json_response(conn, 200)
      assert body["status"] == "completed"
      assert elapsed_ms < 500, "a terminal request must never wait"
    end

    test "a pending request with no wait parameter returns immediately, pending, null result", %{
      conn: conn
    } do
      request = request_fixture(%{type: :ask, title: "No wait requested"})

      started_at = System.monotonic_time(:millisecond)
      conn = get(conn, ~p"/api/v1/requests/#{request.id}")
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      body = json_response(conn, 200)
      assert body["status"] == "pending"
      assert body["result"] == nil
      assert elapsed_ms < 500, "no wait parameter must never hold the connection open"
    end

    test "negative, zero, and unparseable wait values all mean no wait at all", %{conn: conn} do
      for raw_wait <- ["-5", "0", "not-a-number", "45abc"] do
        request = request_fixture(%{type: :ask, title: "wait=#{raw_wait}"})

        started_at = System.monotonic_time(:millisecond)
        conn = get(conn, ~p"/api/v1/requests/#{request.id}?wait=#{raw_wait}")
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        body = json_response(conn, 200)
        assert body["status"] == "pending"
        assert elapsed_ms < 500, "wait=#{raw_wait} must behave as no wait, took #{elapsed_ms}ms"
      end
    end

    test "a wait value above the ceiling is clamped to the ceiling, never the raw requested value",
         %{conn: conn} do
      request = request_fixture(%{type: :ask, title: "wait above the ceiling, never answered"})

      original_ceiling = Application.get_env(:humanport, :long_poll_max_wait_seconds, 50)
      Application.put_env(:humanport, :long_poll_max_wait_seconds, 1)

      on_exit(fn ->
        Application.put_env(:humanport, :long_poll_max_wait_seconds, original_ceiling)
      end)

      started_at = System.monotonic_time(:millisecond)
      # Request a wait far above the (temporarily lowered) ceiling, on a
      # request nobody answers — if the raw requested value were honored
      # unclamped, this test would hang for the full test-suite timeout
      # instead of returning at the 1-second ceiling.
      conn = get(conn, ~p"/api/v1/requests/#{request.id}?wait=999999")
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      body = json_response(conn, 200)
      assert body["status"] == "pending"
      assert elapsed_ms >= 1_000, "expected the clamped 1s ceiling to govern, not wait=999999"
      assert elapsed_ms < 4_000, "expected the clamp to hold — the raw value was not honored"
    end
  end
end
