const std = @import("std");
const builtin = @import("builtin");
const identity = @import("../ipc/identity.zig");
const microvm_transport = @import("microvm_transport.zig");
const virtio_blk = @import("virtio_blk.zig");
const storaged_protocol = @import("../user/protocols/storaged_protocol.zig");
const dipc = @import("../ipc/dipc.zig");
const router = @import("../ipc/router.zig");
const endpoint_table = @import("../ipc/endpoint_table.zig");
const pmm = @import("../kernel/pmm.zig");

pub const QueueError = error{ Busy, InvalidGpa, InvalidDescriptor };

const virtio_queue_size_max: u32 = 256;
const virtio_desc_size: usize = 16;

pub const Entry = struct {
    microvm_id: identity.MicrovmId,
    page_phys: u64,
};

const MAX_PENDING: usize = 8;

var buf: [MAX_PENDING]Entry = undefined;
var head: u8 = 0;
var tail: u8 = 0;
var count: u8 = 0;
var bridge_lock: bool = false;

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
    while (@atomicRmw(bool, &bridge_lock, .Xchg, true, .seq_cst)) {
        if (!builtin.is_test and comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("pause");
        } else {
            std.atomic.spinLoopHint();
        }
    }
    return flags;
}

fn releaseLock(flags: u64) void {
    @atomicStore(bool, &bridge_lock, false, .seq_cst);
    if (!builtin.is_test and comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\pushq %[flags]
            \\popfq
            :
            : [flags] "r" (flags),
        );
    }
}

fn capU8() u8 {
    return @as(u8, @intCast(MAX_PENDING));
}

pub fn init() void {
    const flags = acquireLock();
    defer releaseLock(flags);
    head = 0;
    tail = 0;
    count = 0;
}

// Bring-up boundary for future MicroVM-local ingress.
// Ring 0 records the target MicroVM handle and the DIPC page ownership moves to this queue.
pub fn enqueue(microvm_id: identity.MicrovmId, page_phys: u64) QueueError!void {
    const flags = acquireLock();
    defer releaseLock(flags);
    if (count >= capU8()) return error.Busy;
    buf[@as(usize, tail)] = .{ .microvm_id = microvm_id, .page_phys = page_phys };
    tail +%= 1;
    if (tail >= capU8()) tail = 0;
    count += 1;
}

pub fn dequeue() ?Entry {
    const flags = acquireLock();
    defer releaseLock(flags);
    if (count == 0) return null;
    const entry = buf[@as(usize, head)];
    head +%= 1;
    if (head >= capU8()) head = 0;
    count -= 1;
    return entry;
}

pub fn dequeueForVm(microvm_id: identity.MicrovmId) ?Entry {
    const flags = acquireLock();
    defer releaseLock(flags);
    if (count == 0) return null;

    var found: ?Entry = null;
    var i: u8 = 0;
    var write_idx: u8 = head;
    var read_idx: u8 = head;
    var new_count: u8 = 0;
    while (i < count) : (i += 1) {
        const entry = buf[@as(usize, read_idx)];
        read_idx +%= 1;
        if (read_idx >= capU8()) read_idx = 0;

        if (found == null and entry.microvm_id == microvm_id) {
            found = entry;
        } else {
            buf[@as(usize, write_idx)] = entry;
            write_idx +%= 1;
            if (write_idx >= capU8()) write_idx = 0;
            new_count += 1;
        }
    }
    tail = write_idx;
    count = new_count;
    return found;
}

pub fn dropForVm(microvm_id: identity.MicrovmId) void {
    const buffer_grant = @import("buffer_grant.zig");
    buffer_grant.releaseAllForVm(microvm_id);
    while (dequeueForVm(microvm_id)) |entry| {
        dipc.freePageMessage(entry.page_phys);
    }
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

pub var gpa_to_hpa_fn: ?*const fn (vmid: u32, gpa: u64) ?u64 = null;
pub var inject_irq_fn: ?*const fn (vmid: u32, vector: u8) void = null;

pub fn setBridgeContext(hhdm_offset: u64, table: *const endpoint_table.EndpointTable) void {
    bridge_hhdm_offset = hhdm_offset;
    bridge_endpoint_table = table;
}

fn translateGuestPageHpa(vmid: u32, page_gpa: u64) ?u64 {
    const aligned = page_gpa & ~@as(u64, 0xFFF);
    if (gpa_to_hpa_fn) |translate| {
        const raw = translate(vmid, aligned) orelse return null;
        return raw & ~@as(u64, 0xFFF);
    }
    if (!builtin.is_test) {
        const microvm_reg = @import("microvm_registry.zig");
        const inst = microvm_reg.findMutable(vmid) orelse return null;
        const root = inst.ept_pml4_phys orelse return null;
        const vmx = @import("../arch/x86_64/vmx.zig");
        return vmx.translateEptGpaToHpa(root, aligned);
    }
    return null;
}

fn injectGuestIrq(vmid: u32, vector: u8) void {
    if (inject_irq_fn) |inject| {
        inject(vmid, vector);
        return;
    }
    if (!@import("builtin").is_test) {
        const vmx = @import("../arch/x86_64/vmx.zig");
        vmx.injectGuestInterrupt(vmid, vector);
    }
}

pub fn validateGuestSpan(vmid: u32, gpa: u64, len: usize) bool {
    if (len == 0) return true;
    const end = std.math.add(u64, gpa, @as(u64, @intCast(len - 1))) catch return false;
    var cur_page = gpa & ~@as(u64, 0xFFF);
    const end_page = end & ~@as(u64, 0xFFF);
    while (true) {
        if (translateGuestPageHpa(vmid, cur_page) == null) return false;
        if (cur_page == end_page) break;
        cur_page = std.math.add(u64, cur_page, pmm.PAGE_SIZE) catch return false;
    }
    return true;
}

fn validateContiguousGuestSpanHpa(vmid: u32, gpa: u64, len: usize) ?u64 {
    if (len == 0) {
        const page_hpa = translateGuestPageHpa(vmid, gpa) orelse return null;
        return page_hpa + (gpa & 0xFFF);
    }
    const end = std.math.add(u64, gpa, @as(u64, @intCast(len - 1))) catch return null;
    const first_page = gpa & ~@as(u64, 0xFFF);
    const end_page = end & ~@as(u64, 0xFFF);
    const first_hpa = translateGuestPageHpa(vmid, first_page) orelse return null;

    var cur_page = first_page;
    var expected_hpa = first_hpa;
    while (true) {
        const hpa = translateGuestPageHpa(vmid, cur_page) orelse return null;
        if (hpa != expected_hpa) return null;
        if (cur_page == end_page) break;
        cur_page = std.math.add(u64, cur_page, pmm.PAGE_SIZE) catch return null;
        expected_hpa = std.math.add(u64, expected_hpa, pmm.PAGE_SIZE) catch return null;
    }
    return first_hpa + (gpa & 0xFFF);
}

fn readGuestBytes(hhdm: u64, vmid: u32, gpa: u64, out: []u8) bool {
    var offset: usize = 0;
    while (offset < out.len) {
        const cur_gpa = std.math.add(u64, gpa, @as(u64, @intCast(offset))) catch return false;
        const page_hpa = translateGuestPageHpa(vmid, cur_gpa) orelse return false;
        const page_off = @as(usize, @intCast(cur_gpa & 0xFFF));
        const chunk = @min(pmm.PAGE_SIZE - page_off, out.len - offset);
        const src: [*]const u8 = @ptrFromInt(page_hpa + hhdm + page_off);
        @memcpy(out[offset .. offset + chunk], src[0..chunk]);
        offset += chunk;
    }
    return true;
}

fn writeGuestBytes(hhdm: u64, vmid: u32, gpa: u64, data: []const u8) bool {
    var offset: usize = 0;
    while (offset < data.len) {
        const cur_gpa = std.math.add(u64, gpa, @as(u64, @intCast(offset))) catch return false;
        const page_hpa = translateGuestPageHpa(vmid, cur_gpa) orelse return false;
        const page_off = @as(usize, @intCast(cur_gpa & 0xFFF));
        const chunk = @min(pmm.PAGE_SIZE - page_off, data.len - offset);
        const dst: [*]u8 = @ptrFromInt(page_hpa + hhdm + page_off);
        @memcpy(dst[0..chunk], data[offset .. offset + chunk]);
        offset += chunk;
    }
    return true;
}

fn readGuestInt(comptime T: type, hhdm: u64, vmid: u32, gpa: u64) ?T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    if (!readGuestBytes(hhdm, vmid, gpa, &bytes)) return null;
    return std.mem.readInt(T, &bytes, .little);
}

fn writeGuestInt(comptime T: type, hhdm: u64, vmid: u32, gpa: u64, val: T) bool {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, val, .little);
    return writeGuestBytes(hhdm, vmid, gpa, &bytes);
}

fn validateQueueMemory(vmid: u32, q: *const virtio_blk.QueueState, event_idx: bool) bool {
    if (!isQueueValid(q)) return false;
    if ((q.desc_addr & (virtio_desc_size - 1)) != 0) return false;
    if ((q.driver_addr & 0x1) != 0) return false;
    if ((q.device_addr & 0x3) != 0) return false;

    const desc_bytes = @as(usize, q.num) * virtio_desc_size;
    const avail_bytes = 4 + (@as(usize, q.num) * 2) + (if (event_idx) @as(usize, 2) else 0);
    const used_bytes = 4 + (@as(usize, q.num) * 8) + (if (event_idx) @as(usize, 2) else 0);

    return validateGuestSpan(vmid, q.desc_addr, desc_bytes) and
        validateGuestSpan(vmid, q.driver_addr, avail_bytes) and
        validateGuestSpan(vmid, q.device_addr, used_bytes);
}

/// When the guest triggers a virtio-blk queue notify via MMIO, the VM-Exit handler
/// calls this routine to package the read/write request into a DIPC page targeted at `storaged`.
pub fn routeVirtioBlkNotify(vmid: u32, queue_idx: u16) void {
    if (queue_idx != 0) return;
    if (!microvm_registry.isRunning(vmid)) return;

    const inst = virtio_blk.getInstance(vmid) orelse return;
    const q = &inst.queues[0];
    const event_idx = inst.hasEventIdx();
    if (!validateQueueMemory(vmid, q, event_idx)) return;

    const hhdm = bridge_hhdm_offset;
    const idx = readGuestInt(u16, hhdm, vmid, q.driver_addr + 2) orelse return;
    const pending = idx -% q.last_avail_idx;
    if (pending > @as(u16, @intCast(q.num))) return;

    // Process new descriptors from last_avail_idx to current idx
    while (q.last_avail_idx != idx) {
        const ring_gpa = q.driver_addr + 4 + (@as(u64, q.last_avail_idx % @as(u16, @intCast(q.num))) * 2);
        const head_idx = readGuestInt(u16, hhdm, vmid, ring_gpa) orelse return;
        q.last_avail_idx +%= 1;

        if (event_idx) {
            const avail_event_gpa = q.device_addr + 4 + (@as(u64, q.num) * 8);
            _ = writeGuestInt(u16, hhdm, vmid, avail_event_gpa, q.last_avail_idx);
        }

        // Walk descriptor chain starting at head_idx
        processDescriptorChain(vmid, inst, q, head_idx) catch |err| {
            completeBlkRequestOnError(hhdm, vmid, inst, q, head_idx, err);
        };
    }
}

fn isQueueValid(q: *const virtio_blk.QueueState) bool {
    return q.ready and q.num > 0 and q.num <= virtio_queue_size_max;
}

fn isDescriptorIndexValid(q: *const virtio_blk.QueueState, index: u16) bool {
    return @as(u32, index) < q.num;
}

const RawDescriptor = struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

fn readDescriptor(hhdm: u64, vmid: u32, q: *const virtio_blk.QueueState, idx: u16) ?RawDescriptor {
    if (!isDescriptorIndexValid(q, idx)) return null;
    const d_gpa = q.desc_addr + (@as(u64, idx) * virtio_desc_size);
    var raw: [16]u8 = undefined;
    if (!readGuestBytes(hhdm, vmid, d_gpa, &raw)) return null;
    return .{
        .addr = std.mem.readInt(u64, raw[0..8], .little),
        .len = std.mem.readInt(u32, raw[8..12], .little),
        .flags = std.mem.readInt(u16, raw[12..14], .little),
        .next = std.mem.readInt(u16, raw[14..16], .little),
    };
}

const DescriptorChainInfo = struct {
    request: virtio_blk.RequestHeader,
    storaged_req_type: u32,
    data_gpa: u64 = 0,
    data_hpa: u64,
    data_len: u32,
    status_addr: u64,
};

fn storagedRequestType(request_type: u32) ?u32 {
    const fua = request_type & virtio_blk.VIRTIO_BLK_T_FUA != 0;
    return switch (request_type & ~virtio_blk.VIRTIO_BLK_T_FUA) {
        virtio_blk.VIRTIO_BLK_T_IN => if (fua) null else @backingInt(storaged_protocol.ReqType.read),
        virtio_blk.VIRTIO_BLK_T_OUT => if (fua)
            @backingInt(storaged_protocol.ReqType.write_fua)
        else
            @backingInt(storaged_protocol.ReqType.write),
        virtio_blk.VIRTIO_BLK_T_FLUSH => if (fua) null else @backingInt(storaged_protocol.ReqType.flush),
        else => null,
    };
}

fn decodeDescriptorChain(hhdm: u64, vmid: u32, q: *virtio_blk.QueueState, chain_head: u16) !DescriptorChainInfo {
    if (!isQueueValid(q) or !isDescriptorIndexValid(q, chain_head)) return error.InvalidDescriptor;
    if ((q.desc_addr & (virtio_desc_size - 1)) != 0) return error.InvalidDescriptor;

    const d1 = readDescriptor(hhdm, vmid, q, chain_head) orelse return error.InvalidGpa;
    if ((d1.flags & virtio_blk.VIRTQ_DESC_F_INDIRECT) != 0) return error.InvalidDescriptor;
    if ((d1.flags & virtio_blk.VIRTQ_DESC_F_WRITE) != 0) return error.InvalidDescriptor;
    if ((d1.flags & virtio_blk.VIRTQ_DESC_F_NEXT) == 0) return error.InvalidDescriptor;
    if (d1.len < @sizeOf(virtio_blk.RequestHeader)) return error.InvalidDescriptor;

    var hdr_bytes: [@sizeOf(virtio_blk.RequestHeader)]u8 = undefined;
    if (!readGuestBytes(hhdm, vmid, d1.addr, &hdr_bytes)) return error.InvalidGpa;
    const req = std.mem.bytesToValue(virtio_blk.RequestHeader, &hdr_bytes);
    const storaged_req_type = storagedRequestType(req.type) orelse return error.UnsupportedOperation;
    const operation = req.type & ~virtio_blk.VIRTIO_BLK_T_FUA;

    var info = DescriptorChainInfo{
        .request = req,
        .storaged_req_type = storaged_req_type,
        .data_gpa = 0,
        .data_hpa = 0,
        .data_len = 0,
        .status_addr = 0,
    };

    const d2 = readDescriptor(hhdm, vmid, q, d1.next) orelse return error.InvalidDescriptor;
    if ((d2.flags & virtio_blk.VIRTQ_DESC_F_INDIRECT) != 0) return error.InvalidDescriptor;

    if ((d2.flags & virtio_blk.VIRTQ_DESC_F_NEXT) != 0) {
        if (operation == virtio_blk.VIRTIO_BLK_T_FLUSH) return error.InvalidDescriptor;
        if (d2.len == 0 or d2.len > std.math.maxInt(u16) or d2.len % 512 != 0) return error.InvalidDescriptor;
        if (operation == virtio_blk.VIRTIO_BLK_T_IN and (d2.flags & virtio_blk.VIRTQ_DESC_F_WRITE) == 0) {
            return error.InvalidDescriptor;
        }
        if (operation == virtio_blk.VIRTIO_BLK_T_OUT and (d2.flags & virtio_blk.VIRTQ_DESC_F_WRITE) != 0) {
            return error.InvalidDescriptor;
        }
        info.data_len = d2.len;
        info.data_gpa = d2.addr;
        info.data_hpa = validateContiguousGuestSpanHpa(vmid, d2.addr, d2.len) orelse return error.InvalidGpa;

        const d3 = readDescriptor(hhdm, vmid, q, d2.next) orelse return error.InvalidDescriptor;
        if ((d3.flags & virtio_blk.VIRTQ_DESC_F_INDIRECT) != 0) return error.InvalidDescriptor;
        if ((d3.flags & virtio_blk.VIRTQ_DESC_F_NEXT) != 0) return error.InvalidDescriptor;
        if ((d3.flags & virtio_blk.VIRTQ_DESC_F_WRITE) == 0 or d3.len < 1) return error.InvalidDescriptor;
        if (!validateGuestSpan(vmid, d3.addr, 1)) return error.InvalidGpa;
        info.status_addr = d3.addr;
    } else {
        if (operation != virtio_blk.VIRTIO_BLK_T_FLUSH) return error.InvalidDescriptor;
        if ((d2.flags & virtio_blk.VIRTQ_DESC_F_WRITE) == 0 or d2.len < 1) return error.InvalidDescriptor;
        if (!validateGuestSpan(vmid, d2.addr, 1)) return error.InvalidGpa;
        info.status_addr = d2.addr;
    }

    return info;
}

fn makeStoragedRequest(
    info: DescriptorChainInfo,
    vmid: u32,
    chain_head: u16,
) storaged_protocol.BlkRequest {
    return .{
        .req_type = info.storaged_req_type,
        .sector = info.request.sector,
        .vmid = vmid,
        .chain_head = chain_head,
        .data_len = @intCast(info.data_len),
        .data_hpa = info.data_hpa,
    };
}

fn findStatusDescriptorAddr(hhdm: u64, vmid: u32, q: *const virtio_blk.QueueState, chain_head: u16) ?u64 {
    var curr = chain_head;
    var steps: u32 = 0;
    while (steps < q.num) : (steps += 1) {
        const d = readDescriptor(hhdm, vmid, q, curr) orelse return null;
        if ((d.flags & virtio_blk.VIRTQ_DESC_F_INDIRECT) != 0) return null;
        if ((d.flags & virtio_blk.VIRTQ_DESC_F_NEXT) == 0) {
            if ((d.flags & virtio_blk.VIRTQ_DESC_F_WRITE) != 0 and d.len >= 1 and validateGuestSpan(vmid, d.addr, 1)) {
                return d.addr;
            }
            return null;
        }
        curr = d.next;
    }
    return null;
}

fn shouldNotifyDriver(hhdm: u64, vmid: u32, inst: *const virtio_blk.DeviceInstance, q: *const virtio_blk.QueueState, old_used_idx: u16, new_used_idx: u16) bool {
    if (inst.hasEventIdx()) {
        const used_event_gpa = q.driver_addr + 4 + (@as(u64, q.num) * 2);
        const used_event = readGuestInt(u16, hhdm, vmid, used_event_gpa) orelse return false;
        return (new_used_idx -% used_event -% 1) < (new_used_idx -% old_used_idx);
    }
    const avail_flags = readGuestInt(u16, hhdm, vmid, q.driver_addr) orelse return false;
    return (avail_flags & virtio_blk.VIRTQ_AVAIL_F_NO_INTERRUPT) == 0;
}

fn pushUsedAndNotify(hhdm: u64, vmid: u32, inst: *virtio_blk.DeviceInstance, q: *virtio_blk.QueueState, head_idx: u16, used_len: u32) void {
    if (!isDescriptorIndexValid(q, head_idx)) return;
    const old_used_idx = readGuestInt(u16, hhdm, vmid, q.device_addr + 2) orelse return;
    const elem_gpa = q.device_addr + 4 + (@as(u64, old_used_idx % @as(u16, @intCast(q.num))) * 8);

    if (!writeGuestInt(u32, hhdm, vmid, elem_gpa, @as(u32, head_idx))) return;
    if (!writeGuestInt(u32, hhdm, vmid, elem_gpa + 4, used_len)) return;

    const new_used_idx = old_used_idx +% 1;
    if (!writeGuestInt(u16, hhdm, vmid, q.device_addr + 2, new_used_idx)) return;
    q.last_used_idx = new_used_idx;

    if (shouldNotifyDriver(hhdm, vmid, inst, q, old_used_idx, new_used_idx)) {
        inst.interrupt_status |= 1;
        injectGuestIrq(vmid, 14);
    }
}

fn completeBlkRequestOnError(hhdm: u64, vmid: u32, inst: *virtio_blk.DeviceInstance, q: *virtio_blk.QueueState, head_idx: u16, err: anyerror) void {
    const buffer_grant = @import("buffer_grant.zig");
    _ = buffer_grant.releaseGrantForChain(vmid, head_idx);

    if (!isDescriptorIndexValid(q, head_idx)) return;
    const status_byte: u8 = if (err == error.UnsupportedOperation)
        virtio_blk.VIRTIO_BLK_S_UNSUPP
    else
        virtio_blk.VIRTIO_BLK_S_IOERR;

    var used_len: u32 = 0;
    if (findStatusDescriptorAddr(hhdm, vmid, q, head_idx)) |status_gpa| {
        if (writeGuestInt(u8, hhdm, vmid, status_gpa, status_byte)) {
            used_len = 1;
        }
    }
    pushUsedAndNotify(hhdm, vmid, inst, q, head_idx, used_len);
}

fn processDescriptorChain(vmid: u32, inst: *virtio_blk.DeviceInstance, q: *virtio_blk.QueueState, chain_head: u16) !void {
    _ = inst;
    const hhdm = bridge_hhdm_offset;
    const info = try decodeDescriptorChain(hhdm, vmid, q, chain_head);

    if (info.data_len > 0) {
        const buffer_grant = @import("buffer_grant.zig");
        const dir: buffer_grant.GrantDirection = if (info.storaged_req_type == @backingInt(storaged_protocol.ReqType.read))
            .write
        else
            .read;
        _ = buffer_grant.acquireGrant(vmid, chain_head, info.data_gpa, info.data_hpa, info.data_len, dir) orelse return error.GrantFailed;
    }

    // Allocate DIPC page for storaged
    const table = bridge_endpoint_table orelse return error.NoRoute;
    const storaged_addr = dipc.Address{
        .node = dipc.Ipv6Addr.loopback(),
        .endpoint = @backingInt(identity.ReservedEndpoint.storaged),
    };
    const kernel_addr = dipc.Address{
        .node = dipc.Ipv6Addr.loopback(),
        .endpoint = @backingInt(identity.ReservedEndpoint.kernel_control),
    };

    const request = makeStoragedRequest(info, vmid, chain_head);

    const msg_page = try dipc.allocPageMessage(hhdm, kernel_addr, storaged_addr, std.mem.asBytes(&request));
    errdefer dipc.freePageMessage(msg_page);

    // Send to storaged via router
    _ = try router.routePageWithLocalNode(hhdm, table, msg_page);
}

const control_protocol = @import("../control/control_protocol.zig");
const microvm_registry = @import("microvm_registry.zig");

/// Broadcast telemetry for all active MicroVMs to the dashd service.
pub fn broadcastTelemetryFromContext() void {
    const hhdm = bridge_hhdm_offset;
    const table = bridge_endpoint_table orelse return;
    broadcastTelemetry(hhdm, table);
}

pub fn broadcastTelemetry(hhdm: u64, table: *const endpoint_table.EndpointTable) void {
    const dashd_entity = table.lookup(@backingInt(identity.ReservedEndpoint.dashd)) orelse return;
    const dashd_sid = switch (dashd_entity) {
        .service => |sid| sid,
        else => return,
    };
    if (dashd_sid == 0) return;

    var i: usize = 0;
    while (i < microvm_registry.TARGET_INSTANCES) : (i += 1) {
        const inst = microvm_registry.findMutable(@as(u32, @intCast(i + 1))) orelse continue;
        if (!inst.in_use) continue;

        const dashd_addr = dipc.Address{
            .node = dipc.Ipv6Addr.loopback(),
            .endpoint = @backingInt(identity.ReservedEndpoint.dashd),
        };
        const kernel_addr = dipc.Address{
            .node = dipc.Ipv6Addr.loopback(),
            .endpoint = @backingInt(identity.ReservedEndpoint.kernel_control),
        };

        var payload: [64]u8 = @splat(0);
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
    if (!microvm_registry.isRunning(vmid)) return;
    const hhdm = bridge_hhdm_offset;

    const buffer_grant = @import("buffer_grant.zig");
    _ = buffer_grant.releaseGrantForChain(vmid, head_idx);

    const inst = virtio_blk.getInstance(vmid) orelse return;
    const q = &inst.queues[0];
    if (!validateQueueMemory(vmid, q, inst.hasEventIdx()) or !isDescriptorIndexValid(q, head_idx)) return;

    const info = decodeDescriptorChain(hhdm, vmid, q, head_idx) catch {
        completeBlkRequestOnError(hhdm, vmid, inst, q, head_idx, error.InvalidDescriptor);
        return;
    };

    const wrote_status = writeGuestInt(u8, hhdm, vmid, info.status_addr, io_status);
    const used_len: u32 = if (!wrote_status)
        0
    else if (io_status == virtio_blk.VIRTIO_BLK_S_OK and info.request.type == virtio_blk.VIRTIO_BLK_T_IN)
        info.data_len + 1
    else
        1;

    pushUsedAndNotify(hhdm, vmid, inst, q, head_idx, used_len);
}

const limine = @import("../kernel/limine.zig");

var test_backing: [16][4096]u8 align(4096) = undefined;
var test_irq_count: usize = 0;

fn testTranslateDiscontiguous(_: u32, gpa: u64) ?u64 {
    const page = gpa & ~@as(u64, 0xFFF);
    // Deliberately map GPA pages 0..3 to reversed host pages 4..1 so cross-page
    // accesses fail if code assumes contiguous host physical memory.
    return switch (page) {
        0x1000 => 4 * pmm.PAGE_SIZE,
        0x2000 => 3 * pmm.PAGE_SIZE,
        0x3000 => 2 * pmm.PAGE_SIZE,
        0x4000 => 1 * pmm.PAGE_SIZE,
        else => null,
    };
}

fn testRecordIrq(_: u32, _: u8) void {
    test_irq_count += 1;
}

test "virtio-blk cross-page rings, failure completion, and event-idx suppression" {
    @memset(std.mem.asBytes(&test_backing), 0);
    const hhdm = @intFromPtr(&test_backing);
    var entry = limine.MemmapEntry{
        .base = 0,
        .length = @sizeOf(@TypeOf(test_backing)),
        .kind = limine.MEMMAP_USABLE,
    };
    var entries = [_]*limine.MemmapEntry{&entry};
    var memmap = limine.MemmapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = @ptrCast(&entries),
    };
    pmm.init(&memmap, hhdm);
    for (1..5) |p| pmm.setBit(p);

    test_irq_count = 0;
    virtio_blk.init();
    gpa_to_hpa_fn = testTranslateDiscontiguous;
    inject_irq_fn = testRecordIrq;
    defer {
        gpa_to_hpa_fn = null;
        inject_irq_fn = null;
        bridge_hhdm_offset = 0;
        bridge_endpoint_table = null;
    }

    var table: endpoint_table.EndpointTable = undefined;
    table.init();
    setBridgeContext(hhdm, &table);

    const vmid: u32 = 1;
    microvm_registry.init();
    const vm_name: [32]u8 = @splat(0);
    const vm_container: [32]u8 = @splat(0);
    const created_vmid = microvm_registry.create(vm_name, vm_container, 1, 1, 0, 0, 0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(vmid, created_vmid);
    try std.testing.expect(microvm_registry.start(vmid));

    const inst = virtio_blk.getInstance(vmid).?;
    inst.driver_features = virtio_blk.VIRTIO_F_EVENT_IDX;
    const q = &inst.queues[0];
    q.* = .{
        .ready = true,
        .num = 4,
        // Place descriptor table, avail ring, and used ring across 4 KiB page boundaries!
        .desc_addr = 0x1FE0, // 2 descriptors on page 0x1000, 2 descriptors on page 0x2000
        .driver_addr = 0x2FFA, // flags+idx+ring[0] on 0x2000, ring[1..3]+used_event on 0x3000
        .device_addr = 0x3FF8, // flags+idx+ring[0].id on 0x3000, ring[0].len+ring[1..3]+avail_event on 0x4000
    };

    try std.testing.expect(validateQueueMemory(vmid, q, true));

    // Set up a 3-descriptor READ chain (0 -> 1 -> 2) where descriptor 2 is across page 0x2000
    // Desc 0 (at 0x1FE0): header at GPA 0x1100, len 16, NEXT -> 1
    _ = writeGuestInt(u64, hhdm, vmid, 0x1FE0 + 0, 0x1100);
    _ = writeGuestInt(u32, hhdm, vmid, 0x1FE0 + 8, 16);
    _ = writeGuestInt(u16, hhdm, vmid, 0x1FE0 + 12, virtio_blk.VIRTQ_DESC_F_NEXT);
    _ = writeGuestInt(u16, hhdm, vmid, 0x1FE0 + 14, 1);

    // Desc 1 (at 0x1FF0): data at GPA 0x1200, len 512, WRITE | NEXT -> 2
    _ = writeGuestInt(u64, hhdm, vmid, 0x1FF0 + 0, 0x1200);
    _ = writeGuestInt(u32, hhdm, vmid, 0x1FF0 + 8, 512);
    _ = writeGuestInt(u16, hhdm, vmid, 0x1FF0 + 12, virtio_blk.VIRTQ_DESC_F_WRITE | virtio_blk.VIRTQ_DESC_F_NEXT);
    _ = writeGuestInt(u16, hhdm, vmid, 0x1FF0 + 14, 2);

    // Desc 2 (at 0x2000, across page boundary!): status at GPA 0x1400, len 1, WRITE
    _ = writeGuestInt(u64, hhdm, vmid, 0x2000 + 0, 0x1400);
    _ = writeGuestInt(u32, hhdm, vmid, 0x2000 + 8, 1);
    _ = writeGuestInt(u16, hhdm, vmid, 0x2000 + 12, virtio_blk.VIRTQ_DESC_F_WRITE);
    _ = writeGuestInt(u16, hhdm, vmid, 0x2000 + 14, 0);

    // Write valid RequestHeader (VIRTIO_BLK_T_IN, sector 0) at 0x1100
    _ = writeGuestInt(u32, hhdm, vmid, 0x1100, virtio_blk.VIRTIO_BLK_T_IN);
    _ = writeGuestInt(u32, hhdm, vmid, 0x1104, 0);
    _ = writeGuestInt(u64, hhdm, vmid, 0x1108, 0);
    _ = writeGuestInt(u8, hhdm, vmid, 0x1400, 0xFF);

    // Populate avail ring: idx = 1, ring[0] = 0, used_event = 1 (suppresses idx 0->1 interrupt!)
    _ = writeGuestInt(u16, hhdm, vmid, q.driver_addr + 0, 0);
    _ = writeGuestInt(u16, hhdm, vmid, q.driver_addr + 2, 1);
    _ = writeGuestInt(u16, hhdm, vmid, q.driver_addr + 4, 0);
    const used_event_gpa = q.driver_addr + 4 + (4 * 2);
    _ = writeGuestInt(u16, hhdm, vmid, used_event_gpa, 1);

    // Because storaged is not registered in `table`, routing fails -> must complete with IOERR (status=1, used_len=1)
    // and update avail_event = 1 without firing an IRQ (since used_event == 1, old_used_idx == 0).
    routeVirtioBlkNotify(vmid, 0);

    try std.testing.expectEqual(@as(u8, virtio_blk.VIRTIO_BLK_S_IOERR), readGuestInt(u8, hhdm, vmid, 0x1400).?);
    try std.testing.expectEqual(@as(u16, 1), readGuestInt(u16, hhdm, vmid, q.device_addr + 2).?);
    try std.testing.expectEqual(@as(u32, 0), readGuestInt(u32, hhdm, vmid, q.device_addr + 4).?);
    try std.testing.expectEqual(@as(u32, 1), readGuestInt(u32, hhdm, vmid, q.device_addr + 8).?);
    try std.testing.expectEqual(@as(u16, 1), readGuestInt(u16, hhdm, vmid, q.device_addr + 4 + (4 * 8)).?);
    try std.testing.expectEqual(@as(usize, 0), test_irq_count);

    // Now test handleVirtioBlkResponse with IOERR when used_event matches old_used_idx (1):
    // must report used_len = 1 (not 513!) and trigger IRQ!
    _ = writeGuestInt(u8, hhdm, vmid, 0x1400, 0xFF);
    handleVirtioBlkResponse(vmid, 0, virtio_blk.VIRTIO_BLK_S_IOERR);
    try std.testing.expectEqual(@as(u8, virtio_blk.VIRTIO_BLK_S_IOERR), readGuestInt(u8, hhdm, vmid, 0x1400).?);
    try std.testing.expectEqual(@as(u16, 2), readGuestInt(u16, hhdm, vmid, q.device_addr + 2).?);
    try std.testing.expectEqual(@as(u32, 1), readGuestInt(u32, hhdm, vmid, q.device_addr + 4 + 8 + 4).?);
    try std.testing.expectEqual(@as(usize, 1), test_irq_count);

    // Verify 2-descriptor chain validation: valid for FLUSH, invalid for IN/OUT
    _ = writeGuestInt(u32, hhdm, vmid, 0x1100, virtio_blk.VIRTIO_BLK_T_FLUSH);
    _ = writeGuestInt(u64, hhdm, vmid, 0x1FE0 + 0, 0x1100);
    _ = writeGuestInt(u32, hhdm, vmid, 0x1FE0 + 8, 16);
    _ = writeGuestInt(u16, hhdm, vmid, 0x1FE0 + 12, virtio_blk.VIRTQ_DESC_F_NEXT);
    _ = writeGuestInt(u16, hhdm, vmid, 0x1FE0 + 14, 2); // -> status descriptor directly
    const flush_info = try decodeDescriptorChain(hhdm, vmid, q, 0);
    try std.testing.expectEqual(@as(u32, @backingInt(storaged_protocol.ReqType.flush)), flush_info.storaged_req_type);
    try std.testing.expectEqual(@as(u32, 0), flush_info.data_len);

    // 2-descriptor chain with VIRTIO_BLK_T_IN must fail with InvalidDescriptor
    _ = writeGuestInt(u32, hhdm, vmid, 0x1100, virtio_blk.VIRTIO_BLK_T_IN);
    try std.testing.expectError(error.InvalidDescriptor, decodeDescriptorChain(hhdm, vmid, q, 0));

    // 3-descriptor chain with VIRTIO_BLK_T_FLUSH must fail with InvalidDescriptor
    _ = writeGuestInt(u32, hhdm, vmid, 0x1100, virtio_blk.VIRTIO_BLK_T_FLUSH);
    _ = writeGuestInt(u16, hhdm, vmid, 0x1FE0 + 14, 1); // -> data descriptor -> status descriptor
    try std.testing.expectError(error.InvalidDescriptor, decodeDescriptorChain(hhdm, vmid, q, 0));

    // Verify control_handler.handleKernelControlPage accepts .virtio_blk_response from storaged
    // and rejects non-storaged senders
    const control_handler = @import("../control/control_handler.zig");
    const node_config = @import("../ipc/node_config.zig");
    var resp_buf: [@sizeOf(control_protocol.ControlHeader) + @sizeOf(control_protocol.VirtioBlkResponsePayload)]u8 = undefined;
    const ch = control_protocol.ControlHeader{
        .op = .virtio_blk_response,
        .payload_len = @sizeOf(control_protocol.VirtioBlkResponsePayload),
    };
    const resp_payload = control_protocol.VirtioBlkResponsePayload{
        .vmid = vmid,
        .head_idx = 0,
        .status = virtio_blk.VIRTIO_BLK_S_OK,
    };
    @memcpy(resp_buf[0..@sizeOf(control_protocol.ControlHeader)], std.mem.asBytes(&ch));
    @memcpy(resp_buf[@sizeOf(control_protocol.ControlHeader)..], std.mem.asBytes(&resp_payload));

    const local_node = node_config.getLocalNode();
    const unauthorized_src = dipc.Address{
        .node = local_node,
        .endpoint = @backingInt(identity.ReservedEndpoint.netd),
    };
    const dst_addr = dipc.Address{
        .node = local_node,
        .endpoint = @backingInt(identity.ReservedEndpoint.kernel_control),
    };
    const bad_page = try dipc.allocPageMessage(hhdm, unauthorized_src, dst_addr, &resp_buf);
    defer dipc.freePageMessage(bad_page);
    try std.testing.expectError(error.Unauthorized, control_handler.handleKernelControlPage(hhdm, &table, bad_page));

    const storaged_src = dipc.Address{
        .node = local_node,
        .endpoint = @backingInt(identity.ReservedEndpoint.storaged),
    };
    _ = writeGuestInt(u16, hhdm, vmid, 0x1FE0 + 14, 2); // restore valid 2-descriptor FLUSH chain
    _ = writeGuestInt(u8, hhdm, vmid, 0x1400, 0xFF);
    const ok_page = try dipc.allocPageMessage(hhdm, storaged_src, dst_addr, &resp_buf);
    defer dipc.freePageMessage(ok_page);
    try control_handler.handleKernelControlPage(hhdm, &table, ok_page);
    try std.testing.expectEqual(@as(u8, virtio_blk.VIRTIO_BLK_S_OK), readGuestInt(u8, hhdm, vmid, 0x1400).?);
}

test "virtio-blk request metadata matches storaged wire layout" {
    const info = DescriptorChainInfo{
        .request = .{ .type = virtio_blk.VIRTIO_BLK_T_OUT, .sector = 0x1122_3344_5566_7788 },
        .storaged_req_type = @backingInt(storaged_protocol.ReqType.write),
        .data_hpa = 0x8877_6655_4433_2211,
        .data_len = 4096,
        .status_addr = 0xAABB_CCDD_EEFF_0011,
    };
    const request = makeStoragedRequest(info, 0x1234_5678, 0x9ABC);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(@TypeOf(request)));
    try std.testing.expectEqual(virtio_blk.VIRTIO_BLK_T_OUT, request.req_type);
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), request.sector);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), request.vmid);
    try std.testing.expectEqual(@as(u16, 0x9ABC), request.chain_head);
    try std.testing.expectEqual(@as(u16, 4096), request.data_len);
    try std.testing.expectEqual(@as(u64, 0x8877_6655_4433_2211), request.data_hpa);
}

test "virtio-blk FUA writes map to write-plus-flush storage requests" {
    try std.testing.expectEqual(
        @as(?u32, @backingInt(storaged_protocol.ReqType.write)),
        storagedRequestType(virtio_blk.VIRTIO_BLK_T_OUT),
    );
    try std.testing.expectEqual(
        @as(?u32, @backingInt(storaged_protocol.ReqType.write_fua)),
        storagedRequestType(virtio_blk.VIRTIO_BLK_T_OUT | virtio_blk.VIRTIO_BLK_T_FUA),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        storagedRequestType(virtio_blk.VIRTIO_BLK_T_IN | virtio_blk.VIRTIO_BLK_T_FUA),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        storagedRequestType(virtio_blk.VIRTIO_BLK_T_FLUSH | virtio_blk.VIRTIO_BLK_T_FUA),
    );
}

test "m1: microvm_registry affinity, device state, and uart circular buffer" {
    const reg = @import("microvm_registry.zig");
    reg.init();

    const name: [32]u8 = "test-vm-1".* ++ @as([23]u8, @splat(0));
    const container: [32]u8 = "container-1".* ++ @as([21]u8, @splat(0));

    const id = reg.createWithAffinity(name, container, 1024, 1, 0, 0, 0, 0, 1).?;
    try std.testing.expect(id >= 1);

    const inst = reg.lookup(id).?;
    try std.testing.expectEqual(@as(?u8, 1), inst.pinned_cpu);
    try std.testing.expectEqual(true, inst.in_use);
    try std.testing.expectEqual(reg.MicrovmState.created, inst.state);

    // Verify setPinnedCpu
    try std.testing.expect(reg.setPinnedCpu(id, 2));
    const updated = reg.lookup(id).?;
    try std.testing.expectEqual(@as(?u8, 2), updated.pinned_cpu);

    // Verify VirtualDeviceState & UART circular buffer
    var uart: reg.VmUartState = .{};
    try std.testing.expect(uart.isRxEmpty());
    try std.testing.expectEqual(@as(usize, 0), uart.tx_len);

    // Test UART TX writing
    uart.writeTxSlice("Hello, MicroVM!");
    try std.testing.expectEqual(@as(usize, 15), uart.tx_len);
    var log_buf: [32]u8 = undefined;
    const n = uart.readTxLog(&log_buf);
    try std.testing.expectEqual(@as(usize, 15), n);
    try std.testing.expectEqualStrings("Hello, MicroVM!", log_buf[0..n]);

    // Test UART RX injection and consumption
    try std.testing.expect(uart.injectRxByte('X'));
    try std.testing.expect(!uart.isRxEmpty());
    try std.testing.expect(uart.irq4_pending);
    try std.testing.expectEqual(@as(?u8, 'X'), uart.readRxByte());
    try std.testing.expect(uart.isRxEmpty());
    try std.testing.expect(!uart.irq4_pending);

    // Test registry console log helper
    var log_out: [64]u8 = undefined;
    _ = reg.getConsoleLog(id, &log_out);
    try std.testing.expect(reg.injectConsoleInput(id, 'Z'));
}

test "m5: production UART rejects overflow and preserves FIFO order through wraparound" {
    const reg = @import("microvm_registry.zig");
    reg.init();

    const name: [32]u8 = "uart-stress".* ++ @as([21]u8, @splat(0));
    const container: [32]u8 = @splat(0);
    const id = reg.create(name, container, 1024, 1, 0, 0, 0, 0).?;

    for (0..256) |i| {
        try std.testing.expect(reg.injectConsoleInput(id, @truncate(i)));
    }
    try std.testing.expect(!reg.injectConsoleInput(id, 0xFF));
    try std.testing.expect(!reg.injectConsoleInput(0xFFFF_FFFF, 0xFF));

    try std.testing.expect(reg.hasConsoleInput(id));
    reg.configureConsoleUartInterrupt(id, 0x01, true);
    try std.testing.expect(reg.consoleUartInterruptPending(id, false));
    try std.testing.expect(reg.consoleUartInterruptPending(id, true));

    for (0..256) |i| {
        try std.testing.expectEqual(@as(?u8, @truncate(i)), reg.readConsoleInput(id));
    }
    try std.testing.expect(!reg.hasConsoleInput(id));
    try std.testing.expect(!reg.consoleUartInterruptPending(id, false));

    for (0..10) |i| {
        try std.testing.expect(reg.injectConsoleInput(id, @truncate(i + 10)));
    }
    for (0..10) |i| {
        try std.testing.expectEqual(@as(?u8, @truncate(i + 10)), reg.readConsoleInput(id));
    }
}

test "m5: production UART TX logs stay isolated and retain the newest 4096 bytes" {
    const reg = @import("microvm_registry.zig");
    reg.init();

    const container: [32]u8 = @splat(0);
    const first_name: [32]u8 = "uart-tx-1".* ++ @as([23]u8, @splat(0));
    const second_name: [32]u8 = "uart-tx-2".* ++ @as([23]u8, @splat(0));
    const first_id = reg.create(first_name, container, 1024, 1, 0, 0, 0, 0).?;
    const second_id = reg.create(second_name, container, 1024, 1, 0, 0, 0, 0).?;

    for (0..4097) |i| reg.writeConsoleByte(first_id, @truncate(i));
    reg.writeConsoleByte(second_id, 'B');

    var first_log: [4096]u8 = undefined;
    var second_log: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4096), reg.getConsoleLog(first_id, &first_log));
    try std.testing.expectEqual(@as(u8, 1), first_log[0]);
    try std.testing.expectEqual(@as(u8, 0), first_log[4095]);
    try std.testing.expectEqual(@as(usize, 1), reg.getConsoleLog(second_id, &second_log));
    try std.testing.expectEqual(@as(u8, 'B'), second_log[0]);
    try std.testing.expectEqual(@as(usize, 0), reg.getConsoleLog(0xFFFF_FFFF, &second_log));
}

test "m1: microvm_bridge synchronized enqueue and dequeue" {
    init();

    const m_id: identity.MicrovmId = 42;
    const page: u64 = 0x10000;

    try enqueue(m_id, page);
    const entry = dequeue().?;
    try std.testing.expectEqual(@as(u32, 42), entry.microvm_id);
    try std.testing.expectEqual(page, entry.page_phys);

    // Queue should now be empty
    try std.testing.expect(dequeue() == null);
}

test "m1: gdt per-core tssBaseForCpu" {
    const gdt_mod = @import("../arch/x86_64/gdt.zig");
    const tss0 = gdt_mod.tssBaseForCpu(0);
    const tss1 = gdt_mod.tssBaseForCpu(1);

    try std.testing.expect(tss0 != 0);
    try std.testing.expect(tss1 != 0);
    try std.testing.expect(tss0 != tss1);
    try std.testing.expectEqual(tss0, gdt_mod.tssBase());
}
