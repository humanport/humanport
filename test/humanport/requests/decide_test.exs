defmodule Humanport.Requests.DecideTest do
  @moduledoc """
  CORE-03 — `approve`/`reject` as real decisions. `Requests.approve/2` and
  `reject/2` mirror `answer/3`'s shape exactly (Task 1, plan 01-03): each
  writes its own §23 audit event inside the same `Ash.transaction/3` as the
  state change, guards the type/action pairing *before* the transaction
  opens (a caller error, not a race — the request's `type` never changes),
  and D-06's not-implemented rejection for `choose`/`escalate` leaves
  neither a row nor an audit event behind.
  """

  use Humanport.DataCase, async: true

  import Humanport.Fixtures

  alias Humanport.Requests

  defp audit_rows(request_id) do
    # Schemaless query — Ecto can't infer that `request_id` is a `:uuid`
    # column, so the raw string must be dumped to its 16-byte binary form
    # before it reaches Postgrex (same pitfall 01-02 hit in
    # dogfooding_loop_test.exs).
    request_id_bin = Ecto.UUID.dump!(request_id)

    Repo.all(
      from(e in "audit_events",
        where: e.request_id == ^request_id_bin,
        select: %{
          event_type: e.event_type,
          previous_state: e.previous_state,
          new_state: e.new_state,
          actor_verified: e.actor_verified
        },
        order_by: e.occurred_at
      )
    )
  end

  describe "approve/2" do
    test "approves a pending approve request, records the decided-by snapshot, and writes exactly one request.approved audit event" do
      request = request_fixture(%{type: :approve, title: "Ship the release?"})

      assert {:ok, approved} = Requests.approve(request, default_actor())

      assert approved.state == :approved
      assert approved.decision == :approved
      refute is_nil(approved.completed_at)

      assert approved.decided_by == %{
               "id" => nil,
               "type" => "human",
               "label" => "owner@localhost",
               "verified" => false,
               "method" => nil
             }

      assert [
               %{event_type: "request.created", previous_state: nil, new_state: "pending"},
               %{
                 event_type: "request.approved",
                 previous_state: "pending",
                 new_state: "approved",
                 actor_verified: false
               }
             ] = audit_rows(approved.id)
    end
  end

  describe "reject/2" do
    test "rejects a pending approve request, records the decided-by snapshot, and writes exactly one request.rejected audit event" do
      request = request_fixture(%{type: :approve, title: "Ship the release?"})

      assert {:ok, rejected} = Requests.reject(request, default_actor())

      assert rejected.state == :rejected
      assert rejected.decision == :rejected
      refute is_nil(rejected.completed_at)

      assert rejected.decided_by == %{
               "id" => nil,
               "type" => "human",
               "label" => "owner@localhost",
               "verified" => false,
               "method" => nil
             }

      assert [
               %{event_type: "request.created", previous_state: nil, new_state: "pending"},
               %{
                 event_type: "request.rejected",
                 previous_state: "pending",
                 new_state: "rejected",
                 actor_verified: false
               }
             ] = audit_rows(rejected.id)
    end
  end

  describe "type/action mismatch — refused as invalid, not as a conflict" do
    test "answering an approve request with free text is refused as invalid and writes nothing" do
      request = request_fixture(%{type: :approve, title: "Ship the release?"})

      assert {:error, %Ash.Error.Invalid{} = error} =
               Requests.answer(request, "some free text", default_actor())

      refute Enum.any?(error.errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
      refute Enum.any?(error.errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))

      assert {:ok, reloaded} = Requests.get_request(request.id)
      assert reloaded.state == :pending
      assert is_nil(reloaded.completed_at)

      assert [%{event_type: "request.created"}] = audit_rows(request.id)
    end

    test "approving an ask request is refused as invalid and writes nothing" do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})

      assert {:error, %Ash.Error.Invalid{} = error} = Requests.approve(request, default_actor())

      refute Enum.any?(error.errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
      refute Enum.any?(error.errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))

      assert {:ok, reloaded} = Requests.get_request(request.id)
      assert reloaded.state == :pending

      assert [%{event_type: "request.created"}] = audit_rows(request.id)
    end

    test "rejecting an ask request is refused as invalid and writes nothing" do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})

      assert {:error, %Ash.Error.Invalid{} = error} = Requests.reject(request, default_actor())

      refute Enum.any?(error.errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
      refute Enum.any?(error.errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))

      assert {:ok, reloaded} = Requests.get_request(request.id)
      assert reloaded.state == :pending

      assert [%{event_type: "request.created"}] = audit_rows(request.id)
    end
  end

  describe "D-06 — an unimplemented type must never look like a working one" do
    test "creating a choose or an escalate request fails with the not-implemented message and writes no row, no audit event" do
      for type <- [:choose, :escalate] do
        distinguishing_title = "not-implemented-#{type}-#{System.unique_integer([:positive])}"

        requests_before = Repo.aggregate(from(r in "human_requests"), :count)
        audit_events_before = Repo.aggregate(from(e in "audit_events"), :count)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 Requests.submit(
                   %{type: type, title: distinguishing_title},
                   default_actor()
                 )

        assert Enum.any?(error.errors, fn
                 %Ash.Error.Changes.InvalidAttribute{field: :type, message: message} ->
                   is_binary(message) and String.contains?(message, "not implemented")

                 _ ->
                   false
               end)

        assert Repo.aggregate(
                 from(r in "human_requests", where: r.title == ^distinguishing_title),
                 :count
               ) == 0

        # Nothing was written at all — not just nothing under this title.
        # `Requests.submit/2` guards `do_submit` inside the `with`, so a
        # changeset-validation failure never reaches `Humanport.Audit.record/2`.
        assert Repo.aggregate(from(r in "human_requests"), :count) == requests_before
        assert Repo.aggregate(from(e in "audit_events"), :count) == audit_events_before
      end
    end
  end
end
