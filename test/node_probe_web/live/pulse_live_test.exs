defmodule NodeProbeWeb.PulseLiveTest do
  use NodeProbeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "renders default state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Pulse"
    assert html =~ "Chain Height"
    assert html =~ "Peers"
    assert html =~ "Mempool"
    assert html =~ "eBPF"
  end

  test "updates chain height on aggregated_chain event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_chain, %{"blocks" => 840_000, "initialblockdownload" => false, "verificationprogress" => 1.0}})

    assert render(view) =~ "840000"
  end

  test "updates peer count on aggregated_peers event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    peers = [%{"id" => 1, "inbound" => false}, %{"id" => 2, "inbound" => true}]
    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_peers, peers})

    assert render(view) =~ "2"
  end

  test "shows IBD progress bar when syncing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_chain, %{"blocks" => 100_000, "initialblockdownload" => true, "verificationprogress" => 0.42}})

    rendered = render(view)
    assert rendered =~ "progress"
    assert rendered =~ "42"
  end

  test "shows event in ticker on anomaly event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:anomaly, %{category: :bitcoin, severity: :info, description: "Test event", ts: 1_716_000_000}})

    assert render(view) =~ "Test event"
  end
end
