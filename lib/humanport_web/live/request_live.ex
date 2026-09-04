defmodule HumanportWeb.RequestLive do
  @moduledoc """
  UI-02/UI-07 — the request detail view at `/requests/:id`, and the **only**
  place a response can be submitted (D-17). Renders the seven blocks the
  UI-SPEC fixes, in order: title, `AgentBadge`, `RiskBadge`, `MetaList`,
  `ContextBlock`, `RequestTimeline`, the decision block. A block with no
  data is omitted entirely rather than rendered empty.

  **The short id is the LAST five hex characters of the UUID**, hyphens
  removed, lowercased (D-20) — never the first five. The primary key is a
  UUIDv7 whose leading bits are a millisecond timestamp; a token taken from
  the front would be shared by every request created in the same ~3.1-day
  window, which is the exact collision this mechanism exists to prevent.
  The same short id is what `PaneHeader` already displays, so the
  confirmation token is legible on screen rather than guessable from memory.

  Subscribes to its own per-request topic `"request:<id>"` on connect
  (D-15). `handle_info/2` re-reads from the database and re-renders — the
  broadcast payload is never trusted, only the re-read is (same rule plan
  01-04's long-poll depends on).

  This LiveView never builds a changeset or decides a transition itself —
  `answer_submit`/`approve_submit`/`reject_submit` call
  `Humanport.Requests.answer/3` / `approve/2` / `reject/2` directly, the
  same domain functions the plain-HTTP surface calls, so every surface gets
  the same transaction-wrapped audit write.
  """

  use HumanportWeb, :live_view

  alias Humanport.Requests

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Requests.get_request(id) do
      {:ok, request} ->
        if connected?(socket), do: HumanportWeb.Endpoint.subscribe("request:#{id}")

        {:ok,
         socket
         |> assign(
           confirm_value: "",
           answer_value: "",
           choice_selected_option_id: nil,
           choice_free_text_value: ""
         )
         |> load_request(request)}

      {:error, _error} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Request not found."))
         |> push_navigate(to: ~p"/requests")}
    end
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: "request:" <> _id}, socket) do
    case Requests.get_request(socket.assigns.request.id) do
      {:ok, request} -> {:noreply, load_request(socket, request)}
      {:error, _error} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("answer_change", %{"answer" => value}, socket) do
    {:noreply, assign(socket, :answer_value, value)}
  end

  def handle_event("answer_submit", %{"answer" => value}, socket) do
    socket = assign(socket, :answer_state, :submitting)

    case Requests.answer(socket.assigns.request, value, socket.assigns.actor) do
      {:ok, answered} -> {:noreply, load_request(socket, answered)}
      {:error, error} -> {:noreply, handle_response_error(socket, error, :answer_state, :editing)}
    end
  end

  def handle_event("confirm_change", %{"confirm" => value}, socket) do
    socket = assign(socket, :confirm_value, value)
    {:noreply, assign(socket, :decision_state, lock_state(socket))}
  end

  def handle_event("approve_submit", _params, socket) do
    socket = assign(socket, :decision_state, :submitting)

    case Requests.approve(socket.assigns.request, socket.assigns.actor) do
      {:ok, approved} ->
        {:noreply, load_request(socket, approved)}

      {:error, error} ->
        {:noreply, handle_response_error(socket, error, :decision_state, lock_state(socket))}
    end
  end

  def handle_event("reject_submit", _params, socket) do
    socket = assign(socket, :decision_state, :submitting)

    case Requests.reject(socket.assigns.request, socket.assigns.actor) do
      {:ok, rejected} ->
        {:noreply, load_request(socket, rejected)}

      {:error, error} ->
        {:noreply, handle_response_error(socket, error, :decision_state, lock_state(socket))}
    end
  end

  # CORE-04 — `ChoiceCard`'s own two handlers. `choice_change` records the
  # form's current selection/free-text into the socket; nothing here
  # submits anything. `choice_submit` is the only path that calls
  # `Humanport.Requests.choose/3` — never a changeset, exactly the rule this
  # module's own moduledoc already states for the other three decisions.
  def handle_event("choice_change", params, socket) do
    {:noreply,
     assign(socket,
       choice_selected_option_id: Map.get(params, "selected_option_id"),
       choice_free_text_value: Map.get(params, "free_text", "")
     )}
  end

  def handle_event("choice_submit", _params, socket) do
    socket = assign(socket, :choice_state, :submitting)
    selection = build_choice_selection(socket.assigns)

    case Requests.choose(socket.assigns.request, selection, socket.assigns.actor) do
      {:ok, chosen} ->
        {:noreply, load_request(socket, chosen)}

      {:error, error} ->
        {:noreply, handle_response_error(socket, error, :choice_state, :editing)}
    end
  end

  # A selection, when one was made, always wins over free text — the card
  # never sends both, so a reader of the result can tell which happened by
  # which field came back populated (locked decision 4).
  defp build_choice_selection(%{choice_selected_option_id: id}) when is_binary(id) and id != "" do
    %{selected_option_ids: [id]}
  end

  defp build_choice_selection(assigns) do
    free_text =
      case assigns[:choice_free_text_value] do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: nil, else: value

        _ ->
          nil
      end

    %{selected_option_ids: [], free_text: free_text}
  end

  # ---- request/state loading -------------------------------------------

  defp load_request(socket, request) do
    {:ok, events} = Humanport.Audit.list_events_for_request(request.id)
    short = short_id(request.id)
    token = confirm_token(short)
    confirm_value = socket.assigns[:confirm_value] || ""

    decision_state =
      cond do
        request.completed_at -> :decided
        token_matches?(confirm_value, token) -> :unlocked
        true -> :locked
      end

    assign(socket,
      request: request,
      short_id: short,
      confirm_token: token,
      events: timeline_events(events),
      answer_state: if(request.completed_at, do: :decided, else: :editing),
      decision_state: decision_state,
      choice_state: if(request.completed_at, do: :decided, else: :editing)
    )
  end

  defp lock_state(socket) do
    if token_matches?(socket.assigns.confirm_value, socket.assigns.confirm_token) do
      :unlocked
    else
      :locked
    end
  end

  # ---- error paths (conflict, save-failure) ------------------------------

  defp handle_response_error(socket, error, state_key, fallback_state) do
    if conflict_error?(error) do
      case Requests.get_request(socket.assigns.request.id) do
        {:ok, fresh} ->
          socket
          |> load_request(fresh)
          |> put_flash(:error, conflict_message(fresh))

        {:error, _error} ->
          socket
          |> assign(state_key, fallback_state)
          |> put_flash(:error, gettext("This request was already answered."))
      end
    else
      socket
      |> assign(state_key, fallback_state)
      |> put_flash(
        :error,
        gettext("The connection to the server dropped. Nothing was recorded — try again.")
      )
    end
  end

  defp conflict_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.StaleRecord{} -> true
      %AshStateMachine.Errors.NoMatchingTransition{} -> true
      _ -> false
    end)
  end

  defp conflict_error?(_error), do: false

  defp conflict_message(request) do
    gettext(
      "This request was already answered. %{actor} answered it at %{time}. Your response was not recorded.",
      actor: actor_label(request.decided_by),
      time: format_time(request.completed_at)
    )
  end

  # ---- short id / confirmation token (D-20) -----------------------------

  @doc """
  D-20 — the request's short id: the LAST five hex characters of its UUID,
  hyphens removed, lowercased. Never the first five — the primary key is a
  UUIDv7 whose leading ~48 bits are a millisecond timestamp (RFC 9562), so a
  front-derived token would collide across every request created in the
  same ~3.1-day window. Public so this derivation can be asserted directly
  against fixed UUIDs in tests, independent of a live request's real id.
  """
  def short_id(id) do
    id
    |> String.replace("-", "")
    |> String.downcase()
    |> String.slice(-5, 5)
  end

  defp confirm_token(short), do: "approve " <> short

  defp token_matches?(value, expected), do: normalize(value) == normalize(expected)

  defp normalize(nil), do: ""
  defp normalize(str) when is_binary(str), do: str |> String.trim() |> String.downcase()

  # ---- timeline (block 6) -------------------------------------------------

  defp timeline_events([]), do: []

  defp timeline_events(events) do
    last_index = length(events) - 1

    events
    |> Enum.with_index()
    |> Enum.map(fn {event, index} ->
      %{time: event.occurred_at, text: event_sentence(event), current: index == last_index}
    end)
  end

  # D-04 (02-02-PLAN.md Task 2) — renders the acting actor through
  # `<.actor_identity>` with its own `verified?`/`method`, instead of
  # interpolating a bare `actor_label` string. This is what makes the
  # credential axis visible in the timeline at all: a bare label cannot
  # say whether it was verified or how, so a service-token-created request
  # would otherwise show the SAME plain name in both the header
  # (unverified run label) and the timeline (verified credential), with
  # nothing distinguishing the two. `assigns = %{...}; ~H"""..."""` is a
  # small function-component pattern — the sentence text is data
  # (`event.event_type`-keyed) but the actor rendering itself needs
  # `<.actor_identity>`'s own markup, which a plain `gettext/2` string
  # cannot produce.
  defp event_sentence(%{event_type: "request.created"} = event),
    do: actor_identity_sentence(event, gettext("created this request."))

  defp event_sentence(%{event_type: "request.responded"} = event),
    do: actor_identity_sentence(event, gettext("answered it."))

  defp event_sentence(%{event_type: "request.approved"} = event),
    do: actor_identity_sentence(event, gettext("approved it."))

  defp event_sentence(%{event_type: "request.rejected"} = event),
    do: actor_identity_sentence(event, gettext("rejected it."))

  defp event_sentence(%{event_type: "request.chosen"} = event),
    do: actor_identity_sentence(event, gettext("chose an option."))

  defp event_sentence(event), do: event.event_type

  defp actor_identity_sentence(event, action_text) do
    assigns = %{
      name: event.actor_label || gettext("unknown"),
      verified: event.actor_verified,
      method: event.actor_method,
      action_text: action_text
    }

    ~H"""
    <.actor_identity name={@name} verified={@verified} method={@method} />
    {@action_text}
    """
  end

  # ---- meta list (block 4) -------------------------------------------------

  defp meta_items(request) do
    [
      %{key: "state", value: to_string(request.state), tone: :default},
      %{key: "waited", value: waited_value(request), tone: :default},
      %{key: "type", value: to_string(request.type), tone: :default},
      %{key: "source", value: request.source, tone: :default},
      %{key: "external_correlation", value: request.external_correlation, tone: :default},
      %{key: "subject", value: subject_value(request), tone: :default}
    ]
  end

  defp waited_value(request) do
    ends_at = request.completed_at || DateTime.utc_now()
    seconds = DateTime.diff(ends_at, request.inserted_at)
    minutes = div(seconds, 60)

    cond do
      minutes < 1 -> "<1m"
      minutes < 60 -> "#{minutes}m"
      minutes < 1440 -> "#{div(minutes, 60)}h"
      true -> "#{div(minutes, 1440)}d"
    end
  end

  defp subject_value(%{subject: %{type: type, label: label}})
       when is_binary(type) and is_binary(label),
       do: "#{type} · #{label}"

  defp subject_value(_request), do: nil

  # ---- context block (block 5) ---------------------------------------------

  defp context_rows(context) when is_map(context) and map_size(context) > 0 do
    if flat_context?(context) do
      Enum.map(context, fn {k, v} -> {to_string(k), to_string(v)} end)
    end
  end

  defp context_rows(_context), do: nil

  defp context_text(context) when is_map(context) and map_size(context) > 0 do
    unless flat_context?(context), do: Jason.encode!(context, pretty: true)
  end

  defp context_text(_context), do: nil

  defp flat_context?(context),
    do: Enum.all?(Map.values(context), &(not is_map(&1) and not is_list(&1)))

  # ---- shared actor/time formatting -----------------------------------------

  defp actor_label(%{"label" => label}) when is_binary(label), do: label
  defp actor_label(%{label: label}) when is_binary(label), do: label
  defp actor_label(_actor), do: gettext("unknown")

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_time(other), do: to_string(other)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.pane_header form={:detail} short_id={@short_id}></.pane_header>

      <div class="flex flex-col gap-6 p-4">
        <h1 class="font-mono text-[length:var(--hp-text-title)] font-extrabold tracking-[-.02em] text-text-primary">
          {@request.title}
        </h1>

        <.agent_badge name={@request.requester_label} verified={@request.requester_verified} />

        <.risk_badge level={@request.risk} reversible={@request.reversible} layout={:block} />

        <.meta_list items={meta_items(@request)} />

        <.context_block
          rows={context_rows(@request.context)}
          text={context_text(@request.context)}
        />

        <p
          :if={@events != []}
          class="font-mono text-[length:var(--hp-text-meta)] text-text-faint"
        >
          {gettext(
            "The name above is who asked; the name below is the credential that acted — not always the same thing."
          )}
        </p>

        <.request_timeline :if={@events != []} events={@events} />

        <.approval_card
          :if={@request.type == :approve}
          id={"approval-#{@request.id}"}
          confirm_token={@confirm_token}
          value={@confirm_value}
          state={@decision_state}
          decision={@request.decision}
          decided_by={@request.decided_by}
          decided_at={@request.completed_at}
          agent={@request.requester_label}
        />

        <.answer_card
          :if={@request.type == :ask}
          id={"answer-#{@request.id}"}
          state={@answer_state}
          value={@answer_value}
          answer={@request.answer}
          answered_by={@request.decided_by}
          answered_at={@request.completed_at}
          agent={@request.requester_label}
        />

        <.choice_card
          :if={@request.type == :choose}
          id={"choice-#{@request.id}"}
          state={@choice_state}
          options={@request.options || []}
          allow_free_text={@request.allow_free_text}
          selected_option_id={@choice_selected_option_id}
          free_text_value={@choice_free_text_value}
          selected_option_ids={@request.selected_option_ids}
          free_text={@request.answer}
          decided_by={@request.decided_by}
          decided_at={@request.completed_at}
          agent={@request.requester_label}
        />

        <div
          :if={@request.type == :escalate}
          class="flex flex-col gap-2 rounded-inner border border-border-hairline bg-surface-raised p-4 font-mono text-[length:var(--hp-text-body)]"
        >
          <p class="font-bold text-text-primary">
            {gettext("This request type cannot be answered yet.")}
          </p>
          <p class="text-text-secondary">
            {gettext(
              "HumanPort recorded a %{type} request, but this version answers only ask, approve and choose. Nothing will happen to it.",
              type: @request.type
            )}
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
