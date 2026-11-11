const std = @import("std");
const lib = @import("lib.zig");

/// configd — OS Configuration Application
///
/// Provides a text-mode UI rendered via windowd onto the kernel framebuffer.
/// Displays:
///   - Local node IPv6 address (from bootstrap)
///   - Cluster node registry (received via registry_sync DIPC from other nodes)
///   - MicroVM list with status (launched by clusterd)
///   - Network interface status (from netd heartbeats)
///
/// The user can issue commands by pressing keys routed via inputd.
/// Supported commands (single keypress):
///   'l' — Launch a new MicroVM via clusterd (sends create_microvm DIPC)
///   'r' — Refresh display
///   'q' — Shutdown request (idles)
const configd_proto = @import("protocols/configd_protocol.zig");
const netd_proto = @import("protocols/netd_protocol.zig");
const partition_metadata = @import("protocols/partition_metadata.zig");
const storaged_proto = @import("protocols/storaged_protocol.zig");

// ---------------------------------------------------------------------------
// Syscall shim
// ---------------------------------------------------------------------------

const SYS_REGISTER = lib.SYS_REGISTER;
const SYS_TRY_RECV = lib.SYS_TRY_RECV;
const SYS_FREE_PAGE = lib.SYS_FREE_PAGE;
const SYS_ALLOC_DMA = lib.SYS_ALLOC_DMA;
const SYS_SEND_PAGE = lib.SYS_SEND_PAGE;
const SYS_GET_KEY = lib.SYS_GET_KEY;
const SYS_FB_DRAW = lib.SYS_FB_DRAW;
const SYS_MAP_RECV = lib.SYS_MAP_RECV;

// ---------------------------------------------------------------------------
// Memory layout constants
// ---------------------------------------------------------------------------

const USER_BOOTSTRAP_VADDR: usize = lib.USER_BOOTSTRAP_VADDR;
const DMA_BASE_VA: u64 = lib.DMA_BASE_VA;
const DIPC_RECV_VA: u64 = lib.DIPC_RECV_VA;
const PAGE_SIZE: u64 = lib.PAGE_SIZE;

// DMA slot layout (each slot is one 4 KiB page):
//   slot 0: framebuffer text scratch (send via SYS_FB_DRAW)
//   slot 1: outgoing DIPC messages (send via SYS_SEND_PAGE)
const DMA_TEXT_SLOT: u64 = DMA_BASE_VA;
const DMA_DIPC_SLOT: u64 = DMA_BASE_VA + PAGE_SIZE;

// ---------------------------------------------------------------------------
// Bootstrap descriptor (mirrors service_bootstrap.Descriptor)
// ---------------------------------------------------------------------------

const BootstrapDescriptor = lib.BootstrapDescriptor;

fn sendVmSnapshotRequest(bs: *const BootstrapDescriptor, token: u64, dma_phys: u64) bool {
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_DIPC_SLOT);
    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @intCast(lib.DIPC_HEADER_SIZE),
        .payload_len = @intCast(lib.CONTROL_HEADER_SIZE),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = EP_CONFIGD },
        .dst = .{ .node = local_node, .endpoint = @backingInt(lib.ReservedEndpoint.kernel_control) },
    };
    const control: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    control.* = .{ .op = .list_microvms, .payload_len = 0 };
    return lib.syscall(SYS_SEND_PAGE, dma_phys, 0, token) == 0;
}

fn sendNetdConfig(
    bs: *const BootstrapDescriptor,
    token: u64,
    dma_phys: u64,
    op: netd_proto.Op,
    payload: []const u8,
) bool {
    const payload_len = @sizeOf(netd_proto.NetdHeader) + payload.len;
    if (lib.DIPC_HEADER_SIZE + payload_len > lib.PAGE_SIZE) return false;

    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_DIPC_SLOT);
    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @intCast(lib.DIPC_HEADER_SIZE),
        .payload_len = @intCast(payload_len),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = EP_CONFIGD },
        .dst = .{ .node = local_node, .endpoint = EP_NETD },
    };
    const netd_header: *align(1) netd_proto.NetdHeader =
        @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    netd_header.* = .{ .op = op };
    if (payload.len > 0) {
        @memcpy(
            scratch[lib.DIPC_HEADER_SIZE + @sizeOf(netd_proto.NetdHeader) ..][0..payload.len],
            payload,
        );
    }
    return lib.syscall(SYS_SEND_PAGE, dma_phys, 0, token) == 0;
}

fn sendStoragedVmDiskConfig(
    bs: *const BootstrapDescriptor,
    token: u64,
    dma_phys: u64,
    req_type: storaged_proto.ReqType,
    vmid: u32,
) bool {
    const start_lba = partition_metadata.vmDiskStartLba(vmid) orelse return false;
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_DIPC_SLOT);
    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @intCast(lib.DIPC_HEADER_SIZE),
        .payload_len = @intCast(@sizeOf(storaged_proto.BlkRequest)),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = EP_CONFIGD },
        .dst = .{ .node = local_node, .endpoint = EP_STORAGED },
    };
    const req: *align(1) storaged_proto.BlkRequest =
        @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    req.* = .{
        .req_type = @backingInt(req_type),
        .sector = if (req_type == .attach_vm_disk) start_lba else 0,
        .vmid = vmid,
        .chain_head = 0,
        .data_len = if (req_type == .attach_vm_disk) @intCast(partition_metadata.VM_DISK_SECTORS) else 0,
        .data_hpa = 0,
    };
    return lib.syscall(SYS_SEND_PAGE, dma_phys, 0, token) == 0;
}

fn sendLocalConfigReply(token: u64, dma_phys: u64, op: configd_proto.Op, payload: []const u8) bool {
    const payload_len = @sizeOf(configd_proto.ConfigdHeader) + payload.len;
    if (lib.DIPC_HEADER_SIZE + payload_len > lib.PAGE_SIZE) return false;

    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_DIPC_SLOT);
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @intCast(lib.DIPC_HEADER_SIZE),
        .payload_len = @intCast(payload_len),
        .auth_tag = 0,
        .src = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = EP_CONFIGD },
        .dst = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = EP_WINDOWD },
    };
    const config_header: *align(1) configd_proto.ConfigdHeader =
        @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    config_header.* = .{ .op = op, .payload_len = @intCast(payload.len) };
    if (payload.len > 0) {
        @memcpy(scratch[lib.DIPC_HEADER_SIZE + @sizeOf(configd_proto.ConfigdHeader) ..][0..payload.len], payload);
    }
    return lib.syscall(SYS_SEND_PAGE, dma_phys, 0, token) == 0;
}

fn findNetworkPort(vmid: u32) ?*NetworkPort {
    for (&network_ports) |*port| {
        if (port.used and port.vmid == vmid) return port;
    }
    return null;
}

fn vmIsRunning(snapshot: *align(1) const lib.VmSnapshotListPayload, vmid: u32) bool {
    const count = @min(@as(usize, snapshot.count), snapshot.entries.len);
    for (snapshot.entries[0..count]) |entry| {
        if (entry.instance_id == vmid and entry.state == VM_STATE_RUNNING) return true;
    }
    return false;
}

fn requestPortAttach(bs: *const BootstrapDescriptor, token: u64, dma_phys: u64, port: *NetworkPort) void {
    const request = netd_proto.SwitchPortAttachPayload{
        .vmid = port.vmid,
        .segment = DEFAULT_LOCAL_SEGMENT,
        .mac = netd_proto.hostAssignedMac(port.vmid),
        .ipv4_count = 0,
        .ipv6_count = 0,
    };
    if (sendNetdConfig(bs, token, dma_phys, .switch_port_attach, std.mem.asBytes(&request))) {
        port.state = .attach_pending;
    } else {
        lib.serialWrite("configd: vNIC attach request send failed\n");
    }
}

fn progressPendingBindings(bs: *const BootstrapDescriptor, token: u64, dma_phys: u64, port: *NetworkPort) void {
    const request = port.pending_bindings orelse return;
    if (port.pending_binding_reply) |reply| {
        if (sendLocalConfigReply(token, dma_phys, .local_bindings_reply, std.mem.asBytes(&reply))) {
            port.pending_bindings = null;
            port.pending_binding_reply = null;
            if (reply.status == .ok) lib.serialWrite("configd: vNIC address bindings updated (default-deny)\n");
        }
    } else {
        _ = sendNetdConfig(bs, token, dma_phys, .switch_bindings_replace, std.mem.asBytes(&request));
    }
}

fn reconcileNetworkPorts(
    bs: *const BootstrapDescriptor,
    token: u64,
    dma_phys: u64,
    snapshot: *align(1) const lib.VmSnapshotListPayload,
) void {
    const count = @min(@as(usize, snapshot.count), snapshot.entries.len);
    for (snapshot.entries[0..count]) |entry| {
        if (entry.instance_id == 0 or entry.state != VM_STATE_RUNNING) continue;
        if (findNetworkPort(entry.instance_id) != null) continue;

        var free_port: ?*NetworkPort = null;
        for (&network_ports) |*port| {
            if (!port.used) {
                free_port = port;
                break;
            }
        }
        const port = free_port orelse {
            lib.serialWrite("configd: vNIC table full; VM remains unconfigured\n");
            continue;
        };
        port.* = .{ .used = true, .vmid = entry.instance_id };
    }

    for (&network_ports) |*port| {
        if (!port.used) continue;
        const is_running = vmIsRunning(snapshot, port.vmid);
        if (is_running) {
            if (!port.disk_attached) {
                if (sendStoragedVmDiskConfig(bs, token, dma_phys, .attach_vm_disk, port.vmid)) {
                    port.disk_attached = true;
                    lib.serialWrite("configd: per-VM disk attached\n");
                }
            }
            if (port.state == .unused or port.state == .attach_pending) {
                requestPortAttach(bs, token, dma_phys, port);
            } else if (port.state == .attached) {
                progressPendingBindings(bs, token, dma_phys, port);
            }
        } else {
            if (port.disk_attached) {
                if (sendStoragedVmDiskConfig(bs, token, dma_phys, .detach_vm_disk, port.vmid)) {
                    port.disk_attached = false;
                    lib.serialWrite("configd: per-VM disk detached\n");
                }
            }
            if (port.state == .attached or port.state == .detach_pending) {
                if (port.pending_bindings) |request| {
                    const reply = port.pending_binding_reply orelse configd_proto.LocalBindingsReply{
                        .request_id = request.request_id,
                        .vmid = request.vmid,
                        .status = .stale,
                        .generation = request.generation,
                        .policy_revision = 0,
                    };
                    _ = sendLocalConfigReply(token, dma_phys, .local_bindings_reply, std.mem.asBytes(&reply));
                    port.pending_bindings = null;
                    port.pending_binding_reply = null;
                }
                port.pending_rule = null;
                const request = netd_proto.SwitchPortDetachPayload{
                    .vmid = port.vmid,
                    .generation = port.generation,
                };
                if (sendNetdConfig(bs, token, dma_phys, .switch_port_detach, std.mem.asBytes(&request))) {
                    port.state = .detach_pending;
                } else {
                    lib.serialWrite("configd: vNIC detach request send failed\n");
                }
            } else if (!port.disk_attached) {
                port.* = .{};
            }
        }
    }
}

fn handleVmSnapshot(
    bs: *const BootstrapDescriptor,
    token: u64,
    dma_phys: u64,
    recv_va: u64,
) void {
    const snapshot: *align(1) const lib.VmSnapshotListPayload =
        @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
    lib.serialWrite("configd: VM lifecycle snapshot received\n");
    reconcileNetworkPorts(bs, token, dma_phys, snapshot);
}

fn handleNetdConfigAck(bs: *const BootstrapDescriptor, recv_va: u64, payload_len: usize) void {
    const page_header: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
    const netd_header: *align(1) const netd_proto.NetdHeader =
        @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
    if (!isNetdConfigAckEnvelope(page_header, netd_header, payload_len, &bs.local_node)) {
        lib.serialWrite("configd: invalid netd configuration response length\n");
        return;
    }
    const ack: *align(1) const netd_proto.SwitchConfigAckPayload =
        @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(netd_proto.NetdHeader));
    const port = findNetworkPort(ack.vmid) orelse return;
    switch (applySwitchConfigAck(port, ack)) {
        .attached => lib.serialWrite("configd: host-assigned vNIC attached (default-deny)\n"),
        .attach_rejected => lib.serialWrite("configd: vNIC attach rejected by netd\n"),
        .detached => lib.serialWrite("configd: vNIC detached\n"),
        .detach_rejected => lib.serialWrite("configd: vNIC detach rejected by netd\n"),
        .ignored => {},
    }
}

fn beginSwitchRule(port: *NetworkPort, request: *align(1) const netd_proto.SwitchRuleUpdatePayload) netd_proto.SwitchConfigStatus {
    if (request.request_id == 0 or request.vmid == 0 or request._pad != 0 or request._reserved != 0 or
        request.action > netd_proto.SWITCH_RULE_CLEAR)
    {
        return .invalid;
    }
    if (!port.used or port.state != .attached or request.vmid != port.vmid or
        request.generation != port.generation)
    {
        return .stale;
    }
    if (port.pending_rule != null or port.pending_bindings != null) return .no_capacity;
    if (request.expected_revision != port.policy_revision) return .stale;
    port.pending_rule = request.*;
    return .ok;
}

fn applySwitchRuleAck(port: *NetworkPort, ack: *align(1) const netd_proto.SwitchBindingsAckPayload) bool {
    const pending = port.pending_rule orelse return false;
    if (!port.used or port.state != .attached or ack.vmid != port.vmid or
        ack.request_id != pending.request_id or ack.generation != pending.generation or
        ack._reserved != 0)
    {
        return false;
    }
    const status = @as(*align(1) const u16, @ptrCast(&ack.status)).*;
    if (status > @backingInt(netd_proto.SwitchConfigStatus.no_capacity)) return false;
    if (status == @backingInt(netd_proto.SwitchConfigStatus.ok)) {
        const next_revision = std.math.add(u64, pending.expected_revision, 1) catch return false;
        if (ack.policy_revision != next_revision) return false;
        port.policy_revision = ack.policy_revision;
    } else if (ack.policy_revision != 0) {
        return false;
    }
    port.pending_rule = null;
    return true;
}

fn handleNetdBindingsAck(bs: *const BootstrapDescriptor, token: u64, dma_phys: u64, recv_va: u64, payload_len: usize) void {
    const page_header: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
    const netd_header: *align(1) const netd_proto.NetdHeader =
        @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
    if (isNetdAckEnvelope(page_header, netd_header, payload_len, &bs.local_node, .switch_rule_ack, @sizeOf(netd_proto.SwitchBindingsAckPayload))) {
        const rule_ack: *align(1) const netd_proto.SwitchBindingsAckPayload =
            @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(netd_proto.NetdHeader));
        const rule_port = findNetworkPort(rule_ack.vmid) orelse return;
        if (!applySwitchRuleAck(rule_port, rule_ack)) return;
        _ = sendLocalConfigReply(token, dma_phys, .local_rule_reply, std.mem.asBytes(rule_ack));
        if (rule_ack.status == .ok) lib.serialWrite("configd: vNIC firewall rule applied (default-deny)\n");
        return;
    }
    if (!isNetdAckEnvelope(page_header, netd_header, payload_len, &bs.local_node, .switch_bindings_ack, @sizeOf(netd_proto.SwitchBindingsAckPayload))) return;
    const ack: *align(1) const netd_proto.SwitchBindingsAckPayload =
        @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(netd_proto.NetdHeader));
    const port = findNetworkPort(ack.vmid) orelse return;
    if (!applySwitchBindingsAck(port, ack)) return;
    progressPendingBindings(bs, token, dma_phys, port);
}

fn isNetdConfigAckEnvelope(
    page: *align(1) const lib.PageHeader,
    netd: *align(1) const netd_proto.NetdHeader,
    payload_len: usize,
    local_node: *const [16]u8,
) bool {
    return isNetdAckEnvelope(page, netd, payload_len, local_node, .switch_config_ack, @sizeOf(netd_proto.SwitchConfigAckPayload));
}

fn isNetdAckEnvelope(
    page: *align(1) const lib.PageHeader,
    netd: *align(1) const netd_proto.NetdHeader,
    payload_len: usize,
    local_node: *const [16]u8,
    expected_op: netd_proto.Op,
    body_size: usize,
) bool {
    const loopback = lib.Ipv6Addr.loopback();
    return payload_len == @sizeOf(netd_proto.NetdHeader) + body_size and
        page.magic == lib.WireMagic and
        page.version == lib.WireVersion and
        page.header_len == lib.DIPC_HEADER_SIZE and
        page.payload_len == payload_len and
        page.src.endpoint == EP_NETD and
        page.dst.endpoint == EP_CONFIGD and
        std.mem.eql(u8, &page.src.node.bytes, &loopback.bytes) and
        std.mem.eql(u8, &page.dst.node.bytes, local_node) and
        netd.magic == netd_proto.MAGIC and
        netd.version == netd_proto.VERSION and
        @as(*align(1) const u16, @ptrCast(&netd.op)).* == @backingInt(expected_op);
}

fn isLocalWindowdRequest(page: *align(1) const lib.PageHeader) bool {
    const loopback = lib.Ipv6Addr.loopback();
    return page.magic == lib.WireMagic and
        page.version == lib.WireVersion and
        page.header_len == lib.DIPC_HEADER_SIZE and
        page.src.endpoint == EP_WINDOWD and
        page.dst.endpoint == EP_CONFIGD and
        std.mem.eql(u8, &page.src.node.bytes, &loopback.bytes) and
        std.mem.eql(u8, &page.dst.node.bytes, &loopback.bytes);
}

fn handleLocalSwitchAdmin(bs: *const BootstrapDescriptor, token: u64, dma_phys: u64, recv_va: u64) void {
    const page: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
    if (!isLocalWindowdRequest(page) or page.payload_len < @sizeOf(configd_proto.ConfigdHeader)) return;
    const header: *align(1) const configd_proto.ConfigdHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
    if (header.magic != configd_proto.MAGIC or header.version != configd_proto.VERSION or
        header.payload_len != page.payload_len - @sizeOf(configd_proto.ConfigdHeader)) return;
    const op = @as(*align(1) const u16, @ptrCast(&header.op)).*;
    const body_va = recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(configd_proto.ConfigdHeader);
    if (op == @backingInt(configd_proto.Op.local_port_status)) {
        if (header.payload_len != @sizeOf(configd_proto.LocalPortStatusRequest)) return;
        const request: *align(1) const configd_proto.LocalPortStatusRequest = @ptrFromInt(body_va);
        const reply = makeLocalPortStatus(findNetworkPort(request.vmid), request);
        _ = sendLocalConfigReply(token, dma_phys, .local_port_status_reply, std.mem.asBytes(&reply));
    } else if (op == @backingInt(configd_proto.Op.local_bindings_replace)) {
        if (header.payload_len != @sizeOf(configd_proto.LocalBindingsRequest)) return;
        const request: *align(1) const configd_proto.LocalBindingsRequest = @ptrFromInt(body_va);
        const port = findNetworkPort(request.vmid);
        const status = if (port) |found| beginSwitchBindings(found, request) else netd_proto.SwitchConfigStatus.stale;
        if (status == .ok) {
            progressPendingBindings(bs, token, dma_phys, port.?);
        } else {
            const reply = configd_proto.LocalBindingsReply{
                .request_id = request.request_id,
                .vmid = request.vmid,
                .status = status,
                .generation = request.generation,
                .policy_revision = 0,
            };
            _ = sendLocalConfigReply(token, dma_phys, .local_bindings_reply, std.mem.asBytes(&reply));
        }
    } else if (op == @backingInt(configd_proto.Op.local_rule_update)) {
        if (header.payload_len != @sizeOf(configd_proto.LocalRuleRequest)) return;
        const request: *align(1) const configd_proto.LocalRuleRequest = @ptrFromInt(body_va);
        const port = findNetworkPort(request.vmid);
        const status = if (port) |found| beginSwitchRule(found, request) else netd_proto.SwitchConfigStatus.stale;
        if (status == .ok) {
            if (!sendNetdConfig(bs, token, dma_phys, .switch_rule_update, std.mem.asBytes(request))) {
                port.?.pending_rule = null;
                lib.serialWrite("configd: vNIC rule request send failed\n");
            }
        } else {
            const reply = configd_proto.LocalRuleReply{
                .request_id = request.request_id,
                .vmid = request.vmid,
                .status = status,
                .generation = request.generation,
                .policy_revision = 0,
            };
            _ = sendLocalConfigReply(token, dma_phys, .local_rule_reply, std.mem.asBytes(&reply));
        }
    }
}

// ---------------------------------------------------------------------------
// Shared DIPC / control protocol constants
// ---------------------------------------------------------------------------

const EP_CLUSTERD: u64 = 7;
const EP_WINDOWD: u64 = 9;
const EP_CONFIGD: u64 = 10;
const EP_NETD: u64 = @backingInt(lib.ReservedEndpoint.netd);
const EP_STORAGED: u64 = @backingInt(lib.ReservedEndpoint.storaged);
const VM_STATE_RUNNING: u8 = 2;
const DEFAULT_LOCAL_SEGMENT: u64 = 1;
const SNAPSHOT_INTERVAL_TICKS: u32 = 20_000;
const SNAPSHOT_TIMEOUT_TICKS: u32 = 100_000;

// ---------------------------------------------------------------------------
// Intra-service state
// ---------------------------------------------------------------------------

const MAX_CLUSTER_NODES = 8;
const MAX_VMS = 8;

const NodeEntry = struct {
    used: bool = false,
    addr: [16]u8 = @splat(0),
    services: u16 = 0,
};

const VmEntry = struct {
    used: bool = false,
    instance_id: u32 = 0,
    mem_pages: u32 = 0,
};

var cluster_nodes: [MAX_CLUSTER_NODES]NodeEntry = @splat(.{});
var vms: [MAX_VMS]VmEntry = @splat(.{});
var next_vmid: u32 = 1;

const NetworkPortState = enum {
    unused,
    attach_pending,
    attached,
    detach_pending,
};

const NetworkPort = struct {
    used: bool = false,
    vmid: u32 = 0,
    disk_attached: bool = false,
    generation: u64 = 0,
    policy_revision: u64 = 0,
    state: NetworkPortState = .unused,
    pending_bindings: ?netd_proto.SwitchBindingsReplacePayload = null,
    pending_binding_reply: ?netd_proto.SwitchBindingsAckPayload = null,
    /// Operator firewall change forwarded to netd and awaiting its ack. It is
    /// sent once (rule updates are not idempotent); a lost ack surfaces in
    /// windowd as an indeterminate timeout rather than a blind retry.
    pending_rule: ?netd_proto.SwitchRuleUpdatePayload = null,
};

var network_ports: [MAX_VMS]NetworkPort = @splat(.{});

const ConfigAckTransition = enum {
    ignored,
    attached,
    attach_rejected,
    detached,
    detach_rejected,
};

fn applySwitchConfigAck(port: *NetworkPort, ack: *align(1) const netd_proto.SwitchConfigAckPayload) ConfigAckTransition {
    if (!port.used or ack.vmid != port.vmid) return .ignored;

    const request_op = @as(*align(1) const u16, @ptrCast(&ack.request_op)).*;
    const status = @as(*align(1) const u16, @ptrCast(&ack.status)).*;
    if (request_op == @backingInt(netd_proto.Op.switch_port_attach)) {
        if (port.state != .attach_pending) return .ignored;
        if (status != @backingInt(netd_proto.SwitchConfigStatus.ok)) {
            if (status > @backingInt(netd_proto.SwitchConfigStatus.no_capacity)) return .ignored;
            port.* = .{};
            return .attach_rejected;
        }
        if (ack.generation == 0 or ack.policy_revision == 0) return .ignored;
        port.generation = ack.generation;
        port.policy_revision = ack.policy_revision;
        port.state = .attached;
        return .attached;
    }
    if (request_op == @backingInt(netd_proto.Op.switch_port_detach)) {
        if (port.state != .detach_pending or ack.generation != port.generation) return .ignored;
        if (status == @backingInt(netd_proto.SwitchConfigStatus.ok)) {
            port.* = .{};
            return .detached;
        }
        if (status > @backingInt(netd_proto.SwitchConfigStatus.no_capacity)) return .ignored;
        port.state = .attached;
        return .detach_rejected;
    }
    return .ignored;
}

fn makeLocalPortStatus(port: ?*const NetworkPort, request: *align(1) const configd_proto.LocalPortStatusRequest) configd_proto.LocalPortStatusReply {
    var reply = configd_proto.LocalPortStatusReply{
        .request_id = request.request_id,
        .vmid = request.vmid,
        .status = .stale,
        .generation = 0,
        .policy_revision = 0,
    };
    if (request.request_id == 0 or request.vmid == 0 or request._reserved != 0) {
        reply.status = .invalid;
    } else if (port) |found| {
        if (found.used and found.state == .attached) {
            reply.status = if (found.pending_bindings == null and found.pending_rule == null) .ok else .no_capacity;
            reply.generation = found.generation;
            reply.policy_revision = found.policy_revision;
        }
    }
    return reply;
}

fn beginSwitchBindings(port: *NetworkPort, request: *align(1) const netd_proto.SwitchBindingsReplacePayload) netd_proto.SwitchConfigStatus {
    if (request.request_id == 0 or request.vmid == 0 or request._reserved != 0 or
        !std.mem.allEqual(u8, &request._pad, 0) or
        request.ipv4_count > request.ipv4_addresses.len or request.ipv6_count > request.ipv6_addresses.len)
    {
        return .invalid;
    }
    if (!port.used or port.state != .attached or request.vmid != port.vmid or
        request.generation != port.generation)
    {
        return .stale;
    }
    if (port.pending_bindings) |pending| {
        return if (std.meta.eql(pending, request.*)) .ok else .no_capacity;
    }
    if (request.expected_revision != port.policy_revision) return .stale;
    port.pending_bindings = request.*;
    return .ok;
}

fn applySwitchBindingsAck(port: *NetworkPort, ack: *align(1) const netd_proto.SwitchBindingsAckPayload) bool {
    const pending = port.pending_bindings orelse return false;
    if (!port.used or port.state != .attached or ack.vmid != port.vmid or
        ack.request_id != pending.request_id or ack.generation != pending.generation or
        ack._reserved != 0)
    {
        return false;
    }
    const status = @as(*align(1) const u16, @ptrCast(&ack.status)).*;
    if (status > @backingInt(netd_proto.SwitchConfigStatus.no_capacity)) return false;
    if (port.pending_binding_reply) |reply| return std.meta.eql(reply, ack.*);
    if (status == @backingInt(netd_proto.SwitchConfigStatus.ok)) {
        const next_revision = std.math.add(u64, pending.expected_revision, 1) catch return false;
        if (ack.policy_revision != next_revision or
            (port.policy_revision != pending.expected_revision and port.policy_revision != next_revision)) return false;
        port.policy_revision = ack.policy_revision;
    } else if (ack.policy_revision != 0) {
        return false;
    }
    port.pending_binding_reply = ack.*;
    return true;
}

// ---------------------------------------------------------------------------
// Serial helpers (for debug output before windowd is ready)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Text helpers (write into DMA text slot)
// ---------------------------------------------------------------------------

fn textBuf() [*]u8 {
    return @ptrFromInt(DMA_TEXT_SLOT);
}

fn writeLine(buf: [*]u8, pos: *usize, s: []const u8) void {
    for (s) |c| {
        buf[pos.*] = c;
        pos.* += 1;
    }
}

fn writeHex8(buf: [*]u8, pos: *usize, v: u8) void {
    const hex = "0123456789ABCDEF";
    buf[pos.*] = hex[v >> 4];
    pos.* += 1;
    buf[pos.*] = hex[v & 0xF];
    pos.* += 1;
}

fn writeHexNode(buf: [*]u8, pos: *usize, addr: [16]u8) void {
    // Print first 8 bytes as condensed hex groups, e.g. "fe80:0000:0000:0001"
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        if (i > 0) {
            buf[pos.*] = ':';
            pos.* += 1;
        }
        writeHex8(buf, pos, addr[i]);
        writeHex8(buf, pos, addr[i + 1]);
    }
}

// ---------------------------------------------------------------------------
// Draw a full UI frame to the framebuffer via windowd SYS_FB_DRAW
// ---------------------------------------------------------------------------

fn drawUi(text_phys: u64, token: u64, local_node: [16]u8) void {
    const buf = textBuf();

    // --- Row 0: banner ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "=== Catenary OS  Configuration Console ===");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, 0) << 32) | 0, token);
    }

    // --- Row 1: local node ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "Node: ");
        writeHexNode(buf, &pos, local_node);
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, 1) << 32) | 0, token);
    }

    // --- Row 2: separator ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "------------------------------------------");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, 2) << 32) | 0, token);
    }

    // --- Row 3: cluster header ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "Cluster Nodes:");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, 3) << 32) | 0, token);
    }

    // --- Rows 4..(4+MAX_CLUSTER_NODES): node list ---
    var row: u32 = 4;
    for (&cluster_nodes) |*n| {
        var pos: usize = 0;
        if (n.used) {
            writeLine(buf, &pos, "  [*] ");
            writeHexNode(buf, &pos, n.addr);
            writeLine(buf, &pos, "  svc=0x");
            writeHex8(buf, &pos, @truncate(n.services >> 8));
            writeHex8(buf, &pos, @truncate(n.services & 0xFF));
        } else {
            writeLine(buf, &pos, "  [ ] ---");
        }
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }

    // --- MicroVM section ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "MicroVMs:");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }

    for (&vms) |*v| {
        var pos: usize = 0;
        if (v.used) {
            writeLine(buf, &pos, "  VM#");
            writeHex8(buf, &pos, @truncate(v.instance_id));
            writeLine(buf, &pos, "  mem=");
            writeHex8(buf, &pos, @truncate(v.mem_pages >> 8));
            writeHex8(buf, &pos, @truncate(v.mem_pages & 0xFF));
            writeLine(buf, &pos, " pages");
        } else {
            writeLine(buf, &pos, "  ---");
        }
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }

    // --- Footer ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "------------------------------------------");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "Keys: [L] Launch VM   [R] Refresh   [Q] Quit");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
    }
}

// ---------------------------------------------------------------------------
// Send a create_microvm control request to the kernel via DIPC.
// The DIPC message goes to kernel_control (endpoint 2).
// ---------------------------------------------------------------------------

fn launchMicroVm(bs: *const BootstrapDescriptor, token: u64, dipc_phys_slot1: u64) void {
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_DIPC_SLOT);
    const local_node = lib.queryCurrentNode(bs, token, dipc_phys_slot1, DMA_DIPC_SLOT, EP_CONFIGD) orelse lib.Ipv6Addr{ .bytes = bs.local_node };

    // mem_pages = 256 (1 GiB / 4 KiB = 256 pages for a 1 MiB VM)
    const mem_pages: u32 = 256;

    const ini_file =
        \\[microvm]
        \\vcpus=1
        \\mem_pages=256
    ;

    var vcpus: u32 = 1;
    {
        var i: usize = 0;
        while (i < ini_file.len) {
            // Check for vcpus=
            var is_match = true;
            const prefix = "vcpus=";
            if (i + prefix.len <= ini_file.len) {
                for (prefix, 0..) |c, j| {
                    if (ini_file[i + j] != c) {
                        is_match = false;
                        break;
                    }
                }
                if (is_match) {
                    var v: u32 = 0;
                    var j = i + prefix.len;
                    while (j < ini_file.len and ini_file[j] >= '0' and ini_file[j] <= '9') {
                        v = v * 10 + (ini_file[j] - '0');
                        j += 1;
                    }
                    if (v > 0) vcpus = v;
                    break;
                }
            }
            while (i < ini_file.len and ini_file[i] != '\n') i += 1;
            if (i < ini_file.len) i += 1; // skip newline
        }
    }

    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(@sizeOf(lib.ControlHeader) + @sizeOf(lib.CreateMicrovmPayload))),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = EP_CONFIGD },
        .dst = .{ .node = local_node, .endpoint = bs.reserved_kernel_control_endpoint },
    };

    const control: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    control.* = .{
        .op = .create_microvm,
        .payload_len = @as(u32, @intCast(@sizeOf(lib.CreateMicrovmPayload))),
    };

    const payload: *align(1) lib.CreateMicrovmPayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
    payload.* = .{
        .mem_pages = mem_pages,
        .vcpus = vcpus,
        .kernel_phys = bs.linux_bzimage_phys,
        .kernel_size = bs.linux_bzimage_size,
        .initramfs_phys = bs.initramfs_phys,
        .initramfs_size = bs.initramfs_size,
        .name = @splat(0),
        .container = @splat(0),
    };

    // The kernel's SYS_SEND_PAGE copies from the DMA phys page, re-signs, and routes.
    _ = lib.syscall(SYS_SEND_PAGE, dipc_phys_slot1, 0, token);

    // Record in local VM table
    for (&vms) |*v| {
        if (!v.used) {
            v.used = true;
            v.instance_id = next_vmid;
            v.mem_pages = mem_pages;
            next_vmid += 1;
            break;
        }
    }

    lib.serialWrite("configd: create_microvm request sent\n");
}

// ---------------------------------------------------------------------------
// Handle an incoming DIPC registry_sync message (updates cluster_nodes table)
// ---------------------------------------------------------------------------

const RegistrySyncPayload = lib.RegistrySyncPayload;

fn handleRegistrySync(page_va: u64) void {
    const header: *align(1) const lib.PageHeader = @ptrFromInt(page_va);
    const payload: *align(1) const RegistrySyncPayload = @ptrFromInt(page_va + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
    const src_node = header.src.node.bytes;

    // Find existing or new slot for this node
    var slot: ?*NodeEntry = null;
    for (&cluster_nodes) |*n| {
        if (n.used) {
            var match = true;
            for (0..16) |i| {
                if (n.addr[i] != src_node[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                slot = n;
                break;
            }
        }
    }
    if (slot == null) {
        for (&cluster_nodes) |*n| {
            if (!n.used) {
                n.used = true;
                @memcpy(&n.addr, &src_node);
                slot = n;
                break;
            }
        }
    }

    if (slot) |s| {
        // Accumulate service kind bitmask so we can display which services are present
        s.services |= @as(u16, 1) << @as(u4, @truncate(payload.service_kind & 0xF));
        lib.serialWrite("configd: registry sync applied\n");
    }
}

// ---------------------------------------------------------------------------
// Handle a list_microvms request from windowd — reply with a VmSnapshotListPayload.
// ---------------------------------------------------------------------------

fn handleListMicrovms(bs: *const BootstrapDescriptor, token: u64, text_phys: u64, req_va: u64) void {
    // Determine the requesting endpoint so we can route the reply back.
    const req_hdr: *align(1) const lib.PageHeader = @ptrFromInt(req_va);
    const reply_ep = req_hdr.src.endpoint;
    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };

    // Build the snapshot into the DMA text slot (VA = DMA_TEXT_SLOT, phys = text_phys).
    const reply_buf: [*]u8 = lib.ptrFrom([*]u8, DMA_TEXT_SLOT);

    // DIPC header
    const reply_hdr: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(reply_buf));
    reply_hdr.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(lib.CONTROL_HEADER_SIZE + @sizeOf(lib.VmSnapshotListPayload))),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = EP_CONFIGD },
        .dst = .{ .node = local_node, .endpoint = reply_ep },
    };

    // Control header
    const reply_ctrl: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(reply_buf) + lib.DIPC_HEADER_SIZE);
    reply_ctrl.* = .{
        .op = .list_microvms,
        .payload_len = @as(u32, @intCast(@sizeOf(lib.VmSnapshotListPayload))),
    };

    // Payload — convert our simple VmEntry table to VmSnapshotEntry format.
    const snap: *align(1) lib.VmSnapshotListPayload = @ptrFromInt(@intFromPtr(reply_buf) + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
    // Zero-initialise
    @memset(@as([*]u8, @ptrFromInt(@intFromPtr(snap)))[0..@sizeOf(lib.VmSnapshotListPayload)], 0);
    var count: u32 = 0;
    for (&vms, 0..) |*v, i| {
        if (!v.used) continue;
        if (count >= lib.MAX_VM_SNAPSHOT_ENTRIES) break;
        snap.entries[count] = .{
            .instance_id = v.instance_id,
            .state = 1, // created (we don't track running/stopped here yet)
            .mem_pages = v.mem_pages,
            .vcpus = 1,
            .cpu_cycles = 0,
            .exit_count = 0,
            .name = @splat(0),
            .container = @splat(0),
        };
        // Copy first 3 chars of index as a default name placeholder
        _ = i;
        count += 1;
    }
    snap.count = count;

    _ = lib.syscall(SYS_SEND_PAGE, text_phys, 0, token);
    lib.serialWrite("configd: list_microvms reply sent\n");
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    lib.serialWrite("configd: starting OS Configuration App\n");

    // Register at endpoint 10
    _ = lib.syscall(SYS_REGISTER, 0, EP_CONFIGD, token);
    lib.serialWrite("configd: registered at endpoint 10\n");

    // Allocate two DMA pages: text scratch (slot 0) + DIPC lib.outbox (slot 1)
    const text_phys = lib.syscall(SYS_ALLOC_DMA, 2, 0, token);
    if (text_phys == 0) {
        lib.serialWrite("configd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }
    // Slot 1 physical = slot 0 + PAGE_SIZE
    const dipc_phys: u64 = text_phys + PAGE_SIZE;
    _ = &dipc_phys;

    // Draw initial UI
    // (windowd owns the framebuffer — configd is now a headless data backend)
    lib.serialWrite("configd: started (headless mode, windowd owns UI)\n");

    var snapshot_requested = false;
    var snapshot_interval: u32 = 0;
    var snapshot_wait: u32 = 0;
    if (sendVmSnapshotRequest(bs, token, dipc_phys)) {
        snapshot_requested = true;
        lib.serialWrite("configd: VM lifecycle snapshot requested\n");
    } else {
        lib.serialWrite("configd: initial VM snapshot request failed\n");
    }

    // Main event loop — receive DIPC messages; UI is handled by windowd
    while (true) {
        // --- Poll DIPC inbox ---
        const page_phys = lib.syscall(SYS_TRY_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                const page_header: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
                if (page_header.src.endpoint == @backingInt(lib.ReservedEndpoint.kernel_control) and
                    page_header.payload_len == @sizeOf(lib.VmSnapshotListPayload))
                {
                    handleVmSnapshot(bs, token, dipc_phys, recv_va);
                    snapshot_requested = false;
                    snapshot_wait = 0;
                } else if (page_header.src.endpoint == EP_NETD and
                    page_header.payload_len == @sizeOf(netd_proto.NetdHeader) + @sizeOf(netd_proto.SwitchConfigAckPayload))
                {
                    handleNetdConfigAck(bs, recv_va, page_header.payload_len);
                } else if (page_header.src.endpoint == EP_NETD and
                    page_header.payload_len == @sizeOf(netd_proto.NetdHeader) + @sizeOf(netd_proto.SwitchBindingsAckPayload))
                {
                    handleNetdBindingsAck(bs, token, dipc_phys, recv_va, page_header.payload_len);
                } else if (page_header.src.endpoint == EP_WINDOWD) {
                    handleLocalSwitchAdmin(bs, token, dipc_phys, recv_va);
                } else if (page_header.payload_len >= lib.CONTROL_HEADER_SIZE) {
                    const control: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
                    switch (control.op) {
                        .registry_sync => {
                            handleRegistrySync(recv_va);
                        },
                        .list_microvms => {
                            handleListMicrovms(bs, token, text_phys, recv_va);
                        },
                        else => {},
                    }
                }
                _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
            } else {
                _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
            }
        }

        snapshot_interval +%= 1;
        if (snapshot_requested) {
            snapshot_wait +%= 1;
            if (snapshot_wait >= SNAPSHOT_TIMEOUT_TICKS) {
                snapshot_requested = false;
                snapshot_wait = 0;
                lib.serialWrite("configd: VM snapshot request timed out\n");
            }
        } else if (snapshot_interval >= SNAPSHOT_INTERVAL_TICKS) {
            snapshot_interval = 0;
            if (sendVmSnapshotRequest(bs, token, dipc_phys)) {
                snapshot_requested = true;
                lib.serialWrite("configd: VM lifecycle snapshot requested\n");
            } else {
                lib.serialWrite("configd: VM snapshot request send failed\n");
            }
        }

        _ = lib.syscall(lib.SYS_YIELD, 0, 0, token);
        asm volatile ("pause");
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}

test "switch attach acknowledgements require a matching pending request and valid generation" {
    var port = NetworkPort{ .used = true, .vmid = 7, .state = .attach_pending };
    var ack = netd_proto.SwitchConfigAckPayload{
        .request_op = .switch_port_attach,
        .status = .ok,
        .vmid = 7,
        .generation = 0,
        .policy_revision = 1,
    };

    try std.testing.expectEqual(ConfigAckTransition.ignored, applySwitchConfigAck(&port, &ack));
    try std.testing.expectEqual(NetworkPortState.attach_pending, port.state);

    ack.generation = 3;
    ack.policy_revision = 0;
    try std.testing.expectEqual(ConfigAckTransition.ignored, applySwitchConfigAck(&port, &ack));
    try std.testing.expectEqual(NetworkPortState.attach_pending, port.state);

    ack.policy_revision = 1;
    ack.vmid = 8;
    try std.testing.expectEqual(ConfigAckTransition.ignored, applySwitchConfigAck(&port, &ack));
    try std.testing.expectEqual(NetworkPortState.attach_pending, port.state);

    ack.vmid = 7;
    try std.testing.expectEqual(ConfigAckTransition.attached, applySwitchConfigAck(&port, &ack));
    try std.testing.expectEqual(NetworkPortState.attached, port.state);
    try std.testing.expectEqual(@as(u64, 3), port.generation);
}

test "switch acknowledgements with unknown enum values leave port state unchanged" {
    var port = NetworkPort{ .used = true, .vmid = 11, .state = .attach_pending };
    var ack = netd_proto.SwitchConfigAckPayload{
        .request_op = .switch_port_attach,
        .status = .ok,
        .vmid = 11,
        .generation = 2,
        .policy_revision = 1,
    };
    const request_op: *align(1) u16 = @ptrCast(&ack.request_op);
    request_op.* = 0xFFFF;
    try std.testing.expectEqual(ConfigAckTransition.ignored, applySwitchConfigAck(&port, &ack));
    try std.testing.expectEqual(NetworkPortState.attach_pending, port.state);

    request_op.* = @backingInt(netd_proto.Op.switch_port_attach);
    const status: *align(1) u16 = @ptrCast(&ack.status);
    status.* = 0xFFFF;
    try std.testing.expectEqual(ConfigAckTransition.ignored, applySwitchConfigAck(&port, &ack));
    try std.testing.expectEqual(NetworkPortState.attach_pending, port.state);
}

test "netd acknowledgement envelope checks transport and destination identity" {
    const local_node: [16]u8 = @splat(0x2A);
    var page = lib.PageHeader{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @intCast(lib.DIPC_HEADER_SIZE),
        .payload_len = @intCast(@sizeOf(netd_proto.NetdHeader) + @sizeOf(netd_proto.SwitchConfigAckPayload)),
        .auth_tag = 0,
        .src = .{
            .node = lib.Ipv6Addr.loopback(),
            .endpoint = EP_NETD,
        },
        .dst = .{
            .node = .{ .bytes = local_node },
            .endpoint = EP_CONFIGD,
        },
    };
    var netd = netd_proto.NetdHeader{ .op = .switch_config_ack };
    const payload_len = @as(usize, page.payload_len);

    try std.testing.expect(isNetdConfigAckEnvelope(&page, &netd, payload_len, &local_node));
    page.src.node.bytes[0] = 0xFE;
    try std.testing.expect(!isNetdConfigAckEnvelope(&page, &netd, payload_len, &local_node));
    page.src.node = lib.Ipv6Addr.loopback();
    page.dst.node.bytes[0] ^= 1;
    try std.testing.expect(!isNetdConfigAckEnvelope(&page, &netd, payload_len, &local_node));
    page.dst.node.bytes[0] ^= 1;

    page.src.endpoint = EP_CONFIGD;
    try std.testing.expect(!isNetdConfigAckEnvelope(&page, &netd, payload_len, &local_node));
    page.src.endpoint = EP_NETD;

    const op: *align(1) u16 = @ptrCast(&netd.op);
    op.* = 0xFFFF;
    try std.testing.expect(!isNetdConfigAckEnvelope(&page, &netd, payload_len, &local_node));
}

test "stale switch detach acknowledgements retain the attachment reference" {
    var port = NetworkPort{
        .used = true,
        .vmid = 9,
        .generation = 4,
        .state = .detach_pending,
    };
    const mismatched_generation_ack = netd_proto.SwitchConfigAckPayload{
        .request_op = .switch_port_detach,
        .status = .stale,
        .vmid = 9,
        .generation = 3,
        .policy_revision = 0,
    };

    try std.testing.expectEqual(ConfigAckTransition.ignored, applySwitchConfigAck(&port, &mismatched_generation_ack));
    try std.testing.expect(port.used);
    try std.testing.expectEqual(NetworkPortState.detach_pending, port.state);

    var stale_status_ack = mismatched_generation_ack;
    stale_status_ack.generation = 4;
    try std.testing.expectEqual(ConfigAckTransition.detach_rejected, applySwitchConfigAck(&port, &stale_status_ack));
    try std.testing.expect(port.used);
    try std.testing.expectEqual(NetworkPortState.attached, port.state);

    var confirmed_ack = stale_status_ack;
    port.state = .detach_pending;
    confirmed_ack.status = .ok;
    try std.testing.expectEqual(ConfigAckTransition.detached, applySwitchConfigAck(&port, &confirmed_ack));
    try std.testing.expect(!port.used);
}

test "local switch administration accepts only loopback windowd messages" {
    var page = lib.PageHeader{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @intCast(lib.DIPC_HEADER_SIZE),
        .payload_len = @sizeOf(configd_proto.ConfigdHeader),
        .auth_tag = 0,
        .src = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = EP_WINDOWD },
        .dst = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = EP_CONFIGD },
    };
    try std.testing.expect(isLocalWindowdRequest(&page));
    page.src.endpoint = EP_CLUSTERD;
    try std.testing.expect(!isLocalWindowdRequest(&page));
    page.src.endpoint = EP_WINDOWD;
    page.src.node.bytes[0] = 0xFE;
    try std.testing.expect(!isLocalWindowdRequest(&page));
    page.src.node = lib.Ipv6Addr.loopback();
    page.dst.node.bytes[0] = 0xFE;
    try std.testing.expect(!isLocalWindowdRequest(&page));
}

test "binding updates serialize retries and validate correlated acknowledgements" {
    var port = NetworkPort{
        .used = true,
        .vmid = 7,
        .generation = 4,
        .policy_revision = 3,
        .state = .attached,
    };
    const status_request = configd_proto.LocalPortStatusRequest{ .request_id = 20, .vmid = 7 };
    const status = makeLocalPortStatus(&port, &status_request);
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.ok, status.status);
    try std.testing.expectEqual(@as(u64, 4), status.generation);
    try std.testing.expectEqual(@as(u64, 3), status.policy_revision);

    var request = netd_proto.SwitchBindingsReplacePayload{
        .vmid = 7,
        .generation = 4,
        .expected_revision = 3,
        .request_id = 20,
        .ipv4_count = 1,
        .ipv6_count = 0,
    };
    request.ipv4_addresses[0] = .{ 10, 0, 0, 7 };
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.ok, beginSwitchBindings(&port, &request));
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.ok, beginSwitchBindings(&port, &request));
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.no_capacity, makeLocalPortStatus(&port, &status_request).status);
    var conflicting = request;
    conflicting.ipv4_addresses[0][3] = 8;
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.no_capacity, beginSwitchBindings(&port, &conflicting));

    var ack = netd_proto.SwitchBindingsAckPayload{
        .request_id = 21,
        .vmid = 7,
        .status = .ok,
        .generation = 4,
        .policy_revision = 4,
    };
    try std.testing.expect(!applySwitchBindingsAck(&port, &ack));
    ack.request_id = 20;
    ack.generation = 5;
    try std.testing.expect(!applySwitchBindingsAck(&port, &ack));
    ack.generation = 4;
    ack.policy_revision = 5;
    try std.testing.expect(!applySwitchBindingsAck(&port, &ack));
    ack.policy_revision = 4;
    try std.testing.expect(applySwitchBindingsAck(&port, &ack));
    try std.testing.expectEqual(@as(u64, 4), port.policy_revision);
    try std.testing.expect(port.pending_bindings != null);
    try std.testing.expect(applySwitchBindingsAck(&port, &ack));
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.ok, beginSwitchBindings(&port, &request));
    var delayed_failure = ack;
    delayed_failure.status = .stale;
    delayed_failure.policy_revision = 0;
    try std.testing.expect(!applySwitchBindingsAck(&port, &delayed_failure));
    const invalid_status: *align(1) u16 = @ptrCast(&delayed_failure.status);
    invalid_status.* = 0xFFFF;
    try std.testing.expect(!applySwitchBindingsAck(&port, &delayed_failure));
    port.pending_bindings = null;
    port.pending_binding_reply = null;
    try std.testing.expect(!applySwitchBindingsAck(&port, &ack));
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.stale, beginSwitchBindings(&port, &request));
}

test "binding updates reject invalid requests and stale port generations" {
    var port = NetworkPort{
        .used = true,
        .vmid = 7,
        .generation = 4,
        .policy_revision = 3,
        .state = .attached,
    };
    var request = netd_proto.SwitchBindingsReplacePayload{
        .vmid = 7,
        .generation = 4,
        .expected_revision = 3,
        .request_id = 0,
        .ipv4_count = 0,
        .ipv6_count = 0,
    };
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.invalid, beginSwitchBindings(&port, &request));
    request.request_id = 1;
    request.ipv6_count = 5;
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.invalid, beginSwitchBindings(&port, &request));
    request.ipv6_count = 0;
    request.generation = 3;
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.stale, beginSwitchBindings(&port, &request));
    request.generation = 4;
    port.state = .detach_pending;
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.stale, beginSwitchBindings(&port, &request));
    try std.testing.expect(port.pending_bindings == null);
}

test "configd forwards one rule update at a time and applies only matching acks" {
    var port = NetworkPort{ .used = true, .vmid = 4, .generation = 11, .policy_revision = 3, .state = .attached };
    var request = netd_proto.SwitchRuleUpdatePayload{
        .vmid = 4,
        .action = netd_proto.SWITCH_RULE_ADD_INGRESS,
        .ip_version = 6,
        .protocol = 17,
        .generation = 11,
        .expected_revision = 3,
        .request_id = 21,
        .destination_port_first = 5001,
        .destination_port_last = 5001,
    };
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.ok, beginSwitchRule(&port, &request));
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.no_capacity, beginSwitchRule(&port, &request));

    var ack = netd_proto.SwitchBindingsAckPayload{
        .request_id = 22,
        .vmid = 4,
        .status = .ok,
        .generation = 11,
        .policy_revision = 4,
    };
    try std.testing.expect(!applySwitchRuleAck(&port, &ack));
    ack.request_id = 21;
    ack.policy_revision = 9;
    try std.testing.expect(!applySwitchRuleAck(&port, &ack));
    ack.policy_revision = 4;
    try std.testing.expect(applySwitchRuleAck(&port, &ack));
    try std.testing.expectEqual(@as(u64, 4), port.policy_revision);
    try std.testing.expect(port.pending_rule == null);

    request.expected_revision = 3;
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.stale, beginSwitchRule(&port, &request));
    request.expected_revision = 4;
    request.action = 9;
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.invalid, beginSwitchRule(&port, &request));
    request.action = netd_proto.SWITCH_RULE_CLEAR;
    request.generation = 12;
    try std.testing.expectEqual(netd_proto.SwitchConfigStatus.stale, beginSwitchRule(&port, &request));
}
