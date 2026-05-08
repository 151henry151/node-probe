defmodule NodeProbeWeb.PageControllerTest do
  use NodeProbeWeb.ConnCase

  test "GET / redirects to PulseLive", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "node-probe"
  end
end
