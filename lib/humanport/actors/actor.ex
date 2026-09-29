defmodule Humanport.Actors.Actor do
  @moduledoc """
  The resolved acting actor — human, agent, service, or system — passed to every
  domain write path as the Ash `actor:` option. This is the ONLY shape identity
  takes once it leaves `Humanport.Actors.Resolver` (D-09): the domain never sees
  a raw header or session value, only this struct.

  `verified?` is always `false` in Phase 1 (D-11, D-12) — there is no
  authentication yet, so recording an actor as verified would be a lie the
  audit trail could never take back. Phase 2's Cloudflare Access resolver sets
  `verified?: true, method: :sso` for the human actor; the agent-supplied
  `requester_label` stays unverified until Phase 3 (SEC-04/05) replaces it with
  a real revocable credential.

  `role` is set only for an agent-key actor (SEC-02): `:requester` may create
  and read requests, `:responder` may read and decide them, `:admin` may do
  both. Every other actor has `role: nil` and is not restricted by it — a
  human reaching the inbox or the API has already passed whatever gate the
  deployment put in front of it.
  """

  @enforce_keys [:type, :label, :verified?]
  defstruct id: nil, type: nil, label: nil, verified?: false, method: nil, role: nil

  @type actor_type :: :human | :agent | :service | :system

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: actor_type(),
          label: String.t(),
          verified?: boolean(),
          method: atom() | nil,
          role: :requester | :responder | :admin | nil
        }
end
