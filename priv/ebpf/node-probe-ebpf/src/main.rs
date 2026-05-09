#![no_std]
#![no_main]

mod types;
use types::{CpuSampleEvent, LatencyEvent, NetEvent, SyscallEvent};

use aya_ebpf::{
    helpers::{bpf_get_current_pid_tgid, bpf_ktime_get_ns, bpf_probe_read_user_str_bytes},
    macros::{kprobe, kretprobe, map, perf_event, tracepoint},
    maps::{HashMap, RingBuf},
    programs::{PerfEventContext, ProbeContext, RetProbeContext, TracePointContext},
};

// ---------------------------------------------------------------------------
// BPF maps
// ---------------------------------------------------------------------------

/// PID filter — userspace writes bitcoind PID here (key 0).
#[map]
static FILTER_PID: HashMap<u32, u32> = HashMap::with_max_entries(1, 0);

/// Ring buffer for syscall events.
#[map]
static SYSCALL_EVENTS: RingBuf = RingBuf::with_byte_size(1 << 22, 0);

/// Ring buffer for latency events.
#[map]
static LATENCY_EVENTS: RingBuf = RingBuf::with_byte_size(1 << 22, 0);

/// Ring buffer for network events.
#[map]
static NET_EVENTS: RingBuf = RingBuf::with_byte_size(1 << 22, 0);

/// Ring buffer for CPU sample events.
#[map]
static CPU_EVENTS: RingBuf = RingBuf::with_byte_size(1 << 22, 0);

/// Per-TID kprobe entry timestamps for latency tracking.
#[map]
static LATENCY_START: HashMap<u32, u64> = HashMap::with_max_entries(65536, 0);

// ---------------------------------------------------------------------------
// Helper: check if current PID matches bitcoind filter
// ---------------------------------------------------------------------------

#[inline(always)]
fn is_target_pid() -> bool {
    let tgid = (bpf_get_current_pid_tgid() >> 32) as u32;
    matches!(unsafe { FILTER_PID.get(&0) }, Some(&pid) if pid == tgid)
}

// ---------------------------------------------------------------------------
// a) Syscall tracer
// ---------------------------------------------------------------------------

macro_rules! syscall_probe {
    ($name:ident, $nr:expr) => {
        #[tracepoint]
        pub fn $name(_ctx: TracePointContext) -> u32 {
            if !is_target_pid() {
                return 0;
            }
            let pid_tgid = bpf_get_current_pid_tgid();
            let pid = (pid_tgid >> 32) as u32;
            let tid = pid_tgid as u32;

            if let Some(mut event) = SYSCALL_EVENTS.reserve::<SyscallEvent>(0) {
                let e = unsafe { event.as_mut_ptr().as_mut().unwrap() };
                e.pid = pid;
                e.tid = tid;
                e.syscall_nr = $nr;
                e.timestamp_ns = unsafe { bpf_ktime_get_ns() };
                e.fd = 0;
                e.ret = 0;
                event.submit(0);
            }
            0
        }
    };
}

/// `sys_enter_openat` — copy pathname from tracepoint args (see `.../sys_enter_openat/format`, `filename` at offset 24).
#[tracepoint]
pub fn sys_enter_openat(ctx: TracePointContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }
    let pid_tgid = bpf_get_current_pid_tgid();
    let pid = (pid_tgid >> 32) as u32;
    let tid = pid_tgid as u32;

    if let Some(mut event) = SYSCALL_EVENTS.reserve::<SyscallEvent>(0) {
        let e = unsafe { event.as_mut_ptr().as_mut().unwrap() };
        e.pid = pid;
        e.tid = tid;
        e.syscall_nr = 257;
        e.timestamp_ns = unsafe { bpf_ktime_get_ns() };
        e.fd = 0;
        e.ret = 0;
        e.filename = [0u8; 256];

        let user_ptr = unsafe { ctx.read_at::<u64>(24).unwrap_or(0) };
        if user_ptr != 0 {
            let src = user_ptr as *const u8;
            let _ = unsafe { bpf_probe_read_user_str_bytes(src, &mut e.filename) };
        }
        event.submit(0);
    }
    0
}

syscall_probe!(sys_enter_read, 0);
syscall_probe!(sys_enter_write, 1);
syscall_probe!(sys_enter_fsync, 74);
syscall_probe!(sys_enter_fdatasync, 75);
syscall_probe!(sys_enter_connect, 42);
syscall_probe!(sys_enter_sendto, 44);
syscall_probe!(sys_enter_recvfrom, 45);
syscall_probe!(sys_enter_clone, 56);
syscall_probe!(sys_enter_execve, 59);

// ---------------------------------------------------------------------------
// b) Latency probes — vfs_read / vfs_write
// ---------------------------------------------------------------------------

#[kprobe]
pub fn vfs_read_entry(_ctx: ProbeContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }
    let tid = bpf_get_current_pid_tgid() as u32;
    let ts = unsafe { bpf_ktime_get_ns() };
    unsafe { LATENCY_START.insert(&tid, &ts, 0).ok() };
    0
}

#[kretprobe]
pub fn vfs_read_exit(ctx: RetProbeContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }
    let tid = bpf_get_current_pid_tgid() as u32;
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;
    let now = unsafe { bpf_ktime_get_ns() };

    if let Some(&start) = unsafe { LATENCY_START.get(&tid) } {
        let _ = unsafe { LATENCY_START.remove(&tid) };
        if let Some(mut event) = LATENCY_EVENTS.reserve::<LatencyEvent>(0) {
            let e = unsafe { event.as_mut_ptr().as_mut().unwrap() };
            e.pid = pid;
            e.op = 0;
            e.latency_ns = now.saturating_sub(start);
            e.bytes = ctx.ret().unwrap_or(0) as u64;
            e.filename_hash = 0;
            event.submit(0);
        }
    }
    0
}

#[kprobe]
pub fn vfs_write_entry(_ctx: ProbeContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }
    let tid = bpf_get_current_pid_tgid() as u32;
    let ts = unsafe { bpf_ktime_get_ns() };
    unsafe { LATENCY_START.insert(&tid, &ts, 0).ok() };
    0
}

#[kretprobe]
pub fn vfs_write_exit(ctx: RetProbeContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }
    let tid = bpf_get_current_pid_tgid() as u32;
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;
    let now = unsafe { bpf_ktime_get_ns() };

    if let Some(&start) = unsafe { LATENCY_START.get(&tid) } {
        let _ = unsafe { LATENCY_START.remove(&tid) };
        if let Some(mut event) = LATENCY_EVENTS.reserve::<LatencyEvent>(0) {
            let e = unsafe { event.as_mut_ptr().as_mut().unwrap() };
            e.pid = pid;
            e.op = 1;
            e.latency_ns = now.saturating_sub(start);
            e.bytes = ctx.ret().unwrap_or(0) as u64;
            e.filename_hash = 0;
            event.submit(0);
        }
    }
    0
}

// ---------------------------------------------------------------------------
// c) Network probe — TCP state transitions
// ---------------------------------------------------------------------------

#[tracepoint]
pub fn inet_sock_set_state(ctx: TracePointContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }

    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;

    // Tracepoint args layout for inet_sock_set_state:
    // offset 40: oldstate (int), offset 44: newstate (int)
    // offset 28: saddr, offset 32: daddr, offset 36: sport, offset 38: dport
    let old_state: u32 = unsafe { ctx.read_at(40).unwrap_or(0) };
    let new_state: u32 = unsafe { ctx.read_at(44).unwrap_or(0) };
    let saddr: u32 = unsafe { ctx.read_at(28).unwrap_or(0) };
    let daddr: u32 = unsafe { ctx.read_at(32).unwrap_or(0) };
    let sport: u16 = unsafe { ctx.read_at(36).unwrap_or(0) };
    let dport: u16 = unsafe { ctx.read_at(38).unwrap_or(0) };

    if let Some(mut event) = NET_EVENTS.reserve::<NetEvent>(0) {
        let e = unsafe { event.as_mut_ptr().as_mut().unwrap() };
        e.pid = pid;
        e.saddr = saddr;
        e.daddr = daddr;
        e.sport = sport;
        e.dport = dport;
        e.old_state = old_state as u8;
        e.new_state = new_state as u8;
        e.timestamp_ns = unsafe { bpf_ktime_get_ns() };
        event.submit(0);
    }
    0
}

// ---------------------------------------------------------------------------
// d) CPU sampler — perf_event (disabled in lite mode at load time)
// ---------------------------------------------------------------------------

#[perf_event]
pub fn cpu_sampler(_ctx: PerfEventContext) -> u32 {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;

    if !matches!(unsafe { FILTER_PID.get(&0) }, Some(&target) if target == pid) {
        return 0;
    }

    if let Some(mut event) = CPU_EVENTS.reserve::<CpuSampleEvent>(0) {
        let e = unsafe { event.as_mut_ptr().as_mut().unwrap() };
        e.pid = pid;
        e.stack_id = 0;
        e.timestamp_ns = unsafe { bpf_ktime_get_ns() };
        event.submit(0);
    }
    0
}

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}
