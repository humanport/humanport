defmodule HumanportWeb.DogfoodingLoopTest do
  @moduledoc """
  The Phase 1 tracer (plan 01-02, Task 2) — the whole dogfooding loop driven
  through the real HTTP and LiveView surfaces: an agent creates an `ask`
  request, the owner sees it in the inbox, opens it, answers it, and the
  agent reads the answer back. Exercises the three claims the phase rests on:
  the state change and the audit write commit in one transaction, the
  post-commit notifier drives the UI, and the published wire contract is the
  `plain-v1` shape fixed by Task 1's checkpoint decision.
  """

  use HumanportWeb.ConnCase, async: false

  alias Humanport.Repo

  @create_params %{
    "type" => "ask",
    "title" => "Which changelog entry?",
    "context" => %{"pr" => 42},
    "source" => "claude-code/gsd",
    "external_correlation" => "run-42",
    "requester_label" => "claude-code/gsd",
    "risk" => "high",
    "reversible" => "false"
  }

  test "an agent asks over plain HTTP, the owner answers in the inbox, the agent reads it back",
       %{conn: conn} do
    # 1. POST /api/v1/requests — 201, server-generated UUID, pending, null
    # result, echoes source/external_correlation/risk/reversible unchanged.
    create_conn = post(conn, ~p"/api/v1/requests", @create_params)
    created = json_response(create_conn, 201)

    id = created["id"]
    assert is_binary(id)
    assert {:ok, _} = Ecto.UUID.cast(id)
    assert created["state"] == "pending"
    assert created["status"] == "pending"
    assert created["result"] == nil
    assert created["source"] == "claude-code/gsd"
    assert created["external_correlation"] == "run-42"
    assert created["risk"] == "high"
    assert created["reversible"] == "false"

    # 2. A create omitting risk/reversible succeeds and stores both as null —
    # they are never defaulted to a level the agent did not state.
    minimal_conn =
      post(conn, ~p"/api/v1/requests", %{"type" => "ask", "title" => "No risk stated"})

    minimal_body = json_response(minimal_conn, 201)
    assert minimal_body["risk"] == nil
    assert minimal_body["reversible"] == nil

    # 3. GET returns 200 while unanswered — never 202, never 204.
    show_conn = get(conn, ~p"/api/v1/requests/#{id}")
    show_body = json_response(show_conn, 200)
    assert show_body["status"] == "pending"
    assert show_body["state"] == "pending"
    assert show_body["result"] == nil

    # 4. The inbox lists the request; the detail view renders the title, the
    # agent label rendered as unverified, and the answer card.
    {:ok, inbox_live, inbox_html} = live(conn, ~p"/requests")
    assert inbox_html =~ "Which changelog entry?"
    # Plan 01-05 replaced the tracer's per-row <a> with a role="option" div —
    # the inbox is a keyboard-operable listbox now, not a set of navigable
    # links (Enter opens the keyboard-selected option via push_navigate).
    assert has_element?(inbox_live, "[role=option]", "Which changelog entry?")

    {:ok, detail_live, detail_html} = live(conn, ~p"/requests/#{id}")
    assert detail_html =~ "Which changelog entry?"
    assert detail_html =~ "claude-code/gsd"
    assert detail_html =~ "unverified"
    assert has_element?(detail_live, "textarea[name=answer]")

    # 5. Submitting the answer form on the detail LiveView records it.
    detail_live
    |> form("#answer-#{id}-form", %{"answer" => "Use the second entry."})
    |> render_submit()

    assert render(detail_live) =~ "Use the second entry."

    # 6. GET now returns 200 with status completed, state answered, and a
    # result carrying the answer text, who answered, and when.
    answered_conn = get(conn, ~p"/api/v1/requests/#{id}")
    answered_body = json_response(answered_conn, 200)
    assert answered_body["status"] == "completed"
    assert answered_body["state"] == "answered"
    assert answered_body["result"]["answer"] == "Use the second entry."
    assert answered_body["result"]["answered_by"]["verified"] == false
    refute is_nil(answered_body["result"]["answered_at"])

    # 7. audit_events holds exactly two rows for this request, both
    # actor_verified false.
    request_id_bin = Ecto.UUID.dump!(id)

    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT event_type, previous_state, new_state, actor_verified FROM audit_events WHERE request_id = $1 ORDER BY occurred_at",
        [request_id_bin]
      )

    assert [
             ["request.created", nil, "pending", false],
             ["request.responded", "pending", "answered", false]
           ] = rows

    # 8. A raw UPDATE and a raw DELETE against audit_events each raise from
    # PostgreSQL. Each is wrapped in its own Repo.transaction/1 so the
    # sandbox savepoint absorbs the failure instead of poisoning the
    # surrounding test transaction for the second assertion.
    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.transaction(fn ->
        Repo.query!("UPDATE audit_events SET metadata = '{}' WHERE request_id = $1", [
          request_id_bin
        ])
      end)
    end

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.transaction(fn ->
        Repo.query!("DELETE FROM audit_events WHERE request_id = $1", [request_id_bin])
      end)
    end
  end

  test "creating an escalate request fails explicitly as not-implemented", %{
    conn: conn
  } do
    for type <- ["escalate"] do
      resp_conn = post(conn, ~p"/api/v1/requests", %{"type" => type, "title" => "Not built yet"})
      body = json_response(resp_conn, 422)
      assert body["error"]["code"] == "not_implemented"
    end
  end
end
