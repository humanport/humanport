defmodule HumanportWeb.PageController do
  use HumanportWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
