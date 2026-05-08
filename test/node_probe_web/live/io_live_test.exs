defmodule NodeProbeWeb.IoLiveTest do
  use NodeProbeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "renders empty state before any eBPF events", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/io")
    assert html =~ "No file events yet"
    assert html =~ "I/O"
  end

  test "updates file access counts on openat event", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/io")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "ebpf:events", {:ebpf_event, %{"type" => "syscall", "syscall" => "openat", "filename" => "/home/bitcoin/.bitcoin/blocks/blk00142.dat", "ts" => 1_716_000_000_000_000_000}})

    rendered = render(view)
    assert rendered =~ "blocks/"
  end

  test "shows latency histogram on latency events", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/io")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "ebpf:events", {:ebpf_event, %{"type" => "latency", "op" => "read", "latency_ns" => 50_000}})

    rendered = render(view)
    assert rendered =~ "10-100µs"
  end

  test "shows recent file open events", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/io")

    Phoenix.PubSub.broadcast(NodeProbe.PubSub, "ebpf:events", {:ebpf_event, %{"type" => "syscall", "syscall" => "openat", "filename" => "/bitcoin/chainstate/MANIFEST-000042", "ts" => 1_716_000_000_000_000_000}})

    rendered = render(view)
    assert rendered =~ "/bitcoin/chainstate/MANIFEST-000042"
  end
end
