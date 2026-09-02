defmodule HumanportWeb.InboxLive do
  @moduledoc """
  UI-01/UI-16 — the open-requests inbox at `/requests`. Renders
  `HumanPort.UI.PaneHeader` in root form and a plain list of rows for now —
  `RequestCard`, the filter tabs, the empty states and the keyboard model are
  plan 01-05. Live updates (D-15) and the tab-title count (D-18) are plan
  01-02 Task 3.
  """

  use HumanportWeb, :live_view

  alias Humanport.Requests

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_requests(socket)}
  end

  defp load_requests(socket) do
    {:ok, requests} =
      Requests.list_requests(query: [filter: [state: :pending], sort: [inserted_at: :desc]])

    assign(socket, requests: requests, open_count: length(requests))
  end

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
