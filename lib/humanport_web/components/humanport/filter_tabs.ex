defmodule HumanPort.UI.FilterTabs do
  @moduledoc """
  The single open/answered toggle (D-16) — a `tablist` with **exactly two**
  tabs. This is a toggle, not filter navigation; filter navigation is UI-04,
  Phase 6, and must not creep in here.

  `←`/`→` move and select — only the selected tab sits in the tab order
  (roving `tabindex`), and selection is carried by `aria-selected` as well
  as by fill and weight, never by `accent.actionable` (the design system's
  Accent-reserved-for list explicitly excludes the open/answered toggle).

  The arrow-key event is captured by the tablist container's `phx-keydown`
  and forwarded to the parent LiveView as `@on_arrow` — with exactly two
  tabs, either arrow key always means "the other tab", so no client-side
  focus math is needed to resolve it.
  """

  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  attr :active, :atom, required: true, values: [:open, :answered]
  attr :on_select, :string, default: "filter_select"
  attr :on_arrow, :string, default: "filter_arrow"
  attr :class, :any, default: nil

  def filter_tabs(assigns) do
    ~H"""
    <div
      role="tablist"
      aria-label={gettext("Requests")}
      phx-keydown={@on_arrow}
      class={["flex gap-1 border-b border-border-hairline px-4", @class]}
    >
      <.tab
        id="filter-tab-open"
        label={gettext("open")}
        value="open"
        active={@active == :open}
        on_select={@on_select}
      />
      <.tab
        id="filter-tab-answered"
        label={gettext("answered")}
        value="answered"
        active={@active == :answered}
        on_select={@on_select}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :active, :boolean, required: true
  attr :on_select, :string, required: true

  defp tab(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      role="tab"
      aria-selected={to_string(@active)}
      tabindex={if @active, do: "0", else: "-1"}
      phx-click={@on_select}
      phx-value-tab={@value}
      class={[
        "border-b-2 px-3 py-2 font-mono text-[length:var(--hp-text-token)]",
        "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus-ring",
        @active && "border-border-strong font-bold text-text-primary",
        !@active && "border-transparent text-text-secondary hover:text-text-primary"
      ]}
    >
      {@label}
    </button>
    """
  end
end
