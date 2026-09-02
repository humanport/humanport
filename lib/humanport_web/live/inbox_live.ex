defmodule HumanportWeb.InboxLive do
  @moduledoc """
  UI-01/UI-16 — the open-requests inbox at `/requests`. Renders
  `HumanPort.UI.PaneHeader` in root form and a plain list of rows for now —
  `RequestCard`, the filter tabs, the empty states and the keyboard model are
  plan 01-05.

  D-15 — subscribes to the firehose topic `"requests"` on connect and
  re-reads the database on every broadcast; the message is never trusted as
  the fact, only as the hint that something changed. D-18 — the open count
  drives the browser tab title directly via `:page_title`, omitted entirely
  at zero rather than rendered as `(0)`.
  """

  use HumanportWeb, :live_view

  alias Humanport.Requests

  @topic "requests"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: HumanportWeb.Endpoint.subscribe(@topic)

    {:ok, load_requests(socket)}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: @topic}, socket) do
    {:noreply, load_requests(socket)}
  end

  defp load_requests(socket) do
    {:ok, requests} =
      Requests.list_requests(query: [filter: [state: :pending], sort: [inserted_at: :desc]])

    socket
    |> assign(requests: requests, open_count: length(requests))
    |> assign(:page_title, page_title(length(requests)))
  end

  defp page_title(0), do: "humanport"
  defp page_title(n), do: "(#{n}) humanport"

  @impl true
  def render(assigns) do
    ~H"""
    <.pane_header form={:root}>
      <:stats>{@open_count} {gettext("open")}</:stats>
    </.pane_header>
    <div
      role="listbox"
      aria-label={gettext("Open requests")}
      class="divide-y divide-border-hairline"
    >
      <.link
        :for={request <- @requests}
        navigate={~p"/requests/#{request.id}"}
        role="option"
        class="block px-4 py-3 font-mono text-[length:var(--hp-text-row)] text-text-primary hover:bg-surface-raised focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus-ring"
      >
        {request.title}
      </.link>
      <p
        :if={@requests == []}
        class="px-4 py-8 text-center font-mono text-[length:var(--hp-text-body)] text-text-secondary"
      >
        {gettext("Nothing is waiting on you")}
      </p>
    </div>
    """
  end
end
