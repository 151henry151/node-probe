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
  @recent_path_slots 50

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

  @doc """
  Apply one decoded loader JSON object into ETS. Keeps hot-path work out of PubSub so RPC
  aggregation is not starved when syscall throughput is high.
  """
  def ingest_ebpf(%{} = event) do
    case event["type"] do
      "syscall" -> ingest_syscall_event(event)
      "latency" -> ingest_latency_event(event)
      "net" -> ingest_net_event(event)
      _ -> :ok
    end
  end

  def ingest_ebpf(_), do: :ok

  defp ingest_syscall_event(event) do
    syscall = event["syscall"] || "unknown"
    increment_syscall(syscall)

    filename = event["filename"] || ""

    if filename != "" do
      prefix = path_prefix(filename)
      pk = {:path_prefix, prefix}
      :ets.update_counter(@table, pk, {2, 1}, {pk, 0})
      push_recent_path(filename, event["ts"])
    end

    :ok
  end

  defp ingest_latency_event(event) do
    op =
      case event["op"] do
        "read" -> :read
        "write" -> :write
        _ -> :blk
      end

    bytes = event["bytes"] || 0

    if op in [:read, :write] and is_integer(bytes) and bytes > 0 do
      record_vfs_bytes(op, bytes)
    end

    record_latency(op, event["latency_ns"] || 0)
    :ok
  end

  defp ingest_net_event(event) do
    state = event["state_change"] || "unknown"
    ts = timestamp_s()
    key = {:tcp_state, state, ts}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    purge_old_tcp_states()
    :ok
  end

  defp record_vfs_bytes(op, bytes) when op in [:read, :write] do
    ts = timestamp_s()
    key = {:vfs_bytes, op, ts}
    :ets.update_counter(@table, key, {2, bytes}, {key, 0})
    purge_old_vfs_bytes()
  end

  @doc """
  Sum of VFS bytes (`vfs_read` / `vfs_write` return values) in the latency rolling window.
  """
  def vfs_bytes_totals(op) when op in [:read, :write] do
    now = timestamp_s()
    cutoff = now - @latency_window_s

    :ets.match_object(@table, {{:vfs_bytes, op, :"$1"}, :_})
    |> Enum.filter(fn {{_, _, ts}, _} -> ts >= cutoff end)
    |> Enum.map(fn {_, n} -> n end)
    |> Enum.sum()
  end

  @doc """
  TCP `inet_sock_set_state` transitions per new state label in the rolling window.
  """
  def tcp_state_counts do
    now = timestamp_s()
    cutoff = now - @latency_window_s

    :ets.match_object(@table, {{:tcp_state, :_, :"$1"}, :_})
    |> Enum.filter(fn {{_, _, ts}, _} -> ts >= cutoff end)
    |> Enum.reduce(%{}, fn {{_, state, _}, count}, acc ->
      Map.update(acc, state, count, &(&1 + count))
    end)
  end

  @doc "Total latency histogram samples in the window (read or write)."
  def latency_sample_total(op) when op in [:read, :write] do
    latency_histogram(op)
    |> Map.values()
    |> Enum.sum()
  end

  defp push_recent_path(filename, ts) do
    slot =
      :ets.update_counter(@table, :recent_path_cursor, {2, 1}, {:recent_path_cursor, 0})
      |> rem(@recent_path_slots)

    :ets.insert(@table, {{:recent_path, slot}, {filename, ts}})
    :ok
  end

  defp path_prefix(filename) do
    cond do
      String.contains?(filename, "/blocks/") -> "blocks/"
      String.contains?(filename, "/chainstate/") -> "chainstate/"
      String.contains?(filename, "/wallets/") -> "wallets/"
      String.contains?(filename, "/indexes/") -> "indexes/"
      filename == "" -> "unknown"
      true -> "other"
    end
  end

  def syscall_counts do
    :ets.match_object(@table, {{:syscall_count, :_}, :_})
    |> Map.new(fn {{_, name}, count} -> {name, count} end)
  end

  def reset_syscall_counts do
    :ets.match_delete(@table, {{:syscall_count, :_}, :_})
  end

  def path_prefix_counts do
    :ets.match_object(@table, {{:path_prefix, :_}, :_})
    |> Map.new(fn {{:path_prefix, name}, count} -> {name, count} end)
  end

  def recent_paths(limit \\ @recent_path_slots) do
    :ets.match_object(@table, {{:recent_path, :_}, :_})
    |> Enum.map(fn {_, {filename, ts}} -> %{filename: filename, ts: ts} end)
    |> Enum.sort_by(& &1.ts, :desc)
    |> Enum.uniq_by(& &1.filename)
    |> Enum.take(limit)
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

  defp purge_old_vfs_bytes do
    cutoff = timestamp_s() - @latency_window_s

    :ets.select_delete(@table, [
      {{{:vfs_bytes, :_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  defp purge_old_tcp_states do
    cutoff = timestamp_s() - @latency_window_s

    :ets.select_delete(@table, [
      {{{:tcp_state, :_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  defp purge_old_mempool do
    cutoff_ms = System.monotonic_time(:millisecond) - @mempool_window_s * 1_000

    :ets.select_delete(@table, [
      {{{:mempool_history, :"$1", :_}, :_}, [{:<, :"$1", cutoff_ms}], [true]}
    ])
  end
end
