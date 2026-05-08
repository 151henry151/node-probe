defmodule NodeProbe.Collectors.RpcCollectorTest do
  use ExUnit.Case, async: false

  import Mox

  Mox.defmock(NodeProbe.Bitcoin.RpcCollectorMock, for: NodeProbe.Bitcoin.RpcBehaviour)

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Application.put_env(:node_probe, :rpc_poll_interval_ms, 60_000)

    on_exit(fn ->
      Application.delete_env(:node_probe, :rpc_poll_interval_ms)
    end)

    :ok
  end

  defp start_collector do
    {:ok, pid} =
      start_supervised(
        {NodeProbe.Collectors.RpcCollector, [rpc: NodeProbe.Bitcoin.RpcCollectorMock]},
        id: make_ref()
      )

    Mox.allow(NodeProbe.Bitcoin.RpcCollectorMock, self(), pid)
    pid
  end

  defp stub_happy_path do
    stub(NodeProbe.Bitcoin.RpcCollectorMock, :call, fn
      "getblockchaininfo", [] ->
        {:ok, %{"chain" => "main", "blocks" => 840_000, "bestblockhash" => "abc123"}}

      "getpeerinfo", [] ->
        {:ok, [%{"id" => 1, "addr" => "1.2.3.4:8333"}]}

      "getmempoolinfo", [] ->
        {:ok, %{"size" => 5000, "bytes" => 1_000_000}}

      "getblock", ["abc123", 2] ->
        {:ok, %{"hash" => "abc123", "height" => 840_000, "tx" => []}}
    end)
  end

  test "publishes chain info to PubSub on poll" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "rpc:events")
    stub_happy_path()
    pid = start_collector()

    send(pid, :poll)

    assert_receive {:chain, %{"chain" => "main"}}, 1_000
  end

  test "publishes peer info to PubSub on poll" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "rpc:events")
    stub_happy_path()
    pid = start_collector()

    send(pid, :poll)

    assert_receive {:peers, [%{"id" => 1}]}, 1_000
  end

  test "publishes mempool info to PubSub on poll" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "rpc:events")
    stub_happy_path()
    pid = start_collector()

    send(pid, :poll)

    assert_receive {:mempool, %{"size" => 5000}}, 1_000
  end

  test "publishes block when new best block hash is detected" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "rpc:events")
    stub_happy_path()
    pid = start_collector()

    send(pid, :poll)

    assert_receive {:block, %{"hash" => "abc123"}}, 1_000
  end

  test "does not re-publish block for same best hash" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "rpc:events")

    stub(NodeProbe.Bitcoin.RpcCollectorMock, :call, fn
      "getblockchaininfo", [] ->
        {:ok, %{"chain" => "main", "blocks" => 840_000, "bestblockhash" => "abc123"}}

      "getpeerinfo", [] ->
        {:ok, []}

      "getmempoolinfo", [] ->
        {:ok, %{"size" => 0, "bytes" => 0}}

      "getblock", ["abc123", 2] ->
        {:ok, %{"hash" => "abc123", "height" => 840_000, "tx" => []}}
    end)

    pid = start_collector()

    send(pid, :poll)
    assert_receive {:block, _}, 1_000

    send(pid, :poll)
    refute_receive {:block, _}, 200
  end

  test "handles RPC error gracefully without crashing" do
    stub(NodeProbe.Bitcoin.RpcCollectorMock, :call, fn _method, _params ->
      {:error, :econnrefused}
    end)

    pid = start_collector()

    send(pid, :poll)
    Process.sleep(100)
    assert Process.alive?(pid)
  end
end
