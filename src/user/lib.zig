const std = @import("std");
const builtin = @import("builtin");

// Protocol modules — canonical per-service message definitions.
const storaged_proto = @import("protocols/storaged_protocol.zig");
const dashd_proto = @import("protocols/dashd_protocol.zig");
const configd_proto = @import("protocols/configd_protocol.zig");
const inputd_proto = @import("protocols/inputd_protocol.zig");

pub fn ptrFrom(comptime T: type, addr: u64) T {
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => {
            return @ptrFromInt(asm volatile (""
                : [ret] "={rax}" (-> u64),
                : [val] "{rax}" (addr),
            ));
        },
        else => @compileError("Unsupported architecture"),
    }
}

pub fn syscall(op: u64, arg0: u64, arg1: u64, token: u64) u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            return asm volatile ("int $0x80"
                : [ret] "={rax}" (-> u64),
                : [op] "{rax}" (op),
                  [arg0] "{rbx}" (arg0),
                  [arg1] "{rdx}" (arg1),
                  [token] "{r8}" (token),
                : .{ .rcx = true, .r11 = true, .memory = true });
        },
        .aarch64 => {
            return asm volatile ("svc #0"
                : [ret] "={x0}" (-> u64),
                : [op] "{x8}" (op),
                  [arg0] "{x0}" (arg0),
                  [arg1] "{x1}" (arg1),
                  [token] "{x2}" (token),
                : .{ .memory = true });
        },
        else => @compileError("Unsupported architecture"),
    }
}

// Syscall opcode constants — canonical definitions live in syscall_abi.zig.
// Re-exported here so user-space services only need to import lib.zig.
const abi = @import("syscall_abi");
pub const SYS_ACTIVATE = abi.SYS_ACTIVATE;
pub const SYS_REGISTER = abi.SYS_REGISTER;
pub const SYS_RECV = abi.SYS_RECV;
pub const SYS_FREE_PAGE = abi.SYS_FREE_PAGE;
pub const SYS_ALLOC_DMA = abi.SYS_ALLOC_DMA;
pub const SYS_SEND_PAGE = abi.SYS_SEND_PAGE;
pub const SYS_MAP_MMIO = abi.SYS_MAP_MMIO;
pub const SYS_GET_KEY = abi.SYS_GET_KEY;
pub const SYS_SERIAL_WRITE = abi.SYS_SERIAL_WRITE;
pub const SYS_FB_DRAW = abi.SYS_FB_DRAW;
pub const SYS_MAP_RECV = abi.SYS_MAP_RECV;
pub const SYS_FB_DRAW_COLORED = abi.SYS_FB_DRAW_COLORED;
pub const SYS_FB_FILL_RECT = abi.SYS_FB_FILL_RECT;
pub const SYS_TRY_RECV = abi.SYS_TRY_RECV;
pub const SYS_GET_VARDE_LOG = abi.SYS_GET_VARDE_LOG;
pub const SYS_PORT_IN = abi.SYS_PORT_IN;
pub const SYS_PORT_OUT = abi.SYS_PORT_OUT;
pub const SYS_YIELD = abi.SYS_YIELD;
pub const SYS_VARDE_INJECT = abi.SYS_VARDE_INJECT;
pub const SYS_FB_GET_INFO = abi.SYS_FB_GET_INFO;
pub const SYS_PCI_READ_CONFIG = abi.SYS_PCI_READ_CONFIG;
pub const SYS_PCI_WRITE_CONFIG = abi.SYS_PCI_WRITE_CONFIG;
pub const SYS_SPAWN_THREAD = abi.SYS_SPAWN_THREAD;

pub const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
pub const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;
pub const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;
pub const USER_CONFIG_VADDR: usize = USER_BOOTSTRAP_VADDR - (64 * PAGE_SIZE);
pub const PAGE_SIZE: u64 = 4096;

// Mirror of identity.ReservedEndpoint for user-space use.
pub const ReservedEndpoint = enum(u64) {
    netd = 1,
    kernel_control = 2,
    router = 3,
    storaged = 4,
    dashd = 5,
    containerd = 6,
    clusterd = 7,
    inputd = 8,
    windowd = 9,
    configd = 10,
};

pub const ServiceKind = enum(u16) {
    netd = 1,
    vmm = 2,
    storaged = 3,
    dashd = 4,
    containerd = 5,
    clusterd = 6,
    inputd = 7,
    windowd = 8,
    configd = 9,
};

pub const BootstrapDescriptor = extern struct {
    magic: u32,
    version: u16,
    descriptor_len: u16,
    class: u16,
    service_kind: u16,
    runtime_mode: u16,
    _r0: u16,
    service_id: u32,
    user_id: u32,
    flags: u32,
    persistent_trap_vector: u8,
    _r1: u8,
    persistent_heartbeat_op: u16,
    persistent_stop_op: u16,
    _r2: u16,
    local_node: [16]u8,

    dipc_wire_magic: u32,
    dipc_wire_version: u16,
    dipc_header_len: u16,
    dipc_max_payload: u32,
    reserved_netd_endpoint: u64,
    reserved_kernel_control_endpoint: u64,
    reserved_router_endpoint: u64,
    reserved_storaged_endpoint: u64,
    reserved_dashd_endpoint: u64,
    reserved_containerd_endpoint: u64,
    reserved_clusterd_endpoint: u64,
    reserved_inputd_endpoint: u64,
    reserved_windowd_endpoint: u64,
    reserved_configd_endpoint: u64,
    microvm_ingress_magic: u32,
    microvm_ingress_version: u16,
    microvm_ingress_len: u16,
    capability_token: u64,
    config_size: u64,
    linux_bzimage_phys: u64,
    linux_bzimage_size: u64,
    initramfs_phys: u64,
    initramfs_size: u64,
};

pub fn outb(port: u16, val: u8) void {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            asm volatile ("outb %[val], %[port]"
                :
                : [val] "{al}" (val),
                  [port] "{dx}" (port),
                : .{ .memory = true });
        },
        .aarch64 => {
            // Memory mapped IO on AArch64 or ignore
        },
        else => @compileError("Unsupported architecture"),
    }
}

pub fn serialWrite(s: []const u8) void {
    _ = syscall(SYS_SERIAL_WRITE, @intFromPtr(s.ptr), s.len, 0);
}

/// Spawn an additional Ring-3 thread for this service in the same address space.
/// `entry_fn` must be `noreturn`; it starts with no arguments (arg0 from the
/// kernel is 0 for extra threads, not a bootstrap-page address).
/// `stack_top` is the exclusive top of the thread's stack (16-byte aligned).
/// `token` is the caller's capability token.
/// Returns the kernel thread ID on success, 0xFFFFFFFF on failure.
pub fn spawnThread(entry_fn: *const fn () noreturn, stack_top: u64, token: u64) u64 {
    return syscall(SYS_SPAWN_THREAD, @intFromPtr(entry_fn), stack_top, token);
}

pub fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        const c = hex[nibble];
        _ = syscall(SYS_SERIAL_WRITE, @intFromPtr(&c), 1, 0);
        if (shift == 0) break;
        shift -= 4;
    }
}

pub const Ipv6Addr = extern struct {
    bytes: [16]u8,
    pub fn loopback() Ipv6Addr {
        var out: Ipv6Addr = .{ .bytes = [_]u8{0} ** 16 };
        out.bytes[15] = 1;
        return out;
    }
};

pub const EndpointId = u64;

pub const Address = extern struct {
    node: Ipv6Addr,
    endpoint: EndpointId,
};

pub const WireVersion: u16 = 1;
pub const WireMagic: u32 = 0x44495043; // 'DIPC'

pub const PageHeader = extern struct {
    magic: u32,
    version: u16,
    header_len: u16,
    payload_len: u32,
    auth_tag: u64,
    src: Address,
    dst: Address,
};

pub const DIPC_HEADER_SIZE: usize = @sizeOf(PageHeader);

pub const ControlOp = enum(u16) {
    register_netd = 1,
    set_node_addr = 2,
    register_netd_service = 3,
    poll_netd_inbox = 4,
    assign_node_addr = 5,
    create_microvm = 6,
    start_microvm = 7,
    stop_microvm = 8,
    delete_microvm = 9,
    revoke_node_addr = 10,
    register_storaged_service = 11,
    register_telemetry = 12,
    pci_read_config = 13,
    pci_write_config = 14,
    phys_alloc = 15,
    phys_free = 16,
    virtio_blk_response = 17,
    registry_sync = 18,
    list_microvms = 19,
    get_node_status = 20,
    get_node_addr = 21,
};

pub const ControlHeader = extern struct {
    op: ControlOp,
    _reserved: u16 = 0,
    payload_len: u32,
};

pub const CONTROL_HEADER_SIZE: usize = @sizeOf(ControlHeader);

pub const SetNodeAddrPayload = extern struct {
    addr: Ipv6Addr,
};

pub const CreateMicrovmPayload = extern struct {
    mem_pages: u32,
    vcpus: u32,
    kernel_phys: u64,
    kernel_size: u64,
    initramfs_phys: u64,
    initramfs_size: u64,
    name: [32]u8,
    container: [32]u8,
};

pub const StartMicrovmPayload = extern struct {
    instance_id: u32,
    _reserved: u32 = 0,
};

pub const StopMicrovmPayload = extern struct {
    instance_id: u32,
    _reserved: u32 = 0,
};

pub const DeleteMicrovmPayload = extern struct {
    instance_id: u32,
    _reserved: u32 = 0,
};

pub const MicrovmInfo = extern struct {
    instance_id: u32,
    state: u32, // 0=empty, 1=created, 2=running, 3=stopped
    mem_pages: u32,
    vcpus: u32,
    name: [32]u8,
};

pub const ListMicrovmsResult = extern struct {
    count: u32,
    _pad: u32 = 0,
    vms: [64]MicrovmInfo,
};

pub const NodeStatusResult = extern struct {
    total_mem_pages: u32,
    free_mem_pages: u32,
    active_vms: u32,
    _pad: u32 = 0,
};

pub const NodeAddrResult = extern struct {
    addr: Ipv6Addr,
};

/// Per-VM telemetry update.  Re-exported from dashd_protocol.
pub const TelemetryUpdatePayload = dashd_proto.TelemetryUpdate;

/// Cluster node / service registry sync payload.  Re-exported from configd_protocol.
pub const RegistrySyncPayload = configd_proto.RegistrySyncPayload;
/// Canonical block I/O request type.  Re-exported from storaged_protocol.
pub const BlkRequest = storaged_proto.BlkRequest;

/// Block I/O completion.  Re-exported from storaged_protocol.
pub const BlkResponse = storaged_proto.BlkResponse;

pub const VirtioBlkResponsePayload = extern struct {
    vmid: u32,
    head_idx: u16,
    status: u8,
    _pad: u8 = 0,
};

// --- Interactive GUI protocol (mirrors control_protocol.zig) ---

pub const ListVmsRequest = extern struct {
    flags: u32 = 0,
    _pad: u32 = 0,
};

pub const VmSnapshotEntry = extern struct {
    instance_id: u32,
    state: u8,
    _pad: [3]u8 = [_]u8{0} ** 3,
    mem_pages: u32,
    vcpus: u32,
    cpu_cycles: u64,
    exit_count: u64,
    name: [32]u8,
    container: [32]u8,
};

pub const MAX_VM_SNAPSHOT_ENTRIES: usize = 32;

pub const VmSnapshotListPayload = extern struct {
    count: u32,
    _pad: u32 = 0,
    entries: [MAX_VM_SNAPSHOT_ENTRIES]VmSnapshotEntry =
        [_]VmSnapshotEntry{.{
            .instance_id = 0,
            .state = 0,
            .mem_pages = 0,
            .vcpus = 0,
            .cpu_cycles = 0,
            .exit_count = 0,
            .name = [_]u8{0} ** 32,
            .container = [_]u8{0} ** 32,
        }} ** MAX_VM_SNAPSHOT_ENTRIES,
};

pub const UpdateMicrovmNamePayload = extern struct {
    instance_id: u32,
    _pad: u32 = 0,
    name: [32]u8,
};

pub fn queryCurrentNode(
    bs: *const BootstrapDescriptor,
    token: u64,
    scratch_phys: u64,
    scratch_va: u64,
    src_endpoint: EndpointId,
) ?Ipv6Addr {
    if (scratch_phys == 0 or scratch_va == 0) return null;

    const bootstrap_node = Ipv6Addr{ .bytes = bs.local_node };
    const scratch: [*]u8 = ptrFrom([*]u8, scratch_va);

    const header: *align(1) PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = WireMagic,
        .version = WireVersion,
        .header_len = @as(u16, @intCast(DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(CONTROL_HEADER_SIZE)),
        .auth_tag = 0,
        .src = .{ .node = bootstrap_node, .endpoint = src_endpoint },
        .dst = .{ .node = bootstrap_node, .endpoint = bs.reserved_kernel_control_endpoint },
    };

    const control: *align(1) ControlHeader = @ptrFromInt(@intFromPtr(scratch) + DIPC_HEADER_SIZE);
    control.* = .{
        .op = .get_node_addr,
        .payload_len = 0,
    };

    if (syscall(SYS_SEND_PAGE, scratch_phys, 0, token) != 0) return null;

    const page_phys = syscall(SYS_RECV, 0, 0, token);
    if (page_phys == 0) return null;
    const recv_va = syscall(SYS_MAP_RECV, page_phys, 0, token);
    if (recv_va == 0) {
        _ = syscall(SYS_FREE_PAGE, page_phys, 0, token);
        return null;
    }

    const result: *align(1) const NodeAddrResult = @ptrFromInt(recv_va + DIPC_HEADER_SIZE);
    const addr = result.addr;
    _ = syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
    return addr;
}

pub extern fn umain() noreturn;

pub fn _user_start() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\andq $-16, %%rsp
            \\call %[umain]
            \\1: pause
            \\jmp 1b
            :
            : [umain] "X" (&umain),
        ),
        .aarch64 => asm volatile (
            \\bl %[umain]
            \\1: wfi
            \\b 1b
            :
            : [umain] "X" (&umain),
        ),
        else => @compileError("Unsupported architecture"),
    }
}

pub fn getFramebufferInfo() ?struct { width: u32, height: u32 } {
    const res = syscall(SYS_FB_GET_INFO, 0, 0, 0);
    if (res == 0 or res == 0xFFFFFFFF) return null;
    return .{
        .width = @as(u32, @truncate(res >> 32)),
        .height = @as(u32, @truncate(res & 0xFFFF_FFFF)),
    };
}

// --- TUI Helpers ---

pub fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u32, token: u64) void {
    const arg0 = (@as(u64, x) << 48) | (@as(u64, y) << 32) | (@as(u64, w) << 16) | @as(u64, h);
    _ = syscall(SYS_FB_FILL_RECT, arg0, color, token);
}

pub fn drawText(dma_phys: u64, dma_va: u64, row: u32, col: u32, fg: u32, text: []const u8, token: u64) void {
    const len = @min(text.len, 255);
    if (len == 0) return;
    const buf: [*]u8 = ptrFrom([*]u8, dma_va);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const arg1 = (@as(u64, row) << 48) | (@as(u64, col) << 32) | fg;
    _ = syscall(SYS_FB_DRAW_COLORED, dma_phys, arg1, token);
}

// --- DIPC Helpers ---

fn controlSourceEndpoint(bs: *const BootstrapDescriptor) EndpointId {
    return switch (bs.service_kind) {
        @intFromEnum(ServiceKind.netd) => bs.reserved_netd_endpoint,
        @intFromEnum(ServiceKind.storaged) => bs.reserved_storaged_endpoint,
        @intFromEnum(ServiceKind.dashd) => bs.reserved_dashd_endpoint,
        @intFromEnum(ServiceKind.containerd) => bs.reserved_containerd_endpoint,
        @intFromEnum(ServiceKind.clusterd) => bs.reserved_clusterd_endpoint,
        @intFromEnum(ServiceKind.inputd) => bs.reserved_inputd_endpoint,
        @intFromEnum(ServiceKind.windowd) => bs.reserved_windowd_endpoint,
        @intFromEnum(ServiceKind.configd) => bs.reserved_configd_endpoint,
        else => bs.service_id,
    };
}

pub fn sendControl(
    bs: *const BootstrapDescriptor,
    dma_phys: u64,
    dma_va: u64,
    token: u64,
    op: ControlOp,
    extra_payload: []const u8,
) void {
    const scratch: [*]u8 = ptrFrom([*]u8, dma_va);
    const local_node = Ipv6Addr{ .bytes = bs.local_node };

    const total_payload: u32 = @as(u32, @intCast(CONTROL_HEADER_SIZE + extra_payload.len));
    const head: *align(1) PageHeader = @ptrFromInt(@intFromPtr(scratch));
    head.* = .{
        .magic = WireMagic,
        .version = WireVersion,
        .header_len = @as(u16, @intCast(DIPC_HEADER_SIZE)),
        .payload_len = total_payload,
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = controlSourceEndpoint(bs) },
        .dst = .{ .node = local_node, .endpoint = @intFromEnum(ReservedEndpoint.kernel_control) },
    };
    const ctrl: *align(1) ControlHeader = @ptrFromInt(@intFromPtr(scratch) + DIPC_HEADER_SIZE);
    ctrl.* = .{ .op = op, .payload_len = @as(u32, @intCast(extra_payload.len)) };

    if (extra_payload.len > 0) {
        const dst: [*]u8 = @ptrFromInt(@intFromPtr(scratch) + DIPC_HEADER_SIZE + CONTROL_HEADER_SIZE);
        @memcpy(dst[0..extra_payload.len], extra_payload);
    }
    _ = syscall(SYS_SEND_PAGE, dma_phys, 0, token);
}

// --- Utility Helpers ---

pub fn formatU32(n: u32) [8]u8 {
    var buf: [8]u8 = [_]u8{' '} ** 8;
    if (n == 0) {
        buf[7] = '0';
        return buf;
    }
    var v = n;
    var i: usize = 8;
    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = @as(u8, @intCast(v % 10)) + '0';
        v /= 10;
    }
    return buf;
}

pub fn parseDecimal(bytes: []const u8) u32 {
    var val: u32 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') break;
        val = val * 10 + (c - '0');
    }
    return val;
}

pub fn nameLen(name: []const u8) usize {
    var l: usize = 0;
    while (l < name.len and name[l] != 0) : (l += 1) {}
    return l;
}
