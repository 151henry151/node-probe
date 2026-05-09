defmodule NodeProbeWeb.FeeFormat do
  @moduledoc """
  Display helpers for fee rates. Bitcoin Core reports `mempoolminfee` in **BTC per kB**;
  users expect **sat/vB** (satoshis per virtual byte).
  """

  @doc """
  Converts `getmempoolinfo` / `mempoolminfee` from BTC/kB to sat/vB.
  """
  def mempool_min_fee_sat_vb(btc_per_kb) when is_number(btc_per_kb) do
    btc_per_kb * 100_000
  end

  @doc """
  Formats a fee rate in sat/vB without scientific notation (avoids `1.0e-6`-style output).
  """
  def format_sat_per_vb(n) when is_number(n) do
    n = n * 1.0

    cond do
      n >= 100 ->
        :erlang.float_to_binary(n, decimals: 0)

      n >= 10 ->
        :erlang.float_to_binary(n, decimals: 1)

      n >= 1 ->
        :erlang.float_to_binary(n, decimals: 2)

      n > 0 ->
        n
        |> :erlang.float_to_binary(decimals: 8)
        |> trim_trailing_zeros()

      true ->
        "0"
    end
  end

  defp trim_trailing_zeros(str) do
    str
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end
end
