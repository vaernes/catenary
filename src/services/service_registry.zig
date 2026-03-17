const std = @import("std");
const service_bootstrap = @import("service_bootstrap.zig");
const trust = @import("../kernel/trust.zig");

pub const MAX_SERVICES: usize = 8;

pub const ServiceState = enum(u8) {
    empty = 0,
    reserved = 1,
    launched = 2,
    registered = 3,
    active = 4,
    exited = 5,
    faulted = 6,
};

pub const Slot = struct {
    in_use: bool = false,
    service_id: u32 = 0,
    class: service_bootstrap.ProcessClass = .user_service,
    kind: service_bootstrap.ServiceKind = .netd,
    runtime_mode: service_bootstrap.RuntimeMode = .oneshot,
    state: ServiceState = .empty,
    entry_rip: u64 = 0,
    stack_top: u64 = 0,
    bootstrap_page_phys: u64 = 0,
    capability_token: u64 = 0,
    capability_revoked: bool = false,
    last_exit_code: u64 = 0,
    last_fault_code: u64 = 0,
    last_fault_addr: u64 = 0,
    heartbeat_count: u64 = 0,
    pml4_phys: u64 = 0,
    /// Physical address of the DIPC page currently mapped at the service's
    /// receive window VA (0x7F00_0000_0000). Cleared when the page is freed.
    receive_page_phys: u64 = 0,
};

var slots: [MAX_SERVICES]Slot = undefined;
var next_service_id: u32 = 1;
var initialized: bool = false;
var capability_secret: u64 = 0;
var capability_nonce: u64 = 1;

const MANIFEST_MAGIC: u64 = 0x4341544D414E4946;

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        asm volatile ("outb %al, %dx"
            :
            : [al] "{al}" (c),
              [dx] "{dx}" (@as(u16, 0x3F8)),
        );
    }
}

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        serialWrite(hex[nibble..][0..1]);
        if (shift == 0) break;
        shift -= 4;
    }
}

fn refreshCapabilitySecret() void {
    if (trust.global_manifest_ptr.magic == MANIFEST_MAGIC) {
        const manifest = trust.global_manifest_ptr.*;
        capability_secret = manifest.capability_seed ^ 0xA53C_9E17_DF42_B68D;
        return;
    }

    if (capability_secret == 0) {
        capability_secret = 0x93A6_1CF2_B47D_E905;
    }
}

fn mix64(x0: u64) u64 {
    var x = x0;
    x ^= x >> 30;
    x *%= 0xBF58_476D_1CE4_E5B9;
    x ^= x >> 27;
    x *%= 0x94D0_49BB_1331_11EB;
    x ^= x >> 31;
    return x;
}

fn deriveCapabilityToken(service_id: u32) u64 {
    const base = capability_secret ^ (@as(u64, service_id) << 32) ^ capability_nonce;
    var token = mix64(base);
    if (token == 0) token = 1;
    return token;
}

pub fn init() void {
    refreshCapabilitySecret();
    for (0..MAX_SERVICES) |i| slots[i] = Slot{};
    next_service_id = 1;
    capability_nonce = 1;
    initialized = true;
}

fn ensureInit() void {
    if (!initialized) init();
}

pub fn reserve(kind: service_bootstrap.ServiceKind) ?u32 {
    const allocation = reserveWithToken(kind) orelse return null;
    return allocation.service_id;
}

pub fn reserveWithToken(
    kind: service_bootstrap.ServiceKind,
) ?struct { service_id: u32, capability_token: u64 } {
    ensureInit();
    refreshCapabilitySecret();
    for (0..MAX_SERVICES) |i| {
        if (!slots[i].in_use) {
            const service_id = next_service_id;
            const token = deriveCapabilityToken(service_id);
            next_service_id += 1;
            capability_nonce += 1;
            slots[i] = Slot{
                .in_use = true,
                .service_id = service_id,
                .kind = kind,
                .state = .reserved,
                .capability_token = token,
                .capability_revoked = false,
            };
            return .{ .service_id = service_id, .capability_token = token };
        }
    }
    return null;
}

pub fn getCapabilityToken(service_id: u32) u64 {
    ensureInit();
    for (0..MAX_SERVICES) |i| {
        const slot = slots[i];
        if (slot.in_use and slot.service_id == service_id) return slot.capability_token;
    }
    return 0;
}

pub fn verifyCapability(service_id: u32, token: u64) bool {
    if (token == 0) return false;
    ensureInit();
    for (0..MAX_SERVICES) |i| {
        const slot = slots[i];
        if (slot.in_use and slot.service_id == service_id) {
            return (!slot.capability_revoked and slot.capability_token == token);
        }
    }
    return false;
}

pub fn serviceIdForCapability(token: u64) ?u32 {
    if (token == 0) return null;
    ensureInit();
    for (0..MAX_SERVICES) |i| {
        const slot = slots[i];
        if (slot.in_use and !slot.capability_revoked and slot.capability_token == token) return slot.service_id;
    }
    return null;
}

pub fn revokeCapability(service_id: u32) bool {
    ensureInit();
    const slot = findMutable(service_id) orelse return false;
    slot.capability_revoked = true;
    return true;
}

pub fn rotateCapability(service_id: u32) ?u64 {
    ensureInit();
    refreshCapabilitySecret();
    const slot = findMutable(service_id) orelse return null;
    capability_nonce += 1;
    slot.capability_token = deriveCapabilityToken(service_id);
    slot.capability_revoked = false;
    return slot.capability_token;
}

pub fn ensureService(kind: service_bootstrap.ServiceKind) ?u32 {
    ensureInit();
    for (0..MAX_SERVICES) |i| {
        const slot = slots[i];
        if (slot.in_use and slot.kind == kind) return slot.service_id;
    }
    return reserve(kind);
}

pub fn bindLaunch(
    service_id: u32,
    runtime_mode: service_bootstrap.RuntimeMode,
    entry_rip: u64,
    stack_top: u64,
    pml4_phys: u64,
    bootstrap_page_phys: u64,
) bool {
    ensureInit();
    const slot = findMutable(service_id) orelse return false;
    slot.runtime_mode = runtime_mode;
    slot.entry_rip = entry_rip;
    slot.stack_top = stack_top;
    slot.pml4_phys = pml4_phys;
    slot.bootstrap_page_phys = bootstrap_page_phys;
    slot.last_exit_code = 0;
    slot.last_fault_code = 0;
    slot.last_fault_addr = 0;
    slot.state = .launched;
    return true;
}

pub fn getTaskBoundAddressSpace(service_id: u32) ?u64 {
    ensureInit();
    for (0..MAX_SERVICES) |i| {
        const slot = slots[i];
        if (slot.in_use and slot.service_id == service_id) return slot.pml4_phys;
    }
    return null;
}

pub fn markRegistered(service_id: u32) bool {
    ensureInit();
    const slot = findMutable(service_id) orelse return false;
    slot.state = .registered;
    return true;
}

pub fn markHeartbeat(service_id: u32) bool {
    ensureInit();
    const slot = findMutable(service_id) orelse return false;
    slot.heartbeat_count += 1;
    return true;
}

pub fn markExited(service_id: u32, exit_code: u64) bool {
    ensureInit();
    const slot = findMutable(service_id) orelse return false;
    slot.last_exit_code = exit_code;
    slot.state = .exited;
    return true;
}

pub fn markFaulted(service_id: u32, fault_code: u64, fault_addr: u64) bool {
    ensureInit();
    const slot = findMutable(service_id) orelse return false;
    slot.last_fault_code = fault_code;
    slot.last_fault_addr = fault_addr;
    slot.state = .faulted;
    return true;
}

pub fn lookup(service_id: u32) ?Slot {
    ensureInit();
    for (0..MAX_SERVICES) |i| {
        const slot = slots[i];
        if (slot.in_use and slot.service_id == service_id) return slot;
    }
    return null;
}

fn findMutable(service_id: u32) ?*Slot {
    for (0..MAX_SERVICES) |i| {
        if (slots[i].in_use and slots[i].service_id == service_id) return &slots[i];
    }
    return null;
}
pub fn getServiceKind(service_id: u32) ?service_bootstrap.ServiceKind {
    ensureInit();
    for (0..MAX_SERVICES) |i| {
        const slot = slots[i];
        if (slot.in_use and slot.service_id == service_id) return slot.kind;
    }
    return null;
}

pub fn updateServiceState(service_id: u32, state: ServiceState) bool {
    ensureInit();
    const slot = findMutable(service_id) orelse return false;
    slot.state = state;
    return true;
}

pub fn getLaunchDescriptor(service_id: u32) ?struct {
    entry_rip: u64,
    stack_top: u64,
    bootstrap_page_phys: u64,
} {
    ensureInit();
    for (0..MAX_SERVICES) |i| {
        const slot = slots[i];
        if (slot.in_use and slot.service_id == service_id) {
            return .{
                .entry_rip = slot.entry_rip,
                .stack_top = slot.stack_top,
                .bootstrap_page_phys = slot.bootstrap_page_phys,
            };
        }
    }
    return null;
}
pub fn setRecvPage(service_id: u32, phys: u64) void {
    const slot = findMutable(service_id) orelse return;
    slot.receive_page_phys = phys;
}

/// Clears the stored recv page phys and returns the old value (0 if none).
pub fn clearRecvPage(service_id: u32) u64 {
    const slot = findMutable(service_id) orelse return 0;
    const old = slot.receive_page_phys;
    slot.receive_page_phys = 0;
    return old;
}

/// Return the slot at index `i` (0 … MAX_SERVICES-1) by value, or null if
/// the index is out of range. The shell and diagnostics code uses this to
/// iterate all slots without exposing the raw array.
pub fn getSlotByIndex(i: usize) ?Slot {
    if (i >= MAX_SERVICES) return null;
    return slots[i];
}
