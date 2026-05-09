defmodule NodeProbe.MetricsTest do
  use ExUnit.Case, async: false

  alias NodeProbe.Metrics

  setup do
    # ETS table is started by the app supervisor; just clean it before each test
    :ets.delete_all_objects(:node_probe_metrics)
    :ok
  end

  describe "syscall counters" do
    test "increments syscall count" do
      Metrics.increment_syscall("openat")
      Metrics.increment_syscall("openat")
      Metrics.increment_syscall("read")

      counts = Metrics.syscall_counts()
      assert counts["openat"] == 2
      assert counts["read"] == 1
    end

    test "returns empty map when no syscalls recorded" do
      assert Metrics.syscall_counts() == %{}
    end

    test "reset_syscall_counts clears all counters" do
      Metrics.increment_syscall("write")
      Metrics.reset_syscall_counts()
      assert Metrics.syscall_counts() == %{}
    end
  end

  describe "ingest_ebpf/1" do
    test "records syscall, path prefix, and recent path for filesystem samples" do
      Metrics.ingest_ebpf(%{
        "type" => "syscall",
        "syscall" => "openat",
        "filename" => "/var/lib/bitcoin/.bitcoin/blocks/foo.dat",
        "ts" => 99
      })

      assert Metrics.syscall_counts()["openat"] == 1
      assert Metrics.path_prefix_counts()["blocks/"] == 1
      assert [%{filename: _, ts: 99}] = Metrics.recent_paths()
    end

    test "records latency histogram buckets" do
      Metrics.ingest_ebpf(%{"type" => "latency", "op" => "read", "latency_ns" => 5_000})
      hist = Metrics.latency_histogram(:read)
      assert hist["1-10µs"] == 1
    end

    test "records vfs bytes from latency events" do
      Metrics.ingest_ebpf(%{
        "type" => "latency",
        "op" => "write",
        "latency_ns" => 1000,
        "bytes" => 4096
      })

      assert Metrics.vfs_bytes_totals(:write) >= 4096
    end

    test "records tcp state transitions from net events" do
      Metrics.ingest_ebpf(%{
        "type" => "net",
        "state_change" => "ESTABLISHED",
        "daddr" => "1.2.3.4",
        "dport" => 8333
      })

      assert Metrics.tcp_state_counts()["ESTABLISHED"] >= 1
    end

    test "records cpu_sample events in rolling window" do
      Metrics.ingest_ebpf(%{
        "type" => "cpu_sample",
        "pid" => 12345,
        "stack_id" => 7,
        "ts" => 1_716_000_000_000_000_002
      })

      Metrics.ingest_ebpf(%{"type" => "cpu_sample", "pid" => 12345})

      assert Metrics.cpu_samples_total_60s() == 2
      assert_in_delta Metrics.cpu_hz_estimate(), 2 / 60, 0.0001
    end
  end

  describe "latency samples" do
    test "records latency and buckets it correctly" do
      Metrics.record_latency(:read, 500)
      Metrics.record_latency(:read, 5_000)
      Metrics.record_latency(:read, 500_000)

      hist = Metrics.latency_histogram(:read)
      assert hist["<1µs"] == 1
      assert hist["1-10µs"] == 1
      assert hist["100µs-1ms"] == 1
    end

    test "returns empty histogram when no data" do
      assert Metrics.latency_histogram(:write) == %{}
    end
  end

  describe "peer byte counters" do
    test "records and retrieves peer bytes" do
      Metrics.record_peer_bytes(1, :sent, 1000)
      Metrics.record_peer_bytes(1, :sent, 500)
      Metrics.record_peer_bytes(1, :recv, 2000)

      assert %{sent: 1500, recv: 2000} = Metrics.peer_bytes(1)
    end

    test "returns zero for unknown peer" do
      assert %{sent: 0, recv: 0} = Metrics.peer_bytes(99999)
    end
  end

  describe "mempool history" do
    test "records and retrieves mempool size history" do
      Metrics.record_mempool_size(5000)
      Metrics.record_mempool_size(5100)
      Metrics.record_mempool_size(4900)

      history = Metrics.mempool_history()
      sizes = Enum.map(history, fn {_, size} -> size end)
      assert 5000 in sizes
      assert 5100 in sizes
      assert 4900 in sizes
    end

    test "returns empty list when no history" do
      assert Metrics.mempool_history() == []
    end
  end

  describe "block arrivals" do
    test "records and retrieves block arrivals" do
      Metrics.record_block_arrival(840_000, "hash_a")
      Metrics.record_block_arrival(840_001, "hash_b")

      arrivals = Metrics.recent_block_arrivals()
      assert length(arrivals) >= 2
      heights = Enum.map(arrivals, & &1.height)
      assert 840_000 in heights
      assert 840_001 in heights
    end

    test "returns most recent blocks first" do
      Metrics.record_block_arrival(840_000, "hash_a")
      Process.sleep(10)
      Metrics.record_block_arrival(840_001, "hash_b")

      [first | _] = Metrics.recent_block_arrivals()
      assert first.height == 840_001
    end

    test "limits results to requested count" do
      for i <- 1..15, do: Metrics.record_block_arrival(i, "hash_#{i}")
      assert length(Metrics.recent_block_arrivals(5)) == 5
    end
  end
end
