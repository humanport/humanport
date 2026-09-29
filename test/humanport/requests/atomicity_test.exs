defmodule Humanport.Requests.AtomicityTest do
  @moduledoc """
  T-01-17 — the single highest-value test in this phase. The guarantee it
  protects (CORE-06/CORE-07 are database guarantees only as long as every
  state-changing action on `HumanRequest` stays fully atomic) is invisible
  when it disappears: the natural way to lose it is to attach the audit
  write, a notification, or any anonymous-function change to a
  state-changing action — that fails to compile, and the obvious fix
  (`require_atomic? false`) makes it compile while silently turning the
  action back into read-modify-write. Every happy-path test still passes.
  Only a test that reads the resource's own introspection catches that on
  the next run — this is that test.

  Also asserts the transition table itself, so a later phase cannot quietly
  widen the vocabulary further: exactly five transitions, all from
  `:pending`, to `:answered` (twice — `:answer` and CORE-04's `:choose`,
  which deliberately reuses the `:answered` terminal state rather than
  introducing a `:chosen` one), `:approved`, `:rejected`, and ROUTE-*'s
  `:expired` (via `:expire`, run only by the deadline job). `:routed` and
  `:viewed` are §11 candidate states that belong to later routing work.
  """

  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias AshStateMachine.Info, as: StateMachineInfo
  alias Humanport.Requests.HumanRequest

  describe "no state-changing action has lost its atomicity" do
    test "every update action on HumanRequest reports require_atomic?: true" do
      update_actions =
        HumanRequest
        |> Info.actions()
        |> Enum.filter(&(&1.type == :update))

      # Guard against the introspection itself silently seeing nothing —
      # an empty list would make every assertion below vacuously pass.
      assert length(update_actions) >= 3

      for action <- update_actions do
        assert action.require_atomic? == true,
               "#{inspect(action.name)} lost its atomicity requirement — " <>
                 "this silently downgrades it to read-modify-write and destroys " <>
                 "CORE-06/CORE-07's database-level guarantee. See the moduledoc " <>
                 "landmine on Humanport.Requests.HumanRequest."
      end

      assert Enum.map(update_actions, & &1.name) |> Enum.sort() ==
               [:answer, :approve, :choose, :expire, :reject]
    end
  end

  describe "the declared transition table is exactly the CORE-04 set" do
    test "five transitions, all from :pending, to :answered/:approved/:rejected/:expired" do
      transitions = StateMachineInfo.state_machine_transitions(HumanRequest)

      assert length(transitions) == 5

      for transition <- transitions do
        assert List.wrap(transition.from) == [:pending]
      end

      assert transitions |> Enum.map(&{&1.action, List.wrap(&1.to)}) |> Enum.sort() ==
               [
                 answer: [:answered],
                 approve: [:approved],
                 choose: [:answered],
                 expire: [:expired],
                 reject: [:rejected]
               ]
               |> Enum.sort()

      # :routed and :viewed are §11 candidate states reserved for routing
      # work — no transition may target them yet.
      all_targets = transitions |> Enum.flat_map(&List.wrap(&1.to))
      refute :routed in all_targets
      refute :viewed in all_targets
    end

    test "the resource's full state set is exactly the four Phase 1 states plus :expired" do
      all_states = StateMachineInfo.state_machine_all_states(HumanRequest)

      assert Enum.sort(all_states) ==
               Enum.sort([:pending, :answered, :approved, :rejected, :expired])
    end
  end
end
