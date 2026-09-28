defmodule Humanport.Fixtures do
  @moduledoc """
  Test fixtures for HumanPort domain resources.

  Every fixture in this module MUST be built on the resource's real Ash
  action (via `Humanport.Requests.submit/2`), never on `Repo.insert`
  directly — a fixture that bypasses the action under test bypasses the
  behaviour the test exists to prove.
  """

  alias Humanport.Actors.Actor
  alias Humanport.Requests

  @doc """
  Builds a `HumanRequest` via `Humanport.Requests.submit/2` — the real
  `:submit` action, with its own audit write, not `Repo.insert`.

  Accepts the same param keys `:submit` accepts, plus an optional `:actor`
  (defaults to an unverified human actor matching the local D-11 seam).
  """
  def request_fixture(attrs \\ %{}) do
    {actor, attrs} = Map.pop(attrs, :actor, default_actor())

    params =
      Map.merge(
        %{
          type: :ask,
          title: "Which changelog entry?",
          requester_label: "claude-code/gsd"
        },
        attrs
      )

    {:ok, request} = Requests.submit(params, actor)
    request
  end

  @doc """
  Builds a `HumanRequest` of the `choose` type via `Humanport.Requests.submit/2`,
  with a small default option list. Accepts the same keys `request_fixture/1`
  does, plus `:options` to override the default list.
  """
  def choose_request_fixture(attrs \\ %{}) do
    default_options = [
      %{id: "opt-a", label: "Option A"},
      %{id: "opt-b", label: "Option B", description: "The second choice", recommended: true}
    ]

    attrs = Map.put_new(attrs, :options, default_options)

    request_fixture(Map.put(attrs, :type, :choose))
  end

  @doc "The default unverified human actor used when a fixture doesn't need a specific one."
  def default_actor do
    %Actor{id: nil, type: :human, label: "owner@localhost", verified?: false, method: nil}
  end
end
