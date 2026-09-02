defmodule Humanport.Requests.HumanRequest do
  @moduledoc """
  The canonical, protocol-neutral human request (§6.1, §11) — the Phase 1
  minimal subset plus `tenant_id` (D-05) and the two D-24 risk fields.

  `priority`, `deadline` and `routing` are deliberately absent; they belong to
  their own later phase and must not be added here (D-05).

  ## The atomicity landmine — read before touching a state-changing action

  `AshStateMachine.BuiltinChanges.TransitionState` (used by `transition_state/1`
  below) implements `atomic/3`: it compiles the legality of a transition into
  the `UPDATE` statement itself, so PostgreSQL rejects an illegal transition
  against the row it actually holds under its own lock — not against a stale
  copy the caller loaded. That is what makes CORE-06 and CORE-07 database
  guarantees rather than conventions, and it is conditional on every change on
  a state-changing action staying atomic.

  The audit write is the thing a developer would naturally reach for as a
  post-action-style change hook on `:answer`. Do not do that:
  `Ash.Resource.Change.AfterAction` has no `atomic/3`, so adding one forces
  this action's atomicity requirement off — which compiles, passes every
  happy-path test, and silently downgrades the action to read-modify-write —
  destroying the guarantee while looking correct. The audit write lives in
  `Ash.transaction/3` at the `Humanport.Requests` domain-function level
  instead (see `answer/3`, `approve/2`, `reject/2`), never as a change on
  this resource.

  ## The terminal-row trigger (CORE-07, T-01-14)

  `postgres.custom_statements` below declares
  `human_requests_terminal_is_final()`, a `BEFORE UPDATE` trigger that raises
  whenever `OLD.completed_at` is already set — regardless of which code path
  issued the `UPDATE`. The atomic transition guard and the atomic
  `completed_at` filter on `:answer`/`:approve`/`:reject` are the mechanisms
  that produce CORE-07's *deterministic conflict result* for a losing
  concurrent responder going through those actions; this trigger is a
  backstop for every other code path — a console session, a future script, a
  mistake in a later phase. Its error is deliberately ugly on purpose:
  reaching it means something bypassed the domain. It does **not** stand in
  for §54.8 content-binding (that is the content-hash-bound approval record,
  SEC-08, Phase 4, not yet built), and it does not stop the table owner from
  dropping the table or disabling the trigger — the same D-14 limit already
  accepted for the audit trigger.
  """

  use Ash.Resource,
    domain: Humanport.Requests,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "human_requests"
    repo Humanport.Repo

    custom_indexes do
      # The inbox query (D-05 tenant scoping, D-16 open/answered toggle).
      index [:tenant_id, :state, :inserted_at]
    end

    # T-01-14 / Pattern 4(c) — the terminal-row trigger. Defends against
    # every code path that is NOT one of the atomic actions above (console
    # access, a future script, a mistake in a later phase). See the
    # moduledoc section "The terminal-row trigger" for what this does and
    # does not cover. Same two-statement shape as the audit_events
    # append-only trigger in `Humanport.Audit.Event` (D-14's own reasoning
    # applies identically here): a function, then a row-level trigger using
    # it.
    custom_statements do
      statement :human_requests_terminal_is_final_fn do
        up """
        CREATE OR REPLACE FUNCTION human_requests_terminal_is_final() RETURNS trigger AS $$
        BEGIN
          IF OLD.completed_at IS NOT NULL THEN
            RAISE EXCEPTION 'human_request % is already terminal (state=%)', OLD.id, OLD.state
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS human_requests_terminal_is_final();"
      end

      statement :human_requests_terminal_is_final_trigger do
        after_tables ["human_requests"]

        up """
        CREATE TRIGGER human_requests_terminal_is_final
          BEFORE UPDATE ON human_requests
          FOR EACH ROW EXECUTE FUNCTION human_requests_terminal_is_final();
        """

        down "DROP TRIGGER IF EXISTS human_requests_terminal_is_final ON human_requests;"
      end
    end
  end

  # Phase 1 has exactly four states: `pending` is the initial and only
  # non-terminal state (D-21 — no translation layer, `pending` is the literal
  # domain/API/UI token); `answered`, `approved` and `rejected` are terminal.
  # `routed` and `viewed` are §11 candidate states that only start
  # distinguishing anything once routing exists — they belong to Phase 5 and
  # must not be introduced here.
  #
  # Plan 01-02 declared only `:answer` here — `approved`/`rejected` were
  # reserved via `extra_states` because AshStateMachine's own
  # `VerifyTransitionActions` verifier rejects a declared transition whose
  # `action:` does not already exist, and the `:approve`/`:reject` actions
  # were deferred to this plan. Now that both actions exist below, their
  # transitions are declared here instead of `extra_states` — the union of
  # every transition's `from`/`to` plus `initial_states` still resolves to
  # the same four-state set the first migration already carries (see
  # `AshStateMachine.Transformers.FillInTransitionDefaults`), so this is not
  # a schema change.
  state_machine do
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :answer, from: :pending, to: :answered
      transition :approve, from: :pending, to: :approved
      transition :reject, from: :pending, to: :rejected
    end
  end

  actions do
    defaults [:read]

    # D-16 — the inbox's single open/answered toggle. Business logic
    # (which states count as "open" vs "answered") belongs here, in the
    # domain, not as a filter clause built inline in InboxLive. Both are
    # served by the same `[:tenant_id, :state, :inserted_at]` composite
    # index the resource already declares above.
    read :open do
      prepare build(filter: expr(state == :pending), sort: [inserted_at: :desc])
    end

    read :answered do
      prepare build(
                filter: expr(state in [:answered, :approved, :rejected]),
                sort: [completed_at: :desc]
              )
    end

    create :submit do
      # `tenant_id` is NEVER accepted from the wire (D-05) — it is set below
      # from application config, not by the caller.
      accept [
        :type,
        :title,
        :description,
        :context,
        :subject,
        :source,
        :external_correlation,
        :requester_label,
        :risk,
        :reversible
      ]

      # D-06 — the enum carries all four §6.2 values, only `ask` and `approve`
      # are implemented. An unimplemented type must never look like a working
      # one: this is an explicit, boundary-mapped rejection, not silence.
      validate one_of(:type, [:ask, :approve]),
        message: "request type is not implemented in this version"

      change set_attribute(:requester_verified, false)
      change {Humanport.Requests.Changes.SetTenantId, []}
    end

    update :answer do
      argument :answer, :string, allow_nil?: false

      # Pattern 4(b) — an explicit, atomic-safe widening of what counts as a
      # conflict. Composes with the atomic transition guard below without
      # breaking atomicity.
      change filter(expr(is_nil(completed_at)))
      change set_attribute(:answer, arg(:answer))
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:answered)
      change {Humanport.Requests.Changes.SetDecidedBy, []}
      # NO `change after_action(...)` here — see the moduledoc landmine.
    end

    # Shaped exactly like `:answer` above, on purpose — same atomicity
    # property, same absence of any non-atomic change. Only the target
    # decision/state and the transition differ.
    update :approve do
      change filter(expr(is_nil(completed_at)))
      change set_attribute(:decision, :approved)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:approved)
      change {Humanport.Requests.Changes.SetDecidedBy, []}
    end

    update :reject do
      change filter(expr(is_nil(completed_at)))
      change set_attribute(:decision, :rejected)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change transition_state(:rejected)
      change {Humanport.Requests.Changes.SetDecidedBy, []}
    end
  end

  # BOTH the per-request topic `request:<id>` and the firehose topic
  # `requests` — InboxLive subscribes to the firehose, RequestLive to its own
  # request (D-15, plan 01-04's long-poll also subscribes per-request).
  # `Ash.Notifier.PubSub` batches and dispatches only after the transaction
  # commits (see `Humanport.Requests.submit/2` / `answer/3`) — never hand-roll
  # `Endpoint.broadcast/3` in a hook, which would fire before commit.
  pub_sub do
    module HumanportWeb.Endpoint
    broadcast_type :phoenix_broadcast

    publish_all :create, ["request", :id]
    publish_all :create, "requests"
    publish_all :update, ["request", :id]
    publish_all :update, "requests"
  end

  attributes do
    # D-20 — UUIDv7 stays for its time ordering and index locality. The short
    # id shown in the UI is derived from the LAST five hex characters, never
    # the first (a token from the front of a v7 UUID is shared by every
    # request created in the same ~3.1-day window).
    uuid_v7_primary_key :id

    # D-05 — present from the first migration, with no tenancy logic behind
    # it. Never accepted from the wire; set from application config below.
    attribute :tenant_id, :uuid, allow_nil?: false, public?: true

    # D-06 — all four §6.2 values live in the enum now so Phase 5 needs no
    # `ALTER TYPE`; only :ask and :approve are implemented (validated above).
    attribute :type, :atom,
      constraints: [one_of: [:ask, :choose, :approve, :escalate]],
      allow_nil?: false,
      public?: true

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true

    # D-07 — a single jsonb column, no typed context columns yet.
    attribute :context, :map, public?: true

    # D-08 — the narrow embedded subject: type + id + label.
    attribute :subject, Humanport.Requests.Subject, public?: true

    # D-04, §6.1 — the agent's own optional correlation value, carried
    # through unchanged under the canonical field name.
    attribute :source, :string, public?: true
    attribute :external_correlation, :string, public?: true

    # D-24 — nullable, agent-stated only. Never defaulted, never derived from
    # a policy. Absent risk must never render as "stated low risk".
    attribute :risk, :atom, constraints: [one_of: [:high, :medium, :low]], public?: true
    attribute :reversible, :string, public?: true

    # D-12 — the requesting agent's label, recorded honestly as unverified.
    attribute :requester_label, :string, public?: true
    attribute :requester_verified, :boolean, default: false, allow_nil?: false, public?: true

    attribute :answer, :string, public?: true
    attribute :decision, :atom, constraints: [one_of: [:approved, :rejected]], public?: true
    # D-11 — an actor snapshot (see Humanport.Requests.Changes.SetDecidedBy),
    # not a foreign key: who answered must stay legible even if the acting
    # actor's own record later changes.
    attribute :decided_by, :map, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
