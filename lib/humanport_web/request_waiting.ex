defmodule HumanportWeb.RequestWaiting do
  @moduledoc """
  02.1-03-PLAN.md Task 1 Part B — the ONE long-poll primitive in this
  application, extracted (moved, not retyped) from the private functions
  that used to live at the bottom of `HumanportWeb.RequestController`.
  `HumanportWeb.RequestController.show/2` (the `GET
  /api/v1/requests/:id?wait=N` HTTP surface) and `HumanportWeb.MCP.Tools.Await`
  (the MCP `await` tool, `02.1-03-PLAN.md` Task 3) BOTH call `await/4` here —
  that is what makes D-10's "one domain, not a parallel path" hold for the
  wait mechanics specifically, not merely by convention. A change in this
  module changes both surfaces; there is no second wait chain anywhere else
  to drift out of sync with it.

  Public surface is exactly four functions: `await/4`, `topic/1`,
  `parse_wait/1`, `max_wait/0`. Subscribing to and unsubscribing from the
  per-request PubSub topic stays the CALLER's job (both callers need to know
  when to unsubscribe on their own terms — the HTTP controller
  unconditionally, `await.ex` after writing its final SSE event) — this
  module only waits on an already-established subscription.

  ## Why subscribe happens in the caller, before the first read (Pattern 6)

  Reading the request first opens a window in which the answer commits and
  broadcasts before the subscription exists, and the caller then waits out
  the full timeout for an event that already happened. Both callers MUST
  subscribe to `topic(id)` before their own first `Requests.get_request/1`
  call — `await/4` itself does not subscribe, because it does not own the
  subscription's lifetime, but every clause below assumes one is already in
  place whenever `wait_seconds > 0`.
  """

  alias Humanport.Requests

  @terminal_states [:answered, :approved, :rejected]

  @doc "The per-request PubSub topic — the SAME string the resource's `pub_sub` block publishes on."
  def topic(id), do: "request:#{id}"

  @doc """
  Waits for `request` (already read once by the caller) to reach a terminal
  state, for at most `wait_seconds`, on the per-request topic the caller has
  ALREADY subscribed to. Returns `{:ok, request}` — the answered request if
  woken, or a fresh (possibly still pending) read if the window closes
  first. A closed window is never an error (D-02): the caller always gets an
  ordinary, freshly-read request back, `state: :pending` and all.

  Returns `request` unchanged, with NO second database read, when it is
  already terminal or when `wait_seconds` is zero or negative — the
  zero-wait branch is `check`'s entire implementation (`02.1-03-PLAN.md`
  Task 2): the immediate glance is this function's no-wait clause, reached
  without ever subscribing to anything.
  """
  def await(id, topic, request, wait_seconds) do
    do_await(id, topic, request, wait_seconds, deadline(wait_seconds))
  end

  @doc """
  Clamped, non-negative whole seconds. `nil`, a negative number, a
  non-string, or an unparseable string all mean "no wait at all" (`0`); any
  value above `max_wait/0`'s ceiling is clamped to that ceiling, never
  honored raw.
  """
  def parse_wait(nil), do: 0

  def parse_wait(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> n |> max(0) |> min(max_wait())
      _ -> 0
    end
  end

  def parse_wait(_), do: 0

  @doc "The configured long-poll ceiling, in whole seconds (`HUMANPORT_LONG_POLL_MAX_WAIT_SECONDS`, D-01/D-02)."
  def max_wait, do: Application.get_env(:humanport, :long_poll_max_wait_seconds, 50)

  # `round/1`, not a bare `:timer.seconds(wait)` — 02.1-03-PLAN.md Task 3
  # FINDING: `:timer.seconds/1` preserves its argument's type (an integer
  # `wait`, the only kind the HTTP `?wait=N` surface and this module's own
  # pre-Task-3 tests ever pass, yields an integer; but a FRACTIONAL `wait`
  # yields a FLOAT, e.g. `:timer.seconds(0.2) == 200.0`), and Erlang's
  # `receive ... after Timeout` REQUIRES Timeout to be a non-negative
  # integer or `:infinity` — a float timeout raises `:timeout_value`.
  # `HumanportWeb.MCP.Tools.Await`'s keep-alive loop (Task 3) needs genuine
  # sub-second precision — its whole reason for reading the keep-alive
  # interval from application config is so a test can set it to "a fraction
  # of a second and stay honest" rather than waiting twenty-plus seconds to
  # observe a closed socket — so this primitive must accept a fractional
  # `wait` without crashing. `round/1` keeps every existing integer-`wait`
  # caller byte-for-byte unchanged (`round(5000) == 5000`) while making a
  # fractional `wait` (e.g. `0.2`) resolve to a genuine, receive-safe
  # integer millisecond deadline (`round(200.0) == 200`) instead of a
  # crash.
  defp deadline(wait), do: System.monotonic_time(:millisecond) + round(:timer.seconds(wait))

  # Already terminal — return immediately regardless of the wait parameter.
  defp do_await(_id, _topic, %{state: state} = request, _wait, _deadline)
       when state in @terminal_states do
    {:ok, request}
  end

  # No wait requested — return the immediate (possibly pending) read as-is,
  # with NO second database read.
  defp do_await(_id, _topic, request, wait, _deadline) when wait <= 0 do
    {:ok, request}
  end

  defp do_await(id, topic, _request, wait, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      # Timeout — re-read anyway. A dropped or cross-node broadcast then
      # costs latency, not an answer; correctness never depends on the
      # message arriving.
      Requests.get_request(id)
    else
      receive do
        %Phoenix.Socket.Broadcast{topic: ^topic} ->
          # The broadcast proves something changed; the database proves
          # what. Never render from the message payload — always re-read.
          with {:ok, fresh} <- Requests.get_request(id) do
            # If still non-terminal, keep waiting with the REMAINING budget
            # (`deadline` is unchanged — `remaining` is recomputed from it
            # on the next call), never a restarted full timeout.
            do_await(id, topic, fresh, wait, deadline)
          end
      after
        remaining ->
          Requests.get_request(id)
      end
    end
  end
end
