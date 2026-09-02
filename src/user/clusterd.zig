const std = @import("std");
const lib = @import("lib.zig");
const clusterd_proto = @import("protocols/clusterd_protocol.zig");
const netd_proto = @import("protocols/netd_protocol.zig");

const SYS_REGISTER = lib.SYS_REGISTER;
const SYS_RECV = lib.SYS_RECV;
const SYS_FREE_PAGE = lib.SYS_FREE_PAGE;
const SYS_ALLOC_DMA = lib.SYS_ALLOC_DMA;
const SYS_SEND_PAGE = lib.SYS_SEND_PAGE;
const SYS_MAP_RECV = lib.SYS_MAP_RECV;
const SYS_YIELD = lib.SYS_YIELD;

const DMA_BASE_VA: u64 = lib.DMA_BASE_VA;
const DIPC_RECV_VA: u64 = lib.DIPC_RECV_VA;

const BootstrapDescriptor = lib.BootstrapDescriptor;

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;

const EP_CLUSTERD: u64 = @intFromEnum(lib.ReservedEndpoint.clusterd);
const MAX_PEERS: usize = clusterd_proto.MAX_RESOURCE_SNAPSHOT_ENTRIES;
const DEFAULT_VM_MEM_PAGES: u32 = 16384;
const DEFAULT_VM_VCPUS: u32 = 1;
const IPV6_ALL_NODES_MULTICAST = lib.Ipv6Addr{ .bytes = .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };

const PeerState = struct {
    used: bool = false,
    node: lib.Ipv6Addr = lib.Ipv6Addr{ .bytes = [_]u8{0} ** 16 },
    has_resources: bool = false,
    resources: clusterd_proto.ResourceAdvertisement = zeroResources(),
    announced: bool = false,
    snapshot_requested: bool = false,
    launch_requested: bool = false,
};

const PendingInboundLaunch = struct {
    active: bool = false,
    request_id: u64 = 0,
    requester_node: lib.Ipv6Addr = lib.Ipv6Addr{ .bytes = [_]u8{0} ** 16 },
    mem_pages: u32 = 0,
    vcpus: u32 = 0,
};

var g_local_node: lib.Ipv6Addr = lib.Ipv6Addr{ .bytes = [_]u8{0} ** 16 };
var g_local_resources: clusterd_proto.ResourceAdvertisement = zeroResources();
var g_peers: [MAX_PEERS]PeerState = [_]PeerState{.{}} ** MAX_PEERS;
var g_next_request_id: u64 = 1;
var g_pending_launch_request_id: u64 = 0;
var g_pending_launch_node: lib.Ipv6Addr = lib.Ipv6Addr{ .bytes = [_]u8{0} ** 16 };
var g_remote_launch_complete: bool = false;
var g_pending_inbound_launch: PendingInboundLaunch = .{};
var g_local_netd_ready: bool = false;
var g_netd_node_query_sent: bool = false;
var g_netd_peer_snapshot_sent: bool = false;
var g_discovery_ticks: u32 = 0;

fn zeroResources() clusterd_proto.ResourceAdvertisement {
    return .{
        .generation = 1,
        .total_mem_pages = 65536,
        .free_mem_pages = 32768,
        .logical_cpu_total = 4,
        .logical_cpu_available = 4,
        .active_vms = 0,
        .service_mask = 0xFF,
        .flags = 0,
    };
}

fn seedLocalResources() void {
    g_local_resources = .{
        .generation = 1,
        .total_mem_pages = DEFAULT_VM_MEM_PAGES * 4,
        .free_mem_pages = DEFAULT_VM_MEM_PAGES * 4,
        .logical_cpu_total = 1,
        .logical_cpu_available = 1,
        .active_vms = 0,
        .service_mask = (@as(u32, 1) << @as(u5, @intCast(@intFromEnum(lib.ServiceKind.clusterd)))) |
            (@as(u32, 1) << @as(u5, @intCast(@intFromEnum(lib.ServiceKind.netd)))),
        .flags = lib.NODE_FLAG_CLUSTER_CAPABLE,
    };
}

fn ipv6Eq(a: lib.Ipv6Addr, b: lib.Ipv6Addr) bool {
    for (0..16) |i| {
        if (a.bytes[i] != b.bytes[i]) return false;
    }
    return true;
}

fn isLoopback(addr: lib.Ipv6Addr) bool {
    const all_zero = [_]u8{0} ** 16;
    if (std.mem.eql(u8, &addr.bytes, &all_zero)) return true;
    const loopback = lib.Ipv6Addr.loopback().bytes;
    return std.mem.eql(u8, &addr.bytes, &loopback);
}

fn isRemoteNode(addr: lib.Ipv6Addr) bool {
    return !ipv6Eq(addr, g_local_node) and !isLoopback(addr);
}

fn ensurePeer(node: lib.Ipv6Addr) ?*PeerState {
    if (!isRemoteNode(node)) return null;

    for (&g_peers) |*peer| {
        if (peer.used and ipv6Eq(peer.node, node)) return peer;
    }
    for (&g_peers) |*peer| {
        if (!peer.used) {
            peer.* = .{
                .used = true,
                .node = node,
            };
            return peer;
        }
    }
    return null;
}

fn findPeer(node: lib.Ipv6Addr) ?*PeerState {
    for (&g_peers) |*peer| {
        if (peer.used and ipv6Eq(peer.node, node)) return peer;
    }
    return null;
}

fn peerCanHost(peer: *const PeerState, mem_pages: u32, vcpus: u32) bool {
    if (!peer.used or !peer.has_resources) return false;
    if (peer.resources.free_mem_pages < mem_pages) return false;
    if (peer.resources.logical_cpu_available < vcpus) return false;
    return true;
}

fn selectLaunchPeer(mem_pages: u32, vcpus: u32) ?*PeerState {
    var best: ?*PeerState = null;
    for (&g_peers) |*peer| {
        if (!peerCanHost(peer, mem_pages, vcpus)) continue;
        if (peer.launch_requested) continue;
        if (best == null or peer.resources.free_mem_pages > best.?.resources.free_mem_pages) {
            best = peer;
        }
    }
    if (best != null) return best;

    for (&g_peers) |*peer| {
        if (!peer.used or peer.launch_requested) continue;
        return peer;
    }
    return best;
}

fn sendClusterdMessage(
    scratch_phys: u64,
    scratch_va: u64,
    token: u64,
    dst_node: lib.Ipv6Addr,
    op: clusterd_proto.Op,
    payload: []const u8,
) bool {
    const total_payload_len = @sizeOf(clusterd_proto.ClusterdHeader) + payload.len;
    if (lib.DIPC_HEADER_SIZE + total_payload_len > lib.PAGE_SIZE) return false;

    const scratch: [*]u8 = lib.ptrFrom([*]u8, scratch_va);
    const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    head.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(total_payload_len)),
        .auth_tag = 0,
        .src = .{ .node = g_local_node, .endpoint = EP_CLUSTERD },
        .dst = .{ .node = dst_node, .endpoint = EP_CLUSTERD },
    };

    const msg_hdr: *align(1) clusterd_proto.ClusterdHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    msg_hdr.* = .{
        .op = op,
        .payload_len = @as(u32, @intCast(payload.len)),
    };

    if (payload.len > 0) {
        @memcpy(
            scratch[lib.DIPC_HEADER_SIZE + @sizeOf(clusterd_proto.ClusterdHeader) ..][0..payload.len],
            payload,
        );
    }

    return lib.syscall(SYS_SEND_PAGE, scratch_phys, 0, token) == 0;
}

fn sendNetdMessage(
    scratch_phys: u64,
    scratch_va: u64,
    token: u64,
    op: netd_proto.Op,
    payload: []const u8,
) bool {
    const total_payload_len = @sizeOf(netd_proto.NetdHeader) + payload.len;
    if (lib.DIPC_HEADER_SIZE + total_payload_len > lib.PAGE_SIZE) return false;

    const scratch: [*]u8 = lib.ptrFrom([*]u8, scratch_va);
    const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    head.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(total_payload_len)),
        .auth_tag = 0,
        .src = .{ .node = g_local_node, .endpoint = EP_CLUSTERD },
        .dst = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @intFromEnum(lib.ReservedEndpoint.netd) },
    };

    const msg_hdr: *align(1) netd_proto.NetdHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    msg_hdr.* = .{
        .op = op,
    };

    if (payload.len > 0) {
        @memcpy(
            scratch[lib.DIPC_HEADER_SIZE + @sizeOf(netd_proto.NetdHeader) ..][0..payload.len],
            payload,
        );
    }

    return lib.syscall(SYS_SEND_PAGE, scratch_phys, 0, token) == 0;
}

fn sendControlRequest(
    bs: *const BootstrapDescriptor,
    scratch_phys: u64,
    scratch_va: u64,
    token: u64,
    op: lib.ControlOp,
    extra_payload: []const u8,
) bool {
    const scratch: [*]u8 = lib.ptrFrom([*]u8, scratch_va);
    const total_payload_len = lib.CONTROL_HEADER_SIZE + extra_payload.len;
    if (lib.DIPC_HEADER_SIZE + total_payload_len > lib.PAGE_SIZE) return false;

    const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    head.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(total_payload_len)),
        .auth_tag = 0,
        .src = .{ .node = g_local_node, .endpoint = EP_CLUSTERD },
        .dst = .{ .node = g_local_node, .endpoint = bs.reserved_kernel_control_endpoint },
    };

    const ctrl: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    ctrl.* = .{
        .op = op,
        .payload_len = @as(u32, @intCast(extra_payload.len)),
    };

    if (extra_payload.len > 0) {
        @memcpy(
            scratch[lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE ..][0..extra_payload.len],
            extra_payload,
        );
    }

    return lib.syscall(SYS_SEND_PAGE, scratch_phys, 0, token) == 0;
}

fn queryLocalNodeStatus(
    bs: *const BootstrapDescriptor,
    token: u64,
    scratch_phys: u64,
    scratch_va: u64,
) ?lib.NodeStatusResult {
    if (!sendControlRequest(bs, scratch_phys, scratch_va, token, .get_node_status, &[_]u8{})) return null;

    const page_phys = lib.syscall(SYS_RECV, 0, 0, token);
    if (page_phys == 0) return null;
    const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
    if (recv_va == 0) {
        _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
        return null;
    }

    const result: *align(1) const lib.NodeStatusResult = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
    const copy = result.*;
    _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
    return copy;
}

fn refreshLocalResources(
    bs: *const BootstrapDescriptor,
    token: u64,
    scratch_phys: u64,
    scratch_va: u64,
) void {
    const status = queryLocalNodeStatus(bs, token, scratch_phys, scratch_va) orelse return;
    g_local_resources.generation +%= 1;
    g_local_resources.total_mem_pages = status.total_mem_pages;
    g_local_resources.free_mem_pages = status.free_mem_pages;
    g_local_resources.logical_cpu_total = status.logical_cpu_total;
    g_local_resources.logical_cpu_available = status.logical_cpu_available;
    g_local_resources.active_vms = status.active_vms;
    g_local_resources.service_mask = status.service_mask;
    g_local_resources.flags = status.flags;
}

fn reserveLocalResources(mem_pages: u32, vcpus: u32) void {
    g_local_resources.generation +%= 1;
    if (g_local_resources.free_mem_pages > mem_pages) {
        g_local_resources.free_mem_pages -= mem_pages;
    } else {
        g_local_resources.free_mem_pages = 0;
    }
    g_local_resources.active_vms += 1;
    if (g_local_resources.logical_cpu_available > vcpus) {
        g_local_resources.logical_cpu_available -= vcpus;
    } else {
        g_local_resources.logical_cpu_available = 0;
    }
}

fn sendLocalResourceAdvertisement(scratch_phys: u64, scratch_va: u64, token: u64, dst_node: lib.Ipv6Addr) void {
    g_local_resources.generation +%= 1;
    _ = sendClusterdMessage(scratch_phys, scratch_va, token, dst_node, .resource_advertisement, std.mem.asBytes(&g_local_resources));
}

fn sendResourceSnapshotRequest(scratch_phys: u64, scratch_va: u64, token: u64, dst_node: lib.Ipv6Addr) void {
    const req = clusterd_proto.ResourceSnapshotRequest{};
    _ = sendClusterdMessage(scratch_phys, scratch_va, token, dst_node, .resource_snapshot_request, std.mem.asBytes(&req));
}

fn sendResourceSnapshotReply(scratch_phys: u64, scratch_va: u64, token: u64, dst_node: lib.Ipv6Addr) void {
    var reply = clusterd_proto.ResourceSnapshotReply{ .count = 1 };
    reply.entries[0] = .{
        .node_addr = g_local_node.bytes,
        .resources = g_local_resources,
    };
    _ = sendClusterdMessage(scratch_phys, scratch_va, token, dst_node, .resource_snapshot_reply, std.mem.asBytes(&reply));
}

fn nextRequestId() u64 {
    const id = g_next_request_id;
    g_next_request_id +%= 1;
    return if (id == 0) 1 else id;
}

fn mapControlStatus(status: lib.ControlStatus) clusterd_proto.LaunchVmStatus {
    return switch (status) {
        .ok => .ok,
        .unauthorized => .unauthorized,
        .busy => .busy,
        .no_capacity => .no_capacity,
        .invalid_payload => .invalid_payload,
        else => .internal_error,
    };
}

fn sendLaunchAck(
    scratch_phys: u64,
    scratch_va: u64,
    token: u64,
    dst_node: lib.Ipv6Addr,
    request_id: u64,
    result: lib.CreateMicrovmResult,
) void {
    const ack = clusterd_proto.LaunchVmAck{
        .request_id = request_id,
        .instance_id = result.instance_id,
        .status = mapControlStatus(result.status),
    };
    _ = sendClusterdMessage(scratch_phys, scratch_va, token, dst_node, .launch_vm_ack, std.mem.asBytes(&ack));
}

var g_local_launch_attempted: bool = false;

fn maybeRequestLocalLaunch(
    bs: *const BootstrapDescriptor,
    scratch_phys: u64,
    scratch_va: u64,
    token: u64,
) void {
    if (g_remote_launch_complete or g_pending_launch_request_id != 0 or g_local_launch_attempted) return;
    g_local_launch_attempted = true;

    lib.serialWrite("clusterd: requesting local MicroVM launch\n");
    var create = lib.CreateMicrovmPayload{
        .mem_pages = DEFAULT_VM_MEM_PAGES,
        .vcpus = DEFAULT_VM_VCPUS,
        .kernel_phys = bs.linux_bzimage_phys,
        .kernel_size = bs.linux_bzimage_size,
        .initramfs_phys = bs.initramfs_phys,
        .initramfs_size = bs.initramfs_size,
        .name = [_]u8{0} ** 32,
        .container = [_]u8{0} ** 32,
    };
    @memcpy(create.name[0..7], "default");
    _ = sendControlRequest(bs, scratch_phys, scratch_va, token, .create_microvm, std.mem.asBytes(&create));
}

fn maybeRequestRemoteLaunch(
    bs: *const BootstrapDescriptor,
    scratch_phys: u64,
    scratch_va: u64,
    token: u64,
) void {
    if (isLoopback(g_local_node)) return;
    if (g_remote_launch_complete or g_pending_launch_request_id != 0) return;

    const peer = selectLaunchPeer(DEFAULT_VM_MEM_PAGES, DEFAULT_VM_VCPUS) orelse {
        var has_remote_peers = false;
        for (g_peers) |p| {
            if (p.used and isRemoteNode(p.node)) {
                has_remote_peers = true;
                break;
            }
        }
        if (!has_remote_peers) {
            // Wait a short window (8 ticks = 40 main-loop iters) for peer
            // discovery before falling back to a local MicroVM launch.
            if (g_discovery_ticks < 8) {
                g_discovery_ticks += 1;
                return;
            }
            maybeRequestLocalLaunch(bs, scratch_phys, scratch_va, token);
        }
        return;
    };
    const request_id = nextRequestId();
    var req = clusterd_proto.LaunchVmRequest{
        .request_id = request_id,
        .mem_pages = DEFAULT_VM_MEM_PAGES,
        .vcpus = DEFAULT_VM_VCPUS,
        .kernel_phys = bs.linux_bzimage_phys,
        .kernel_size = bs.linux_bzimage_size,
        .initramfs_phys = bs.initramfs_phys,
        .initramfs_size = bs.initramfs_size,
        .name = [_]u8{0} ** 32,
        .container = [_]u8{0} ** 32,
    };
    @memcpy(req.name[0..13], "remote-micron");

    lib.serialWrite("clusterd: discovered remote node via registry_sync, requesting remote MicroVM launch\n");
    if (sendClusterdMessage(scratch_phys, scratch_va, token, IPV6_ALL_NODES_MULTICAST, .launch_vm_request, std.mem.asBytes(&req))) {
        peer.launch_requested = true;
        g_pending_launch_request_id = request_id;
        g_pending_launch_node = peer.node;
    }
}

fn handleRegistrySync(
    bs: *const BootstrapDescriptor,
    scratch_phys: u64,
    scratch_va: u64,
    token: u64,
    recv_va: u64,
) void {
    const hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
    const payload: *align(1) const lib.RegistrySyncPayload = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
    const remote_node = hdr.src.node;

    if (!isRemoteNode(remote_node)) {
        if (payload.service_kind == @intFromEnum(lib.ServiceKind.netd)) {
            g_local_netd_ready = true;
            if (!g_netd_node_query_sent) {
                _ = sendNetdMessage(scratch_phys, scratch_va, token, .get_node_addr, &[_]u8{});
                g_netd_node_query_sent = true;
            }
            if (!g_netd_peer_snapshot_sent) {
                const req = netd_proto.PeerSnapshotRequest{};
                _ = sendNetdMessage(scratch_phys, scratch_va, token, .peer_snapshot_request, std.mem.asBytes(&req));
                g_netd_peer_snapshot_sent = true;
            }
            maybeRequestRemoteLaunch(bs, scratch_phys, scratch_va, token);
        }
        return;
    }

    const peer = ensurePeer(remote_node) orelse return;

    if (!peer.announced) {
        sendLocalResourceAdvertisement(scratch_phys, scratch_va, token, remote_node);
        peer.announced = true;
    }
    if (!peer.snapshot_requested) {
        sendResourceSnapshotRequest(scratch_phys, scratch_va, token, remote_node);
        peer.snapshot_requested = true;
    }

    maybeRequestRemoteLaunch(bs, scratch_phys, scratch_va, token);
}

fn handleNetdProtocol(
    bs: *const BootstrapDescriptor,
    scratch_phys: u64,
    scratch_va: u64,
    token: u64,
    recv_va: u64,
) void {
    const hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
    const msg_hdr: *align(1) const netd_proto.NetdHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
    const msg_payload_len = @as(usize, hdr.payload_len) - @sizeOf(netd_proto.NetdHeader);
    const msg_payload_va = recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(netd_proto.NetdHeader);

    switch (msg_hdr.op) {
        .node_addr_reply => {
            lib.serialWrite("clusterd: received node_addr_reply\n");
            if (msg_payload_len != @sizeOf(netd_proto.NodeAddrReply)) return;
            const reply: *align(1) const netd_proto.NodeAddrReply = @ptrFromInt(msg_payload_va);
            g_local_node = .{ .bytes = reply.addr };
            g_local_resources.flags |= lib.NODE_FLAG_NODE_ADDR_CONFIGURED;
            const req = netd_proto.PeerSnapshotRequest{};
            _ = sendNetdMessage(scratch_phys, scratch_va, token, .peer_snapshot_request, std.mem.asBytes(&req));
            g_netd_peer_snapshot_sent = true;
            maybeRequestRemoteLaunch(bs, scratch_phys, scratch_va, token);
        },
        .peer_snapshot_reply => {
            if (msg_payload_len != @sizeOf(netd_proto.PeerSnapshotReply)) return;
            const reply: *align(1) const netd_proto.PeerSnapshotReply = @ptrFromInt(msg_payload_va);
            var idx: usize = 0;
            const count = @min(@as(usize, reply.count), netd_proto.MAX_PEER_SNAPSHOT_ENTRIES);
            while (idx < count) : (idx += 1) {
                const entry = reply.entries[idx];
                const node = lib.Ipv6Addr{ .bytes = entry.node_addr };
                const peer = ensurePeer(node) orelse continue;
                if (!peer.announced and !isLoopback(g_local_node)) {
                    sendLocalResourceAdvertisement(scratch_phys, scratch_va, token, node);
                    peer.announced = true;
                }
                if (!peer.snapshot_requested) {
                    sendResourceSnapshotRequest(scratch_phys, scratch_va, token, node);
                    peer.snapshot_requested = true;
                }
            }
            maybeRequestRemoteLaunch(bs, scratch_phys, scratch_va, token);
        },
        else => {},
    }
}

fn handleClusterdProtocol(
    bs: *const BootstrapDescriptor,
    scratch_phys: u64,
    scratch_va: u64,
    token: u64,
    recv_va: u64,
) void {
    const hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
    const msg_hdr: *align(1) const clusterd_proto.ClusterdHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
    const msg_payload_len = @as(usize, msg_hdr.payload_len);
    const msg_payload_va = recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(clusterd_proto.ClusterdHeader);
    const src_node = hdr.src.node;

    switch (msg_hdr.op) {
        .launch_vm_request => {
            if (msg_payload_len != @sizeOf(clusterd_proto.LaunchVmRequest)) return;
            if (ipv6Eq(src_node, g_local_node)) return;
            const req_ptr: *align(1) const clusterd_proto.LaunchVmRequest = @ptrFromInt(msg_payload_va);
            const req = req_ptr.*;

            if (g_pending_inbound_launch.active) {
                sendLaunchAck(scratch_phys, scratch_va, token, IPV6_ALL_NODES_MULTICAST, req.request_id, .{
                    .status = .busy,
                    .instance_id = 0,
                });
                return;
            }

            g_pending_inbound_launch = .{
                .active = true,
                .request_id = req.request_id,
                .requester_node = src_node,
                .mem_pages = req.mem_pages,
                .vcpus = req.vcpus,
            };

            var create = lib.CreateMicrovmPayload{
                .mem_pages = req.mem_pages,
                .vcpus = req.vcpus,
                .kernel_phys = bs.linux_bzimage_phys,
                .kernel_size = bs.linux_bzimage_size,
                .initramfs_phys = bs.initramfs_phys,
                .initramfs_size = bs.initramfs_size,
                .name = req.name,
                .container = req.container,
            };
            if (!sendControlRequest(bs, scratch_phys, scratch_va, token, .create_microvm, std.mem.asBytes(&create))) {
                sendLaunchAck(scratch_phys, scratch_va, token, IPV6_ALL_NODES_MULTICAST, req.request_id, .{
                    .status = .internal_error,
                    .instance_id = 0,
                });
                g_pending_inbound_launch = .{};
            }
        },
        .launch_vm_ack => {
            if (msg_payload_len != @sizeOf(clusterd_proto.LaunchVmAck)) return;
            const ack: *align(1) const clusterd_proto.LaunchVmAck = @ptrFromInt(msg_payload_va);
            if (ack.request_id != g_pending_launch_request_id or !ipv6Eq(src_node, g_pending_launch_node)) return;

            g_pending_launch_request_id = 0;
            if (findPeer(src_node)) |peer| {
                if (ack.status != .ok) peer.launch_requested = false;
            }

            if (ack.status == .ok) {
                g_remote_launch_complete = true;
                lib.serialWrite("clusterd: remote launch acknowledged\n");
            } else {
                lib.serialWrite("clusterd: remote launch rejected\n");
                maybeRequestRemoteLaunch(bs, scratch_phys, scratch_va, token);
            }
        },
        .resource_advertisement => {
            if (msg_payload_len != @sizeOf(clusterd_proto.ResourceAdvertisement)) return;
            const res: *align(1) const clusterd_proto.ResourceAdvertisement = @ptrFromInt(msg_payload_va);
            const peer = ensurePeer(src_node) orelse return;
            peer.resources = res.*;
            peer.has_resources = true;
            if (!peer.announced) {
                sendLocalResourceAdvertisement(scratch_phys, scratch_va, token, src_node);
                peer.announced = true;
            }
            maybeRequestRemoteLaunch(bs, scratch_phys, scratch_va, token);
        },
        .resource_snapshot_request => {
            sendResourceSnapshotReply(scratch_phys, scratch_va, token, src_node);
        },
        .resource_snapshot_reply => {
            if (msg_payload_len != @sizeOf(clusterd_proto.ResourceSnapshotReply)) return;
            const reply: *align(1) const clusterd_proto.ResourceSnapshotReply = @ptrFromInt(msg_payload_va);
            var idx: usize = 0;
            const count = @min(@as(usize, reply.count), clusterd_proto.MAX_RESOURCE_SNAPSHOT_ENTRIES);
            while (idx < count) : (idx += 1) {
                const entry = reply.entries[idx];
                const node = lib.Ipv6Addr{ .bytes = entry.node_addr };
                const peer = ensurePeer(node) orelse continue;
                peer.resources = entry.resources;
                peer.has_resources = true;
            }
            maybeRequestRemoteLaunch(bs, scratch_phys, scratch_va, token);
        },
        .vm_list_request, .vm_list_reply => {},
    }
}

fn handleKernelControlReply(scratch_phys: u64, scratch_va: u64, token: u64, recv_va: u64) void {
    if (!g_pending_inbound_launch.active) return;

    const ctrl: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
    if (ctrl.op != .create_microvm or ctrl.payload_len != @sizeOf(lib.CreateMicrovmResult)) return;

    const result: *align(1) const lib.CreateMicrovmResult = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
    const result_copy = result.*;
    const pending = g_pending_inbound_launch;
    g_pending_inbound_launch = .{};

    if (result_copy.status == .ok) {
        reserveLocalResources(pending.mem_pages, pending.vcpus);
    }
    sendLaunchAck(scratch_phys, scratch_va, token, IPV6_ALL_NODES_MULTICAST, pending.request_id, result_copy);
    sendLocalResourceAdvertisement(scratch_phys, scratch_va, token, pending.requester_node);
}

fn dispatchDipcMessage(
    bs: *const BootstrapDescriptor,
    dipc_phys: u64,
    token: u64,
    recv_va: u64,
) void {
    const in_header: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
    if (isLoopback(g_local_node) and !isLoopback(in_header.dst.node)) {
        g_local_node = in_header.dst.node;
        g_local_resources.flags |= lib.NODE_FLAG_NODE_ADDR_CONFIGURED;
    }
    const payload_len = @as(usize, in_header.payload_len);
    const payload_ptr: [*]const u8 = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);

    const ctrl_hdr: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
    if (payload_len >= lib.CONTROL_HEADER_SIZE and
        ctrl_hdr.op == .registry_sync)
    {
        handleRegistrySync(bs, dipc_phys, DMA_BASE_VA, token, recv_va);
    } else if (in_header.src.endpoint == bs.reserved_kernel_control_endpoint and
        payload_len >= lib.CONTROL_HEADER_SIZE)
    {
        handleKernelControlReply(dipc_phys, DMA_BASE_VA, token, recv_va);
    } else if (in_header.src.endpoint == @intFromEnum(lib.ReservedEndpoint.netd) or
               (payload_len >= 4 and std.mem.readInt(u32, payload_ptr[0..4], .little) == netd_proto.MAGIC))
    {
        handleNetdProtocol(bs, dipc_phys, DMA_BASE_VA, token, recv_va);
    } else if (payload_len >= 4 and std.mem.readInt(u32, payload_ptr[0..4], .little) == clusterd_proto.MAGIC) {
        handleClusterdProtocol(bs, dipc_phys, DMA_BASE_VA, token, recv_va);
    }
}

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    lib.serialWrite("clusterd: starting\n");
    _ = lib.syscall(SYS_REGISTER, 0, EP_CLUSTERD, token);
    lib.serialWrite("clusterd: registered at endpoint 7\n");

    const dipc_phys = lib.syscall(SYS_ALLOC_DMA, 1, 0, token);
    if (dipc_phys == 0) {
        lib.serialWrite("clusterd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    g_local_node = lib.Ipv6Addr{ .bytes = bs.local_node };
    seedLocalResources();

    // Send initial query to netd immediately
    _ = sendNetdMessage(dipc_phys, DMA_BASE_VA, token, .get_node_addr, &[_]u8{});
    maybeRequestRemoteLaunch(bs, dipc_phys, DMA_BASE_VA, token);

    var poll_ticks: u32 = 0;
    while (true) {
        poll_ticks +%= 1;
        if (poll_ticks % 5 == 0) {
            if (isLoopback(g_local_node)) {
                _ = sendNetdMessage(dipc_phys, DMA_BASE_VA, token, .get_node_addr, &[_]u8{});
            } else if (!g_remote_launch_complete and g_pending_launch_request_id == 0) {
                const req = netd_proto.PeerSnapshotRequest{};
                _ = sendNetdMessage(dipc_phys, DMA_BASE_VA, token, .peer_snapshot_request, std.mem.asBytes(&req));
                // Also advance the local-launch fallback timer each tick.
                maybeRequestRemoteLaunch(bs, dipc_phys, DMA_BASE_VA, token);
            }
        }

        while (true) {
            const page_phys = lib.syscall(lib.SYS_TRY_RECV, 0, 0, token);
            if (page_phys == 0) break;
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                dispatchDipcMessage(bs, dipc_phys, token, recv_va);
                _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
            } else {
                _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
            }
        }

        _ = lib.syscall(SYS_YIELD, 0, 0, token);
        asm volatile ("pause");
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
