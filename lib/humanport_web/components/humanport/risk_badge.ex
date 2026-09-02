defmodule HumanPort.UI.RiskBadge do
  @moduledoc """
  Risk notation — carried by **glyph count and weight, never by hue**, in both
  themes. See `.planning/design/DESIGN-SYSTEM.md` § Notation (private repo)
  and `01-UI-SPEC.md` § Risk notation.

  `level` and `reversible` are D-24's two nullable, agent-stated-only fields.
  **When both are absent this component renders nothing at all.** An agent
  that stated no risk has not stated a low one — rendering the absent case as
  `[!··]` would be the component lying about its input (T-01-37). Never
  derive, default, or infer a level; render exactly what was supplied.

  Every colour used here (`text-text-primary` / `text-text-faint`) is the
  same in every state — only the sigil's glyph count and the spelled form
  change. No `data-risk`-driven colour class exists anywhere in this module.
  """

  use Phoenix.Component

  attr :level, :atom, default: nil, values: [nil, :high, :medium, :low]
  attr :reversible, :string, default: nil
  attr :layout, :atom, default: :inline, values: [:inline, :block]
  attr :class, :any, default: nil

  def risk_badge(assigns) do
    ~H"""
    <span
      :if={@level}
      class={[
        @layout == :block && "flex items-center gap-2",
        @layout == :inline && "inline-flex items-center gap-2",
        "font-mono text-[length:var(--hp-text-token)]",
        @class
      ]}
    >
      <span class="font-bold text-text-primary" aria-hidden="true">{sigil(@level)}</span>
      <span class="text-text-secondary">{spelled(@level, @reversible)}</span>
    </span>
    """
  end

  defp sigil(:high), do: "[!!!]"
  defp sigil(:medium), do: "[!!·]"
  defp sigil(:low), do: "[!··]"

  defp spelled(level, nil), do: "risk:#{level} #{glyph_count(level)}/3"

  defp spelled(level, reversible),
    do: "risk:#{level} #{glyph_count(level)}/3 · reversible:#{reversible}"

  defp glyph_count(:high), do: 3
  defp glyph_count(:medium), do: 2
  defp glyph_count(:low), do: 1
end
