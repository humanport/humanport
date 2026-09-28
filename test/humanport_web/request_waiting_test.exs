defmodule HumanportWeb.RequestWaitingTest do
  @moduledoc """
  02.1-03-PLAN.md Task 1 — unit-level coverage of `parse_wait/1`, `topic/1`
  and `await/4` directly. The HTTP integration proof (the woken path, the
  timed-out path, the answered-in-the-gap race) is
  `test/humanport_web/controllers/long_poll_test.exs`, which stays
  byte-identical to its pre-extraction state and green — that file, not this
  one, is the proof the extraction changed no HTTP behaviour.

  Runs `async: false` (`HumanportWeb.ConnCase`'s default when no `async:` is
  given) because several tests below mutate `:humanport, :long_poll_max_wait_seconds`
  application config — process-global state — via `Application.put_env/3`,
  restored in `on_exit`.
  """

  use HumanportWeb.ConnCase, async: false

  import Humanport.Fixtures

  alias Humanport.Requests
  alias HumanportWeb.RequestWaiting

  describe "parse_wait/1" do
    test "nil means no wait" do
      assert RequestWaiting.parse_wait(nil) == 0
    end

    test "a negative number means no wait" do
      assert RequestWaiting.parse_wait("-5") == 0
    end

    test "a non-string means no wait" do
      assert RequestWaiting.parse_wait(5) == 0
      assert RequestWaiting.parse_wait(%{}) == 0
      assert RequestWaiting.parse_wait([]) == 0
    end

    test "an unparseable string means no wait" do
      assert RequestWaiting.parse_wait("not-a-number") == 0
      assert RequestWaiting.parse_wait("45abc") == 0
    end

    test "zero means no wait" do
      assert RequestWaiting.parse_wait("0") == 0
    end

    test "a value above the ceiling is clamped to the ceiling, never honored raw" do
      original = Application.get_env(:humanport, :long_poll_max_wait_seconds, 50)
      Application.put_env(:humanport, :long_poll_max_wait_seconds, 5)
      on_exit(fn -> Application.put_env(:humanport, :long_poll_max_wait_seconds, original) end)

      assert RequestWaiting.parse_wait("999999") == 5
    end

    test "a value within the ceiling is honored as-is" do
      assert RequestWaiting.parse_wait("3") == 3
    end
  end

  describe "topic/1" do
    test "returns the same per-request topic string the resource's pub_sub block publishes on" do
      request = request_fixture(%{type: :ask, title: "Which topic?"})

      assert RequestWaiting.topic(request.id) == "request:#{request.id}"

      HumanportWeb.Endpoint.subscribe(RequestWaiting.topic(request.id))
      {:ok, _} = Requests.answer(request, "the answer", default_actor())

      assert_receive %Phoenix.Socket.Broadcast{topic: topic}
      assert topic == RequestWaiting.topic(request.id)
    end
  end

  describe "max_wait/0" do
    test "reads the configured ceiling, defaulting to 50" do
      original = Application.get_env(:humanport, :long_poll_max_wait_seconds, 50)
      on_exit(fn -> Application.put_env(:humanport, :long_poll_max_wait_seconds, original) end)

      Application.put_env(:humanport, :long_poll_max_wait_seconds, 7)
      assert RequestWaiting.max_wait() == 7
    end
  end

  describe "await/4 — already terminal" do
    test "returns immediately regardless of the wait, unchanged, no second read" do
      request = request_fixture(%{type: :ask, title: "Already answered"})
      {:ok, answered} = Requests.answer(request, "done", default_actor())

      # A request nobody deletes underneath us — if await/4 re-read the
      # database here it would still see the same row, so instead assert on
      # timing: a terminal request must never wait even when asked to.
      topic = RequestWaiting.topic(answered.id)

      started_at = System.monotonic_time(:millisecond)
      {:ok, result} = RequestWaiting.await(answered.id, topic, answered, 10)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert result.id == answered.id
      assert result.state == :answered
      assert elapsed_ms < 200, "a terminal request must never wait, took #{elapsed_ms}ms"
    end
  end

  describe "await/4 — no wait requested" do
    test "returns the request unchanged, with no second database read, when wait is zero" do
      request = request_fixture(%{type: :ask, title: "No wait"})
      topic = RequestWaiting.topic(request.id)

      # Delete the row so a second read would provably fail — proving the
      # zero-wait clause never re-reads. `HumanportWeb.ConnCase`'s own setup
      # already checked out the sandbox connection for this test.
      Humanport.Repo.delete!(request)

      assert {:ok, result} = RequestWaiting.await(request.id, topic, request, 0)
      assert result.id == request.id
    end

    test "returns the request unchanged when wait is negative" do
      request = request_fixture(%{type: :ask, title: "Negative wait"})
      topic = RequestWaiting.topic(request.id)

      assert {:ok, result} = RequestWaiting.await(request.id, topic, request, -5)
      assert result.id == request.id
    end
  end

  describe "await/4 — woken by a real broadcast" do
    test "returns promptly, well before the deadline, when answered mid-wait", %{} do
      request = request_fixture(%{type: :ask, title: "Woken by broadcast"})
      topic = RequestWaiting.topic(request.id)

      wait_task =
        Task.async(fn ->
          # Subscribe and await in the SAME process — await/4's `receive`
          # only ever sees broadcasts delivered to ITS OWN mailbox, exactly
          # like the HTTP controller's caller-owns-the-subscription design
          # this test is proving.
          HumanportWeb.Endpoint.subscribe(topic)
          started_at = System.monotonic_time(:millisecond)
          {:ok, result} = RequestWaiting.await(request.id, topic, request, 10)
          {result, System.monotonic_time(:millisecond) - started_at}
        end)

      Process.sleep(150)
      {:ok, _answered} = Requests.answer(request, "the real answer", default_actor())

      {result, elapsed_ms} = Task.await(wait_task, 5_000)

      assert result.state == :answered
      assert result.answer == "the real answer"
      assert elapsed_ms < 2_000, "expected a prompt wake, took #{elapsed_ms}ms"
    end
  end

  describe "await/4 — the window closes with no answer" do
    test "returns a fresh pending read at the deadline, never an error" do
      request = request_fixture(%{type: :ask, title: "Nobody answers"})
      topic = RequestWaiting.topic(request.id)
      HumanportWeb.Endpoint.subscribe(topic)

      started_at = System.monotonic_time(:millisecond)
      assert {:ok, result} = RequestWaiting.await(request.id, topic, request, 1)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert result.state == :pending
      assert elapsed_ms >= 1_000
      assert elapsed_ms < 4_000
    end
  end

  describe "await/4 — fractional wait_seconds (02.1-03-PLAN.md Task 3 finding)" do
    test "a sub-second wait does not crash — round/1, not a bare :timer.seconds/1" do
      request = request_fixture(%{type: :ask, title: "Fractional wait"})
      topic = RequestWaiting.topic(request.id)
      HumanportWeb.Endpoint.subscribe(topic)

      started_at = System.monotonic_time(:millisecond)
      assert {:ok, result} = RequestWaiting.await(request.id, topic, request, 0.2)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert result.state == :pending
      assert elapsed_ms >= 200
      assert elapsed_ms < 2_000
    end
  end

  describe "HumanportWeb.MCP.Timeouts.verify!/0" do
    alias HumanportWeb.MCP.Timeouts

    test "returns :ok for the shipped defaults" do
      assert Timeouts.verify!() == :ok
    end

    test "raises, naming both values, when the configured transport bound does not exceed the await ceiling" do
      original_http = HumanportWeb.Endpoint.config(:http)

      on_exit(fn -> Phoenix.Config.put(HumanportWeb.Endpoint, :http, original_http) end)

      # Lower the effective transport bound BELOW the (default 50_000ms)
      # await ceiling — via the same ETS-backed mechanism Phoenix's own
      # Endpoint.config/2 reads (see HumanportWeb.MCP.Timeouts' moduledoc:
      # this is the "effective, running configuration," not a file on disk).
      Phoenix.Config.put(
        HumanportWeb.Endpoint,
        :http,
        Keyword.put(original_http, :thousand_island_options, read_timeout: 1_000)
      )

      assert_raise Timeouts.ConfigurationError, ~r/does not exceed the MCP await ceiling/, fn ->
        Timeouts.verify!()
      end
    end

    test "raises, naming both values, when the keep-alive interval is not strictly less than the await ceiling" do
      original = Application.get_env(:humanport, :mcp_keep_alive_interval_ms)
      on_exit(fn -> Application.put_env(:humanport, :mcp_keep_alive_interval_ms, original) end)

      Application.put_env(:humanport, :mcp_keep_alive_interval_ms, Timeouts.await_timeout_ms())

      assert_raise Timeouts.ConfigurationError,
                   ~r/not strictly less than the MCP await ceiling/,
                   fn ->
                     Timeouts.verify!()
                   end
    end

    test "raises when the await ceiling is not a positive integer" do
      original = Application.get_env(:humanport, :mcp_await_timeout_ms)
      on_exit(fn -> Application.put_env(:humanport, :mcp_await_timeout_ms, original) end)

      Application.put_env(:humanport, :mcp_await_timeout_ms, 0)

      assert_raise Timeouts.ConfigurationError, ~r/must be a positive integer/, fn ->
        Timeouts.verify!()
      end
    end
  end
end
