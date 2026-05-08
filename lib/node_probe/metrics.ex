defmodule NodeProbe.Metrics do
  @moduledoc """
  In-memory rolling metrics store backed by ETS.

  Maintains:
  - Last 60 seconds of latency samples (histogram buckets)
  - Syscall frequency counters per syscall type
  - Per-peer byte counters
  - Mempool size history (last 10 minutes)
  - Block arrival times
  """

  @table :node_probe_metrics
  @latency_window_s 60
  @mempool_window_s 600

  def start_link(_opts \\ []) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])

      _ ->
        :ok
    end

    {:ok, self()}
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # ---------------------------------------------------------------------------
  # Latency samples
  # ---------------------------------------------------------------------------

  def record_latency(op, latency_ns) when op in [:read, :write, :blk] do
    bucket = latency_bucket(latency_ns)
    key = {:latency, op, bucket, timestamp_s()}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    purge_old_latency()
  end

  def latency_histogram(op) do
    now = timestamp_s()
    cutoff = now - @latency_window_s

    :ets.match_object(@table, {{:latency, op, :_, :"$1"}, :_})
    |> Enum.filter(fn {{_, _, _, ts}, _} -> ts >= cutoff end)
    |> Enum.group_by(fn {{_, _, bucket, _}, _} -> bucket end, fn {_, count} -> count end)
    |> Map.new(fn {bucket, counts} -> {bucket, Enum.sum(counts)} end)
  end

  # ---------------------------------------------------------------------------
  # Syscall counters
  # ---------------------------------------------------------------------------

  def increment_syscall(syscall_name) do
    key = {:syscall_count, syscall_name}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  def syscall_counts do
    :ets.match_object(@table, {{:syscall_count, :_}, :_})
    |> Map.new(fn {{_, name}, count} -> {name, count} end)
  end

  def reset_syscall_counts do
    :ets.match_delete(@table, {{:syscall_count, :_}, :_})
  end

  # ---------------------------------------------------------------------------
  # Per-peer byte counters
  # ---------------------------------------------------------------------------

  def record_peer_bytes(peer_id, direction, bytes)
      when direction in [:sent, :recv] and is_integer(bytes) do
    key = {:peer_bytes, peer_id, direction}
    :ets.update_counter(@table, key, {2, bytes}, {key, 0})
  end

  def peer_bytes(peer_id) do
    sent =
      case :ets.lookup(@table, {:peer_bytes, peer_id, :sent}) do
        [{_, n}] -> n
        [] -> 0
      end

    recv =
      case :ets.lookup(@table, {:peer_bytes, peer_id, :recv}) do
        [{_, n}] -> n
        [] -> 0
      end

    %{sent: sent, recv: recv}
  end

  # ---------------------------------------------------------------------------
  # Mempool size history
  # ---------------------------------------------------------------------------

  def record_mempool_size(size) when is_integer(size) do
    ts_ms = System.monotonic_time(:millisecond)
    seq = System.unique_integer([:monotonic])
    :ets.insert(@table, {{:mempool_history, ts_ms, seq}, size})
    purge_old_mempool()
  end

  def mempool_history do
    cutoff_ms = System.monotonic_time(:millisecond) - @mempool_window_s * 1_000

    :ets.match_object(@table, {{:mempool_history, :"$1", :_}, :_})
    |> Enum.filter(fn {{_, ts_ms, _}, _} -> ts_ms >= cutoff_ms end)
    |> Enum.map(fn {{_, ts_ms, _}, size} -> {ts_ms, size} end)
    |> Enum.sort_by(fn {ts_ms, _} -> ts_ms end)
  end

  # ---------------------------------------------------------------------------
  # Block arrival times
  # ---------------------------------------------------------------------------

  def record_block_arrival(height, hash) do
    ts_ms = System.monotonic_time(:millisecond)
    :ets.insert(@table, {{:block_arrival, height}, %{hash: hash, ts: ts_ms}})
  end

  def recent_block_arrivals(count \\ 10) do
    :ets.match_object(@table, {{:block_arrival, :_}, :_})
    |> Enum.map(fn {{_, height}, data} -> Map.put(data, :height, height) end)
    |> Enum.sort_by(& &1.ts, :desc)
    |> Enum.take(count)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp timestamp_s, do: System.os_time(:second)

  defp latency_bucket(ns) do
    cond do
      ns < 1_000 -> "<1µs"
      ns < 10_000 -> "1-10µs"
      ns < 100_000 -> "10-100µs"
      ns < 1_000_000 -> "100µs-1ms"
      ns < 10_000_000 -> "1-10ms"
      ns < 100_000_000 -> "10-100ms"
      true -> ">100ms"
    end
  end

  defp purge_old_latency do
    cutoff = timestamp_s() - @latency_window_s
    :ets.select_delete(@table, [{{{:latency, :_, :_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp purge_old_mempool do
    cutoff_ms = System.monotonic_time(:millisecond) - @mempool_window_s * 1_000
    :ets.select_delete(@table, [{{{:mempool_history, :"$1", :_}, :_}, [{:<, :"$1", cutoff_ms}], [true]}])
  end
end
