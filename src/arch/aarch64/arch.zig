const builtin = @import("builtin");

pub const uart = @import("uart.zig");
pub const mmu = @import("mmu.zig");
pub const cpu = @import("cpu.zig");

pub fn init() void {
    if (comptime builtin.cpu.arch == .aarch64) {
        uart.init();
        cpu.setupExceptions();
        mmu.init();
    }
}
