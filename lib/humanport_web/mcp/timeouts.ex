defmodule HumanportWeb.MCP.Timeouts do
  @moduledoc """
  02.1-03-PLAN.md Task 1 Part C — the timeout relations `await` (Task 3)
  depends on, and a boot-time assertion (`verify!/0`) that the transport
  cannot silently truncate a wait shorter than the MCP surface promises.

  `await_timeout_ms/0` is the MCP `await` tool's own ceiling
  (`:humanport, :mcp_await_timeout_ms`, overridable via
  `HUMANPORT_MCP_AWAIT_TIMEOUT_SECONDS`) — the value `HumanportWeb.MCP.Tools.Await`
  clamps a caller-requested wait against. `long_poll_ceiling_ms/0` derives
  from `HumanportWeb.RequestWaiting.max_wait/0` — the SAME ceiling the HTTP
  `?wait=` surface has always used — expressed in milliseconds, so both
  surfaces' ceilings are inspectable through this one module.
  `keep_alive_interval_ms/0` is the SSE comment-line cadence `await.ex`
  writes at (`:humanport, :mcp_keep_alive_interval_ms`) — kept small enough
  in tests (via `Application.put_env/3`) that the "closing the stream
  cancels the wait" proof does not have to run for twenty-plus seconds to
  observe a closed socket.

  ## `verify!/0`'s honesty about what it can prove

  `verify!/0` reads the EFFECTIVE transport bound back out of the running
  configuration — `HumanportWeb.Endpoint.config(:http)` — never assumed from
  whichever of `config/config.exs`, `config/dev.exs`/`config/test.exs`/
  `config/prod.exs`, or `config/runtime.exs` happened to set it, because all
  three can and do set the endpoint's `:http` key and Elixir's `Config`
  module deep-merges keyword lists across them; only the merged value
  actually governs.

  Reading the dependency's own source (`deps/thousand_island/lib/thousand_island/handler.ex`'s
  moduledoc) rather than trusting the name turned up a FINDING, recorded
  here rather than papered over: `read_timeout` (the option this project's
  own `config/runtime.exs` comment names as "Bandit's 60s read timeout,"
  itself a `thousand_island_options` key, NOT an `http_1_options` key as
  that comment's phrasing suggested) bounds the IDLE time BETWEEN
  `ThousandIsland.Handler` callbacks — the time spent waiting for the NEXT
  chunk of CLIENT-SENT data — not the duration of a single callback's own
  execution. Once a request's headers (and body, if any) are fully read,
  Bandit dispatches the whole Plug pipeline synchronously inside ONE
  callback invocation; `await.ex`'s keep-alive loop runs entirely inside
  that one invocation, writing its OWN response bytes rather than waiting
  for the peer to send more, so `read_timeout` does not, in practice, bound
  how long `await` may hold a response open. `verify!/0` still asserts the
  relation below — set explicitly in `config/config.exs`, comfortably above
  the await ceiling — so a future Bandit/ThousandIsland version that DOES
  start enforcing a response-duration bound cannot silently shorten every
  wait without this assertion catching it first. **Either way, the
  load-bearing proof of "nothing truncates `await`" is Task 3's real-socket
  test past thirty-one seconds, not this function** — a config value is a
  claim, and a running system is the evidence.
  """

  defmodule ConfigurationError do
    @moduledoc """
    Raised by `HumanportWeb.MCP.Timeouts.verify!/0` when a configured
    timeout relation would let the transport, or a starved keep-alive, cut
    an `await` wait short. Names both offending values so the fix is
    obvious from the boot log, never a silent truncation discovered later
    as "the agent's wait mysteriously returned early."
    """

    defexception [:message]
  end

  alias HumanportWeb.RequestWaiting

  @default_await_timeout_ms 50_000
  @default_keep_alive_interval_ms 15_000

  @doc "The MCP `await` tool's own timeout ceiling, in milliseconds — what a caller-requested wait is clamped against."
  def await_timeout_ms do
    Application.get_env(:humanport, :mcp_await_timeout_ms, @default_await_timeout_ms)
  end

  @doc "The HTTP `?wait=` long-poll ceiling (`RequestWaiting.max_wait/0`), expressed in milliseconds."
  def long_poll_ceiling_ms, do: RequestWaiting.max_wait() * 1_000

  @doc "The SSE keep-alive comment-line interval, in milliseconds."
  def keep_alive_interval_ms do
    Application.get_env(:humanport, :mcp_keep_alive_interval_ms, @default_keep_alive_interval_ms)
  end

  @doc """
  Raises `HumanportWeb.MCP.Timeouts.ConfigurationError` — naming both
  offending values — when: the await ceiling is not a positive integer; the
  configured transport bound does not EXCEED the await ceiling; or the
  keep-alive interval is not STRICTLY LESS than the await ceiling. Returns
  `:ok` otherwise. Called from `Humanport.Application.start/2` so a
  misconfiguration that would silently shorten every wait is a loud boot
  failure, not a slow mystery — the same precedent `config/runtime.exs`
  already sets with its half-configured-Access raise.
  """
  def verify! do
    ceiling = await_timeout_ms()
    keep_alive = keep_alive_interval_ms()
    transport_bound = transport_read_timeout_ms()

    cond do
      not (is_integer(ceiling) and ceiling > 0) ->
        raise ConfigurationError,
          message:
            "HumanportWeb.MCP.Timeouts.await_timeout_ms/0 must be a positive integer, " <>
              "got #{inspect(ceiling)} (:humanport, :mcp_await_timeout_ms)"

      is_integer(transport_bound) and transport_bound <= ceiling ->
        raise ConfigurationError,
          message:
            "the configured HTTP transport read_timeout (#{transport_bound}ms, " <>
              "http: [thousand_island_options: [read_timeout: _]] on HumanportWeb.Endpoint) " <>
              "does not exceed the MCP await ceiling (#{ceiling}ms, :humanport, " <>
              ":mcp_await_timeout_ms) — raise the transport bound or lower the await ceiling"

      not (keep_alive < ceiling) ->
        raise ConfigurationError,
          message:
            "the SSE keep-alive interval (#{keep_alive}ms, :humanport, " <>
              ":mcp_keep_alive_interval_ms) is not strictly less than the MCP await ceiling " <>
              "(#{ceiling}ms, :humanport, :mcp_await_timeout_ms) — an await could close with " <>
              "no keep-alive ever written"

      true ->
        :ok
    end
  end

  defp transport_read_timeout_ms do
    HumanportWeb.Endpoint.config(:http, [])
    |> Keyword.get(:thousand_island_options, [])
    |> Keyword.get(:read_timeout)
  end
end
