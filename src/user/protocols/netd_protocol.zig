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

    /// Announce a discovered peer and its transport-relevant properties.
    /// Payload: PeerAnnouncementPayload.
    peer_announce = 6,

    /// Request a snapshot of the currently known peer table.
    /// Payload: PeerSnapshotRequest. Reply op: peer_snapshot_reply.
    peer_snapshot_request = 7,

    /// Reply to peer_snapshot_request.
    /// Payload: PeerSnapshotReply.
    peer_snapshot_reply = 8,

    /// Request netd to start listening for TCP connections on a port.
    /// Payload: TcpListenPayload. Reply op: tcp_listen_ack.
    tcp_listen = 9,

    /// Acknowledge a tcp_listen request.
    /// Payload: TcpListenAckPayload.
    tcp_listen_ack = 10,

    /// Initiate an active TCP connection to a remote IPv6 node/port.
    /// Payload: TcpConnectPayload. Reply op: tcp_connect_ack.
    tcp_connect = 11,

    /// Acknowledge an active TCP connection attempt.
    /// Payload: TcpConnectAckPayload.
    tcp_connect_ack = 12,

    /// Transmit TCP data on an established connection.
    /// Payload: TcpSendPayload followed by data bytes.
    tcp_send = 13,

    /// Receive TCP data delivered from netd to the owning endpoint.
    /// Payload: TcpRecvPayload followed by data bytes.
    tcp_recv = 14,

    /// Request closing of a TCP socket.
    /// Payload: TcpClosePayload.
    tcp_close = 15,

    /// Notification that a TCP socket was closed by peer or teardown completed.
    /// Payload: TcpClosedPayload.
    tcp_closed = 16,

    /// Query TCP socket status.
    /// Payload: TcpStatusPayload. Reply op: tcp_status_reply.
    tcp_status = 17,

    /// Reply with TCP socket status.
    /// Payload: TcpStatusReplyPayload.
    tcp_status_reply = 18,
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

pub const PEER_FLAG_LINK_LOCAL_ONLY: u16 = 1 << 0;
pub const PEER_FLAG_TRUSTED: u16 = 1 << 1;
pub const PEER_FLAG_ROUTE_DIRECT: u16 = 1 << 2;
pub const PEER_FLAG_HAS_NETD: u16 = 1 << 3;

/// Op.peer_announce — advertise a discovered cluster peer.
pub const PeerAnnouncementPayload = extern struct {
    node_addr: [16]u8,
    service_mask: u32,
    mtu: u16,
    flags: u16,
    mac: [6]u8,
    _pad: [2]u8 = [_]u8{0} ** 2,
};

pub const PeerSnapshotRequest = extern struct {
    flags: u32 = 0,
    _pad: u32 = 0,
};

pub const PeerSnapshotEntry = extern struct {
    node_addr: [16]u8,
    service_mask: u32,
    mtu: u16,
    flags: u16,
    mac: [6]u8,
    _pad: [2]u8 = [_]u8{0} ** 2,
};

pub const MAX_PEER_SNAPSHOT_ENTRIES: usize = 16;

pub const PeerSnapshotReply = extern struct {
    count: u32,
    _pad: u32 = 0,
    entries: [MAX_PEER_SNAPSHOT_ENTRIES]PeerSnapshotEntry = [_]PeerSnapshotEntry{.{
        .node_addr = [_]u8{0} ** 16,
        .service_mask = 0,
        .mtu = 0,
        .flags = 0,
        .mac = [_]u8{0} ** 6,
    }} ** MAX_PEER_SNAPSHOT_ENTRIES,
};

// ---------------------------------------------------------------------------
// TCP socket management (ops: tcp_listen through tcp_status_reply)
// ---------------------------------------------------------------------------

/// Op.tcp_listen — request netd to start listening for TCP connections on a port.
pub const TcpListenPayload = extern struct {
    port: u16,
    _pad: u16 = 0,
    backlog: u32 = 4,
};

/// Backward-compatible alias for TcpListenPayload.
pub const TcpListenRequest = extern struct {
    port: u16,
    _pad: u16 = 0,
    notify_endpoint: u64 = 0,
};

/// Op.tcp_listen_ack — acknowledgement from netd for a tcp_listen request.
pub const TcpListenAckPayload = extern struct {
    port: u16,
    status: u16, // 0 = ok, 1 = error/in-use, 2 = no capacity
    socket_id: u32,
};

/// Backward-compatible alias for TcpListenAckPayload.
pub const TcpListenAck = extern struct {
    port: u16,
    status: u8,
    _pad: u8 = 0,
};

/// Op.tcp_connect — request netd to establish a TCP connection to a remote IPv6 peer.
pub const TcpConnectPayload = extern struct {
    remote_ip: [16]u8,
    remote_port: u16,
    local_port: u16 = 0, // 0 = auto ephemeral
};

/// Op.tcp_connect_ack — response to a tcp_connect request.
pub const TcpConnectAckPayload = extern struct {
    socket_id: u32,
    status: u16, // 0 = success, 1 = refused, 2 = timeout
    local_port: u16,
};

/// Op.tcp_send — transmit TCP payload data over an established connection.
/// The raw payload bytes follow immediately after this struct in the page.
pub const TcpSendPayload = extern struct {
    socket_id: u32,
    data_len: u16,
    _pad: u16 = 0,
};

/// Op.tcp_recv — received TCP data delivered to the socket owner.
/// The raw payload bytes follow immediately after this struct in the page.
pub const TcpRecvPayload = extern struct {
    socket_id: u32,
    data_len: u16,
    _pad: u16 = 0,
};

/// Op.tcp_close — request graceful or immediate teardown of a TCP socket.
pub const TcpClosePayload = extern struct {
    socket_id: u32,
};

/// Op.tcp_closed — notification that a TCP connection is closed.
pub const TcpClosedPayload = extern struct {
    socket_id: u32,
    reason: u16, // 0 = clean FIN close, 1 = RST, 2 = timeout
    _pad: u16 = 0,
};

/// Op.tcp_status — query the state of a TCP socket.
pub const TcpStatusPayload = extern struct {
    socket_id: u32,
};

/// Op.tcp_status_reply — status reply for a TCP socket.
pub const TcpStatusReplyPayload = extern struct {
    socket_id: u32,
    state: u8,
    _pad: [3]u8 = [_]u8{0} ** 3,
    local_port: u16,
    remote_port: u16,
    remote_ip: [16]u8 = [_]u8{0} ** 16,
    rx_buffered: u32 = 0,
};

