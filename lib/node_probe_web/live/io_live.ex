defmodule NodeProbeWeb.IoLive do
  use NodeProbeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NodeProbe.PubSub, "ebpf:events")
    end

    ebpf_on = Application.get_env(:node_probe, :ebpf_enabled, true)

    {:ok,
     assign(socket,
       page_title: "I/O",
       ebpf_enabled: ebpf_on,
       latency_hist_read: %{},
       latency_hist_write: %{},
       recent_file_events: [],
       syscall_counts: %{},
       path_prefix_counts: %{}
     )}
  end

  @impl true
  def handle_info({:ebpf_event, %{"type" => "syscall"} = event}, socket) do
    syscall = event["syscall"] || "unknown"

    counts =
      Map.update(socket.assigns.syscall_counts, syscall, 1, &(&1 + 1))

    filename = event["filename"] || ""

    prefix_counts =
      if filename != "" do
        Map.update(socket.assigns.path_prefix_counts, file_prefix(filename), 1, &(&1 + 1))
      else
        socket.assigns.path_prefix_counts
      end

    recent =
      if filename != "" do
        [%{filename: filename, ts: event["ts"]} | socket.assigns.recent_file_events]
        |> Enum.take(50)
      else
        socket.assigns.recent_file_events
      end

    {:noreply,
     assign(socket,
       syscall_counts: counts,
       path_prefix_counts: prefix_counts,
       recent_file_events: recent
     )}
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

  defp io_empty?(assigns) do
    assigns.syscall_counts == %{} and assigns.latency_hist_read == %{} and
      assigns.latency_hist_write == %{} and assigns.recent_file_events == []
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :io_empty?, io_empty?(assigns))

    ~H"""
    <div class="io-view">
      <div :if={@io_empty?} class="muted io-empty-hint">
        <%= if @ebpf_enabled do %>
          No bitcoind I/O events received yet. During sync the loader should show syscall counts (read/write/openat)
          and read latency. If this stays empty, confirm the eBPF loader is running and attached to <span class="mono">bitcoind</span>.
        <% else %>
          eBPF is disabled (<code class="mono">EBPF_ENABLED=false</code>). Enable it and rebuild the loader to see live I/O.
        <% end %>
      </div>

      <div class="io-grid">
        <div class="io-section">
          <div class="section-label">Syscalls (bitcoind)</div>
          <div :for={{name, count} <- Enum.sort_by(@syscall_counts, fn {_, c} -> c end, :desc) |> Enum.take(12)} class="io-row">
            <span class="mono">{name}</span>
            <span class="mono accent-blue">{count}</span>
          </div>
          <div :if={@syscall_counts == %{}} class="muted">No syscall samples yet</div>
        </div>

        <div class="io-section">
          <div class="section-label">File access by path prefix</div>
          <div :for={{prefix, count} <- Enum.sort_by(@path_prefix_counts, fn {_, c} -> c end, :desc) |> Enum.take(10)} class="io-row">
            <span class="mono">{prefix}</span>
            <span class="mono accent-blue">{count}</span>
          </div>
          <div :if={@path_prefix_counts == %{}} class="muted">
            No paths yet (kernel programs do not capture full paths yet — counts above still reflect syscall activity)
          </div>
        </div>

        <div class="io-section">
          <div class="section-label">Read latency distribution</div>
          <div :for={{bucket, count} <- @latency_hist_read} class="io-row">
            <span class="mono">{bucket}</span>
            <span class="mono">{count}</span>
          </div>
          <div :if={@latency_hist_read == %{}} class="muted">No read latency samples yet</div>
        </div>
      </div>

      <div class="recent-files">
        <div class="section-label">Recent paths (when available)</div>
        <div :for={event <- @recent_file_events} class="io-row mono">
          {event.filename}
        </div>
        <div :if={@recent_file_events == []} class="muted">No file paths yet</div>
      </div>
    </div>
    """
  end
end
