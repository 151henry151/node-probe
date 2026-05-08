defmodule NodeProbeWeb.PeersLive do
  use NodeProbeWeb, :live_view

  alias NodeProbe.Bitcoin.Enricher

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")
    end

    {:ok,
     assign(socket,
       page_title: "Peers",
       peers: [],
       sort_by: :id,
       sort_dir: :asc,
       filter: ""
     )}
  end

  @impl true
  def handle_event("filter", %{"value" => value}, socket) do
    {:noreply, assign(socket, filter: value)}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    field = String.to_existing_atom(field)
    dir = if socket.assigns.sort_by == field and socket.assigns.sort_dir == :asc, do: :desc, else: :asc
    {:noreply, assign(socket, sort_by: field, sort_dir: dir)}
  end

  @impl true
  def handle_info({:aggregated_peers, raw_peers}, socket) do
    peers = Enum.map(raw_peers, &Enricher.enrich_peer/1)
    {:noreply, assign(socket, peers: peers)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="peers-view">
      <div class="peers-toolbar">
        <input
          type="text"
          class="filter-input"
          placeholder="Filter by IP…"
          value={@filter}
          phx-input="filter"
          phx-debounce="200"
        />
        <span class="peer-count mono">{length(@peers)} peers</span>
      </div>

      <table class="peers-table">
        <thead>
          <tr>
            <th phx-click="sort" phx-value-field="addr">Address</th>
            <th phx-click="sort" phx-value-field="version">Version</th>
            <th phx-click="sort" phx-value-field="ping_ms">Ping</th>
            <th phx-click="sort" phx-value-field="bytes_sent">Sent</th>
            <th phx-click="sort" phx-value-field="bytes_recv">Recv</th>
            <th>Dir</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={peer <- filtered_peers(sorted_peers(@peers, @sort_by, @sort_dir), @filter)}>
            <td class="mono">{peer.addr}</td>
            <td class="mono">{peer.version}</td>
            <td class="mono">{peer.ping_ms} ms</td>
            <td class="mono">{format_bytes(peer.bytes_sent)}</td>
            <td class="mono">{format_bytes(peer.bytes_recv)}</td>
            <td>{if peer.inbound, do: "↓ in", else: "↑ out"}</td>
          </tr>
        </tbody>
      </table>

      <div :if={@peers == []} class="empty-state muted">No peers connected</div>
    </div>
    """
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000,
    do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "—"
end
