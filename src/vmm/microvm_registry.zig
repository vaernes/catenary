// VMM MicroVM instance registry.
//
// Ring 0 tracks VMCS allocation state and MicroVM lifecycle for the VMX subsystem.
// The OCI control plane that issues create/start/stop/delete is a Ring-3
// responsibility; this module is the kernel-side table that validates state
// transitions and tracks hardware resource ownership.
//
// Ownership rule: instance_id is the stable identifier issued at create time
// and released at delete time.  No external entity may re-use a slot until
// `delete` is called successfully.

const pmm = @import("../kernel/pmm.zig");

pub const MIN_INSTANCES: usize = 8;
pub const TARGET_INSTANCES: usize = 64;

pub const MicrovmState = enum(u8) {
    empty = 0,
    created = 1,
    running = 2,
    stopped = 3,
    deleted = 4,
};

pub const Instance = struct {
    in_use: bool = false,
    instance_id: u32 = 0,
    state: MicrovmState = .empty,
    /// Guest RAM size in 4 KiB pages (e.g. 16384 = 64 MiB).
    mem_pages: u32 = 0,
    vcpus: u32 = 1,
    kernel_phys: u64 = 0,
    kernel_size: u64 = 0,
    initramfs_phys: u64 = 0,
    initramfs_size: u64 = 0,
    vmcs_phys: ?u64 = null,
    ept_pml4_phys: ?u64 = null,
    /// Host-physical address of the guest-specific page pool.
    pool_phys: ?u64 = null,
    pool_used: u32 = 0,
    /// CPU cycles consumed by this VM (tracked on VM-exit)
    cpu_cycles: u64 = 0,
    /// Number of VM-exits triggered by this instance
    exit_count: u64 = 0,
};

var instances_fallback: [MIN_INSTANCES]Instance = undefined;
var instances: []Instance = instances_fallback[0..];
var registry_page_phys: ?u64 = null;
var next_instance_id: u32 = 1;
var initialized: bool = false;

pub fn init() void {
    instances = instances_fallback[0..];
    for (instances) |*slot| slot.* = .{};
    next_instance_id = 1;
    initialized = true;
}

pub fn initWithCapacityHint(hhdm_offset: u64, target_instances: usize) void {
    const target = if (target_instances < MIN_INSTANCES) MIN_INSTANCES else target_instances;
    _ = target;

    if (registry_page_phys == null) {
        registry_page_phys = pmm.allocPage();
    }

    if (registry_page_phys) |phys| {
        const cap = pmm.PAGE_SIZE / @sizeOf(Instance);
        if (cap >= MIN_INSTANCES) {
            const base: [*]Instance = @ptrFromInt(phys + hhdm_offset);
            instances = base[0..cap];
        } else {
            instances = instances_fallback[0..];
        }
    } else {
        instances = instances_fallback[0..];
    }

    for (instances) |*slot| slot.* = .{};
    next_instance_id = 1;
    initialized = true;
}

fn ensureInit() void {
    if (!initialized) init();
}

pub fn findMutable(instance_id: u32) ?*Instance {
    for (0..instances.len) |i| {
        if (instances[i].in_use and instances[i].instance_id == instance_id)
            return &instances[i];
    }
    return null;
}

/// Allocate a new MicroVM slot.  Returns the stable instance_id or null if the
/// table is full.
pub fn create(mem_pages: u32, vcpus: u32, kernel_phys: u64, kernel_size: u64, initramfs_phys: u64, initramfs_size: u64) ?u32 {
    ensureInit();
    for (0..instances.len) |i| {
        if (!instances[i].in_use) {
            const id = next_instance_id;
            next_instance_id += 1;
            instances[i] = .{
                .in_use = true,
                .instance_id = id,
                .state = .created,
                .mem_pages = mem_pages,
                .vcpus = vcpus,
                .kernel_phys = kernel_phys,
                .kernel_size = kernel_size,
                .initramfs_phys = initramfs_phys,
                .initramfs_size = initramfs_size,
            };
            return id;
        }
    }
    return null;
}

/// Transition a created instance to running.  Returns false if the instance
/// does not exist or is not in the `created` state.
pub fn start(instance_id: u32) bool {
    ensureInit();
    const slot = findMutable(instance_id) orelse return false;
    if (slot.state != .created) return false;
    slot.state = .running;
    return true;
}

/// Transition a running instance to stopped.  Returns false if the instance
/// is not in the `running` state.
pub fn stop(instance_id: u32) bool {
    ensureInit();
    const slot = findMutable(instance_id) orelse return false;
    if (slot.state != .running) return false;
    slot.state = .stopped;
    return true;
}

/// Release a stopped (or created) instance slot.  Returns false if the
/// instance is still running.
pub fn delete(instance_id: u32) bool {
    ensureInit();
    const slot = findMutable(instance_id) orelse return false;
    if (slot.state == .running) return false;
    slot.* = .{};
    return true;
}

/// Read-only snapshot of a slot by instance_id.
pub fn lookup(instance_id: u32) ?Instance {
    ensureInit();
    for (instances) |slot| {
        if (slot.in_use and slot.instance_id == instance_id) return slot;
    }
    return null;
}

pub fn capacity() usize {
    ensureInit();
    return instances.len;
}
