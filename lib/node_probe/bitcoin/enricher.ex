defmodule NodeProbe.Bitcoin.Enricher do
  @moduledoc """
  Enriches raw Bitcoin Core RPC data into typed structs.

  Bitcoin Core's verbose RPC responses already include fee, weight, vsize,
  and script type information. This module normalises that data into our
  internal types and computes derived fields (fee rates, breakdowns, etc.).
  """

  alias NodeProbe.Bitcoin.Types.{Block, Tx, Peer, MempoolEntry}

  @satoshis_per_btc 100_000_000

  @doc """
  Enriches a raw `getblock` (verbosity=2) response into a `%Block{}`.
  """
  def enrich_block(raw) when is_map(raw) do
    txs = Map.get(raw, "tx", [])
    total_fees_sat = calculate_total_fees_sat(txs)
    median_fee_rate = calculate_median_fee_rate(txs)
    breakdown = spend_type_breakdown(txs)

    %Block{
      hash: raw["hash"],
      height: raw["height"],
      timestamp: raw["time"],
      tx_count: length(txs),
      total_fees_sat: total_fees_sat,
      weight: raw["weight"],
      median_fee_rate: median_fee_rate,
      spend_type_breakdown: breakdown
    }
  end

  @doc """
  Enriches a raw verbose transaction map into a `%Tx{}`.

  Expects the transaction to include a `"fee"` field in BTC (as returned by
  `getblock` with verbosity 2 or `getrawtransaction` with verbose=true).
  """
  def enrich_tx(raw) when is_map(raw) do
    fee_sat = btc_to_sat(raw["fee"] || 0)
    weight = raw["weight"] || compute_weight(raw)
    vsize = ceil(weight / 4)
    fee_rate = if vsize > 0, do: fee_sat / vsize, else: 0.0

    vouts = Map.get(raw, "vout", [])
    total_output_sat = vouts |> Enum.map(&btc_to_sat(&1["value"] || 0)) |> Enum.sum()
    spend_types = classify_outputs(vouts)

    %Tx{
      txid: raw["txid"],
      fee_sat: fee_sat,
      fee_rate_svb: fee_rate,
      weight: weight,
      input_count: length(Map.get(raw, "vin", [])),
      output_count: length(vouts),
      spend_types: spend_types,
      total_output_sat: total_output_sat
    }
  end

  @doc """
  Enriches a raw peer info map (from `getpeerinfo`) into a `%Peer{}`.
  """
  def enrich_peer(raw) when is_map(raw) do
    %Peer{
      id: raw["id"],
      addr: raw["addr"],
      version: raw["version"],
      subver: raw["subver"],
      services: raw["services"],
      ping_ms: round((raw["pingtime"] || 0) * 1000),
      bytes_sent: raw["bytessent"] || 0,
      bytes_recv: raw["bytesrecv"] || 0,
      connected_since: raw["conntime"],
      inbound: raw["inbound"] || false
    }
  end

  @doc """
  Enriches a raw mempool entry map into a `%MempoolEntry{}`.
  """
  def enrich_mempool_entry(txid, raw) when is_binary(txid) and is_map(raw) do
    fee_sat = btc_to_sat(raw["fee"] || 0)
    weight = raw["weight"] || (raw["vsize"] || 0) * 4
    vsize = ceil(weight / 4)
    fee_rate = if vsize > 0, do: fee_sat / vsize, else: 0.0

    %MempoolEntry{
      txid: txid,
      fee_sat: fee_sat,
      fee_rate_svb: fee_rate,
      weight: weight,
      time: raw["time"],
      height: raw["height"]
    }
  end

  defp calculate_total_fees_sat(txs) do
    txs
    |> Enum.reject(&coinbase?/1)
    |> Enum.map(&btc_to_sat(&1["fee"] || 0))
    |> Enum.sum()
  end

  defp calculate_median_fee_rate(txs) do
    rates =
      txs
      |> Enum.reject(&coinbase?/1)
      |> Enum.map(fn tx ->
        fee_sat = btc_to_sat(tx["fee"] || 0)
        weight = tx["weight"] || 1
        vsize = max(ceil(weight / 4), 1)
        fee_sat / vsize
      end)
      |> Enum.sort()

    case rates do
      [] -> 0.0
      list -> Enum.at(list, div(length(list), 2))
    end
  end

  defp spend_type_breakdown(txs) do
    all_vouts =
      txs
      |> Enum.flat_map(&Map.get(&1, "vout", []))

    all_vouts
    |> Enum.group_by(&script_type/1)
    |> Map.new(fn {type, outs} -> {type, length(outs)} end)
  end

  defp classify_outputs(vouts) do
    vouts
    |> Enum.group_by(&script_type/1)
    |> Map.new(fn {type, outs} -> {type, length(outs)} end)
  end

  defp script_type(%{"scriptPubKey" => %{"type" => type}}), do: type
  defp script_type(_), do: "unknown"

  defp coinbase?(%{"vin" => [%{"coinbase" => _} | _]}), do: true
  defp coinbase?(_), do: false

  defp btc_to_sat(btc) when is_number(btc) do
    round(btc * @satoshis_per_btc)
  end

  defp compute_weight(%{"vsize" => vsize}) when is_integer(vsize), do: vsize * 4
  defp compute_weight(_), do: 0
end
