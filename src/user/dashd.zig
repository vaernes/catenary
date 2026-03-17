/// dashd — system observability daemon.
///
/// Receives TelemetryUpdate DIPC messages from the VMM (microvm_bridge) and
/// renders per-VM stats onto the framebuffer via the SYS_FB_DRAW syscall.
const std = @import("std");

fn ptrFrom(comptime T: type, addr: u64) T {
    return @ptrFromInt(asm volatile ("" : [ret] "={rax}" (-> u64) : [val] "{rax}" (addr)));
}

// ---------------------------------------------------------------------------
// Syscall + serial helpers
// ---------------------------------------------------------------------------

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
        : .{ .memory = true });
}
fn serialWrite(s: []const u8) void {
    for (s) |c| outb(0x3F8, c);
}

fn syscall(op: u64, arg0: u64, arg1: u64, token: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [op] "{rax}" (op),
          [arg0] "{rbx}" (arg0),
          [arg1] "{rdx}" (arg1),
          [token] "{r8}" (token),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

const SYS_LOG = 1;
const SYS_REGISTER = 2;
const SYS_RECV = 3;
const SYS_FREE_PAGE = 4;
const SYS_ALLOC_DMA = 5;
const SYS_FB_DRAW = 16;
const SYS_MAP_RECV = 17;

const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;
const PAGE_SIZE: u64 = 4096;

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

const BootstrapDescriptor = extern struct {
    magic: u32,
    version: u16,
    descriptor_len: u16,
    class: u16,
    service_kind: u16,
    runtime_mode: u16,
    _r0: u16,
    service_id: u32,
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
    microvm_ingress_magic: u32,
    microvm_ingress_version: u16,
    microvm_ingress_len: u16,
    capability_token: u64,
};

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;

// ---------------------------------------------------------------------------
// Telemetry message layout (mirrors microvm_bridge TelemetryUpdatePayload)
// ---------------------------------------------------------------------------

const DIPC_HEADER_SIZE: usize = 64; // DIPC header is 64 bytes
const CTRL_HEADER_SIZE: usize = 8; // ControlHeader (op + flags) is 8 bytes

const TelemetryPayload = extern struct {
    instance_id: u32,
    _reserved: u32,
    cpu_cycles: u64,
    exit_count: u64,
};

// Per-VM stats kept in a small table (max 8 VMs).
const MAX_VMS: u32 = 8;

const VmStats = struct {
    used: bool = false,
    id: u32 = 0,
    cpu_cycles: u64 = 0,
    exit_count: u64 = 0,
};

var vm_table: [MAX_VMS]VmStats = [_]VmStats{.{}} ** MAX_VMS;

// ---------------------------------------------------------------------------
// Small text helpers (write null-terminated string into DMA page)
// ---------------------------------------------------------------------------

fn appendByte(buf: [*]u8, pos: *usize, b: u8) void {
    buf[pos.*] = b;
    pos.* += 1;
}

fn appendStr(buf: [*]u8, pos: *usize, s: []const u8) void {
    for (s) |c| appendByte(buf, pos, c);
}

fn appendHex16(buf: [*]u8, pos: *usize, v: u64, digits: u8) void {
    const hexdig = "0123456789ABCDEF";
    var i: u8 = digits;
    while (i > 0) : (i -= 1) {
        const shift: u6 = @intCast((@as(u8, i) - 1) * 4);
        const nibble: usize = @intCast((v >> shift) & 0xF);
        appendByte(buf, pos, hexdig[nibble]);
    }
}

// ---------------------------------------------------------------------------
// Render dashboard rows onto the framebuffer via SYS_FB_DRAW.
// Each VM takes one text row; we allocate one DMA page as our text buffer.
// ---------------------------------------------------------------------------

fn renderDashboard(text_phys: u64, token: u64) void {
    const text_buf: [*]u8 = ptrFrom([*]u8, DMA_BASE_VA); // slot 0 VA
    var row: u32 = 0;

    // Header row (row 0)
    {
        var pos: usize = 0;
        appendStr(text_buf, &pos, "VM    CPU CYCLES         EXIT COUNT");
        appendByte(text_buf, &pos, 0); // null terminate
        _ = syscall(SYS_FB_DRAW, text_phys, @as(u64, 0) << 32, token);
        row = 1;
    }

    // Per-VM rows
    for (&vm_table) |*s| {
        if (!s.used) continue;
        var pos: usize = 0;
        appendStr(text_buf, &pos, "VM");
        appendHex16(text_buf, &pos, s.id, 4);
        appendByte(text_buf, &pos, ' ');
        appendHex16(text_buf, &pos, s.cpu_cycles, 16);
        appendByte(text_buf, &pos, ' ');
        appendHex16(text_buf, &pos, s.exit_count, 16);
        appendByte(text_buf, &pos, 0);
        _ = syscall(SYS_FB_DRAW, text_phys, @as(u64, row) << 32, token);
        row += 1;
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    if (bs.magic != 0x53565442) while (true) asm volatile ("hlt");
    const token = bs.capability_token;

    serialWrite("dashd: starting\n");
    _ = syscall(SYS_REGISTER, 0, bs.reserved_dashd_endpoint, token);
    serialWrite("dashd: registered\n");

    // Allocate one DMA page as a text scratch buffer.
    const text_phys = syscall(SYS_ALLOC_DMA, 1, 0, token);
    if (text_phys == 0) {
        serialWrite("dashd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    // Draw empty dashboard once at startup.
    renderDashboard(text_phys, token);

    // Main event loop.
    while (true) {
        const page_phys = syscall(SYS_RECV, 0, 0, token);
        if (page_phys == 0) {
            asm volatile ("pause");
            continue;
        }

        const recv_va = syscall(SYS_MAP_RECV, page_phys, 0, token);
        if (recv_va == 0) {
            _ = syscall(SYS_FREE_PAGE, page_phys, 0, token);
            continue;
        }

        // Decode telemetry payload (skip DIPC header + control header).
        const payload_ptr: [*]const u8 = ptrFrom([*]const u8, recv_va + DIPC_HEADER_SIZE + CTRL_HEADER_SIZE);
        const telem = @as(*const TelemetryPayload, @ptrCast(@alignCast(payload_ptr)));

        // Update VM stats table.
        const vid = telem.instance_id;
        var slot: ?*VmStats = null;
        for (&vm_table) |*s| {
            if (s.used and s.id == vid) {
                slot = s;
                break;
            }
        }
        if (slot == null) {
            for (&vm_table) |*s| {
                if (!s.used) {
                    s.used = true;
                    s.id = vid;
                    slot = s;
                    break;
                }
            }
        }
        if (slot) |s| {
            s.cpu_cycles = telem.cpu_cycles;
            s.exit_count = telem.exit_count;
        }

        // Re-render the dashboard.
        renderDashboard(text_phys, token);

        // Free the received DIPC page.
        _ = syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
    }
}
