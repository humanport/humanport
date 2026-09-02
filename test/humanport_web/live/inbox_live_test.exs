defmodule HumanportWeb.Live.InboxLiveTest do
  @moduledoc """
  Plan 01-02 Task 3 — D-15 live updates and D-18's tab-title count. Every
  assertion here trusts only what the LiveView re-reads from the database
  after a broadcast, never the broadcast payload itself.
  """

  use HumanportWeb.ConnCase, async: false

  import Humanport.Fixtures

  alias Humanport.Requests

  test "a newly created request appears without a reload, and the tab title carries the open count",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/requests")
    assert page_title(view) == "humanport"

    request_fixture(%{title: "Ship the release notes"})

    assert render(view) =~ "Ship the release notes"
    assert page_title(view) == "(1) humanport"
  end

  test "a request answered elsewhere disappears from the open list on the next broadcast", %{
    conn: conn
  } do
    request = request_fixture(%{title: "Needs an answer"})

    {:ok, view, html} = live(conn, ~p"/requests")
    assert html =~ "Needs an answer"
    assert page_title(view) == "(1) humanport"

    {:ok, _answered} = Requests.answer(request, "done", default_actor())

    refute render(view) =~ "Needs an answer"
    assert page_title(view) == "humanport"
  end

  test "the tab title omits the count entirely at zero, never rendering (0)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/requests")
    assert page_title(view) == "humanport"
    refute page_title(view) =~ "(0)"
  end
end
