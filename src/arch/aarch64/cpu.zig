const std = @import("std");

pub fn cpuid(leaf: u32, subleaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    _ = leaf;
    _ = subleaf;
    @compileError("AArch64 does not have CPUID (use System Registers/ID_AA64*)");
}

pub fn rdmsr(msr: u32) u64 {
    _ = msr;
    @compileError("AArch64 does not have MSRs (use mrs instruction)");
}

pub fn wrmsr(msr: u32, val: u64) void {
    _ = msr;
    _ = val;
    @compileError("AArch64 does not have MSRs (use msr instruction)");
}

pub fn readCr0() u64 {
    @compileError("AArch64 does not have CR0");
}
pub fn readCr3() u64 {
    @compileError("AArch64 does not have CR3 (use TTBR0/1)");
}
pub fn readCr4() u64 {
    @compileError("AArch64 does not have CR4");
}
pub fn writeCr0(val: u64) void {
    _ = val;
    @compileError("AArch64 does not have CR0");
}
pub fn writeCr3(val: u64) void {
    _ = val;
    @compileError("AArch64 does not have CR3");
}
pub fn writeCr4(val: u64) void {
    _ = val;
    @compileError("AArch64 does not have CR4");
}

pub fn halt() void {
    asm volatile ("wfi");
}

pub fn pause() void {
    asm volatile ("yield");
}

pub fn sti() void {
    asm volatile ("msr daifclr, #2");
}

pub fn hlt() void {
    asm volatile ("wfi");
}

pub fn cli() void {
    asm volatile ("msr daifset, #2");
}

pub fn setupExceptions() void {
    const Exceptions = struct {
        extern var exception_vector_table: anyopaque;
    };
    asm volatile ("msr vbar_el1, %[vbar]"
        :
        : [vbar] "r" (&Exceptions.exception_vector_table),
    );
}
