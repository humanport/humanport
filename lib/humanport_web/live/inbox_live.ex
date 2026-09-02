defmodule HumanportWeb.InboxLive do
  @moduledoc """
  UI-01 — the open-requests inbox at `/requests`. Renders `HumanPort.UI.PaneHeader`
  in root form with the open count in its stats slot, `HumanPort.UI.FilterTabs`
  with exactly the two tabs (D-16), and a `listbox` of `HumanPort.UI.RequestCard`
  options.

  **The keyboard model is the whole navigation model, not an enhancement.** `j`/
  `k` and the arrow keys move the selection, `Enter` opens the selected request;
  the complete answer flow is reachable with a keyboard alone. `←`/`→` on the
  tablist switch between `open` and `answered`.

  D-15 — subscribes to the firehose topic `"requests"` on connect and re-reads
  the database on every broadcast; the message is never trusted as the fact,
  only as the hint that something changed. Re-reads both the active tab's list
  AND the open count on every load, so a request answered in another tab
  visibly moves from `open` to `answered` without a reload. D-18 — the open
  count (never the active tab's count) drives the browser tab title directly
  via `:page_title`, omitted entirely at zero rather than rendered as `(0)`.

  **No response can be submitted from this page (D-17).** There is no
  `phx-click`/`phx-submit` anywhere in this module bound to `approve`,
  `reject`, `answer`, or `respond` — a grep gate in the plan's own `<verify>`
  enforces this. §54.8 binds an approval to the content the human was actually
  shown; approving from a list means approving without having seen it.
  """

  use HumanportWeb, :live_view

  alias Humanport.Requests

  @topic "requests"
  @arrow_keys ~w(ArrowLeft ArrowRight)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: HumanportWeb.Endpoint.subscribe(@topic)

    {:ok,
     socket
     |> assign(active_tab: :open, selected_index: 0)
     |> load_requests()}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: @topic}, socket) do
    {:noreply, load_requests(socket)}
  end

  @impl true
  def handle_event("filter_select", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(active_tab: tab_atom(tab), selected_index: 0)
     |> load_requests()}
  end

  def handle_event("filter_arrow", %{"key" => key}, socket) when key in @arrow_keys do
    other_tab = if socket.assigns.active_tab == :open, do: :answered, else: :open

    {:noreply,
     socket
     |> assign(active_tab: other_tab, selected_index: 0)
     |> load_requests()}
  end

  def handle_event("filter_arrow", _params, socket), do: {:noreply, socket}

  def handle_event("select_request", %{"index" => index}, socket) do
    case Enum.at(socket.assigns.requests, String.to_integer(index)) do
      nil -> {:noreply, socket}
      request -> {:noreply, push_navigate(socket, to: ~p"/requests/#{request.id}")}
    end
  end

  def handle_event("inbox_key", %{"key" => key}, socket) do
    {:noreply, handle_inbox_key(key, socket)}
  end

  defp handle_inbox_key(key, socket) when key in ["ArrowDown", "j"] do
    max_index = max(length(socket.assigns.requests) - 1, 0)
    assign(socket, :selected_index, min(socket.assigns.selected_index + 1, max_index))
  end

  defp handle_inbox_key(key, socket) when key in ["ArrowUp", "k"] do
    assign(socket, :selected_index, max(socket.assigns.selected_index - 1, 0))
  end

  defp handle_inbox_key("Enter", socket) do
    case Enum.at(socket.assigns.requests, socket.assigns.selected_index) do
      nil -> socket
      request -> push_navigate(socket, to: ~p"/requests/#{request.id}")
    end
  end

  defp handle_inbox_key(_key, socket), do: socket

  defp tab_atom("answered"), do: :answered
  defp tab_atom(_), do: :open

  defp load_requests(socket) do
    {:ok, open_requests} = Requests.list_open_requests()

    requests =
      case socket.assigns.active_tab do
        :open ->
          open_requests

        :answered ->
          {:ok, answered} = Requests.list_answered_requests()
          answered
      end

    socket
    |> assign(requests: requests, open_count: length(open_requests))
    |> assign(:page_title, page_title(length(open_requests)))
  end

  defp page_title(0), do: "humanport"
  defp page_title(n), do: "(#{n}) humanport"

  defp result_token(%{type: :ask}), do: "ok"
  defp result_token(%{type: :approve, decision: :approved}), do: "ok"
  defp result_token(%{type: :approve, decision: :rejected}), do: "no"
  defp result_token(_request), do: nil

  defp decided_by_label(%{decided_by: %{"label" => label}}) when is_binary(label), do: label
  defp decided_by_label(%{decided_by: %{label: label}}) when is_binary(label), do: label
  defp decided_by_label(_request), do: nil

  defp waited_label(request) do
    seconds = DateTime.diff(DateTime.utc_now(), request.inserted_at)
    minutes = div(seconds, 60)

    cond do
      minutes < 1 -> "<1m"
      minutes < 60 -> "#{minutes}m"
      true -> "#{div(minutes, 60)}h"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.pane_header form={:root}>
        <:stats>{@open_count} {gettext("open")}</:stats>
      </.pane_header>

      <.filter_tabs active={@active_tab} />

      <div
        id="inbox-listbox"
        role="listbox"
        tabindex="0"
        aria-label={gettext("Requests")}
        aria-activedescendant={"request-card-#{@selected_index}"}
        phx-keydown="inbox_key"
        class="flex flex-col outline-none focus-visible:ring-2 focus-visible:ring-focus-ring"
      >
        <.request_card
          :for={{request, index} <- Enum.with_index(@requests)}
          index={index}
          title={request.title}
          agent={request.requester_label}
          type={request.type}
          target={subject_label(request)}
          risk_level={request.risk}
          reversible={request.reversible}
          state={request.state}
          waited={@active_tab == :open && waited_label(request)}
          selected={index == @selected_index}
          answered={@active_tab == :answered}
          result={@active_tab == :answered && result_token(request)}
          decided_by={@active_tab == :answered && decided_by_label(request)}
        />

        <.empty
          :if={@requests == [] and @active_tab == :open}
          title={gettext("Nothing is waiting on you")}
          description={
            gettext("New requests appear here the moment an agent creates one. No reload needed.")
          }
        />

        <.empty
          :if={@requests == [] and @active_tab == :answered}
          title={gettext("Nothing answered yet")}
          description={gettext("Requests you have answered move here.")}
        />
      </div>
    </Layouts.app>
    """
  end

  defp subject_label(%{subject: %{label: label}}) when is_binary(label), do: label
  defp subject_label(_request), do: nil
end
