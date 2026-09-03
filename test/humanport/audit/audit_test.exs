defmodule Humanport.Requests.AuditTest do
  @moduledoc """
  SEC-07 — every security-sensitive transition writes exactly one durable,
  append-only audit event, separate from application logs, and a rolled-back
  transition writes none. D-14's append-only guarantee is a database
  property, not an application convention: `audit_events` rejects UPDATE,
  DELETE, and TRUNCATE from PostgreSQL itself, regardless of which code path
  issues them.

  ## What the append-only trigger does NOT cover

  `human_requests_terminal_is_final`'s sibling, `audit_events_append_only`,
  stops UPDATE/DELETE/TRUNCATE at the trigger level. It does not, and cannot,
  stop the table's owner from `DROP TABLE audit_events` or
  `DROP TRIGGER audit_events_no_update_delete` — D-14 accepted that limit to
  keep `docker compose up` free of a second, more-restricted database role.
  Do not describe this trigger, here or anywhere else, as closing that gap.
  """

  use Humanport.DataCase, async: true

  import Humanport.Fixtures

  alias Humanport.Audit
  alias Humanport.Requests
  alias Humanport.Requests.HumanRequest

  defp audit_rows(request_id) do
    request_id_bin = Ecto.UUID.dump!(request_id)

    Repo.all(
      from(e in "audit_events",
        where: e.request_id == ^request_id_bin,
        select: %{
          event_type: e.event_type,
          previous_state: e.previous_state,
          new_state: e.new_state,
          actor_verified: e.actor_verified,
          actor_method: e.actor_method
        },
        order_by: e.occurred_at
      )
    )
  end

  describe "one event per transition, of the right §23 type, with the right state pair" do
    test "answer writes request.created then request.responded" do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})
      {:ok, answered} = Requests.answer(request, "an answer", default_actor())

      assert [
               %{event_type: "request.created", previous_state: nil, new_state: "pending"},
               %{
                 event_type: "request.responded",
                 previous_state: "pending",
                 new_state: "answered",
                 actor_verified: false
               }
             ] = audit_rows(answered.id)
    end

    test "approve writes request.created then request.approved" do
      request = request_fixture(%{type: :approve, title: "Ship the release?"})
      {:ok, approved} = Requests.approve(request, default_actor())

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

    test "reject writes request.created then request.rejected" do
      request = request_fixture(%{type: :approve, title: "Ship the release?"})
      {:ok, rejected} = Requests.reject(request, default_actor())

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

  describe "D-04 — the audit trail records HOW an actor was verified, not only whether (actor_method)" do
    test "an actor with a method stores that method on the row" do
      request =
        request_fixture(%{
          type: :ask,
          title: "Ask via a service token",
          actor: %Humanport.Actors.Actor{
            type: :service,
            label: "agent-service-token-1.access",
            verified?: true,
            method: :service_token
          }
        })

      assert [%{event_type: "request.created", actor_method: "service_token"}] =
               audit_rows(request.id)
    end

    test "the local unverified actor (no method) still stores nil — D-11/D-12 stay distinguishable" do
      request = request_fixture(%{type: :ask, title: "Local unverified"})

      assert [%{event_type: "request.created", actor_method: nil, actor_verified: false}] =
               audit_rows(request.id)
    end
  end

  describe "a transition that rolls back leaves no audit row" do
    test "the state change and the audit write commit together, or neither commits" do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})
      actor = default_actor()

      # Deliberately reproduces the shape of Requests.answer/3's own
      # Ash.transaction/3 — write the state change for real, THEN force a
      # rollback, to prove the pair is atomic rather than merely "the audit
      # write is never reached on a guard failure" (already covered by
      # decide_test.exs and state_machine_test.exs).
      result =
        Ash.transaction([HumanRequest, Audit.Event], fn ->
          {:ok, _answered} =
            request
            |> Ash.Changeset.for_update(:answer, %{answer: "never persisted"}, actor: actor)
            |> Ash.update()

          Ash.DataLayer.rollback(HumanRequest, :synthetic_rollback_for_test)
        end)

      # Ash.DataLayer.rollback/2 wraps the reason in an Ash error struct
      # rather than passing it through raw.
      assert {:error, %Ash.Error.Unknown.UnknownError{value: nil} = error} = result
      assert error.error =~ "synthetic_rollback_for_test"

      # The state change never committed...
      assert {:ok, reloaded} = Requests.get_request(request.id)
      assert reloaded.state == :pending
      assert is_nil(reloaded.answer)
      assert is_nil(reloaded.completed_at)

      # ...and no request.responded row exists — only the creation event
      # from the fixture, which committed in its own, separate transaction.
      assert [%{event_type: "request.created"}] = audit_rows(request.id)
    end
  end

  describe "audit_events is append-only at the database level" do
    setup do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})
      {:ok, answered} = Requests.answer(request, "an answer", default_actor())
      %{request_id_bin: Ecto.UUID.dump!(answered.id)}
    end

    test "PostgreSQL refuses UPDATE", %{request_id_bin: request_id_bin} do
      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.transaction(fn ->
          Repo.query!("UPDATE audit_events SET metadata = '{}' WHERE request_id = $1", [
            request_id_bin
          ])
        end)
      end
    end

    test "PostgreSQL refuses DELETE", %{request_id_bin: request_id_bin} do
      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.transaction(fn ->
          Repo.query!("DELETE FROM audit_events WHERE request_id = $1", [request_id_bin])
        end)
      end
    end

    test "PostgreSQL refuses TRUNCATE" do
      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.transaction(fn ->
          Repo.query!("TRUNCATE audit_events")
        end)
      end
    end
  end
end
