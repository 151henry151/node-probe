defmodule NodeProbeWeb.AnomalyLive do
  use NodeProbeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")
    end

    {:ok, assign(socket, page_title: "Anomalies", events: [])}
  end

  @impl true
  def handle_info({:anomaly, event}, socket) do
    events = [event | socket.assigns.events] |> Enum.take(200)
    {:noreply, assign(socket, events: events)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="anomaly-view">
      <div class="event-feed">
        <div :for={event <- @events} class={"event-item severity-#{event[:severity] || :info}"}>
          <span class="event-ts mono">{format_ts(event[:ts])}</span>
          <span class={"event-badge badge-#{event[:category]}"}>{event[:category]}</span>
          <span class={"severity-badge severity-#{event[:severity]}"}>
            {event[:severity] || :info}
          </span>
          <span class="event-desc">{event[:description]}</span>
        </div>
        <div :if={@events == []} class="muted">No events yet — the feed will populate as your node runs</div>
      </div>
    </div>
    """
  end

  defp format_ts(nil), do: "—"
  defp format_ts(ts) when is_integer(ts) do
    ts
    |> DateTime.from_unix!()
    |> Calendar.strftime("%H:%M:%S")
  end
end
