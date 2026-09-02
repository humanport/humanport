defmodule HumanportWeb.Plugs.ResolveActor do
  @moduledoc """
  Calls the configured `Humanport.Actors.Resolver` (D-09) and assigns the
  resulting `%Humanport.Actors.Actor{}` — as `conn.assigns.actor` for plain
  HTTP requests (`call/2`), and as `socket.assigns.actor` for LiveView
  (`on_mount/4`, wired via `live_session`). This is the only place either
  surface decides identity; everything downstream receives the resolved
  struct, never a raw header or session value.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {:ok, actor} = resolver().resolve(conn)
    assign(conn, :actor, actor)
  end

  @doc false
  def on_mount(:default, _params, _session, socket) do
    {:ok, actor} = resolver().resolve(socket)
    {:cont, Phoenix.Component.assign(socket, :actor, actor)}
  end

  defp resolver, do: Application.fetch_env!(:humanport, :actor_resolver)
end
