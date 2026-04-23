/// dashd — system observability daemon.
///
/// Receives TelemetryUpdate DIPC messages from the VMM (microvm_bridge) and
/// renders per-VM stats onto the framebuffer via the SYS_FB_DRAW lib.syscall.
const std = @import("std");
const lib = @import("lib.zig");

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

const BootstrapDescriptor = lib.BootstrapDescriptor;
const USER_BOOTSTRAP_VADDR: usize = lib.USER_BOOTSTRAP_VADDR;
const DIPC_RECV_VA: u64 = lib.DIPC_RECV_VA;
const DMA_BASE_VA: u64 = lib.DMA_BASE_VA;

// ---------------------------------------------------------------------------
// Telemetry message layout (mirrors microvm_bridge TelemetryUpdatePayload)
// ---------------------------------------------------------------------------

const TelemetryPayload = lib.TelemetryUpdatePayload;

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
// Entry point
// ---------------------------------------------------------------------------

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    if (bs.magic != 0x53565442) while (true) asm volatile ("hlt");
    const token = bs.capability_token;

    lib.serialWrite("dashd: starting\n");
    _ = lib.syscall(lib.SYS_REGISTER, 0, bs.reserved_dashd_endpoint, token);
    lib.serialWrite("dashd: registered\n");

    // Allocate one DMA page as a text scratch buffer.
    const text_phys = lib.syscall(lib.SYS_ALLOC_DMA, 1, 0, token);
    if (text_phys == 0) {
        lib.serialWrite("dashd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    // Main event loop.
    while (true) {
        const page_phys = lib.syscall(lib.SYS_TRY_RECV, 0, 0, token);
        if (page_phys == 0) {
            _ = lib.syscall(lib.SYS_YIELD, 0, 0, token);
            asm volatile ("pause");
            continue;
        }

        const recv_va = lib.syscall(lib.SYS_MAP_RECV, page_phys, 0, token);
        if (recv_va == 0) {
            _ = lib.syscall(lib.SYS_FREE_PAGE, page_phys, 0, token);
            continue;
        }

        // Telemetry is sent as a raw DIPC payload by microvm_bridge.
        const telem: *align(1) const TelemetryPayload = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);

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

        // Stats updated — windowd will query via list_vms.
        // Free the received DIPC page.
        _ = lib.syscall(lib.SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
