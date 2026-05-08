defmodule NodeProbeWeb.MempoolLive do
  use NodeProbeWeb, :live_view

  alias NodeProbe.Metrics

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")
    end

    {:ok,
     assign(socket,
       page_title: "Mempool",
       tx_count: 0,
       size_mb: 0.0,
       total_fees_btc: 0.0,
       min_fee_rate: 0,
       fee_histogram: %{},
       mempool_history: []
     )}
  end

  @impl true
  def handle_info({:aggregated_mempool, info}, socket) do
    size_bytes = info["bytes"] || 0
    size_mb = Float.round(size_bytes / 1_000_000, 2)
    tx_count = info["size"] || 0
    min_fee_rate = info["mempoolminfee"] || 0

    history = Metrics.mempool_history()

    {:noreply,
     assign(socket,
       tx_count: tx_count,
       size_mb: size_mb,
       min_fee_rate: min_fee_rate,
       mempool_history: history
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mempool-view">
      <div class="stats-grid">
        <div class="stat-card accent-orange">
          <div class="stat-label">Transactions</div>
          <div class="stat-value mono">{@tx_count}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Size</div>
          <div class="stat-value mono">{@size_mb} MB</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Min Fee Rate</div>
          <div class="stat-value mono">{@min_fee_rate} sat/vB</div>
        </div>
      </div>

      <div class="mempool-sparkline">
        <div class="sparkline-label">Mempool Size (last 10 min)</div>
        <div
          id="mempool-sparkline"
          phx-hook="Sparkline"
          data-values={Jason.encode!(Enum.map(@mempool_history, fn {_, size} -> size end))}
        >
        </div>
      </div>
    </div>
    """
  end
end
