defmodule NodeProbe.Collectors.EbpfCollector do
  use GenServer
  require Logger

  @restart_delay_ms 5_000

  defstruct [:port, :loader_path, :loader_args, :enabled]

  def start_link(opts \\ []) do
    gen_opts = if Keyword.has_key?(opts, :name), do: [name: opts[:name]], else: [name: __MODULE__]
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(_opts) do
    enabled = Application.get_env(:node_probe, :ebpf_enabled, true)
    loader_path = Application.get_env(:node_probe, :ebpf_loader_path, "")
    lite_mode = Application.get_env(:node_probe, :lite_mode, false)

    loader_args = if lite_mode, do: ["--lite"], else: []

    state = %__MODULE__{
      loader_path: loader_path,
      loader_args: loader_args,
      enabled: enabled
    }

    if enabled do
      {:ok, open_port(state)}
    else
      Logger.warning("EbpfCollector: eBPF disabled (EBPF_ENABLED=false), running in no-op mode")
      {:ok, %{state | port: nil}}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, event} ->
        NodeProbe.Metrics.ingest_ebpf(event)

      {:error, reason} ->
        Logger.debug("EbpfCollector: JSON decode failed: #{inspect(reason)}, line: #{line}")
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "EbpfCollector: loader exited with status #{status}, restarting in #{@restart_delay_ms}ms"
    )

    Process.send_after(self(), :restart, @restart_delay_ms)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(:restart, state) do
    {:noreply, open_port(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp open_port(%{loader_path: loader_path, loader_args: loader_args} = state) do
    port =
      Port.open(
        {:spawn_executable, loader_path},
        [:binary, :exit_status, {:line, 65_536}, {:args, loader_args}]
      )

    %{state | port: port}
  rescue
    e ->
      Logger.warning(
        "EbpfCollector: failed to open port: #{inspect(e)}, will retry in #{@restart_delay_ms}ms"
      )

      Process.send_after(self(), :restart, @restart_delay_ms)
      %{state | port: nil}
  end
end
