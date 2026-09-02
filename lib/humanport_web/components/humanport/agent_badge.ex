defmodule HumanPort.UI.AgentBadge do
  @moduledoc """
  Who asked. In Phase 1 `verified` is always `false` (D-12) — the requesting
  agent is recorded from a client-supplied label with no credential behind
  it. This treatment is the control, not decoration: it is the only thing
  preventing the interface from implying an identity it never checked.

  - The unverified state is spelled in words: `[unverified]`.
  - The name sets in `text.faint` with a dotted underline.
  - `[unverified]` takes the **strongest** ink (`text.primary`) — the label
    is the loud part, the name is not.
  - `accent.actionable` is never applied to an unverified label — no branch
    in this module reaches for it.

  The identity method (`verified` shown only) is out of scope in Phase 1:
  every label is unverified, so `verified: true` is untested code today, kept
  only so the prop contract does not have to widen in a later phase.
  """

  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  attr :name, :string, required: true
  attr :verb, :string, default: nil
  attr :verified, :boolean, default: false
  attr :class, :any, default: nil

  def agent_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 font-mono text-[length:var(--hp-text-token)]",
      @class
    ]}>
      <span class="text-text-faint underline decoration-dotted">{@name}</span>
      <span :if={@verb} class="text-text-secondary">{@verb}</span>
      <span :if={not @verified} class="font-bold text-text-primary">[{gettext("unverified")}]</span>
      <span :if={@verified} class="text-text-secondary">[{gettext("verified")}]</span>
    </span>
    """
  end
end
