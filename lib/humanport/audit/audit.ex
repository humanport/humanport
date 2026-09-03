defmodule Humanport.Audit do
  @moduledoc """
  The audit domain (D-13, D-14, SEC-07, §23). Knows nothing about request
  internals — `record/2` receives primitives only, never a
  `%Humanport.Requests.HumanRequest{}`.
  """

  use Ash.Domain

  resources do
    resource Humanport.Audit.Event do
      # RequestTimeline's data source (plan 01-05) — a request's own audit
      # trail, oldest first.
      define :list_events_for_request, action: :for_request, args: [:request_id]
    end
  end

  alias Humanport.Actors.Actor
  alias Humanport.Audit.Event

  @doc """
  Writes one §23 audit event. `event_type` is a string like
  `"request.created"` / `"request.responded"`. `attrs` is a plain map:
  `tenant_id`, `request_id`, `resource_type`, `resource_id`, `previous_state`,
  `new_state` (atoms or strings, normalized to strings), `actor`
  (`%Humanport.Actors.Actor{}`, required), and an optional `metadata` map
  (defaults to `%{}` — §23 forbids automatically copying sensitive payloads
  in here; pass `%{}` unless there is a specific non-sensitive fact worth
  recording).

  Always call from inside the same `Ash.transaction/3` as the domain write it
  documents (see `Humanport.Requests.submit/2` / `answer/3`) — never call this
  from an action hook, and never call `Logger` *instead of* this (§24).
  """
  def record(event_type, attrs) when is_binary(event_type) and is_map(attrs) do
    %Actor{} = actor = Map.fetch!(attrs, :actor)

    params = %{
      event_type: event_type,
      occurred_at: DateTime.utc_now(),
      tenant_id: Map.fetch!(attrs, :tenant_id),
      request_id: Map.fetch!(attrs, :request_id),
      actor_id: actor.id,
      actor_type: actor.type,
      actor_label: actor.label,
      actor_verified: actor.verified?,
      actor_method: actor.method,
      resource_type: Map.fetch!(attrs, :resource_type),
      resource_id: Map.fetch!(attrs, :resource_id),
      previous_state: normalize_state(Map.get(attrs, :previous_state)),
      new_state: normalize_state(Map.get(attrs, :new_state)),
      correlation_id: Map.get(attrs, :correlation_id),
      source_protocol: Map.get(attrs, :source_protocol),
      source_identifier: Map.get(attrs, :source_identifier),
      metadata: Map.get(attrs, :metadata, %{})
    }

    Event
    |> Ash.Changeset.for_create(:create, params)
    |> Ash.create()
  end

  defp normalize_state(nil), do: nil
  defp normalize_state(state) when is_atom(state), do: Atom.to_string(state)
  defp normalize_state(state) when is_binary(state), do: state
end
