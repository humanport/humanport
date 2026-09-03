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
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case resolver().resolve(conn) do
      {:ok, actor} ->
        assign(conn, :actor, actor)

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
  def on_mount(:default, _params, _session, socket) do
    case resolver().resolve(socket) do
      {:ok, actor} ->
        {:cont, Phoenix.Component.assign(socket, :actor, actor)}

      {:error, _reason} ->
        raise HumanportWeb.UnauthorizedError
    end
  end

  defp resolver, do: Application.fetch_env!(:humanport, :actor_resolver)
end
