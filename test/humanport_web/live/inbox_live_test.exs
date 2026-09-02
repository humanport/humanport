defmodule HumanportWeb.Live.InboxLiveTest do
  @moduledoc """
  Plan 01-05 Task 2 — the inbox defaults to open requests with a single
  toggle to answered ones, updates live, and is fully operable from the
  keyboard with no pointer. Every assertion here trusts only what the
  LiveView re-reads from the database after a broadcast, never the
  broadcast payload itself (matching plan 01-02's own discipline).
  """

  use HumanportWeb.ConnCase, async: false

  import Humanport.Fixtures

  alias Humanport.Requests

  # `Humanport.UnsandboxedCase` tests (e.g. the CORE-01 durability test) write
  # real, un-rolled-back rows into the test database by design — this file's
  # own sandboxed transaction still sees them. Start every test from a known
  # empty table; the delete is rolled back with the rest of the transaction
  # at the end of each test, so it never touches the permanent rows those
  # other tests rely on.
  setup do
    Humanport.Repo.delete_all(Humanport.Requests.HumanRequest)
    :ok
  end

  describe "default view and live updates (D-15, D-16, D-18)" do
    test "the inbox opens on the open tab, newest activity first", %{conn: conn} do
      request_fixture(%{title: "First request"})
      request_fixture(%{title: "Second request"})

      {:ok, _view, html} = live(conn, ~p"/requests")

      assert html =~ "First request"
      assert html =~ "Second request"

      # Newest first: "Second request" (inserted later) appears before "First request".
      {second_index, _} = :binary.match(html, "Second request")
      {first_index, _} = :binary.match(html, "First request")
      assert second_index < first_index
    end

    test "the answered tab lists terminal requests with their result", %{conn: conn} do
      ask_request = request_fixture(%{title: "Answer me", type: :ask})
      {:ok, _answered} = Requests.answer(ask_request, "42", default_actor())

      {:ok, view, _html} = live(conn, ~p"/requests")

      view |> element("[role=tab][phx-value-tab=answered]") |> render_click()

      html = render(view)
      assert html =~ "Answer me"
      assert html =~ "result:ok"
    end

    test "with no requests the matching empty-state renders for each tab", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/requests")
      assert html =~ "Nothing is waiting on you"

      view |> element("[role=tab][phx-value-tab=answered]") |> render_click()
      assert render(view) =~ "Nothing answered yet"
    end

    test "a request created while the page is open appears without a reload, and the tab title follows",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")
      assert page_title(view) == "humanport"

      request_fixture(%{title: "Ship the release notes"})

      assert render(view) =~ "Ship the release notes"
      assert page_title(view) == "(1) humanport"
    end

    test "with no open requests the tab title is bare, count omitted rather than rendered as zero",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")
      assert page_title(view) == "humanport"
      refute page_title(view) =~ "(0)"
    end

    test "a request answered elsewhere moves from open to answered without a reload", %{
      conn: conn
    } do
      request = request_fixture(%{title: "Needs an answer"})

      {:ok, view, html} = live(conn, ~p"/requests")
      assert html =~ "Needs an answer"
      assert page_title(view) == "(1) humanport"

      {:ok, _answered} = Requests.answer(request, "done", default_actor())

      refute render(view) =~ "Needs an answer"
      assert page_title(view) == "humanport"

      view |> element("[role=tab][phx-value-tab=answered]") |> render_click()
      assert render(view) =~ "Needs an answer"
    end
  end

  describe "risk notation on the row (D-24, T-01-37)" do
    test "a request that states a risk shows its sigil and spelled form", %{conn: conn} do
      request_fixture(%{title: "Risky one", risk: :high, reversible: "false"})

      {:ok, _view, html} = live(conn, ~p"/requests")
      assert html =~ "[!!!]"
      assert html =~ "risk:high 3/3 · reversible:false"
    end

    test "a request that states none shows no sigil at all, never the low one", %{conn: conn} do
      request_fixture(%{title: "No stated risk"})

      {:ok, _view, html} = live(conn, ~p"/requests")
      refute html =~ "[!··]"
      refute html =~ "[!!!]"
      refute html =~ "[!!·]"
    end
  end

  describe "keyboard navigation — the whole navigation model" do
    test "the list is a listbox of options with the selected option marked as such", %{
      conn: conn
    } do
      request_fixture(%{title: "Only request"})
      {:ok, _view, html} = live(conn, ~p"/requests")

      assert html =~ ~s(role="listbox")
      assert html =~ ~s(role="option")
      assert html =~ ~s(aria-selected="true")
    end

    test "ArrowDown/j and ArrowUp/k move the selection", %{conn: conn} do
      request_fixture(%{title: "Request A"})
      request_fixture(%{title: "Request B"})

      {:ok, view, _html} = live(conn, ~p"/requests")

      html =
        view
        |> element("#inbox-listbox")
        |> render_keydown(%{"key" => "ArrowDown"})

      assert html =~ ~s(id="request-card-1" role="option" aria-selected="true")

      html =
        view
        |> element("#inbox-listbox")
        |> render_keydown(%{"key" => "k"})

      assert html =~ ~s(id="request-card-0" role="option" aria-selected="true")
    end

    test "Enter opens the selected request", %{conn: conn} do
      request = request_fixture(%{title: "Open me"})
      {:ok, view, _html} = live(conn, ~p"/requests")

      view
      |> element("#inbox-listbox")
      |> render_keydown(%{"key" => "Enter"})

      assert_redirect(view, ~p"/requests/#{request.id}")
    end

    test "arrow keys on the tablist toggle between open and answered", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/requests")

      html =
        view
        |> element("[role=tablist]")
        |> render_keydown(%{"key" => "ArrowRight"})

      assert html =~ ~s(id="filter-tab-answered" type="button" role="tab" aria-selected="true")
    end
  end

  describe "no response can be submitted from this page (D-17)" do
    test "no phx-click or phx-submit anywhere on the page decides a response", %{conn: conn} do
      request_fixture(%{title: "Decide nothing here", type: :approve})
      {:ok, _view, html} = live(conn, ~p"/requests")

      refute html =~ ~s(phx-click="approve")
      refute html =~ ~s(phx-click="reject")
      refute html =~ ~s(phx-click="answer")
      refute html =~ ~s(phx-submit="respond")
    end
  end
end
