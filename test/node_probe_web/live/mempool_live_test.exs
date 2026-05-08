defmodule NodeProbeWeb.MempoolLiveTest do
  use NodeProbeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "renders initial state", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/mempool")
    assert html =~ "Transactions"
    assert html =~ "Mempool"
  end

  test "updates tx count and size on mempool event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mempool")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_mempool, %{"size" => 5123, "bytes" => 7_340_032, "mempoolminfee" => 1}})

    rendered = render(view)
    assert rendered =~ "5123"
    assert rendered =~ "7.34 MB"
  end

  test "displays min fee rate", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mempool")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_mempool, %{"size" => 100, "bytes" => 100_000, "mempoolminfee" => 3}})

    assert render(view) =~ "3 sat/vB"
  end
end
