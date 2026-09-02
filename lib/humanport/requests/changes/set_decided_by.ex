defmodule Humanport.Requests.Changes.SetDecidedBy do
  @moduledoc """
  Snapshots the resolved `%Humanport.Actors.Actor{}` calling this action onto
  the request's `decided_by` attribute, so `GET /api/v1/requests/:id` can
  answer "who answered" without a join or a live actor lookup (D-11).

  Implements `atomic/3` so it composes with the atomic transition guard
  (`transition_state/1`) and the atomic conflict filter (`filter/1`) on the
  same `:answer` action without turning off that action's atomicity
  requirement — see the landmine documented on
  `Humanport.Requests.HumanRequest`.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.force_change_attribute(changeset, :decided_by, snapshot(context.actor))
  end

  @impl true
  def atomic(_changeset, _opts, context) do
    {:atomic, %{decided_by: snapshot(context.actor)}}
  end

  defp snapshot(nil), do: nil

  defp snapshot(%Humanport.Actors.Actor{} = actor) do
    %{
      "id" => actor.id,
      "type" => to_string(actor.type),
      "label" => actor.label,
      "verified" => actor.verified?,
      "method" => actor.method && to_string(actor.method)
    }
  end
end
