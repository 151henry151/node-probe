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
