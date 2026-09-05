/// netd — physical NIC driver (legacy virtio-net PCI) + minimal IPv6 stack.
///
/// Syscall ABI used here: rax=op, rbx=arg0, rdx=arg1, r8=token.
/// This matches the kernel's lib.syscallIsr bridge exactly.
const std = @import("std");
const lib = @import("lib.zig");
const netd_proto = @import("protocols/netd_protocol.zig");
const tcp = @import("protocols/tcp.zig");

// ---------------------------------------------------------------------------
// Low-level I/O helpers
// ---------------------------------------------------------------------------

const SYS_PORT_IN = lib.SYS_PORT_IN;
const SYS_PORT_OUT = lib.SYS_PORT_OUT;

fn outb(port: u16, val: u8) void {
    _ = lib.syscall(SYS_PORT_OUT, port, (@as(u64, 1) << 32) | val, g_token);
}

fn outw(port: u16, val: u16) void {
    _ = lib.syscall(SYS_PORT_OUT, port, (@as(u64, 2) << 32) | val, g_token);
}
fn outl(port: u16, val: u32) void {
    _ = lib.syscall(SYS_PORT_OUT, port, (@as(u64, 4) << 32) | val, g_token);
}
fn inb(port: u16) u8 {
    return @as(u8, @truncate(lib.syscall(SYS_PORT_IN, port, (@as(u64, 1) << 32), g_token)));
}
fn inw(port: u16) u16 {
    return @as(u16, @truncate(lib.syscall(SYS_PORT_IN, port, (@as(u64, 2) << 32), g_token)));
}
fn inl(port: u16) u32 {
    return @as(u32, @truncate(lib.syscall(SYS_PORT_IN, port, (@as(u64, 4) << 32), g_token)));
}

fn serialByte(c: u8) void {
    _ = lib.syscall(lib.SYS_SERIAL_WRITE, @intFromPtr(&c), 1, 0);
}

fn hexDigit(nibble: u8) u8 {
    return "0123456789ABCDEF"[nibble & 0x0F];
}

fn writeMacAddressLine(mac: *const [6]u8) void {
    var line: [18]u8 = undefined;
    for (mac, 0..) |b, i| {
        const base = i * 3;
        line[base] = hexDigit(@as(u8, @truncate(b >> 4)));
        line[base + 1] = hexDigit(b);
        line[base + 2] = if (i == mac.len - 1) '\n' else ':';
    }
    lib.serialWrite(line[0..]);
}

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var buf: [16]u8 = undefined;
    var shift: u6 = 60;
    var idx: usize = 0;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        buf[idx] = hex[nibble];
        idx += 1;
        if (shift == 0) break;
        shift -= 4;
    }
    _ = lib.syscall(lib.SYS_SERIAL_WRITE, @intFromPtr(&buf), 16, g_token);
}

fn printDec(n: u64) void {
    if (n == 0) {
        const c: u8 = '0';
        _ = lib.syscall(lib.SYS_SERIAL_WRITE, @intFromPtr(&c), 1, 0);
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        buf[len] = @as(u8, @truncate(v % 10)) + '0';
        len += 1;
    }
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        const c = buf[i];
        _ = lib.syscall(lib.SYS_SERIAL_WRITE, @intFromPtr(&c), 1, 0);
    }
}

// ---------------------------------------------------------------------------
// Syscall interface — all constants from lib.zig (which re-exports syscall_abi)
// ---------------------------------------------------------------------------

const SYS_REGISTER = lib.SYS_REGISTER;
const SYS_RECV = lib.SYS_RECV;
const SYS_FREE_PAGE = lib.SYS_FREE_PAGE;
const SYS_ALLOC_DMA = lib.SYS_ALLOC_DMA;
const SYS_SEND_PAGE = lib.SYS_SEND_PAGE;
const SYS_MAP_RECV = lib.SYS_MAP_RECV;
const SYS_YIELD = lib.SYS_YIELD;

const DIPC_RECV_VA: u64 = lib.DIPC_RECV_VA;
const DMA_BASE_VA: u64 = lib.DMA_BASE_VA;
const PAGE_SIZE: u64 = lib.PAGE_SIZE;
const CONTROL_OUTBOX_VA: u64 = DMA_BASE_VA + 10 * PAGE_SIZE;
const DEFAULT_LINK_MTU: u16 = 1500;
const NETD_ENDPOINT: u64 = @intFromEnum(lib.ReservedEndpoint.netd);
const NETD_SERVICE_MASK: u32 = @as(u32, 1) << @as(u5, @intCast(@intFromEnum(lib.ServiceKind.netd)));

var g_wire_frame_buf: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
var g_icmp_frame_buf: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;

// PCI config read via kernel syscall
fn pciRead(bus: u8, dev: u8, func: u8, off: u8, size: u8, token: u64) u64 {
    const addr = (@as(u64, bus) << 24) | (@as(u64, dev) << 16) | (@as(u64, func) << 8) | @as(u64, off);
    return lib.syscall(lib.SYS_PCI_READ_CONFIG, addr, (@as(u64, size) << 32), token);
}
fn pciWrite(bus: u8, dev: u8, func: u8, off: u8, size: u8, val: u32, token: u64) void {
    const addr = (@as(u64, bus) << 24) | (@as(u64, dev) << 16) | (@as(u64, func) << 8) | @as(u64, off);
    _ = lib.syscall(lib.SYS_PCI_WRITE_CONFIG, addr, (@as(u64, size) << 32) | val, token);
}

// ---------------------------------------------------------------------------
// Bootstrap descriptor (matches kernel's service_bootstrap.Descriptor)
// ---------------------------------------------------------------------------

const BootstrapDescriptor = lib.BootstrapDescriptor;

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;

// ---------------------------------------------------------------------------
// Virtio-net legacy (PCI DID 0x1000) constants
// ---------------------------------------------------------------------------

// Legacy virtio PCI IO BAR register offsets
const VIRTIO_PCI_HOST_FEATURES: u16 = 0x00; // 4: device features (read-only to driver)
const VIRTIO_PCI_GUEST_FEATURES: u16 = 0x04; // 4: driver features (write)
const VIRTIO_PCI_QUEUE_ADDR: u16 = 0x08; // 4: queue address >> 12 (write)
const VIRTIO_PCI_QUEUE_SIZE: u16 = 0x0C; // 2: negotiated queue size (read)
const VIRTIO_PCI_QUEUE_SEL: u16 = 0x0E; // 2: queue select (write)
const VIRTIO_PCI_QUEUE_NOTIFY: u16 = 0x10; // 2: queue notify (write)
const VIRTIO_PCI_STATUS: u16 = 0x12; // 1: device status (write)
const VIRTIO_PCI_ISR: u16 = 0x13; // 1: ISR status (read, clear-on-read)
const VIRTIO_PCI_CONFIG: u16 = 0x14; // +: device config (MAC addr etc.)

const VIRTIO_NET_MAC_OFFSET: u16 = VIRTIO_PCI_CONFIG + 0; // 6 bytes

const STATUS_ACKNOWLEDGE: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;

// Virtqueue descriptor flags
const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;

// Virtio-net header (legacy, 10 bytes without num_buffers)
const VirtioNetHdr = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
};

const VIRTIO_NET_HDR_SIZE: usize = @sizeOf(VirtioNetHdr); // 10

// Virtqueue entry sizes for the legacy QEMU default queue size.
const QUEUE_SIZE: u16 = 256;
const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]u16,
};
const VirtqUsedElem = extern struct { id: u32, len: u32 };
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]VirtqUsedElem,
};

// DMA layout (window slots, contiguous per allocation):
// Slot 0-2: RX ring (3 pages for a 256-entry legacy split ring)
// Slot 3-5: TX ring
// Slot 6-7: RX frame buffers (2 pages = 8 × 1024-byte buffers)
// Slot 8:   TX frame buffer
// Slot 9:   DIPC routing scratch page
// Slot 10:  netd control outbox page
// Slot 11:  RX poller stack page
const RX_DESC_VA: u64 = DMA_BASE_VA + 0 * PAGE_SIZE;
const RX_AVAIL_VA: u64 = DMA_BASE_VA + 0 * PAGE_SIZE + @sizeOf([QUEUE_SIZE]VirtqDesc);
const RX_USED_VA: u64 = DMA_BASE_VA + 2 * PAGE_SIZE;
const TX_DESC_VA: u64 = DMA_BASE_VA + 3 * PAGE_SIZE;
const TX_AVAIL_VA: u64 = DMA_BASE_VA + 3 * PAGE_SIZE + @sizeOf([QUEUE_SIZE]VirtqDesc);
const TX_USED_VA: u64 = DMA_BASE_VA + 5 * PAGE_SIZE;
const RXBUF_VA: u64 = DMA_BASE_VA + 6 * PAGE_SIZE;
const TXBUF_VA: u64 = DMA_BASE_VA + 8 * PAGE_SIZE;
const DIPC_SCRATCH_VA: u64 = DMA_BASE_VA + 9 * PAGE_SIZE;
const RX_BUF_SIZE: u32 = 1024; // per RX descriptor buffer
const NUM_RX_BUFS: u16 = 8; // pre-populated RX descriptors

// DIPC wire magic (must match kernel dipc.zig)
const DIPC_WIRE_MAGIC: u32 = lib.WireMagic;
const DIPC_WIRE_VERSION: u16 = lib.WireVersion;
const DIPC_HEADER_SIZE: usize = lib.DIPC_HEADER_SIZE;
const DIPC_UDP_PORT: u16 = 0x4450; // 'DP' – custom port for DIPC-over-UDP
const IPV6_ALL_NODES_MULTICAST: [16]u8 = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

// State globals
var g_io_base: u16 = 0;
var g_our_mac: [6]u8 = [_]u8{0} ** 6;
var g_our_ipv6: [16]u8 = [_]u8{0} ** 16;
var g_rx_last_used: u16 = 0;
var g_tx_last_used: u16 = 0;
var g_tx_avail_idx: u16 = 0;
var g_rx_ring_phys: u64 = 0;
var g_tx_ring_phys: u64 = 0;
var g_rxbuf_phys: u64 = 0;
var g_txbuf_phys: u64 = 0;
var g_dipc_scratch_phys: u64 = 0;
var g_control_outbox_phys: u64 = 0;
var g_kernel_control_endpoint: u64 = 0;

// IPv6 Neighbor Cache — maps IPv6 address → Ethernet MAC.
const NEIGHBOR_CACHE_SIZE: usize = 32;
const NeighborEntry = struct {
    valid: bool = false,
    ipv6: [16]u8 = [_]u8{0} ** 16,
    mac: [6]u8 = [_]u8{0} ** 6,
};
var g_neighbor_cache: [NEIGHBOR_CACHE_SIZE]NeighborEntry = [_]NeighborEntry{.{}} ** NEIGHBOR_CACHE_SIZE;
var g_neighbor_evict: usize = 0; // round-robin eviction index

const PEER_TABLE_SIZE: usize = netd_proto.MAX_PEER_SNAPSHOT_ENTRIES;
const PeerEntry = struct {
    valid: bool = false,
    node_addr: [16]u8 = [_]u8{0} ** 16,
    service_mask: u32 = 0,
    mtu: u16 = 0,
    flags: u16 = 0,
    mac: [6]u8 = [_]u8{0} ** 6,
    next_hop: [16]u8 = [_]u8{0} ** 16,
};

var g_peer_table: [PEER_TABLE_SIZE]PeerEntry = [_]PeerEntry{.{}} ** PEER_TABLE_SIZE;
var g_peer_evict: usize = 0;

fn ipv6Eq(a: *const [16]u8, b: *const [16]u8) bool {
    for (0..16) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn isUnspecifiedIpv6(addr: *const [16]u8) bool {
    for (addr) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn isLoopbackIpv6(addr: *const [16]u8) bool {
    for (addr[0..15]) |byte| {
        if (byte != 0) return false;
    }
    return addr[15] == 1;
}

fn isLinkLocalIpv6(addr: *const [16]u8) bool {
    return addr[0] == 0xFE and (addr[1] & 0xC0) == 0x80;
}

fn isLocalNode(addr: *const [16]u8) bool {
    return ipv6Eq(addr, &g_our_ipv6) or isLoopbackIpv6(addr) or isUnspecifiedIpv6(addr);
}

fn isZeroMac(mac: *const [6]u8) bool {
    for (mac) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn findPeerMutable(node_addr: *const [16]u8) ?*PeerEntry {
    for (&g_peer_table) |*entry| {
        if (entry.valid and ipv6Eq(&entry.node_addr, node_addr)) return entry;
    }
    return null;
}

fn findPeer(node_addr: *const [16]u8) ?*const PeerEntry {
    for (&g_peer_table) |*entry| {
        if (entry.valid and ipv6Eq(&entry.node_addr, node_addr)) return entry;
    }
    return null;
}

fn ensurePeerMutable(node_addr: *const [16]u8) struct { entry: *PeerEntry, is_new: bool } {
    if (findPeerMutable(node_addr)) |existing| {
        return .{ .entry = existing, .is_new = false };
    }

    for (&g_peer_table) |*entry| {
        if (!entry.valid) {
            entry.* = .{ .valid = true };
            @memcpy(&entry.node_addr, node_addr);
            return .{ .entry = entry, .is_new = true };
        }
    }

    const slot = g_peer_evict % PEER_TABLE_SIZE;
    g_peer_evict += 1;
    g_peer_table[slot] = .{ .valid = true };
    @memcpy(&g_peer_table[slot].node_addr, node_addr);
    return .{ .entry = &g_peer_table[slot], .is_new = true };
}

fn localPeerFlags() u16 {
    var flags: u16 = netd_proto.PEER_FLAG_TRUSTED |
        netd_proto.PEER_FLAG_ROUTE_DIRECT |
        netd_proto.PEER_FLAG_HAS_NETD;
    if (isLinkLocalIpv6(&g_our_ipv6)) flags |= netd_proto.PEER_FLAG_LINK_LOCAL_ONLY;
    return flags;
}

fn learnObservedPeer(ipv6: *const [16]u8, mac: *const [6]u8) void {
    if (isLocalNode(ipv6) or ipv6[0] == 0xFF) return;

    const ensured = ensurePeerMutable(ipv6);
    const entry = ensured.entry;
    if (entry.mtu == 0) entry.mtu = DEFAULT_LINK_MTU;
    if (!isZeroMac(mac)) @memcpy(&entry.mac, mac);
    if (isUnspecifiedIpv6(&entry.next_hop)) @memcpy(&entry.next_hop, ipv6);
    entry.flags |= netd_proto.PEER_FLAG_ROUTE_DIRECT;
    if (isLinkLocalIpv6(ipv6)) entry.flags |= netd_proto.PEER_FLAG_LINK_LOCAL_ONLY;
}

fn applyPeerAnnouncement(payload: *align(1) const netd_proto.PeerAnnouncementPayload) bool {
    if (isLocalNode(&payload.node_addr) or payload.node_addr[0] == 0xFF) return false;

    const ensured = ensurePeerMutable(&payload.node_addr);
    const entry = ensured.entry;
    entry.service_mask = payload.service_mask;
    entry.mtu = if (payload.mtu != 0) payload.mtu else DEFAULT_LINK_MTU;
    entry.flags = payload.flags | netd_proto.PEER_FLAG_HAS_NETD;
    if (!isZeroMac(&payload.mac)) {
        @memcpy(&entry.mac, &payload.mac);
        learnNeighbor(&payload.node_addr, &payload.mac);
    }
    if (isUnspecifiedIpv6(&entry.next_hop)) @memcpy(&entry.next_hop, &payload.node_addr);
    return ensured.is_new;
}

fn applyRouteUpdate(payload: *align(1) const netd_proto.RouteUpdatePayload) void {
    if (payload.prefix_len != 128) return;

    if (payload.action == 0) {
        if (findPeerMutable(&payload.prefix)) |entry| {
            if (entry.service_mask == 0 and isZeroMac(&entry.mac)) {
                entry.* = .{};
            } else {
                @memset(entry.next_hop[0..], 0);
                entry.flags &= ~netd_proto.PEER_FLAG_ROUTE_DIRECT;
            }
        }
        return;
    }

    const ensured = ensurePeerMutable(&payload.prefix);
    const entry = ensured.entry;
    entry.mtu = if (entry.mtu != 0) entry.mtu else DEFAULT_LINK_MTU;
    if (isUnspecifiedIpv6(&payload.next_hop)) {
        @memcpy(&entry.next_hop, &payload.prefix);
        entry.flags |= netd_proto.PEER_FLAG_ROUTE_DIRECT;
    } else {
        @memcpy(&entry.next_hop, &payload.next_hop);
        if (ipv6Eq(&payload.next_hop, &payload.prefix)) {
            entry.flags |= netd_proto.PEER_FLAG_ROUTE_DIRECT;
        } else {
            entry.flags &= ~netd_proto.PEER_FLAG_ROUTE_DIRECT;
        }
    }
    if (isLinkLocalIpv6(&payload.prefix)) entry.flags |= netd_proto.PEER_FLAG_LINK_LOCAL_ONLY;
}

fn fillPeerSnapshot(reply: *netd_proto.PeerSnapshotReply) void {
    reply.count = 0;
    for (&g_peer_table) |*entry| {
        if (!entry.valid) continue;
        if (reply.count >= netd_proto.MAX_PEER_SNAPSHOT_ENTRIES) break;

        reply.entries[reply.count] = .{
            .node_addr = entry.node_addr,
            .service_mask = entry.service_mask,
            .mtu = entry.mtu,
            .flags = entry.flags,
            .mac = entry.mac,
        };
        reply.count += 1;
    }
}

fn resolveNextHop(dst_node: *const [16]u8, next_hop_out: *[16]u8) void {
    @memcpy(next_hop_out, dst_node);
    if (findPeer(dst_node)) |entry| {
        if (!isUnspecifiedIpv6(&entry.next_hop)) {
            @memcpy(next_hop_out, &entry.next_hop);
        }
    }
}

fn sendNetdMessage(dst_node: *const [16]u8, dst_endpoint: u64, op: netd_proto.Op, payload: []const u8) bool {
    if (g_control_outbox_phys == 0) return false;

    const total_payload_len = @sizeOf(netd_proto.NetdHeader) + payload.len;
    if (lib.DIPC_HEADER_SIZE + total_payload_len > PAGE_SIZE) return false;

    const outbox: [*]u8 = lib.ptrFrom([*]u8, CONTROL_OUTBOX_VA);
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(outbox));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(total_payload_len)),
        .auth_tag = 0,
        .src = .{ .node = .{ .bytes = g_our_ipv6 }, .endpoint = NETD_ENDPOINT },
        .dst = .{ .node = .{ .bytes = dst_node.* }, .endpoint = dst_endpoint },
    };

    const msg_hdr: *align(1) netd_proto.NetdHeader = @ptrFromInt(@intFromPtr(outbox) + lib.DIPC_HEADER_SIZE);
    msg_hdr.* = .{ .op = op };

    if (payload.len != 0) {
        @memcpy(
            outbox[lib.DIPC_HEADER_SIZE + @sizeOf(netd_proto.NetdHeader) ..][0..payload.len],
            payload,
        );
    }

    return lib.syscall(SYS_SEND_PAGE, g_control_outbox_phys, 0, g_token) == 0;
}

fn sendSelfPeerAnnouncement(dst_node: *const [16]u8) bool {
    const payload = netd_proto.PeerAnnouncementPayload{
        .node_addr = g_our_ipv6,
        .service_mask = NETD_SERVICE_MASK,
        .mtu = DEFAULT_LINK_MTU,
        .flags = localPeerFlags(),
        .mac = g_our_mac,
    };
    return sendNetdMessage(dst_node, NETD_ENDPOINT, .peer_announce, std.mem.asBytes(&payload));
}

fn sendNodeAddrReply(dst_node: *const [16]u8, dst_endpoint: u64) void {
    const reply = netd_proto.NodeAddrReply{ .addr = g_our_ipv6 };
    _ = sendNetdMessage(dst_node, dst_endpoint, .node_addr_reply, std.mem.asBytes(&reply));
}

fn sendPeerSnapshotReply(dst_node: *const [16]u8, dst_endpoint: u64) void {
    var reply = netd_proto.PeerSnapshotReply{ .count = 0 };
    fillPeerSnapshot(&reply);
    _ = sendNetdMessage(dst_node, dst_endpoint, .peer_snapshot_reply, std.mem.asBytes(&reply));
}

fn lookupNeighbor(ipv6: *const [16]u8) ?[6]u8 {
    for (&g_neighbor_cache) |*e| {
        if (!e.valid) continue;
        var match = true;
        for (0..16) |i| if (e.ipv6[i] != ipv6[i]) {
            match = false;
            break;
        };
        if (match) return e.mac;
    }
    return null;
}

fn learnNeighbor(ipv6: *const [16]u8, mac: *const [6]u8) void {
    // Skip link-local multicast and unspecified
    if (ipv6[0] == 0xff) return;
    // Update existing entry
    for (&g_neighbor_cache) |*e| {
        if (!e.valid) continue;
        var match = true;
        for (0..16) |i| if (e.ipv6[i] != ipv6[i]) {
            match = false;
            break;
        };
        if (match) {
            @memcpy(&e.mac, mac);
            return;
        }
    }
    // Find empty slot
    for (&g_neighbor_cache) |*e| {
        if (!e.valid) {
            e.valid = true;
            @memcpy(&e.ipv6, ipv6);
            @memcpy(&e.mac, mac);
            return;
        }
    }
    // Round-robin eviction
    const slot = g_neighbor_evict % NEIGHBOR_CACHE_SIZE;
    g_neighbor_evict += 1;
    g_neighbor_cache[slot].valid = true;
    @memcpy(&g_neighbor_cache[slot].ipv6, ipv6);
    @memcpy(&g_neighbor_cache[slot].mac, mac);
}

fn isAllNodesMulticast(addr: *const [16]u8) bool {
    for (IPV6_ALL_NODES_MULTICAST, 0..) |byte, index| {
        if (addr[index] != byte) return false;
    }
    return true;
}

fn sendDipcPageToWire(dst_node: *const [16]u8, dipc_page: []const u8) void {
    if (dipc_page.len > 1400) return;

    const frame_len = 14 + 40 + 8 + dipc_page.len;
    const frame = &g_wire_frame_buf;
    @memset(frame[0..frame_len], 0);

    if (dst_node[0] == 0xFF) {
        frame[0] = 0x33;
        frame[1] = 0x33;
        frame[2] = dst_node[12];
        frame[3] = dst_node[13];
        frame[4] = dst_node[14];
        frame[5] = dst_node[15];
    } else {
        var next_hop: [16]u8 = undefined;
        resolveNextHop(dst_node, &next_hop);
        if (lookupNeighbor(&next_hop)) |resolved_mac| {
            @memcpy(frame[0..6], &resolved_mac);
        } else {
            @memset(frame[0..6], 0xFF);
            sendNeighborSolicitation(&next_hop);
        }
    }
    @memcpy(frame[6..12], &g_our_mac);
    frame[12] = 0x86;
    frame[13] = 0xDD;
    frame[14] = 0x60;
    put_be16(frame[18..20], @as(u16, @intCast(8 + dipc_page.len)));
    frame[20] = 0x11;
    frame[21] = 255;
    @memcpy(frame[22..38], &g_our_ipv6);
    @memcpy(frame[38..54], dst_node);
    put_be16(frame[54..56], DIPC_UDP_PORT);
    put_be16(frame[56..58], DIPC_UDP_PORT);
    put_be16(frame[58..60], @as(u16, @intCast(8 + dipc_page.len)));
    @memcpy(frame[62 .. 62 + dipc_page.len], dipc_page);
    txFrame(frame[0..frame_len]);
}

fn handleLocalNetdMessage(page_hdr: *align(1) const lib.PageHeader, recv_va: u64) void {
    const total_payload_len = @as(usize, page_hdr.payload_len);
    const payload_ptr = recv_va + lib.DIPC_HEADER_SIZE;

    if (total_payload_len < @sizeOf(netd_proto.NetdHeader)) {
        const raw_frame: [*]const u8 = @ptrFromInt(payload_ptr);
        txFrame(raw_frame[0..total_payload_len]);
        return;
    }

    const msg_hdr: *align(1) const netd_proto.NetdHeader = @ptrFromInt(payload_ptr);
    if (msg_hdr.magic != netd_proto.MAGIC or msg_hdr.version != netd_proto.VERSION) {
        const raw_frame: [*]const u8 = @ptrFromInt(payload_ptr);
        txFrame(raw_frame[0..total_payload_len]);
        return;
    }

    const msg_payload_len = total_payload_len - @sizeOf(netd_proto.NetdHeader);
    const msg_payload_va = payload_ptr + @sizeOf(netd_proto.NetdHeader);

    switch (msg_hdr.op) {
        .transmit => {
            if (msg_payload_len < @sizeOf(netd_proto.TransmitPayload)) return;
            const payload: *align(1) const netd_proto.TransmitPayload = @ptrFromInt(msg_payload_va);
            const frame_len = @as(usize, payload.frame_len);
            const frame_offset = msg_payload_va + @sizeOf(netd_proto.TransmitPayload);
            const available = msg_payload_len - @sizeOf(netd_proto.TransmitPayload);
            if (frame_len > available) return;
            const frame: [*]const u8 = @ptrFromInt(frame_offset);
            txFrame(frame[0..frame_len]);
        },
        .get_node_addr => sendNodeAddrReply(&page_hdr.src.node.bytes, page_hdr.src.endpoint),
        .route_update => {
            if (msg_payload_len != @sizeOf(netd_proto.RouteUpdatePayload)) return;
            const payload: *align(1) const netd_proto.RouteUpdatePayload = @ptrFromInt(msg_payload_va);
            applyRouteUpdate(payload);
        },
        .forward_dipc => {
            if (msg_payload_len < @sizeOf(netd_proto.ForwardPayload)) return;
            const payload: *align(1) const netd_proto.ForwardPayload = @ptrFromInt(msg_payload_va);
            const page_len = @as(usize, payload.page_len);
            const page_offset = msg_payload_va + @sizeOf(netd_proto.ForwardPayload);
            const available = msg_payload_len - @sizeOf(netd_proto.ForwardPayload);
            if (page_len > available) return;
            const dipc_page: [*]const u8 = @ptrFromInt(page_offset);
            sendDipcPageToWire(&payload.dst_node, dipc_page[0..page_len]);
        },
        .peer_announce => {
            if (msg_payload_len != @sizeOf(netd_proto.PeerAnnouncementPayload)) return;
            const payload: *align(1) const netd_proto.PeerAnnouncementPayload = @ptrFromInt(msg_payload_va);
            const is_new = applyPeerAnnouncement(payload);
            if (is_new and !isLocalNode(&payload.node_addr)) {
                _ = sendSelfPeerAnnouncement(&payload.node_addr);
            }
        },
        .peer_snapshot_request => {
            sendPeerSnapshotReply(&page_hdr.src.node.bytes, page_hdr.src.endpoint);
        },
        .node_addr_reply, .peer_snapshot_reply => {},
        .tcp_listen => {
            if (msg_payload_len >= 2) {
                const port = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(@alignCast(@as([*]const u8, @ptrFromInt(msg_payload_va))[0..2]))), .native);
                handleTcpListen(page_hdr, port);
            }
        },
        .tcp_listen_ack => {},
        .tcp_connect => {
            handleTcpConnect(page_hdr, msg_payload_va, msg_payload_len);
        },
        .tcp_connect_ack => {},
        .tcp_send => {
            handleTcpSend(page_hdr, msg_payload_va, msg_payload_len);
        },
        .tcp_recv => {},
        .tcp_close => {
            handleTcpClose(page_hdr, msg_payload_va, msg_payload_len);
        },
        .tcp_closed => {},
        .tcp_status => {
            handleTcpStatus(page_hdr, msg_payload_va, msg_payload_len);
        },
        .tcp_status_reply => {},
    }
}

// ---------------------------------------------------------------------------
// Virtio ring helpers
// ---------------------------------------------------------------------------

fn rxDesc() [*]VirtqDesc {
    return @ptrFromInt(RX_DESC_VA);
}
fn rxAvail() *VirtqAvail {
    return @ptrFromInt(RX_AVAIL_VA);
}
fn rxUsed() *const VirtqUsed {
    return @ptrFromInt(RX_USED_VA);
}
fn txDesc() [*]VirtqDesc {
    return @ptrFromInt(TX_DESC_VA);
}
fn txAvail() *VirtqAvail {
    return @ptrFromInt(TX_AVAIL_VA);
}
fn txUsed() *const VirtqUsed {
    return @ptrFromInt(TX_USED_VA);
}

// Fill the first NUM_RX_BUFS descriptors and add them to the avail ring.
fn fillRxQueue() void {
    const desc = rxDesc();
    const avail = rxAvail();
    var i: u16 = 0;
    while (i < NUM_RX_BUFS) : (i += 1) {
        desc[i] = VirtqDesc{
            .addr = g_rxbuf_phys + @as(u64, i) * RX_BUF_SIZE,
            .len = RX_BUF_SIZE,
            .flags = VIRTQ_DESC_F_WRITE,
            .next = 0,
        };
        avail.ring[i] = i;
    }
    avail.idx = NUM_RX_BUFS;
    // Notify queue 0 so the device picks them up.
    outw(g_io_base + VIRTIO_PCI_QUEUE_NOTIFY, 0);
}

// Replenish a used RX descriptor back into the avail ring.
fn replenishRx(desc_idx: u16) void {
    const avail = rxAvail();
    // Descriptor buffer address/len are unchanged; just re-add.
    avail.ring[avail.idx % QUEUE_SIZE] = desc_idx;
    avail.idx +%= 1;
    outw(g_io_base + VIRTIO_PCI_QUEUE_NOTIFY, 0);
}

// Transmit a raw ethernet frame (no virtio-net header wrap needed for legacy
// DMA-direct; the header is prepended here).
fn txFrame(frame: []const u8) void {
    // Ensure previous TX is done (single-descriptor TX, wait for it).
    var spin: u32 = 100_000;
    const used = txUsed();
    const avail = txAvail();
    while (avail.idx != g_tx_last_used and used.idx == g_tx_last_used and spin > 0) spin -= 1;
    if (used.idx != g_tx_last_used) g_tx_last_used = used.idx;

    // Write virtio-net header + frame into TX buffer VA.
    const hdr: *VirtioNetHdr = lib.ptrFrom(*VirtioNetHdr, TXBUF_VA);
    hdr.* = VirtioNetHdr{};
    const total = VIRTIO_NET_HDR_SIZE + frame.len;
    if (total > PAGE_SIZE) return; // frame too large
    @memcpy(lib.ptrFrom([*]u8, TXBUF_VA + VIRTIO_NET_HDR_SIZE)[0..frame.len], frame);

    // Descriptor 0 of TX ring.
    txDesc()[0] = VirtqDesc{
        .addr = g_txbuf_phys,
        .len = @as(u32, @intCast(total)),
        .flags = 0,
        .next = 0,
    };
    avail.ring[avail.idx % QUEUE_SIZE] = 0;
    avail.idx +%= 1;
    g_tx_avail_idx = avail.idx;
    outw(g_io_base + VIRTIO_PCI_QUEUE_NOTIFY, 1);
}

// ---------------------------------------------------------------------------
// IPv6 / ICMPv6 helpers
// ---------------------------------------------------------------------------

fn be16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}
fn be32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}
fn put_be16(b: []u8, v: u16) void {
    b[0] = @as(u8, @truncate(v >> 8));
    b[1] = @as(u8, @truncate(v));
}
fn put_be32(b: []u8, v: u32) void {
    b[0] = @as(u8, @truncate(v >> 24));
    b[1] = @as(u8, @truncate(v >> 16));
    b[2] = @as(u8, @truncate(v >> 8));
    b[3] = @as(u8, @truncate(v));
}

// Compute ICMPv6 checksum over pseudo-header + ICMPv6 data.
fn icmpv6Checksum(src_ip: *const [16]u8, dst_ip: *const [16]u8, icmp_data: []const u8) u16 {
    var sum: u32 = 0;
    // Pseudo-header: src(16) + dst(16) + upper-layer length(4) + next-header(4, =58)
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        sum += (@as(u32, src_ip[i]) << 8) | src_ip[i + 1];
        sum += (@as(u32, dst_ip[i]) << 8) | dst_ip[i + 1];
    }
    sum += @as(u32, @intCast(icmp_data.len));
    sum += 0x003A; // next header = 58
    // ICMPv6 data
    i = 0;
    while (i + 1 < icmp_data.len) : (i += 2) {
        sum += (@as(u32, icmp_data[i]) << 8) | icmp_data[i + 1];
    }
    if (i < icmp_data.len) sum += @as(u32, icmp_data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @as(u16, @truncate(~sum));
}

// Build a Neighbor Advertisement and send it.
// Replies to a Neighbor Solicitation (NS) for our IPv6 address.
fn sendNeighborAdvertisement(
    dst_mac: *const [6]u8,
    dst_ip: *const [16]u8,
    target_ip: *const [16]u8,
) void {
    // Ethernet (14) + IPv6 (40) + ICMPv6 NA (24) + option TLL (8) = 86 bytes.
    var frame: [86]u8 = [_]u8{0} ** 86;
    // Ethernet header
    @memcpy(frame[0..6], dst_mac);
    @memcpy(frame[6..12], &g_our_mac);
    frame[12] = 0x86;
    frame[13] = 0xDD; // IPv6 ethertype
    // IPv6 header
    frame[14] = 0x60; // version=6
    // traffic class + flow label: 0
    put_be16(frame[18..20], 32); // payload len = 24 + 8
    frame[20] = 0x3A; // next header = ICMPv6
    frame[21] = 255; // hop limit
    @memcpy(frame[22..38], &g_our_ipv6); // src
    @memcpy(frame[38..54], dst_ip); // dst
    // ICMPv6 Neighbor Advertisement (type 136, code 0)
    frame[54] = 136; // NA
    frame[55] = 0;
    frame[56] = 0;
    frame[57] = 0; // checksum placeholder
    // Flags: S (solicited) + O (override) = 0xC0_00_00_00
    frame[58] = 0xC0;
    @memcpy(frame[62..78], target_ip); // target address
    // Option: Target Link-Layer Address (type 2, len 1 = 8 bytes)
    frame[78] = 2;
    frame[79] = 1;
    @memcpy(frame[80..86], &g_our_mac);
    // Compute checksum over ICMPv6 region [54..86]
    const ck = icmpv6Checksum(
        frame[22..38][0..16],
        frame[38..54][0..16],
        frame[54..86],
    );
    put_be16(frame[56..58], ck);
    txFrame(&frame);
}

// Send an ICMPv6 Neighbor Solicitation for target_ipv6 so we can learn its MAC.
fn sendNeighborSolicitation(target_ipv6: *const [16]u8) void {
    // Solicited-node multicast: ff02::1:ffXX:XXXX (last 3 bytes of target)
    var sol_mcast: [16]u8 = [_]u8{0} ** 16;
    sol_mcast[0] = 0xff;
    sol_mcast[1] = 0x02;
    sol_mcast[11] = 0x01;
    sol_mcast[12] = 0xff;
    sol_mcast[13] = target_ipv6[13];
    sol_mcast[14] = target_ipv6[14];
    sol_mcast[15] = target_ipv6[15];
    // Ethernet multicast MAC for solicited-node: 33:33:ff:XX:XX:XX
    const dst_mac = [6]u8{ 0x33, 0x33, 0xff, target_ipv6[13], target_ipv6[14], target_ipv6[15] };

    // ICMPv6 NS: type(1)+code(1)+cksum(2)+reserved(4)+target(16)+SLLAO(8) = 32 bytes
    var icmp: [32]u8 = [_]u8{0} ** 32;
    icmp[0] = 135; // NS
    @memcpy(icmp[8..24], target_ipv6);
    icmp[24] = 1;
    icmp[25] = 1; // option: Source Link-Layer Address, len=1 (8 bytes)
    @memcpy(icmp[26..32], &g_our_mac);
    const ck = icmpv6Checksum(&g_our_ipv6, &sol_mcast, &icmp);
    icmp[2] = @truncate(ck >> 8);
    icmp[3] = @truncate(ck);

    var frame: [86]u8 = [_]u8{0} ** 86;
    @memcpy(frame[0..6], &dst_mac);
    @memcpy(frame[6..12], &g_our_mac);
    frame[12] = 0x86;
    frame[13] = 0xDD;
    frame[14] = 0x60;
    put_be16(frame[18..20], 32); // ICMPv6 payload len
    frame[20] = 0x3A;
    frame[21] = 255;
    @memcpy(frame[22..38], &g_our_ipv6);
    @memcpy(frame[38..54], &sol_mcast);
    @memcpy(frame[54..86], &icmp);
    txFrame(&frame);
}

// Build and send an ICMPv6 Echo Reply.
fn sendEchoReply(
    dst_mac: *const [6]u8,
    dst_ip: *const [16]u8,
    icmp_payload: []const u8, // starting at ICMPv6 type byte of original echo request
) void {
    if (icmp_payload.len < 8) return; // need at least type+code+cksum+id+seq
    const echo_body_len: usize = icmp_payload.len;
    // Max: Ethernet(14)+IPv6(40)+ICMPv6 reply = 14+40+echo_body_len
    const total_eth = 14 + 40 + echo_body_len;
    if (total_eth > PAGE_SIZE) return;
    const frame = &g_icmp_frame_buf;
    @memset(frame[0..total_eth], 0);
    @memcpy(frame[0..6], dst_mac);
    @memcpy(frame[6..12], &g_our_mac);
    frame[12] = 0x86;
    frame[13] = 0xDD;
    frame[14] = 0x60;
    put_be16(frame[18..20], @as(u16, @intCast(echo_body_len)));
    frame[20] = 0x3A;
    frame[21] = 255;
    @memcpy(frame[22..38], &g_our_ipv6);
    @memcpy(frame[38..54], dst_ip);
    // ICMPv6 Echo Reply (type 129)
    frame[54] = 129;
    frame[55] = 0;
    frame[56] = 0;
    frame[57] = 0;
    // Copy original body (skipping type/code, keeping identifier/sequence/data)
    @memcpy(frame[58 .. 58 + echo_body_len - 4], icmp_payload[4..echo_body_len]);
    const ck = icmpv6Checksum(
        frame[22..38][0..16],
        frame[38..54][0..16],
        frame[54 .. 54 + echo_body_len],
    );
    put_be16(frame[56..58], ck);
    txFrame(frame[0 .. 14 + 40 + echo_body_len]);
}

fn sendUnsolicitedNA() void {
    const dst_mac = [6]u8{ 0x33, 0x33, 0x00, 0x00, 0x00, 0x01 };
    const dst_ip = IPV6_ALL_NODES_MULTICAST;
    sendNeighborAdvertisement(&dst_mac, &dst_ip, &g_our_ipv6);
}

// Derive link-local IPv6 address from MAC (EUI-64).
// fe80::XX/10 where XX encodes MAC via RFC 4291 App A.
fn deriveLinkLocal(mac: *const [6]u8, out: *[16]u8) void {
    @memset(out[0..], 0);
    out[0] = 0xFE;
    out[1] = 0x80;
    // EUI-64: insert FFFE in middle, flip U/L bit
    out[8] = mac[0] ^ 0x02;
    out[9] = mac[1];
    out[10] = mac[2];
    out[11] = 0xFF;
    out[12] = 0xFE;
    out[13] = mac[3];
    out[14] = mac[4];
    out[15] = mac[5];
}

fn seedSyntheticMac(seed: u64, out: *[6]u8) void {
    out[0] = 0x02;
    out[1] = 0x54;
    out[2] = 0x00;
    out[3] = @as(u8, @truncate(seed >> 16));
    out[4] = @as(u8, @truncate(seed >> 8));
    out[5] = @as(u8, @truncate(seed));
}

fn publishKernelNodeAddress(bs: *const BootstrapDescriptor, token: u64) bool {
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DIPC_SCRATCH_VA);
    const bootstrap_node = lib.Ipv6Addr{ .bytes = bs.local_node };

    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(@sizeOf(lib.ControlHeader) + @sizeOf(lib.SetNodeAddrPayload))),
        .auth_tag = 0,
        .src = .{ .node = bootstrap_node, .endpoint = bs.reserved_netd_endpoint },
        .dst = .{ .node = bootstrap_node, .endpoint = bs.reserved_kernel_control_endpoint },
    };

    const control: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    control.* = .{
        .op = .set_node_addr,
        .payload_len = @as(u32, @intCast(@sizeOf(lib.SetNodeAddrPayload))),
    };

    const payload: *align(1) lib.SetNodeAddrPayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
    payload.* = .{
        .addr = .{ .bytes = g_our_ipv6 },
    };

    const ok = lib.syscall(SYS_SEND_PAGE, g_dipc_scratch_phys, 0, token) == 0;
    if (ok) {
        sendNodeAddrReply(&g_our_ipv6, @intFromEnum(lib.ReservedEndpoint.clusterd));
    }
    return ok;
}

// ---------------------------------------------------------------------------
// TCP state machine & connection management
// ---------------------------------------------------------------------------

pub const TCP_MAX_SOCKETS: usize = 16;

pub const Socket = struct {
    id: u32 = 0,
    in_use: bool = false,
    state: tcp.State = .closed,
    local_port: u16 = 0,
    remote_port: u16 = 0,
    remote_ip: [16]u8 = [_]u8{0} ** 16,
    remote_mac: [6]u8 = [_]u8{0} ** 6,
    iss: u32 = 0,
    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    snd_wnd: u16 = tcp.DEFAULT_WINDOW_SIZE,
    irs: u32 = 0,
    rcv_nxt: u32 = 0,
    rcv_wnd: u16 = tcp.DEFAULT_WINDOW_SIZE,
    owner_endpoint: u64 = 0,
    owner_node: [16]u8 = [_]u8{0} ** 16,
    rx_buf: [2048]u8 = [_]u8{0} ** 2048,
    rx_len: usize = 0,
};

var g_tcp_sockets: [TCP_MAX_SOCKETS]Socket = [_]Socket{.{}} ** TCP_MAX_SOCKETS;
var g_tcp_next_id: u32 = 1;
var g_tcp_ephemeral_port: u16 = 49152;
var g_isn_seed: u32 = 0x51A7_8C3D;
var g_tcp_tx_frame: [1514]u8 = undefined;

fn nextIsn() u32 {
    g_isn_seed ^= g_isn_seed << 13;
    g_isn_seed ^= g_isn_seed >> 17;
    g_isn_seed ^= g_isn_seed << 5;
    return g_isn_seed;
}

fn allocEphemeralPort() u16 {
    const p = g_tcp_ephemeral_port;
    g_tcp_ephemeral_port = if (g_tcp_ephemeral_port >= 65000) 49152 else g_tcp_ephemeral_port + 1;
    return p;
}

fn initTcpStack() void {
    for (&g_tcp_sockets) |*s| {
        s.* = Socket{};
    }
}

fn findTcpSocketById(id: u32) ?*Socket {
    if (id == 0) return null;
    for (&g_tcp_sockets) |*s| {
        if (s.in_use and s.id == id) return s;
    }
    return null;
}

fn findTcpListener(local_port: u16) ?*Socket {
    for (&g_tcp_sockets) |*s| {
        if (s.in_use and s.state == .listen and s.local_port == local_port) return s;
    }
    return null;
}

fn findTcpConnection(local_port: u16, remote_port: u16, remote_ip: *const [16]u8) ?*Socket {
    for (&g_tcp_sockets) |*s| {
        if (s.in_use and s.state != .listen and s.local_port == local_port and s.remote_port == remote_port and
            ipv6Eq(&s.remote_ip, remote_ip))
        {
            return s;
        }
    }
    return null;
}

fn allocTcpSocket() ?*Socket {
    for (&g_tcp_sockets) |*s| {
        if (!s.in_use or s.state == .closed) {
            s.* = Socket{};
            s.id = g_tcp_next_id;
            g_tcp_next_id +%= 1;
            if (g_tcp_next_id == 0) g_tcp_next_id = 1;
            s.in_use = true;
            return s;
        }
    }
    return null;
}

fn sendTcpSegment(
    dst_mac: *const [6]u8,
    dst_ip: *const [16]u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    payload: []const u8,
) void {
    const total_tcp_len = tcp.TCP_HEADER_MIN_SIZE + payload.len;
    const total_eth_len = 14 + 40 + total_tcp_len;
    if (total_eth_len > g_tcp_tx_frame.len) return;

    const frame = g_tcp_tx_frame[0..total_eth_len];

    var target_mac: [6]u8 = dst_mac.*;
    if (isZeroMac(&target_mac)) {
        if (lookupNeighbor(dst_ip)) |cached_mac| {
            target_mac = cached_mac;
        } else {
            target_mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
        }
    }

    // Ethernet header
    @memcpy(frame[0..6], &target_mac);
    @memcpy(frame[6..12], &g_our_mac);
    frame[12] = 0x86;
    frame[13] = 0xDD;

    // IPv6 header
    frame[14] = 0x60;
    frame[15] = 0;
    frame[16] = 0;
    frame[17] = 0;
    put_be16(frame[18..20], @as(u16, @intCast(total_tcp_len)));
    frame[20] = tcp.TCP_PROTOCOL_NUMBER;
    frame[21] = 64;
    @memcpy(frame[22..38], &g_our_ipv6);
    @memcpy(frame[38..54], dst_ip);

    // TCP header (20 bytes)
    put_be16(frame[54..56], src_port);
    put_be16(frame[56..58], dst_port);
    put_be32(frame[58..62], seq);
    put_be32(frame[62..66], ack);
    frame[66] = (5 << 4); // Data offset = 5 words (20 bytes)
    frame[67] = flags;
    put_be16(frame[68..70], window);
    put_be16(frame[70..72], 0); // Checksum placeholder
    put_be16(frame[72..74], 0); // Urgent pointer

    // Payload
    if (payload.len > 0) {
        @memcpy(frame[74 .. 74 + payload.len], payload);
    }

    // Checksum
    const cksum = tcp.computeChecksum(&g_our_ipv6, dst_ip, frame[54..total_eth_len]);
    put_be16(frame[70..72], cksum);

    txFrame(frame);
}

fn sendTcpRst(
    dst_mac: *const [6]u8,
    dst_ip: *const [16]u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
) void {
    sendTcpSegment(dst_mac, dst_ip, src_port, dst_port, seq, ack, flags, 0, &[_]u8{});
}

fn sendTcpConnectAckToOwner(sock: *Socket, status: u16) void {
    if (sock.owner_endpoint == 0) return;
    const reply = netd_proto.TcpConnectAckPayload{
        .socket_id = sock.id,
        .status = status,
        .local_port = sock.local_port,
    };
    _ = sendNetdMessage(&sock.owner_node, sock.owner_endpoint, .tcp_connect_ack, std.mem.asBytes(&reply));
}

fn sendTcpRecvToOwner(sock: *Socket, data: []const u8) void {
    if (sock.owner_endpoint == 0 or g_control_outbox_phys == 0) return;
    const total_len = @sizeOf(netd_proto.TcpRecvPayload) + data.len;
    if (total_len > 1024) return;

    var buf: [1024]u8 = undefined;
    const payload: *align(1) netd_proto.TcpRecvPayload = @ptrCast(&buf);
    payload.* = .{
        .socket_id = sock.id,
        .data_len = @as(u16, @intCast(data.len)),
        ._pad = 0,
    };
    @memcpy(buf[@sizeOf(netd_proto.TcpRecvPayload) .. total_len], data);
    _ = sendNetdMessage(&sock.owner_node, sock.owner_endpoint, .tcp_recv, buf[0..total_len]);
}

fn sendTcpClosedToOwner(sock: *Socket, reason: u16) void {
    if (sock.owner_endpoint == 0) return;
    const payload = netd_proto.TcpClosedPayload{
        .socket_id = sock.id,
        .reason = reason,
        ._pad = 0,
    };
    _ = sendNetdMessage(&sock.owner_node, sock.owner_endpoint, .tcp_closed, std.mem.asBytes(&payload));
}

fn handleTcpListen(page_hdr: *align(1) const lib.PageHeader, port: u16) void {
    lib.serialWrite("netd: TCP listen on port ");
    printDec(port);
    lib.serialWrite(" acknowledged\n");

    var ack = netd_proto.TcpListenAckPayload{
        .port = port,
        .status = 0,
        .socket_id = 0,
    };

    if (findTcpListener(port)) |existing| {
        ack.status = 1; // already in use
        ack.socket_id = existing.id;
    } else {
        if (allocTcpSocket()) |sock| {
            sock.state = .listen;
            sock.local_port = port;
            sock.owner_endpoint = page_hdr.src.endpoint;
            @memcpy(&sock.owner_node, &page_hdr.src.node.bytes);
            ack.status = 0;
            ack.socket_id = sock.id;
        } else {
            ack.status = 2; // table full
        }
    }

    _ = sendNetdMessage(&page_hdr.src.node.bytes, page_hdr.src.endpoint, .tcp_listen_ack, std.mem.asBytes(&ack));
}

fn handleTcpConnect(page_hdr: *align(1) const lib.PageHeader, payload_va: u64, payload_len: usize) void {
    if (payload_len < @sizeOf(netd_proto.TcpConnectPayload)) return;
    const req: *align(1) const netd_proto.TcpConnectPayload = @ptrFromInt(payload_va);

    var ack = netd_proto.TcpConnectAckPayload{
        .socket_id = 0,
        .status = 1,
        .local_port = 0,
    };

    const sock = allocTcpSocket() orelse {
        ack.status = 2; // table full
        _ = sendNetdMessage(&page_hdr.src.node.bytes, page_hdr.src.endpoint, .tcp_connect_ack, std.mem.asBytes(&ack));
        return;
    };

    const lport = if (req.local_port != 0) req.local_port else allocEphemeralPort();
    sock.state = .syn_sent;
    sock.local_port = lport;
    sock.remote_port = req.remote_port;
    @memcpy(&sock.remote_ip, &req.remote_ip);
    sock.owner_endpoint = page_hdr.src.endpoint;
    @memcpy(&sock.owner_node, &page_hdr.src.node.bytes);

    sock.iss = nextIsn();
    sock.snd_nxt = sock.iss +% 1;
    sock.snd_una = sock.iss;
    sock.rcv_nxt = 0;
    sock.snd_wnd = tcp.DEFAULT_WINDOW_SIZE;
    sock.rcv_wnd = tcp.DEFAULT_WINDOW_SIZE;

    if (lookupNeighbor(&sock.remote_ip)) |mac| {
        @memcpy(&sock.remote_mac, &mac);
    } else {
        @memcpy(&sock.remote_mac, &[_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 });
    }

    ack.socket_id = sock.id;
    ack.status = 0;
    ack.local_port = lport;

    sendTcpSegment(
        &sock.remote_mac,
        &sock.remote_ip,
        sock.local_port,
        sock.remote_port,
        sock.iss,
        0,
        tcp.Flags.SYN,
        sock.rcv_wnd,
        &[_]u8{},
    );

    _ = sendNetdMessage(&page_hdr.src.node.bytes, page_hdr.src.endpoint, .tcp_connect_ack, std.mem.asBytes(&ack));
}

fn handleTcpSend(page_hdr: *align(1) const lib.PageHeader, payload_va: u64, payload_len: usize) void {
    _ = page_hdr;
    if (payload_len < @sizeOf(netd_proto.TcpSendPayload)) return;
    const req: *align(1) const netd_proto.TcpSendPayload = @ptrFromInt(payload_va);
    const data_len = @as(usize, req.data_len);
    const data_offset = payload_va + @sizeOf(netd_proto.TcpSendPayload);
    if (@sizeOf(netd_proto.TcpSendPayload) + data_len > payload_len) return;
    const data: [*]const u8 = @ptrFromInt(data_offset);

    const sock = findTcpSocketById(req.socket_id) orelse return;
    if (sock.state != .established and sock.state != .close_wait) return;

    sendTcpSegment(
        &sock.remote_mac,
        &sock.remote_ip,
        sock.local_port,
        sock.remote_port,
        sock.snd_nxt,
        sock.rcv_nxt,
        tcp.Flags.ACK | tcp.Flags.PSH,
        sock.rcv_wnd,
        data[0..data_len],
    );
    sock.snd_nxt +%= @as(u32, @intCast(data_len));
}

fn handleTcpClose(page_hdr: *align(1) const lib.PageHeader, payload_va: u64, payload_len: usize) void {
    _ = page_hdr;
    if (payload_len < @sizeOf(netd_proto.TcpClosePayload)) return;
    const req: *align(1) const netd_proto.TcpClosePayload = @ptrFromInt(payload_va);

    const sock = findTcpSocketById(req.socket_id) orelse return;

    if (sock.state == .established) {
        sendTcpSegment(
            &sock.remote_mac,
            &sock.remote_ip,
            sock.local_port,
            sock.remote_port,
            sock.snd_nxt,
            sock.rcv_nxt,
            tcp.Flags.FIN | tcp.Flags.ACK,
            sock.rcv_wnd,
            &[_]u8{},
        );
        sock.snd_nxt +%= 1;
        sock.state = .fin_wait_1;
    } else if (sock.state == .close_wait) {
        sendTcpSegment(
            &sock.remote_mac,
            &sock.remote_ip,
            sock.local_port,
            sock.remote_port,
            sock.snd_nxt,
            sock.rcv_nxt,
            tcp.Flags.FIN | tcp.Flags.ACK,
            sock.rcv_wnd,
            &[_]u8{},
        );
        sock.snd_nxt +%= 1;
        sock.state = .last_ack;
    } else {
        sock.state = .closed;
        sock.in_use = false;
    }
}

fn handleTcpStatus(page_hdr: *align(1) const lib.PageHeader, payload_va: u64, payload_len: usize) void {
    if (payload_len < @sizeOf(netd_proto.TcpStatusPayload)) return;
    const req: *align(1) const netd_proto.TcpStatusPayload = @ptrFromInt(payload_va);

    var reply = netd_proto.TcpStatusReplyPayload{
        .socket_id = req.socket_id,
        .state = 0,
        .local_port = 0,
        .remote_port = 0,
        .remote_ip = [_]u8{0} ** 16,
        .rx_buffered = 0,
    };

    if (findTcpSocketById(req.socket_id)) |sock| {
        reply.state = @intFromEnum(sock.state);
        reply.local_port = sock.local_port;
        reply.remote_port = sock.remote_port;
        @memcpy(&reply.remote_ip, &sock.remote_ip);
        reply.rx_buffered = @as(u32, @intCast(sock.rx_len));
    }

    _ = sendNetdMessage(&page_hdr.src.node.bytes, page_hdr.src.endpoint, .tcp_status_reply, std.mem.asBytes(&reply));
}

fn handleTcpFrame(f: []const u8, frame_len: usize, token: u64) void {
    _ = token;
    if (frame_len < 54 + tcp.TCP_HEADER_MIN_SIZE) return;

    const src_mac = f[6..12][0..6];
    const src_ip = f[22..38][0..16];
    const dst_ip = f[38..54][0..16];

    if (!ipv6Eq(dst_ip, &g_our_ipv6) and !isLoopbackIpv6(dst_ip)) return;

    const src_port = be16(f[54..56]);
    const dst_port = be16(f[56..58]);
    const seq_num = be32(f[58..62]);
    const ack_num = be32(f[62..66]);
    const data_offset_words: u8 = (f[66] >> 4) & 0x0F;
    const tcp_hdr_len: usize = @as(usize, data_offset_words) * 4;
    if (tcp_hdr_len < 20 or frame_len < 54 + tcp_hdr_len) return;
    const flags = f[67];
    const window = be16(f[68..70]);
    const payload = f[54 + tcp_hdr_len .. frame_len];

    learnNeighbor(src_ip, src_mac);

    if (findTcpConnection(dst_port, src_port, src_ip)) |sock| {
        @memcpy(&sock.remote_mac, src_mac);
        sock.snd_wnd = window;

        if (flags & tcp.Flags.RST != 0) {
            sock.state = .closed;
            sock.in_use = false;
            sendTcpClosedToOwner(sock, 1);
            return;
        }

        switch (sock.state) {
            .syn_sent => {
                if ((flags & (tcp.Flags.SYN | tcp.Flags.ACK)) == (tcp.Flags.SYN | tcp.Flags.ACK)) {
                    sock.irs = seq_num;
                    sock.rcv_nxt = seq_num +% 1;
                    sock.snd_una = ack_num;
                    sock.state = .established;
                    sendTcpSegment(
                        &sock.remote_mac,
                        &sock.remote_ip,
                        sock.local_port,
                        sock.remote_port,
                        sock.snd_nxt,
                        sock.rcv_nxt,
                        tcp.Flags.ACK,
                        sock.rcv_wnd,
                        &[_]u8{},
                    );
                    sendTcpConnectAckToOwner(sock, 0);
                }
            },
            .syn_received => {
                if (flags & tcp.Flags.ACK != 0) {
                    sock.snd_una = ack_num;
                    sock.state = .established;
                }
            },
            .established => {
                if (flags & tcp.Flags.ACK != 0) {
                    sock.snd_una = ack_num;
                }
                if (payload.len > 0 and seq_num == sock.rcv_nxt) {
                    sock.rcv_nxt +%= @as(u32, @intCast(payload.len));
                    const copy_len = @min(payload.len, sock.rx_buf.len - sock.rx_len);
                    if (copy_len > 0) {
                        @memcpy(sock.rx_buf[sock.rx_len .. sock.rx_len + copy_len], payload[0..copy_len]);
                        sock.rx_len += copy_len;
                    }
                    sendTcpSegment(
                        &sock.remote_mac,
                        &sock.remote_ip,
                        sock.local_port,
                        sock.remote_port,
                        sock.snd_nxt,
                        sock.rcv_nxt,
                        tcp.Flags.ACK,
                        sock.rcv_wnd,
                        &[_]u8{},
                    );
                    if (sock.owner_endpoint != 0 and copy_len > 0) {
                        sendTcpRecvToOwner(sock, payload[0..copy_len]);
                    }
                }
                if (flags & tcp.Flags.FIN != 0) {
                    sock.rcv_nxt +%= 1;
                    sock.state = .close_wait;
                    sendTcpSegment(
                        &sock.remote_mac,
                        &sock.remote_ip,
                        sock.local_port,
                        sock.remote_port,
                        sock.snd_nxt,
                        sock.rcv_nxt,
                        tcp.Flags.ACK,
                        sock.rcv_wnd,
                        &[_]u8{},
                    );
                    sendTcpClosedToOwner(sock, 0);
                    sock.state = .last_ack;
                    sendTcpSegment(
                        &sock.remote_mac,
                        &sock.remote_ip,
                        sock.local_port,
                        sock.remote_port,
                        sock.snd_nxt,
                        sock.rcv_nxt,
                        tcp.Flags.FIN | tcp.Flags.ACK,
                        sock.rcv_wnd,
                        &[_]u8{},
                    );
                    sock.snd_nxt +%= 1;
                }
            },
            .fin_wait_1 => {
                if (flags & tcp.Flags.ACK != 0 and ack_num == sock.snd_nxt) {
                    sock.state = .fin_wait_2;
                }
                if (flags & tcp.Flags.FIN != 0) {
                    sock.rcv_nxt +%= 1;
                    sendTcpSegment(
                        &sock.remote_mac,
                        &sock.remote_ip,
                        sock.local_port,
                        sock.remote_port,
                        sock.snd_nxt,
                        sock.rcv_nxt,
                        tcp.Flags.ACK,
                        sock.rcv_wnd,
                        &[_]u8{},
                    );
                    sock.state = .closed;
                    sock.in_use = false;
                    sendTcpClosedToOwner(sock, 0);
                }
            },
            .fin_wait_2 => {
                if (flags & tcp.Flags.FIN != 0) {
                    sock.rcv_nxt +%= 1;
                    sendTcpSegment(
                        &sock.remote_mac,
                        &sock.remote_ip,
                        sock.local_port,
                        sock.remote_port,
                        sock.snd_nxt,
                        sock.rcv_nxt,
                        tcp.Flags.ACK,
                        sock.rcv_wnd,
                        &[_]u8{},
                    );
                    sock.state = .closed;
                    sock.in_use = false;
                    sendTcpClosedToOwner(sock, 0);
                }
            },
            .last_ack => {
                if (flags & tcp.Flags.ACK != 0 and ack_num == sock.snd_nxt) {
                    sock.state = .closed;
                    sock.in_use = false;
                }
            },
            .close_wait, .time_wait, .closed, .listen => {},
        }
        return;
    }

    if (findTcpListener(dst_port)) |listener| {
        if (flags & tcp.Flags.RST != 0) return;

        if (flags & tcp.Flags.SYN != 0 and flags & tcp.Flags.ACK == 0) {
            const new_sock = allocTcpSocket() orelse return;
            new_sock.state = .syn_received;
            new_sock.local_port = dst_port;
            new_sock.remote_port = src_port;
            @memcpy(&new_sock.remote_ip, src_ip);
            @memcpy(&new_sock.remote_mac, src_mac);
            new_sock.owner_endpoint = listener.owner_endpoint;
            @memcpy(&new_sock.owner_node, &listener.owner_node);

            new_sock.irs = seq_num;
            new_sock.rcv_nxt = seq_num +% 1;
            new_sock.iss = nextIsn();
            new_sock.snd_nxt = new_sock.iss +% 1;
            new_sock.snd_una = new_sock.iss;
            new_sock.snd_wnd = window;

            sendTcpSegment(
                src_mac,
                src_ip,
                dst_port,
                src_port,
                new_sock.iss,
                new_sock.rcv_nxt,
                tcp.Flags.SYN | tcp.Flags.ACK,
                new_sock.rcv_wnd,
                &[_]u8{},
            );
        }
        return;
    }

    if (flags & tcp.Flags.RST == 0) {
        if (flags & tcp.Flags.ACK != 0) {
            sendTcpRst(src_mac, src_ip, dst_port, src_port, ack_num, 0, tcp.Flags.RST);
        } else {
            sendTcpRst(src_mac, src_ip, dst_port, src_port, 0, seq_num +% 1, tcp.Flags.RST | tcp.Flags.ACK);
        }
    }
}

// ---------------------------------------------------------------------------
// Receive packet handler
// ---------------------------------------------------------------------------

fn handleFrame(frame_va: u64, frame_len: u32, token: u64) void {
    if (frame_len < 14) return;
    const f: [*]const u8 = lib.ptrFrom([*]const u8, frame_va);
    const ethertype = be16(f[12..14]);

    if (ethertype == 0x86DD) {
        // IPv6 frame
        if (frame_len < 54) return;
        const payload_len = be16(f[18..20]);
        const next_hdr = f[20];
        const src_ip = f[22..38][0..16];
        const dst_ip = f[38..54][0..16];
        const src_mac = f[6..12][0..6];

        // Opportunistically learn the sender's MAC from any incoming IPv6 frame.
        learnNeighbor(src_ip, src_mac);
        learnObservedPeer(src_ip, src_mac);

        if (next_hdr == 0x3A and frame_len >= 54 + payload_len) {
            // ICMPv6
            const icmp_type = f[54];
            // Neighbor Solicitation (type 135)
            if (icmp_type == 135 and payload_len >= 24) {
                // Target address at f[62..78]
                const target = f[62..78][0..16];
                // Also learn sender from SLLAO option if present (option at f[78]: type=1, len=1, mac=f[80..86])
                if (payload_len >= 32 and f[78] == 1 and f[79] == 1) {
                    learnNeighbor(src_ip, f[80..86][0..6]);
                }
                // Check if solicitation is for our address
                var match = true;
                for (g_our_ipv6, 0..) |b, i| {
                    if (b != target[i]) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    sendNeighborAdvertisement(src_mac, src_ip, target);
                }
            }
            // Neighbor Advertisement (type 136) — update neighbor cache with target/TLLAO
            else if (icmp_type == 136 and payload_len >= 24) {
                // Target at f[62..78], TLLAO option at f[78]: type=2, len=1, mac=f[80..86]
                const target = f[62..78][0..16];
                if (payload_len >= 32 and f[78] == 2 and f[79] == 1) {
                    learnNeighbor(target, f[80..86][0..6]);
                }
            }
            // Echo Request (type 128)
            else if (icmp_type == 128 and payload_len >= 8) {
                // Is it for us?
                var for_us = true;
                for (g_our_ipv6, 0..) |b, i| {
                    if (b != dst_ip[i]) {
                        for_us = false;
                        break;
                    }
                }
                if (for_us) {
                    sendEchoReply(src_mac, src_ip, f[54 .. 54 + payload_len]);
                }
            }
        } else if (next_hdr == 0x11 and frame_len >= 62) {
            // UDP — check for DIPC wire magic
            // UDP header: src_port(2) dst_port(2) len(2) cksum(2) = 8 bytes at f[54]
            const udp_dst_port = be16(f[56..58]);
            const udp_len = be16(f[58..60]);
            if (udp_dst_port == DIPC_UDP_PORT and udp_len >= 8) {
                const udp_payload = f[62..]; // after UDP header
                const udp_payload_len = udp_len - 8;
                if (udp_payload_len >= 4) {
                    const magic = std.mem.readInt(u32, udp_payload[0..4], .little);
                    if (magic == DIPC_WIRE_MAGIC and udp_payload_len >= DIPC_HEADER_SIZE) {
                        // Copy DIPC header+payload into scratch page and route.
                        const copy_len = @min(@as(usize, udp_payload_len), PAGE_SIZE);
                        @memcpy(
                            lib.ptrFrom([*]u8, DIPC_SCRATCH_VA)[0..copy_len],
                            udp_payload[0..copy_len],
                        );

                        const scratch_hdr: *align(1) lib.PageHeader = @ptrFromInt(DIPC_SCRATCH_VA);
                        if (scratch_hdr.version == DIPC_WIRE_VERSION and
                            @as(usize, scratch_hdr.header_len) == DIPC_HEADER_SIZE and
                            isAllNodesMulticast(&scratch_hdr.dst.node.bytes))
                        {
                            for (g_our_ipv6, 0..) |byte, index| {
                                scratch_hdr.dst.node.bytes[index] = byte;
                            }
                        }

                        _ = lib.syscall(SYS_SEND_PAGE, g_dipc_scratch_phys, 0, token);
                    }
                }
            }
        } else if (next_hdr == 0x06 and frame_len >= 54 + tcp.TCP_HEADER_MIN_SIZE) {
            handleTcpFrame(f[0..frame_len], frame_len, token);
        }
    }
}

// Drain all available RX completions.
fn pollRx(token: u64) void {
    const used = rxUsed();
    while (used.idx != g_rx_last_used) {
        const elem = used.ring[@as(usize, g_rx_last_used % QUEUE_SIZE)];
        g_rx_last_used +%= 1;
        const desc_idx = @as(u16, @intCast(elem.id));
        const buf_phys = g_rxbuf_phys + @as(u64, desc_idx) * RX_BUF_SIZE;
        const buf_va = RXBUF_VA + @as(u64, desc_idx) * RX_BUF_SIZE;
        _ = buf_phys;
        if (elem.len > VIRTIO_NET_HDR_SIZE) {
            const frame_va = buf_va + VIRTIO_NET_HDR_SIZE;
            const frame_len = elem.len - @as(u32, VIRTIO_NET_HDR_SIZE);
            handleFrame(frame_va, frame_len, token);
        }
        replenishRx(desc_idx);
    }
}

// Poll the DIPC mailbox for lib.outbound messages to send over the wire.
fn pollDipc(token: u64) bool {
    const page_phys = lib.syscall(lib.SYS_TRY_RECV, 0, 0, token);
    if (page_phys == 0) return false;
    // Map the page into our receive window.
    const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
    if (recv_va == 0) {
        _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
        return true;
    }
    const page_hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
    if (page_hdr.magic == DIPC_WIRE_MAGIC and page_hdr.version == DIPC_WIRE_VERSION) {
        if (page_hdr.dst.endpoint == NETD_ENDPOINT and isLocalNode(&page_hdr.dst.node.bytes)) {
            handleLocalNetdMessage(page_hdr, recv_va);
        } else if (!isLocalNode(&page_hdr.dst.node.bytes)) {
            const dipc_total = lib.DIPC_HEADER_SIZE + @as(usize, page_hdr.payload_len);
            const dipc_page = lib.ptrFrom([*]const u8, recv_va)[0..dipc_total];
            sendDipcPageToWire(&page_hdr.dst.node.bytes, dipc_page);
        }
    }
    _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
    return true;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

var g_token: u64 = 0;

/// Dedicated NIC RX poller thread (spawned by umain after hardware setup).
/// Runs as "netd/1" in the scheduler.  Polls the virtio-net ISR and drains
/// received frames independently of the main DIPC handler.
fn rxPollerLoop() noreturn {
    lib.serialWrite("netd: rx-poller starting\n");
    while (true) {
        // Read and clear the legacy virtio ISR status register.
        _ = inb(g_io_base + VIRTIO_PCI_ISR);
        pollRx(g_token);
        _ = lib.syscall(SYS_YIELD, 0, 0, g_token);
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            asm volatile ("pause");
        }
    }
}

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    g_token = bs.capability_token;
    const token = bs.capability_token;
    g_kernel_control_endpoint = bs.reserved_kernel_control_endpoint;

    lib.serialWrite("netd: starting\n");
    initTcpStack();
    lib.serialWrite("netd: TCP stack initialized\n");

    // Scan PCI for legacy virtio-net (VID=1AF4, DID=1000).
    var found_bus: u8 = 0;
    var found_dev: u8 = 0;
    var found_func: u8 = 0;
    var found = false;
    // Fast-path probe bus 0 dev 2 and dev 3 func 0 (standard QEMU virtio-net locations)
    var dev_try: u8 = 2;
    while (dev_try <= 3) : (dev_try += 1) {
        const probe_vid_did = pciRead(0, dev_try, 0, 0, 4, token);
        const probe_vid: u16 = @truncate(probe_vid_did);
        const probe_did: u16 = @truncate(probe_vid_did >> 16);
        if (probe_vid == 0x1AF4 and (probe_did == 0x1000 or probe_did == 0x1041)) {
            found_bus = 0;
            found_dev = dev_try;
            found_func = 0;
            found = true;
            break;
        }
    }

    if (!found) outer: {
        var bus: u8 = 0;
        while (bus < 2) : (bus += 1) {
            var dev: u8 = 0;
            while (dev < 32) : (dev += 1) {
                const vid_did0 = pciRead(bus, dev, 0, 0, 4, token);
                if (@as(u32, @truncate(vid_did0)) == 0xFFFFFFFF) continue;
                const header_type = @as(u8, @truncate(pciRead(bus, dev, 0, 0x0E, 1, token)));
                const is_multi_function = (header_type & 0x80) != 0;
                var func: u8 = 0;
                const max_func: u8 = if (is_multi_function) 8 else 1;
                while (func < max_func) : (func += 1) {
                    const vid_did = if (func == 0) vid_did0 else pciRead(bus, dev, func, 0, 4, token);
                    if (@as(u32, @truncate(vid_did)) == 0xFFFFFFFF) continue;
                    const vid: u16 = @truncate(vid_did);
                    const did: u16 = @truncate(vid_did >> 16);
                    if (vid == 0x1AF4 and (did == 0x1000 or did == 0x1041)) {
                        found_bus = bus;
                        found_dev = dev;
                        found_func = func;
                        found = true;
                        break :outer;
                    }
                }
            }
        }
    }

    if (!found) {
        lib.serialWrite("netd: no virtio-net found; entering fallback loop\n");
        const dma_base_phys = lib.syscall(SYS_ALLOC_DMA, 12, 0, token);
        if (dma_base_phys != 0) {
            g_dipc_scratch_phys = dma_base_phys + 9 * PAGE_SIZE;
            g_control_outbox_phys = dma_base_phys + 10 * PAGE_SIZE;
        }
        seedSyntheticMac(token, &g_our_mac);
        deriveLinkLocal(&g_our_mac, &g_our_ipv6);
        _ = lib.syscall(SYS_REGISTER, 0, @intFromEnum(lib.ReservedEndpoint.netd), token);
        lib.serialWrite("netd: registered\n");
        while (true) {
            if (!pollDipc(token)) {
                _ = lib.syscall(SYS_YIELD, 0, 0, token);
                asm volatile ("pause");
            }
        }
    }

    lib.serialWrite("netd: virtio-net at ");
    printHex(found_dev);
    lib.serialWrite("\n");

    // Enable PCI I/O space (bit 0) and Bus-Mastering (bit 2) for DMA.
    const pci_cmd = @as(u16, @truncate(pciRead(found_bus, found_dev, found_func, 0x04, 2, token)));
    pciWrite(found_bus, found_dev, found_func, 0x04, 2, pci_cmd | 0x0005, token);

    // Read BAR0 (IO BAR for legacy virtio).
    const bar0_raw: u32 = @truncate(pciRead(found_bus, found_dev, found_func, 0x10, 4, token));
    if ((bar0_raw & 1) != 1) {
        lib.serialWrite("netd: BAR0 is MMIO, not IO — not legacy virtio, giving up\n");
        while (true) asm volatile ("pause");
    }
    g_io_base = @truncate(bar0_raw & 0xFFFC);
    lib.serialWrite("netd: IO base=");
    printHex(g_io_base);
    lib.serialWrite("\n");

    // Reset device.
    outb(g_io_base + VIRTIO_PCI_STATUS, 0);
    outb(g_io_base + VIRTIO_PCI_STATUS, STATUS_ACKNOWLEDGE);
    outb(g_io_base + VIRTIO_PCI_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);
    lib.serialWrite("netd: stage reset\n");

    // Negotiate features (accept none beyond basic).
    lib.serialWrite("netd: stage features\n");
    _ = inl(g_io_base + VIRTIO_PCI_HOST_FEATURES);
    outl(g_io_base + VIRTIO_PCI_GUEST_FEATURES, 0);

    // Allocate 13 contiguous DMA pages: rings(0-8), scratch(9), outbox(10), unused(11), rx-poller stack(12).
    const dma_base_phys = lib.syscall(SYS_ALLOC_DMA, 13, 0, token);
    if (dma_base_phys == 0) {
        lib.serialWrite("netd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    g_rx_ring_phys = dma_base_phys + 0 * PAGE_SIZE;
    g_tx_ring_phys = dma_base_phys + 3 * PAGE_SIZE;
    g_rxbuf_phys = dma_base_phys + 6 * PAGE_SIZE;
    g_txbuf_phys = dma_base_phys + 8 * PAGE_SIZE;
    g_dipc_scratch_phys = dma_base_phys + 9 * PAGE_SIZE;
    g_control_outbox_phys = dma_base_phys + 10 * PAGE_SIZE;
    const rx_poller_stack_phys = dma_base_phys + 11 * PAGE_SIZE;
    _ = rx_poller_stack_phys;

    lib.serialWrite("netd: stage dma ok\n");

    // Setup RX queue (queue 0).
    outw(g_io_base + VIRTIO_PCI_QUEUE_SEL, 0);
    _ = inw(g_io_base + VIRTIO_PCI_QUEUE_SIZE);
    outl(g_io_base + VIRTIO_PCI_QUEUE_ADDR, @truncate(g_rx_ring_phys >> 12));
    lib.serialWrite("netd: stage rx_queue\n");

    // Setup TX queue (queue 1).
    outw(g_io_base + VIRTIO_PCI_QUEUE_SEL, 1);
    _ = inw(g_io_base + VIRTIO_PCI_QUEUE_SIZE);
    outl(g_io_base + VIRTIO_PCI_QUEUE_ADDR, @truncate(g_tx_ring_phys >> 12));
    lib.serialWrite("netd: stage tx_queue\n");

    var hw_mac: [6]u8 = undefined;
    const mac_lo = inl(g_io_base + VIRTIO_NET_MAC_OFFSET);
    const mac_hi = inw(g_io_base + VIRTIO_NET_MAC_OFFSET + 4);
    hw_mac[0] = @truncate(mac_lo);
    hw_mac[1] = @truncate(mac_lo >> 8);
    hw_mac[2] = @truncate(mac_lo >> 16);
    hw_mac[3] = @truncate(mac_lo >> 24);
    hw_mac[4] = @truncate(mac_hi);
    hw_mac[5] = @truncate(mac_hi >> 8);
    var valid_hw_mac = false;
    for (hw_mac) |b| {
        if (b != 0 and b != 0xFF) valid_hw_mac = true;
    }
    if (valid_hw_mac) {
        g_our_mac = hw_mac;
    } else {
        seedSyntheticMac(token, &g_our_mac);
    }
    lib.serialWrite("netd: MAC=");
    writeMacAddressLine(&g_our_mac);

    // Derive link-local IPv6 address from MAC (EUI-64 per RFC 4291).
    deriveLinkLocal(&g_our_mac, &g_our_ipv6);
    lib.serialWrite("netd: link-local IPv6 assigned\n");

    // Mark Virtio device live, THEN fill RX descriptors and notify queue.
    outb(g_io_base + VIRTIO_PCI_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);
    lib.serialWrite("netd: stage driver_ok\n");
    fillRxQueue();

    _ = lib.syscall(SYS_REGISTER, 0, @intFromEnum(lib.ReservedEndpoint.netd), token);
    lib.serialWrite("netd: registered\n");

    lib.serialWrite("netd: publishing kernel node address...\n");
    if (publishKernelNodeAddress(bs, token)) {
        lib.serialWrite("netd: published kernel node address\n");
    } else {
        lib.serialWrite("netd: failed to publish kernel node address\n");
    }

    sendUnsolicitedNA();

    // Spawn dedicated RX poller thread
    const stack_top: u64 = DMA_BASE_VA + 12 * PAGE_SIZE;
    const tid = lib.spawnThread(&rxPollerLoop, stack_top, token);
    if (tid != 0xFFFFFFFF) {
        lib.serialWrite("netd: rx-poller thread spawned tid=");
        printHex(tid);
        lib.serialWrite("\n");
    } else {
        lib.serialWrite("netd: rx-poller spawn failed\n");
    }

    lib.serialWrite("netd: NIC ready, entering DIPC/NIC event loop\n");

    // Send initial peer announcement immediately upon entering event loop
    if (g_control_outbox_phys != 0) {
        _ = sendSelfPeerAnnouncement(&IPV6_ALL_NODES_MULTICAST);
    }

    var poll_counter: u32 = 0;
    while (true) {
        poll_counter +%= 1;
        if (poll_counter % 10 == 0 and g_control_outbox_phys != 0) {
            _ = sendSelfPeerAnnouncement(&IPV6_ALL_NODES_MULTICAST);
        }
        if (!pollDipc(token)) {
            _ = lib.syscall(SYS_YIELD, 0, 0, token);
            asm volatile ("pause");
        }
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
