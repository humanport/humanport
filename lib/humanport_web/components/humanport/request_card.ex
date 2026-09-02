defmodule HumanPort.UI.RequestCard do
  @moduledoc """
  One inbox row — an `option` inside the inbox `listbox`. See
  `.planning/design/DESIGN-SYSTEM.md` § Components (private repo) and
  `01-UI-SPEC.md` § Component Inventory for the full prop contract.

  `left`, `overdue` and `escalated` are always `nil`/`false` in Phase 1 —
  there are no deadlines and no escalation yet. They stay in the prop
  contract on purpose (it is the design system's, not this phase's, and
  narrowing it now would mean widening it again in Phase 5); this renderer
  **omits** each affordance entirely when it is nil/false rather than
  rendering an empty slot.

  `risk_level`/`reversible` carry real values (D-24) and drive an inline
  `RiskBadge`; the row shows no badge at all when the request states no
  risk — never a low one standing in for silence (T-01-37).

  The title is **never truncated** by this component, at any length — one of
  the two held-out UI-state backstops this phase verifies.
  """

  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  import HumanPort.UI.RiskBadge

  attr :index, :integer, required: true
  attr :title, :string, required: true
  attr :agent, :string, required: true
  attr :type, :atom, required: true, values: [:ask, :choose, :approve, :escalate]
  attr :target, :string, default: nil
  attr :risk_level, :atom, default: nil, values: [nil, :high, :medium, :low]
  attr :reversible, :string, default: nil
  attr :state, :atom, required: true
  attr :waited, :string, default: nil
  attr :left, :string, default: nil
  attr :overdue, :boolean, default: false
  attr :escalated, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :answered, :boolean, default: false
  attr :result, :string, default: nil
  attr :decided_by, :string, default: nil
  attr :on_select, :string, default: "select_request"

  def request_card(assigns) do
    ~H"""
    <div
      id={"request-card-#{@index}"}
      role="option"
      aria-selected={to_string(@selected)}
      phx-click={@on_select}
      phx-value-index={@index}
      class={[
        "flex cursor-pointer flex-col gap-1 border-b border-border-hairline px-4 py-[13px]",
        "font-mono text-[length:var(--hp-text-row)] text-text-primary",
        @selected && "bg-surface-raised"
      ]}
    >
      <div class="flex flex-wrap items-center gap-2 text-[length:var(--hp-text-meta)] text-text-faint">
        <span>{@index}</span>
        <span>state:{@state}</span>
        <span :if={@waited}>waited:{@waited}</span>
        <span :if={@left}>left:{@left}</span>
        <span :if={@overdue} class="font-bold text-accent-destructive">{gettext("overdue")}</span>
        <span :if={@escalated} class="text-text-secondary">{gettext("escalated")}</span>
        <.risk_badge :if={@risk_level} level={@risk_level} reversible={@reversible} layout={:inline} />
      </div>
      <div class="whitespace-normal break-words font-bold">{@title}</div>
      <div class="flex flex-wrap items-center gap-2 text-[length:var(--hp-text-meta)] text-text-secondary">
        <span class="text-text-faint underline decoration-dotted">{@agent}</span>
        <span>type:{@type}</span>
        <span :if={@target}>{@target}</span>
        <span :if={@answered and @result}>result:{@result}</span>
        <span :if={@answered and @decided_by}>{gettext("by")} {@decided_by}</span>
      </div>
    </div>
    """
  end
end
