defmodule ValkkaWeb.PageControllerTest do
  use ValkkaWeb.ConnCase

  test "GET / renders dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Valkka"
  end
end
