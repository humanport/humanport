defmodule Humanport.Agents.Changes.GenerateToken do
  @moduledoc """
  Mints the token for `Humanport.Agents.AgentKey`'s `:issue` action: sets
  `prefix` and `secret_hash`, and hands the plaintext back exactly once as
  the `:token` metadata on the created record. The plaintext is never
  written to any attribute.
  """

  use Ash.Resource.Change

  alias Humanport.Agents

  @impl true
  def change(changeset, _opts, _context) do
    prefix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    token = "hp_" <> prefix <> "_" <> secret

    changeset
    |> Ash.Changeset.force_change_attribute(:prefix, prefix)
    |> Ash.Changeset.force_change_attribute(:secret_hash, Agents.hash_token(token))
    |> Ash.Changeset.after_action(fn _changeset, key ->
      {:ok, Ash.Resource.put_metadata(key, :token, token)}
    end)
  end
end
