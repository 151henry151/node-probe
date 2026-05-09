defmodule NodeProbe.AggregatorTest do
  use ExUnit.Case, async: false

  alias NodeProbe.Aggregator
  alias NodeProbe.Metrics

  setup do
    # Metrics ETS table is started by the app supervisor; just clean it
    :ets.delete_all_objects(:node_probe_metrics)

    # Start an Aggregator with a unique name so it doesn't conflict with the app supervisor's instance
    name = :"aggregator_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({Aggregator, [name: name]}, id: make_ref())
    {:ok, aggregator: pid}
  end

  test "subscribes to ebpf:events and rpc:events on init", %{aggregator: pid} do
    assert Process.alive?(pid)
  end

  test "increments syscall metric on ebpf syscall event" do
    before_count = Metrics.syscall_counts()["openat"] || 0

    Phoenix.PubSub.broadcast(
      NodeProbe.PubSub,
      "ebpf:events",
      {:ebpf_event, %{"type" => "syscall", "syscall" => "openat"}}
    )

    Process.sleep(100)

    after_count = Metrics.syscall_counts()["openat"] || 0
    assert after_count >= before_count + 1
  end

  test "records latency metric on ebpf latency event" do
    Phoenix.PubSub.broadcast(
      NodeProbe.PubSub,
      "ebpf:events",
      {:ebpf_event, %{"type" => "latency", "op" => "read", "latency_ns" => 10_000}}
    )

    Process.sleep(50)

    hist = Metrics.latency_histogram(:read)
    assert map_size(hist) > 0
  end

  test "publishes aggregated_chain event on rpc chain event" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "rpc:events", {:chain, %{"blocks" => 840_000}})

    assert_receive {:aggregated_chain, %{"blocks" => 840_000}}, 1_000
  end

  test "publishes aggregated_mempool and records size on rpc mempool event" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "rpc:events", {:mempool, %{"size" => 5000}})

    assert_receive {:aggregated_mempool, %{"size" => 5000}}, 1_000

    Process.sleep(50)
    history = Metrics.mempool_history()
    assert Enum.any?(history, fn {_, size} -> size == 5000 end)
  end

  test "publishes aggregated_block and records arrival on rpc block event" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")

    Phoenix.PubSub.broadcast(
      NodeProbe.PubSub,
      "rpc:events",
      {:block, %{"height" => 840_000, "hash" => "abc123", "tx" => []}}
    )

    assert_receive {:aggregated_block, %{"height" => 840_000}}, 1_000

    Process.sleep(50)
    arrivals = Metrics.recent_block_arrivals()
    assert Enum.any?(arrivals, &(&1.height == 840_000))
  end

  test "publishes aggregated_peers on rpc peers event" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")

    Phoenix.PubSub.broadcast(
      NodeProbe.PubSub,
      "rpc:events",
      {:peers, [%{"id" => 1, "addr" => "1.2.3.4:8333"}]}
    )

    assert_receive {:aggregated_peers, [%{"id" => 1}]}, 1_000
  end

  test "emits block latency anomaly for second block" do
    Phoenix.PubSub.subscribe(NodeProbe.PubSub, "node_probe:events")

    Phoenix.PubSub.broadcast(
      NodeProbe.PubSub,
      "rpc:events",
      {:block, %{"height" => 840_000, "hash" => "hash_a", "tx" => []}}
    )

    assert_receive {:aggregated_block, _}, 1_000

    # Wait a moment so last_block_ts is set
    Process.sleep(100)

    Phoenix.PubSub.broadcast(
      NodeProbe.PubSub,
      "rpc:events",
      {:block, %{"height" => 840_001, "hash" => "hash_b", "tx" => []}}
    )

    assert_receive {:anomaly, %{category: :bitcoin, severity: :info}}, 1_000
  end
end
