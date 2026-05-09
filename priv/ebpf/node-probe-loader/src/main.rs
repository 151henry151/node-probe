use anyhow::{anyhow, Context, Result};
use clap::Parser;
use serde::Serialize;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Parser, Debug)]
#[command(name = "node-probe-loader", about = "eBPF loader for node-probe")]
struct Args {
    /// PID of bitcoind process (auto-detected if omitted)
    #[arg(short, long)]
    pid: Option<u32>,

    /// Path to compiled eBPF object file
    #[arg(long, default_value = "./target/bpfel-unknown-none/release/node-probe-ebpf")]
    ebpf_obj: PathBuf,

    /// Disable CPU flame graph sampler (lite mode)
    #[arg(long)]
    lite: bool,
}

// ---------------------------------------------------------------------------
// Output event types
// ---------------------------------------------------------------------------

#[derive(Serialize, Debug)]
#[serde(tag = "type", rename_all = "snake_case")]
enum OutputEvent {
    Syscall {
        pid: u32,
        syscall: String,
        ts: u64,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        filename: String,
    },
    Latency {
        pid: u32,
        op: String,
        latency_ns: u64,
        bytes: u64,
    },
    Net {
        pid: u32,
        daddr: String,
        dport: u16,
        state_change: String,
        ts: u64,
    },
    CpuSample {
        pid: u32,
        stack_id: i64,
        ts: u64,
    },
}

fn syscall_name(nr: u32) -> &'static str {
    match nr {
        0 => "read",
        1 => "write",
        42 => "connect",
        44 => "sendto",
        45 => "recvfrom",
        56 => "clone",
        59 => "execve",
        74 => "fsync",
        75 => "fdatasync",
        257 => "openat",
        _ => "unknown",
    }
}

fn tcp_state_name(state: u8) -> &'static str {
    match state {
        1 => "ESTABLISHED",
        2 => "SYN_SENT",
        3 => "SYN_RECV",
        4 => "FIN_WAIT1",
        5 => "FIN_WAIT2",
        6 => "TIME_WAIT",
        7 => "CLOSE",
        8 => "CLOSE_WAIT",
        9 => "LAST_ACK",
        10 => "LISTEN",
        11 => "CLOSING",
        _ => "UNKNOWN",
    }
}

fn format_ipv4(addr: u32) -> String {
    let b = addr.to_be_bytes();
    format!("{}.{}.{}.{}", b[0], b[1], b[2], b[3])
}

// ---------------------------------------------------------------------------
// PID discovery
// ---------------------------------------------------------------------------

/// Scan /proc for a process named `bitcoind` and return its PID.
pub fn discover_bitcoind_pid(proc_root: &Path) -> Result<u32> {
    for entry in std::fs::read_dir(proc_root)
        .with_context(|| format!("reading {}", proc_root.display()))?
    {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        // Skip non-numeric entries
        let pid: u32 = match name_str.parse() {
            Ok(n) => n,
            Err(_) => continue,
        };

        let comm_path = entry.path().join("comm");
        if let Ok(comm) = std::fs::read_to_string(&comm_path) {
            if comm.trim() == "bitcoind" {
                return Ok(pid);
            }
        }
    }
    Err(anyhow!("bitcoind process not found in {}", proc_root.display()))
}

// ---------------------------------------------------------------------------
// JSON output helpers
// ---------------------------------------------------------------------------

/// Emit a single event as newline-delimited JSON to stdout.
///
/// When stdout is a pipe (Erlang **`Port`**), libc uses **block buffering**, so **`writeln!` alone**
/// can leave lines stuck until the buffer fills — the Elixir **`EbpfCollector`** would see no JSON.
pub fn emit_event(event: &OutputEvent) {
    if let Ok(json) = serde_json::to_string(event) {
        let stdout = io::stdout();
        let mut out = stdout.lock();
        let _ = writeln!(out, "{json}");
        let _ = out.flush();
    }
}

/// Kernel `SyscallEvent` stores an optional path payload after the fixed header (see `types.rs`).
fn parse_syscall_filename(item: &[u8]) -> String {
    if item.len() >= 280 {
        let raw = &item[24..280];
        let end = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
        String::from_utf8_lossy(&raw[..end]).to_string()
    } else {
        String::new()
    }
}

// ---------------------------------------------------------------------------
// Main — load eBPF programs and poll ring buffers
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let pid = match args.pid {
        Some(p) => p,
        None => discover_bitcoind_pid(Path::new("/proc"))
            .context("auto-detecting bitcoind PID")?,
    };

    eprintln!("node-probe-loader: attaching to PID {pid}");

    let ebpf_bytes = std::fs::read(&args.ebpf_obj)
        .with_context(|| format!("reading eBPF object {}", args.ebpf_obj.display()))?;

    load_and_run(pid, &ebpf_bytes, args.lite).await
}

async fn load_and_run(pid: u32, ebpf_bytes: &[u8], lite: bool) -> Result<()> {
    use aya::{
        maps::HashMap,
        programs::{KProbe, PerfEvent, TracePoint},
        Ebpf,
    };

    let mut bpf = Ebpf::load(ebpf_bytes)?;

    // Write bitcoind PID into the filter map
    {
        let mut filter: HashMap<_, u32, u32> =
            HashMap::try_from(bpf.map_mut("FILTER_PID").context("FILTER_PID map")?)?;
        filter.insert(0u32, pid, 0)?;
    }

    // Attach syscall tracepoints
    for (prog_name, category, name) in [
        ("sys_enter_openat", "syscalls", "sys_enter_openat"),
        ("sys_enter_read", "syscalls", "sys_enter_read"),
        ("sys_enter_write", "syscalls", "sys_enter_write"),
        ("sys_enter_fsync", "syscalls", "sys_enter_fsync"),
        ("sys_enter_fdatasync", "syscalls", "sys_enter_fdatasync"),
        ("sys_enter_connect", "syscalls", "sys_enter_connect"),
        ("sys_enter_sendto", "syscalls", "sys_enter_sendto"),
        ("sys_enter_recvfrom", "syscalls", "sys_enter_recvfrom"),
        ("sys_enter_clone", "syscalls", "sys_enter_clone"),
        ("sys_enter_execve", "syscalls", "sys_enter_execve"),
    ] {
        let prog: &mut TracePoint = bpf
            .program_mut(prog_name)
            .with_context(|| format!("program {prog_name}"))?
            .try_into()?;
        prog.load()?;
        prog.attach(category, name)?;
    }

    // Attach kprobes for latency
    for (prog_name, fn_name) in [
        ("vfs_read_entry", "vfs_read"),
        ("vfs_write_entry", "vfs_write"),
    ] {
        let prog: &mut KProbe = bpf
            .program_mut(prog_name)
            .with_context(|| format!("program {prog_name}"))?
            .try_into()?;
        prog.load()?;
        prog.attach(fn_name, 0)?;
    }
    for (prog_name, fn_name) in [
        ("vfs_read_exit", "vfs_read"),
        ("vfs_write_exit", "vfs_write"),
    ] {
        let prog: &mut KProbe = bpf
            .program_mut(prog_name)
            .with_context(|| format!("program {prog_name}"))?
            .try_into()?;
        prog.load()?;
        prog.attach(fn_name, 0)?;
    }

    // Attach network tracepoint
    {
        let prog: &mut TracePoint = bpf
            .program_mut("inet_sock_set_state")
            .context("inet_sock_set_state")?
            .try_into()?;
        prog.load()?;
        prog.attach("sock", "inet_sock_set_state")?;
    }

    // Optionally attach CPU sampler
    if !lite {
        let prog: &mut PerfEvent = bpf
            .program_mut("cpu_sampler")
            .context("cpu_sampler")?
            .try_into()?;
        prog.load()?;
        prog.attach(
            aya::programs::perf_event::PerfTypeId::Software,
            aya::programs::perf_event::perf_sw_ids::PERF_COUNT_SW_CPU_CLOCK as u64,
            aya::programs::perf_event::PerfEventScope::AllProcessesOneCpu { cpu: 0 },
            aya::programs::perf_event::SamplePolicy::Frequency(99),
            false,
        )?;
    }

    eprintln!("node-probe-loader: all probes attached, streaming events…");

    // Poll ring buffers
    use aya::maps::RingBuf;
    use tokio::signal;

    let _signal = signal::ctrl_c();

    // Fair round-robin: pop at most one event per ring per inner iteration so high syscall
    // volume cannot starve LATENCY_EVENTS / NET_EVENTS (previously we drained the entire
    // syscall ring before touching latency).
    loop {
        loop {
            let mut progressed = false;

            {
                let buf = {
                    let mut rb = RingBuf::try_from(
                        bpf.map_mut("SYSCALL_EVENTS")
                            .context("SYSCALL_EVENTS map")?,
                    )?;
                    rb.next().map(|item| item.as_ref().to_vec())
                };
                if let Some(item) = buf {
                    if item.len() >= 16 {
                        let pid_bytes: [u8; 4] = item[0..4].try_into().unwrap_or([0; 4]);
                        let nr_bytes: [u8; 4] = item[8..12].try_into().unwrap_or([0; 4]);
                        let ts_bytes: [u8; 8] = item[16..24].try_into().unwrap_or([0; 8]);
                        let syscall_pid = u32::from_ne_bytes(pid_bytes);
                        let syscall_nr = u32::from_ne_bytes(nr_bytes);
                        let ts = u64::from_ne_bytes(ts_bytes);
                        let filename = parse_syscall_filename(item.as_ref());
                        emit_event(&OutputEvent::Syscall {
                            pid: syscall_pid,
                            syscall: syscall_name(syscall_nr).to_string(),
                            ts,
                            filename,
                        });
                        progressed = true;
                    }
                }
            }
            {
                let buf = {
                    let mut rb = RingBuf::try_from(
                        bpf.map_mut("LATENCY_EVENTS")
                            .context("LATENCY_EVENTS map")?,
                    )?;
                    rb.next().map(|item| item.as_ref().to_vec())
                };
                if let Some(item) = buf {
                    if item.len() >= 24 {
                        let pid_bytes: [u8; 4] = item[0..4].try_into().unwrap_or([0; 4]);
                        let latency_bytes: [u8; 8] = item[8..16].try_into().unwrap_or([0; 8]);
                        let bytes_bytes: [u8; 8] = item[16..24].try_into().unwrap_or([0; 8]);
                        let op_byte = item[4];
                        let event_pid = u32::from_ne_bytes(pid_bytes);
                        let latency_ns = u64::from_ne_bytes(latency_bytes);
                        let bytes = u64::from_ne_bytes(bytes_bytes);
                        let op = match op_byte {
                            0 => "read",
                            1 => "write",
                            _ => "blk",
                        };
                        emit_event(&OutputEvent::Latency {
                            pid: event_pid,
                            op: op.to_string(),
                            latency_ns,
                            bytes,
                        });
                        progressed = true;
                    }
                }
            }
            {
                let buf = {
                    let mut rb =
                        RingBuf::try_from(bpf.map_mut("NET_EVENTS").context("NET_EVENTS map")?)?;
                    rb.next().map(|item| item.as_ref().to_vec())
                };
                if let Some(item) = buf {
                    if item.len() >= 28 {
                        let pid_bytes: [u8; 4] = item[0..4].try_into().unwrap_or([0; 4]);
                        let daddr_bytes: [u8; 4] = item[8..12].try_into().unwrap_or([0; 4]);
                        let dport_bytes: [u8; 2] = item[14..16].try_into().unwrap_or([0; 2]);
                        let new_state = item[17];
                        let ts_bytes: [u8; 8] = item[20..28].try_into().unwrap_or([0; 8]);
                        let event_pid = u32::from_ne_bytes(pid_bytes);
                        let daddr = u32::from_ne_bytes(daddr_bytes);
                        let dport = u16::from_ne_bytes(dport_bytes);
                        let ts = u64::from_ne_bytes(ts_bytes);
                        emit_event(&OutputEvent::Net {
                            pid: event_pid,
                            daddr: format_ipv4(daddr),
                            dport,
                            state_change: tcp_state_name(new_state).to_string(),
                            ts,
                        });
                        progressed = true;
                    }
                }
            }

            if !progressed {
                break;
            }
        }

        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    fn make_proc_dir(dir: &TempDir, pid: u32, comm: &str) -> std::path::PathBuf {
        let proc_pid = dir.path().join(pid.to_string());
        std::fs::create_dir_all(&proc_pid).unwrap();
        let mut f = std::fs::File::create(proc_pid.join("comm")).unwrap();
        writeln!(f, "{comm}").unwrap();
        dir.path().to_path_buf()
    }

    #[test]
    fn discovers_bitcoind_pid() {
        let dir = tempfile::tempdir().unwrap();
        make_proc_dir(&dir, 12345, "bitcoind");
        make_proc_dir(&dir, 99999, "bash");

        let pid = discover_bitcoind_pid(dir.path()).unwrap();
        assert_eq!(pid, 12345);
    }

    #[test]
    fn returns_error_when_bitcoind_not_found() {
        let dir = tempfile::tempdir().unwrap();
        make_proc_dir(&dir, 1, "systemd");
        make_proc_dir(&dir, 2, "kthreadd");

        assert!(discover_bitcoind_pid(dir.path()).is_err());
    }

    #[test]
    fn syscall_event_json_roundtrip() {
        let event = OutputEvent::Syscall {
            pid: 12345,
            syscall: "openat".to_string(),
            ts: 1_716_000_000_000_000_000,
            filename: String::new(),
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"type\":\"syscall\""));
        assert!(json.contains("\"pid\":12345"));
        assert!(json.contains("\"syscall\":\"openat\""));
        assert!(!json.contains("\"filename\""));
    }

    #[test]
    fn syscall_event_json_includes_nonempty_filename() {
        let event = OutputEvent::Syscall {
            pid: 1,
            syscall: "openat".to_string(),
            ts: 0,
            filename: "/var/lib/bitcoin/.bitcoin/blocks/foo.dat".to_string(),
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"filename\":\"/var/lib/bitcoin/.bitcoin/blocks/foo.dat\""));
    }

    #[test]
    fn parse_syscall_filename_reads_embedded_path() {
        let mut buf = vec![0u8; 280];
        buf[0..4].copy_from_slice(&12345u32.to_ne_bytes());
        buf[8..12].copy_from_slice(&257u32.to_ne_bytes());
        buf[16..24].copy_from_slice(&99u64.to_ne_bytes());
        let path = b"/blocks/blk000.dat";
        buf[24..24 + path.len()].copy_from_slice(path);
        assert_eq!(
            parse_syscall_filename(&buf),
            "/blocks/blk000.dat".to_string()
        );
    }

    #[test]
    fn latency_event_json_roundtrip() {
        let event = OutputEvent::Latency {
            pid: 12345,
            op: "read".to_string(),
            latency_ns: 842_000,
            bytes: 4096,
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"type\":\"latency\""));
        assert!(json.contains("\"latency_ns\":842000"));
    }

    #[test]
    fn net_event_json_roundtrip() {
        let event = OutputEvent::Net {
            pid: 12345,
            daddr: "192.168.1.10".to_string(),
            dport: 8333,
            state_change: "ESTABLISHED".to_string(),
            ts: 1_716_000_000_000_000_001,
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"type\":\"net\""));
        assert!(json.contains("\"dport\":8333"));
    }

    #[test]
    fn cpu_sample_event_json_roundtrip() {
        let event = OutputEvent::CpuSample {
            pid: 12345,
            stack_id: 7,
            ts: 1_716_000_000_000_000_002,
        };
        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"type\":\"cpu_sample\""));
        assert!(json.contains("\"stack_id\":7"));
    }

    #[test]
    fn format_ipv4_works() {
        // 192.168.1.10 in big-endian = 0xC0A8010A
        let addr = u32::from_be_bytes([192, 168, 1, 10]);
        assert_eq!(format_ipv4(addr), "192.168.1.10");
    }

    #[test]
    fn syscall_name_known_syscalls() {
        assert_eq!(syscall_name(0), "read");
        assert_eq!(syscall_name(1), "write");
        assert_eq!(syscall_name(257), "openat");
        assert_eq!(syscall_name(9999), "unknown");
    }

    #[test]
    fn tcp_state_names_known() {
        assert_eq!(tcp_state_name(1), "ESTABLISHED");
        assert_eq!(tcp_state_name(10), "LISTEN");
        assert_eq!(tcp_state_name(255), "UNKNOWN");
    }
}
