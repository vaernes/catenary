const std = @import("std");
const testing = std.testing;
const varde_shell = @import("varde_shell.zig");
const service_registry = @import("../services/service_registry.zig");
const microvm_registry = @import("../vmm/microvm_registry.zig");
const pmm = @import("pmm.zig");
const limine = @import("limine.zig");
const scheduler = @import("scheduler.zig");
const HistoryRing = @import("../user/tui/history_ring.zig").HistoryRing;

fn getMilestone() []const u8 {
    return varde_shell.test_last_milestone[0..varde_shell.test_last_milestone_len];
}

fn getHistoryLog() []const u8 {
    return varde_shell.history_buf[0..varde_shell.history_pos];
}

test "HistoryRing: 16-entry circular rollover, Up/Down recall, draft stashing, and duplicate rejection" {
    var ring = HistoryRing.init();

    // Empty ring returns null on recall
    try testing.expect(ring.recallUp("draft", 5) == null);
    try testing.expect(ring.recallDown() == null);

    // Push 16 commands ("cmd-00" .. "cmd-15")
    var buf: [16]u8 = undefined;
    for (0..16) |i| {
        const s = try std.fmt.bufPrint(&buf, "cmd-{d:0>2}", .{i});
        ring.push(s);
    }
    try testing.expectEqual(@as(usize, 16), ring.count);

    // Consecutive duplicate is rejected
    ring.push("cmd-15");
    try testing.expectEqual(@as(usize, 16), ring.count);

    // 17th unique command rolls over and overwrites oldest ("cmd-00")
    ring.push("cmd-16");
    try testing.expectEqual(@as(usize, 16), ring.count);

    // Start typing uncommitted draft "vm-create my-vm", cursor at pos 9, then press Up
    const r1 = ring.recallUp("vm-create my-vm", 9).?;
    try testing.expectEqualStrings("cmd-16", r1.text);
    try testing.expectEqual(@as(usize, 6), r1.cursor);

    // Traverse all the way to the oldest entry ("cmd-01", since "cmd-00" was overwritten)
    var last_res = r1;
    for (0..20) |_| {
        last_res = ring.recallUp("ignored-while-browsing", 0).?;
    }
    try testing.expectEqualStrings("cmd-01", last_res.text);

    // Traverse back down 15 times to "cmd-16"
    for (0..15) |_| {
        last_res = ring.recallDown().?;
    }
    try testing.expectEqualStrings("cmd-16", last_res.text);

    // One more Down restores the uncommitted draft AND original cursor position!
    const restored = ring.recallDown().?;
    try testing.expectEqualStrings("vm-create my-vm", restored.text);
    try testing.expectEqual(@as(usize, 9), restored.cursor);
    try testing.expect(!ring.isBrowsing());
}

test "varde_shell: all 14 commands execute, format output, and emit exact COM1 milestones" {
    service_registry.init();
    microvm_registry.init();

    var backing: [16 * 4096]u8 align(4096) = @splat(0);
    const hhdm = @intFromPtr(&backing);
    var entry = limine.MemmapEntry{
        .base = 0,
        .length = @sizeOf(@TypeOf(backing)),
        .kind = limine.MEMMAP_USABLE,
    };
    var entries = [_]*limine.MemmapEntry{&entry};
    var memmap = limine.MemmapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = @ptrCast(&entries),
    };
    pmm.init(&memmap, hhdm);

    varde_shell.init();

    // 1. help
    varde_shell.dispatch("help");
    try testing.expectEqualStrings("varde_shell: executed 'help'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Varde Operator Shell") != null);
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Hotkeys:") != null);

    // 2. ps
    varde_shell.dispatch("ps");
    try testing.expectEqualStrings("varde_shell: executed 'ps'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "SID  Service       State        Origin") != null);

    // 3. vm-create rejects unsupported multi-vCPU requests without allocating a VM.
    varde_shell.dispatch("vm-create rejected-vm 2 64");
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "supports one vCPU per MicroVM") != null);
    try testing.expect(microvm_registry.lookup(1) == null);

    // 4. vm-create accepts the implemented single-vCPU profile.
    varde_shell.dispatch("vm-create test-vm 1 64");
    try testing.expectEqualStrings("varde_shell: executed 'vm-create'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Created and started MicroVM 'test-vm'") != null);

    // 5. vmlist
    varde_shell.dispatch("vmlist");
    try testing.expectEqualStrings("varde_shell: executed 'vmlist'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "test-vm") != null);

    // 6. vm-kill
    varde_shell.dispatch("vm-kill 1");
    try testing.expectEqualStrings("varde_shell: executed 'vm-kill'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "MicroVM 1 stop requested.") != null);
    try testing.expect(microvm_registry.completeStop(1));

    // 7. vm-start
    varde_shell.dispatch("vm-start 1");
    try testing.expectEqualStrings("varde_shell: executed 'vm-start'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "MicroVM 1 started.") != null);

    // 8. vm-delete (stop first or delete stopped VM)
    varde_shell.dispatch("vm-kill 1");
    try testing.expect(microvm_registry.completeStop(1));
    varde_shell.dispatch("vm-delete 1");
    try testing.expectEqualStrings("varde_shell: executed 'vm-delete'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "MicroVM 1 deleted.") != null);

    // 9. cluster
    varde_shell.dispatch("cluster");
    try testing.expectEqualStrings("varde_shell: executed 'cluster'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Cluster Topology & Node Status:") != null);

    // 10. net-stat
    varde_shell.dispatch("net-stat");
    try testing.expectEqualStrings("varde_shell: executed 'net-stat'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Virtio-Net      : RX/TX Queues Ready") != null);

    // 11. storage-stat
    varde_shell.dispatch("storage-stat");
    try testing.expectEqualStrings("varde_shell: executed 'storage-stat'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Storage Subsystem Status:") != null);

    // 12. top
    scheduler.threads[0].state = .Running;
    scheduler.threads[0].id = 1;
    varde_shell.dispatch("top");
    try testing.expectEqualStrings("varde_shell: executed 'top'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "TID   Name             SID   VMID  State   CPU%   Ticks(M)") != null);

    // 12. memory
    varde_shell.dispatch("memory");
    try testing.expectEqualStrings("varde_shell: executed 'memory'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Physical Memory Manager (4 KiB frames):") != null);

    // 13. status
    varde_shell.dispatch("status");
    try testing.expectEqualStrings("varde_shell: executed 'status'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Kernel status: ") != null);

    // 14. clear
    varde_shell.dispatch("clear");
    try testing.expectEqualStrings("varde_shell: executed 'clear'\n", getMilestone());
    try testing.expectEqual(@as(usize, 0), varde_shell.history_pos);

    // 15. Phase 11 Full-VM admission gate & warm reboot commands
    varde_shell.dispatch("vm-create-full win11-26h2");
    try testing.expectEqualStrings("varde_shell: executed 'vm-create-full'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "missing-installer-media") != null);

    varde_shell.dispatch("vm-create-full uefi-revoked");
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "secure-boot-dbx-revoked") != null);

    varde_shell.dispatch("vm-create-full uefi-test");
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Admitted and started UEFI Full-VM 'uefi-test'") != null);

    varde_shell.dispatch("vm-send 2 disk-write");
    try testing.expectEqualStrings("varde_shell: executed 'vm-send'\n", getMilestone());
    try testing.expect(microvm_registry.hasConsoleInput(2));

    varde_shell.dispatch("vm-reboot 2");
    try testing.expectEqualStrings("varde_shell: executed 'vm-reboot'\n", getMilestone());
    try testing.expect(microvm_registry.lookup(2).?.reboot_requested);

    // 16. Phase 12 Coordinated VM Snapshot & Restore commands
    varde_shell.dispatch("vm-snapshot 2 snap-gold");
    try testing.expectEqualStrings("varde_shell: executed 'vm-snapshot'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Coordinated snapshot created for VM 2") != null);

    varde_shell.dispatch("vm-restore 2 1");
    try testing.expectEqualStrings("varde_shell: executed 'vm-restore'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "VM 2 restored to generation 1.") != null);

    // 17. Phase 13 Nested VMX L0 capability validation
    varde_shell.dispatch("vm-nested-test 2");
    try testing.expectEqualStrings("varde_shell: executed 'vm-nested-test'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Nested VMX L0 capability validated for VM 2") != null);

    // 18. Phase 14 Capability-scoped buffer grant validation
    varde_shell.dispatch("vm-grant-test 2");
    try testing.expectEqualStrings("varde_shell: executed 'vm-grant-test'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Buffer grant capability validated for VM 2") != null);

    // 19. Phase 15 Cluster authentication, replay prevention & fencing validation
    varde_shell.dispatch("cluster-auth-test");
    try testing.expectEqualStrings("varde_shell: executed 'cluster-auth-test'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Cluster authentication, monotonic replay prevention & fencing epochs validated.") != null);

    // 20. Phase 16 Cluster consensus, term election & quorum validation
    varde_shell.dispatch("cluster-quorum-test");
    try testing.expectEqualStrings("varde_shell: executed 'cluster-quorum-test'\n", getMilestone());
    try testing.expect(std.mem.indexOf(u8, getHistoryLog(), "Cluster consensus, term election, quorum validation & leader step-down validated.") != null);
}
