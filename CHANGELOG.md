# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] - 2026-05-09

### Fixed

- Register **LiveView chart hooks** (`FeeHistogram`, `Sparkline`) in **`assets/js/chart_hooks.js`** — the generated **phoenix-colocated** bundle was empty, so block fee charts and mempool sparklines never rendered.
- Convert **`mempoolminfee`** from **BTC/kB** to **sat/vB** for display and format without scientific notation via **`NodeProbeWeb.FeeFormat`**.
- **I/O** LiveView: aggregate **all** syscall types (read/write/openat/...) with clearer empty-state copy; keep path-prefix and recent files when the loader provides **`filename`**.
- **Rust loader**: include optional **`filename`** in syscall JSON and parse the path payload from the ring buffer when present.

## [0.1.3] - 2026-05-09

### Added

- **`target/bpfel-unknown-none/release/node-probe-ebpf`** symlink so **`node-probe-loader`** default **`./target/...`** path resolves when the app **`cwd`** is the Elixir project root (loader binary lives under **`priv/ebpf/target/`**).

## [0.1.2] - 2026-05-09

### Fixed

- Resolve LiveView WebSocket path from the digested **`script[phx-track-static]`** URL so **`/node-probe/live`** works behind nginx (avoid connecting to **`/live`** at site root).
- Use **`~p`** path helpers for sidebar navigation links when **`PHX_PATH`** is set.

## [0.1.1] - 2026-05-09

### Changed

- Start **`RpcCollector`** and **`EbpfCollector`** under **`NodeProbe.Application`** so RPC and eBPF pipelines run in production.
- Extend **`config/runtime.exs`** production settings with **`PHX_PATH`** (nginx path prefix), loopback **`http`** bind, and **`check_origin`** for **`hromp.com`** / **`www.hromp.com`** when **`PHX_BIND`** is unset.

### Added

- Ignore **`.env.production`** in **`.gitignore`**.

## [0.1.0] - 2026-05-08

### Added
- Initial Phoenix/LiveView project scaffold with dark oscilloscope-style UI
- Rust/Aya eBPF workspace with four kernel programs: syscall tracer, latency probe (kprobe/kretprobe), TCP state tracepoint, and 99Hz CPU sampler
- `node-probe-loader` userspace binary: auto-discovers `bitcoind` PID via `/proc`, attaches all probes, streams newline-delimited JSON events to stdout; supports `--lite` flag
- `EbpfCollector` GenServer: spawns loader as an Erlang Port, decodes JSON lines, publishes to `Phoenix.PubSub` on topic `"ebpf:events"`; restarts automatically on loader exit
- `RpcCollector` GenServer: polls Bitcoin Core JSON-RPC on a configurable interval (`getblockchaininfo`, `getpeerinfo`, `getmempoolinfo`, `getblock`); publishes to `"rpc:events"`
- `Bitcoin.Rpc` HTTP client: supports both cookie authentication and username/password; wraps `Finch`
- `Bitcoin.RpcBehaviour` for Mox-compatible test mocking
- `Bitcoin.Enricher`: enriches raw RPC data into typed structs — `Block`, `Tx`, `Peer`, `MempoolEntry`; computes fee rates, spend type breakdown, median fee rate
- `Bitcoin.Types`: typed structs for `Block`, `Tx`, `Peer`, `MempoolEntry`
- `Aggregator` GenServer: subscribes to both PubSub topics, correlates eBPF ↔ Bitcoin events, emits anomaly events, publishes to `"node_probe:events"`
- `Metrics`: ETS-backed rolling metrics store — latency histograms, syscall counters, per-peer byte totals, mempool size history, block arrival times
- Six LiveView routes: Pulse (`/`), Block (`/block`), Peers (`/peers`), Mempool (`/mempool`), I/O (`/io`), Anomalies (`/anomalies`)
- Dark "oscilloscope meets terminal" UI theme: `#0a0a0f` background, Bitcoin orange (`#f7931a`) for Bitcoin-layer data, electric blue (`#4fc3f7`) for kernel-layer data, JetBrains Mono for live values, DM Sans for labels; responsive sidebar navigation
- `Makefile` with targets: `all`, `ebpf`, `ebpf-lite`, `elixir`, `test`, `release`, `release-lite`, `clean`
- Mix release configuration with eBPF loader binary overlay
- Systemd unit file (`priv/systemd/node-probe.service`) with `CAP_BPF`/`CAP_PERFMON` support
- Full test suite: ExUnit with Mox for RPC mocking, StreamData property tests for the enricher, Phoenix.LiveViewTest for all six LiveView modules, Rust unit tests for event struct layouts and JSON serialization
- `LITE_MODE` support: disables CPU sampler, P2P tap, and high-frequency syscall tracing for Raspberry Pi / constrained hardware
