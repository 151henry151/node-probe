defmodule NodeProbeWeb.PageControllerTest do
  use NodeProbeWeb.ConnCase

  test "GET / renders dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "node-probe"
  end
end
