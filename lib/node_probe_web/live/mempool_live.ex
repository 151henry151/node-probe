defmodule NodeProbeWeb.MempoolLive do
  use NodeProbeWeb, :live_view

  alias NodeProbe.Metrics
  alias NodeProbeWeb.FeeFormat

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
       min_fee_sat_vb_display: "—",
       fee_histogram: %{},
       mempool_history: []
     )}
  end

  @impl true
  def handle_info({:aggregated_mempool, info}, socket) do
    size_bytes = info["bytes"] || 0
    size_mb = Float.round(size_bytes / 1_000_000, 2)
    tx_count = info["size"] || 0
    raw_min = info["mempoolminfee"] || 0
    min_sat_vb = FeeFormat.mempool_min_fee_sat_vb(to_number(raw_min))
    min_display = FeeFormat.format_sat_per_vb(min_sat_vb)

    history = Metrics.mempool_history()

    {:noreply,
     assign(socket,
       tx_count: tx_count,
       size_mb: size_mb,
       min_fee_sat_vb_display: min_display,
       mempool_history: history
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp to_number(v) when is_integer(v), do: v * 1.0
  defp to_number(v) when is_float(v), do: v

  defp to_number(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_number(_), do: 0.0

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
          <div class="stat-value mono">{@min_fee_sat_vb_display} sat/vB</div>
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
