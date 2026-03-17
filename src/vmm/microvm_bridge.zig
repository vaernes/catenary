const std = @import("std");
const identity = @import("../ipc/identity.zig");
const microvm_transport = @import("microvm_transport.zig");
const virtio_blk = @import("virtio_blk.zig");
const dipc = @import("../ipc/dipc.zig");
const router = @import("../ipc/router.zig");
const endpoint_table = @import("../ipc/endpoint_table.zig");
const pmm = @import("../kernel/pmm.zig");

pub const QueueError = error{ Busy, InvalidGpa, InvalidDescriptor };

pub const Entry = struct {
    microvm_id: identity.MicrovmId,
    page_phys: u64,
};

const MAX_PENDING: usize = 8;

var buf: [MAX_PENDING]Entry = undefined;
var head: u8 = 0;
var tail: u8 = 0;
var count: u8 = 0;

fn capU8() u8 {
    return @as(u8, @intCast(MAX_PENDING));
}

pub fn init() void {
    head = 0;
    tail = 0;
    count = 0;
}

// Bring-up boundary for future MicroVM-local ingress.
// Ring 0 records the target MicroVM handle and the DIPC page ownership moves to this queue.
pub fn enqueue(microvm_id: identity.MicrovmId, page_phys: u64) QueueError!void {
    if (count >= capU8()) return error.Busy;
    buf[@as(usize, tail)] = .{ .microvm_id = microvm_id, .page_phys = page_phys };
    tail +%= 1;
    if (tail >= capU8()) tail = 0;
    count += 1;
}

pub fn dequeue() ?Entry {
    if (count == 0) return null;
    const entry = buf[@as(usize, head)];
    head +%= 1;
    if (head >= capU8()) head = 0;
    count -= 1;
    return entry;
}

pub fn descriptorForEntry(
    hhdm_offset: u64,
    entry: Entry,
) microvm_transport.DescriptorError!microvm_transport.IngressDescriptor {
    return microvm_transport.ingressDescriptorFromPage(hhdm_offset, entry.microvm_id, entry.page_phys);
}

// --- Service Manager: Virtio-Blk Backend Routing ---

var bridge_hhdm_offset: u64 = 0;
var bridge_endpoint_table: ?*const endpoint_table.EndpointTable = null;

pub fn setBridgeContext(hhdm_offset: u64, table: *const endpoint_table.EndpointTable) void {
    bridge_hhdm_offset = hhdm_offset;
    bridge_endpoint_table = table;
}

/// When the guest triggers a virtio-blk queue notify via MMIO, the VM-Exit handler
/// calls this routine to package the read/write request into a DIPC page targeted at `storaged`.
pub fn routeVirtioBlkNotify(vmid: u32, queue_idx: u16) void {
    const vmx = @import("../arch/x86_64/vmx.zig");
    _ = queue_idx; // Blk usually has 1 queue

    const inst = virtio_blk.getInstance(vmid) orelse return;
    const q = &inst.queues[0];
    if (!q.ready) return;

    // 1. Access guest memory to read the available ring.
    // Note: We need the HHDM offset to access our own physical pages
    // that hold mapping for the guest's physical ring.
    const hhdm = bridge_hhdm_offset;

    // Guest Virtqueue layout:
    // Descriptor Table: [num] * Descriptor
    // Available Ring: [2]u16 + [num]u16 + [1]u16
    // Used Ring: [2]u16 + [num] * UsedElem + [1]u16

    const avail_hpa = vmx.findGuestPageHpaPublic(q.driver_addr) orelse return;
    const avail_ptr: [*]const u8 = @ptrFromInt(avail_hpa + hhdm + (q.driver_addr & 0xFFF));

    const flags = std.mem.readInt(u16, avail_ptr[0..2][0..2], .little);
    const idx = std.mem.readInt(u16, avail_ptr[2..4][0..2], .little);
    _ = flags;

    // Process new descriptors from last_avail_idx to current idx
    var cur = q.last_avail_idx;
    while (cur != idx) : (cur +%= 1) {
        const ring_off = 4 + (@as(usize, cur % q.num) * 2);
        const head_idx = std.mem.readInt(u16, avail_ptr[ring_off .. ring_off + 2][0..2], .little);

        // Walk descriptor chain starting at head_idx
        processDescriptorChain(vmid, inst, q, head_idx) catch {
            // Log error and continue to avoid blocking the host
            // (In a real system we'd inject a device error status)
        };
    }
    q.last_avail_idx = idx;
}

fn processDescriptorChain(vmid: u32, inst: *virtio_blk.DeviceInstance, q: *virtio_blk.QueueState, chain_head: u16) !void {
    _ = inst;
    const vmx = @import("../arch/x86_64/vmx.zig");
    const hhdm = bridge_hhdm_offset;

    const desc_hpa = vmx.findGuestPageHpaPublic(q.desc_addr) orelse return error.InvalidGpa;
    const desc_ptr: [*]const u8 = @ptrFromInt(desc_hpa + hhdm + (q.desc_addr & 0xFFF));

    // Virtio Descriptor is 16 bytes: addr(8), len(4), flags(2), next(2)
    const d_off = @as(usize, chain_head) * 16;
    const d_addr = std.mem.readInt(u64, desc_ptr[d_off .. d_off + 8][0..8], .little);
    _ = std.mem.readInt(u32, desc_ptr[d_off + 8 .. d_off + 12][0..4], .little);
    const d_flags = std.mem.readInt(u16, desc_ptr[d_off + 12 .. d_off + 14][0..2], .little);
    const d_next = std.mem.readInt(u16, desc_ptr[d_off + 14 .. d_off + 16][0..2], .little);

    var data_hpa: u64 = 0;
    var data_len: u32 = 0;
    var status_addr: u64 = 0;

    if ((d_flags & 1) != 0) {
        const d2_off = @as(usize, d_next) * 16;
        const d2_addr = std.mem.readInt(u64, desc_ptr[d2_off .. d2_off + 8][0..8], .little);
        const d2_len = std.mem.readInt(u32, desc_ptr[d2_off + 8 .. d2_off + 12][0..4], .little);
        const d2_flags = std.mem.readInt(u16, desc_ptr[d2_off + 12 .. d2_off + 14][0..2], .little);

        if ((d2_flags & 1) != 0) {
            data_len = d2_len;
            if (vmx.findGuestPageHpaPublic(d2_addr)) |hpa_base| {
                data_hpa = hpa_base + (d2_addr & 0xFFF);
            }
            const d3_idx = std.mem.readInt(u16, desc_ptr[d2_off + 14 .. d2_off + 16][0..2], .little);
            const d3_off = @as(usize, d3_idx) * 16;
            status_addr = std.mem.readInt(u64, desc_ptr[d3_off .. d3_off + 8][0..8], .little);
        } else {
            status_addr = d2_addr;
        }
    }

    // First descriptor in blk request is the Header (RequestHeader)
    const hdr_hpa = vmx.findGuestPageHpaPublic(d_addr) orelse return error.InvalidGpa;
    const hdr_ptr: [*]const virtio_blk.RequestHeader = @ptrFromInt(hdr_hpa + hhdm + (d_addr & 0xFFF));
    const req_hdr = hdr_ptr[0];

    // Allocate DIPC page for storaged
    const table = bridge_endpoint_table orelse return;
    const storaged_addr = dipc.Address{
        .node = dipc.Ipv6Addr.loopback(),
        .endpoint = @intFromEnum(identity.ReservedEndpoint.storaged),
    };
    const kernel_addr = dipc.Address{
        .node = dipc.Ipv6Addr.loopback(),
        .endpoint = @intFromEnum(identity.ReservedEndpoint.kernel_control),
    };

    // Format payload: RequestHeader + metadata
    var payload: [64]u8 = [_]u8{0} ** 64;
    std.mem.copyForwards(u8, payload[0..@sizeOf(virtio_blk.RequestHeader)], std.mem.asBytes(&req_hdr));
    // Additional metadata: VMID (32..36), chain_head (36..38), data_len (38..40), data_hpa (40..48)
    std.mem.writeInt(u32, payload[32..36][0..4], vmid, .little);
    std.mem.writeInt(u16, payload[36..38][0..2], chain_head, .little);
    std.mem.writeInt(u16, payload[38..40][0..2], @as(u16, @truncate(data_len)), .little);
    std.mem.writeInt(u64, payload[40..48][0..8], data_hpa, .little);
    // Also save status_addr so handleVirtioBlkResponse knows where to write the status
    std.mem.writeInt(u64, payload[48..56][0..8], status_addr, .little);

    const msg_page = try dipc.allocPageMessage(hhdm, kernel_addr, storaged_addr, &payload);

    // Send to storaged via router
    _ = try router.routePageWithLocalNode(hhdm, table, msg_page);
}

const control_protocol = @import("../control/control_protocol.zig");
const microvm_registry = @import("microvm_registry.zig");

/// Broadcast telemetry for all active MicroVMs to the dashd service.
pub fn broadcastTelemetry(hhdm: u64, table: *const endpoint_table.EndpointTable) void {
    const dashd_entity = table.lookup(@intFromEnum(identity.ReservedEndpoint.dashd)) orelse return;
    const dashd_sid = switch (dashd_entity) {
        .service => |sid| sid,
        else => return,
    };
    if (dashd_sid == 0) return;

    var i: usize = 0;
    while (i < microvm_registry.TARGET_INSTANCES) : (i += 1) {
        const inst = microvm_registry.findMutable(@as(u32, @intCast(i + 1))) orelse continue;
        if (!inst.in_use or inst.state != .running) continue;

        const dashd_addr = dipc.Address{
            .node = dipc.Ipv6Addr.loopback(),
            .endpoint = @intFromEnum(identity.ReservedEndpoint.dashd),
        };
        const kernel_addr = dipc.Address{
            .node = dipc.Ipv6Addr.loopback(),
            .endpoint = @intFromEnum(identity.ReservedEndpoint.kernel_control),
        };

        var payload: [64]u8 = [_]u8{0} ** 64;
        const telem = control_protocol.TelemetryUpdatePayload{
            .instance_id = inst.instance_id,
            .cpu_cycles = inst.cpu_cycles,
            .exit_count = inst.exit_count,
        };
        std.mem.copyForwards(u8, payload[0..@sizeOf(control_protocol.TelemetryUpdatePayload)], std.mem.asBytes(&telem));

        const msg_page = dipc.allocPageMessage(hhdm, kernel_addr, dashd_addr, &payload) catch continue;
        _ = router.routePageWithLocalNode(hhdm, table, msg_page) catch {
            pmm.freePage(msg_page);
            continue;
        };
    }
}

/// Receives block I/O completions from `storaged`.
pub fn handleVirtioBlkResponse(vmid: u32, head_idx: u16, io_status: u8) void {
    const vmx = @import("../arch/x86_64/vmx.zig");
    const hhdm = bridge_hhdm_offset;

    const inst = virtio_blk.getInstance(vmid) orelse return;
    const q = &inst.queues[0];

    // Retrieve the original descriptor chain to find the status byte address.
    const desc_hpa = vmx.findGuestPageHpaPublic(q.desc_addr) orelse return;
    const desc_ptr: [*]const u8 = @ptrFromInt(desc_hpa + hhdm + (q.desc_addr & 0xFFF));
    const d_off = @as(usize, head_idx) * 16;
    const d_flags = std.mem.readInt(u16, desc_ptr[d_off + 12 .. d_off + 14][0..2], .little);
    const d_next = std.mem.readInt(u16, desc_ptr[d_off + 14 .. d_off + 16][0..2], .little);

    var status_addr: u64 = 0;
    if ((d_flags & 1) != 0) {
        const d2_off = @as(usize, d_next) * 16;
        const d2_addr = std.mem.readInt(u64, desc_ptr[d2_off .. d2_off + 8][0..8], .little);
        const d2_flags = std.mem.readInt(u16, desc_ptr[d2_off + 12 .. d2_off + 14][0..2], .little);
        if ((d2_flags & 1) != 0) {
            const d3_idx = std.mem.readInt(u16, desc_ptr[d2_off + 14 .. d2_off + 16][0..2], .little);
            const d3_off = @as(usize, d3_idx) * 16;
            status_addr = std.mem.readInt(u64, desc_ptr[d3_off .. d3_off + 8][0..8], .little);
        } else {
            status_addr = d2_addr;
        }
    }

    // Write io_status to guest status descriptor memory
    if (vmx.findGuestPageHpaPublic(status_addr)) |status_hpa| {
        const status_ptr: [*]u8 = @ptrFromInt(status_hpa + hhdm + (status_addr & 0xFFF));
        status_ptr[0] = io_status;
    }

    // Used Ring: [2]u16 flags/idx, then [num] * UsedElem{id(4), len(4)}
    const used_hpa = vmx.findGuestPageHpaPublic(q.device_addr) orelse return;
    const used_ptr: [*]u8 = @ptrFromInt(used_hpa + hhdm + (q.device_addr & 0xFFF));

    const used_idx_ptr = used_ptr[2..4];
    const current_used_idx = std.mem.readInt(u16, used_idx_ptr[0..2], .little);

    const elem_off = 4 + (@as(usize, current_used_idx % q.num) * 8);
    // Write UsedElem: id (4 bytes), len (4 bytes)
    std.mem.writeInt(u32, used_ptr[elem_off .. elem_off + 4][0..4], head_idx, .little);
    std.mem.writeInt(u32, used_ptr[elem_off + 4 .. elem_off + 8][0..4], 1, .little); // 1 byte written (status)

    // Update used index
    std.mem.writeInt(u16, used_idx_ptr[0..2], current_used_idx +% 1, .little);

    inst.interrupt_status |= 1;
    vmx.injectGuestInterrupt(vmid, 14);
}
