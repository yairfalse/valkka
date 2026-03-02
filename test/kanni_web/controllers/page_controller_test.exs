defmodule KanniWeb.PageControllerTest do
  use KanniWeb.ConnCase

  test "GET / renders dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Känni"
  end
end
