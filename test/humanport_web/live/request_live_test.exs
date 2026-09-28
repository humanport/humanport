defmodule HumanportWeb.Live.RequestLiveTest do
  @moduledoc """
  Plan 01-05 Task 3 — the request detail renders the seven blocks in order
  and ending in the decision block, and is the only place a response can be
  submitted (D-17). The short-id assertions are checked against fixed
  UUIDs, not prose — see `HumanportWeb.RequestLive.short_id/1`'s moduledoc.
  """

  use HumanportWeb.ConnCase, async: false

  import Humanport.Fixtures

  # `Humanport.UnsandboxedCase` tests (e.g. the CORE-01 durability test) write
  # real, un-rolled-back rows into the test database by design — this file's
  # own sandboxed transaction still sees them. Start every test from a known
  # empty table; the delete is rolled back with the rest of the transaction
  # at the end of each test.
  setup do
    Humanport.Repo.delete_all(Humanport.Requests.HumanRequest)
    :ok
  end

  describe "short id derivation (D-20) — asserted against fixed UUIDs" do
    test "the short id is the LAST five hex characters, hyphens removed and lowercased" do
      assert HumanportWeb.RequestLive.short_id("01930b8c-7f21-7c3d-9a4e-b7c29d4a7b2c") == "a7b2c"
    end

    test "two UUIDs sharing the same millisecond-timestamp prefix produce different short ids" do
      # Same leading ~48 bits (the millisecond timestamp per RFC 9562), different tail.
      id_a = "01930b8c-7f21-7c3d-9a4e-b7c29d4a7b2c"
      id_b = "01930b8c-7f21-7c3d-9a4e-000000000000"

      assert HumanportWeb.RequestLive.short_id(id_a) != HumanportWeb.RequestLive.short_id(id_b)

      # A front-derived implementation (first five hex chars) would collide here —
      # both ids share the same leading "01930".
      refute String.slice(String.replace(id_a, "-", ""), 0, 5) ==
               HumanportWeb.RequestLive.short_id(id_a)
    end
  end

  describe "the seven blocks, in order, omitted when absent" do
    test "renders title, agent badge, meta list, and the pane header short id", %{conn: conn} do
      request = request_fixture(%{title: "Deploy release 1.4"})
      short = HumanportWeb.RequestLive.short_id(request.id)

      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ "Deploy release 1.4"
      assert html =~ "req/#{short}"
      assert html =~ "unverified"
      assert html =~ "state:"
      assert html =~ "pending"
      assert html =~ "type:"
      assert html =~ "ask"
    end

    test "the risk block renders the spelled form and sigil when stated", %{conn: conn} do
      request = request_fixture(%{title: "Risky", risk: :high, reversible: "false"})

      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")
      assert html =~ "[!!!]"
      assert html =~ "risk:high 3/3 · reversible:false"
    end

    test "the risk block is absent entirely when no risk was stated", %{conn: conn} do
      request = request_fixture(%{title: "No risk stated"})

      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")
      refute html =~ "[!!!]"
      refute html =~ "[!!·]"
      refute html =~ "[!··]"
    end

    test "the context block is omitted entirely when there is no context", %{conn: conn} do
      request = request_fixture(%{title: "No context"})
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")
      refute html =~ "<pre"
    end

    test "the context block renders flat context as aligned rows", %{conn: conn} do
      request = request_fixture(%{title: "Flat context", context: %{"pr" => "42"}})
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")
      assert html =~ "pr"
      assert html =~ "42"
    end

    test "the timeline lists the request's audit events as sentences", %{conn: conn} do
      request = request_fixture(%{title: "Timeline me"})
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")
      assert html =~ "created this request"
    end

    test "the timeline renders the acting actor's verified state through actor_identity, not a bare label",
         %{conn: conn} do
      request =
        request_fixture(%{
          title: "Created by a service token",
          requester_label: "claude-code/gsd",
          actor: %Humanport.Actors.Actor{
            type: :service,
            label: "agent-service-token-1.access",
            verified?: true,
            method: :service_token
          }
        })

      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      # The header names the RUN (client-supplied, always unverified per
      # D-12) — the timeline names the CREDENTIAL that actually authenticated
      # the call. Same request, two distinguishable identities, per the
      # assumption-delta decision this plan carries.
      assert html =~ "claude-code/gsd"
      assert html =~ "agent-service-token-1.access"
      assert html =~ "verified"
      assert html =~ "service_token"
    end
  end

  describe "the approval asymmetry — approve request" do
    test "approve stays disabled until the confirmation token is typed", %{conn: conn} do
      request = request_fixture(%{title: "Ship it", type: :approve})
      short = HumanportWeb.RequestLive.short_id(request.id)

      {:ok, view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ "Type approve #{short} to unlock Approve."
      assert has_element?(view, "button[disabled]", "Approve")
    end

    test "the comparison is case-insensitive and whitespace-trimmed", %{conn: conn} do
      request = request_fixture(%{title: "Ship it", type: :approve})
      short = HumanportWeb.RequestLive.short_id(request.id)

      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      view
      |> form("#approval-#{request.id}-form", %{
        "confirm" => "  APPROVE #{String.upcase(short)}  "
      })
      |> render_change()

      assert has_element?(view, "button:not([disabled])", "Approve")
    end

    test "the hint sentence is wired as aria-describedby with a per-instance id", %{conn: conn} do
      request = request_fixture(%{title: "Ship it", type: :approve})
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ "aria-describedby=\"approval-#{request.id}-approval-hint\""
    end

    test "submitting shows submitting then decided, naming who and when", %{conn: conn} do
      request = request_fixture(%{title: "Ship it", type: :approve})
      short = HumanportWeb.RequestLive.short_id(request.id)

      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      view
      |> form("#approval-#{request.id}-form", %{"confirm" => "approve #{short}"})
      |> render_change()

      html =
        view
        |> element("button", "Approve")
        |> render_click()

      assert html =~ "Approved"
      assert html =~ "owner@localhost"
    end

    test "reject submits on one press with no confirmation dialog", %{conn: conn} do
      request = request_fixture(%{title: "Ship it", type: :approve})
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      html =
        view
        |> element("button", "Reject")
        |> render_click()

      assert html =~ "Rejected"
      refute has_element?(view, "[role=dialog]")
    end

    test "a second submission against an already-decided request shows the conflict copy", %{
      conn: conn
    } do
      request = request_fixture(%{title: "Ship it", type: :approve})
      short = HumanportWeb.RequestLive.short_id(request.id)

      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      view
      |> form("#approval-#{request.id}-form", %{"confirm" => "approve #{short}"})
      |> render_change()

      # A concurrent responder decides the request via a raw update that
      # bypasses Ash (and therefore never broadcasts) — the LiveView's own
      # subscription never fires, so its in-memory state stays :unlocked,
      # exactly the stale-client scenario CORE-07 defends against.
      import Ecto.Query

      Humanport.Repo.update_all(
        from(r in Humanport.Requests.HumanRequest, where: r.id == ^request.id),
        set: [state: "rejected", decision: "rejected", completed_at: DateTime.utc_now()]
      )

      html =
        view
        |> element("button", "Approve")
        |> render_click()

      assert html =~ "was already answered"
      assert html =~ "was not recorded"
      # The card itself now reflects the fresh, authoritative outcome.
      assert html =~ "Rejected"
    end
  end

  describe "the free-text answer — ask request" do
    test "send stays disabled while the text is empty and enables once it is not", %{conn: conn} do
      request = request_fixture(%{title: "Answer me", type: :ask})
      {:ok, view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ "Write an answer to enable Send answer."

      view
      |> form("#answer-#{request.id}-form", %{"answer" => "Use the second entry."})
      |> render_change()

      assert has_element?(view, "button:not([disabled])", "Send answer")
    end

    test "submitting the answer shows the decided state", %{conn: conn} do
      request = request_fixture(%{title: "Answer me", type: :ask})
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      html =
        view
        |> form("#answer-#{request.id}-form", %{"answer" => "Use the second entry."})
        |> render_submit()

      assert html =~ "Use the second entry."
      assert html =~ "owner@localhost"
    end
  end

  describe "the choice — choose request (CORE-04, 02.1-05-PLAN.md Task 2)" do
    test "no option is pre-selected on first render, including the recommended one", %{
      conn: conn
    } do
      request = choose_request_fixture(%{title: "Pick a path"})
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      # Asserted against the rendered markup, not the socket's assigns —
      # the assign could be empty while the template still emitted a
      # `checked` attribute derived from `recommended`.
      refute html =~ "checked"
      assert html =~ "Option A"
      assert html =~ "Option B"
      assert html =~ "suggested"
    end

    test "submit stays disabled until a selection is made", %{conn: conn} do
      request = choose_request_fixture(%{title: "Pick a path"})
      {:ok, view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ "Choose an option to enable Submit choice."
      assert has_element?(view, "button[disabled]", "Submit choice")

      view
      |> form("#choice-#{request.id}-form", %{"selected_option_id" => "opt-a"})
      |> render_change()

      assert has_element?(view, "button:not([disabled])", "Submit choice")
    end

    test "no handler submits on change, on blur, or on a timer", %{conn: conn} do
      request = choose_request_fixture(%{title: "Pick a path"})
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      refute html =~ ~s(phx-submit="choice_submit")
    end

    test "selecting an option and pressing submit records a one-element selection list, and the timeline shows a sentence for the choice",
         %{conn: conn} do
      request = choose_request_fixture(%{title: "Pick a path"})
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      view
      |> form("#choice-#{request.id}-form", %{"selected_option_id" => "opt-a"})
      |> render_change()

      html =
        view
        |> element("button", "Submit choice")
        |> render_click()

      assert html =~ "Option A"
      assert html =~ "owner@localhost"
      assert html =~ "chose an option"

      {:ok, chosen} = Humanport.Requests.get_request(request.id)
      assert chosen.selected_option_ids == ["opt-a"]
    end

    test "on a request whose free-text flag is true, a text field appears and free text can be submitted with no selection",
         %{conn: conn} do
      request = choose_request_fixture(%{title: "Free text allowed", allow_free_text: true})
      {:ok, view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ "Or write your own answer"

      view
      |> form("#choice-#{request.id}-form", %{"free_text" => "Neither of these."})
      |> render_change()

      html =
        view
        |> element("button", "Submit choice")
        |> render_click()

      assert html =~ "Neither of these."

      {:ok, chosen} = Humanport.Requests.get_request(request.id)
      assert chosen.selected_option_ids == []
      assert chosen.answer == "Neither of these."
    end

    test "on a request whose free-text flag is false, no text field appears", %{conn: conn} do
      request = choose_request_fixture(%{title: "No free text"})
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      refute html =~ "Or write your own answer"
    end

    test "a losing concurrent submission surfaces the conflict message and the refreshed state",
         %{
           conn: conn
         } do
      request = choose_request_fixture(%{title: "Race"})
      {:ok, view, _html} = live(conn, ~p"/requests/#{request.id}")

      view
      |> form("#choice-#{request.id}-form", %{"selected_option_id" => "opt-a"})
      |> render_change()

      # A concurrent responder decides the request via a raw update that
      # bypasses Ash (and therefore never broadcasts) — the same stale-client
      # scenario the approval asymmetry test above exercises.
      import Ecto.Query

      Humanport.Repo.update_all(
        from(r in Humanport.Requests.HumanRequest, where: r.id == ^request.id),
        set: [state: "answered", selected_option_ids: ["opt-b"], completed_at: DateTime.utc_now()]
      )

      html =
        view
        |> element("button", "Submit choice")
        |> render_click()

      assert html =~ "was already answered"
      assert html =~ "was not recorded"
      assert html =~ "Option B"
    end
  end

  describe "error paths" do
    test "an unknown identifier renders the not-found copy with a route back to the inbox", %{
      conn: conn
    } do
      {:error, {:live_redirect, %{to: to}}} =
        live(conn, ~p"/requests/01930b8c-0000-0000-0000-000000000000")

      assert to == ~p"/requests"
    end

    test "an escalate request renders the not-implemented copy and no response control" do
      # 02.1-05-PLAN.md Task 2 — narrowed from `choose or escalate` to
      # `escalate` alone: `choose` is now answerable via `ChoiceCard`.
      # D-06 rejects creating an escalate request explicitly — build one
      # directly against the resource to exercise the defensive render for a
      # row created before that guard, or from a console.
      {:ok, request} =
        Humanport.Requests.HumanRequest
        |> Ash.Changeset.for_create(:submit, %{type: :ask, title: "will be forced"},
          actor: default_actor()
        )
        |> Ash.Changeset.force_change_attribute(:type, :escalate)
        |> Ash.create()

      conn = Phoenix.ConnTest.build_conn()
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      assert html =~ "This request type cannot be answered yet."
      refute html =~ "Approve"
      refute html =~ "Send answer"
    end
  end

  describe "no other control submits a response" do
    test "no phx-submit exists besides the answer/confirm forms", %{conn: conn} do
      request = request_fixture(%{title: "Only one path", type: :approve})
      {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")

      # ApprovalCard's confirmation input never submits on its own —
      # approving requires the explicit Approve button click.
      refute html =~ ~s(phx-submit="approve_submit")
    end
  end
end
