const builtin = @import("builtin");

pub const cpu = @import("cpu.zig");
pub const gdt = @import("gdt.zig");
pub const hardening = @import("hardening.zig");
pub const idt = @import("idt.zig");
pub const paging = @import("paging.zig");
pub const timer = @import("timer.zig");
pub const user_mode = @import("user_mode.zig");
pub const vmx = @import("vmx.zig");
pub const svm = @import("svm.zig");

pub fn init() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        gdt.init();
        idt.init();
    }
}
