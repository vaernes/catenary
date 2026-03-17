const std = @import("std");
const dipc = @import("../ipc/dipc.zig");
const identity = @import("../ipc/identity.zig");
const microvm_registry = @import("microvm_registry.zig");
const pmm = @import("../kernel/pmm.zig");
const router = @import("../ipc/router.zig");
const endpoint_table = @import("../ipc/endpoint_table.zig");

/// Virtio MMIO device and block-device specific registers.
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
pub const VIRTIO_DEVICE_BLOCK: u32 = 2;
pub const VIRTIO_VENDOR_ID: u32 = 0x554d4551; // 'QEMU'

/// Virtio-blk specific config (minimal)
pub const Config = extern struct {
    capacity: u64,
    size_max: u32,
    seg_max: u32,
};

/// Virtio-blk request header (sent in DIPC payload to storaged)
pub const RequestHeader = extern struct {
    type: u32,
    _reserved: u32 = 0,
    sector: u64,
};

pub const VIRTIO_BLK_T_IN: u32 = 0;
pub const VIRTIO_BLK_T_OUT: u32 = 1;
pub const VIRTIO_BLK_T_FLUSH: u32 = 4;

pub const VIRTIO_BLK_S_OK: u8 = 0;
pub const VIRTIO_BLK_S_IOERR: u8 = 1;

/// Per-instance virtio-blk state.
pub const DeviceInstance = struct {
    vmid: u32,
    status: u32 = 0,
    selected_queue: u32 = 0,
    queues: [1]QueueState = undefined, // Blk usually has 1 request queue
    interrupt_status: u32 = 0,
    capacity_sectors: u64 = 0x40000, // 128 MiB default
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

pub fn handleRead(vmid: u32, offset: u64) u32 {
    const inst = getInstance(vmid) orelse return 0xFFFFFFFF;
    if (offset >= 0x100) {
        // Handle Config space (0x100+)
        const cfg_off = offset - 0x100;
        if (cfg_off == 0) return @as(u32, @truncate(inst.capacity_sectors));
        if (cfg_off == 4) return @as(u32, @truncate(inst.capacity_sectors >> 32));
        return 0;
    }

    const reg = @as(VirtioReg, @enumFromInt(@as(u16, @truncate(offset))));
    return switch (reg) {
        .MagicValue => VIRTIO_MAGIC,
        .Version => VIRTIO_VERSION,
        .DeviceID => VIRTIO_DEVICE_BLOCK,
        .VendorID => VIRTIO_VENDOR_ID,
        .DeviceFeatures => 0, // No specific features enabled for now
        .QueueNumMax => 256,
        .QueueReady => if (inst.selected_queue < 1) (if (inst.queues[0].ready) @as(u32, 1) else 0) else 0,
        .InterruptStatus => inst.interrupt_status,
        .Status => inst.status,
        .ConfigGeneration => 0,
        else => 0,
    };
}

pub fn handleWrite(vmid: u32, offset: u64, val: u32) void {
    const inst = getInstance(vmid) orelse return;
    if (offset >= 0x100) return; // Read-only config for now

    const reg = @as(VirtioReg, @enumFromInt(@as(u16, @truncate(offset))));
    switch (reg) {
        .DeviceFeaturesSel => {},
        .DriverFeaturesSel => {},
        .QueueSel => inst.selected_queue = val,
        .QueueNum => {
            if (inst.selected_queue < 1) inst.queues[0].num = val;
        },
        .QueueReady => {
            if (inst.selected_queue < 1) inst.queues[0].ready = (val != 0);
        },
        .QueueNotify => {
            // This is the trigger for I/O!
            // We'll call back into microvm_bridge to route to storaged.
            // For now, we stub this out or just log.
            const microvm_bridge = @import("microvm_bridge.zig");
            microvm_bridge.routeVirtioBlkNotify(vmid, @as(u16, @truncate(val)));
        },
        .InterruptACK => inst.interrupt_status &= ~val,
        .Status => inst.status = val,
        .QueueDescLow => {
            if (inst.selected_queue < 1) inst.queues[0].desc_addr = (inst.queues[0].desc_addr & 0xFFFFFFFF_00000000) | val;
        },
        .QueueDescHigh => {
            if (inst.selected_queue < 1) inst.queues[0].desc_addr = (inst.queues[0].desc_addr & 0x00000000_FFFFFFFF) | (@as(u64, val) << 32);
        },
        .QueueDriverLow => {
            if (inst.selected_queue < 1) inst.queues[0].driver_addr = (inst.queues[0].driver_addr & 0xFFFFFFFF_00000000) | val;
        },
        .QueueDriverHigh => {
            if (inst.selected_queue < 1) inst.queues[0].driver_addr = (inst.queues[0].driver_addr & 0x00000000_FFFFFFFF) | (@as(u64, val) << 32);
        },
        .QueueDeviceLow => {
            if (inst.selected_queue < 1) inst.queues[0].device_addr = (inst.queues[0].device_addr & 0xFFFFFFFF_00000000) | val;
        },
        .QueueDeviceHigh => {
            if (inst.selected_queue < 1) inst.queues[0].device_addr = (inst.queues[0].device_addr & 0x00000000_FFFFFFFF) | (@as(u64, val) << 32);
        },
        else => {},
    }
}
