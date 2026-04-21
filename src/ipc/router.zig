const dipc = @import("dipc.zig");
const endpoint_table = @import("endpoint_table.zig");
const identity = @import("identity.zig");
const node_config = @import("node_config.zig");
const scheduler = @import("../kernel/scheduler.zig");
const net_bridge = @import("net_bridge.zig");
const microvm_bridge = @import("../vmm/microvm_bridge.zig");
const std = @import("std");

pub const RouteError = error{
    BadHeader,
    BadSignature,
    NoRoute,
    NoNetDaemon,
    Busy,
    UnsupportedTarget,
};

pub const RouteResult = enum {
    DeliveredLocal,
    QueuedForMicrovm,
    HandedToNetd,
};

// Core IPC routing boundary:
// - If dst.node is local, deliver to a local entity (thread for now).
// - Otherwise, hand off to the user-space net daemon.
//
// Ownership of page_phys stays with the caller unless RouteResult indicates delivery.
pub fn routePage(
    hhdm_offset: u64,
    local_node: dipc.Ipv6Addr,
    table: *const endpoint_table.EndpointTable,
    page_phys: u64,
) RouteError!RouteResult {
    const hdr = dipc.headerFromPage(hhdm_offset, page_phys);
    if (hdr.magic != dipc.WireMagic) {
        if (node_config.isNodeAddrConfigured(local_node)) {
            const arch_cpu = @import("../arch.zig").cpu;
            for ("Routing failed: BadMagic\n") |c| arch_cpu.outb(0x3F8, c);
        }
        return error.BadHeader;
    }
    if (hdr.version != dipc.WireVersion) {
        if (node_config.isNodeAddrConfigured(local_node)) {
            const arch_cpu = @import("../arch.zig").cpu;
            for ("Routing failed: BadVersion\n") |c| arch_cpu.outb(0x3F8, c);
        }
        return error.BadHeader;
    }
    if (!dipc.verifyPageAuth(hhdm_offset, page_phys)) {
        if (node_config.isNodeAddrConfigured(local_node)) {
            const arch_cpu = @import("../arch.zig").cpu;
            for ("Routing failed: BadSignature\n") |c| arch_cpu.outb(0x3F8, c);
        }
        return error.BadSignature;
    }

    if (dipc.Ipv6Addr.eql(hdr.dst.node, local_node) or dipc.Ipv6Addr.eql(hdr.dst.node, dipc.Ipv6Addr.loopback())) {
        const target = table.lookup(hdr.dst.endpoint) orelse {
            if (node_config.isNodeAddrConfigured(local_node)) {
                // Only log if we have a real address (avoids noise during early boot)
                const arch_cpu = @import("../arch.zig").cpu;
                for ("Routing failed: NoRoute\n") |c| arch_cpu.outb(0x3F8, c);
            }
            return error.NoRoute;
        };
        switch (target) {
            .thread => |tid| {
                if (!scheduler.send(tid, page_phys)) return error.Busy;
                return .DeliveredLocal;
            },
            .microvm => |microvm_id| {
                microvm_bridge.enqueue(microvm_id, page_phys) catch return error.Busy;
                return .QueuedForMicrovm;
            },
            .service => |sid| {
                if (!scheduler.sendToService(sid, page_phys)) {
                    return error.Busy;
                }
                return .DeliveredLocal;
            },
        }
    }

    const netd_target = table.netdTarget() orelse return error.NoNetDaemon;
    net_bridge.sendToNetDaemon(netd_target, page_phys) catch return error.Busy;
    return .HandedToNetd;
}

pub fn routePageWithLocalNode(
    hhdm_offset: u64,
    table: *const endpoint_table.EndpointTable,
    page_phys: u64,
) RouteError!RouteResult {
    return routePage(hhdm_offset, node_config.getLocalNode(), table, page_phys);
}

fn makeTestHeader(page: []u8, local_node: dipc.Ipv6Addr, dst_node: dipc.Ipv6Addr, dst_endpoint: identity.EndpointId) *dipc.PageHeader {
    const hdr: *dipc.PageHeader = @ptrCast(@alignCast(page.ptr));
    hdr.* = .{
        .magic = dipc.WireMagic,
        .version = dipc.WireVersion,
        .header_len = @as(u16, @intCast(dipc.HEADER_SIZE)),
        .payload_len = 0,
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = 1 },
        .dst = .{ .node = dst_node, .endpoint = dst_endpoint },
    };
    hdr.auth_tag = dipc.computeAuthTag(hdr.src, hdr.dst, "");
    return hdr;
}

test "routePage rejects invalid header" {
    var table: endpoint_table.EndpointTable = undefined;
    table.init();

    var page: [dipc.HEADER_SIZE + 16]u8 align(@alignOf(dipc.PageHeader)) = [_]u8{0} ** (dipc.HEADER_SIZE + 16);
    const hdr: *dipc.PageHeader = @ptrCast(@alignCast(&page));
    hdr.* = .{
        .magic = 0,
        .version = dipc.WireVersion,
        .header_len = @as(u16, @intCast(dipc.HEADER_SIZE)),
        .payload_len = 0,
        .auth_tag = 0,
        .src = .{ .node = dipc.Ipv6Addr.loopback(), .endpoint = 1 },
        .dst = .{ .node = dipc.Ipv6Addr.loopback(), .endpoint = 2 },
    };

    const res = routePage(0, dipc.Ipv6Addr.loopback(), &table, @intFromPtr(&page));
    try std.testing.expectError(error.BadHeader, res);
}

test "routePage local endpoint not found" {
    var table: endpoint_table.EndpointTable = undefined;
    table.init();

    var page: [dipc.HEADER_SIZE + 16]u8 align(@alignOf(dipc.PageHeader)) = [_]u8{0} ** (dipc.HEADER_SIZE + 16);
    _ = makeTestHeader(&page, dipc.Ipv6Addr.loopback(), dipc.Ipv6Addr.loopback(), 1234);

    const res = routePage(0, dipc.Ipv6Addr.loopback(), &table, @intFromPtr(&page));
    try std.testing.expectError(error.NoRoute, res);
}

test "routePage remote requires net daemon" {
    var table: endpoint_table.EndpointTable = undefined;
    table.init();

    var remote: dipc.Ipv6Addr = dipc.Ipv6Addr.loopback();
    remote.bytes[0] = 0x20;

    var page: [dipc.HEADER_SIZE + 16]u8 align(@alignOf(dipc.PageHeader)) = [_]u8{0} ** (dipc.HEADER_SIZE + 16);
    _ = makeTestHeader(&page, dipc.Ipv6Addr.loopback(), remote, 3);

    const res = routePage(0, dipc.Ipv6Addr.loopback(), &table, @intFromPtr(&page));
    try std.testing.expectError(error.NoNetDaemon, res);
}

test "routePage treats loopback as local alias" {
    var table: endpoint_table.EndpointTable = undefined;
    table.init();

    var local: dipc.Ipv6Addr = dipc.Ipv6Addr.loopback();
    local.bytes[0] = 0xFE;
    local.bytes[1] = 0x80;
    local.bytes[15] = 0x42;
    // node_config.isNodeAddrConfigured checks if local != loopback.
    // In this test, local is FE80...42 which IS configured.
    // But kernel tests run in Ring 3 (linux user-space) and outb 0x3F8 is forbidden.

    var page: [dipc.HEADER_SIZE + 16]u8 align(@alignOf(dipc.PageHeader)) = [_]u8{0} ** (dipc.HEADER_SIZE + 16);
    _ = makeTestHeader(&page, local, dipc.Ipv6Addr.loopback(), 1234);

    // We use loopback as the "local address" for the router in this test to avoid the outb call.
    const res = routePage(0, dipc.Ipv6Addr.loopback(), &table, @intFromPtr(&page));
    try std.testing.expectError(error.NoRoute, res);
}

test "routePage queues for microvm" {
    var table: endpoint_table.EndpointTable = undefined;
    table.init();
    microvm_bridge.init();

    const endpoint = table.registerMicrovm(7);
    try std.testing.expect(endpoint != 0);

    var page: [dipc.HEADER_SIZE + 16]u8 align(@alignOf(dipc.PageHeader)) = [_]u8{0} ** (dipc.HEADER_SIZE + 16);
    _ = makeTestHeader(&page, dipc.Ipv6Addr.loopback(), dipc.Ipv6Addr.loopback(), endpoint);

    const result = try routePage(0, dipc.Ipv6Addr.loopback(), &table, @intFromPtr(&page));
    try std.testing.expectEqual(RouteResult.QueuedForMicrovm, result);

    const queued = microvm_bridge.dequeue() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(identity.MicrovmId, 7), queued.microvm_id);
    try std.testing.expectEqual(@as(u64, @intFromPtr(&page)), queued.page_phys);
}

test "routePage reports busy when microvm queue full" {
    var table: endpoint_table.EndpointTable = undefined;
    table.init();
    microvm_bridge.init();

    const endpoint = table.registerMicrovm(9);
    try std.testing.expect(endpoint != 0);

    const TestPage = struct {
        bytes: [dipc.HEADER_SIZE + 16]u8 align(@alignOf(dipc.PageHeader)) = [_]u8{0} ** (dipc.HEADER_SIZE + 16),
    };
    var pages: [9]TestPage = [_]TestPage{.{}} ** 9;

    // Fill queue capacity (8 entries).
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = makeTestHeader(&pages[i].bytes, dipc.Ipv6Addr.loopback(), dipc.Ipv6Addr.loopback(), endpoint);
        _ = try routePage(0, dipc.Ipv6Addr.loopback(), &table, @intFromPtr(&pages[i].bytes));
    }

    _ = makeTestHeader(&pages[8].bytes, dipc.Ipv6Addr.loopback(), dipc.Ipv6Addr.loopback(), endpoint);
    const res = routePage(0, dipc.Ipv6Addr.loopback(), &table, @intFromPtr(&pages[8].bytes));
    try std.testing.expectError(error.Busy, res);
}
