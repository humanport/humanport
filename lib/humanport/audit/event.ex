defmodule Humanport.Audit.Event do
  @moduledoc """
  The §23 append-only audit event. Create-and-read only at the Ash level —
  `defaults [:read, create: :*]` declares no `:update` and no `:destroy`
  action, so there is no code path in this resource that can mutate or remove
  a row (SEC-07). Database-level immutability is enforced separately by the
  `custom_statements` trigger below (D-14) — application-level and
  database-level immutability are two independent statements, and SEC-07
  wants both.

  Written exclusively through `Humanport.Audit.record/2`, which takes
  primitives (ids, states, an `%Humanport.Actors.Actor{}`, a metadata map) —
  never a `%Humanport.Requests.HumanRequest{}`. This resource has no
  compile-time knowledge of the requests domain, and `Humanport.Requests`
  never declares a relationship to it. That decoupling is the point.
  """

  use Ash.Resource,
    domain: Humanport.Audit,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "audit_events"
    repo Humanport.Repo

    custom_statements do
      # The name is used to detect if the statement is removed or modified.
      # No table dependency declared — the function itself references no
      # table structure, only `audit_events`'s two triggers below do.
      statement :audit_events_append_only_fn do
        up """
        CREATE OR REPLACE FUNCTION audit_events_append_only() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'audit_events is append-only: % is not permitted', TG_OP
            USING ERRCODE = 'integrity_constraint_violation';
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS audit_events_append_only();"
      end

      # FOR EACH ROW covers UPDATE and DELETE.
      statement :audit_events_no_update_delete do
        after_tables ["audit_events"]

        up """
        CREATE TRIGGER audit_events_no_update_delete
          BEFORE UPDATE OR DELETE ON audit_events
          FOR EACH ROW EXECUTE FUNCTION audit_events_append_only();
        """

        down "DROP TRIGGER IF EXISTS audit_events_no_update_delete ON audit_events;"
      end

      # TRUNCATE triggers cannot be FOR EACH ROW — a second trigger is
      # required because row-level triggers do not cover TRUNCATE.
      statement :audit_events_no_truncate do
        after_tables ["audit_events"]

        up """
        CREATE TRIGGER audit_events_no_truncate
          BEFORE TRUNCATE ON audit_events
          FOR EACH STATEMENT EXECUTE FUNCTION audit_events_append_only();
        """

        down "DROP TRIGGER IF EXISTS audit_events_no_truncate ON audit_events;"
      end
    end
  end

  actions do
    # Ash 3 accepts NO attributes by default on a bare `:create` — `create: :*`
    # is required to accept the full set of public attributes below. No
    # `:update`, no `:destroy`: this resource has neither action, at all.
    defaults [:read, create: :*]
  end

  attributes do
    uuid_primary_key :event_id

    attribute :event_type, :string, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :request_id, :uuid, allow_nil?: false, public?: true

    # D-11/D-12 additions to §23's minimum — required so a local unverified
    # entry stays distinguishable from a Phase 2 verified one.
    attribute :actor_id, :string, public?: true

    attribute :actor_type, :atom,
      constraints: [one_of: [:human, :agent, :service, :system]],
      public?: true

    attribute :actor_label, :string, public?: true
    attribute :actor_verified, :boolean, default: false, allow_nil?: false, public?: true

    attribute :resource_type, :string, allow_nil?: false, public?: true
    attribute :resource_id, :uuid, allow_nil?: false, public?: true

    attribute :previous_state, :string, public?: true
    attribute :new_state, :string, public?: true

    attribute :correlation_id, :string, public?: true
    attribute :source_protocol, :string, public?: true
    attribute :source_identifier, :string, public?: true

    # §23 — sensitive payloads are NEVER automatically copied here.
    attribute :metadata, :map, default: %{}, public?: true
  end
end
