defmodule Humanport.Requests.ChooseConflictTest do
  @moduledoc """
  CORE-04's `unresolved` concurrency row (delegated by `02.1-01-PLAN.md`,
  resolved here): two concurrent `choose` calls on one pending request
  produce exactly one success and one deterministic conflict, exactly one
  terminal row, and exactly one audit event — enforced by the atomic
  completion filter and the atomic transition guard compiled into the
  `:choose` action's `UPDATE`, decided by PostgreSQL, never by application
  code.

  Modelled directly on `test/humanport/requests/conflict_test.exs` — see
  that file's moduledoc for the full defense-in-depth rationale ((a) the
  atomic transition guard, (b) the atomic `completed_at` filter, (c) the
  `human_requests_terminal_is_final` trigger backstop). Runs on
  `Humanport.UnsandboxedCase`, never `Humanport.DataCase` — under the
  ordinary SQL sandbox in ownership/shared mode, collaborating processes
  share one connection and therefore one transaction, so two "concurrent"
  `choose` calls on that one connection would serialise trivially and this
  test would pass whether or not CORE-07's guarantee actually holds for the
  `:choose` action specifically.
  """

  use Humanport.UnsandboxedCase

  import Humanport.Fixtures

  alias Humanport.Requests
  alias Humanport.Requests.HumanRequest

  # audit_events is append-only (D-14) — DELETE raises the same trigger this
  # module exists to prove works, so cleanup here can only ever touch
  # human_requests. Its audit rows simply outlive the test; every count
  # assertion below is scoped by request_id, so leftover rows from a prior
  # run never affect a later one.
  defp cleanup_request(id) do
    on_exit(fn ->
      Repo.query!("DELETE FROM human_requests WHERE id = $1", [Ecto.UUID.dump!(id)])
    end)
  end

  test "two concurrent choices on one pending request yield exactly one success and one conflict" do
    request =
      choose_request_fixture(%{
        options: [
          %{id: "opt-a", label: "Option A"},
          %{id: "opt-b", label: "Option B"}
        ]
      })

    cleanup_request(request.id)

    results =
      [
        Task.async(fn ->
          Requests.choose(request, %{selected_option_ids: ["opt-a"]}, default_actor())
        end),
        Task.async(fn ->
          Requests.choose(request, %{selected_option_ids: ["opt-b"]}, default_actor())
        end)
      ]
      |> Task.await_many(5_000)

    successes = Enum.filter(results, &match?({:ok, _}, &1))
    failures = Enum.filter(results, &match?({:error, _}, &1))

    assert length(successes) == 1
    assert length(failures) == 1

    [{:error, error}] = failures
    assert %Ash.Error.Invalid{errors: errors} = error

    assert Enum.any?(errors, fn e ->
             match?(%AshStateMachine.Errors.NoMatchingTransition{}, e) or
               match?(%Ash.Error.Changes.StaleRecord{}, e)
           end)

    [{:ok, winner}] = successes

    fresh = Repo.get!(HumanRequest, request.id)
    # The stored selection is the winner's — the loser's ids appear nowhere.
    assert fresh.selected_option_ids == winner.selected_option_ids
    assert fresh.state == :answered

    assert audit_row_count(request.id, "request.chosen") == 1
  end

  defp audit_row_count(request_id, event_type) do
    request_id_bin = Ecto.UUID.dump!(request_id)

    %Postgrex.Result{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_events WHERE request_id = $1 AND event_type = $2",
        [request_id_bin, event_type]
      )

    count
  end
end
