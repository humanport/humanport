defmodule Humanport.Requests.ChooseTest do
  @moduledoc """
  CORE-04 — a caller may attach a list of options to a request and get the
  chosen ones back verbatim, without HumanPort ever knowing what any of them
  mean (ROADMAP.md "Locked decisions for `choose`", `02.1-CONTEXT.md` D-12,
  D-13). Task 1 covers the opaque `Option` embedded resource, the four new
  `HumanRequest` attributes, and the type-derivation/validation pair on
  `:submit`. Tasks 2 and 3 extend this file with `Requests.choose/3`, the
  atomic `:choose` action, and the wire shape.
  """

  use Humanport.DataCase, async: true

  import Humanport.Fixtures

  alias Humanport.Requests
  alias Humanport.Requests.Option

  defp audit_rows(request_id) do
    request_id_bin = Ecto.UUID.dump!(request_id)

    Repo.all(
      from(e in "audit_events",
        where: e.request_id == ^request_id_bin,
        select: %{
          event_type: e.event_type,
          previous_state: e.previous_state,
          new_state: e.new_state,
          metadata: e.metadata
        },
        order_by: e.occurred_at
      )
    )
  end

  describe "the opaque option round trip" do
    test "three options submitted come back verbatim, in order, with absent fields still absent" do
      options = [
        %{id: "opt-1", label: "  leading space label", description: "first", recommended: false},
        %{
          id: "opt-2",
          label: "MIXED Case Label <b>markup</b>",
          description: nil,
          recommended: true
        },
        %{id: "opt-3", label: "third label"}
      ]

      request = choose_request_fixture(%{options: options})

      assert [
               %Option{
                 id: "opt-1",
                 label: "  leading space label",
                 description: "first",
                 recommended: false
               },
               %Option{
                 id: "opt-2",
                 label: "MIXED Case Label <b>markup</b>",
                 description: nil,
                 recommended: true
               },
               %Option{id: "opt-3", label: "third label", description: nil, recommended: nil}
             ] = request.options
    end
  end

  describe "the type follows from the presence of options (D-12)" do
    test "submitting options without naming a type produces a choose request" do
      assert {:ok, request} =
               Requests.submit(
                 %{title: "Pick one", options: [%{id: "a", label: "A"}]},
                 default_actor()
               )

      assert request.type == :choose
    end

    test "submitting options together with an explicit ask type still yields choose" do
      # The case that breaks if DeriveChooseType is declared after the
      # one_of validation instead of before it.
      request =
        request_fixture(%{
          type: :ask,
          options: [%{id: "a", label: "A"}]
        })

      assert request.type == :choose
    end

    test "the choose type with no options is refused with a field-level message, writes nothing" do
      requests_before = Repo.aggregate(from(r in "human_requests"), :count)
      audit_events_before = Repo.aggregate(from(e in "audit_events"), :count)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Requests.submit(%{type: :choose, title: "Nothing to choose from"}, default_actor())

      assert Enum.any?(error.errors, fn
               %Ash.Error.Changes.InvalidAttribute{field: :options} -> true
               _ -> false
             end)

      assert Repo.aggregate(from(r in "human_requests"), :count) == requests_before
      assert Repo.aggregate(from(e in "audit_events"), :count) == audit_events_before
    end

    test "the choose type with an empty option list is refused the same way" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Requests.submit(
                 %{type: :choose, title: "Nothing to choose from", options: []},
                 default_actor()
               )

      assert Enum.any?(error.errors, fn
               %Ash.Error.Changes.InvalidAttribute{field: :options} -> true
               _ -> false
             end)
    end
  end

  describe "choose is no longer refused as not-implemented" do
    test "submitting the choose type with options succeeds" do
      assert {:ok, request} =
               Requests.submit(
                 %{type: :choose, title: "Pick one", options: [%{id: "a", label: "A"}]},
                 default_actor()
               )

      assert request.type == :choose
      assert request.state == :pending

      assert [%{event_type: "request.created"}] = audit_rows(request.id)
    end

    test "submitting the escalate type is still refused as not-implemented" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Requests.submit(%{type: :escalate, title: "Not built yet"}, default_actor())

      assert Enum.any?(error.errors, fn
               %Ash.Error.Changes.InvalidAttribute{field: :type, message: message} ->
                 is_binary(message) and String.contains?(message, "not implemented")

               _ ->
                 false
             end)
    end
  end

  describe "max_selections and allow_free_text defaults" do
    test "max_selections defaults to one" do
      request = choose_request_fixture()
      assert request.max_selections == 1
    end

    test "max_selections rejects zero" do
      assert {:error, %Ash.Error.Invalid{}} =
               Requests.submit(
                 %{
                   type: :choose,
                   title: "Pick one",
                   options: [%{id: "a", label: "A"}],
                   max_selections: 0
                 },
                 default_actor()
               )
    end

    test "max_selections rejects a negative value" do
      assert {:error, %Ash.Error.Invalid{}} =
               Requests.submit(
                 %{
                   type: :choose,
                   title: "Pick one",
                   options: [%{id: "a", label: "A"}],
                   max_selections: -1
                 },
                 default_actor()
               )
    end

    test "allow_free_text defaults to false" do
      request = choose_request_fixture()
      assert request.allow_free_text == false
    end
  end

  describe "selected_option_ids is not accepted at create" do
    test "a create request cannot arrive already answered — the attribute is not a valid input" do
      # `selected_option_ids` is absent from `:submit`'s accept list, so Ash
      # refuses it as an unrecognized input rather than silently accepting
      # and ignoring it — a stronger guarantee than a value that happens to
      # be dropped.
      assert {:error, %Ash.Error.Invalid{} = error} =
               Requests.submit(
                 %{
                   type: :choose,
                   title: "Pick one",
                   options: [%{id: "a", label: "A"}],
                   selected_option_ids: ["a"]
                 },
                 default_actor()
               )

      assert Enum.any?(error.errors, &match?(%Ash.Error.Invalid.NoSuchInput{}, &1))
    end
  end

  # --- Task 2 — Requests.choose/3 and the atomic :choose action ---------

  describe "choosing one offered id succeeds" do
    test "the request reaches the answered terminal state with a one-element selection" do
      request = choose_request_fixture()

      assert {:ok, chosen} =
               Requests.choose(request, %{selected_option_ids: ["opt-a"]}, default_actor())

      assert chosen.state == :answered
      assert chosen.selected_option_ids == ["opt-a"]
      refute is_nil(chosen.completed_at)
      refute is_nil(chosen.decided_by)
    end

    test "the selection is a list even for a single choice" do
      request = choose_request_fixture()

      assert {:ok, chosen} =
               Requests.choose(request, %{selected_option_ids: ["opt-a"]}, default_actor())

      assert is_list(chosen.selected_option_ids)
    end
  end

  describe "max_selections is enforced before any write" do
    test "choosing two ids on a maximum of one names both the count sent and the maximum allowed" do
      request = choose_request_fixture()

      assert {:error, %Ash.Error.Invalid{} = error} =
               Requests.choose(
                 request,
                 %{selected_option_ids: ["opt-a", "opt-b"]},
                 default_actor()
               )

      assert Enum.any?(error.errors, fn
               %Ash.Error.Changes.InvalidAttribute{field: :selected_option_ids, message: message} ->
                 String.contains?(message, "2") and String.contains?(message, "1")

               _ ->
                 false
             end)

      assert {:ok, reloaded} = Requests.get_request(request.id)
      assert reloaded.state == :pending
      assert [%{event_type: "request.created"}] = audit_rows(request.id)
    end
  end

  describe "an id the request never offered is refused as malformed, not as a conflict" do
    test "an unoffered id is refused" do
      request = choose_request_fixture()

      assert {:error, %Ash.Error.Invalid{} = error} =
               Requests.choose(request, %{selected_option_ids: ["nope"]}, default_actor())

      refute Enum.any?(error.errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))
      refute Enum.any?(error.errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      assert Enum.any?(error.errors, &match?(%Ash.Error.Changes.InvalidAttribute{}, &1))
    end
  end

  describe "membership is exact string equality — no trimming, no case folding" do
    test "an id differing only by surrounding whitespace is refused" do
      request = choose_request_fixture()

      assert {:error, %Ash.Error.Invalid{}} =
               Requests.choose(request, %{selected_option_ids: [" opt-a "]}, default_actor())
    end

    test "an id differing only by case is refused" do
      request = choose_request_fixture()

      assert {:error, %Ash.Error.Invalid{}} =
               Requests.choose(request, %{selected_option_ids: ["OPT-A"]}, default_actor())
    end
  end

  describe "choosing the same id twice in one call is refused" do
    test "a duplicate id is refused" do
      request = choose_request_fixture()

      assert {:error, %Ash.Error.Invalid{}} =
               Requests.choose(
                 request,
                 %{selected_option_ids: ["opt-a", "opt-a"]},
                 default_actor()
               )
    end
  end

  describe "free text (locked decision 4)" do
    test "free text on a request whose flag is false is refused" do
      request = choose_request_fixture()

      assert {:error, %Ash.Error.Invalid{}} =
               Requests.choose(
                 request,
                 %{selected_option_ids: [], free_text: "something else entirely"},
                 default_actor()
               )
    end

    test "free text on a request whose flag is true succeeds, leaves the selection an empty list, and the audit records text was given" do
      request = choose_request_fixture(%{allow_free_text: true})

      assert {:ok, chosen} =
               Requests.choose(
                 request,
                 %{selected_option_ids: [], free_text: "something else entirely"},
                 default_actor()
               )

      assert chosen.answer == "something else entirely"
      assert chosen.selected_option_ids == []

      assert [_created, %{event_type: "request.chosen", metadata: metadata}] =
               audit_rows(request.id)

      assert metadata["free_text_given"] == true
      assert metadata["selected_options"] == []
    end
  end

  describe "an empty selection with no free text is refused" do
    test "nothing may be answered with nothing" do
      request = choose_request_fixture()

      assert {:error, %Ash.Error.Invalid{}} =
               Requests.choose(request, %{selected_option_ids: []}, default_actor())
    end
  end

  describe "type/action mismatch — refused as invalid, not as a conflict" do
    test "choosing on a request that is not of the choose type is refused before the transaction opens" do
      request = request_fixture(%{type: :ask, title: "Which changelog entry?"})

      assert {:error, %Ash.Error.Invalid{} = error} =
               Requests.choose(request, %{selected_option_ids: ["a"]}, default_actor())

      refute Enum.any?(error.errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
      refute Enum.any?(error.errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))

      assert {:ok, reloaded} = Requests.get_request(request.id)
      assert reloaded.state == :pending
      assert [%{event_type: "request.created"}] = audit_rows(request.id)
    end
  end

  describe "the audit entry — D-13" do
    test "exactly one request.chosen event is written per successful choice, carrying id and label" do
      request = choose_request_fixture()

      assert {:ok, chosen} =
               Requests.choose(request, %{selected_option_ids: ["opt-b"]}, default_actor())

      assert [%{event_type: "request.created"}, %{event_type: "request.chosen"} = choice_event] =
               audit_rows(chosen.id)

      assert choice_event.previous_state == "pending"
      assert choice_event.new_state == "answered"

      assert choice_event.metadata == %{
               "selected_options" => [%{"id" => "opt-b", "label" => "Option B"}],
               "free_text_given" => false
             }
    end

    test "the audit entry records the label as it stood at decision time, not one resolved by id later" do
      # Options are opaque per-request payloads with no global id registry
      # (D-13's own reasoning): a caller reusing the same option id with a
      # different label on a LATER request must not retroactively change
      # what an EARLIER decision's audit entry says was shown. Since the
      # `human_requests_terminal_is_final` trigger makes the terminal row
      # itself immutable (by design — CORE-07), this is the only way to
      # observe "resolved later" going wrong: it would require someone to
      # follow the id back into a *different* record and re-derive the
      # label from there, which nothing in `choose/3` ever does.
      request = choose_request_fixture()

      assert {:ok, chosen} =
               Requests.choose(request, %{selected_option_ids: ["opt-b"]}, default_actor())

      # A later, unrelated request reuses the id "opt-b" with a different
      # label — the caller "renamed" the option in its own catalog.
      _later_request =
        choose_request_fixture(%{
          options: [%{id: "opt-b", label: "Renamed after the fact"}]
        })

      assert [_created, %{metadata: metadata}] = audit_rows(chosen.id)
      assert metadata["selected_options"] == [%{"id" => "opt-b", "label" => "Option B"}]
    end
  end
end
