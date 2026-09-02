defmodule HumanPort.UI.AnswerCard do
  @moduledoc """
  The free-text `ask` decision block. Documented in
  `.planning/design/DESIGN-SYSTEM.md` § Components (private repo) and
  `01-UI-SPEC.md` § New Components — same structure and visual states as
  `ApprovalCard` (plan 01-03), with one deliberate difference: **no
  confirmation token and no lock**. A free-text answer authorises nobody to
  act — it is information, not permission — so the approval asymmetry does
  not apply here.

  Submission stays detail-view only (D-17). This component never decides a
  transition itself — the parent LiveView calls `Humanport.Requests.answer/3`
  on submit, exactly the domain function that opens the audit-writing
  transaction; nothing in this component builds a changeset.
  """

  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  import PetalComponents.Field, only: [field: 1]
  import PetalComponents.Button, only: [button: 1]

  attr :state, :atom, required: true, values: [:editing, :submitting, :decided]
  attr :value, :string, default: ""
  attr :answer, :string, default: nil
  attr :answered_by, :map, default: nil
  attr :answered_at, :any, default: nil
  attr :id, :string, required: true
  attr :on_change, :string, default: "answer_change"
  attr :on_submit, :string, default: "answer_submit"

  def answer_card(assigns) do
    assigns = assign(assigns, :hint_id, "#{assigns.id}-answer-hint")

    ~H"""
    <div
      id={@id}
      class="flex flex-col gap-3 rounded-inner border border-border-hairline bg-surface-raised p-4"
    >
      <div :if={@state == :decided}>
        <p class="whitespace-pre-wrap font-mono text-[length:var(--hp-text-body)] text-text-primary">
          {@answer}
        </p>
        <p id={@hint_id} class="mt-2 font-mono text-[length:var(--hp-text-meta)] text-text-secondary">
          {answered_hint(@answered_by, @answered_at)}
        </p>
      </div>
      <form
        :if={@state != :decided}
        id={"#{@id}-form"}
        phx-change={@on_change}
        phx-submit={@on_submit}
      >
        <.field
          id={"#{@id}-answer"}
          name="answer"
          type="textarea"
          label={gettext("Your answer")}
          value={@value}
          disabled={@state == :submitting}
          aria-describedby={@hint_id}
        />
        <div class="mt-3 flex items-center gap-3">
          <.button
            type="submit"
            disabled={@state == :submitting or @value in [nil, ""]}
            loading={@state == :submitting}
          >
            {gettext("Send answer")}
          </.button>
        </div>
        <p id={@hint_id} class="mt-2 font-mono text-[length:var(--hp-text-body)] text-text-secondary">
          {editing_hint(@state, @value)}
        </p>
      </form>
    </div>
    """
  end

  defp editing_hint(:submitting, _value), do: gettext("Sending your answer…")

  defp editing_hint(_state, value) when value in [nil, ""],
    do: gettext("Write an answer to enable Send answer.")

  defp editing_hint(_state, _value), do: gettext("Waiting for this answer.")

  defp answered_hint(nil, at), do: gettext("Answered at %{time}.", time: format_time(at))

  defp answered_hint(answered_by, at) do
    gettext("Answered by %{actor} at %{time}.",
      actor: actor_label(answered_by),
      time: format_time(at)
    )
  end

  defp actor_label(%{"label" => label}) when is_binary(label), do: label
  defp actor_label(%{label: label}) when is_binary(label), do: label
  defp actor_label(_), do: gettext("unknown")

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_time(other), do: to_string(other)
end
