const endpoint_table = @import("endpoint_table.zig");
const identity = @import("identity.zig");
const dipc = @import("dipc.zig");
const control_handler = @import("../control/control_handler.zig");
const scheduler = @import("../kernel/scheduler.zig");
const router = @import("router.zig");
const node_config = @import("node_config.zig");

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        asm volatile ("outb %al, %dx"
            :
            : [al] "{al}" (c),
              [dx] "{dx}" (@as(u16, 0x3F8)),
        );
    }
}

// Global IPC state
var table: endpoint_table.EndpointTable align(16) linksection(".data") = undefined;
var initialized: bool = false;
var hhdm_offset: u64 = 0;

pub fn init(offset: u64) void {
    if (initialized) return;
    hhdm_offset = offset;
    table.init();

    const control_tid = scheduler.spawn(controlLoop) catch {
        serialWrite("MANAGER: failed to spawn control loop\n");
        return;
    };
    table.registerReservedKernelControlThread(control_tid);

    initialized = true;
}

pub fn endpointTable() *endpoint_table.EndpointTable {
    return &table;
}

/// Core kernel IPC control loop.
/// Handles kernel_control messages and dispatches them to control_handler.
pub fn controlLoop() void {
    while (true) {
        if (scheduler.receive()) |msg| {
            const page_phys = msg;
            const hdr = dipc.headerFromPage(hhdm_offset, page_phys);

            // Kernel-control: consume + free.
            if (hdr.magic == dipc.WireMagic and hdr.dst.endpoint == @intFromEnum(identity.ReservedEndpoint.kernel_control)) {
                control_handler.handleKernelControlPage(hhdm_offset, &table, page_phys) catch {
                    serialWrite("MANAGER: control_handler error!\n");
                };
                dipc.freePageMessage(page_phys);
                continue;
            }

            // Not for kernel control: Hand off to router.
            _ = router.routePageWithLocalNode(hhdm_offset, &table, page_phys) catch {
                dipc.freePageMessage(page_phys);
                continue;
            };
        } else {
            scheduler.schedule();
        }
    }
}
