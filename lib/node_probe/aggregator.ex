defmodule NodeProbe.Aggregator do
  use GenServer
  require Logger

  alias NodeProbe.Metrics

  defstruct [
    :last_block_ts,
    :baseline_latency_p50,
    :session_files
  ]

  def start_link(opts \\ []) do
    gen_opts = if Keyword.has_key?(opts, :name), do: [name: opts[:name]], else: [name: __MODULE__]
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "ebpf:events")
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "rpc:events")

    state = %__MODULE__{
      last_block_ts: nil,
      baseline_latency_p50: nil,
      session_files: MapSet.new()
    }

    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Handle eBPF events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:ebpf_event, %{"type" => "syscall"} = event}, state) do
    syscall = event["syscall"] || "unknown"
    Metrics.increment_syscall(syscall)
    {:noreply, state}
  end

  def handle_info({:ebpf_event, %{"type" => "latency"} = event}, state) do
    op =
      case event["op"] do
        "read" -> :read
        "write" -> :write
        _ -> :blk
      end

    latency_ns = event["latency_ns"] || 0
    Metrics.record_latency(op, latency_ns)
    {:noreply, state}
  end

  def handle_info({:ebpf_event, %{"type" => "net"}}, state) do
    {:noreply, state}
  end

  def handle_info({:ebpf_event, _event}, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Handle RPC events
  # ---------------------------------------------------------------------------

  def handle_info({:block, block}, state) do
    height = block["height"]
    hash = block["hash"]
    now = System.os_time(:second)

    if height && hash do
      Metrics.record_block_arrival(height, hash)
    end

    state = maybe_emit_block_latency(state, now, block)

    publish({:aggregated_block, block})
    {:noreply, %{state | last_block_ts: now}}
  end

  def handle_info({:mempool, info}, state) do
    size = info["size"] || 0
    Metrics.record_mempool_size(size)
    publish({:aggregated_mempool, info})
    {:noreply, state}
  end

  def handle_info({:peers, peers}, state) do
    Enum.each(peers, fn peer ->
      id = peer["id"]

      if id do
        sent = peer["bytessent"] || 0
        recv = peer["bytesrecv"] || 0
        Metrics.record_peer_bytes(id, :sent, 0)
        Metrics.record_peer_bytes(id, :recv, 0)
        _ = {sent, recv}
      end
    end)

    publish({:aggregated_peers, peers})
    {:noreply, state}
  end

  def handle_info({:chain, info}, state) do
    publish({:aggregated_chain, info})
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Anomaly detection helpers
  # ---------------------------------------------------------------------------

  defp maybe_emit_block_latency(state, now, block) do
    if state.last_block_ts do
      gap_s = now - state.last_block_ts
      height = block["height"]

      if height && gap_s >= 0 do
        publish(
          {:anomaly,
           %{
             category: :bitcoin,
             severity: :info,
             description: "Block #{height} arrived after #{gap_s}s gap",
             ts: now
           }}
        )
      end
    end

    state
  end

  defp publish(event) do
    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "node_probe:events", event)
  end
end
