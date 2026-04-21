const dipc = @import("dipc.zig");

// Core IPC placeholder for node identity.
// For now this is a compile-time constant so it cannot silently drift at runtime.
// Later phases can populate this from a user-space control plane (or boot-time config)
// without moving networking/address assignment into Ring 0.

var local_node: dipc.Ipv6Addr = dipc.Ipv6Addr.loopback();
var node_locked: bool = false;

pub fn getLocalNode() dipc.Ipv6Addr {
    return local_node;
}

pub fn isLocalAddress(addr: dipc.Ipv6Addr) bool {
    return dipc.Ipv6Addr.eql(addr, local_node) or dipc.Ipv6Addr.eql(addr, dipc.Ipv6Addr.loopback());
}

pub fn setLocalNode(addr: dipc.Ipv6Addr) void {
    local_node = addr;
    node_locked = true;
}

pub fn assignLocalNode(addr: dipc.Ipv6Addr) bool {
    if (node_locked) return false;
    local_node = addr;
    node_locked = true;
    return true;
}

pub fn revokeLocalNode() void {
    local_node = dipc.Ipv6Addr.loopback();
    node_locked = false;
}

pub fn isLocalNodeLocked() bool {
    return node_locked;
}

pub fn isNodeAddrConfigured(addr: dipc.Ipv6Addr) bool {
    return !dipc.Ipv6Addr.eql(addr, dipc.Ipv6Addr.loopback());
}
