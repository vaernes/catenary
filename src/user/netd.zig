/// netd — physical NIC driver (legacy virtio-net PCI) + minimal IPv6 stack.
///
/// Syscall ABI used here: rax=op, rbx=arg0, rdx=arg1, r8=token.
/// This matches the kernel's lib.syscallIsr bridge exactly.
const std = @import("std");
const lib = @import("lib.zig");

// ---------------------------------------------------------------------------
// Low-level I/O helpers
// ---------------------------------------------------------------------------

const SYS_PORT_IN = 22;
const SYS_PORT_OUT = 23;

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
    var shift: u6 = 60;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        const c = hex[nibble];
        _ = lib.syscall(lib.SYS_SERIAL_WRITE, @intFromPtr(&c), 1, 0);
        if (shift == 0) break;
        shift -= 4;
    }
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
// Syscall interface
// ---------------------------------------------------------------------------

const SYS_LOG = 1;
const SYS_REGISTER = 2;
const SYS_RECV = 3; // returns page_phys or 0
const SYS_FREE_PAGE = 4; // arg0=page_phys or DIPC_RECV_VA
const SYS_ALLOC_DMA = 5; // arg0=num_pages, arg1=slot_start → phys_base
const SYS_SEND_PAGE = 6; // arg0=dma_phys → route DIPC copy
const SYS_MAP_IO = 7; // not used by netd (IO BAR => IO ports)
const SYS_FB_DRAW = 16;
const SYS_MAP_RECV = 17; // arg0=page_phys → maps at DIPC_RECV_VA, returns it
const SYS_YIELD = 24;

const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;
const PAGE_SIZE: u64 = 4096;

// PCI config read via kernel lib.syscall 13
fn pciRead(bus: u8, dev: u8, func: u8, off: u8, size: u8, token: u64) u64 {
    const addr = (@as(u64, bus) << 24) | (@as(u64, dev) << 16) | (@as(u64, func) << 8) | @as(u64, off);
    return lib.syscall(13, addr, (@as(u64, size) << 32), token);
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

// Virtqueue entry sizes for q=64
const QUEUE_SIZE: u16 = 64;
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
// Slot 0-1: RX ring (2 pages: slot0=desc+avail, slot1=used)
// Slot 2-3: TX ring
// Slot 4-5: RX frame buffers (2 pages = 8 × 1024-byte buffers)
// Slot 6:   TX frame buffer
// Slot 7-8: DIPC routing scratch page (one page reused)
const RX_DESC_VA: u64 = DMA_BASE_VA + 0 * PAGE_SIZE;
const RX_AVAIL_VA: u64 = DMA_BASE_VA + 0 * PAGE_SIZE + @sizeOf([QUEUE_SIZE]VirtqDesc);
const RX_USED_VA: u64 = DMA_BASE_VA + 1 * PAGE_SIZE;
const TX_DESC_VA: u64 = DMA_BASE_VA + 2 * PAGE_SIZE;
const TX_AVAIL_VA: u64 = DMA_BASE_VA + 2 * PAGE_SIZE + @sizeOf([QUEUE_SIZE]VirtqDesc);
const TX_USED_VA: u64 = DMA_BASE_VA + 3 * PAGE_SIZE;
const RXBUF_VA: u64 = DMA_BASE_VA + 4 * PAGE_SIZE;
const TXBUF_VA: u64 = DMA_BASE_VA + 6 * PAGE_SIZE;
const DIPC_SCRATCH_VA: u64 = DMA_BASE_VA + 7 * PAGE_SIZE;
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
    while (used.idx == g_tx_last_used and spin > 0) spin -= 1;
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
    var frame: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;
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

    return lib.syscall(SYS_SEND_PAGE, g_dipc_scratch_phys, 0, token) == 0;
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
                    const magic: u32 = (@as(u32, udp_payload[0]) << 24) |
                        (@as(u32, udp_payload[1]) << 16) |
                        (@as(u32, udp_payload[2]) << 8) |
                        udp_payload[3];
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
                            scratch_hdr.dst.endpoint == g_kernel_control_endpoint and
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
fn pollDipc(token: u64) void {
    const page_phys = lib.syscall(SYS_RECV, 0, 0, token);
    if (page_phys == 0) return;
    // Map the page into our receive window.
    const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
    if (recv_va == 0) {
        _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
        return;
    }
    // Read DIPC destination: if remote, encapsulate into IPv6 UDP and TX.
    const hdr: [*]const u8 = lib.ptrFrom([*]const u8, recv_va);
    // Magic check (bytes 0-3, little-endian in memory)
    const magic: u32 = @as(u32, hdr[0]) | (@as(u32, hdr[1]) << 8) | (@as(u32, hdr[2]) << 16) | (@as(u32, hdr[3]) << 24);
    if (magic == DIPC_WIRE_MAGIC) {
        // dst node is at hdr offset 24+16=40 (after magic/ver/hlen/plen/auth_tag/src_node/src_ep/dst_node)
        // Actually: PageHeader layout: magic(4)+ver(2)+hlen(2)+plen(4)+auth_tag(8)+src(24)+dst(24)
        // src = bytes 20..44 (Address = Ipv6Addr(16) + endpoint(8) = 24 bytes)
        // dst = bytes 44..68
        const dst_node: *const [16]u8 = @ptrCast(hdr[44..60]);
        // Check if destination is loopback (local) — already routed by kernel, so this
        // would be a remote node message. A non-loopback node means send over wire.
        var is_loopback = true;
        for (dst_node[0..15]) |b| if (b != 0) {
            is_loopback = false;
            break;
        };
        if (!is_loopback or dst_node[15] != 1) {
            // Build IPv6 UDP frame targeting dst_node.
            const payload_len_hdr: u32 = @as(u32, hdr[8]) | (@as(u32, hdr[9]) << 8) | (@as(u32, hdr[10]) << 16) | (@as(u32, hdr[11]) << 24);
            const dipc_total = DIPC_HEADER_SIZE + @as(usize, payload_len_hdr);
            if (dipc_total <= 1400) {
                // Ethernet(14) + IPv6(40) + UDP(8) + DIPC = total frame
                const frame_len = 14 + 40 + 8 + dipc_total;
                var frame: [PAGE_SIZE]u8 = [_]u8{0} ** PAGE_SIZE;

                // Determine Ethernet destination MAC:
                // - IPv6 multicast ff02::1 → 33:33:00:00:00:01
                // - other multicast (ff:*) → 33:33 + last 4 bytes
                // - unicast → neighbor cache lookup; fallback to broadcast + send NDP NS
                if (dst_node[0] == 0xff) {
                    // Ethernet multicast MAC: 33:33 + last 4 bytes of IPv6 dst
                    frame[0] = 0x33;
                    frame[1] = 0x33;
                    frame[2] = dst_node[12];
                    frame[3] = dst_node[13];
                    frame[4] = dst_node[14];
                    frame[5] = dst_node[15];
                } else if (lookupNeighbor(dst_node)) |resolved_mac| {
                    @memcpy(frame[0..6], &resolved_mac);
                } else {
                    // Unknown unicast MAC — send Ethernet broadcast and trigger NDP resolution.
                    @memset(frame[0..6], 0xFF);
                    sendNeighborSolicitation(dst_node);
                }
                @memcpy(frame[6..12], &g_our_mac);
                frame[12] = 0x86;
                frame[13] = 0xDD;
                // IPv6
                frame[14] = 0x60;
                put_be16(frame[18..20], @as(u16, @intCast(8 + dipc_total)));
                frame[20] = 0x11;
                frame[21] = 255; // UDP, hop=255
                @memcpy(frame[22..38], &g_our_ipv6);
                @memcpy(frame[38..54], dst_node);
                // UDP
                put_be16(frame[54..56], DIPC_UDP_PORT); // src port
                put_be16(frame[56..58], DIPC_UDP_PORT); // dst port
                put_be16(frame[58..60], @as(u16, @intCast(8 + dipc_total)));
                // checksum = 0 (optional for IPv6 UDP, acceptable here)
                // DIPC payload
                @memcpy(frame[62 .. 62 + dipc_total], lib.ptrFrom([*]const u8, recv_va)[0..dipc_total]);
                txFrame(frame[0..frame_len]);
            }
        }
    }
    _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

var g_token: u64 = 0;

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    g_token = bs.capability_token;
    const token = bs.capability_token;
    g_kernel_control_endpoint = bs.reserved_kernel_control_endpoint;

    lib.serialWrite("netd: starting\n");

    // Scan PCI for legacy virtio-net (VID=1AF4, DID=1000).
    var found_bus: u8 = 0;
    var found_dev: u8 = 0;
    var found_func: u8 = 0;
    var found = false;
    outer: {
        var bus: u8 = 0;
        while (bus < 8) : (bus += 1) {
            var dev: u8 = 0;
            while (dev < 32) : (dev += 1) {
                var func: u8 = 0;
                while (func < 8) : (func += 1) {
                    const vid_did = pciRead(bus, dev, func, 0, 4, token);
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
        lib.serialWrite("netd: no virtio-net found; entering idle loop\n");
        _ = lib.syscall(SYS_REGISTER, 0, 0, token);
        lib.serialWrite("netd: registered\n");
        while (true) {
            _ = lib.syscall(SYS_RECV, 0, 0, token);
            asm volatile ("pause");
        }
    }

    lib.serialWrite("netd: virtio-net at ");
    printHex(found_dev);
    lib.serialWrite("\n");

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

    // Negotiate features (accept none beyond basic).
    _ = inl(g_io_base + VIRTIO_PCI_HOST_FEATURES);
    outl(g_io_base + VIRTIO_PCI_GUEST_FEATURES, 0);

    // Allocate DMA memory for rings.
    g_rx_ring_phys = lib.syscall(SYS_ALLOC_DMA, 2, 0, token);
    g_tx_ring_phys = lib.syscall(SYS_ALLOC_DMA, 2, 2, token);
    g_rxbuf_phys = lib.syscall(SYS_ALLOC_DMA, 2, 4, token);
    g_txbuf_phys = lib.syscall(SYS_ALLOC_DMA, 1, 6, token);
    g_dipc_scratch_phys = lib.syscall(SYS_ALLOC_DMA, 1, 7, token);

    if (g_rx_ring_phys == 0 or g_tx_ring_phys == 0 or
        g_rxbuf_phys == 0 or g_txbuf_phys == 0 or g_dipc_scratch_phys == 0)
    {
        lib.serialWrite("netd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    // Setup RX queue (queue 0).
    outw(g_io_base + VIRTIO_PCI_QUEUE_SEL, 0);
    const rx_qsz = inw(g_io_base + VIRTIO_PCI_QUEUE_SIZE);
    _ = rx_qsz;
    outl(g_io_base + VIRTIO_PCI_QUEUE_ADDR, @truncate(g_rx_ring_phys >> 12));

    // Setup TX queue (queue 1).
    outw(g_io_base + VIRTIO_PCI_QUEUE_SEL, 1);
    const tx_qsz = inw(g_io_base + VIRTIO_PCI_QUEUE_SIZE);
    _ = tx_qsz;
    outl(g_io_base + VIRTIO_PCI_QUEUE_ADDR, @truncate(g_tx_ring_phys >> 12));

    // Enable device.
    outb(g_io_base + VIRTIO_PCI_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);

    // Read MAC address from config space.
    for (0..6) |i| {
        g_our_mac[i] = inb(g_io_base + VIRTIO_NET_MAC_OFFSET + @as(u16, @intCast(i)));
    }
    lib.serialWrite("netd: MAC=");
    writeMacAddressLine(&g_our_mac);

    // Derive link-local IPv6 address from MAC (EUI-64 per RFC 4291).
    deriveLinkLocal(&g_our_mac, &g_our_ipv6);
    lib.serialWrite("netd: link-local IPv6 assigned\n");

    if (publishKernelNodeAddress(bs, token)) {
        lib.serialWrite("netd: published kernel node address\n");
    } else {
        lib.serialWrite("netd: failed to publish kernel node address\n");
    }

    // Register after publishing the canonical node address so later service
    // registration broadcasts use the updated kernel-local identity.
    _ = lib.syscall(SYS_REGISTER, 0, 0, token);
    lib.serialWrite("netd: registered\n");

    // Pre-fill RX descriptors.
    fillRxQueue();

    lib.serialWrite("netd: NIC ready, entering DIPC/NIC event loop\n");

    // Main event loop.
    var isr_poll: u32 = 0;
    while (true) {
        isr_poll += 1;
        if (isr_poll >= 1000) {
            isr_poll = 0;
            // Poll NIC ISR status (clears on read).
            const isr = inb(g_io_base + VIRTIO_PCI_ISR);
            if (isr & 1 != 0) {
                pollRx(token);
            }
        }
        pollDipc(token);
        _ = lib.syscall(SYS_YIELD, 0, 0, token);
        asm volatile ("pause");
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
