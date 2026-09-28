defmodule Humanport.Requests.Changes.SetRequester do
  @moduledoc """
  SEC-04/05 — records who is asking. When the acting actor is a verified
  agent (an authenticated `Humanport.Agents.AgentKey`), the request carries
  that key's label as `requester_label`, `requester_verified: true`, and the
  key's id as `requester_agent_key_id` — the last is what lets
  `Humanport.Requests` refuse to let a key answer its own request. A
  `requester_label` sent on the wire is overwritten in that case: a verified
  requester is named by its credential, not by what it says about itself.

  Every other actor leaves the wire label as sent and records it as
  unverified, exactly as before agent keys existed (D-12).
  """

  use Ash.Resource.Change

  alias Humanport.Actors.Actor

  @impl true
  def change(changeset, _opts, %{actor: %Actor{type: :agent, verified?: true} = actor}) do
    changeset
    |> Ash.Changeset.force_change_attribute(:requester_label, actor.label)
    |> Ash.Changeset.force_change_attribute(:requester_verified, true)
    |> Ash.Changeset.force_change_attribute(:requester_agent_key_id, actor.id)
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(changeset, :requester_verified, false)
  end
end
