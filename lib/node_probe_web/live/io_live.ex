defmodule NodeProbeWeb.IoLive do
  use NodeProbeWeb, :live_view

  alias NodeProbe.Metrics

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NodeProbe.PubSub, "ebpf:events")
    end

    {:ok,
     assign(socket,
       page_title: "I/O",
       latency_hist_read: %{},
       latency_hist_write: %{},
       recent_file_events: [],
       file_access_counts: %{}
     )}
  end

  @impl true
  def handle_info({:ebpf_event, %{"type" => "syscall", "syscall" => "openat"} = event}, socket) do
    filename = event["filename"] || ""
    prefix = file_prefix(filename)

    counts =
      Map.update(socket.assigns.file_access_counts, prefix, 1, &(&1 + 1))

    events =
      [%{filename: filename, ts: event["ts"]} | socket.assigns.recent_file_events]
      |> Enum.take(50)

    {:noreply, assign(socket, file_access_counts: counts, recent_file_events: events)}
  end

  def handle_info({:ebpf_event, %{"type" => "latency"} = event}, socket) do
    hist =
      case event["op"] do
        "read" ->
          bucket = latency_bucket(event["latency_ns"] || 0)
          Map.update(socket.assigns.latency_hist_read, bucket, 1, &(&1 + 1))

        "write" ->
          bucket = latency_bucket(event["latency_ns"] || 0)
          Map.update(socket.assigns.latency_hist_write, bucket, 1, &(&1 + 1))

        _ ->
          nil
      end

    socket =
      case event["op"] do
        "read" -> assign(socket, latency_hist_read: hist)
        "write" -> assign(socket, latency_hist_write: hist)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp file_prefix(filename) do
    cond do
      String.contains?(filename, "/blocks/") -> "blocks/"
      String.contains?(filename, "/chainstate/") -> "chainstate/"
      String.contains?(filename, "/wallets/") -> "wallets/"
      String.contains?(filename, "/indexes/") -> "indexes/"
      filename == "" -> "unknown"
      true -> "other"
    end
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="io-view">
      <div class="io-grid">
        <div class="io-section">
          <div class="section-label">File Access by Prefix</div>
          <div :for={{prefix, count} <- Enum.sort_by(@file_access_counts, fn {_, c} -> c end, :desc) |> Enum.take(10)} class="io-row">
            <span class="mono">{prefix}</span>
            <span class="mono accent-blue">{count}</span>
          </div>
          <div :if={@file_access_counts == %{}} class="muted">No file events yet (eBPF required)</div>
        </div>

        <div class="io-section">
          <div class="section-label">Read Latency Distribution</div>
          <div :for={{bucket, count} <- @latency_hist_read} class="io-row">
            <span class="mono">{bucket}</span>
            <span class="mono">{count}</span>
          </div>
          <div :if={@latency_hist_read == %{}} class="muted">No latency data yet</div>
        </div>
      </div>

      <div class="recent-files">
        <div class="section-label">Recent File Opens</div>
        <div :for={event <- @recent_file_events} class="io-row mono">
          {event.filename}
        </div>
        <div :if={@recent_file_events == []} class="muted">No file open events yet</div>
      </div>
    </div>
    """
  end
end
