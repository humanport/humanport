defmodule HumanportWeb.RequestControllerTest do
  @moduledoc """
  Plan 01-04, Task 2 — approve/reject reachable over plain HTTP, and
  `HumanportWeb.FallbackController`'s contained-error mapping: the 409-vs-422
  split an agent's retry loop depends on, the D-06 not-implemented message,
  field-level detail on ordinary create validation, and the D-04/D-24
  correlation/risk round-trip. Companion to `long_poll_test.exs` (Task 1) and
  01-02's `dogfooding_loop_test.exs` (the `ask` happy path end to end).
  """

  use HumanportWeb.ConnCase, async: true

  import Humanport.Fixtures

  describe "approve/reject over plain HTTP" do
    test "approving an approve request returns 200 with a decision result", %{conn: conn} do
      request = request_fixture(%{type: :approve, title: "Deploy release 1.4 to prod?"})

      resp_conn =
        post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{"decision" => "approve"})

      body = json_response(resp_conn, 200)

      assert body["status"] == "completed"
      assert body["state"] == "approved"
      assert body["result"]["decision"] == "approved"
      assert body["result"]["decided_by"]["verified"] == false
      refute is_nil(body["result"]["decided_at"])
    end

    test "rejecting an approve request returns 200 with a decision result", %{conn: conn} do
      request = request_fixture(%{type: :approve, title: "Deploy release 1.4 to prod?"})

      resp_conn =
        post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{"decision" => "reject"})

      body = json_response(resp_conn, 200)

      assert body["status"] == "completed"
      assert body["state"] == "rejected"
      assert body["result"]["decision"] == "rejected"
      assert body["result"]["decided_by"]["verified"] == false
      refute is_nil(body["result"]["decided_at"])
    end
  end

  describe "409 vs 422 — the split an agent's retry loop depends on" do
    test "responding twice returns 200 then 409 telling the agent to stop retrying", %{
      conn: conn
    } do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})

      first_conn =
        post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{"answer" => "Use the second."})

      json_response(first_conn, 200)

      second_conn =
        post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{"answer" => "Use the first."})

      body = json_response(second_conn, 409)

      assert body["error"]["code"] == "conflict"
      assert body["error"]["message"] =~ "already answered"
    end

    test "responding twice to an approve request returns 200 then 409", %{conn: conn} do
      request = request_fixture(%{type: :approve, title: "Deploy release 1.4 to prod?"})

      first_conn =
        post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{"decision" => "approve"})

      json_response(first_conn, 200)

      second_conn =
        post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{"decision" => "reject"})

      body = json_response(second_conn, 409)
      assert body["error"]["code"] == "conflict"
    end

    test "responding to a request that does not exist returns 404", %{conn: conn} do
      missing_id = Ash.UUID.generate()

      resp_conn = post(conn, ~p"/api/v1/requests/#{missing_id}/respond", %{"answer" => "x"})
      body = json_response(resp_conn, 404)

      assert body["error"]["code"] == "not_found"
    end

    test "responding with a decision to an ask request returns 422, not 409", %{conn: conn} do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})

      resp_conn =
        post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{"decision" => "approve"})

      body = json_response(resp_conn, 422)
      assert body["error"]["code"] == "invalid"
    end

    test "responding with free text to an approve request returns 422, not 409", %{conn: conn} do
      request = request_fixture(%{type: :approve, title: "Deploy release 1.4 to prod?"})

      resp_conn = post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{"answer" => "sure"})
      body = json_response(resp_conn, 422)
      assert body["error"]["code"] == "invalid"
    end

    test "responding with an unrecognized decision value returns 422", %{conn: conn} do
      request = request_fixture(%{type: :approve, title: "Deploy release 1.4 to prod?"})

      resp_conn =
        post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{"decision" => "maybe"})

      body = json_response(resp_conn, 422)
      assert body["error"]["code"] == "invalid"
    end

    test "responding with neither answer nor decision returns 422", %{conn: conn} do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})

      resp_conn = post(conn, ~p"/api/v1/requests/#{request.id}/respond", %{})
      body = json_response(resp_conn, 422)
      assert body["error"]["code"] == "invalid"
    end
  end

  describe "D-06 — creating an unimplemented type is refused at create, never left pending forever" do
    test "creating an escalate request returns 422 naming the type", %{conn: conn} do
      for type <- ["escalate"] do
        resp_conn =
          post(conn, ~p"/api/v1/requests", %{"type" => type, "title" => "Not built yet"})

        body = json_response(resp_conn, 422)

        assert body["error"]["code"] == "not_implemented"

        assert body["error"]["message"] ==
                 "HumanPort recorded a #{type} request, but this version answers only ask, approve and choose."
      end
    end
  end

  describe "create validation — missing title, unknown type get field-level detail" do
    test "creating with a missing title returns 422 with field-level detail", %{conn: conn} do
      resp_conn = post(conn, ~p"/api/v1/requests", %{"type" => "ask"})
      body = json_response(resp_conn, 422)

      assert body["error"]["code"] == "invalid"
      assert [%{"field" => "title"} | _] = body["error"]["details"]
    end

    test "creating with an unknown type returns 422 with field-level detail", %{conn: conn} do
      resp_conn = post(conn, ~p"/api/v1/requests", %{"type" => "bogus", "title" => "x"})
      body = json_response(resp_conn, 422)

      assert body["error"]["code"] == "invalid"
      assert [%{"field" => "type"} | _] = body["error"]["details"]
    end
  end

  describe "D-04/D-24 — correlation and risk data round-trip unchanged" do
    test "source, external_correlation, risk and reversible come back exactly as sent", %{
      conn: conn
    } do
      params = %{
        "type" => "approve",
        "title" => "Deploy release 1.4 to prod?",
        "source" => "claude-code/gsd",
        "external_correlation" => "run-77",
        "risk" => "high",
        "reversible" => "manual"
      }

      created = conn |> post(~p"/api/v1/requests", params) |> json_response(201)

      assert created["source"] == "claude-code/gsd"
      assert created["external_correlation"] == "run-77"
      assert created["risk"] == "high"
      assert created["reversible"] == "manual"

      fetched = conn |> get(~p"/api/v1/requests/#{created["id"]}") |> json_response(200)

      assert fetched["source"] == "claude-code/gsd"
      assert fetched["external_correlation"] == "run-77"
      assert fetched["risk"] == "high"
      assert fetched["reversible"] == "manual"
    end

    test "risk and reversible are null when omitted, never defaulted to a stated level", %{
      conn: conn
    } do
      created =
        conn
        |> post(~p"/api/v1/requests", %{"type" => "approve", "title" => "No risk stated"})
        |> json_response(201)

      assert created["risk"] == nil
      assert created["reversible"] == nil
    end
  end
end
