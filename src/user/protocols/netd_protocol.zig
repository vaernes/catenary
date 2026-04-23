/// netd DIPC protocol
///
/// Endpoint: ReservedEndpoint.netd (1)
///
/// netd owns the physical NIC and IPv6 stack.  Other services (and the kernel
/// virtio bridge) send it packets to transmit and route queries.
///
/// Message format:
///   PageHeader  (lib.DIPC_HEADER_SIZE bytes)
///   NetdHeader  (8 bytes)
///   payload     (op-specific, see below)
pub const MAGIC: u32 = 0x4E455444; // 'NETD'
pub const VERSION: u16 = 1;

pub const Op = enum(u16) {
    /// Transmit a raw IPv6 packet.
    /// Payload: TransmitPayload followed by the raw packet bytes.
    transmit = 1,

    /// Query the local IPv6 address assigned to the NIC.
    /// Payload: none.  Reply op: node_addr_reply.
    get_node_addr = 2,

    /// Reply to get_node_addr.
    /// Payload: NodeAddrReply.
    node_addr_reply = 3,

    /// Notify netd of a new route entry (e.g., from a cluster peer discovery).
    /// Payload: RouteUpdatePayload.
    route_update = 4,

    /// Request netd to forward an already-built DIPC frame to a remote node.
    /// Payload: ForwardPayload followed by the DIPC page bytes.
    forward_dipc = 5,
};

/// Header prepended to every netd DIPC message (after the PageHeader).
pub const NetdHeader = extern struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    op: Op,
};

// ---------------------------------------------------------------------------
// Per-op payloads
// ---------------------------------------------------------------------------

/// Op.transmit — send a raw Ethernet/IPv6 frame out the physical NIC.
/// The raw frame bytes follow immediately after this struct in the page.
pub const TransmitPayload = extern struct {
    /// Length of the raw frame (bytes), excluding this header.
    frame_len: u16,
    _pad: [6]u8 = [_]u8{0} ** 6,
};

/// Op.node_addr_reply — netd's response to a get_node_addr query.
pub const NodeAddrReply = extern struct {
    addr: [16]u8, // IPv6 address in network byte order
};

/// Op.route_update — insert or remove a route entry from netd's table.
pub const RouteUpdatePayload = extern struct {
    prefix: [16]u8, // IPv6 network prefix
    prefix_len: u8, // CIDR prefix length (0–128)
    action: u8, // 0 = remove, 1 = add
    _pad: [6]u8 = [_]u8{0} ** 6,
    next_hop: [16]u8, // IPv6 next-hop (or :: for on-link)
};

/// Op.forward_dipc — ask netd to send a DIPC page to a remote node's IPv6 addr.
/// The serialized DIPC page bytes follow immediately after this struct.
pub const ForwardPayload = extern struct {
    dst_node: [16]u8, // destination IPv6 node address
    page_len: u32, // length of the DIPC page that follows
    _pad: u32 = 0,
};
