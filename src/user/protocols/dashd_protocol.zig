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

pub const Op = enum(u16) {
    /// Request a telemetry summary snapshot from dashd.
    /// Payload: TelemetrySummaryRequest. Reply op: telemetry_summary_reply.
    telemetry_summary_request = 1,

    /// Reply to telemetry_summary_request.
    /// Payload: TelemetrySummaryReply.
    telemetry_summary_reply = 2,

    /// Forwarded cross-node telemetry sample.
    /// Payload: ClusterTelemetryUpdate.
    cluster_telemetry_update = 3,
};

pub const DashdHeader = extern struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    op: Op,
    payload_len: u32,
    _pad: u32 = 0,
};

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

pub const ClusterTelemetryUpdate = extern struct {
    sample_tsc: u64,
    node_addr: [16]u8,
    instance_id: u32,
    _reserved: u32 = 0,
    cpu_cycles: u64,
    exit_count: u64,
};

pub const TelemetrySummaryRequest = extern struct {
    flags: u32 = 0,
    _pad: u32 = 0,
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

pub const TelemetrySummaryEntry = extern struct {
    node_addr: [16]u8,
    instance_id: u32,
    _pad: u32 = 0,
    cpu_cycles: u64,
    exit_count: u64,
};

pub const MAX_TELEMETRY_SUMMARY_ENTRIES: usize = 32;

pub const TelemetrySummaryReply = extern struct {
    count: u32,
    _pad: u32 = 0,
    entries: [MAX_TELEMETRY_SUMMARY_ENTRIES]TelemetrySummaryEntry = [_]TelemetrySummaryEntry{.{
        .node_addr = [_]u8{0} ** 16,
        .instance_id = 0,
        .cpu_cycles = 0,
        .exit_count = 0,
    }} ** MAX_TELEMETRY_SUMMARY_ENTRIES,
};
