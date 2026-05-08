.PHONY: all ebpf ebpf-lite elixir test release release-lite clean

all: ebpf elixir

ebpf:
	cd priv/ebpf/node-probe-ebpf && cargo build --bin node-probe-ebpf --target bpfel-unknown-none -Z build-std=core --release
	cd priv/ebpf && cargo build --release --package node-probe-loader

ebpf-lite:
	cd priv/ebpf/node-probe-ebpf && cargo build --bin node-probe-ebpf --target bpfel-unknown-none -Z build-std=core --release --features lite
	cd priv/ebpf && cargo build --release --package node-probe-loader

elixir:
	mix deps.get && mix compile

test:
	cd priv/ebpf/node-probe-ebpf && cargo test --lib
	cd priv/ebpf && cargo test --package node-probe-loader
	mix test

release:
	MIX_ENV=prod mix release

release-lite:
	LITE_MODE=true MIX_ENV=prod mix release

clean:
	cd priv/ebpf && cargo clean
	mix clean
