defmodule HumanPort.UI.ChoiceCard do
  @moduledoc """
  The `choose` decision block (`02.1-05-PLAN.md` Task 2, CORE-04). Same
  structure and visual states as `HumanPort.UI.AnswerCard` and
  `HumanPort.UI.ApprovalCard` — one deliberate choice mirrors `AnswerCard`'s
  own: **no confirmation token and no lock.**

  A choice between named paths the caller supplied is information, not
  permission: the human is telling the agent which way to go, not granting
  it permission it did not already have. `ApprovalCard`'s token exists
  because approving lets an agent *act* — rejecting stays one press,
  deliberately asymmetric. A `choose` request carries no such asymmetry
  between its options, so no option here requires typing anything to
  select. **A decision that genuinely authorises action should be sent as
  an approval request, not as a choice** — which is exactly why there are
  three request types rather than one.

  Submission stays detail-view only (D-17). This component never decides a
  transition itself — the parent LiveView calls
  `Humanport.Requests.choose/3` on submit, the same domain function every
  other surface (the HTTP respond endpoint) calls; nothing in this
  component builds a changeset or reaches the data layer.

  ## Nothing is pre-selected — the whole point of this component (§54.8)

  The card receives the current selection as an attribute defaulting to
  `nil`, and renders no `checked` attribute on any option control when
  there is none — including the option carrying the advisory `recommended`
  flag. That flag is rendered as a suggestion beside the option's own
  wrapping content, never as a selection state and never as a fallback
  when nothing was chosen. A gate that answers itself is not a gate.

  ## The phone precedent — no truncation, no non-wrapping row

  Options stack vertically, each a full-width block, at every breakpoint.
  Labels wrap; descriptions wrap; the advisory marker sits inside the
  option's own wrapping content rather than pinned to a non-wrapping row's
  right edge — the exact hazard class that clipped `HumanPort.UI.ActorIdentity`'s
  trust marker on 2026-09-03. No `truncate`, `text-ellipsis`,
  `whitespace-nowrap`, or `line-clamp` class appears anywhere in this
  module, and no two options are ever laid out side by side.

  ## Free text is an alternative, never an additional requirement

  When `allow_free_text` is true, a text field renders beneath the
  options. Submitting sends the selection when one was made and the free
  text otherwise — never both at once — so a reader of the result can tell
  which happened by which field came back populated (locked decision 4).
  """

  use Phoenix.Component
  use Gettext, backend: HumanportWeb.Gettext

  import PetalComponents.Field, only: [field: 1]
  import PetalComponents.Button, only: [button: 1]

  attr :id, :string, required: true
  attr :state, :atom, required: true, values: [:editing, :submitting, :decided]
  attr :options, :list, default: []
  attr :allow_free_text, :boolean, default: false
  attr :selected_option_id, :string, default: nil
  attr :free_text_value, :string, default: ""
  attr :selected_option_ids, :list, default: nil
  attr :free_text, :string, default: nil
  attr :decided_by, :map, default: nil
  attr :decided_at, :any, default: nil
  attr :agent, :string, default: nil
  attr :on_change, :string, default: "choice_change"
  attr :on_submit, :string, default: "choice_submit"

  def choice_card(assigns) do
    assigns = assign(assigns, :hint_id, "#{assigns.id}-choice-hint")

    ~H"""
    <div
      id={@id}
      class="flex flex-col gap-3 rounded-inner border border-border-hairline bg-surface-raised p-4"
    >
      <div :if={@state == :decided}>
        <p class="font-mono text-[length:var(--hp-text-body)] font-bold text-text-primary">
          {decided_label(@selected_option_ids, @free_text, @options)}
        </p>
        <p id={@hint_id} class="mt-2 font-mono text-[length:var(--hp-text-meta)] text-text-secondary">
          {decided_hint(@decided_by, @decided_at)}
        </p>
      </div>

      <div :if={@state != :decided} class="flex flex-col gap-3">
        <form id={"#{@id}-form"} phx-change={@on_change}>
          <div class="flex flex-col gap-3">
            <label
              :for={option <- @options}
              class="flex flex-col gap-1 rounded-inner border border-border-hairline p-3"
            >
              <span class="flex flex-wrap items-baseline gap-2">
                <input
                  type="radio"
                  name="selected_option_id"
                  value={option.id}
                  checked={option.id == @selected_option_id}
                  disabled={@state == :submitting}
                />
                <span class="font-mono text-[length:var(--hp-text-body)] text-text-primary">
                  {option.label}
                </span>
                <span
                  :if={option.recommended}
                  class="font-mono text-[length:var(--hp-text-meta)] text-text-secondary"
                >
                  ({gettext("suggested")})
                </span>
              </span>
              <span
                :if={option.description}
                class="font-mono text-[length:var(--hp-text-meta)] text-text-secondary"
              >
                {option.description}
              </span>
            </label>
          </div>

          <.field
            :if={@allow_free_text}
            id={"#{@id}-free-text"}
            name="free_text"
            type="textarea"
            label={gettext("Or write your own answer")}
            value={@free_text_value}
            disabled={@state == :submitting}
            aria-describedby={@hint_id}
          />
        </form>

        <div class="flex items-center gap-3">
          <.button
            type="button"
            phx-click={@on_submit}
            disabled={not can_submit?(@selected_option_id, @free_text_value, @allow_free_text)}
            loading={@state == :submitting}
            aria-describedby={@hint_id}
          >
            {gettext("Submit choice")}
          </.button>
        </div>

        <p id={@hint_id} class="font-mono text-[length:var(--hp-text-body)] text-text-secondary">
          {editing_hint(@state, @selected_option_id, @free_text_value, @allow_free_text, @agent)}
        </p>
      </div>
    </div>
    """
  end

  defp can_submit?(selected_option_id, _free_text_value, _allow_free_text)
       when is_binary(selected_option_id) and selected_option_id != "",
       do: true

  defp can_submit?(_selected_option_id, free_text_value, true),
    do: is_binary(free_text_value) and String.trim(free_text_value) != ""

  defp can_submit?(_selected_option_id, _free_text_value, _allow_free_text), do: false

  defp editing_hint(:submitting, _selected, _free_text, _allow_free_text, _agent),
    do: gettext("Recording your choice…")

  defp editing_hint(_state, selected, _free_text, _allow_free_text, agent)
       when is_binary(selected) and selected != "" do
    waiting_hint(agent)
  end

  defp editing_hint(_state, _selected, _free_text, true, _agent) do
    gettext("Choose an option, or write your own answer, to enable Submit choice.")
  end

  defp editing_hint(_state, _selected, _free_text, false, _agent) do
    gettext("Choose an option to enable Submit choice.")
  end

  defp waiting_hint(nil), do: gettext("Waiting for this choice.")
  defp waiting_hint(agent), do: gettext("%{agent} is waiting for this choice.", agent: agent)

  defp decided_label(selected_option_ids, free_text, options) do
    case selected_option_ids do
      [_ | _] = ids ->
        ids
        |> Enum.map(&option_label(&1, options))
        |> Enum.join(", ")

      _ ->
        free_text || gettext("(no answer recorded)")
    end
  end

  defp option_label(id, options) do
    case Enum.find(options, &(&1.id == id)) do
      nil -> id
      option -> option.label
    end
  end

  defp decided_hint(nil, at), do: gettext("Chosen at %{time}.", time: format_time(at))

  defp decided_hint(decided_by, at) do
    gettext("Chosen by %{actor} at %{time}.",
      actor: actor_label(decided_by),
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
