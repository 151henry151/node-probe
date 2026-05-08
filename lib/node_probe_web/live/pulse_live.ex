defmodule NodeProbeWeb.PulseLive do
  use NodeProbeWeb, :live_view

  alias NodeProbe.Metrics

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")
    end

    {:ok, assign_defaults(socket)}
  end

  @impl true
  def handle_info({:aggregated_chain, info}, socket) do
    {:noreply,
     assign(socket,
       chain_height: info["blocks"],
       chain_ibd: info["initialblockdownload"] || false,
       ibd_progress: info["verificationprogress"] || 1.0,
       chain_info: info
     )}
  end

  def handle_info({:aggregated_peers, peers}, socket) do
    inbound = Enum.count(peers, & &1["inbound"])
    outbound = length(peers) - inbound
    {:noreply, assign(socket, peer_count: length(peers), inbound_count: inbound, outbound_count: outbound)}
  end

  def handle_info({:aggregated_mempool, info}, socket) do
    {:noreply,
     assign(socket,
       mempool_tx_count: info["size"] || 0,
       mempool_size_mb: Float.round((info["bytes"] || 0) / 1_000_000, 2),
       mempool_min_fee: info["mempoolminfee"] || 0
     )}
  end

  def handle_info({:aggregated_block, _block}, socket) do
    {:noreply, assign(socket, last_block_ts: System.os_time(:second))}
  end

  def handle_info({:anomaly, event}, socket) do
    events = [event | socket.assigns.recent_events] |> Enum.take(20)
    {:noreply, assign(socket, recent_events: events)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp assign_defaults(socket) do
    assign(socket,
      page_title: "Pulse",
      chain_height: nil,
      chain_ibd: false,
      ibd_progress: 1.0,
      chain_info: %{},
      peer_count: 0,
      inbound_count: 0,
      outbound_count: 0,
      mempool_tx_count: 0,
      mempool_size_mb: 0.0,
      mempool_min_fee: 0,
      last_block_ts: nil,
      recent_events: [],
      ebpf_enabled: Application.get_env(:node_probe, :ebpf_enabled, true)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="pulse-view">
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Chain Height</div>
          <div class="stat-value mono">{@chain_height || "—"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Peers</div>
          <div class="stat-value mono">{@peer_count} <span class="muted">({@inbound_count}↓ {@outbound_count}↑)</span></div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Mempool</div>
          <div class="stat-value mono">{@mempool_tx_count} tx · {@mempool_size_mb} MB</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">eBPF</div>
          <div class="stat-value mono">{if @ebpf_enabled, do: "enabled", else: "disabled"}</div>
        </div>
      </div>

      <div :if={@chain_ibd} class="ibd-banner">
        <span>Initial Block Download in progress</span>
        <div class="progress-bar">
          <div class="progress-fill" style={"width: #{round(@ibd_progress * 100)}%"}></div>
        </div>
        <span class="mono">{round(@ibd_progress * 10000) / 100}%</span>
      </div>

      <div class="event-ticker">
        <div class="ticker-label">Recent Events</div>
        <div class="ticker-events">
          <div :for={event <- @recent_events} class={"event-row severity-#{event[:severity] || :info}"}>
            <span class="event-category">{event[:category]}</span>
            <span class="event-desc">{event[:description]}</span>
          </div>
          <div :if={@recent_events == []} class="muted">No events yet</div>
        </div>
      </div>
    </div>
    """
  end
end
