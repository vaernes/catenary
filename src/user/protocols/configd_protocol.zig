/// configd DIPC protocol
///
/// Endpoint: ReservedEndpoint.configd (10)
///
/// configd maintains the cluster node registry and surfaces it through a
/// text-mode console UI.  It receives:
///   - registry_sync from the kernel router whenever a node is discovered
///   - (future) heartbeat messages from netd / remote configd peers
///
/// It sends:
///   - create_microvm to kernel_control (via lib.ControlOp) on user request
///
/// The inbound service-to-service messages that configd handles are defined
/// below.  Kernel-control messages use lib.ControlHeader + lib.ControlOp.
///
/// Message format (inbound registry_sync):
///   PageHeader          (lib.DIPC_HEADER_SIZE bytes)
///   lib.ControlHeader   (op = .registry_sync)
///   RegistrySyncPayload
pub const MAGIC: u32 = 0x434F4E46; // 'CONF'
pub const VERSION: u16 = 1;

// ---------------------------------------------------------------------------
// registry_sync payload (shared with the router and clusterd)
// ---------------------------------------------------------------------------

/// Service state flags embedded in RegistrySyncPayload.state.
pub const ServiceState = enum(u8) {
    /// Service has registered and is running.
    up = 1,
    /// Service has stopped or timed out.
    down = 0,
};

/// Payload carried by kernel ControlOp.registry_sync messages.
/// This is the canonical definition; lib.RegistrySyncPayload mirrors it.
pub const RegistrySyncPayload = extern struct {
    service_id: u32,
    service_kind: u16,
    state: u8,
    _pad: u8 = 0,
};

// ---------------------------------------------------------------------------
// Future direct configd→configd ops (not yet used in the service loop)
// ---------------------------------------------------------------------------

pub const Op = enum(u16) {
    /// Notify a peer configd that a new node has joined the cluster.
    /// Payload: NodeJoinPayload.
    node_joined = 1,

    /// Notify a peer configd that a node has left the cluster.
    /// Payload: NodeLeavePayload.
    node_left = 2,

    /// Propagate a config key/value update to all cluster nodes.
    /// Payload: ConfigUpdatePayload.
    config_update = 3,
};

pub const ConfigdHeader = extern struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    op: Op,
    payload_len: u32,
    _pad: u32 = 0,
};

/// Op.node_joined — a new node has been discovered.
pub const NodeJoinPayload = extern struct {
    /// IPv6 address of the newly-joined node.
    node_addr: [16]u8,
    /// Bitmask of services running on that node (bit i = ServiceKind(i)).
    service_mask: u16,
    _pad: [6]u8 = [_]u8{0} ** 6,
};

/// Op.node_left — a previously-seen node has gone away.
pub const NodeLeavePayload = extern struct {
    node_addr: [16]u8,
    reason: u8, // 0 = timeout, 1 = graceful shutdown
    _pad: [7]u8 = [_]u8{0} ** 7,
};

/// Op.config_update — a key/value pair update to be propagated cluster-wide.
pub const ConfigUpdatePayload = extern struct {
    key: [32]u8,
    value: [64]u8,
};
