defmodule Humanport.Actors.Resolver do
  @moduledoc """
  The D-09 actor-resolver seam — the ONE place the acting actor is decided.

  `HumanportWeb.Plugs.ResolveActor` calls whichever module is configured under
  `config :humanport, :actor_resolver` and assigns the result to
  `conn.assigns.actor` (HTTP) or the LiveView socket (`on_mount`). Every write
  path downstream receives a resolved `%Humanport.Actors.Actor{}`, never a raw
  header or session value — that is what lets Phase 2 swap in
  `Humanport.Actors.Resolvers.CloudflareAccess`, which verifies the JWT against
  Cloudflare's JWKS (D-10), without touching a single write path.

  Do not make trusting a request header the easy path here. A seam that
  invites header-trust now is where Phase 2's JWKS verification gets skipped
  later.
  """

  @callback resolve(source :: term()) ::
              {:ok, Humanport.Actors.Actor.t()} | {:error, term()}
end
