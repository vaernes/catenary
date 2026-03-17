const scheduler = @import("../kernel/scheduler.zig");
const identity = @import("identity.zig");

pub const SendError = error{Busy};

// Core IPC boundary: Ring 0 only hands off a page-handle (physical address)
// to a user-space networking/routing daemon via local IPC.
pub fn sendToNetDaemon(target: identity.LocalEntity, page_phys: u64) SendError!void {
    const ok = switch (target) {
        .thread => |tid| scheduler.send(tid, page_phys),
        .service => |sid| scheduler.sendToService(sid, page_phys),
        else => false,
    };
    if (!ok) return error.Busy;
}
