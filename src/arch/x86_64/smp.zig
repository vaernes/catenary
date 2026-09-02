/// smp.zig — Symmetric Multi-Processing (SMP) bringup for Catenary OS.
///
/// Detects secondary CPU cores and coordinates APIC inter-processor interrupts (IPI).
const std = @import("std");
const cpu = @import("cpu.zig");

pub const MAX_CPUS: usize = 32;

pub const CpuCore = struct {
    id: u32,
    lapic_id: u32,
    online: bool,
    is_bsp: bool,
};

var cpus: [MAX_CPUS]CpuCore = [_]CpuCore{.{
    .id = 0,
    .lapic_id = 0,
    .online = true,
    .is_bsp = true,
}} ** MAX_CPUS;

var cpu_count: usize = 1;

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        cpu.outb(0x3F8, c);
    }
}

pub fn init() void {
    const cpuid_1 = cpu.cpuid(1, 0);
    const bsp_apic_id = @as(u8, @truncate(cpuid_1.ebx >> 24));
    cpus[0].lapic_id = bsp_apic_id;

    serialWrite("SMP: BSP active LAPIC ID=");
    printHex(bsp_apic_id);
    serialWrite(" cores=1\n");
}

pub fn getCpuCount() usize {
    return cpu_count;
}

pub fn isBsp() bool {
    return cpus[0].is_bsp;
}

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        cpu.outb(0x3F8, hex[nibble]);
        if (shift >= 4) shift -= 4;
    }
}
