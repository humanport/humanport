defmodule HumanPort.UI.RequestTimeline do
  @moduledoc """
  The audit events for one request, rendered as an ordered list of
  sentences — a timestamp plus one sentence naming the actor and what
  happened. No log syntax, no stack traces, no version diffs (§20.3: the
  timeline reads as a story, not a version diff).

  `events` is a list of `%{time:, text:, current:}` maps. At most one event
  should carry `current: true`; the current event says so **in words**
  (`(current)`) as well as by accent — colour alone never carries the
  distinction (§20.4).
  """

  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  attr :events, :list, default: []
  attr :class, :any, default: nil

  def request_timeline(assigns) do
    ~H"""
    <ol class={["flex flex-col gap-2 font-mono text-[length:var(--hp-text-token)]", @class]}>
      <li :for={event <- @events} class="flex items-baseline gap-3">
        <span class="shrink-0 text-text-faint">{format_time(event.time)}</span>
        <span class={(current?(event) && "font-bold text-accent-actionable") || "text-text-primary"}>
          {event.text}
          <span :if={current?(event)}>({gettext("current")})</span>
        </span>
      </li>
    </ol>
    """
  end

  defp current?(%{current: true}), do: true
  defp current?(_), do: false

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_time(other), do: to_string(other)
end
