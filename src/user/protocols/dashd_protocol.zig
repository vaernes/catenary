/// dashd DIPC protocol
///
/// Endpoint: ReservedEndpoint.dashd (5)
///
/// dashd is the observability daemon.  It receives telemetry from the kernel
/// VMM bridge (microvm_bridge) and exposes aggregated stats to windowd on
/// demand.  It does not initiate any outbound messages.
///
/// Message format:
///   PageHeader         (lib.DIPC_HEADER_SIZE bytes)
///   TelemetryUpdate    (sent by the VMM bridge after each vmexit burst)
pub const MAGIC: u32 = 0x44415348; // 'DASH'
pub const VERSION: u16 = 1;

// ---------------------------------------------------------------------------
// Messages sent TO dashd
// ---------------------------------------------------------------------------

/// Per-VM telemetry snapshot pushed by microvm_bridge after each scheduling
/// quantum ends.  dashd accumulates these and merges into its stats table.
pub const TelemetryUpdate = extern struct {
    /// MicroVM instance ID.
    instance_id: u32,
    _reserved: u32 = 0,
    /// Cumulative guest TSC cycles consumed since boot.
    cpu_cycles: u64,
    /// Cumulative number of VM-exits since boot.
    exit_count: u64,
};

// ---------------------------------------------------------------------------
// Messages sent FROM dashd (replies)
// ---------------------------------------------------------------------------

/// Per-VM stats summary — returned when another service queries dashd
/// (currently polled by windowd indirectly via kernel list_microvms).
/// Not yet used; defined here as the intended future reply type.
pub const VmStatsSummary = extern struct {
    instance_id: u32,
    _pad: u32 = 0,
    cpu_cycles: u64,
    exit_count: u64,
};
