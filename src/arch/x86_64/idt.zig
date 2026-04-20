const std = @import("std");
const cpu = @import("cpu.zig");
const timer = @import("timer.zig");
const keyboard = @import("keyboard.zig");

const user_mode = @import("user_mode.zig");

const IdtEntry = packed struct {
    isr_low: u16,
    kernel_cs: u16,
    ist: u8,
    attributes: u8,
    isr_mid: u16,
    isr_high: u32,
    reserved: u32,
};

var idt: [256]IdtEntry = undefined;
var idtr: cpu.DescriptorTablePointer = undefined;

pub fn setGate(vector: u8, isr: *const fn () callconv(.naked) void, flags: u8) void {
    setGateWithIst(vector, isr, flags, 0);
}

pub fn setGateWithIst(vector: u8, isr: *const fn () callconv(.naked) void, flags: u8, ist: u8) void {
    const addr = @intFromPtr(isr);
    idt[vector] = IdtEntry{
        .isr_low = @as(u16, @truncate(addr & 0xFFFF)),
        .kernel_cs = 0x08, // Kernel code segment offset
        .ist = ist,
        .attributes = flags,
        .isr_mid = @as(u16, @truncate((addr >> 16) & 0xFFFF)),
        .isr_high = @as(u32, @truncate((addr >> 32) & 0xFFFFFFFF)),
        .reserved = 0,
    };
}

fn ignoreIsr() callconv(.naked) void {
    asm volatile (
        \\pushq %rax
        \\pushq %rdx
        \\movw $0x20, %dx
        \\movb $0x20, %al
        \\outb %al, %dx
        \\movw $0xA0, %dx
        \\outb %al, %dx
        \\popq %rdx
        \\popq %rax
        \\iretq
    );
}

fn genericIsr() callconv(.naked) void {
    asm volatile (
        \\movq $0, %rsi
        \\movq $0, %rdx
        \\movq $0, %rcx
        \\movb $0xFF, %dil
        \\callq catenary_fatalTrap
    );
}

fn serialByte(c: u8) void {
    outb(0x3F8, c);
}

fn serialHex(v: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const nibble: usize = @intCast((v >> shift) & 0xF);
        serialByte(hex[nibble]);
        if (shift >= 4) shift -= 4;
    }
}

pub export fn catenary_fatalTrap(vector: u8, err: u64, rip: u64, cr2: u64) callconv(.c) noreturn {
    serialWriteLiteral("\nFATAL_TRAP vector=0x");
    serialHex(vector);
    serialWriteLiteral(" err=0x");
    serialHex(err);
    serialWriteLiteral(" rip=0x");
    serialHex(rip);
    serialWriteLiteral(" cr2=0x");
    serialHex(cr2);
    if (vector == 14) {
        // Page fault with P=0 is a not-present fault, which includes intentional
        // guard pages used by scheduler stack hardening.
        if ((err & 1) == 0) {
            serialWriteLiteral(" cause=guard_or_not_present");
        }
    }
    serialByte('\n');
    cpu.cli();
    while (true) {
        cpu.hlt();
    }
}

fn serialWriteLiteral(s: []const u8) void {
    for (s) |c| {
        serialByte(c);
    }
}

fn deIsr() callconv(.naked) void {
    asm volatile (
        \\movq 0(%rsp), %rsi
        \\movq $0, %rdx
        \\movq $0, %rcx
        \\movb $0, %dil
        \\callq catenary_fatalTrap
    );
}

fn dbIsr() callconv(.naked) void {
    asm volatile (
        \\movq 0(%rsp), %rsi
        \\movq $0, %rdx
        \\movq $0, %rcx
        \\movb $1, %dil
        \\callq catenary_fatalTrap
    );
}

fn bpIsr() callconv(.naked) void {
    asm volatile (
        \\movq 0(%rsp), %rsi
        \\movq $0, %rdx
        \\movq $0, %rcx
        \\movb $3, %dil
        \\callq catenary_fatalTrap
    );
}

fn udIsr() callconv(.naked) void {
    asm volatile (
        \\movq 0(%rsp), %rsi
        \\movq $0, %rdx
        \\movq $0, %rcx
        \\movb $6, %dil
        \\callq catenary_fatalTrap
    );
}

fn gpIsr() callconv(.naked) void {
    asm volatile (
        \\movq 8(%rsp), %rdx
        \\movq 0(%rsp), %rsi
        \\movq $0, %rcx
        \\movb $13, %dil
        \\callq catenary_fatalTrap
    );
}

fn pfIsr() callconv(.naked) void {
    asm volatile (
        \\movq 8(%rsp), %rdx
        \\movq 0(%rsp), %rsi
        \\movq %cr2, %rcx
        \\movb $14, %dil
        \\callq catenary_fatalTrap
    );
}

pub fn init() void {
    // Populate IDT and load IDTR *before* remapping the PIC.
    // If PIC remapping were done first, a spurious interrupt arriving before
    // lidt executes would find no valid handler and triple-fault on real hardware.

    // Initialize all to generic handler
    for (0..32) |i| {
        setGate(@as(u8, @intCast(i)), genericIsr, 0x8E);
    }
    for (32..256) |i| {
        setGate(@as(u8, @intCast(i)), ignoreIsr, 0x8E);
    }

    setGateWithIst(8, genericIsr, 0x8E, 1); // Double Fault — IST1 for dedicated stack
    setGate(0, deIsr, 0x8E);
    setGate(1, dbIsr, 0x8E);
    setGate(3, user_mode.breakpointIsr, 0xEE);
    setGate(6, udIsr, 0x8E);
    setGate(13, user_mode.gpIsr, 0xEE);
    setGate(14, user_mode.pfIsr, 0xEE);
    setGate(0x80, user_mode.syscallIsr, 0xEE);
    setGate(0x20, timer.timerInterrupt, 0x8E);
    setGate(0x21, keyboard.keyboardInterrupt, 0x8E);

    idtr = cpu.DescriptorTablePointer{
        .limit = @as(u16, @sizeOf(@TypeOf(idt)) - 1),
        .base = @intFromPtr(&idt),
    };

    cpu.lidt(&idtr);

    // Remap PIC: IRQ0-7 → vectors 32-39, IRQ8-15 → vectors 40-47.
    // Now that the IDT is live any spurious interrupt gets the generic handler.
    outb(0x20, 0x11);
    outb(0xA0, 0x11);
    outb(0x21, 0x20); // Master offset 32
    outb(0xA1, 0x28); // Slave offset 40
    outb(0x21, 0x04);
    outb(0xA1, 0x02);
    outb(0x21, 0x01);
    outb(0xA1, 0x01);
    outb(0x21, 0x0);
    outb(0xA1, 0x0);
}

const builtin = @import("builtin");

pub fn enableInterrupts() void {
    cpu.sti();
}

fn outb(port: u16, val: u8) void {
    cpu.outb(port, val);
}
