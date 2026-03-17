const cpu = @import("cpu.zig");
const scheduler = @import("../../kernel/scheduler.zig");

const PIT_CMD_PORT: u16 = 0x43;
const PIT_CH0_PORT: u16 = 0x40;
const PIT_BASE_HZ: u32 = 1_193_182;
const TICK_HZ: u32 = 100;

pub fn init() void {
    // PIT channel 0, lobyte/hibyte, mode 2 (rate generator), binary mode.
    const divisor_u32 = PIT_BASE_HZ / TICK_HZ;
    const divisor: u16 = @as(u16, @intCast(if (divisor_u32 == 0) 1 else divisor_u32));
    cpu.outb(PIT_CMD_PORT, 0x34);
    cpu.outb(PIT_CH0_PORT, @as(u8, @truncate(divisor & 0xFF)));
    cpu.outb(PIT_CH0_PORT, @as(u8, @truncate((divisor >> 8) & 0xFF)));
}

pub export fn catenary_timerInterruptBridge() callconv(.c) void {
    cpu.outb(0x20, 0x20);
    scheduler.schedule();
}

pub fn timerInterrupt() callconv(.naked) void {
    asm volatile (
        \\pushq %rax
        \\pushq %rcx
        \\pushq %rdx
        \\pushq %rbx
        \\pushq %rbp
        \\pushq %rsi
        \\pushq %rdi
        \\pushq %r8
        \\pushq %r9
        \\pushq %r10
        \\pushq %r11
        \\pushq %r12
        \\pushq %r13
        \\pushq %r14
        \\pushq %r15
        \\callq catenary_timerInterruptBridge
        \\popq %r15
        \\popq %r14
        \\popq %r13
        \\popq %r12
        \\popq %r11
        \\popq %r10
        \\popq %r9
        \\popq %r8
        \\popq %rdi
        \\popq %rsi
        \\popq %rbp
        \\popq %rbx
        \\popq %rdx
        \\popq %rcx
        \\popq %rax
        \\iretq
    );
}
