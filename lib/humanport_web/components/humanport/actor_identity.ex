defmodule HumanPort.UI.ActorIdentity do
  @moduledoc """
  Who acted on a decision — same unverified/verified treatment as
  `HumanPort.UI.AgentBadge`, applied to the human/agent that decided a
  request rather than the one who requested it. In Phase 1 every acting
  actor is `verified: false` (D-11) — the local actor-resolver seam records
  identity from an environment variable, with no credential behind it.

  `prefix` is `:by` only in Phase 1 — `:escalated_to` and `:on_behalf_of`
  belong to routing and escalation (Phase 5) and are accepted here only so
  the prop contract does not have to widen later; nothing in this phase
  passes them.

  `method` (`:sso` / `:oidc` / `:api-key`) is shown only when `verified` is
  true. Phase 1 never sets `verified: true`, so `method` is always `nil` in
  the running product — the branch that renders it is exercised only by this
  component's own render test.
  """

  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  attr :name, :string, required: true
  attr :prefix, :atom, default: :by, values: [:by, :escalated_to, :on_behalf_of]
  attr :method, :atom, default: nil, values: [nil, :sso, :oidc, :"api-key"]
  attr :verified, :boolean, default: false
  attr :when, :any, default: nil
  attr :class, :any, default: nil

  # `when` is an Elixir reserved word — `@when` cannot be written directly
  # inside the `~H` sigil (the tokenizer rejects it). The public attr stays
  # named `when` to match the design system's prop contract; internally it
  # is re-assigned to `:at` before the template runs.
  def actor_identity(assigns) do
    assigns = assign(assigns, :at, assigns[:when])

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 font-mono text-[length:var(--hp-text-token)]",
      @class
    ]}>
      <span class="text-text-secondary">{prefix_word(@prefix)}</span>
      <span class="text-text-faint underline decoration-dotted">{@name}</span>
      <span :if={not @verified} class="font-bold text-text-primary">[{gettext("unverified")}]</span>
      <span :if={@verified} class="text-text-secondary">
        [{gettext("verified")}<span :if={@method}>·{@method}</span>]
      </span>
      <span :if={@at} class="text-text-faint">{format_when(@at)}</span>
    </span>
    """
  end

  defp prefix_word(:by), do: gettext("by")
  defp prefix_word(:escalated_to), do: gettext("escalated to")
  defp prefix_word(:on_behalf_of), do: gettext("on behalf of")

  defp format_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_when(other), do: to_string(other)
end
