defmodule HumanportWeb.Plugs.ResolveActor do
  @moduledoc """
  Calls the configured `Humanport.Actors.Resolver` (D-09) and assigns the
  resulting `%Humanport.Actors.Actor{}` — as `conn.assigns.actor` for plain
  HTTP requests (`call/2`), and as `socket.assigns.actor` for LiveView
  (`on_mount/4`, wired via `live_session`). This is the only place either
  surface decides identity; everything downstream receives the resolved
  struct, never a raw header or session value.

  D-02/WR-05 — the resolver `@callback` declares
  `{:ok, Actor.t()} | {:error, term()}`. `Resolvers.Env` (Phase 1) never
  returns the error branch, so it stayed latent until
  `Resolvers.CloudflareAccess` (Phase 2) made it live: every missing,
  expired or forged token is exactly that branch. Both `call/2` and
  `on_mount/4` handle it explicitly — `call/2` renders 401 through the same
  `plain-v1` envelope `HumanportWeb.FallbackController` uses, so an
  authentication failure and a validation failure look the same to a
  client; `on_mount/4` raises `HumanportWeb.UnauthorizedError` rather than
  redirecting (see that module's moduledoc for why a redirect loops).

  02-02-PLAN.md Task 1 — the session relay a LiveView socket reconnect
  depends on. Phoenix does not expose raw request cookies to a socket's
  `connect_info` (see `HumanportWeb.Endpoint`'s moduledoc comment on its
  `socket "/live", ...` declaration for why, verified against the
  installed Phoenix/LiveView source) — `Resolvers.CloudflareAccess`'s
  socket clause therefore cannot re-read `CF_Authorization` the way `call/2`
  reads it from a plain `Plug.Conn`. `call/2` closes that gap generically,
  for every resolver, not just Cloudflare's: on every successful resolve it
  snapshots the resolved `%Actor{}` into the Plug session under
  `@actor_session_key`.

  That snapshot reaches `on_mount/4` as its OWN third argument (`session`,
  historically ignored here as `_session`) — NOT via
  `Phoenix.LiveView.get_connect_info(socket, :session)`, which does not
  exist: `:session` is not among the keys `get_connect_info/2` itself
  supports (confirmed by reading `phoenix_live_view`'s own
  `conn_connect_info/2` clauses — only `:peer_data`, `:trace_context_headers`,
  `:x_headers`, `:uri`, `:user_agent`). `connect_info: [session: ...]`
  instead controls what Phoenix decodes INTO that `session` argument itself,
  on both the initial dead render and every reconnect (LiveView re-signs and
  replays it as `phx_session` — see `phoenix_live_view/static.ex`). Since a
  resolver's `@callback resolve/1` takes one `term()`, not a
  `{socket, session}` pair, `on_mount/4` stashes `session` into
  `socket.private` before calling `resolve/1` — `private` is a plain,
  server-only struct field, never sent to the client — so
  `Resolvers.CloudflareAccess` reads it back from there rather than the
  callback contract changing shape. A resolver with no use for it
  (`Resolvers.Env`) simply ignores the extra private key.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Humanport.Actors.Actor

  @behaviour Plug

  # Cross-referenced (not shared as a function call, to avoid a
  # `lib/humanport_web` -> `lib/humanport` -> `lib/humanport_web` layering
  # loop) in `Resolvers.CloudflareAccess`'s own moduledoc and socket clause
  # — keep both literals in sync if this ever changes.
  @actor_session_key "hp_resolved_actor"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case resolver().resolve(conn) do
      {:ok, actor} ->
        conn
        |> assign(:actor, actor)
        |> snapshot_actor_for_liveview(actor)

      {:error, _reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(
          HumanportWeb.RequestJSON.error(%{
            code: "unauthorized",
            message: "Identity could not be resolved.",
            details: %{}
          })
        )
        |> halt()
    end
  end

  @doc false
  def on_mount(:default, _params, session, socket) do
    socket_with_session = put_in(socket.private[:hp_session], session)

    case resolver().resolve(socket_with_session) do
      {:ok, actor} ->
        {:cont, Phoenix.Component.assign(socket, :actor, actor)}

      {:error, _reason} ->
        raise HumanportWeb.UnauthorizedError
    end
  end

  defp resolver, do: Application.fetch_env!(:humanport, :actor_resolver)

  # The `:api` pipeline (router.ex) never plugs `:fetch_session` — guard on
  # the fetch having actually COMPLETED (`:done`, set by `fetch_session/1`;
  # `Plug.Session` alone only stashes a lazy fetch FUNCTION under this same
  # key, so checking mere key presence is not enough) rather than let
  # `put_session/3` raise `ArgumentError` for requests with no LiveView
  # socket to relay identity to anyway.
  defp snapshot_actor_for_liveview(conn, actor) do
    if conn.private[:plug_session_fetch] == :done do
      put_session(conn, @actor_session_key, actor_snapshot(actor))
    else
      conn
    end
  end

  defp actor_snapshot(%Actor{} = actor) do
    %{
      "id" => actor.id,
      "type" => to_string(actor.type),
      "label" => actor.label,
      "verified" => actor.verified?,
      "method" => actor.method && to_string(actor.method)
    }
  end
end
