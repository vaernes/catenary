const std = @import("std");
const builtin = @import("builtin");

// Capability-scoped buffer grants for Ring-3 virtio backends (storaged, netd)
// Ensures bounded lifetimes, read/write directions, and per-VM isolation.

pub const GrantDirection = enum(u8) {
    read = 1,
    write = 2,
    read_write = 3,
};

pub const BufferGrant = struct {
    vmid: u32 = 0,
    chain_head: u16 = 0,
    gpa: u64 = 0,
    hpa: u64 = 0,
    len: u32 = 0,
    direction: GrantDirection = .read,
    generation: u32 = 0,
    active: bool = false,
};

pub const MAX_GRANTS: usize = 32;
var grant_table: [MAX_GRANTS]BufferGrant = @splat(.{});
var next_grant_id: u32 = 1;
var grant_lock: bool = false;

fn acquireLock() u64 {
    var flags: u64 = 0;
    if (!builtin.is_test and comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\pushfq
            \\popq %[flags]
            \\cli
            : [flags] "=r" (flags),
        );
    }
    while (@atomicRmw(bool, &grant_lock, .Xchg, true, .seq_cst)) {
        if (!builtin.is_test and comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("pause");
        } else {
            std.atomic.spinLoopHint();
        }
    }
    return flags;
}

fn releaseLock(flags: u64) void {
    @atomicStore(bool, &grant_lock, false, .seq_cst);
    if (!builtin.is_test and comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\pushq %[flags]
            \\popfq
            :
            : [flags] "r" (flags),
        );
    }
}

pub fn acquireGrant(vmid: u32, chain_head: u16, gpa: u64, hpa: u64, len: u32, direction: GrantDirection) ?u32 {
    if (vmid == 0 or len == 0 or hpa == 0) return null;
    const flags = acquireLock();
    defer releaseLock(flags);

    for (&grant_table) |*entry| {
        if (!entry.active) {
            const gid = next_grant_id;
            next_grant_id +%= 1;
            if (next_grant_id == 0) next_grant_id = 1;

            entry.* = .{
                .vmid = vmid,
                .chain_head = chain_head,
                .gpa = gpa,
                .hpa = hpa,
                .len = len,
                .direction = direction,
                .generation = gid,
                .active = true,
            };
            return gid;
        }
    }
    return null;
}

pub fn validateGrant(grant_id: u32, vmid: u32, required_len: u32, required_dir: GrantDirection) ?u64 {
    const flags = acquireLock();
    defer releaseLock(flags);

    for (&grant_table) |*entry| {
        if (entry.active and entry.generation == grant_id) {
            if (entry.vmid != vmid) return null;
            if (entry.len < required_len) return null;
            if (entry.direction != .read_write and entry.direction != required_dir) return null;
            return entry.hpa;
        }
    }
    return null;
}

pub fn validateGrantForChain(vmid: u32, chain_head: u16, required_len: u32, required_dir: GrantDirection) ?u64 {
    const flags = acquireLock();
    defer releaseLock(flags);

    for (&grant_table) |*entry| {
        if (entry.active and entry.vmid == vmid and entry.chain_head == chain_head) {
            if (entry.len < required_len) return null;
            if (entry.direction != .read_write and entry.direction != required_dir) return null;
            return entry.hpa;
        }
    }
    return null;
}

pub fn releaseGrant(grant_id: u32, vmid: u32) bool {
    const flags = acquireLock();
    defer releaseLock(flags);

    for (&grant_table) |*entry| {
        if (entry.active and entry.generation == grant_id and entry.vmid == vmid) {
            entry.* = .{};
            return true;
        }
    }
    return false;
}

pub fn releaseGrantForChain(vmid: u32, chain_head: u16) bool {
    const flags = acquireLock();
    defer releaseLock(flags);

    for (&grant_table) |*entry| {
        if (entry.active and entry.vmid == vmid and entry.chain_head == chain_head) {
            entry.* = .{};
            return true;
        }
    }
    return false;
}

pub fn releaseAllForVm(vmid: u32) void {
    const flags = acquireLock();
    defer releaseLock(flags);

    for (&grant_table) |*entry| {
        if (entry.active and entry.vmid == vmid) {
            entry.* = .{};
        }
    }
}

pub fn getActiveCountForVm(vmid: u32) usize {
    const flags = acquireLock();
    defer releaseLock(flags);

    var count: usize = 0;
    for (&grant_table) |*entry| {
        if (entry.active and entry.vmid == vmid) count += 1;
    }
    return count;
}

test "buffer_grant: acquire, validate direction/bounds, and release" {
    releaseAllForVm(1);
    const gid = acquireGrant(1, 4, 0x1000, 0x4000_1000, 512, .read) orelse return error.TestUnexpectedResult;

    // Correct validation by grant ID
    try std.testing.expectEqual(@as(?u64, 0x4000_1000), validateGrant(gid, 1, 512, .read));

    // Correct validation by chain head
    try std.testing.expectEqual(@as(?u64, 0x4000_1000), validateGrantForChain(1, 4, 512, .read));

    // Wrong direction rejected
    try std.testing.expectEqual(@as(?u64, null), validateGrant(gid, 1, 512, .write));
    try std.testing.expectEqual(@as(?u64, null), validateGrantForChain(1, 4, 512, .write));

    // Length overrun rejected
    try std.testing.expectEqual(@as(?u64, null), validateGrant(gid, 1, 1024, .read));

    // Wrong VM rejected
    try std.testing.expectEqual(@as(?u64, null), validateGrant(gid, 2, 512, .read));

    // Active count
    try std.testing.expectEqual(@as(usize, 1), getActiveCountForVm(1));
    try std.testing.expectEqual(@as(usize, 0), getActiveCountForVm(2));

    // Release by chain
    try std.testing.expect(releaseGrantForChain(1, 4));
    try std.testing.expectEqual(@as(?u64, null), validateGrant(gid, 1, 512, .read));
    try std.testing.expectEqual(@as(usize, 0), getActiveCountForVm(1));
}
