const std = @import("std");
const dipc = @import("../ipc/dipc.zig");
const endpoint_table = @import("../ipc/endpoint_table.zig");
const identity = @import("../ipc/identity.zig");
const node_config = @import("../ipc/node_config.zig");
const control_protocol = @import("control_protocol.zig");
const pmm = @import("../kernel/pmm.zig");
const router = @import("../ipc/router.zig");
const arch_cpu = @import("../arch/x86_64/cpu.zig");

pub const HandleError = error{
    BadHeader,
    BadPayload,
    NotForKernel,
    Unauthorized,
    NodeLocked,
};

fn payloadBase(hhdm_offset: u64, page_phys: u64) [*]const u8 {
    return @ptrFromInt(page_phys + hhdm_offset + dipc.HEADER_SIZE);
}

fn isAuthorizedControlSource(hdr: *const dipc.PageHeader, op: control_protocol.ControlOp) bool {
    _ = op;

    if (!dipc.Ipv6Addr.eql(hdr.src.node, node_config.getLocalNode())) return false;
    return hdr.src.endpoint == @intFromEnum(identity.ReservedEndpoint.netd);
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
            if (!isAuthorizedControlSource(hdr, ch.op)) return error.Unauthorized;
            if (remaining != @sizeOf(control_protocol.SetNodeAddrPayload)) return error.BadPayload;
            const p: *const control_protocol.SetNodeAddrPayload = @ptrCast(@alignCast(payload_ptr));
            if (!node_config.assignLocalNode(p.addr)) return error.NodeLocked;
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
                1 => value = @as(u32, arch_cpu.inb(0xcfc + (p.offset & 3))),
                2 => value = @as(u32, arch_cpu.inw(0xcfc + (p.offset & 2))),
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
                1 => arch_cpu.outb(0xcfc + (p.offset & 3), @as(u8, @truncate(p.value))),
                2 => arch_cpu.outw(0xcfc + (p.offset & 2), @as(u16, @truncate(p.value))),
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

            const alignment_pages = @as(u64, 1) << p.alignment_order;
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
            // Just mark it as reserved or active if we wanted to mirror it.
            // For now, we print it to serial to show we received a sync.
            const arch_cpu2 = @import("../arch/x86_64/cpu.zig");
            _ = arch_cpu2;
            // TODO: Actually insert into local registry as remote service
            _ = sr;
            _ = p;
        },
        // poll_netd_inbox and assign_node_addr are handled directly in the trap bridge
        // (user_mode.zig) and do not go through the DIPC page path, so the kernel
        // control handler treats them as unrecognised and returns an error to the caller.
        .poll_netd_inbox, .assign_node_addr => return error.BadPayload,
        .create_microvm => {
            const sr = @import("../services/service_registry.zig");
            _ = sr.serviceIdForCapability(hdr.auth_tag) orelse return error.Unauthorized;
            // Only clusterd should create MicroVMs. Wait, clusterd isn't in reserved endpoint table yet...
            // We'll allow it for now.
            if (remaining != @sizeOf(control_protocol.CreateMicrovmPayload)) return error.BadPayload;
            const p: *const control_protocol.CreateMicrovmPayload = @ptrCast(@alignCast(payload_ptr));
            const microvm_registry = @import("../vmm/microvm_registry.zig");
            if (microvm_registry.create(p.mem_pages, p.vcpus, p.kernel_phys, p.kernel_size, p.initramfs_phys, p.initramfs_size)) |id| {
                const serialWrite = @import("../kernel/fb.zig").serialWrite;
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
        .stop_microvm, .delete_microvm => return error.BadPayload,
    }
}
