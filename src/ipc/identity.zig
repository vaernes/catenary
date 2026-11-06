const std = @import("std");
const dipc = @import("dipc.zig");

pub const NodeAddr = dipc.Ipv6Addr;
pub const EndpointId = dipc.EndpointId;
pub const Address = dipc.Address;

pub const ThreadId = u32;
pub const MicrovmId = u32;

pub const EntityKind = enum(u8) {
    thread = 1,
    microvm = 2,
    service = 3,
};

pub const LocalEntity = union(EntityKind) {
    thread: ThreadId,
    microvm: MicrovmId,
    service: u32,
};

// Reserved endpoints are stable ABI for user-space daemons.
// Keep this list small; most endpoints should be dynamically allocated.
pub const ReservedEndpoint = enum(EndpointId) {
    // User-space IPv6 routing + orchestration daemon.
    netd = 1,

    // Kernel-owned control endpoint (for future user-space control plane interactions).
    // This is NOT a networking endpoint; it's a stable addressable target within the DIPC namespace.
    kernel_control = 2,

    // User-space block storage daemon.
    storaged = 4,

    // User-space dashboard daemon.
    dashd = 5,

    // Kernel-owned router ingress endpoint (bring-up only).
    // Callers can send a page-handle here to have the kernel route it locally or hand it to netd.
    router = 3,

    // User-space container orchestration daemon.
    containerd = 6,

    // User-space cluster workload scheduler.
    clusterd = 7,

    // User-space input daemon.
    inputd = 8,

    // User-space compositor.
    windowd = 9,

    // User-space configuration app.
    configd = 10,
};

pub const FIRST_DYNAMIC_ENDPOINT: EndpointId = 0x100;

/// Kernel-originated MicroVM virtio-net TX pages use this base plus the VM ID.
pub const MICROVM_GUEST_TX_ENDPOINT_BASE: EndpointId = 0x1000;

pub fn microvmIdFromGuestTxEndpoint(endpoint: EndpointId) ?MicrovmId {
    if (endpoint < MICROVM_GUEST_TX_ENDPOINT_BASE) return null;
    const microvm_id = endpoint - MICROVM_GUEST_TX_ENDPOINT_BASE;
    if (microvm_id == 0 or microvm_id > std.math.maxInt(MicrovmId)) return null;
    return @intCast(microvm_id);
}

test "guest TX endpoint maps only valid MicroVM IDs" {
    try std.testing.expectEqual(@as(?MicrovmId, 7), microvmIdFromGuestTxEndpoint(MICROVM_GUEST_TX_ENDPOINT_BASE + 7));
    try std.testing.expectEqual(@as(?MicrovmId, null), microvmIdFromGuestTxEndpoint(MICROVM_GUEST_TX_ENDPOINT_BASE));
    try std.testing.expectEqual(@as(?MicrovmId, null), microvmIdFromGuestTxEndpoint(MICROVM_GUEST_TX_ENDPOINT_BASE + std.math.maxInt(MicrovmId) + 1));
}
