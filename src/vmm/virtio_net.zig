const std = @import("std");
const dipc = @import("../ipc/dipc.zig");
const identity = @import("../ipc/identity.zig");
const microvm_registry = @import("microvm_registry.zig");
const pmm = @import("../kernel/pmm.zig");
const router = @import("../ipc/router.zig");
const endpoint_table = @import("../ipc/endpoint_table.zig");
const netd_protocol = @import("../user/protocols/netd_protocol.zig");

/// Virtio-net MMIO device registers (minimal set for bring-up)
pub const VirtioReg = enum(u16) {
    MagicValue = 0x000,
    Version = 0x004,
    DeviceID = 0x008,
    VendorID = 0x00c,
    DeviceFeatures = 0x010,
    DeviceFeaturesSel = 0x014,
    DriverFeatures = 0x020,
    DriverFeaturesSel = 0x024,
    QueueSel = 0x030,
    QueueNumMax = 0x034,
    QueueNum = 0x038,
    QueueReady = 0x044,
    QueueNotify = 0x050,
    InterruptStatus = 0x060,
    InterruptACK = 0x064,
    Status = 0x070,
    QueueDescLow = 0x080,
    QueueDescHigh = 0x084,
    QueueDriverLow = 0x090,
    QueueDriverHigh = 0x094,
    QueueDeviceLow = 0x0a0,
    QueueDeviceHigh = 0x0a4,
    ConfigGeneration = 0x0fc,
    _,
};

pub const VIRTIO_MAGIC: u32 = 0x74726976; // 'virt'
pub const VIRTIO_VERSION: u32 = 2;
pub const VIRTIO_DEVICE_NET: u32 = 1;
pub const VIRTIO_VENDOR_ID: u32 = 0x554d4551; // 'QEMU'

/// Virtio-net specific config
pub const Config = extern struct {
    mac: [6]u8,
    status: u16,
    max_virtqueue_pairs: u16,
    mtu: u16,
};

/// Virtqueue Descriptor (Legacy/Modern shared layout)
pub const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const VIRTQ_DESC_F_NEXT: u16 = 1;
pub const VIRTQ_DESC_F_WRITE: u16 = 2;
pub const VIRTQ_DESC_F_INDIRECT: u16 = 4;

pub const VIRTQ_AVAIL_F_NO_INTERRUPT: u16 = 1;
pub const VIRTQ_USED_F_NO_NOTIFY: u16 = 1;
pub const VIRTIO_F_EVENT_IDX: u32 = 1 << 29;

const virtio_queue_size_max: u32 = 256;
const virtio_desc_size: usize = 16;

/// Per-instance virtio-net state
pub const DeviceInstance = struct {
    vmid: u32,
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u32 = 0,
    selected_queue: u32 = 0,
    queues: [2]QueueState = undefined, // 0: RX, 1: TX
    mac: [6]u8 = @splat(0),
    interrupt_status: u32 = 0,
    config: Config = undefined,

    pub fn hasEventIdx(self: *const DeviceInstance) bool {
        return (self.driver_features & VIRTIO_F_EVENT_IDX) != 0;
    }
};

pub const QueueState = struct {
    ready: bool = false,
    num: u32 = 0,
    desc_addr: u64 = 0,
    driver_addr: u64 = 0,
    device_addr: u64 = 0,
    last_avail_idx: u16 = 0,
    last_used_idx: u16 = 0,
};

var instances: [microvm_registry.TARGET_INSTANCES]DeviceInstance = undefined;
var initialized: bool = false;

pub fn init() void {
    for (&instances) |*inst| {
        inst.* = .{ .vmid = 0 };
    }
    initialized = true;
}

pub fn getInstance(vmid: u32) ?*DeviceInstance {
    if (!initialized) init();
    for (&instances) |*inst| {
        if (inst.vmid == vmid) return inst;
        if (inst.vmid == 0) {
            inst.vmid = vmid;
            inst.mac = netd_protocol.hostAssignedMac(vmid);
            for (&inst.queues) |*q| {
                q.* = .{};
            }
            return inst;
        }
    }
    return null;
}

pub fn resetInstance(vmid: u32) void {
    if (!initialized) return;
    for (&instances) |*inst| {
        if (inst.vmid == vmid) {
            inst.* = .{ .vmid = 0 };
        }
    }
}

/// Link back to VMX/Registry to translate GPA->HPA for descriptors.
pub var gpa_to_hpa_fn: ?*const fn (vmid: u32, gpa: u64) ?u64 = null;
pub var hhdm_offset: u64 = 0;
pub var system_endpoint_table: ?*const endpoint_table.EndpointTable = null;

fn translateGuestPageHpa(vmid: u32, page_gpa: u64) ?u64 {
    const translate = gpa_to_hpa_fn orelse return null;
    const aligned = page_gpa & ~@as(u64, 0xFFF);
    const raw = translate(vmid, aligned) orelse return null;
    return raw & ~@as(u64, 0xFFF);
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

fn readGuestBytes(vmid: u32, gpa: u64, out: []u8) bool {
    var offset: usize = 0;
    while (offset < out.len) {
        const cur_gpa = std.math.add(u64, gpa, @as(u64, @intCast(offset))) catch return false;
        const page_hpa = translateGuestPageHpa(vmid, cur_gpa) orelse return false;
        const page_off = @as(usize, @intCast(cur_gpa & 0xFFF));
        const chunk = @min(pmm.PAGE_SIZE - page_off, out.len - offset);
        const src: [*]const u8 = @ptrFromInt(hhdm_offset + page_hpa + page_off);
        @memcpy(out[offset .. offset + chunk], src[0..chunk]);
        offset += chunk;
    }
    return true;
}

fn writeGuestBytes(vmid: u32, gpa: u64, data: []const u8) bool {
    var offset: usize = 0;
    while (offset < data.len) {
        const cur_gpa = std.math.add(u64, gpa, @as(u64, @intCast(offset))) catch return false;
        const page_hpa = translateGuestPageHpa(vmid, cur_gpa) orelse return false;
        const page_off = @as(usize, @intCast(cur_gpa & 0xFFF));
        const chunk = @min(pmm.PAGE_SIZE - page_off, data.len - offset);
        const dst: [*]u8 = @ptrFromInt(hhdm_offset + page_hpa + page_off);
        @memcpy(dst[0..chunk], data[offset .. offset + chunk]);
        offset += chunk;
    }
    return true;
}

fn readGuestInt(comptime T: type, vmid: u32, gpa: u64) ?T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    if (!readGuestBytes(vmid, gpa, &bytes)) return null;
    return std.mem.readInt(T, &bytes, .little);
}

fn writeGuestInt(comptime T: type, vmid: u32, gpa: u64, val: T) bool {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, val, .little);
    return writeGuestBytes(vmid, gpa, &bytes);
}

fn validateQueueMemory(vmid: u32, q: *const QueueState, event_idx: bool) bool {
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

fn readDescriptor(vmid: u32, q: *const QueueState, idx: u16) ?VirtqDesc {
    if (!isDescriptorIndexValid(q, idx)) return null;
    const d_gpa = q.desc_addr + (@as(u64, idx) * virtio_desc_size);
    var raw: [16]u8 = undefined;
    if (!readGuestBytes(vmid, d_gpa, &raw)) return null;
    return .{
        .addr = std.mem.readInt(u64, raw[0..8], .little),
        .len = std.mem.readInt(u32, raw[8..12], .little),
        .flags = std.mem.readInt(u16, raw[12..14], .little),
        .next = std.mem.readInt(u16, raw[14..16], .little),
    };
}

/// Handle a read from the Virtio MMIO range
pub fn handleRead(vmid: u32, offset: u64) u32 {
    const inst = getInstance(vmid) orelse return 0;
    const reg_int = @as(u16, @intCast(offset & 0xFFF));

    // Config space access (starting at 0x100)
    if (reg_int >= 0x100 and reg_int < 0x200) {
        const config_offset = @as(usize, reg_int - 0x100);
        const config_ptr = @as([*]const u8, @ptrCast(&inst.mac));
        if (config_offset < @sizeOf([6]u8)) {
            var val: u32 = 0;
            const copy_len = @min(@as(usize, 4), @sizeOf([6]u8) - config_offset);
            @memcpy(@as([*]u8, @ptrCast(&val))[0..copy_len], config_ptr[config_offset .. config_offset + copy_len]);
            return val;
        }
        return 0;
    }

    const reg: VirtioReg = @fromBackingInt(@intCast(reg_int));

    return switch (reg) {
        .MagicValue => VIRTIO_MAGIC,
        .Version => VIRTIO_VERSION,
        .DeviceID => VIRTIO_DEVICE_NET,
        .VendorID => VIRTIO_VENDOR_ID,
        .DeviceFeatures => if (inst.device_features_sel == 0) VIRTIO_F_EVENT_IDX else 0,
        .Status => inst.status,
        .QueueNumMax => virtio_queue_size_max,
        .QueueReady => if (inst.selected_queue < 2) (if (inst.queues[inst.selected_queue].ready) 1 else 0) else 0,
        .InterruptStatus => inst.interrupt_status,
        else => 0,
    };
}

/// Handle a write to the Virtio MMIO range
pub fn handleWrite(vmid: u32, offset: u64, value: u32) void {
    const inst = getInstance(vmid) orelse return;
    const reg: VirtioReg = @fromBackingInt(@intCast(@as(u16, @intCast(offset & 0xFFF))));

    switch (reg) {
        .DeviceFeaturesSel => inst.device_features_sel = value,
        .DriverFeaturesSel => inst.driver_features_sel = value,
        .DriverFeatures => {
            if (inst.driver_features_sel == 0) {
                inst.driver_features = value & VIRTIO_F_EVENT_IDX;
            }
        },
        .Status => {
            inst.status = value;
            if (value == 0) {
                inst.device_features_sel = 0;
                inst.driver_features_sel = 0;
                inst.driver_features = 0;
                inst.selected_queue = 0;
                inst.interrupt_status = 0;
                for (&inst.queues) |*q| q.* = .{};
            }
        },
        .QueueSel => inst.selected_queue = value,
        .QueueNum => if (inst.selected_queue < 2) {
            inst.queues[inst.selected_queue].num = if (value <= virtio_queue_size_max) value else 0;
        },
        .QueueReady => if (inst.selected_queue < 2) {
            inst.queues[inst.selected_queue].ready = (value != 0);
        },
        .QueueDescLow => if (inst.selected_queue < 2) {
            inst.queues[inst.selected_queue].desc_addr = (inst.queues[inst.selected_queue].desc_addr & 0xFFFFFFFF_00000000) | value;
        },
        .QueueDescHigh => if (inst.selected_queue < 2) {
            inst.queues[inst.selected_queue].desc_addr = (inst.queues[inst.selected_queue].desc_addr & 0x00000000_FFFFFFFF) | (@as(u64, value) << 32);
        },
        .QueueDriverLow => if (inst.selected_queue < 2) {
            inst.queues[inst.selected_queue].driver_addr = (inst.queues[inst.selected_queue].driver_addr & 0xFFFFFFFF_00000000) | value;
        },
        .QueueDriverHigh => if (inst.selected_queue < 2) {
            inst.queues[inst.selected_queue].driver_addr = (inst.queues[inst.selected_queue].driver_addr & 0x00000000_FFFFFFFF) | (@as(u64, value) << 32);
        },
        .QueueDeviceLow => if (inst.selected_queue < 2) {
            inst.queues[inst.selected_queue].device_addr = (inst.queues[inst.selected_queue].device_addr & 0xFFFFFFFF_00000000) | value;
        },
        .QueueDeviceHigh => if (inst.selected_queue < 2) {
            inst.queues[inst.selected_queue].device_addr = (inst.queues[inst.selected_queue].device_addr & 0x00000000_FFFFFFFF) | (@as(u64, value) << 32);
        },
        .QueueNotify => {
            if (value == 1) {
                processQueueEx(inst, 1);
            }
        },
        .InterruptACK => inst.interrupt_status &= ~value,
        else => {},
    }
}

fn processQueueEx(inst: *DeviceInstance, qidx: u8) void {
    if (qidx != 1) return;
    if (!microvm_registry.isRunning(inst.vmid)) return;
    const q = &inst.queues[qidx];
    const event_idx = inst.hasEventIdx();
    if (!validateQueueMemory(inst.vmid, q, event_idx)) return;

    const avail_idx = readGuestInt(u16, inst.vmid, q.driver_addr + 2) orelse return;
    const pending = avail_idx -% q.last_avail_idx;
    if (pending > @as(u16, @intCast(q.num))) return;

    while (q.last_avail_idx != avail_idx) {
        const ring_gpa = q.driver_addr + 4 + (@as(u64, q.last_avail_idx % @as(u16, @intCast(q.num))) * 2);
        const head_idx = readGuestInt(u16, inst.vmid, ring_gpa) orelse return;
        q.last_avail_idx +%= 1;

        if (event_idx) {
            const avail_event_gpa = q.device_addr + 4 + (@as(u64, q.num) * 8);
            _ = writeGuestInt(u16, inst.vmid, avail_event_gpa, q.last_avail_idx);
        }

        processDescriptorChain(inst, qidx, head_idx);
    }
}

fn processDescriptorChain(inst: *DeviceInstance, qidx: u8, head_idx: u16) void {
    const q = &inst.queues[qidx];
    if (!isQueueValid(q) or !isDescriptorIndexValid(q, head_idx)) return;

    // First pass: validate the entire descriptor chain and compute total TX byte length.
    var curr_idx = head_idx;
    var descriptors_seen: u32 = 0;
    var total_len: usize = 0;
    var terminated = false;

    while (descriptors_seen < q.num) : (descriptors_seen += 1) {
        const desc = readDescriptor(inst.vmid, q, curr_idx) orelse break;
        if ((desc.flags & VIRTQ_DESC_F_INDIRECT) != 0) break;
        if ((desc.flags & VIRTQ_DESC_F_WRITE) != 0) break; // TX descriptors must be device-readable

        const desc_len = @as(usize, desc.len);
        const new_total = std.math.add(usize, total_len, desc_len) catch break;
        if (new_total > dipc.MAX_PAYLOAD) break;
        if (!validateGuestSpan(inst.vmid, desc.addr, desc_len)) break;

        total_len = new_total;
        if ((desc.flags & VIRTQ_DESC_F_NEXT) == 0) {
            terminated = true;
            break;
        }
        if (!isDescriptorIndexValid(q, desc.next)) break;
        curr_idx = desc.next;
    }

    if (terminated and qidx == 1 and total_len > 0) {
        dispatchTxChain(inst, q, head_idx, total_len);
    }

    markUsed(inst, qidx, head_idx, 0);
}

fn dispatchTxChain(inst: *DeviceInstance, q: *const QueueState, head_idx: u16, total_len: usize) void {
    const table = system_endpoint_table orelse return;
    var stage: [dipc.MAX_PAYLOAD]u8 = undefined;

    var curr_idx = head_idx;
    var offset: usize = 0;
    var steps: u32 = 0;
    while (steps < q.num) : (steps += 1) {
        const desc = readDescriptor(inst.vmid, q, curr_idx) orelse return;
        const dlen = @as(usize, desc.len);
        if (offset + dlen > total_len) return;
        if (dlen > 0 and !readGuestBytes(inst.vmid, desc.addr, stage[offset .. offset + dlen])) return;
        offset += dlen;
        if ((desc.flags & VIRTQ_DESC_F_NEXT) == 0) break;
        curr_idx = desc.next;
    }
    if (offset != total_len) return;

    const msg_phys = dipc.allocPageMessage(
        hhdm_offset,
        .{
            .node = dipc.Ipv6Addr.loopback(),
            .endpoint = identity.MICROVM_GUEST_TX_ENDPOINT_BASE + @as(u64, inst.vmid),
        },
        .{ .node = dipc.Ipv6Addr.loopback(), .endpoint = @backingInt(identity.ReservedEndpoint.netd) },
        stage[0..total_len],
    ) catch return;

    _ = router.routePageWithLocalNode(hhdm_offset, table, msg_phys) catch {
        dipc.freePageMessage(msg_phys);
    };
}

fn isQueueValid(q: *const QueueState) bool {
    return q.ready and q.num > 0 and q.num <= virtio_queue_size_max;
}

fn isDescriptorIndexValid(q: *const QueueState, index: u16) bool {
    return @as(u32, index) < q.num;
}

fn shouldNotifyDriver(inst: *const DeviceInstance, q: *const QueueState, old_used_idx: u16, new_used_idx: u16) bool {
    if (inst.hasEventIdx()) {
        const used_event_gpa = q.driver_addr + 4 + (@as(u64, q.num) * 2);
        const used_event = readGuestInt(u16, inst.vmid, used_event_gpa) orelse return false;
        return (new_used_idx -% used_event -% 1) < (new_used_idx -% old_used_idx);
    }
    const avail_flags = readGuestInt(u16, inst.vmid, q.driver_addr) orelse return false;
    return (avail_flags & VIRTQ_AVAIL_F_NO_INTERRUPT) == 0;
}

fn markUsed(inst: *DeviceInstance, qidx: u8, head_idx: u16, len: u32) void {
    const q = &inst.queues[qidx];
    if (!isQueueValid(q) or !isDescriptorIndexValid(q, head_idx)) return;

    const old_used_idx = readGuestInt(u16, inst.vmid, q.device_addr + 2) orelse return;
    const elem_gpa = q.device_addr + 4 + (@as(u64, old_used_idx % @as(u16, @intCast(q.num))) * 8);

    if (!writeGuestInt(u32, inst.vmid, elem_gpa, @as(u32, head_idx))) return;
    if (!writeGuestInt(u32, inst.vmid, elem_gpa + 4, len)) return;

    const new_used_idx = old_used_idx +% 1;
    if (!writeGuestInt(u16, inst.vmid, q.device_addr + 2, new_used_idx)) return;
    q.last_used_idx = new_used_idx;

    if (shouldNotifyDriver(inst, q, old_used_idx, new_used_idx)) {
        inst.interrupt_status |= 1;
    }
}

pub fn injectPacket(vmid: u32, data: []const u8) void {
    if (data.len == 0 or data.len > dipc.MAX_PAYLOAD) return;
    if (!microvm_registry.isRunning(vmid)) return;
    const inst = getInstance(vmid) orelse return;
    const q = &inst.queues[0];
    const event_idx = inst.hasEventIdx();
    if (!validateQueueMemory(inst.vmid, q, event_idx)) return;

    const avail_idx = readGuestInt(u16, inst.vmid, q.driver_addr + 2) orelse return;
    if (q.last_avail_idx == avail_idx) return;
    const pending = avail_idx -% q.last_avail_idx;
    if (pending > @as(u16, @intCast(q.num))) return;

    const ring_gpa = q.driver_addr + 4 + (@as(u64, q.last_avail_idx % @as(u16, @intCast(q.num))) * 2);
    const head_idx = readGuestInt(u16, inst.vmid, ring_gpa) orelse return;
    if (!isDescriptorIndexValid(q, head_idx)) return;

    // Validate the RX descriptor chain before consuming or writing into guest memory.
    var curr_idx = head_idx;
    var steps: u32 = 0;
    var total_capacity: usize = 0;
    var valid_chain = false;

    while (steps < q.num) : (steps += 1) {
        const desc = readDescriptor(inst.vmid, q, curr_idx) orelse break;
        if ((desc.flags & VIRTQ_DESC_F_INDIRECT) != 0) break;
        if ((desc.flags & VIRTQ_DESC_F_WRITE) == 0) break; // RX descriptors must be device-writable

        const dlen = @as(usize, desc.len);
        if (!validateGuestSpan(inst.vmid, desc.addr, dlen)) break;
        total_capacity = std.math.add(usize, total_capacity, dlen) catch break;

        if ((desc.flags & VIRTQ_DESC_F_NEXT) == 0) {
            valid_chain = true;
            break;
        }
        if (!isDescriptorIndexValid(q, desc.next)) break;
        curr_idx = desc.next;
    }

    if (!valid_chain or total_capacity == 0) return;

    q.last_avail_idx +%= 1;
    if (event_idx) {
        const avail_event_gpa = q.device_addr + 4 + (@as(u64, q.num) * 8);
        _ = writeGuestInt(u16, inst.vmid, avail_event_gpa, q.last_avail_idx);
    }

    const copy_total = @min(total_capacity, data.len);
    var copied: usize = 0;
    curr_idx = head_idx;
    steps = 0;
    while (steps < q.num and copied < copy_total) : (steps += 1) {
        const desc = readDescriptor(inst.vmid, q, curr_idx) orelse return;
        const chunk = @min(@as(usize, desc.len), copy_total - copied);
        if (chunk > 0 and !writeGuestBytes(inst.vmid, desc.addr, data[copied .. copied + chunk])) return;
        copied += chunk;
        if ((desc.flags & VIRTQ_DESC_F_NEXT) == 0) break;
        curr_idx = desc.next;
    }

    markUsed(inst, 0, head_idx, @intCast(copied));
}

const limine = @import("../kernel/limine.zig");

test "virtio-net cross-page RX/TX chains, DIPC reclaim, and interrupt suppression" {
    const TestState = struct {
        var net_test_backing: [16][4096]u8 align(4096) = undefined;

        fn netTestTranslateDiscontiguous(_: u32, gpa: u64) ?u64 {
            const page = gpa & ~@as(u64, 0xFFF);
            return switch (page) {
                0x1000 => 4 * pmm.PAGE_SIZE,
                0x2000 => 3 * pmm.PAGE_SIZE,
                0x3000 => 2 * pmm.PAGE_SIZE,
                0x4000 => 1 * pmm.PAGE_SIZE,
                0x5000 => 5 * pmm.PAGE_SIZE,
                else => null,
            };
        }
    };

    @memset(std.mem.asBytes(&TestState.net_test_backing), 0);
    const hhdm = @intFromPtr(&TestState.net_test_backing);
    var entry = limine.MemmapEntry{
        .base = 0,
        .length = @sizeOf(@TypeOf(TestState.net_test_backing)),
        .kind = limine.MEMMAP_USABLE,
    };
    var entries = [_]*limine.MemmapEntry{&entry};
    var memmap = limine.MemmapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = @ptrCast(&entries),
    };
    pmm.init(&memmap, hhdm);
    for (1..6) |p| pmm.setBit(p);

    microvm_registry.init();
    const vm_name: [32]u8 = @splat(0);
    const vm_container: [32]u8 = @splat(0);
    const vmid = microvm_registry.create(vm_name, vm_container, 1, 1, 0, 0, 0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(microvm_registry.start(vmid));

    init();
    gpa_to_hpa_fn = TestState.netTestTranslateDiscontiguous;
    hhdm_offset = hhdm;
    var table: endpoint_table.EndpointTable = undefined;
    table.init();
    system_endpoint_table = &table;
    defer {
        gpa_to_hpa_fn = null;
        hhdm_offset = 0;
        system_endpoint_table = null;
    }

    const inst = getInstance(vmid).?;

    // 1. Test RX multi-descriptor chain across discontiguous pages with VIRTQ_AVAIL_F_NO_INTERRUPT
    const rx_q = &inst.queues[0];
    rx_q.* = .{
        .ready = true,
        .num = 4,
        .desc_addr = 0x1FF0, // Desc 0 on page 0x1000, Desc 1..3 on page 0x2000
        .driver_addr = 0x2FFE, // Straddles 0x2000 -> 0x3000
        .device_addr = 0x3FFC, // Straddles 0x3000 -> 0x4000
    };

    // Desc 0: 6 bytes writable at 0x4FFD (straddles 0x4000 -> 0x5000!), NEXT -> 1
    _ = writeGuestInt(u64, vmid, 0x1FF0 + 0, 0x4FFD);
    _ = writeGuestInt(u32, vmid, 0x1FF0 + 8, 6);
    _ = writeGuestInt(u16, vmid, 0x1FF0 + 12, VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_NEXT);
    _ = writeGuestInt(u16, vmid, 0x1FF0 + 14, 1);

    // Desc 1: 8 bytes writable at 0x3100
    _ = writeGuestInt(u64, vmid, 0x2000 + 0, 0x3100);
    _ = writeGuestInt(u32, vmid, 0x2000 + 8, 8);
    _ = writeGuestInt(u16, vmid, 0x2000 + 12, VIRTQ_DESC_F_WRITE);
    _ = writeGuestInt(u16, vmid, 0x2000 + 14, 0);

    // Avail ring: flags = VIRTQ_AVAIL_F_NO_INTERRUPT, idx = 1, ring[0] = 0
    _ = writeGuestInt(u16, vmid, rx_q.driver_addr + 0, VIRTQ_AVAIL_F_NO_INTERRUPT);
    _ = writeGuestInt(u16, vmid, rx_q.driver_addr + 2, 1);
    _ = writeGuestInt(u16, vmid, rx_q.driver_addr + 4, 0);

    // Notify Queue 0 (RX) must NOT prematurely consume the empty RX buffer!
    handleWrite(vmid, @backingInt(VirtioReg.QueueNotify), 0);
    try std.testing.expectEqual(@as(u16, 0), rx_q.last_avail_idx);

    const pkt = "hello-catenary";
    injectPacket(vmid, pkt);

    try std.testing.expectEqual(@as(u16, 1), rx_q.last_avail_idx);
    try std.testing.expectEqual(@as(u16, 1), readGuestInt(u16, vmid, rx_q.device_addr + 2).?);
    try std.testing.expectEqual(@as(u32, @intCast(pkt.len)), readGuestInt(u32, vmid, rx_q.device_addr + 8).?);
    // Interrupt suppressed by VIRTQ_AVAIL_F_NO_INTERRUPT
    try std.testing.expectEqual(@as(u32, 0), inst.interrupt_status);

    var rx_out: [14]u8 = undefined;
    try std.testing.expect(readGuestBytes(vmid, 0x4FFD, rx_out[0..6]));
    try std.testing.expect(readGuestBytes(vmid, 0x3100, rx_out[6..14]));
    try std.testing.expectEqualSlices(u8, pkt, &rx_out);

    // 2. Test TX descriptor chain when netd route fails: must reclaim DIPC page and complete used ring
    const tx_q = &inst.queues[1];
    tx_q.* = .{
        .ready = true,
        .num = 4,
        .desc_addr = 0x1F00,
        .driver_addr = 0x2F00,
        .device_addr = 0x3F00,
    };

    // Desc 0 (device-readable, 5 bytes at 0x1100)
    _ = writeGuestBytes(vmid, 0x1100, "txpkt");
    _ = writeGuestInt(u64, vmid, 0x1F00 + 0, 0x1100);
    _ = writeGuestInt(u32, vmid, 0x1F00 + 8, 5);
    _ = writeGuestInt(u16, vmid, 0x1F00 + 12, 0);
    _ = writeGuestInt(u16, vmid, 0x1F00 + 14, 0);

    _ = writeGuestInt(u16, vmid, tx_q.driver_addr + 0, 0); // Interrupts enabled
    _ = writeGuestInt(u16, vmid, tx_q.driver_addr + 2, 1);
    _ = writeGuestInt(u16, vmid, tx_q.driver_addr + 4, 0);

    const probe_before = pmm.allocPage().?;
    pmm.freePage(probe_before);

    handleWrite(vmid, @backingInt(VirtioReg.QueueNotify), 1);

    // Verify TX DIPC message page was reclaimed after route failure (no netd registered)
    const probe_after = pmm.allocPage().?;
    pmm.freePage(probe_after);
    try std.testing.expectEqual(probe_before, probe_after);

    try std.testing.expectEqual(@as(u16, 1), readGuestInt(u16, vmid, tx_q.device_addr + 2).?);
    try std.testing.expectEqual(@as(u32, 1), inst.interrupt_status);

    try std.testing.expect(microvm_registry.stop(vmid));
    _ = writeGuestInt(u16, vmid, rx_q.driver_addr + 2, 2);
    injectPacket(vmid, pkt);
    try std.testing.expectEqual(@as(u16, 1), rx_q.last_avail_idx);

    _ = writeGuestInt(u16, vmid, tx_q.driver_addr + 2, 2);
    handleWrite(vmid, @backingInt(VirtioReg.QueueNotify), 1);
    try std.testing.expectEqual(@as(u16, 1), tx_q.last_avail_idx);
    try std.testing.expect(microvm_registry.completeStop(vmid));
    try std.testing.expect(microvm_registry.delete(vmid));
}
