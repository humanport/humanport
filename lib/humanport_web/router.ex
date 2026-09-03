defmodule HumanportWeb.Router do
  use HumanportWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HumanportWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # D-09 — resolves conn.assigns.actor for the dead render; LiveViews get
    # the same struct on every (re)connect via the live_session on_mount below.
    plug HumanportWeb.Plugs.ResolveActor
  end

  # PROTO-01 — the agent-facing HTTP surface. Unauthenticated in Phase 1 by
  # design (§ threat model T-01-11); still resolves an actor so writes carry
  # a recorded (unverified) identity rather than none at all.
  pipeline :api do
    plug :accepts, ["json"]
    plug HumanportWeb.Plugs.ResolveActor
  end

  # OPS-06, D-06/D-07 — deliberately NOT ResolveActor. `/health` and `/ready`
  # must keep answering even when the actor resolver itself is what is
  # broken; see HealthController's own moduledoc for the full reasoning.
  pipeline :health do
    plug :accepts, ["json"]
  end

  scope "/", HumanportWeb do
    pipe_through :health

    get "/health", HealthController, :health
    get "/ready", HealthController, :ready
  end

  scope "/", HumanportWeb do
    pipe_through :browser

    get "/", PageController, :home

    live_session :requests, on_mount: [HumanportWeb.Plugs.ResolveActor] do
      live "/requests", InboxLive, :index
      live "/requests/:id", RequestLive, :show
    end
  end

  scope "/api/v1", HumanportWeb do
    pipe_through :api

    post "/requests", RequestController, :create
    get "/requests/:id", RequestController, :show
    post "/requests/:id/respond", RequestController, :respond
  end
end
