defmodule Humanport.Agents.AgentKey do
  @moduledoc """
  SEC-04/05 — a revocable credential an agent presents as
  `Authorization: Bearer hp_<prefix>_<secret>` on `/api/v1` and `/mcp`.

  Only a SHA-256 digest of the whole token is stored (`secret_hash`); the
  plaintext exists exactly once, as the `:token` metadata on the record the
  `:issue` action returns. The token is 32 random bytes, so a fast digest is
  the right tool here — a slow password hash protects low-entropy secrets,
  and this one has none to protect. `prefix` is random too, stored in the
  clear and unique, and only locates the row; it proves nothing on its own.

  Nothing ever deletes a key. Revoking sets `revoked_at`, which the atomic
  `filter` on `:revoke` refuses to overwrite, so a key's revocation time is
  written once and a second revoke is a stale-record error rather than a
  silent re-stamp. Written only through `Humanport.Agents`, which pairs each
  change with its audit event in one transaction.
  """

  use Ash.Resource,
    domain: Humanport.Agents,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "agent_keys"
    repo Humanport.Repo
  end

  actions do
    defaults [:read]

    read :by_prefix do
      argument :prefix, :string, allow_nil?: false
      get? true
      filter expr(prefix == ^arg(:prefix))
    end

    create :issue do
      accept [:label]

      change {Humanport.Agents.Changes.GenerateToken, []}
      change {Humanport.Requests.Changes.SetTenantId, []}
    end

    update :revoke do
      change filter(expr(is_nil(revoked_at)))
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true

    attribute :label, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 200, trim?: true]

    attribute :prefix, :string, allow_nil?: false, public?: true
    attribute :secret_hash, :string, allow_nil?: false, sensitive?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_prefix, [:prefix]
  end
end
