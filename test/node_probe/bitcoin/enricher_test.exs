defmodule NodeProbe.Bitcoin.EnricherTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias NodeProbe.Bitcoin.Enricher
  alias NodeProbe.Bitcoin.Types.{Block, Tx, Peer, MempoolEntry}

  @sample_tx %{
    "txid" => "abc123",
    "fee" => 0.0001,
    "weight" => 600,
    "vin" => [%{"txid" => "prev", "vout" => 0, "scriptSig" => %{}}],
    "vout" => [
      %{"value" => 0.5, "scriptPubKey" => %{"type" => "witness_v1_taproot"}},
      %{"value" => 0.4999, "scriptPubKey" => %{"type" => "witness_v0_keyhash"}}
    ]
  }

  @coinbase_tx %{
    "txid" => "coinbase_txid",
    "fee" => nil,
    "weight" => 300,
    "vin" => [%{"coinbase" => "03abc123"}],
    "vout" => [%{"value" => 3.125, "scriptPubKey" => %{"type" => "witness_v0_keyhash"}}]
  }

  @sample_block %{
    "hash" => "000000000000000000016a4e1c8e3b1e2c3d4e5f",
    "height" => 840_000,
    "time" => 1_716_000_000,
    "weight" => 3_993_000,
    "tx" => [@coinbase_tx, @sample_tx]
  }

  describe "enrich_tx/1" do
    test "returns a Tx struct" do
      assert %Tx{} = Enricher.enrich_tx(@sample_tx)
    end

    test "sets txid correctly" do
      assert %Tx{txid: "abc123"} = Enricher.enrich_tx(@sample_tx)
    end

    test "converts fee from BTC to satoshis" do
      tx = Enricher.enrich_tx(@sample_tx)
      assert tx.fee_sat == 10_000
    end

    test "fee_sat is always non-negative" do
      tx = Enricher.enrich_tx(Map.put(@sample_tx, "fee", 0.0))
      assert tx.fee_sat >= 0
    end

    test "fee_rate_svb is non-negative" do
      tx = Enricher.enrich_tx(@sample_tx)
      assert tx.fee_rate_svb >= 0.0
    end

    test "computes weight correctly" do
      tx = Enricher.enrich_tx(@sample_tx)
      assert tx.weight == 600
    end

    test "counts inputs" do
      tx = Enricher.enrich_tx(@sample_tx)
      assert tx.input_count == 1
    end

    test "counts outputs" do
      tx = Enricher.enrich_tx(@sample_tx)
      assert tx.output_count == 2
    end

    test "sums total output in satoshis" do
      tx = Enricher.enrich_tx(@sample_tx)
      assert tx.total_output_sat == 99_990_000
    end

    test "classifies output spend types" do
      tx = Enricher.enrich_tx(@sample_tx)
      assert tx.spend_types["witness_v1_taproot"] == 1
      assert tx.spend_types["witness_v0_keyhash"] == 1
    end

    test "handles missing fee field gracefully" do
      tx = Enricher.enrich_tx(Map.delete(@sample_tx, "fee"))
      assert tx.fee_sat == 0
    end
  end

  describe "enrich_block/1" do
    test "returns a Block struct" do
      assert %Block{} = Enricher.enrich_block(@sample_block)
    end

    test "sets hash and height" do
      block = Enricher.enrich_block(@sample_block)
      assert block.hash == "000000000000000000016a4e1c8e3b1e2c3d4e5f"
      assert block.height == 840_000
    end

    test "counts transactions" do
      block = Enricher.enrich_block(@sample_block)
      assert block.tx_count == 2
    end

    test "excludes coinbase from fee totals" do
      block = Enricher.enrich_block(@sample_block)
      assert block.total_fees_sat == 10_000
    end

    test "total_fees_sat is non-negative" do
      block = Enricher.enrich_block(@sample_block)
      assert block.total_fees_sat >= 0
    end

    test "spend_type_breakdown is a map" do
      block = Enricher.enrich_block(@sample_block)
      assert is_map(block.spend_type_breakdown)
    end
  end

  describe "enrich_peer/1" do
    test "returns a Peer struct" do
      raw = %{
        "id" => 42,
        "addr" => "1.2.3.4:8333",
        "version" => 70_016,
        "subver" => "/Satoshi:26.0.0/",
        "services" => "000000000000040d",
        "pingtime" => 0.045,
        "bytessent" => 100_000,
        "bytesrecv" => 500_000,
        "conntime" => 1_716_000_000,
        "inbound" => false
      }

      peer = Enricher.enrich_peer(raw)
      assert %Peer{id: 42, addr: "1.2.3.4:8333"} = peer
      assert peer.ping_ms == 45
      assert peer.inbound == false
    end
  end

  describe "enrich_mempool_entry/2" do
    test "returns a MempoolEntry struct" do
      raw = %{
        "fee" => 0.0001,
        "weight" => 600,
        "time" => 1_716_000_000,
        "height" => 840_000
      }

      entry = Enricher.enrich_mempool_entry("abc123", raw)
      assert %MempoolEntry{txid: "abc123", fee_sat: 10_000} = entry
      assert entry.fee_rate_svb >= 0.0
    end
  end

  describe "property tests" do
    property "fee_sat is always non-negative for any fee value >= 0" do
      check all(fee <- float(min: 0.0, max: 21_000_000.0)) do
        tx = Enricher.enrich_tx(Map.put(@sample_tx, "fee", fee))
        assert tx.fee_sat >= 0
      end
    end

    property "fee_rate_svb is always non-negative" do
      check all(
              fee <- float(min: 0.0, max: 1.0),
              weight <- integer(1..400_000)
            ) do
        raw = Map.merge(@sample_tx, %{"fee" => fee, "weight" => weight})
        tx = Enricher.enrich_tx(raw)
        assert tx.fee_rate_svb >= 0.0
      end
    end

    property "total_output_sat is always non-negative" do
      check all(values <- list_of(float(min: 0.0, max: 100.0), min_length: 1)) do
        vouts =
          Enum.map(values, fn v ->
            %{"value" => v, "scriptPubKey" => %{"type" => "pubkeyhash"}}
          end)

        raw = Map.put(@sample_tx, "vout", vouts)
        tx = Enricher.enrich_tx(raw)
        assert tx.total_output_sat >= 0
      end
    end
  end
end
