defmodule Humanport.Requests.Changes.SetContentHash do
  @moduledoc """
  SEC-08 — stores `Humanport.Requests.ContentHash`'s fingerprint on a new
  request. Runs as a `before_action` hook so it sees every value the row
  will actually be written with: defaults, the derived `choose` type and the
  requester fields `SetRequester` sets. Used on `:submit` only, a create, so
  it has no bearing on the atomic decision actions.
  """

  use Ash.Resource.Change

  alias Humanport.Requests.ContentHash

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      Ash.Changeset.force_change_attribute(
        changeset,
        :content_hash,
        ContentHash.compute_changeset(changeset)
      )
    end)
  end
end
