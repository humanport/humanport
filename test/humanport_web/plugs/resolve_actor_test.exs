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

    test "with no session snapshot, raises HumanportWeb.UnauthorizedError rather than redirecting" do
      assert_raise HumanportWeb.UnauthorizedError, fn ->
        HumanportWeb.Plugs.ResolveActor.on_mount(:default, %{}, %{}, bare_socket())
      end
    end

    test "with a verified-actor session snapshot, resolves and continues" do
      snapshot = %{
        "id" => nil,
        "type" => "human",
        "label" => "owner@example.com",
        "verified" => true,
        "method" => "sso"
      }

      session = %{"hp_resolved_actor" => snapshot}

      assert {:cont, updated_socket} =
               HumanportWeb.Plugs.ResolveActor.on_mount(:default, %{}, session, bare_socket())

      assert updated_socket.assigns.actor.verified? == true
    end
  end

  describe "the session relay end to end (02-02-PLAN.md Task 1) — a REAL connected LiveView, not a synthetic socket" do
    # Phoenix does not expose raw cookies (or `:session`) to
    # `get_connect_info/2` at all (see `Resolvers.CloudflareAccess`'s
    # moduledoc) — the synthetic `bare_socket/1` tests above prove
    # `on_mount/4`'s own logic in isolation but cannot catch a break in the
    # ACTUAL relay between `call/2`'s `put_session/3` and the `session`
    # argument Phoenix threads into `on_mount/4` on a real dead render and
    # reconnect, since that relay only exists on the real, compiled
    # `HumanportWeb.Endpoint`/router/live_session wiring. `live/2` drives
    # the request through that real endpoint, so this is the test that
    # would have caught the `:cookies` mistake this task's own
    # research/plan made.
    setup :with_cloudflare_access_resolver

    test "a genuine token on the dead render lets the connected reconnect resolve too", %{
      conn: conn
    } do
      request = Humanport.Fixtures.request_fixture()
      token = Fixtures.signed_token()

      conn = put_req_header(conn, "cf-access-jwt-assertion", token)

      assert {:ok, _view, html} = live(conn, ~p"/requests/#{request.id}")
      assert html =~ request.title
    end
  end

  defp bare_socket, do: %Phoenix.LiveView.Socket{private: %{}}

  defp with_cloudflare_access_resolver(_context) do
    original_resolver = Application.fetch_env!(:humanport, :actor_resolver)

    Application.put_env(:humanport, :actor_resolver, Humanport.Actors.Resolvers.CloudflareAccess)

    on_exit(fn ->
      Application.put_env(:humanport, :actor_resolver, original_resolver)
    end)

    :ok
  end
end
