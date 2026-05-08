defmodule NodeProbeWeb.BlockLive do
  use NodeProbeWeb, :live_view

  alias NodeProbe.Bitcoin.Enricher

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")
    end

    {:ok, assign(socket, page_title: "Block", current_block: nil, block_history: [], fee_histogram: %{})}
  end

  @impl true
  def handle_info({:aggregated_block, block}, socket) do
    enriched = Enricher.enrich_block(block)
    history = [enriched | socket.assigns.block_history] |> Enum.take(10)
    histogram = build_fee_histogram(block)

    {:noreply, assign(socket, current_block: enriched, block_history: history, fee_histogram: histogram)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp build_fee_histogram(block) do
    (block["tx"] || [])
    |> Enum.reject(fn tx -> match?([%{"coinbase" => _} | _], tx["vin"] || []) end)
    |> Enum.map(fn tx ->
      fee_sat = round((tx["fee"] || 0) * 100_000_000)
      weight = tx["weight"] || max((tx["vsize"] || 1) * 4, 1)
      vsize = max(ceil(weight / 4), 1)
      fee_sat / vsize
    end)
    |> Enum.group_by(&fee_rate_bucket/1)
    |> Map.new(fn {bucket, rates} -> {bucket, length(rates)} end)
  end

  defp fee_rate_bucket(rate) do
    cond do
      rate < 2 -> "1-2"
      rate < 5 -> "2-5"
      rate < 10 -> "5-10"
      rate < 25 -> "10-25"
      rate < 50 -> "25-50"
      rate < 100 -> "50-100"
      rate < 300 -> "100-300"
      true -> "300+"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="block-view">
      <div :if={@current_block} class="current-block">
        <div class="block-header">
          <span class="block-height mono">#{ @current_block.height}</span>
          <span class="block-hash mono">{String.slice(@current_block.hash || "", 0, 16)}…</span>
        </div>
        <div class="block-stats">
          <div class="stat-card">
            <div class="stat-label">Transactions</div>
            <div class="stat-value mono">{@current_block.tx_count}</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Total Fees</div>
            <div class="stat-value mono">{@current_block.total_fees_sat} sat</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Median Fee Rate</div>
            <div class="stat-value mono">{Float.round(@current_block.median_fee_rate || 0.0, 1)} sat/vB</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Weight</div>
            <div class="stat-value mono">{@current_block.weight} WU</div>
          </div>
        </div>
        <div class="fee-histogram" id="fee-histogram" phx-hook="FeeHistogram" data-histogram={Jason.encode!(@fee_histogram)}>
          <div class="histogram-label">Fee Rate Distribution (sat/vB)</div>
        </div>
      </div>

      <div :if={@current_block == nil} class="empty-state muted">Waiting for next block…</div>

      <div :if={@block_history != []} class="block-timeline">
        <div class="timeline-label">Recent Blocks</div>
        <div :for={b <- @block_history} class="timeline-item mono">
          #{ b.height} — {b.tx_count} tx — {b.total_fees_sat} sat fees
        </div>
      </div>
    </div>
    """
  end
end
