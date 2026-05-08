defmodule NodeProbeWeb.AnomalyLiveTest do
  use NodeProbeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "renders empty state before any events", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/anomalies")
    assert html =~ "No events yet"
    assert html =~ "Anomalies"
  end

  test "shows anomaly events in the feed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/anomalies")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:anomaly, %{category: :bitcoin, severity: :info, description: "Block 840000 arrived after 587s gap", ts: 1_716_000_000}})

    rendered = render(view)
    assert rendered =~ "Block 840000 arrived"
    assert rendered =~ "bitcoin"
  end

  test "shows category badge for each event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/anomalies")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:anomaly, %{category: :kernel, severity: :warn, description: "Latency spike detected", ts: 1_716_000_000}})

    rendered = render(view)
    assert rendered =~ "kernel"
    assert rendered =~ "warn"
  end

  test "accumulates multiple events in reverse chronological order", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/anomalies")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:anomaly, %{category: :bitcoin, severity: :info, description: "First event", ts: 1_716_000_001}})
    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:anomaly, %{category: :peer, severity: :info, description: "Second event", ts: 1_716_000_002}})

    rendered = render(view)
    assert rendered =~ "First event"
    assert rendered =~ "Second event"

    first_pos = :binary.match(rendered, "Second event") |> elem(0)
    second_pos = :binary.match(rendered, "First event") |> elem(0)
    assert first_pos < second_pos
  end
end
