const std = @import("std");
const build_options = @import("build_options");
const dipc = @import("../ipc/dipc.zig");
const endpoint_table = @import("../ipc/endpoint_table.zig");
const identity = @import("../ipc/identity.zig");
const node_config = @import("../ipc/node_config.zig");
const control_protocol = @import("control_protocol.zig");
const pmm = @import("../kernel/pmm.zig");
const router = @import("../ipc/router.zig");
const arch_cpu = @import("../arch/x86_64/cpu.zig");

pub const HandleError = (error{
    BadHeader,
    BadPayload,
    NotForKernel,
    Unauthorized,
    NodeLocked,
} || dipc.AllocError || router.RouteError);

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        asm volatile ("outb %al, %dx"
            :
            : [al] "{al}" (c),
              [dx] "{dx}" (@as(u16, 0x3F8)),
        );
    }
}

fn payloadBase(hhdm_offset: u64, page_phys: u64) [*]const u8 {
    return @ptrFromInt(page_phys + hhdm_offset + dipc.HEADER_SIZE);
}

fn isAuthorizedControlSource(hdr: *const dipc.PageHeader, op: control_protocol.ControlOp) bool {
    const dipc_local = node_config.getLocalNode();
    if (op != .set_node_addr and !dipc.Ipv6Addr.eql(hdr.src.node, dipc_local)) {
        for ("Control: reject: src_node mismatch\n") |c| arch_cpu.outb(0x3F8, c);
        return false;
    }
    if (hdr.src.endpoint != @intFromEnum(identity.ReservedEndpoint.netd)) {
        for ("Control: reject: src_endpoint mismatch\n") |c| arch_cpu.outb(0x3F8, c);
        return false;
    }
    return true;
}

fn isAuthorizedMicrovmSource(hdr: *const dipc.PageHeader) bool {
    const ep = hdr.src.endpoint;
    return ep == @intFromEnum(identity.ReservedEndpoint.clusterd) or
           ep == @intFromEnum(identity.ReservedEndpoint.windowd) or
           ep == @intFromEnum(identity.ReservedEndpoint.configd);
}

pub fn handleKernelControlPage(
    hhdm_offset: u64,
    table: *endpoint_table.EndpointTable,
    page_phys: u64,
) HandleError!void {
    const hdr = dipc.headerFromPage(hhdm_offset, page_phys);
    if (hdr.magic != dipc.WireMagic or hdr.version != dipc.WireVersion) return error.BadHeader;
    if (!dipc.verifyPageAuth(hhdm_offset, page_phys)) return error.BadHeader;
    if (hdr.dst.endpoint != @intFromEnum(identity.ReservedEndpoint.kernel_control)) return error.NotForKernel;

    const payload_len = @as(usize, hdr.payload_len);
    if (payload_len < @sizeOf(control_protocol.ControlHeader)) return error.BadPayload;
    if (payload_len > dipc.MAX_PAYLOAD) return error.BadPayload;

    const base = payloadBase(hhdm_offset, page_phys);
    const ch: *const control_protocol.ControlHeader = @ptrCast(@alignCast(base));

    const remaining = payload_len - @sizeOf(control_protocol.ControlHeader);
    const payload_ptr: [*]const u8 = base + @sizeOf(control_protocol.ControlHeader);

    if (@as(usize, ch.payload_len) != remaining) return error.BadPayload;

    switch (ch.op) {
        .register_netd => {
            if (!isAuthorizedControlSource(hdr, ch.op)) return error.Unauthorized;
            if (remaining != @sizeOf(control_protocol.RegisterNetdPayload)) return error.BadPayload;
            const p: *const control_protocol.RegisterNetdPayload = @ptrCast(@alignCast(payload_ptr));
            table.registerReservedNetdThread(p.thread_id);
        },
        .register_netd_service => {
            if (!isAuthorizedControlSource(hdr, ch.op)) return error.Unauthorized;
            if (remaining != @sizeOf(control_protocol.RegisterNetdServicePayload)) return error.BadPayload;
            const p: *const control_protocol.RegisterNetdServicePayload = @ptrCast(@alignCast(payload_ptr));
            const sr = @import("../services/service_registry.zig");
            const sid = sr.serviceIdForCapability(p.capability_token) orelse return error.Unauthorized;
            table.registerReservedNetdService(sid);
        },
        .register_storaged_service => {
            if (!isAuthorizedControlSource(hdr, ch.op)) return error.Unauthorized;
            if (remaining != @sizeOf(control_protocol.RegisterStoragedServicePayload)) return error.BadPayload;
            const p: *const control_protocol.RegisterStoragedServicePayload = @ptrCast(@alignCast(payload_ptr));
            const sr = @import("../services/service_registry.zig");
            const sid = sr.serviceIdForCapability(p.capability_token) orelse return error.Unauthorized;
            table.registerReservedStoragedService(sid);
        },
        .register_telemetry => {
            if (!isAuthorizedControlSource(hdr, ch.op)) return error.Unauthorized;
            if (remaining != @sizeOf(control_protocol.RegisterTelemetryPayload)) return error.BadPayload;
            const p: *const control_protocol.RegisterTelemetryPayload = @ptrCast(@alignCast(payload_ptr));
            const sr = @import("../services/service_registry.zig");
            const sid = sr.serviceIdForCapability(p.capability_token) orelse return error.Unauthorized;
            table.registerReservedDashdService(sid);
        },
        .set_node_addr => {
            if (!isAuthorizedControlSource(hdr, ch.op)) {
                for ("Control: set_node_addr auth failed\n") |c| arch_cpu.outb(0x3F8, c);
                return error.Unauthorized;
            }
            if (remaining != @sizeOf(control_protocol.SetNodeAddrPayload)) {
                for ("Control: set_node_addr length failed\n") |c| arch_cpu.outb(0x3F8, c);
                return error.BadPayload;
            }
            const p: *const control_protocol.SetNodeAddrPayload = @ptrCast(@alignCast(payload_ptr));
            if (!node_config.assignLocalNode(p.addr)) {
                for ("Control: set_node_addr lock failed\n") |c| arch_cpu.outb(0x3F8, c);
                return error.NodeLocked;
            }
            for ("Control: set_node_addr success\n") |c| arch_cpu.outb(0x3F8, c);
        },
        .revoke_node_addr => {
            if (!isAuthorizedControlSource(hdr, ch.op)) return error.Unauthorized;
            if (remaining != 0) return error.BadPayload;
            node_config.revokeLocalNode();
        },
        .pci_read_config => {
            const sr = @import("../services/service_registry.zig");
            const sid = sr.serviceIdForCapability(hdr.auth_tag) orelse return error.Unauthorized;
            if (sid != table.reserved_storaged_service) return error.Unauthorized;

            if (remaining != @sizeOf(control_protocol.PciReadConfigPayload)) return error.BadPayload;
            const p: *const control_protocol.PciReadConfigPayload = @ptrCast(@alignCast(payload_ptr));

            const addr = 0x80000000 | (@as(u32, p.bus) << 16) | (@as(u32, p.device) << 11) | (@as(u32, p.function) << 8) | (p.offset & 0xfc);
            arch_cpu.outl(0xcf8, addr);

            var value: u32 = 0;
            switch (p.size) {
                1 => value = @as(u32, arch_cpu.inb(@as(u16, 0x0cfc) + @as(u16, p.offset & 3))),
                2 => value = @as(u32, arch_cpu.inw(@as(u16, 0x0cfc) + @as(u16, p.offset & 2))),
                4 => value = arch_cpu.inl(0xcfc),
                else => return error.BadPayload,
            }

            // Create response DIPC page
            const table_const: *const endpoint_table.EndpointTable = table;
            const msg_page = try dipc.allocPageMessage(hhdm_offset, hdr.dst, hdr.src, std.mem.asBytes(&value));
            _ = try router.routePageWithLocalNode(hhdm_offset, table_const, msg_page);
        },
        .pci_write_config => {
            const sr = @import("../services/service_registry.zig");
            const sid = sr.serviceIdForCapability(hdr.auth_tag) orelse return error.Unauthorized;
            if (sid != table.reserved_storaged_service) return error.Unauthorized;

            if (remaining != @sizeOf(control_protocol.PciWriteConfigPayload)) return error.BadPayload;
            const p: *const control_protocol.PciWriteConfigPayload = @ptrCast(@alignCast(payload_ptr));

            const addr = 0x80000000 | (@as(u32, p.bus) << 16) | (@as(u32, p.device) << 11) | (@as(u32, p.function) << 8) | (p.offset & 0xfc);
            arch_cpu.outl(0xcf8, addr);

            switch (p.size) {
                1 => arch_cpu.outb(@as(u16, 0x0cfc) + @as(u16, p.offset & 3), @as(u8, @truncate(p.value))),
                2 => arch_cpu.outw(@as(u16, 0x0cfc) + @as(u16, p.offset & 2), @as(u16, @truncate(p.value))),
                4 => arch_cpu.outl(0xcfc, p.value),
                else => return error.BadPayload,
            }
        },
        .phys_alloc => {
            const sr = @import("../services/service_registry.zig");
            const sid = sr.serviceIdForCapability(hdr.auth_tag) orelse return error.Unauthorized;
            // Only storaged (DMA) and netd (buffer pools) should use this.
            if (sid != table.reserved_storaged_service and sid != table.reserved_netd_service) return error.Unauthorized;

            if (remaining != @sizeOf(control_protocol.PhysAllocPayload)) return error.BadPayload;
            const p: *const control_protocol.PhysAllocPayload = @ptrCast(@alignCast(payload_ptr));
            if (p.alignment_order >= 64) return error.BadPayload;

            const alignment_pages = @as(u64, 1) << @as(u6, @intCast(p.alignment_order));
            const phys = pmm.allocContiguousAligned(p.num_pages, alignment_pages) orelse 0;

            const res = control_protocol.PhysAllocResult{
                .phys_addr = phys,
                .num_pages = p.num_pages,
            };

            const msg_page = try dipc.allocPageMessage(hhdm_offset, hdr.dst, hdr.src, std.mem.asBytes(&res));
            const table_const: *const endpoint_table.EndpointTable = table;
            _ = try router.routePageWithLocalNode(hhdm_offset, table_const, msg_page);
        },
        .phys_free => {
            const sr = @import("../services/service_registry.zig");
            const sid = sr.serviceIdForCapability(hdr.auth_tag) orelse return error.Unauthorized;
            if (sid != table.reserved_storaged_service and sid != table.reserved_netd_service) return error.Unauthorized;

            if (remaining != @sizeOf(control_protocol.PhysFreePayload)) return error.BadPayload;
            const p: *const control_protocol.PhysFreePayload = @ptrCast(@alignCast(payload_ptr));

            var i: u32 = 0;
            while (i < p.num_pages) : (i += 1) {
                pmm.freePage(p.phys_addr + (@as(u64, i) * pmm.PAGE_SIZE));
            }
        },
        .virtio_blk_response => {
            const sr = @import("../services/service_registry.zig");
            const sid = sr.serviceIdForCapability(hdr.auth_tag) orelse return error.Unauthorized;
            if (sid != table.reserved_storaged_service) return error.Unauthorized;

            if (remaining != @sizeOf(control_protocol.VirtioBlkResponsePayload)) return error.BadPayload;
            const p: *const control_protocol.VirtioBlkResponsePayload = @ptrCast(@alignCast(payload_ptr));
            const microvm_bridge = @import("../vmm/microvm_bridge.zig");
            microvm_bridge.handleVirtioBlkResponse(p.vmid, p.head_idx, p.status);
        },
        .registry_sync => {
            if (remaining != @sizeOf(control_protocol.RegistrySyncPayload)) return error.BadPayload;
            const p: *const control_protocol.RegistrySyncPayload = @ptrCast(@alignCast(payload_ptr));
            const sr = @import("../services/service_registry.zig");
            if (!sr.registerRemoteService(p.service_id, p.service_kind, p.state, hdr.src.node)) {
                serialWrite("kernel_control: registry sync failed to register remote service\n");
            } else {
                serialWrite("kernel_control: remote service registered from sync\n");
            }
            // Forward to local clusterd and configd so they can react to remote node registrations.
            // Preserve hdr.src so the receiving daemon can identify which remote node sent it.
            const fwd_payload_len = @sizeOf(control_protocol.ControlHeader) + @sizeOf(control_protocol.RegistrySyncPayload);
            const fwd_payload: []const u8 = base[0..fwd_payload_len];
            const table_const: *const endpoint_table.EndpointTable = table;
            const clusterd_dst = dipc.Address{
                .node = node_config.getLocalNode(),
                .endpoint = @intFromEnum(identity.ReservedEndpoint.clusterd),
            };
            const configd_dst = dipc.Address{
                .node = node_config.getLocalNode(),
                .endpoint = @intFromEnum(identity.ReservedEndpoint.configd),
            };
            if (dipc.allocPageMessage(hhdm_offset, hdr.src, clusterd_dst, fwd_payload)) |fwd_page| {
                _ = router.routePageWithLocalNode(hhdm_offset, table_const, fwd_page) catch {};
            } else |_| {}
            if (dipc.allocPageMessage(hhdm_offset, hdr.src, configd_dst, fwd_payload)) |fwd_page| {
                _ = router.routePageWithLocalNode(hhdm_offset, table_const, fwd_page) catch {};
            } else |_| {}
        },
        // poll_netd_inbox and assign_node_addr are handled directly in the trap bridge
        // (user_mode.zig) and do not go through the DIPC page path, so the kernel
        // control handler treats them as unrecognised and returns an error to the caller.
        .poll_netd_inbox, .assign_node_addr => return error.BadPayload,
        .get_node_addr => {
            const res = control_protocol.NodeAddrResult{
                .addr = node_config.getLocalNode(),
            };
            const msg_page = try dipc.allocPageMessage(hhdm_offset, hdr.dst, hdr.src, std.mem.asBytes(&res));
            const table_const: *const endpoint_table.EndpointTable = table;
            _ = try router.routePageWithLocalNode(hhdm_offset, table_const, msg_page);
        },
        .create_microvm => {
            if (!isAuthorizedMicrovmSource(hdr)) return error.Unauthorized;
            if (remaining != @sizeOf(control_protocol.CreateMicrovmPayload)) return error.BadPayload;
            const p: *const control_protocol.CreateMicrovmPayload = @ptrCast(@alignCast(payload_ptr));

            if (build_options.vmm_active and build_options.services_active) {
                const vmx = @import("../arch/x86_64/vmx.zig");
                if (vmx.launchStagedInstance()) |id| {
                    serialWrite("kernel_control: staged MicroVM launched via DIPC\n");
                    _ = id;
                    return;
                } else |_| {}
            }

            const microvm_registry = @import("../vmm/microvm_registry.zig");
            if (microvm_registry.create(p.name, p.mem_pages, p.vcpus, p.kernel_phys, p.kernel_size, p.initramfs_phys, p.initramfs_size)) |id| {
                serialWrite("configd: MicroVM created via DIPC\n");
                _ = id;
            } else {
                return error.BadPayload;
            }
        },
        .start_microvm => {
            if (remaining != @sizeOf(control_protocol.StartMicrovmPayload)) return error.BadPayload;
            const p: *const control_protocol.StartMicrovmPayload = @ptrCast(@alignCast(payload_ptr));
            const microvm_registry = @import("../vmm/microvm_registry.zig");
            if (!microvm_registry.start(p.instance_id)) return error.BadPayload;
        },
        .stop_microvm => {
            if (!isAuthorizedMicrovmSource(hdr)) return error.Unauthorized;
            if (remaining != @sizeOf(control_protocol.StopMicrovmPayload)) return error.BadPayload;
            const p: *const control_protocol.StopMicrovmPayload = @ptrCast(@alignCast(payload_ptr));
            const microvm_registry = @import("../vmm/microvm_registry.zig");
            if (!microvm_registry.stop(p.instance_id)) return error.BadPayload;
        },
        .delete_microvm => {
            if (!isAuthorizedMicrovmSource(hdr)) return error.Unauthorized;
            if (remaining != @sizeOf(control_protocol.DeleteMicrovmPayload)) return error.BadPayload;
            const p: *const control_protocol.DeleteMicrovmPayload = @ptrCast(@alignCast(payload_ptr));
            const microvm_registry = @import("../vmm/microvm_registry.zig");
            if (!microvm_registry.delete(p.instance_id)) return error.BadPayload;
        },
        .list_microvms => {
            const microvm_registry = @import("../vmm/microvm_registry.zig");
            const instances = microvm_registry.getInstances();

            var res = control_protocol.VmSnapshotListPayload{
                .count = 0,
            };

            for (instances) |inst| {
                if (inst.in_use) {
                    if (res.count < control_protocol.MAX_VM_SNAPSHOT_ENTRIES) {
                        res.entries[res.count] = .{
                            .instance_id = inst.instance_id,
                            .state = @intFromEnum(inst.state),
                            .mem_pages = inst.mem_pages,
                            .vcpus = inst.vcpus,
                            .cpu_cycles = inst.cpu_cycles,
                            .exit_count = inst.exit_count,
                            .name = inst.name,
                        };
                        res.count += 1;
                    }
                }
            }

            const msg_page = try dipc.allocPageMessage(hhdm_offset, hdr.dst, hdr.src, std.mem.asBytes(&res));
            const table_const: *const endpoint_table.EndpointTable = table;
            _ = try router.routePageWithLocalNode(hhdm_offset, table_const, msg_page);
        },
        .get_node_status => {
            var res = control_protocol.NodeStatusResult{
                .total_mem_pages = @intCast(pmm.getTotalPages()),
                .free_mem_pages = @intCast(pmm.getFreePages()),
                .active_vms = 0,
            };

            const microvm_registry = @import("../vmm/microvm_registry.zig");
            const instances = microvm_registry.getInstances();
            for (instances) |inst| {
                if (inst.in_use) res.active_vms += 1;
            }

            const msg_page = try dipc.allocPageMessage(hhdm_offset, hdr.dst, hdr.src, std.mem.asBytes(&res));
            const table_const: *const endpoint_table.EndpointTable = table;
            _ = try router.routePageWithLocalNode(hhdm_offset, table_const, msg_page);
        },
    }
}
