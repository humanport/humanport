defmodule HumanPort.UI.ApprovalCard do
  @moduledoc """
  The approval asymmetry — the most important interaction in the product.
  Approving lets an agent act; rejecting only stops it, so the costs are
  deliberately unequal.

  Approving requires typing `approve <short-id>` before the control unlocks
  — the same short id `HumanPort.UI.PaneHeader` already shows, so the token
  is legible on screen rather than guessable from memory. Comparison is
  case-insensitive and whitespace-trimmed; the parent LiveView owns that
  comparison and passes the result in as `state`.

  Rejecting stays **one press** — no confirmation dialog, no token, no
  modal. That asymmetry *is* the design; a confirmation on reject would
  erase the signal that approving is the consequential direction.

  The lock is never signalled by dimming alone: a hint sentence under the
  controls states the current condition in words and is wired as
  `aria-describedby`, with the hint `id` derived per instance (`@id`) so
  several cards on one screen each describe their own lock rather than one
  another's.

  **State plainly: the typed token is mis-click prevention, not content
  binding.** It sits on screen in the hint sentence, so a reader could copy
  it without ever having read the request.

  The real §54.8 content-binding guarantee is not implemented in Phase 1 —
  that requires a stored hash of the exact content the human was shown,
  which is SEC-08, a later phase.

  No comment, doc, or commit message may claim this token satisfies §54.8's content-binding guarantee — not here, not anywhere in this module.

  The one sub-threshold-contrast role in the whole interface —
  `text.disabled` — is legal exactly here, on the locked Approve label, and
  only because the hint sentence beside it also states the condition in
  words.
  """

  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  import PetalComponents.Field, only: [field: 1]
  import PetalComponents.Button, only: [button: 1]

  attr :confirm_token, :string, required: true, doc: ~s(e.g. "approve c1e5f")
  attr :value, :string, default: ""
  attr :state, :atom, required: true, values: [:locked, :unlocked, :submitting, :decided]
  attr :decision, :atom, default: nil, values: [nil, :approved, :rejected]
  attr :decided_by, :map, default: nil
  attr :decided_at, :any, default: nil
  attr :agent, :string, default: nil
  attr :id, :string, required: true
  attr :on_change, :string, default: "confirm_change"
  attr :on_approve, :string, default: "approve_submit"
  attr :on_reject, :string, default: "reject_submit"

  def approval_card(assigns) do
    assigns = assign(assigns, :hint_id, "#{assigns.id}-approval-hint")

    ~H"""
    <div
      id={@id}
      class="flex flex-col gap-3 rounded-inner border border-border-hairline bg-surface-raised p-4"
    >
      <div :if={@state == :decided}>
        <p class="font-mono text-[length:var(--hp-text-body)] font-bold text-text-primary">
          {decision_label(@decision)}
        </p>
        <p id={@hint_id} class="mt-2 font-mono text-[length:var(--hp-text-meta)] text-text-secondary">
          {decided_hint(@decision, @decided_by, @decided_at)}
        </p>
      </div>

      <div :if={@state != :decided} class="flex flex-col gap-3">
        <form id={"#{@id}-form"} phx-change={@on_change}>
          <.field
            id={"#{@id}-confirm"}
            name="confirm"
            type="text"
            label={gettext("Confirmation")}
            placeholder={@confirm_token}
            value={@value}
            disabled={@state == :submitting}
            aria-describedby={@hint_id}
          />
        </form>

        <div class="flex items-center gap-3">
          <.button
            type="button"
            phx-click={@on_approve}
            disabled={@state != :unlocked}
            loading={@state == :submitting}
            aria-describedby={@hint_id}
            class={@state == :locked && "text-text-disabled"}
          >
            {gettext("Approve")}
          </.button>
          <.button
            type="button"
            variant="outline"
            phx-click={@on_reject}
            disabled={@state == :submitting}
            class="border-border-destructive text-accent-destructive"
          >
            {gettext("Reject")}
          </.button>
        </div>

        <p id={@hint_id} class="font-mono text-[length:var(--hp-text-body)] text-text-secondary">
          {editing_hint(@state, @confirm_token, @agent)}
        </p>
      </div>
    </div>
    """
  end

  defp editing_hint(:locked, confirm_token, _agent),
    do: gettext("Type %{token} to unlock Approve.", token: confirm_token)

  defp editing_hint(:unlocked, _confirm_token, nil),
    do: gettext("Approve is unlocked.")

  defp editing_hint(:unlocked, _confirm_token, agent),
    do: gettext("Approve is unlocked. Approving lets %{agent} proceed.", agent: agent)

  defp editing_hint(:submitting, _confirm_token, _agent),
    do: gettext("Recording your decision…")

  defp decision_label(:approved), do: gettext("Approved")
  defp decision_label(:rejected), do: gettext("Rejected")

  defp decided_hint(decision, decided_by, decided_at) do
    gettext("%{decision} by %{actor} at %{time}.",
      decision: decision_label(decision),
      actor: actor_label(decided_by),
      time: format_time(decided_at)
    )
  end

  defp actor_label(%{"label" => label}) when is_binary(label), do: label
  defp actor_label(%{label: label}) when is_binary(label), do: label
  defp actor_label(_), do: gettext("unknown")

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_time(other), do: to_string(other)
end
