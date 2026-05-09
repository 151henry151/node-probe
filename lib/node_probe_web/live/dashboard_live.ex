defmodule NodeProbeWeb.DashboardLive do
  @moduledoc """
  Single-page dashboard: chain overview, latest block, mempool, peers, and eBPF I/O.
  """
  use NodeProbeWeb, :live_view

  alias NodeProbe.Bitcoin.Enricher
  alias NodeProbe.Metrics
  alias NodeProbeWeb.FeeFormat

  @io_tick_ms 250

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")
      send(self(), :io_tick)
    end

    {:ok, assign_defaults(socket)}
  end

  defp assign_defaults(socket) do
    ebpf_on = Application.get_env(:node_probe, :ebpf_enabled, true)

    assign(socket,
      page_title: "Dashboard",
      chain_height: nil,
      chain_ibd: false,
      ibd_progress: 1.0,
      chain_info: %{},
      peer_count: 0,
      inbound_count: 0,
      outbound_count: 0,
      mempool_tx_count: 0,
      mempool_size_mb: 0.0,
      min_fee_sat_vb_display: "—",
      mempool_history: [],
      last_block_ts: nil,
      pulse_events: [],
      ebpf_enabled: ebpf_on,
      current_block: nil,
      block_history: [],
      fee_histogram: %{},
      peers: [],
      peer_sort_by: :addr,
      peer_sort_dir: :asc,
      peer_filter: "",
      latency_hist_read: %{},
      latency_hist_write: %{},
      recent_file_events: [],
      syscall_counts: %{},
      path_prefix_counts: %{}
    )
  end

  @impl true
  def handle_event("peer_filter", %{"value" => value}, socket) do
    {:noreply, assign(socket, peer_filter: value)}
  end

  def handle_event("peer_sort", %{"field" => field}, socket) do
    field =
      case field do
        "addr" -> :addr
        "version" -> :version
        "ping_ms" -> :ping_ms
        "bytes_sent" -> :bytes_sent
        "bytes_recv" -> :bytes_recv
        _ -> socket.assigns.peer_sort_by
      end

    dir =
      if socket.assigns.peer_sort_by == field and socket.assigns.peer_sort_dir == :asc do
        :desc
      else
        :asc
      end

    {:noreply, assign(socket, peer_sort_by: field, peer_sort_dir: dir)}
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

  def handle_info({:aggregated_peers, raw_peers}, socket) do
    inbound = Enum.count(raw_peers, & &1["inbound"])
    outbound = length(raw_peers) - inbound

    peers = Enum.map(raw_peers, &Enricher.enrich_peer/1)

    {:noreply,
     assign(socket,
       peers: peers,
       peer_count: length(raw_peers),
       inbound_count: inbound,
       outbound_count: outbound
     )}
  end

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
       mempool_tx_count: tx_count,
       mempool_size_mb: size_mb,
       min_fee_sat_vb_display: min_display,
       mempool_history: history
     )}
  end

  def handle_info({:aggregated_block, block}, socket) do
    enriched = Enricher.enrich_block(block)
    history = [enriched | socket.assigns.block_history] |> Enum.take(10)
    histogram = build_fee_histogram(block)

    {:noreply,
     assign(socket,
       current_block: enriched,
       block_history: history,
       fee_histogram: histogram,
       last_block_ts: System.os_time(:second)
     )}
  end

  def handle_info({:anomaly, event}, socket) do
    pulse = [event | socket.assigns.pulse_events] |> Enum.take(12)
    {:noreply, assign(socket, pulse_events: pulse)}
  end

  def handle_info(:io_tick, socket) do
    socket =
      assign(socket,
        syscall_counts: Metrics.syscall_counts(),
        path_prefix_counts: Metrics.path_prefix_counts(),
        latency_hist_read: Metrics.latency_histogram(:read),
        latency_hist_write: Metrics.latency_histogram(:write),
        recent_file_events: Metrics.recent_paths()
      )

    Process.send_after(self(), :io_tick, @io_tick_ms)
    {:noreply, socket}
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

  defp io_empty?(assigns) do
    assigns.syscall_counts == %{} and assigns.latency_hist_read == %{} and
      assigns.latency_hist_write == %{} and assigns.recent_file_events == []
  end

  defp sorted_peers(peers, sort_by, sort_dir) do
    sorted = Enum.sort_by(peers, fn p -> Map.get(p, sort_by) end)
    if sort_dir == :desc, do: Enum.reverse(sorted), else: sorted
  end

  defp filtered_peers(peers, ""), do: peers

  defp filtered_peers(peers, filter) do
    Enum.filter(peers, fn p ->
      addr = p.addr || ""
      String.contains?(addr, filter)
    end)
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000,
    do: "#{Float.round(bytes / 1_000, 1)} KB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "—"

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:io_empty?, io_empty?(assigns))
      |> assign(
        :visible_peers,
        filtered_peers(
          sorted_peers(assigns.peers, assigns.peer_sort_by, assigns.peer_sort_dir),
          assigns.peer_filter
        )
      )

    ~H"""
    <div class="np-dashboard">
      <header class="np-dash-header">
        <div class="np-dash-brand">
          <span class="dash-logo-mark">⬡</span>
          <div>
            <div class="dash-title">node-probe</div>
            <div class="dash-subtitle mono">Bitcoin observatory</div>
          </div>
        </div>
        <div class="np-dash-meta mono">
          <span class="dash-meta-item">
            height <strong class="dash-accent">{@chain_height || "—"}</strong>
          </span>
          <span class="dash-meta-item muted">·</span>
          <span class="dash-meta-item">
            {@peer_count} peers <span class="muted">({@inbound_count}↓ {@outbound_count}↑)</span>
          </span>
        </div>
      </header>

      <%!-- Overview --%>
      <section class="dash-section" id="overview" aria-labelledby="overview-heading">
        <h2 id="overview-heading" class="dash-section-title">Overview</h2>
        <div class="stats-grid dash-overview-stats">
          <div class="stat-card">
            <div class="stat-label">Chain height</div>
            <div class="stat-value mono">{@chain_height || "—"}</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Peers</div>
            <div class="stat-value mono">
              {@peer_count} <span class="muted">({@inbound_count}↓ {@outbound_count}↑)</span>
            </div>
          </div>
          <div class="stat-card accent-orange">
            <div class="stat-label">Mempool</div>
            <div class="stat-value mono">{@mempool_tx_count} tx · {@mempool_size_mb} MB</div>
          </div>
          <div class="stat-card">
            <div class="stat-label">Min fee</div>
            <div class="stat-value mono">
              {@min_fee_sat_vb_display} <span class="muted">sat/vB</span>
            </div>
          </div>
        </div>

        <div :if={@chain_ibd} class="ibd-banner">
          <span>Initial Block Download</span>
          <div class="progress-bar">
            <div class="progress-fill" style={"width: #{round(@ibd_progress * 100)}%"}></div>
          </div>
          <span class="mono">{round(@ibd_progress * 10000) / 100}%</span>
        </div>

        <div class="pulse-strip">
          <div class="ticker-label">Live pulse</div>
          <div class="pulse-strip-events">
            <div
              :for={event <- @pulse_events}
              class={"pulse-chip severity-#{event[:severity] || :info}"}
            >
              <span class="event-category">{event[:category]}</span>
              <span class="event-desc">{event[:description]}</span>
            </div>
            <div :if={@pulse_events == []} class="muted pulse-chip-empty">Waiting for signals…</div>
          </div>
        </div>
      </section>

      <div class="dash-columns">
        <div class="dash-col dash-col-main">
          <%!-- Block --%>
          <section class="dash-section" id="block" aria-labelledby="block-heading">
            <h2 id="block-heading" class="dash-section-title">Latest block</h2>
            <div :if={@current_block} class="current-block dash-tight-block">
              <div class="block-header">
                <span class="block-height mono">#{@current_block.height}</span>
                <span class="block-hash mono">{String.slice(@current_block.hash || "", 0, 18)}…</span>
              </div>
              <div class="block-stats">
                <div class="stat-card">
                  <div class="stat-label">Transactions</div>
                  <div class="stat-value mono">{@current_block.tx_count}</div>
                </div>
                <div class="stat-card">
                  <div class="stat-label">Total fees</div>
                  <div class="stat-value mono">{@current_block.total_fees_sat} sat</div>
                </div>
                <div class="stat-card">
                  <div class="stat-label">Median fee</div>
                  <div class="stat-value mono">
                    {Float.round(@current_block.median_fee_rate || 0.0, 1)} sat/vB
                  </div>
                </div>
                <div class="stat-card">
                  <div class="stat-label">Weight</div>
                  <div class="stat-value mono">{@current_block.weight} WU</div>
                </div>
              </div>
              <div
                class="fee-histogram"
                id="dash-fee-histogram"
                phx-hook="FeeHistogram"
                data-histogram={Jason.encode!(@fee_histogram)}
              >
                <div class="histogram-label">Fee rate distribution (sat/vB)</div>
              </div>
            </div>
            <div :if={@current_block == nil} class="empty-state muted dash-empty-inline">
              Waiting for next block…
            </div>
            <div :if={@block_history != []} class="block-timeline dash-compact-timeline">
              <div class="timeline-label">Recent blocks</div>
              <div :for={b <- @block_history} class="timeline-item mono">
                #{b.height} — {b.tx_count} tx — {b.total_fees_sat} sat fees
              </div>
            </div>
          </section>

          <%!-- Mempool --%>
          <section class="dash-section" id="mempool" aria-labelledby="mempool-heading">
            <h2 id="mempool-heading" class="dash-section-title">Mempool</h2>
            <div class="stats-grid mempool-mini-stats">
              <div class="stat-card accent-orange">
                <div class="stat-label">Transactions</div>
                <div class="stat-value mono">{@mempool_tx_count}</div>
              </div>
              <div class="stat-card">
                <div class="stat-label">Size</div>
                <div class="stat-value mono">{@mempool_size_mb} MB</div>
              </div>
              <div class="stat-card">
                <div class="stat-label">Min fee</div>
                <div class="stat-value mono">{@min_fee_sat_vb_display} sat/vB</div>
              </div>
            </div>
            <div class="mempool-sparkline">
              <div class="sparkline-label">Size — last 10 min</div>
              <div
                id="dash-mempool-sparkline"
                phx-hook="Sparkline"
                data-values={Jason.encode!(Enum.map(@mempool_history, fn {_, size} -> size end))}
              >
              </div>
            </div>
          </section>
        </div>

        <div class="dash-col dash-col-side">
          <%!-- Peers --%>
          <section class="dash-section" id="peers" aria-labelledby="peers-heading">
            <h2 id="peers-heading" class="dash-section-title">Peers</h2>
            <div class="peers-toolbar">
              <input
                id="peer-filter-input"
                type="text"
                class="filter-input"
                placeholder="Filter by IP…"
                value={@peer_filter}
                phx-input="peer_filter"
                phx-debounce="200"
              />
              <span class="peer-count mono">{length(@peers)} peers</span>
            </div>
            <div class="peers-table-wrap">
              <table class="peers-table">
                <thead>
                  <tr>
                    <th phx-click="peer_sort" phx-value-field="addr">Address</th>
                    <th phx-click="peer_sort" phx-value-field="version">Ver</th>
                    <th phx-click="peer_sort" phx-value-field="ping_ms">Ping</th>
                    <th phx-click="peer_sort" phx-value-field="bytes_sent">Sent</th>
                    <th phx-click="peer_sort" phx-value-field="bytes_recv">Recv</th>
                    <th>Dir</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={peer <- @visible_peers}>
                    <td class="mono">{peer.addr}</td>
                    <td class="mono">{peer.version}</td>
                    <td class="mono">{peer.ping_ms} ms</td>
                    <td class="mono">{format_bytes(peer.bytes_sent)}</td>
                    <td class="mono">{format_bytes(peer.bytes_recv)}</td>
                    <td>{if peer.inbound, do: "↓ in", else: "↑ out"}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div :if={@peers == []} class="empty-state muted dash-empty-inline">
              No peers connected
            </div>
          </section>

          <%!-- I/O --%>
          <section class="dash-section" id="io" aria-labelledby="io-heading">
            <h2 id="io-heading" class="dash-section-title">
              Kernel I/O <span class="muted">(bitcoind)</span>
            </h2>
            <div :if={@io_empty?} class="muted io-empty-hint dash-io-hint">
              <%= if @ebpf_enabled do %>
                No samples yet — with the loader attached to <span class="mono">bitcoind</span>, expect <span class="mono">read</span> / <span class="mono">write</span> syscall counts during sync plus read/write latency from VFS probes. If this never moves, reload the loader (see README).
              <% else %>
                eBPF disabled (<code class="mono">EBPF_ENABLED=false</code>).
              <% end %>
            </div>
            <div class="io-grid dash-io-grid">
              <div class="io-section">
                <div class="section-label">Syscalls</div>
                <div
                  :for={
                    {name, count} <-
                      Enum.sort_by(@syscall_counts, fn {_, c} -> c end, :desc) |> Enum.take(10)
                  }
                  class="io-row"
                >
                  <span class="mono">{name}</span>
                  <span class="mono accent-blue">{count}</span>
                </div>
                <div :if={@syscall_counts == %{}} class="muted">No samples</div>
              </div>
              <div class="io-section">
                <div class="section-label">Path prefix</div>
                <div
                  :for={
                    {prefix, count} <-
                      Enum.sort_by(@path_prefix_counts, fn {_, c} -> c end, :desc) |> Enum.take(8)
                  }
                  class="io-row"
                >
                  <span class="mono">{prefix}</span>
                  <span class="mono accent-blue">{count}</span>
                </div>
                <div :if={@path_prefix_counts == %{}} class="muted">No paths captured</div>
              </div>
              <div class="io-section">
                <div class="section-label">Read latency</div>
                <div :for={{bucket, count} <- @latency_hist_read} class="io-row">
                  <span class="mono">{bucket}</span>
                  <span class="mono">{count}</span>
                </div>
                <div :if={@latency_hist_read == %{}} class="muted">No read samples yet</div>
              </div>
              <div class="io-section">
                <div class="section-label">Write latency</div>
                <div :for={{bucket, count} <- @latency_hist_write} class="io-row">
                  <span class="mono">{bucket}</span>
                  <span class="mono">{count}</span>
                </div>
                <div :if={@latency_hist_write == %{}} class="muted">No write samples yet</div>
              </div>
            </div>
            <div class="recent-files dash-recent-files">
              <div class="section-label">Recent paths</div>
              <div
                :for={event <- Enum.take(@recent_file_events, 12)}
                class="io-row mono truncate-path"
              >
                {event.filename}
              </div>
              <div :if={@recent_file_events == []} class="muted">None yet</div>
            </div>
          </section>
        </div>
      </div>
    </div>
    """
  end
end
