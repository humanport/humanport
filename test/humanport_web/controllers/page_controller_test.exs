defmodule HumanportWeb.PageControllerTest do
  use HumanportWeb.ConnCase

  test "GET / redirects to the inbox", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/requests"
  end

  test "the root no longer claims the inbox is unbuilt", %{conn: conn} do
    # Guards the specific regression this replaced: plan 01-01's placeholder
    # outlived the inbox it was standing in for and kept telling visitors the
    # inbox did not exist. A redirect cannot carry that text; a re-added
    # placeholder page could.
    body = conn |> get(~p"/") |> response(302)
    refute body =~ "not built yet"
  end
end
