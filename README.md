# node-probe

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

A Bitcoin node observatory that combines eBPF kernel-level behavioral tracing of `bitcoind`
with Bitcoin RPC/P2P semantic data — enriched via the `bitcoinex` Elixir library — streamed
live to a Phoenix LiveView dashboard.

Your node, from two simultaneous angles: **what the kernel sees** (raw behavioral truth) and
**what Bitcoin sees** (semantic meaning).

---

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │                  bitcoind                    │
                        └──────┬──────────────────────┬───────────────┘
                               │ kernel events         │ JSON-RPC / P2P
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

- Linux kernel >= 5.8 (eBPF ring buffer, `bpf_get_stackid`)
- Elixir 1.15+ / OTP 26+
- Rust nightly toolchain (for eBPF kernel programs via `aya-ebpf`)
- `bitcoind` running on the same host
- The eBPF loader must have `CAP_BPF` and `CAP_PERFMON` capabilities, or run as root

---

## Quickstart

```bash
# 1. Clone and install Elixir deps
git clone https://github.com/151henry151/node-probe.git
cd node-probe
mix deps.get

# 2. Build eBPF programs (requires Rust nightly)
make ebpf

# 3. Configure (see Configuration Reference below)
export BITCOIN_RPC_URL=http://127.0.0.1:8332
export BITCOIN_RPC_USER=bitcoin
export BITCOIN_RPC_PASS=yourpassword

# 4. Start the dashboard
mix phx.server
# Visit http://localhost:4000
```

---

## Configuration Reference

All configuration is via environment variables. Defaults are shown.

| Variable | Default | Description |
|---|---|---|
| `BITCOIN_RPC_URL` | `http://127.0.0.1:8332` | Bitcoin Core RPC endpoint |
| `BITCOIN_RPC_USER` | `bitcoin` | RPC username (ignored if cookie auth is used) |
| `BITCOIN_RPC_PASS` | _(empty)_ | RPC password (ignored if cookie auth is used) |
| `BITCOIN_COOKIE_PATH` | `~/.bitcoin/.cookie` | Path to `.cookie` file for cookie auth |
| `EBPF_LOADER_PATH` | `./priv/ebpf/target/release/node-probe-loader` | Path to compiled eBPF loader binary |
| `EBPF_ENABLED` | `true` | Set to `false` to disable eBPF tracing entirely |
| `P2P_TAP_ENABLED` | `false` | Enable raw P2P message tapping |
| `RPC_POLL_MS` | `2000` | How often (ms) to poll Bitcoin RPC |
| `LITE_MODE` | `false` | See Lite Mode below |
| `PORT` | `4000` | HTTP port for the Phoenix server |
| `SECRET_KEY_BASE` | _(dev default)_ | Phoenix secret key (required in prod) |

---

## Lite Mode

Set `LITE_MODE=true` for Raspberry Pi or other constrained hardware.

Lite mode disables:
- **CPU flame graph sampling** — the 99Hz perf_event eBPF sampler is not loaded
- **P2P message tapping** — raw P2P stream capture is skipped
- **High-frequency eBPF syscall tracing** — only coarse-grained syscall events are emitted

The dashboard remains fully functional; you simply lose the CPU profiling view and fine-grained
syscall resolution.

```bash
LITE_MODE=true mix phx.server
# or for a release:
make release-lite
```

---

## Deployment

### Requirements

- Linux kernel >= 5.8 on the same host as `bitcoind`
- The eBPF loader binary (`node-probe-loader`) needs `CAP_BPF` and `CAP_PERFMON`:
  ```bash
  sudo setcap cap_bpf,cap_perfmon+ep ./priv/ebpf/target/release/node-probe-loader
  ```
  Or run node-probe as root in a trusted environment.

### Systemd

A unit file is provided at `priv/systemd/node-probe.service`. Copy and adjust:

```bash
sudo cp priv/systemd/node-probe.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now node-probe
```

### Mix Release

```bash
make release        # standard build
make release-lite   # Raspberry Pi / low-power build
```

The release tarball is self-contained — no Elixir/Erlang runtime needed on the target.

---

## Contributing

1. Fork the repo and create a feature branch.
2. Follow TDD — write tests alongside every module.
3. Run `mix precommit` before pushing (compiles with warnings-as-errors, formats, runs tests).
4. Open a pull request against `main`.

---

## License

GPL v3. See [LICENSE](LICENSE).
