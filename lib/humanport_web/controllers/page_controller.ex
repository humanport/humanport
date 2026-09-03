defmodule HumanportWeb.PageController do
  use HumanportWeb, :controller

  @doc """
  Sends the site root to the inbox.

  Plan 01-01 put a placeholder here to prove the Console token wiring before the
  request domain existed. Plan 01-05 built the real inbox at `/requests`, which
  left the placeholder standing at the front door still telling every visitor the
  inbox "is not built yet" — false, and the first thing anyone opening the
  deployment reads. There is nothing for the root to say that the inbox does not
  say better, so it redirects rather than duplicating it.
  """
  def home(conn, _params) do
    redirect(conn, to: ~p"/requests")
  end
end
