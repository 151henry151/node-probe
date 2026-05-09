defmodule NodeProbeWeb.DashboardLiveTest do
  use NodeProbeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  defp sample_peers do
    [
      %{
        "id" => 1,
        "addr" => "1.2.3.4:8333",
        "version" => 70_016,
        "subver" => "/Satoshi:26.0.0/",
        "services" => "000000000000040d",
        "pingtime" => 0.045,
        "bytessent" => 100_000,
        "bytesrecv" => 500_000,
        "conntime" => 1_716_000_000,
        "inbound" => false
      },
      %{
        "id" => 2,
        "addr" => "5.6.7.8:8333",
        "version" => 70_015,
        "subver" => "/Satoshi:25.0.0/",
        "services" => "000000000000040d",
        "pingtime" => 0.120,
        "bytessent" => 50_000,
        "bytesrecv" => 200_000,
        "conntime" => 1_716_000_000,
        "inbound" => true
      }
    ]
  end

  test "renders unified dashboard sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "node-probe"
    assert html =~ "Overview"
    assert html =~ "Latest block"
    assert html =~ "Mempool"
    assert html =~ "Peers"
    assert html =~ "Kernel I/O"
    assert html =~ "Anomaly log"
  end

  test "legacy paths redirect to dashboard" do
    for path <- ~w(/block /peers /mempool /io /anomalies) do
      conn = build_conn() |> get(path)
      assert redirected_to(conn) == "/"
    end
  end

  test "updates mempool metrics from aggregated_mempool", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    send(
      view.pid,
      {:aggregated_mempool, %{"size" => 100, "bytes" => 100_000, "mempoolminfee" => 0.00001}}
    )

    assert render(view) =~ "1.00 sat/vB"
  end

  test "renders block section when block arrives", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    block = %{
      "hash" => "000000000000000000016a4e1c8e3b1e2c3d4e5f",
      "height" => 840_000,
      "time" => 1_716_000_000,
      "weight" => 3_993_000,
      "tx" => [
        %{"vin" => [%{"coinbase" => "abc"}], "vout" => [], "weight" => 300},
        %{
          "txid" => "tx1",
          "fee" => 0.0001,
          "weight" => 600,
          "vin" => [%{"txid" => "prev", "vout" => 0}],
          "vout" => [%{"value" => 0.5, "scriptPubKey" => %{"type" => "witness_v1_taproot"}}]
        }
      ]
    }

    send(view.pid, {:aggregated_block, block})
    rendered = render(view)
    assert rendered =~ "840000"
    assert rendered =~ "10000 sat"
  end

  test "peer table updates from aggregated_peers", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    send(view.pid, {:aggregated_peers, sample_peers()})
    rendered = render(view)
    assert rendered =~ "1.2.3.4:8333"
    assert rendered =~ "45 ms"
    assert rendered =~ "2 peers"
  end

  test "io section counts syscall events", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    send(view.pid, {:ebpf_event, %{"type" => "syscall", "syscall" => "read", "ts" => 1}})

    rendered = render(view)
    assert rendered =~ "read"
  end

  test "anomaly log receives anomaly events", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    send(
      view.pid,
      {:anomaly,
       %{category: :bitcoin, description: "gap", severity: :info, ts: System.os_time(:second)}}
    )

    rendered = render(view)
    assert rendered =~ "gap"
  end
end
