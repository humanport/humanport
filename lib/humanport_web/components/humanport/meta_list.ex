defmodule HumanPort.UI.MetaList do
  @moduledoc """
  A definition list, not a table. `items` is a list of `%{key:, value:,
  tone:}` maps; `tone` is one of `:default` | `:critical` | `:accent` |
  `:quiet`. An item with a `nil` or empty-string value is omitted entirely —
  never rendered as an empty row.

  `:critical` exists for the design system's deadline notation
  (`14:22 → auto_reject`). **Phase 1 has no deadlines, so no caller may pass
  `tone: :critical`** — the tone is implemented here only so the component
  does not have to be re-shaped when Phase 5 needs it.
  """

  use Phoenix.Component

  attr :items, :list, default: []
  attr :class, :any, default: nil

  def meta_list(assigns) do
    ~H"""
    <dl class={[
      "grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 font-mono text-[length:var(--hp-text-token)]",
      @class
    ]}>
      <%= for item <- present(@items) do %>
        <dt class="text-text-faint">{item.key}</dt>
        <dd class={tone_class(Map.get(item, :tone, :default))}>{item.value}</dd>
      <% end %>
    </dl>
    """
  end

  defp present(items), do: Enum.reject(items, &(&1.value in [nil, ""]))

  defp tone_class(:default), do: "text-text-primary"
  defp tone_class(:critical), do: "font-bold text-accent-destructive"
  defp tone_class(:accent), do: "text-accent-actionable"
  defp tone_class(:quiet), do: "text-text-secondary"
end
