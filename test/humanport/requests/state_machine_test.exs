defmodule Humanport.Requests.StateMachineTest do
  @moduledoc """
  CORE-06 — illegal transitions fail atomically, against the real domain
  functions (`Requests.answer/3`, `approve/2`, `reject/2`), never against a
  bare changeset. The error asserted on is
  `AshStateMachine.Errors.NoMatchingTransition` inside an `Ash.Error.Invalid`
  — it carries the action, the target state and the old state, which is what
  the HTTP boundary (plan 01-04) branches on to return 409.

  The negative half of every test here is the load-bearing half: a refused
  transition must leave the row untouched and add no audit row. A transition
  that fails *after* writing is exactly the failure CORE-06 exists to
  exclude, and a test that only checks "it raised" would miss that.
  """

  use Humanport.DataCase, async: true

  import Humanport.Fixtures

  alias Humanport.Requests

  defp audit_row_count(request_id) do
    request_id_bin = Ecto.UUID.dump!(request_id)

    Repo.aggregate(
      from(e in "audit_events", where: e.request_id == ^request_id_bin),
      :count
    )
  end

  test "answering an already-answered request raises NoMatchingTransition, class invalid, and writes nothing further" do
    request = request_fixture(%{type: :ask, title: "Which changelog entry?"})
    actor = default_actor()

    assert {:ok, answered} = Requests.answer(request, "first answer", actor)
    assert audit_row_count(answered.id) == 2

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Requests.answer(answered, "second answer", actor)

    assert [%AshStateMachine.Errors.NoMatchingTransition{} = no_match] =
             Enum.filter(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))

    assert no_match.action == :answer
    assert no_match.target == :answered
    assert no_match.old_state == :answered

    # The row is unchanged — still carries the FIRST answer, not overwritten
    # and not blanked.
    assert {:ok, reloaded} = Requests.get_request(request.id)
    assert reloaded.answer == "first answer"
    assert reloaded.state == :answered

    # No third audit row appeared for the refused second attempt.
    assert audit_row_count(request.id) == 2
  end

  test "approving an already-rejected request raises NoMatchingTransition, class invalid, and writes nothing further" do
    request = request_fixture(%{type: :approve, title: "Ship the release?"})
    actor = default_actor()

    assert {:ok, rejected} = Requests.reject(request, actor)
    assert audit_row_count(rejected.id) == 2

    assert {:error, %Ash.Error.Invalid{errors: errors}} = Requests.approve(rejected, actor)

    assert [%AshStateMachine.Errors.NoMatchingTransition{} = no_match] =
             Enum.filter(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))

    assert no_match.action == :approve
    assert no_match.target == :approved
    assert no_match.old_state == :rejected

    assert {:ok, reloaded} = Requests.get_request(request.id)
    assert reloaded.decision == :rejected
    assert reloaded.state == :rejected

    assert audit_row_count(request.id) == 2
  end

  test "rejecting an already-approved request raises NoMatchingTransition, class invalid, and writes nothing further" do
    request = request_fixture(%{type: :approve, title: "Ship the release?"})
    actor = default_actor()

    assert {:ok, approved} = Requests.approve(request, actor)
    assert audit_row_count(approved.id) == 2

    assert {:error, %Ash.Error.Invalid{errors: errors}} = Requests.reject(approved, actor)

    assert [%AshStateMachine.Errors.NoMatchingTransition{} = no_match] =
             Enum.filter(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))

    assert no_match.action == :reject
    assert no_match.target == :rejected
    assert no_match.old_state == :approved

    assert {:ok, reloaded} = Requests.get_request(request.id)
    assert reloaded.decision == :approved
    assert reloaded.state == :approved

    assert audit_row_count(request.id) == 2
  end
end
