defmodule NodeProbeWeb.BlockLiveTest do
  use NodeProbeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "renders empty state before first block", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/block")
    assert html =~ "Waiting for next block"
  end

  test "renders block data when block arrives", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/block")

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

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_block, block})

    rendered = render(view)
    assert rendered =~ "840000"
    assert rendered =~ "10000 sat"
  end

  test "keeps history of last 10 blocks", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/block")

    for i <- 1..12 do
      block = %{
        "hash" => "hash_#{i}",
        "height" => 840_000 + i,
        "time" => 1_716_000_000 + i,
        "weight" => 3_993_000,
        "tx" => []
      }
      Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", {:aggregated_block, block})
    end

    Process.sleep(100)
    rendered = render(view)
    assert rendered =~ "840012"
    refute rendered =~ "840001"
  end
end
