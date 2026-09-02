defmodule HumanportWeb.RequestLive do
  @moduledoc """
  UI-02/UI-07 — the request detail view at `/requests/:id`. Renders the
  title, the agent label (always unverified in Phase 1, D-12), and the
  decision block. `HumanPort.UI.AnswerCard` is the only path that submits a
  free-text answer (D-17) — this LiveView never builds a changeset or decides
  a transition itself; `answer_submit` calls `Humanport.Requests.answer/3`
  directly, the same domain function PROTO-01's controller calls, so both
  surfaces get the same transaction-wrapped audit write.
  """

  use HumanportWeb, :live_view

  alias Humanport.Requests

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Requests.get_request(id) do
      {:ok, request} ->
        {:ok,
         assign(socket,
           request: request,
           answer_value: "",
           answer_state: if(request.completed_at, do: :decided, else: :editing)
         )}

      {:error, _error} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Request not found."))
         |> push_navigate(to: ~p"/requests")}
    end
  end

  @impl true
  def handle_event("answer_change", %{"answer" => value}, socket) do
    {:noreply, assign(socket, :answer_value, value)}
  end

  def handle_event("answer_submit", %{"answer" => value}, socket) do
    socket = assign(socket, :answer_state, :submitting)

    case Requests.answer(socket.assigns.request, value, socket.assigns.actor) do
      {:ok, answered} ->
        {:noreply, assign(socket, request: answered, answer_state: :decided)}

      {:error, _error} ->
        {:noreply,
         socket
         |> assign(:answer_state, :editing)
         |> put_flash(:error, gettext("Your answer could not be saved."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-6 p-4">
      <h1 class="font-mono text-[length:var(--hp-text-title)] font-extrabold tracking-[-.02em] text-text-primary">
        {@request.title}
      </h1>

      <p class="font-mono text-[length:var(--hp-text-meta)]">
        <span class="text-text-faint underline decoration-dotted">
          {@request.requester_label}
        </span>
        <span class="text-text-primary">[{gettext("unverified")}]</span>
      </p>

      <.answer_card
        :if={@request.type == :ask}
        id={"answer-#{@request.id}"}
        state={@answer_state}
        value={@answer_value}
        answer={@request.answer}
        answered_by={@request.decided_by}
        answered_at={@request.completed_at}
      />

      <p
        :if={@request.type != :ask}
        class="font-mono text-[length:var(--hp-text-body)] text-text-secondary"
      >
        {gettext("This request type cannot be answered yet.")}
      </p>
    </div>
    """
  end
end
