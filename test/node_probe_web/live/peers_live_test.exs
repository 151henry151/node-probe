defmodule NodeProbeWeb.PeersLiveTest do
  use NodeProbeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp sample_peers do
    [
      %{"id" => 1, "addr" => "1.2.3.4:8333", "version" => 70_016, "subver" => "/Satoshi:26.0.0/", "services" => "000000000000040d", "pingtime" => 0.045, "bytessent" => 100_000, "bytesrecv" => 500_000, "conntime" => 1_716_000_000, "inbound" => false},
      %{"id" => 2, "addr" => "5.6.7.8:8333", "version" => 70_015, "subver" => "/Satoshi:25.0.0/", "services" => "000000000000040d", "pingtime" => 0.120, "bytessent" => 50_000, "bytesrecv" => 200_000, "conntime" => 1_716_000_000, "inbound" => true}
    ]
  end

  test "renders empty state with no peers", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/peers")
    assert html =~ "No peers connected"
  end

  test "renders peer table when peers arrive", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/peers")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_peers, sample_peers()})

    rendered = render(view)
    assert rendered =~ "1.2.3.4:8333"
    assert rendered =~ "5.6.7.8:8333"
    assert rendered =~ "45 ms"
  end

  test "shows correct peer count", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/peers")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_peers, sample_peers()})

    assert render(view) =~ "2 peers"
  end

  test "distinguishes inbound and outbound peers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/peers")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_peers, sample_peers()})

    rendered = render(view)
    assert rendered =~ "↑ out"
    assert rendered =~ "↓ in"
  end
end
