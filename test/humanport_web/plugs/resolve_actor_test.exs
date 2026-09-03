defmodule HumanportWeb.Plugs.ResolveActorTest do
  @moduledoc """
  WR-05/D-02 (01-REVIEW.md, 02-RESEARCH.md Pitfall 6) — the resolver
  contract's error case must reach HTTP as 401, never a `MatchError`/500,
  and must reach a LiveView socket connect as a terminated mount, never a
  redirect loop through `/`. `ResolveActor` has no dedicated test file
  before this plan (confirmed by `find test -iname "*resolve*"` returning
  nothing) — this is that file.

  `async: false`: several tests here swap
  `config :humanport, :actor_resolver` for the duration of a test via
  `Application.put_env/3`, which is process-global state shared by every
  test in the BEAM node — safe within one sequential file, not safe against
  a sibling file mutating the same key concurrently.
  """

  use HumanportWeb.ConnCase, async: false

  alias Humanport.CloudflareAccessFixtures, as: Fixtures

  describe "D-12 guard — no Cloudflare configuration" do
    test "the configured resolver is Resolvers.Env with no Cloudflare env vars set" do
      assert Application.fetch_env!(:humanport, :actor_resolver) == Humanport.Actors.Resolvers.Env
    end
  end

  describe "call/2 through the real :api pipeline, with CloudflareAccess active" do
    setup :with_cloudflare_access_resolver

    test "a missing token returns 401 in the plain-v1 envelope, not a MatchError/500", %{
      conn: conn
    } do
      conn = post(conn, ~p"/api/v1/requests", %{"type" => "ask", "title" => "probe"})

      body = json_response(conn, 401)
      assert body["error"]["code"] == "unauthorized"
    end

    test "a genuine, valid token yields the route's normal 201", %{conn: conn} do
      token = Fixtures.signed_token()

      conn =
        conn
        |> put_req_header("cf-access-jwt-assertion", token)
        |> post(~p"/api/v1/requests", %{"type" => "ask", "title" => "probe"})

      body = json_response(conn, 201)
      assert body["state"] == "pending"
    end
  end

  describe "on_mount/4 through a LiveView socket, with CloudflareAccess active" do
    setup :with_cloudflare_access_resolver

    test "with no cookie, raises HumanportWeb.UnauthorizedError rather than redirecting" do
      socket = bare_socket()

      assert_raise HumanportWeb.UnauthorizedError, fn ->
        HumanportWeb.Plugs.ResolveActor.on_mount(:default, %{}, %{}, socket)
      end
    end

    test "with a genuine token via the CF_Authorization cookie, resolves and continues" do
      token = Fixtures.signed_token()
      socket = bare_socket(%{"CF_Authorization" => token})

      assert {:cont, updated_socket} =
               HumanportWeb.Plugs.ResolveActor.on_mount(:default, %{}, %{}, socket)

      assert updated_socket.assigns.actor.verified? == true
    end
  end

  defp bare_socket(cookies \\ %{}) do
    %Phoenix.LiveView.Socket{
      private: %{live_temp: %{}, connect_info: %{cookies: cookies}}
    }
  end

  defp with_cloudflare_access_resolver(_context) do
    original_resolver = Application.fetch_env!(:humanport, :actor_resolver)

    Application.put_env(:humanport, :actor_resolver, Humanport.Actors.Resolvers.CloudflareAccess)

    on_exit(fn ->
      Application.put_env(:humanport, :actor_resolver, original_resolver)
    end)

    :ok
  end
end
