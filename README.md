# node-probe

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Version](https://img.shields.io/badge/version-0.1.0-orange.svg)](CHANGELOG.md)

A Bitcoin node observatory that combines eBPF kernel-level behavioral tracing of `bitcoind`
with Bitcoin RPC/P2P semantic data, streamed live to a Phoenix LiveView dashboard.

Your node, from two simultaneous angles: **what the kernel sees** (raw behavioral truth) and
**what Bitcoin sees** (semantic meaning).

---

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │                  bitcoind                    │
                        └──────┬──────────────────────┬───────────────┘
                               │ kernel events         │ JSON-RPC
              ┌────────────────▼──────────┐   ┌───────▼───────────────┐
              │   node-probe-loader       │   │    RpcCollector        │
              │   (Rust/Aya eBPF)         │   │    (GenServer)         │
              │   syscall | latency       │   │    getblockchaininfo   │
              │   net     | cpu sample    │   │    getpeerinfo         │
              └────────────────┬──────────┘   │    getmempoolinfo      │
                               │ JSON stdout  └───────┬───────────────┘
              ┌────────────────▼──────────┐           │
              │   EbpfCollector           │           │
              │   (GenServer + Port)      │           │
              └────────────────┬──────────┘           │
                               │                      │
                        PubSub │ "ebpf:events"        │ PubSub "rpc:events"
                               │                      │
                        ┌──────▼──────────────────────▼───────┐
                        │            Aggregator               │
                        │   correlates kernel ↔ bitcoin       │
                        │   maintains ETS rolling metrics     │
                        └──────────────────┬──────────────────┘
                                           │ PubSub "node_probe:events"
              ┌────────────────────────────┼────────────────────────────┐
              │            │              │               │             │
         ┌────▼───┐  ┌─────▼──┐  ┌───────▼──┐  ┌───────▼──┐  ┌───────▼──┐
         │ Pulse  │  │ Block  │  │  Peers   │  │ Mempool  │  │   I/O    │
         │ Live   │  │ Live   │  │  Live    │  │  Live    │  │  Live    │
         └────────┘  └────────┘  └──────────┘  └──────────┘  └──────────┘
                                         Browser (LiveView)
```

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Linux kernel | >= 5.8 | eBPF ring buffer, `bpf_get_stackid` |
| Elixir | >= 1.15 | OTP 26+ |
| Rust | nightly | For eBPF kernel programs (`aya-ebpf`, `no_std`) |
| `bpf-linker` | latest | `cargo install bpf-linker` |
| `bitcoind` | any | Must be running on the same host |
| Capabilities | `CAP_BPF`, `CAP_PERFMON` | Or run loader as root |

---

## Quickstart

```bash
# 1. Clone and install Elixir deps
git clone https://github.com/151henry151/node-probe.git
cd node-probe
mix deps.get

# 2. Install Rust nightly + bpf-linker (one-time setup)
rustup toolchain install nightly --component rust-src
cargo install bpf-linker

# 3. Build eBPF programs and loader
make ebpf

# 4. Configure Bitcoin RPC connection
export BITCOIN_RPC_URL=http://127.0.0.1:8332
export BITCOIN_COOKIE_PATH=~/.bitcoin/.cookie   # or use user/pass:
# export BITCOIN_RPC_USER=bitcoin
# export BITCOIN_RPC_PASS=yourpassword

# 5. Start the dashboard
mix phx.server
# Open http://localhost:4000
```

---

## Dashboard

| Route | Description |
|---|---|
| `/` | Single-page dashboard: overview (chain, mempool, eBPF, live pulse), latest block + fee histogram, mempool sparkline, peers table, kernel I/O, anomaly log |
| `/block`, `/peers`, `/mempool`, `/io`, `/anomalies` | HTTP redirects to `/` (bookmark-compatible) |

---

## Configuration Reference

All configuration is via environment variables at runtime.

| Variable | Default | Description |
|---|---|---|
| `BITCOIN_RPC_URL` | `http://127.0.0.1:8332` | Bitcoin Core JSON-RPC endpoint |
| `BITCOIN_RPC_USER` | `bitcoin` | RPC username (cookie auth preferred) |
| `BITCOIN_RPC_PASS` | _(empty)_ | RPC password |
| `BITCOIN_COOKIE_PATH` | `~/.bitcoin/.cookie` | Path to `.cookie` file for cookie auth |
| `EBPF_LOADER_PATH` | `./priv/ebpf/target/release/node-probe-loader` | Path to compiled eBPF loader binary |
| `EBPF_ENABLED` | `true` | Set `false` to disable eBPF tracing entirely |
| `P2P_TAP_ENABLED` | `false` | Enable raw P2P message tapping |
| `RPC_POLL_MS` | `2000` | RPC polling interval in milliseconds |
| `LITE_MODE` | `false` | See Lite Mode below |
| `PORT` | `4000` | HTTP port for the Phoenix server |
| `SECRET_KEY_BASE` | _(dev only)_ | Required in production — generate with `mix phx.gen.secret` |

---

## Lite Mode

Set `LITE_MODE=true` for Raspberry Pi or constrained hardware.

**Disabled in lite mode:**
- CPU flame graph sampling — the 99Hz `perf_event` eBPF sampler is not loaded
- P2P message tapping
- High-frequency eBPF syscall tracing

The dashboard remains fully functional; you lose CPU profiling and fine-grained syscall data.

```bash
# Development
LITE_MODE=true mix phx.server

# Production release
make release-lite
```

---

## Building

```bash
make all          # build eBPF programs + compile Elixir
make ebpf         # build only eBPF workspace (kernel programs + loader)
make ebpf-lite    # build eBPF workspace in lite mode
make elixir       # deps.get + compile
make test         # run Rust unit tests + Elixir test suite
make release      # MIX_ENV=prod mix release (creates tarball)
make release-lite # LITE_MODE=true production release
make clean        # cargo clean + mix clean
```

---

## Deployment

### eBPF Capabilities

The loader binary needs kernel privileges. Grant capabilities instead of running as root:

```bash
sudo setcap cap_bpf,cap_perfmon+ep ./priv/ebpf/target/release/node-probe-loader
```

Or set `AmbientCapabilities=CAP_BPF CAP_PERFMON` in the systemd unit (see below).

When the loader is spawned as an Erlang **Port**, its **stdout is a pipe**. The loader **`flush`es** stdout after each NDJSON line so the Phoenix **`EbpfCollector`** receives events in real time — without that, lines can sit in a libc block buffer and the dashboard stays empty even while probes fire.

### Mix Release

```bash
make release
# Release tarball: _build/prod/node_probe-0.1.0.tar.gz
# Extract to /opt/node-probe and run: bin/node_probe start
```

The release is self-contained — no Elixir/Erlang runtime required on the target.

### Systemd

A unit file is provided at `priv/systemd/node-probe.service`:

```bash
sudo cp priv/systemd/node-probe.service /etc/systemd/system/
# Edit /etc/systemd/system/node-probe.service — set SECRET_KEY_BASE, paths, etc.
sudo systemctl daemon-reload
sudo systemctl enable --now node-probe
sudo journalctl -fu node-probe   # tail logs
```

---

## Testing

```bash
mix test                  # full Elixir test suite
mix test --cover          # with coverage report
mix test --stale          # only tests affected by recent changes
cd priv/ebpf && cargo test --lib --package node-probe-ebpf
cd priv/ebpf && cargo test --package node-probe-loader
```

Coverage target: >80% line coverage on all Elixir modules.

---

## Contributing

1. Fork and create a feature branch from `main`.
2. Follow TDD — write tests alongside every module.
3. Run `mix precommit` before pushing (compile with warnings-as-errors, format, test).
4. Open a pull request. Keep commits bisectable — one logical change per commit.

---

## License

node-probe is free software, licensed under the GNU General Public License v3.0 or later.
See the [LICENSE](LICENSE) file (to be added) or https://www.gnu.org/licenses/gpl-3.0.html.
