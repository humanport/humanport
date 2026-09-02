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
  """

  @enforce_keys [:type, :label, :verified?]
  defstruct id: nil, type: nil, label: nil, verified?: false, method: nil

  @type actor_type :: :human | :agent | :service | :system

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: actor_type(),
          label: String.t(),
          verified?: boolean(),
          method: atom() | nil
        }
end
