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

  Nothing ever deletes a key. Revoking sets `revoked_at`, and the atomic
  validation on `:revoke` refuses to overwrite it, so a key's revocation
  time is written once and a second revoke is an error rather than a silent
  re-stamp. Written only through `Humanport.Agents`, which pairs each
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
      accept [:label, :role]

      change {Humanport.Agents.Changes.GenerateToken, []}
      change {Humanport.Requests.Changes.SetTenantId, []}
    end

    update :revoke do
      # Compiled into the UPDATE itself, so it checks the row as stored, not
      # the caller's possibly stale copy. It must come BEFORE the change
      # below: after it, the attribute would already read as the new
      # timestamp. (`change filter(...)` looks like it would do this, but on
      # a single-record update it never reaches the WHERE clause.)
      validate absent(:revoked_at), message: "this agent key is already revoked"
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

    # SEC-02 — what this key may do (see `Humanport.Actors.Actor`'s `role`).
    # Least privilege by default: a key that should answer has to be issued
    # as one.
    attribute :role, :atom,
      constraints: [one_of: [:requester, :responder, :admin]],
      default: :requester,
      allow_nil?: false,
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_prefix, [:prefix]
  end
end
