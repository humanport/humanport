defmodule HumanPort.UI.PaneHeader do
  @moduledoc """
  The header chrome for a Console pane — either the inbox root
  (`humanport ~/requests`) or a request detail (`← esc` plus the request
  short id). See `.planning/design/DESIGN-SYSTEM.md` § Components (private repo)
  and `01-UI-SPEC.md` § Component Inventory for the full prop contract.

  Phase 1 renders both forms but never populates `notice` — that carries
  deadline notices and is reserved for Phase 5 (ROUTE-*). It is accepted here,
  not implemented, so the prop contract does not have to widen later.
  """
  use Phoenix.Component

  import PetalComponents.Icon, only: [icon: 1]
  import PetalComponents.Kbd, only: [kbd: 1]

  attr :form, :atom, required: true, values: [:root, :detail]

  attr :short_id, :string,
    default: nil,
    doc: "required when form is :detail — the request's short id, e.g. \"c1e5f\""

  attr :back, :string,
    default: "/requests",
    doc: "navigate target for the detail form's back control"

  attr :notice, :string,
    default: nil,
    doc: "unused in Phase 1 — reserved for deadline notices, Phase 5 (ROUTE-*)"

  slot :stats, doc: "trailing stats shown beside the pane title, e.g. the open-request count"

  def pane_header(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-4 border-b border-border-strong bg-surface-raised px-4 py-3">
      <.pane_header_title form={@form} short_id={@short_id} back={@back} />
      <div
        :if={@stats != []}
        class="flex items-center gap-3 font-mono text-[length:var(--hp-text-meta)] text-text-secondary"
      >
        {render_slot(@stats)}
      </div>
    </header>
    <p
      :if={@notice}
      class="border-b border-border-hairline bg-surface-raised px-4 py-2 font-mono text-[length:var(--hp-text-meta)] text-text-secondary"
    >
      {@notice}
    </p>
    """
  end

  defp pane_header_title(%{form: :root} = assigns) do
    ~H"""
    <span class="font-mono text-[length:var(--hp-text-token)] font-bold text-text-primary">
      <span class="text-text-secondary">humanport</span> ~/requests
    </span>
    """
  end

  defp pane_header_title(%{form: :detail} = assigns) do
    ~H"""
    <.link
      navigate={@back}
      class="flex items-center gap-2 rounded-inner font-mono text-[length:var(--hp-text-token)] text-text-secondary hover:text-text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus-ring"
    >
      <.icon name="hero-arrow-left" class="size-4" />
      <.kbd keys={["esc"]} />
      <span class="font-bold text-text-primary">req/{@short_id}</span>
    </.link>
    """
  end
end
