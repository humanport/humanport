defmodule Humanport.Actors.Resolvers.Env do
  @moduledoc """
  The Phase 1 implementation of the D-09 actor-resolver seam (D-11).

  Reads the acting human's identity from `HUMANPORT_ACTOR_EMAIL`, defaulting
  to `"owner@localhost"` so `docker compose up` produces a functional
  environment with no configuration (OPS-01). Always resolves with
  `verified?: false` — there is no Cloudflare Access tunnel in front locally,
  so an env-var identity must never be recorded, or rendered, as verified.
  `method` stays `nil`; the UI shows a method only when `verified?` is true.

  Configured as the active resolver via `config :humanport, :actor_resolver`
  so Phase 2 can swap in `Humanport.Actors.Resolvers.CloudflareAccess` without
  changing anything that calls `Humanport.Actors.Resolver.resolve/1`.
  """

  @behaviour Humanport.Actors.Resolver

  alias Humanport.Actors.Actor

  @impl true
  def resolve(_source) do
    {:ok,
     %Actor{
       id: nil,
       type: :human,
       label: System.get_env("HUMANPORT_ACTOR_EMAIL", "owner@localhost"),
       verified?: false,
       method: nil
     }}
  end
end
