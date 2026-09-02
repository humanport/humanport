defmodule HumanPort.UI.ContextBlock do
  @moduledoc """
  The agent's structured context, rendered **as supplied**: never re-flowed
  into prose, never summarised, never truncated behind a "show more". `rows`
  is a list of `{key, value}` pairs for a flat key/value shape; `text` is a
  single pre-formatted string. Pass exactly one; the other stays `nil`.

  Wide pre-formatted content scrolls **horizontally within the block**
  (`overflow-x-auto` on a `whitespace-pre` element) rather than re-flowing,
  breaking the pane grid, or being clipped — one of the two held-out UI-state
  backstops this phase verifies.

  **Everything here is agent-supplied and untrusted (T-01-25).** Every value
  renders through ordinary HEEx interpolation (`{...}`), which HTML-escapes
  by construction — this module reaches for no unescaped-markup helper on
  agent-supplied content anywhere, and must not start now.
  """

  use Phoenix.Component

  attr :rows, :list, default: nil
  attr :text, :string, default: nil
  attr :framed, :boolean, default: true
  attr :class, :any, default: nil

  def context_block(assigns) do
    ~H"""
    <div
      :if={present?(@rows, @text)}
      class={[
        @framed && "rounded-inner border border-border-hairline bg-surface-raised p-4",
        @class
      ]}
    >
      <dl
        :if={@rows not in [nil, []]}
        class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 font-mono text-[length:var(--hp-text-token)]"
      >
        <%= for {key, value} <- @rows do %>
          <dt class="text-text-faint">{key}</dt>
          <dd class="break-words text-text-primary">{value}</dd>
        <% end %>
      </dl>
      <pre
        :if={@text not in [nil, ""]}
        class="overflow-x-auto whitespace-pre font-mono text-[length:var(--hp-text-token)] text-text-primary"
      >{@text}</pre>
    </div>
    """
  end

  defp present?(rows, text), do: rows not in [nil, []] or text not in [nil, ""]
end
