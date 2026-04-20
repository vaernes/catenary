const std = @import("std");
const limine = @import("../kernel/limine.zig");
const pmm = @import("../kernel/pmm.zig");
const scheduler = @import("../kernel/scheduler.zig");
const dipc = @import("../ipc/dipc.zig");
const service_registry = @import("service_registry.zig");
const service_launch = @import("service_launch.zig");
const service_bootstrap = @import("service_bootstrap.zig");
const task_loader = @import("task_loader.zig");

const main = @import("../main.zig");
const kernel = @import("../main.zig");

const fb = @import("../kernel/fb.zig");

pub const ManagerError = error{
    ModuleNotFound,
    LoadFailed,
    LaunchFailed,
};

fn bootLog(s: []const u8) void {
    main.serialWrite(s);
    fb.printString(s);
}

fn serviceName(kind: service_bootstrap.ServiceKind) []const u8 {
    return switch (kind) {
        .netd => "netd",
        .storaged => "storaged",
        .dashd => "dashd",
        .containerd => "containerd",
        .clusterd => "clusterd",
        .inputd => "inputd",
        .windowd => "windowd",
        .configd => "configd",
        else => "service",
    };
}

/// Scans Limine modules and boots all recognized services.
pub fn bootAll(hhdm_offset: u64, local_node: dipc.Ipv6Addr) ManagerError!void {
    const response = main.limine_module_request.response orelse {
        return error.ModuleNotFound;
    };
    var launched_kinds: [10]bool = [_]bool{false} ** 10;

    for (0..response.module_count) |i| {
        const module_ptr = response.modules.?[i] orelse continue;
        const module: *limine.File = @ptrCast(module_ptr);
        const name = std.mem.span(module.path);

        const kind: ?service_bootstrap.ServiceKind = if (std.mem.endsWith(u8, name, "netd.elf"))
            .netd
        else if (std.mem.endsWith(u8, name, "storaged.elf"))
            .storaged
        else if (std.mem.endsWith(u8, name, "dashd.elf"))
            .dashd
        else if (std.mem.endsWith(u8, name, "containerd.elf"))
            .containerd
        else if (std.mem.endsWith(u8, name, "clusterd.elf"))
            .clusterd
        else if (std.mem.endsWith(u8, name, "inputd.elf"))
            .inputd
        else if (std.mem.endsWith(u8, name, "windowd.elf"))
            .windowd
        else if (std.mem.endsWith(u8, name, "configd.elf"))
            .configd
        else
            null;

        const service_kind = kind orelse continue;
        const kind_index: usize = @intFromEnum(service_kind);
        if (launched_kinds[kind_index]) continue;

        try launchService(hhdm_offset, local_node, service_kind, module.address[0..module.size]);
        launched_kinds[kind_index] = true;
    }
}

fn launchService(
    hhdm_offset: u64,
    local_node: dipc.Ipv6Addr,
    kind: service_bootstrap.ServiceKind,
    elf_bytes: []const u8,
) ManagerError!void {
    const task = task_loader.loadElfIntoNewSpace(elf_bytes, hhdm_offset) catch {
        main.serialWrite("service_manager: loadElfIntoNewSpace failed\n");
        return error.LoadFailed;
    };

    const sid = service_registry.reserve(kind) orelse {
        main.serialWrite("service_manager: service_registry.reserve failed\n");
        return error.LaunchFailed;
    };

    // Create launch descriptor and bootstrap page.
    // For now we use oneshot or persistent based on kind.
    const mode: service_bootstrap.RuntimeMode = if (kind == .netd) .persistent else .oneshot;

    const descriptor = service_launch.allocLaunch(
        hhdm_offset,
        local_node,
        sid,
        kind,
        mode,
        task.entry,
        task.stack_top,
    ) catch {
        main.serialWrite("service_manager: service_launch.allocLaunch failed\n");
        return error.LaunchFailed;
    };

    if (!service_registry.bindLaunch(
        sid,
        mode,
        descriptor.entry_rip,
        descriptor.stack_top,
        task.cr3,
        descriptor.bootstrap_page_phys,
    )) {
        main.serialWrite("service_manager: service_registry.bindLaunch failed\n");
        return error.LaunchFailed;
    }

    // Map bootstrap page into user space address space
    task_loader.mapPageInAddressSpace(task.cr3, hhdm_offset, task_loader.USER_BOOTSTRAP_VADDR, descriptor.bootstrap_page_phys, 0x7) catch {
        main.serialWrite("service_manager: task_loader.mapPageInAddressSpace failed\n");
        return error.LaunchFailed;
    };

    // Spawn thread
    const tid = scheduler.spawnThreadForService(sid, kind) catch {
        main.serialWrite("service_manager: scheduler.spawnThreadForService failed\n");
        return error.LaunchFailed;
    };

    // Register initial thread in endpoint table
    const table = @import("../ipc/manager.zig").endpointTable();
    switch (kind) {
        .netd => table.registerReservedNetdThread(tid),
        .storaged => table.registerReservedStoragedThread(tid),
        .dashd => table.registerReservedDashdThread(tid),
        .containerd => table.registerReservedContainerdThread(tid),
        .clusterd => table.registerReservedClusterdThread(tid),
        .inputd => table.registerReservedInputdThread(tid),
        .windowd => table.registerReservedWindowdThread(tid),
        .configd => table.registerReservedConfigdThread(tid),
        else => {},
    }

    bootLog("service_manager: launched ");
    bootLog(serviceName(kind));
    bootLog("\n");
}
