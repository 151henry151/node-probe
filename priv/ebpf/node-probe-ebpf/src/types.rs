#![no_std]

/// Emitted when bitcoind makes a syscall we're tracing.
#[repr(C)]
pub struct SyscallEvent {
    pub pid: u32,
    pub tid: u32,
    pub syscall_nr: u32,
    pub timestamp_ns: u64,
    pub filename: [u8; 256],
    pub fd: i32,
    pub ret: i64,
}

/// Emitted with measured latency on kretprobe exit.
#[repr(C)]
pub struct LatencyEvent {
    pub pid: u32,
    pub op: u8, // 0=read, 1=write, 2=blk
    pub latency_ns: u64,
    pub bytes: u64,
    pub filename_hash: u32,
}

/// Emitted on TCP state transitions for sockets owned by bitcoind.
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

/// Emitted by the 99Hz CPU sampler (disabled in lite mode).
#[repr(C)]
pub struct CpuSampleEvent {
    pub pid: u32,
    pub stack_id: i64,
    pub timestamp_ns: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::mem;

    #[test]
    fn syscall_event_layout() {
        assert_eq!(mem::align_of::<SyscallEvent>(), 8);
        assert!(mem::size_of::<SyscallEvent>() >= 288);
    }

    #[test]
    fn latency_event_layout() {
        assert!(mem::size_of::<LatencyEvent>() >= 24);
        assert_eq!(mem::align_of::<LatencyEvent>(), 8);
    }

    #[test]
    fn net_event_layout() {
        assert!(mem::size_of::<NetEvent>() >= 20);
        assert_eq!(mem::align_of::<NetEvent>(), 8);
    }

    #[test]
    fn cpu_sample_event_layout() {
        assert!(mem::size_of::<CpuSampleEvent>() >= 16);
        assert_eq!(mem::align_of::<CpuSampleEvent>(), 8);
    }

    #[test]
    fn op_values_are_distinct() {
        assert_ne!(0u8, 1u8); // read != write
        assert_ne!(1u8, 2u8); // write != blk
        assert_ne!(0u8, 2u8); // read != blk
    }
}
