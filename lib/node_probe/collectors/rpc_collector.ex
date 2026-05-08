defmodule NodeProbe.Collectors.RpcCollector do
  use GenServer
  require Logger

  @default_interval_ms 2_000

  defstruct [
    :rpc,
    :interval_ms,
    :timer_ref,
    :last_best_block_hash,
    :last_mempool_txids
  ]

  def start_link(opts \\ []) do
    gen_opts = if Keyword.has_key?(opts, :name), do: [name: opts[:name]], else: [name: __MODULE__]
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    rpc = Keyword.get(opts, :rpc, NodeProbe.Bitcoin.Rpc)
    interval_ms = Application.get_env(:node_probe, :rpc_poll_interval_ms, @default_interval_ms)

    state = %__MODULE__{
      rpc: rpc,
      interval_ms: interval_ms,
      last_best_block_hash: nil,
      last_mempool_txids: MapSet.new()
    }

    {:ok, schedule_poll(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_all(state)
    {:noreply, schedule_poll(state)}
  end

  defp poll_all(state) do
    state
    |> poll_chain()
    |> poll_peers()
    |> poll_mempool()
  end

  defp poll_chain(state) do
    case state.rpc.call("getblockchaininfo", []) do
      {:ok, info} ->
        publish({:chain, info})

        case info["bestblockhash"] do
          hash when hash != state.last_best_block_hash and not is_nil(hash) ->
            fetch_and_publish_block(state.rpc, hash)
            %{state | last_best_block_hash: hash}

          _ ->
            state
        end

      {:error, reason} ->
        Logger.warning("RpcCollector: getblockchaininfo failed: #{inspect(reason)}")
        state
    end
  end

  defp poll_peers(state) do
    case state.rpc.call("getpeerinfo", []) do
      {:ok, peers} ->
        publish({:peers, peers})
        state

      {:error, reason} ->
        Logger.warning("RpcCollector: getpeerinfo failed: #{inspect(reason)}")
        state
    end
  end

  defp poll_mempool(state) do
    case state.rpc.call("getmempoolinfo", []) do
      {:ok, info} ->
        publish({:mempool, info})
        state

      {:error, reason} ->
        Logger.warning("RpcCollector: getmempoolinfo failed: #{inspect(reason)}")
        state
    end
  end

  defp fetch_and_publish_block(rpc, hash) do
    with {:ok, block} <- rpc.call("getblock", [hash, 2]) do
      publish({:block, block})
    else
      {:error, reason} ->
        Logger.warning("RpcCollector: getblock failed for #{hash}: #{inspect(reason)}")
    end
  end

  defp publish(event) do
    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "rpc:events", event)
  end

  defp schedule_poll(%{interval_ms: interval_ms} = state) do
    timer_ref = Process.send_after(self(), :poll, interval_ms)
    %{state | timer_ref: timer_ref}
  end
end
