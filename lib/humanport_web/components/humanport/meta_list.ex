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

  # Rendered as a single "key:value" token per row (the Console notation —
  # `state:pending`, `waited:6m` — is one glued token, never a key and a
  # value in visually separate columns). `dt`/`dd` sit on one source line
  # with nothing between their tags, so no whitespace text node can slip
  # between the colon-bearing key and its value.
  def meta_list(assigns) do
    ~H"""
    <dl class={["flex flex-col gap-1 font-mono text-[length:var(--hp-text-token)]", @class]}>
      <div :for={item <- present(@items)} class="flex items-baseline gap-1">
        <dt class="text-text-faint">{item.key}:</dt><dd class={
          tone_class(Map.get(item, :tone, :default))
        }>
          {item.value}
        </dd>
      </div>
    </dl>
    """
  end

  defp present(items), do: Enum.reject(items, &(&1.value in [nil, ""]))

  defp tone_class(:default), do: "text-text-primary"
  defp tone_class(:critical), do: "font-bold text-accent-destructive"
  defp tone_class(:accent), do: "text-accent-actionable"
  defp tone_class(:quiet), do: "text-text-secondary"
end
