// VMM MicroVM instance registry.
//
// Ring 0 tracks VMCS allocation state, MicroVM lifecycle, core affinity,
// and per-instance virtual device state for the VMX subsystem.
// Thread-safe across SMP cores via registry_lock.

const std = @import("std");
const builtin = @import("builtin");
const pmm = @import("../kernel/pmm.zig");

pub const MIN_INSTANCES: usize = 8;
pub const TARGET_INSTANCES: usize = 8;

pub const MicrovmState = enum(u8) {
    empty = 0,
    created = 1,
    running = 2,
    stopped = 3,
    deleted = 4,
    stopping = 5,
    failed = 6,
};

// ---------------------------------------------------------------------------
// Virtual Device State Struct Definitions
// ---------------------------------------------------------------------------

pub const VmPicState = struct {
    master_imr: u8 = 0xFF,
    slave_imr: u8 = 0xFF,
    master_icw_step: u8 = 0,
    slave_icw_step: u8 = 0,
    master_vector_base: u8 = 0x20, // IRQ 0..7 -> 0x20..0x27
    slave_vector_base: u8 = 0x28, // IRQ 8..15 -> 0x28..0x2F

    pub fn reset(self: *VmPicState) void {
        self.* = .{};
    }
};

pub const VmPitState = struct {
    channel0_reload: u16 = 0,
    channel0_mode: u8 = 0,
    write_lsb_next: bool = true,
    reload_low: u8 = 0,
    configured: bool = false,
    timer_irq_pending: bool = false,

    pub fn reset(self: *VmPitState) void {
        self.* = .{};
    }
};

pub const LAPIC_REG_WORDS: usize = 0x1000 / 4; // 1024 words = 4096 bytes

pub const VmLapicState = struct {
    guest_apic_base: u64 = 0x0000_0000_FEE0_0900,
    nmi_pending: bool = false,
    regs: [LAPIC_REG_WORDS]u32 = @splat(0),

    pub fn reset(self: *VmLapicState) void {
        self.guest_apic_base = 0x0000_0000_FEE0_0900;
        self.nmi_pending = false;
        @memset(&self.regs, 0);
    }
};

pub const VmUartState = struct {
    dll: u8 = 0x01,
    dlm: u8 = 0x00,
    ier: u8 = 0,
    fcr: u8 = 0,
    lcr: u8 = 0x03,
    mcr: u8 = 0,
    scr: u8 = 0,
    irq4_pending: bool = false,
    rx_buf: [256]u8 = undefined,
    rx_head: u8 = 0,
    rx_tail: u8 = 0,
    rx_count: u16 = 0,
    tx_buf: [4096]u8 = undefined,
    tx_len: usize = 0,

    pub fn reset(self: *VmUartState) void {
        self.dll = 0x01;
        self.dlm = 0x00;
        self.ier = 0;
        self.fcr = 0;
        self.lcr = 0x03;
        self.mcr = 0;
        self.scr = 0;
        self.irq4_pending = false;
        self.rx_head = 0;
        self.rx_tail = 0;
        self.rx_count = 0;
        self.tx_len = 0;
    }

    pub fn writeTxByte(self: *VmUartState, ch: u8) void {
        if (self.tx_len < self.tx_buf.len) {
            self.tx_buf[self.tx_len] = ch;
            self.tx_len += 1;
        } else {
            // Scrollback circular slide (use copyForwards for overlapping slice)
            std.mem.copyForwards(u8, self.tx_buf[0 .. self.tx_buf.len - 1], self.tx_buf[1..self.tx_buf.len]);
            self.tx_buf[self.tx_buf.len - 1] = ch;
        }
    }

    pub fn writeTxSlice(self: *VmUartState, bytes: []const u8) void {
        for (bytes) |b| self.writeTxByte(b);
    }

    pub fn readTxLog(self: *const VmUartState, out: []u8) usize {
        const to_copy = @min(self.tx_len, out.len);
        @memcpy(out[0..to_copy], self.tx_buf[0..to_copy]);
        return to_copy;
    }

    pub fn injectRxByte(self: *VmUartState, ch: u8) bool {
        if (self.rx_count >= 256) return false;
        self.rx_buf[@as(usize, self.rx_tail)] = ch;
        self.rx_tail +%= 1;
        self.rx_count += 1;
        self.irq4_pending = true;
        return true;
    }

    pub fn readRxByte(self: *VmUartState) ?u8 {
        if (self.rx_count == 0) return null;
        const ch = self.rx_buf[@as(usize, self.rx_head)];
        self.rx_head +%= 1;
        self.rx_count -= 1;
        if (self.rx_count == 0) {
            self.irq4_pending = false;
        }
        return ch;
    }

    pub fn isRxEmpty(self: *const VmUartState) bool {
        return self.rx_count == 0;
    }
};

pub const VmPciState = struct {
    config_address: u32 = 0,
    root_command: u16 = 0,

    pub fn reset(self: *VmPciState) void {
        self.* = .{};
    }
};

pub const VmMiscState = struct {
    port_61_value: u8 = 0,
    port_61_reads: u32 = 0,
    preemption_timer_active: bool = false,
    timer_inject_count: u64 = 0,
    timer_exit_count: u64 = 0,

    pub fn reset(self: *VmMiscState) void {
        self.* = .{};
    }
};

pub const VirtualDeviceState = struct {
    pic: VmPicState = .{},
    pit: VmPitState = .{},
    lapic: VmLapicState = .{},
    uart: VmUartState = .{},
    pci: VmPciState = .{},
    misc: VmMiscState = .{},

    pub fn reset(self: *VirtualDeviceState) void {
        self.pic.reset();
        self.pit.reset();
        self.lapic.reset();
        self.uart.reset();
        self.pci.reset();
        self.misc.reset();
    }
};

// ---------------------------------------------------------------------------
// Instance Struct
// ---------------------------------------------------------------------------

pub const Instance = struct {
    in_use: bool = false,
    instance_id: u32 = 0,
    state: MicrovmState = .empty,
    name: [32]u8 = @splat(0),
    container: [32]u8 = @splat(0),
    /// Guest RAM size in 4 KiB pages (e.g. 16384 = 64 MiB).
    mem_pages: u32 = 0,
    vcpus: u32 = 1,
    /// Bound SMP core affinity (null = unpinned, 0 = BSP, 1 = AP 1, etc.)
    pinned_cpu: ?u8 = null,
    kernel_phys: u64 = 0,
    kernel_size: u64 = 0,
    initramfs_phys: u64 = 0,
    initramfs_size: u64 = 0,
    vmcs_phys: ?u64 = null,
    ept_pml4_phys: ?u64 = null,
    /// Host-physical address of the guest-specific page pool.
    pool_phys: ?u64 = null,
    pool_used: u64 = 0,
    /// CPU cycles consumed by this VM (tracked on VM-exit)
    cpu_cycles: u64 = 0,
    /// Number of VM-exits triggered by this instance
    exit_count: u64 = 0,
    /// Linux 64-bit boot protocol RSI parameter (pointer to struct boot_params GPA)
    launch_rsi: u64 = 0,
    /// Per-instance emulated device registers
    devices: VirtualDeviceState = .{},

    pub fn reset(self: *Instance) void {
        self.in_use = false;
        self.instance_id = 0;
        self.state = .empty;
        @memset(&self.name, 0);
        @memset(&self.container, 0);
        self.mem_pages = 0;
        self.vcpus = 1;
        self.pinned_cpu = null;
        self.kernel_phys = 0;
        self.kernel_size = 0;
        self.initramfs_phys = 0;
        self.initramfs_size = 0;
        self.vmcs_phys = null;
        self.ept_pml4_phys = null;
        self.pool_phys = null;
        self.pool_used = 0;
        self.cpu_cycles = 0;
        self.exit_count = 0;
        self.launch_rsi = 0;
        self.devices.reset();
    }
};

// ---------------------------------------------------------------------------
// Storage & Spinlock Synchronization
// ---------------------------------------------------------------------------

var instances_storage: [MIN_INSTANCES]Instance = undefined;
var instances: []Instance = instances_storage[0..];
var next_instance_id: u32 = 1;
var initialized: bool = false;
var registry_lock: bool = false;

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
    while (@atomicRmw(bool, &registry_lock, .Xchg, true, .seq_cst)) {
        if (!builtin.is_test and comptime builtin.cpu.arch == .x86_64) {
            asm volatile ("pause");
        } else {
            std.atomic.spinLoopHint();
        }
    }
    return flags;
}

fn releaseLock(flags: u64) void {
    @atomicStore(bool, &registry_lock, false, .seq_cst);
    if (!builtin.is_test and comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\pushq %[flags]
            \\popfq
            :
            : [flags] "r" (flags),
        );
    }
}

pub fn lock() u64 {
    return acquireLock();
}

pub fn unlock(flags: u64) void {
    releaseLock(flags);
}

// ---------------------------------------------------------------------------
// Public Registry Operations
// ---------------------------------------------------------------------------

pub fn init() void {
    const flags = acquireLock();
    defer releaseLock(flags);
    instances = instances_storage[0..];
    for (instances) |*slot| slot.reset();
    next_instance_id = 1;
    initialized = true;
}

pub fn initWithCapacityHint(hhdm_offset: u64, target_instances: usize) void {
    _ = hhdm_offset;
    _ = target_instances;
    init();
}

fn ensureInit() void {
    if (!initialized) init();
}

fn findMutableInternal(instance_id: u32) ?*Instance {
    for (0..instances.len) |i| {
        if (instances[i].in_use and instances[i].instance_id == instance_id)
            return &instances[i];
    }
    return null;
}

pub fn findMutable(instance_id: u32) ?*Instance {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    return findMutableInternal(instance_id);
}

/// Allocate a new MicroVM slot with default unpinned affinity.
pub fn create(name: [32]u8, container: [32]u8, mem_pages: u32, vcpus: u32, kernel_phys: u64, kernel_size: u64, initramfs_phys: u64, initramfs_size: u64) ?u32 {
    return createWithAffinity(name, container, mem_pages, vcpus, kernel_phys, kernel_size, initramfs_phys, initramfs_size, null);
}

/// Allocate a new MicroVM slot with explicit core affinity.
pub fn createWithAffinity(name: [32]u8, container: [32]u8, mem_pages: u32, vcpus: u32, kernel_phys: u64, kernel_size: u64, initramfs_phys: u64, initramfs_size: u64, pinned_cpu: ?u8) ?u32 {
    if (vcpus != 1) return null;

    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);

    for (0..instances.len) |i| {
        if (!instances[i].in_use) {
            const id = next_instance_id;
            next_instance_id += 1;
            const slot = &instances[i];
            slot.reset();
            slot.in_use = true;
            slot.instance_id = id;
            slot.state = .created;
            slot.name = name;
            slot.container = container;
            slot.mem_pages = mem_pages;
            slot.vcpus = vcpus;
            slot.pinned_cpu = pinned_cpu;
            slot.kernel_phys = kernel_phys;
            slot.kernel_size = kernel_size;
            slot.initramfs_phys = initramfs_phys;
            slot.initramfs_size = initramfs_size;
            return id;
        }
    }
    return null;
}

pub fn setPinnedCpu(instance_id: u32, pinned_cpu: ?u8) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;
    slot.pinned_cpu = pinned_cpu;
    return true;
}

/// Transition a created or stopped instance to running.
pub fn start(instance_id: u32) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;
    if (slot.state != .created and slot.state != .stopped) return false;
    slot.state = .running;
    return true;
}

fn requestStopState(state: *MicrovmState) bool {
    if (state.* != .running) return false;
    state.* = .stopping;
    return true;
}

/// Request that a running instance stop at a VM-exit state check.
pub fn stop(instance_id: u32) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;
    return requestStopState(&slot.state);
}

fn completeStopState(state: *MicrovmState) bool {
    if (state.* != .stopping) return false;
    state.* = .stopped;
    return true;
}

/// Complete a stop request after the VMX exit path has left guest execution.
pub fn completeStop(instance_id: u32) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;
    return completeStopState(&slot.state);
}

pub fn fail(instance_id: u32) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;
    if (slot.state != .created and slot.state != .running and slot.state != .stopping) return false;
    slot.state = .failed;
    return true;
}

fn canDeleteState(state: MicrovmState) bool {
    return state != .running and state != .stopping;
}

fn canDeleteInstance(instance: *const Instance) bool {
    return canDeleteState(instance.state) and
        instance.vmcs_phys == null and
        instance.ept_pml4_phys == null and
        instance.pool_phys == null and
        instance.pool_used == 0;
}

/// Release a stopped (or created) instance slot.
pub fn delete(instance_id: u32) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;
    if (!canDeleteInstance(slot)) return false;
    slot.reset();
    return true;
}

pub fn getInstances() []const Instance {
    ensureInit();
    return instances;
}

/// Read-only reference to a slot by instance_id.
pub fn lookup(instance_id: u32) ?*const Instance {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    return findMutableInternal(instance_id);
}

pub fn isRunning(instance_id: u32) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;
    return slot.state == .running;
}

pub fn capacity() usize {
    ensureInit();
    return instances.len;
}

test "stop request waits for VMX exit before deletion" {
    var state: MicrovmState = .running;
    try std.testing.expect(requestStopState(&state));
    try std.testing.expectEqual(MicrovmState.stopping, state);
    try std.testing.expect(!canDeleteState(state));
    try std.testing.expect(!requestStopState(&state));
    try std.testing.expect(completeStopState(&state));
    try std.testing.expectEqual(MicrovmState.stopped, state);
    try std.testing.expect(canDeleteState(state));
    state = .running;
    try std.testing.expect(requestStopState(&state));
    state = .failed;
    try std.testing.expect(canDeleteState(state));
}

test "registry refuses deletion while VM-owned pages or VMCS remain" {
    init();
    const name: [32]u8 = @splat(0);
    const container: [32]u8 = @splat(0);
    const id = create(name, container, 1, 1, 0, 0, 0, 0) orelse return error.TestUnexpectedResult;
    const instance = findMutable(id) orelse return error.TestUnexpectedResult;

    instance.state = .stopped;
    instance.ept_pml4_phys = 0x1000;
    try std.testing.expect(!delete(id));
    try std.testing.expect(lookup(id) != null);

    instance.ept_pml4_phys = null;
    instance.vmcs_phys = 0x2000;
    try std.testing.expect(!delete(id));

    instance.vmcs_phys = null;
    instance.pool_used = 1;
    try std.testing.expect(!delete(id));

    instance.pool_used = 0;
    try std.testing.expect(delete(id));
    try std.testing.expect(lookup(id) == null);
}

test "registry rejects unsupported multi-vCPU requests without consuming an ID" {
    init();
    const name: [32]u8 = @splat(0);
    const container: [32]u8 = @splat(0);
    try std.testing.expect(create(name, container, 1, 2, 0, 0, 0, 0) == null);

    const id = create(name, container, 1, 1, 0, 0, 0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expectEqual(@as(u32, 1), lookup(id).?.vcpus);
    try std.testing.expect(delete(id));
}

// ---------------------------------------------------------------------------
// Console Syscall ABI Helpers (Ops 28 & 29)
// ---------------------------------------------------------------------------

/// Copies the circular console output log into dest buffer. Returns bytes copied.
pub fn getConsoleLog(instance_id: u32, out: []u8) usize {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return 0;
    return slot.devices.uart.readTxLog(out);
}

/// Injects a raw ASCII keystroke into the guest's 256-byte RX FIFO.
pub fn injectConsoleInput(instance_id: u32, ch: u8) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;
    return slot.devices.uart.injectRxByte(ch);
}

pub fn hasConsoleInput(instance_id: u32) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;
    return !slot.devices.uart.isRxEmpty();
}

pub fn readConsoleInput(instance_id: u32) ?u8 {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return null;
    return slot.devices.uart.readRxByte();
}

pub fn configureConsoleUartInterrupt(instance_id: u32, ier: u8, irq4_unmasked: bool) void {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return;

    const rx_non_empty = !slot.devices.uart.isRxEmpty();
    const rda_active = (ier & 0x01) != 0 and rx_non_empty;
    const thre_active = (ier & 0x02) != 0;
    slot.devices.uart.ier = ier;
    if ((rda_active or thre_active) and irq4_unmasked) {
        slot.devices.uart.irq4_pending = true;
    } else if (!rda_active and !thre_active) {
        slot.devices.uart.irq4_pending = false;
    }
}

pub fn consoleUartInterruptPending(instance_id: u32, acknowledge: bool) bool {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return false;

    const pending = slot.devices.uart.irq4_pending or
        (!slot.devices.uart.isRxEmpty() and (slot.devices.uart.ier & 0x01) != 0);
    if (pending and acknowledge) slot.devices.uart.irq4_pending = false;
    return pending;
}

/// Appends a raw ASCII character to the guest's console TX log under registry lock.
pub fn writeConsoleByte(instance_id: u32, ch: u8) void {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return;
    slot.devices.uart.writeTxByte(ch);
}

/// Direct pointer access to an instance's devices for the VMX core.
pub fn getDevices(instance_id: u32) ?*VirtualDeviceState {
    ensureInit();
    const flags = acquireLock();
    defer releaseLock(flags);
    const slot = findMutableInternal(instance_id) orelse return null;
    return &slot.devices;
}
