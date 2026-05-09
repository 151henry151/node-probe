defmodule NodeProbe.Collectors.EbpfCollectorTest do
  use ExUnit.Case, async: false

  alias NodeProbe.Collectors.EbpfCollector

  setup do
    # Use a fake "loader" that is just the `echo` command for happy-path tests,
    # and a non-existent path to test error handling.
    on_exit(fn ->
      Application.delete_env(:node_probe, :ebpf_enabled)
      Application.delete_env(:node_probe, :ebpf_loader_path)
      Application.delete_env(:node_probe, :lite_mode)
    end)

    :ok
  end

  defp start_collector(opts \\ []) do
    name = :"ebpf_collector_test_#{System.unique_integer([:positive])}"
    opts = Keyword.put_new(opts, :name, name)

    {:ok, pid} = start_supervised({EbpfCollector, opts}, id: make_ref())
    pid
  end

  describe "when ebpf_enabled is false" do
    test "starts in no-op mode without opening a port" do
      Application.put_env(:node_probe, :ebpf_enabled, false)
      Application.put_env(:node_probe, :ebpf_loader_path, "/nonexistent/loader")

      pid = start_collector()
      assert Process.alive?(pid)

      state = :sys.get_state(pid)
      assert state.port == nil
      assert state.enabled == false
    end
  end

  describe "when loader path is invalid" do
    test "starts without crashing when loader binary not found" do
      Application.put_env(:node_probe, :ebpf_enabled, true)
      Application.put_env(:node_probe, :ebpf_loader_path, "/nonexistent/node-probe-loader")

      pid = start_collector()
      assert Process.alive?(pid)
    end
  end

  describe "JSON line processing" do
    test "decodes valid syscall JSON lines into Metrics" do
      :ets.delete_all_objects(:node_probe_metrics)

      Application.put_env(:node_probe, :ebpf_enabled, false)
      pid = start_collector()

      # Simulate receiving a line from the port
      json = ~s({"type":"syscall","pid":12345,"syscall":"openat","ts":1716000000000000000})
      send(pid, {nil, {:data, {:eol, json}}})

      Process.sleep(50)
      assert NodeProbe.Metrics.syscall_counts()["openat"] >= 1
    end

    test "handles malformed JSON without crashing" do
      Application.put_env(:node_probe, :ebpf_enabled, false)
      pid = start_collector()

      send(pid, {nil, {:data, {:eol, "not json at all"}}})
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "port exit handling" do
    test "schedules restart after port exit without crashing" do
      Application.put_env(:node_probe, :ebpf_enabled, false)
      pid = start_collector()

      # Simulate port exit
      send(pid, {nil, {:exit_status, 1}})
      Process.sleep(50)

      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      assert state.port == nil
    end
  end
end
