const std = @import("std");
const dipc = @import("../ipc/dipc.zig");
const identity = @import("../ipc/identity.zig");
const microvm_registry = @import("microvm_registry.zig");
const pmm = @import("../kernel/pmm.zig");
const router = @import("../ipc/router.zig");
const endpoint_table = @import("../ipc/endpoint_table.zig");

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

/// Per-instance virtio-net state
pub const DeviceInstance = struct {
    vmid: u32,
    status: u32 = 0,
    selected_queue: u32 = 0,
    queues: [2]QueueState = undefined, // 0: RX, 1: TX
    mac: [6]u8 = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }, // Default MAC
    interrupt_status: u32 = 0,
    config: Config = undefined,
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
            for (&inst.queues) |*q| {
                q.* = .{};
            }
            return inst;
        }
    }
    return null;
}

/// Link back to VMX/Registry to translate GPA->HPA for descriptors.
pub var gpa_to_hpa_fn: ?*const fn (vmid: u32, gpa: u64) ?u64 = null;
pub var hhdm_offset: u64 = 0;
pub var system_endpoint_table: ?*const endpoint_table.EndpointTable = null;

/// Handle a read from the Virtio MMIO range
pub fn handleRead(vmid: u32, offset: u64) u32 {
    const inst = getInstance(vmid) orelse return 0;
    const reg_int = @as(u16, @intCast(offset & 0xFFF));

    // Config space access (starting at 0x100)
    if (reg_int >= 0x100 and reg_int < 0x200) {
        const config_offset = reg_int - 0x100;
        const config_ptr = @as([*]const u8, @ptrCast(&inst.mac));
        if (config_offset + 4 <= @sizeOf([6]u8)) {
            var val: u32 = 0;
            @memcpy(@as(*[4]u8, @ptrCast(&val)), config_ptr[config_offset .. config_offset + 4]);
            return val;
        }
        return 0;
    }

    const reg: VirtioReg = @enumFromInt(reg_int);

    return switch (reg) {
        .MagicValue => VIRTIO_MAGIC,
        .Version => VIRTIO_VERSION,
        .DeviceID => VIRTIO_DEVICE_NET,
        .VendorID => VIRTIO_VENDOR_ID,
        .Status => inst.status,
        .QueueNumMax => 256,
        .QueueReady => if (inst.selected_queue < 2) (if (inst.queues[inst.selected_queue].ready) 1 else 0) else 0,
        .InterruptStatus => inst.interrupt_status,
        else => 0,
    };
}

/// Handle a write to the Virtio MMIO range
pub fn handleWrite(vmid: u32, offset: u64, value: u32) void {
    const inst = getInstance(vmid) orelse return;
    const reg: VirtioReg = @enumFromInt(@as(u16, @intCast(offset & 0xFFF)));

    switch (reg) {
        .Status => inst.status = value,
        .QueueSel => inst.selected_queue = value,
        .QueueNum => if (inst.selected_queue < 2) {
            inst.queues[inst.selected_queue].num = value;
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
            if (value < 2) {
                processQueueEx(inst, @intCast(value));
            }
        },
        .InterruptACK => inst.interrupt_status &= ~value,
        else => {},
    }
}

fn processQueueEx(inst: *DeviceInstance, qidx: u8) void {
    const q = &inst.queues[qidx];
    if (!q.ready) return;

    const translate = gpa_to_hpa_fn orelse return;
    const avail_hpa = translate(inst.vmid, q.driver_addr) orelse return;

    const avail_ring = @as(*const extern struct {
        flags: u16,
        idx: u16,
        ring: [256]u16,
    }, @ptrFromInt(hhdm_offset + avail_hpa));

    while (q.last_avail_idx != avail_ring.idx) {
        const head_idx = avail_ring.ring[q.last_avail_idx % 256];
        processDescriptorChain(inst, qidx, head_idx);
        q.last_avail_idx +%= 1;
    }
}

fn processDescriptorChain(inst: *DeviceInstance, qidx: u8, head_idx: u16) void {
    const q = &inst.queues[qidx];
    const translate = gpa_to_hpa_fn orelse return;
    const desc_hpa = translate(inst.vmid, q.desc_addr) orelse return;
    const desc_table = @as([*]const VirtqDesc, @ptrFromInt(hhdm_offset + desc_hpa));

    var curr_idx = head_idx;
    while (true) {
        const desc = desc_table[curr_idx];
        if (qidx == 1) { // TX
            handleTxBuffer(inst, desc.addr, desc.len);
        }

        if ((desc.flags & VIRTQ_DESC_F_NEXT) == 0) {
            markUsed(inst, qidx, head_idx, 0);
            break;
        }
        curr_idx = desc.next;
    }
}

fn markUsed(inst: *DeviceInstance, qidx: u8, head_idx: u16, len: u32) void {
    const q = &inst.queues[qidx];
    const translate = gpa_to_hpa_fn orelse return;
    const used_hpa = translate(inst.vmid, q.device_addr) orelse return;

    const used_ring = @as(*extern struct {
        flags: u16,
        idx: u16,
        ring: [256]extern struct {
            id: u32,
            len: u32,
        },
    }, @ptrFromInt(hhdm_offset + used_hpa));

    used_ring.ring[q.last_used_idx % 256] = .{
        .id = head_idx,
        .len = len,
    };
    q.last_used_idx +%= 1;
    used_ring.idx = q.last_used_idx;

    inst.interrupt_status |= 1;
}

fn handleTxBuffer(inst: *DeviceInstance, gpa: u64, len: u32) void {
    const translate = gpa_to_hpa_fn orelse return;
    const hpa = translate(inst.vmid, gpa) orelse return;

    // Use the system-wide endpoint table to route.
    // If the netd service is registered at ReservedEndpoint.netd, the message will reach it.
    const table = system_endpoint_table orelse return;

    const buffer = @as([*]const u8, @ptrFromInt(hhdm_offset + hpa))[0..@intCast(len)];

    // Source address: VM with an endpoint derived from its ID.
    // Destination address: Reserved netd service endpoint.
    const msg_phys = dipc.allocPageMessage(
        hhdm_offset,
        .{ .node = dipc.Ipv6Addr.loopback(), .endpoint = 0x1000 + @as(u64, inst.vmid) },
        .{ .node = dipc.Ipv6Addr.loopback(), .endpoint = @intFromEnum(identity.ReservedEndpoint.netd) },
        buffer,
    ) catch return;

    _ = router.routePageWithLocalNode(hhdm_offset, table, msg_phys) catch {
        // Drop on failure; PMM will clean up the page eventually
    };
}

pub fn injectPacket(vmid: u32, data: []const u8) void {
    const inst = getInstance(vmid) orelse return;
    const q = &inst.queues[0];
    if (!q.ready) return;

    const translate = gpa_to_hpa_fn orelse return;
    const avail_hpa = translate(inst.vmid, q.driver_addr) orelse return;
    const avail_ring = @as(*const extern struct {
        flags: u16,
        idx: u16,
        ring: [256]u16,
    }, @ptrFromInt(hhdm_offset + avail_hpa));

    if (q.last_avail_idx == avail_ring.idx) return;

    const head_idx = avail_ring.ring[q.last_avail_idx % 256];
    q.last_avail_idx +%= 1;

    const desc_hpa = translate(inst.vmid, q.desc_addr) orelse return;
    const desc_table = @as([*]const VirtqDesc, @ptrFromInt(hhdm_offset + desc_hpa));

    const desc = desc_table[head_idx];
    const dest_hpa = translate(inst.vmid, desc.addr) orelse return;
    const dest_ptr = @as([*]u8, @ptrFromInt(hhdm_offset + dest_hpa));

    const copy_len = @min(@as(usize, desc.len), data.len);
    @memcpy(dest_ptr[0..copy_len], data[0..copy_len]);

    markUsed(inst, 0, head_idx, @intCast(copy_len));
}
