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

  `method` is shown only when `verified` is true.

  02-02-PLAN.md Task 2 (D-04) — the `values:` list is widened to the SAME
  vocabulary `Humanport.Audit.Event`'s `actor_method` column now carries
  (`[:sso, :service_token, :magic_link, :oidc, :api_key]`), a superset of
  Phase 1's original list. `:api_key` (underscore) is CANONICAL — it is
  what the audit column and every producer from Phase 2 forward writes;
  `:"api-key"` (hyphen) stays in the list only because it was already
  accepted here and nothing has ever produced it, avoiding a silent
  breaking change to this component's public prop contract for a value
  no caller passes.

  Note on what `values:` actually enforces: `Phoenix.Component`'s `attr
  ... values:` check is a COMPILE-TIME warning for a LITERAL atom written
  at a `<.actor_identity method={:some_atom} />` call site — it does
  **not** raise at runtime, and does not validate a value that arrives
  dynamically (`method={@event.actor_method}`, this component's actual
  Phase 2 usage), confirmed by reading `Phoenix.Component.Declarative
  .verify/3`, whose relevant clause only matches a literal HEEx AST
  attribute value. An earlier draft of this moduledoc (matching this
  plan's own action text) claimed a runtime raise; that was incorrect.
  """

  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  attr :name, :string, required: true
  attr :prefix, :atom, default: :by, values: [:by, :escalated_to, :on_behalf_of]

  attr :method, :atom,
    default: nil,
    values: [nil, :sso, :oidc, :"api-key", :service_token, :magic_link, :api_key]

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
