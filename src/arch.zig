// Architecture dispatch layer.
//
// All architecture-specific kernel subsystems are accessed through this file.
// To add a new architecture: create src/arch/<name>/arch.zig that exposes the
// same public symbols, then add a branch below.
//
// Currently only x86_64 is implemented.

const builtin = @import("builtin");

pub const gdt = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/gdt.zig"),
    .aarch64 => struct {
        pub fn init() void {}
    },
    else => @compileError("Unsupported arch for GDT"),
};

pub const idt = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/idt.zig"),
    .aarch64 => struct {
        pub fn init() void {}
    },
    else => @compileError("Unsupported arch for IDT"),
};

pub const paging = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/paging.zig"),
    else => struct {},
};

pub const cpu = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/cpu.zig"),
    .aarch64 => @import("arch/aarch64/cpu.zig"),
    else => @compileError("Unsupported arch for CPU"),
};

pub const hardening = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/hardening.zig"),
    else => struct {
        pub const BaselineReport = struct {
            nx_enabled: bool = false,
            nx_supported: bool = false,
            smep_enabled: bool = false,
            smep_supported: bool = false,
            smap_supported: bool = false,
        };
        pub fn applyBaseline() BaselineReport {
            return .{};
        }
    },
};
