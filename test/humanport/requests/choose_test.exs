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
end
