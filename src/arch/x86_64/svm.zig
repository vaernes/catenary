const std = @import("std");
const cpu = @import("cpu.zig");
const limine = @import("../../kernel/limine.zig");

const MSR_VM_CR: u32 = 0xC001_0114;
const MSR_EFER: u32 = 0xC000_0080;
const VM_CR_SVMDIS: u64 = 1 << 4;
const EFER_SVME: u64 = 1 << 12;
const CPUID_EXT_SVM_ECX_BIT: u32 = 2;

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        cpu.outb(0x3F8, c);
    }
}

fn cpuidBitSet(value: u32, bit: u32) bool {
    return (value & (@as(u32, 1) << @as(u5, @intCast(bit)))) != 0;
}

pub fn isSvmSupported() bool {
    const max_ext = cpu.cpuid(0x8000_0000, 0).eax;
    if (max_ext < 0x8000_0001) return false;

    const ext = cpu.cpuid(0x8000_0001, 0);
    if (!cpuidBitSet(ext.ecx, CPUID_EXT_SVM_ECX_BIT)) return false;

    const vm_cr = cpu.rdmsr(MSR_VM_CR);
    if ((vm_cr & VM_CR_SVMDIS) != 0) return false;

    return true;
}

pub fn init(memmap: *limine.MemmapResponse, hhdm_offset: u64) !void {
    _ = memmap;
    _ = hhdm_offset;

    if (!isSvmSupported()) {
        serialWrite("SVM: unsupported\n");
        return error.Unsupported;
    }

    var efer = cpu.rdmsr(MSR_EFER);
    efer |= EFER_SVME;
    cpu.wrmsr(MSR_EFER, efer);

    if ((cpu.rdmsr(MSR_EFER) & EFER_SVME) == 0) {
        serialWrite("SVM: failed to enable EFER.SVME\n");
        return error.EnableFailed;
    }

    serialWrite("SVM: EFER.SVME enabled\n");
}

fn clgi() void {
    if (comptime @import("builtin").cpu.arch == .x86_64) {
        asm volatile ("clgi" ::: .{ .memory = true });
    }
}
