# node-probe — Cursor Agent Implementation Prompt

## Project overview

Build `node-probe`: a Bitcoin node observatory that combines eBPF kernel-level
behavioral tracing of `bitcoind` with Bitcoin RPC/P2P semantic data — enriched
via the `bitcoinex` Elixir library — streamed live to a Phoenix LiveView
dashboard. The user sees their node from two simultaneous angles: what the
kernel sees (raw behavioral truth) and what Bitcoin sees (semantic meaning).

This is an open-source project licensed under the GPL. Follow TDD throughout:
write tests before or alongside every module. Maintain a CHANGELOG following
Keep a Changelog conventions. Use semantic versioning starting at `0.1.0`.

---

## Repository structure

```
node-probe/
├── LICENSE                        # GPL v3
├── CHANGELOG.md                   # Keep a Changelog format
├── README.md
├── mix.exs
├── mix.lock
├── .formatter.exs
├── .gitignore
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── prod.exs
│   ├── test.exs
│   └── runtime.exs                # Runtime env config (RPC URL, cookie, etc.)
├── priv/
│   ├── ebpf/                      # Rust/Aya workspace (see below)
│   │   ├── Cargo.toml
│   │   ├── node-probe-ebpf/       # eBPF kernel programs (no_std)
│   │   │   ├── Cargo.toml
│   │   │   └── src/main.rs
│   │   └── node-probe-loader/     # Userspace loader binary
│   │       ├── Cargo.toml
│   │       └── src/main.rs
│   └── static/
├── lib/
│   ├── node_probe/
│   │   ├── application.ex
│   │   ├── collectors/
│   │   │   ├── ebpf_collector.ex       # GenServer: manages loader binary, reads ring buffer
│   │   │   ├── rpc_collector.ex        # GenServer: polls bitcoind JSON-RPC
│   │   │   └── p2p_collector.ex        # GenServer: taps raw p2p message stream (optional)
│   │   ├── aggregator.ex               # Merges event streams, enriches via Bitcoinex
│   │   ├── event.ex                    # Shared event struct definitions
│   │   ├── bitcoin/
│   │   │   ├── rpc.ex                  # Bitcoin RPC client wrapper
│   │   │   ├── enricher.ex             # Bitcoinex-based tx/script/fee enrichment
│   │   │   └── types.ex                # Domain types: Block, Tx, Peer, MempoolEntry
│   │   └── metrics.ex                  # In-memory rolling metrics store (ETS)
│   └── node_probe_web/
│       ├── endpoint.ex
│       ├── router.ex
│       ├── telemetry.ex
│       ├── live/
│       │   ├── pulse_live.ex           # Top-level node heartbeat view
│       │   ├── block_live.ex           # Block arrival theater
│       │   ├── peers_live.ex           # Live peer map
│       │   ├── mempool_live.ex         # Mempool lens
│       │   ├── io_live.ex              # File I/O explorer
│       │   └── anomaly_live.ex         # Rolling anomaly/event feed
│       └── components/
│           ├── core_components.ex
│           ├── chart_component.ex      # Reusable live chart wrapper
│           ├── peer_map_component.ex
│           └── event_feed_component.ex
└── test/
    ├── node_probe/
    │   ├── collectors/
    │   │   ├── ebpf_collector_test.exs
    │   │   ├── rpc_collector_test.exs
    │   │   └── p2p_collector_test.exs
    │   ├── aggregator_test.exs
    │   ├── bitcoin/
    │   │   ├── rpc_test.exs
    │   │   └── enricher_test.exs
    │   └── metrics_test.exs
    └── node_probe_web/
        └── live/
            ├── pulse_live_test.exs
            ├── block_live_test.exs
            └── mempool_live_test.exs
```

---

## Phase 1 — Project scaffold

### 1.1 Mix project

Create the Phoenix project:

```bash
mix phx.new node_probe --no-ecto --no-mailer --no-dashboard
```

Add to `mix.exs` dependencies:

```elixir
{:bitcoinex, "~> 0.1"},
{:jason, "~> 1.4"},
{:finch, "~> 0.18"},
{:phoenix_live_view, "~> 0.20"},
{:telemetry_metrics, "~> 0.6"},
{:telemetry_poller, "~> 1.0"},
```

### 1.2 Licensing and project identity

- Write `LICENSE` as GPLv3 (full text).
- Write `CHANGELOG.md` with initial `[Unreleased]` section and a `[0.1.0]`
  stub covering scaffold, eBPF loader, RPC collector, basic LiveView pulse.
- Write `README.md` with: project description, architecture diagram (ASCII),
  prerequisites, quickstart, configuration reference, Pi/lite mode note,
  contributing guide, license badge.

### 1.3 Configuration

`config/runtime.exs` should read from environment:

```elixir
config :node_probe,
  bitcoin_rpc_url: System.get_env("BITCOIN_RPC_URL", "http://127.0.0.1:8332"),
  bitcoin_rpc_user: System.get_env("BITCOIN_RPC_USER", "bitcoin"),
  bitcoin_rpc_pass: System.get_env("BITCOIN_RPC_PASS", ""),
  bitcoin_cookie_path: System.get_env("BITCOIN_COOKIE_PATH", "~/.bitcoin/.cookie"),
  ebpf_loader_path: System.get_env("EBPF_LOADER_PATH", "./priv/ebpf/target/release/node-probe-loader"),
  ebpf_enabled: System.get_env("EBPF_ENABLED", "true") == "true",
  p2p_tap_enabled: System.get_env("P2P_TAP_ENABLED", "false") == "true",
  rpc_poll_interval_ms: String.to_integer(System.get_env("RPC_POLL_MS", "2000")),
  lite_mode: System.get_env("LITE_MODE", "false") == "true"
```

`lite_mode: true` disables: CPU flame graph sampling, p2p tap, high-frequency
eBPF syscall tracing. Suitable for Raspberry Pi. Document this clearly.

---

## Phase 2 — eBPF programs (Rust + Aya)

The eBPF subsystem lives in `priv/ebpf/` as a Cargo workspace. It compiles
independently and produces a single release binary: `node-probe-loader`.

### 2.1 Cargo workspace

`priv/ebpf/Cargo.toml`:

```toml
[workspace]
members = ["node-probe-ebpf", "node-probe-loader"]
resolver = "2"
```

### 2.2 Kernel-side programs (`node-probe-ebpf`)

Use `aya-ebpf` (no_std). Implement the following eBPF programs, each as a
separate function with the appropriate Aya attribute:

**a) Syscall tracer** — `tracepoint/syscalls/sys_enter_*`

Attach to: `openat`, `read`, `write`, `fsync`, `fdatasync`, `connect`,
`sendto`, `recvfrom`, `clone`, `execve`.

Filter by PID (passed in via a BPF map from userspace — the PID of `bitcoind`).
Emit events to a perf ring buffer:

```rust
#[repr(C)]
pub struct SyscallEvent {
    pub pid: u32,
    pub tid: u32,
    pub syscall_nr: u32,
    pub timestamp_ns: u64,
    pub filename: [u8; 256],  // for openat
    pub fd: i32,
    pub ret: i64,
}
```

**b) Latency probe** — `kprobe` + `kretprobe` pairs

Instrument: `vfs_read`, `vfs_write`, `blk_account_io_start` /
`blk_account_io_done`. Track entry timestamp in a per-tid BPF hashmap, emit
latency on return:

```rust
#[repr(C)]
pub struct LatencyEvent {
    pub pid: u32,
    pub op: u8,           // 0=read, 1=write, 2=blk
    pub latency_ns: u64,
    pub bytes: u64,
    pub filename_hash: u32,
}
```

**c) Network probe** — `tracepoint/sock/inet_sock_set_state`

Track TCP state transitions for sockets owned by `bitcoind`. Emit:

```rust
#[repr(C)]
pub struct NetEvent {
    pub pid: u32,
    pub saddr: u32,
    pub daddr: u32,
    pub sport: u16,
    pub dport: u16,
    pub old_state: u8,
    pub new_state: u8,
    pub timestamp_ns: u64,
}
```

**d) CPU sampler** — `perf_event` (only when `lite_mode` is false)

Sample `bitcoind`'s CPU at 99Hz. Capture stack traces (up to 20 frames) via
`bpf_get_stackid`. Emit stack IDs to a ringbuf for userspace flame graph
folding.

### 2.3 Userspace loader (`node-probe-loader`)

Uses `aya` (std). Responsibilities:

1. Accept `bitcoind` PID as CLI arg or discover it via `/proc` scan for
   `bitcoind` process name.
2. Load and attach all eBPF programs above.
3. Write `bitcoind` PID into the filter BPF map.
4. Poll perf ring buffers for all event types.
5. Serialize events as newline-delimited JSON to stdout.
6. Accept a `--lite` flag that skips loading the CPU sampler program.

Output format (one JSON object per line):

```json
{"type":"syscall","pid":12345,"syscall":"openat","filename":"/home/bitcoin/.bitcoin/blocks/blk00142.dat","ts":1716000000000000000}
{"type":"latency","pid":12345,"op":"read","latency_ns":842000,"bytes":4096}
{"type":"net","pid":12345,"daddr":"192.168.1.10","dport":8333,"state_change":"ESTABLISHED","ts":1716000000000000001}
{"type":"cpu_sample","pid":12345,"stack_id":7,"ts":1716000000000000002}
```

Write tests for JSON serialization and PID discovery logic.

---

## Phase 3 — Elixir collectors

### 3.1 `EbpfCollector`

A GenServer that:

1. On start, spawns the `node-probe-loader` binary as a Port using
   `Port.open({:spawn_executable, loader_path}, [:binary, :line, args: args])`.
2. Receives lines from the port, decodes JSON, and publishes to
   `Phoenix.PubSub` on topic `"ebpf:events"`.
3. Handles port exit gracefully — logs, waits 5s, restarts.
4. Respects `ebpf_enabled: false` config — if disabled, starts in no-op mode
   and logs a warning.

```elixir
defmodule NodeProbe.Collectors.EbpfCollector do
  use GenServer
  require Logger
  alias Phoenix.PubSub

  # GenServer callbacks...
  # handle_info({port, {:data, {:eol, line}}}, state) -> decode and publish
  # handle_info({port, {:exit_status, status}}, state) -> restart logic
end
```

Write tests using a mock port (send fake JSON lines into the GenServer).

### 3.2 `RpcCollector`

A GenServer that polls the Bitcoin RPC on a configurable interval. Implements:

```elixir
defmodule NodeProbe.Collectors.RpcCollector do
  use GenServer

  # Polls on interval, calls NodeProbe.Bitcoin.Rpc for:
  # - getblockchaininfo
  # - getnetworkinfo
  # - getpeerinfo
  # - getmempoolinfo
  # - getmempoolentry (for new txids seen)
  # - getbestblockhash + getblock (when new block detected)
  #
  # Publishes to Phoenix.PubSub topic "rpc:events"
  # Emits: {:block, block_data}, {:peers, peer_list},
  #        {:mempool, mempool_info}, {:chain, chain_info}
end
```

Write tests mocking the RPC HTTP client with `Finch` test adapter or `Mox`.

### 3.3 `Bitcoin.Rpc`

Thin HTTP client wrapping `Finch`:

```elixir
defmodule NodeProbe.Bitcoin.Rpc do
  # call(method, params \\ []) :: {:ok, result} | {:error, reason}
  # Reads config for URL, auth. Supports cookie auth and user/pass auth.
  # Handles RPC error codes cleanly.
end
```

### 3.4 `Bitcoin.Enricher`

Uses `Bitcoinex` to decode and enrich raw RPC data:

```elixir
defmodule NodeProbe.Bitcoin.Enricher do
  # enrich_block(raw_block) :: %Block{
  #   hash, height, timestamp, tx_count, total_fees_sat,
  #   weight, median_fee_rate, spend_type_breakdown
  # }
  #
  # enrich_tx(raw_tx) :: %Tx{
  #   txid, fee_sat, fee_rate_svb, weight, input_count,
  #   output_count, spend_types, total_output_sat
  # }
  #
  # Uses Bitcoinex for: script parsing, bech32, fee calculation
end
```

### 3.5 `Aggregator`

A GenServer that subscribes to both `"ebpf:events"` and `"rpc:events"` PubSub
topics, correlates them (e.g. when a block arrives via RPC, pair it with the
eBPF I/O burst that coincided), and publishes enriched composite events to
`"node_probe:events"` for LiveView processes to consume.

Also maintains a rolling in-memory state in ETS via `NodeProbe.Metrics`:
- Last 60 seconds of latency samples (histogram buckets)
- Syscall frequency counters per syscall type
- Per-peer byte counters
- Mempool size history (last 10 minutes)
- Block arrival times

---

## Phase 4 — LiveView dashboard

### 4.1 Router

```elixir
scope "/", NodeProbeWeb do
  pipe_through :browser

  live "/", PulseLive, :index
  live "/block", BlockLive, :index
  live "/peers", PeersLive, :index
  live "/mempool", MempoolLive, :index
  live "/io", IoLive, :index
  live "/anomalies", AnomalyLive, :index
end
```

### 4.2 Visual design direction

The UI should feel like **a serious technical instrument** — not a startup
dashboard. Think oscilloscope meets terminal. Design notes for the agent:

- Dark theme only. Background: near-black (`#0a0a0f`). Not pure black.
- Accent color: Bitcoin orange (`#f7931a`) used sparingly — only for live
  data highlights and the most important numbers.
- Secondary accent: a cold electric blue (`#4fc3f7`) for eBPF/kernel-layer
  data, to visually distinguish it from Bitcoin-layer data (orange).
- Typography: monospace for all live data values (use `JetBrains Mono` from
  Google Fonts). A clean geometric sans for labels (`DM Sans` or `Outfit`).
- Layout: sidebar navigation (icon + label), main content area. Sidebar
  collapses on small screens.
- Animations: subtle. Data updates should feel like an instrument reading
  changing, not like a React component re-rendering. Use CSS transitions on
  value changes, not flash animations.
- Every live number should have a small sparkline next to it showing its last
  60 seconds of history.

### 4.3 `PulseLive` — node heartbeat

The landing view. Shows at a glance:

- Chain tip height + time since last block
- IBD progress bar (if syncing) — uses `getblockchaininfo.verificationprogress`
- Peer count (inbound / outbound breakdown)
- Mempool: tx count, size in MB, min fee rate
- eBPF health: is the loader running? Events/sec received?
- `bitcoind` process stats: CPU %, RSS memory, open file descriptors
- A live event ticker at the bottom: last 20 events from the aggregator

All values update via `handle_info` from PubSub. No polling in LiveView.

### 4.4 `BlockLive` — block arrival theater

When a new block arrives:
- Animate it in: block hash, height, timestamp, miner (if identifiable),
  tx count, total fees, median fee rate, weight/vsize, full/empty block indicator
- Below: the eBPF I/O burst that accompanied validation — bytes read from
  block files, UTXO db reads, validation latency
- A fee rate histogram for transactions in the block (use Chart.js via a
  LiveView hook)
- A spend type breakdown (P2PKH / P2WPKH / P2TR / P2SH / other) as a
  horizontal bar
- History of last 10 blocks as a scrollable timeline

### 4.5 `PeersLive` — peer connections

- Table of connected peers: IP, port, version, services, ping, bytes
  sent/received, connection duration, inbound/outbound
- Filter and sort controls (all client-side via LiveView assigns)
- A live bytes-in / bytes-out chart per peer (sparklines)
- Geolocation: resolve peer IPs to country/city using a local GeoIP database
  (`MaxMind GeoLite2` — embed as a priv asset). Show country flags.
- Highlight peers that have sent us a block or transaction recently (correlate
  with eBPF net events)

### 4.6 `MempoolLive` — mempool lens

- Total tx count, total size (MB), total fees (BTC + USD estimate)
- Fee rate histogram: bucket transactions into fee rate ranges, show as a
  live bar chart updating in real time as txs arrive/depart
- Tx arrival rate: txs/min over last 10 minutes (sparkline)
- Eviction feed: transactions evicted from mempool (RBF replacements,
  low-fee evictions) shown as a live event stream
- "Next block template estimate": based on mempool, what would a miner likely
  include? Show estimated fee range, tx count, weight

### 4.7 `IoLive` — file I/O explorer

- A live heatmap of file paths being accessed by `bitcoind` — rows are file
  path prefixes (blocks/, chainstate/, wallets/, etc.), columns are time
  buckets (last 60 seconds)
- Latency distribution: a histogram of read/write latencies updated live
- Top files by access count in the last 60 seconds
- A raw event stream of individual file opens with filename and latency

### 4.8 `AnomalyLive` — event feed

A chronological feed of interesting events detected by the aggregator:

- New peer connected / peer disconnected
- Block arrived (with height and latency since previous)
- Large mempool spike or drop (>20% change in 30s)
- Unusual file access (path never seen before in this session)
- eBPF latency spike (p99 > 10x baseline)
- Syscall rate anomaly
- IBD phase transition (headers → blocks → done)

Each event has: timestamp, category badge (kernel / bitcoin / peer / mempool),
severity (info / warn / alert), and a one-line description.

---

## Phase 5 — Build, release, deployment

### 5.1 Makefile

Provide a `Makefile` with targets:

```makefile
.PHONY: all ebpf elixir test release release-lite clean

all: ebpf elixir

ebpf:
	cd priv/ebpf && cargo build --release

ebpf-lite:
	cd priv/ebpf && cargo build --release --features lite

elixir:
	mix deps.get && mix compile

test:
	cd priv/ebpf && cargo test
	mix test

release:
	MIX_ENV=prod mix release

release-lite:
	LITE_MODE=true MIX_ENV=prod mix release

clean:
	cd priv/ebpf && cargo clean
	mix clean
```

### 5.2 Mix release config

In `mix.exs`, define a release:

```elixir
releases: [
  node_probe: [
    include_executables_for: [:unix],
    steps: [:assemble, :tar]
  ]
]
```

Include the compiled eBPF loader binary in the release via `mix.exs` overlays.

### 5.3 Deployment notes (README)

Document:
- Requirements: Linux kernel >= 5.8, `bitcoind` running on same host,
  user must have `CAP_BPF` and `CAP_PERFMON` (or run loader as root)
- Elixir/OTP release is self-contained, no runtime deps
- Systemd unit file example (provided in `priv/systemd/node-probe.service`)
- Environment variable reference
- `LITE_MODE=true` for Raspberry Pi / constrained hardware

---

## Phase 6 — Testing strategy

Follow TDD throughout. Specific guidance:

### eBPF (Rust)
- Unit test JSON serialization of all event structs
- Unit test PID discovery logic against a mock `/proc` directory
- Integration tests: use a mock `bitcoind` process, attach probes, verify
  events are emitted (run only in CI with `--features integration`)

### Elixir
- Use `ExUnit` with `async: true` where safe
- Mock the eBPF loader port with a fake process that sends canned JSON lines
- Mock Bitcoin RPC with `Mox` — define `NodeProbe.Bitcoin.RpcBehaviour`
- Use `Phoenix.LiveViewTest` for all LiveView tests:
  - Assert socket assigns update correctly on PubSub messages
  - Assert DOM elements reflect live data
- Property-based tests for `Enricher` using `StreamData` — generate random
  valid tx structures and verify fee calculations are always non-negative

### Coverage
- Aim for >80% line coverage on all Elixir modules
- Run `mix test --cover` in CI

---

## CHANGELOG.md initial content

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - unreleased

### Added
- Initial Phoenix/LiveView project scaffold
- Rust/Aya eBPF workspace: syscall, latency, network, CPU probes
- EbpfCollector GenServer (Port-based loader integration)
- RpcCollector GenServer (Bitcoin JSON-RPC polling)
- Bitcoin.Rpc client (cookie + user/pass auth)
- Bitcoin.Enricher (Bitcoinex-based tx/block enrichment)
- Aggregator GenServer (event correlation, ETS metrics store)
- PulseLive: live node heartbeat dashboard
- BlockLive: block arrival theater
- PeersLive: live peer table with geolocation
- MempoolLive: fee histogram and tx rate live view
- IoLive: file I/O heatmap and latency explorer
- AnomalyLive: rolling event feed
- Makefile with ebpf / elixir / test / release / release-lite targets
- Systemd unit file
- GPL v3 license
- Full test suite (ExUnit + Mox + StreamData + Rust unit tests)
```

---

## Implementation order for the agent

Build in this sequence. **After each numbered commit point, run all tests, then
commit and push before proceeding to the next.** This produces a clean,
bisectable history. Never bundle work from two commit points into one commit.
Commit messages are given verbatim — use them exactly.

Before the first commit, initialize the repo and configure the remote:

```bash
git init
git remote add origin git@github.com:151henry151/node-probe.git
git branch -M main
```

---

### Commit 1 — Project scaffold

Implement:
- Mix project (`mix phx.new`) with all deps added to `mix.exs`
- `config/runtime.exs` with full env var config block
- `LICENSE` (GPL v3 full text)
- `CHANGELOG.md` (initial skeleton with `[Unreleased]` and `[0.1.0] - unreleased` stub)
- `README.md` (project description, architecture ASCII diagram, prerequisites,
  quickstart placeholder, license badge)
- `.gitignore` (Elixir + Rust + editor files)

Run: `mix deps.get && mix compile` — must succeed with no errors.

```
git add -A
git commit -m "chore: initial project scaffold, config, license, changelog"
git push -u origin main
```

---

### Commit 2 — Bitcoin RPC client

Implement:
- `NodeProbe.Bitcoin.Rpc` module with cookie + user/pass auth
- `NodeProbe.Bitcoin.RpcBehaviour` (Mox-compatible behaviour)
- `test/node_probe/bitcoin/rpc_test.exs`

Run: `mix test test/node_probe/bitcoin/rpc_test.exs` — all tests pass.

```
git add -A
git commit -m "feat: Bitcoin RPC client with cookie and user/pass auth"
git push
```

---

### Commit 3 — RPC collector

Implement:
- `NodeProbe.Collectors.RpcCollector` GenServer
- `test/node_probe/collectors/rpc_collector_test.exs`

Run: `mix test test/node_probe/collectors/` — all tests pass.

```
git add -A
git commit -m "feat: RpcCollector GenServer with PubSub event publishing"
git push
```

---

### Commit 4 — Bitcoin enricher

Implement:
- `NodeProbe.Bitcoin.Enricher` (Bitcoinex-based tx/block enrichment)
- `NodeProbe.Bitcoin.Types` (Block, Tx, Peer, MempoolEntry structs)
- `test/node_probe/bitcoin/enricher_test.exs` (include StreamData property tests)

Run: `mix test test/node_probe/bitcoin/` — all tests pass.

```
git add -A
git commit -m "feat: Bitcoin.Enricher with Bitcoinex tx/script/fee decoding"
git push
```

---

### Commit 5 — eBPF Rust workspace (kernel programs)

Implement:
- `priv/ebpf/Cargo.toml` workspace
- `priv/ebpf/node-probe-ebpf/` — all four eBPF kernel programs:
  syscall tracer, latency probe, network probe, CPU sampler
- Rust unit tests for event struct serialization

Run: `cd priv/ebpf && cargo build` — must compile cleanly for the eBPF target.
Run: `cd priv/ebpf && cargo test --package node-probe-ebpf` — all tests pass.

```
git add -A
git commit -m "feat: Aya eBPF kernel programs (syscall, latency, net, cpu)"
git push
```

---

### Commit 6 — eBPF loader binary

Implement:
- `priv/ebpf/node-probe-loader/` — userspace loader:
  PID discovery, program attachment, ring buffer polling, JSON stdout output,
  `--lite` flag
- Rust unit tests for PID discovery and JSON serialization

Run: `cd priv/ebpf && cargo build --release` — produces release binary.
Run: `cd priv/ebpf && cargo test --package node-probe-loader` — all tests pass.

```
git add -A
git commit -m "feat: eBPF userspace loader binary with JSON event output"
git push
```

---

### Commit 7 — eBPF Elixir collector

Implement:
- `NodeProbe.Collectors.EbpfCollector` GenServer (Port-based)
- `test/node_probe/collectors/ebpf_collector_test.exs` (mock port)

Run: `mix test test/node_probe/collectors/ebpf_collector_test.exs` — all pass.

```
git add -A
git commit -m "feat: EbpfCollector GenServer bridging loader Port to PubSub"
git push
```

---

### Commit 8 — Aggregator and metrics store

Implement:
- `NodeProbe.Metrics` (ETS-backed rolling metrics store)
- `NodeProbe.Aggregator` GenServer (event correlation, anomaly detection)
- `test/node_probe/aggregator_test.exs`
- `test/node_probe/metrics_test.exs`

Run: `mix test` — full suite passes.

```
git add -A
git commit -m "feat: Aggregator GenServer and ETS metrics store"
git push
```

---

### Commit 9 — LiveView shell and navigation

Implement:
- Router with all six live routes
- Root layout with sidebar navigation (icon + label per view)
- Dark theme CSS — color variables, typography (JetBrains Mono + DM Sans),
  base component styles
- `NodeProbeWeb.CoreComponents` — shared UI primitives (badge, sparkline
  wrapper, event row, stat card)

Run: `mix phx.server` — app boots, sidebar renders, routes resolve.
Run: `mix test test/node_probe_web/` — layout and router tests pass.

```
git add -A
git commit -m "feat: LiveView router, sidebar shell, dark theme, core components"
git push
```

---

### Commit 10 — PulseLive

Implement:
- `NodeProbeWeb.Live.PulseLive`
- `test/node_probe_web/live/pulse_live_test.exs`

Run: `mix test test/node_probe_web/live/pulse_live_test.exs` — all pass.

```
git add -A
git commit -m "feat: PulseLive node heartbeat dashboard"
git push
```

---

### Commit 11 — BlockLive

Implement:
- `NodeProbeWeb.Live.BlockLive`
- Chart.js hook for fee rate histogram
- `test/node_probe_web/live/block_live_test.exs`

Run: `mix test test/node_probe_web/live/block_live_test.exs` — all pass.

```
git add -A
git commit -m "feat: BlockLive block arrival theater with fee histogram"
git push
```

---

### Commit 12 — PeersLive

Implement:
- `NodeProbeWeb.Live.PeersLive`
- GeoIP integration (MaxMind GeoLite2 in `priv/geoip/`)
- `NodeProbeWeb.Components.PeerMapComponent`
- `test/node_probe_web/live/peers_live_test.exs`

Run: `mix test test/node_probe_web/live/peers_live_test.exs` — all pass.

```
git add -A
git commit -m "feat: PeersLive with geolocation and per-peer byte sparklines"
git push
```

---

### Commit 13 — MempoolLive

Implement:
- `NodeProbeWeb.Live.MempoolLive`
- `test/node_probe_web/live/mempool_live_test.exs`

Run: `mix test test/node_probe_web/live/mempool_live_test.exs` — all pass.

```
git add -A
git commit -m "feat: MempoolLive fee histogram and tx arrival rate view"
git push
```

---

### Commit 14 — IoLive

Implement:
- `NodeProbeWeb.Live.IoLive`
- `test/node_probe_web/live/io_live_test.exs`

Run: `mix test test/node_probe_web/live/io_live_test.exs` — all pass.

```
git add -A
git commit -m "feat: IoLive file I/O heatmap and latency explorer"
git push
```

---

### Commit 15 — AnomalyLive

Implement:
- `NodeProbeWeb.Live.AnomalyLive`
- `NodeProbeWeb.Components.EventFeedComponent`
- `test/node_probe_web/live/anomaly_live_test.exs`

Run: `mix test` — full suite passes with no failures.

```
git add -A
git commit -m "feat: AnomalyLive rolling event feed"
git push
```

---

### Commit 16 — Build system and release

Implement:
- `Makefile` with all targets (ebpf, elixir, test, release, release-lite, clean)
- Mix release config in `mix.exs`
- `priv/systemd/node-probe.service` unit file

Run: `make test` — full Rust + Elixir test suite passes.
Run: `make release` — Mix release assembles cleanly.

```
git add -A
git commit -m "chore: Makefile, Mix release config, systemd unit file"
git push
```

---

### Commit 17 — Documentation and version cut

Implement:
- Full `README.md` pass: architecture diagram, configuration reference,
  prerequisites, quickstart, lite mode docs, contributing guide
- Move `[Unreleased]` items into `[0.1.0]` in `CHANGELOG.md` with today's date
- Verify `mix.exs` version is `"0.1.0"`

Run: `mix test` — all tests pass one final time.

```
git add -A
git commit -m "docs: complete README, cut v0.1.0 in CHANGELOG"
git tag v0.1.0
git push
git push --tags
```
