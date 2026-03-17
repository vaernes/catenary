const arch = @import("../arch.zig");

pub export fn debug_print_reg() callconv(.naked) void {
    asm volatile (
        \\movq %rbx, %rdi
        \\call debug_print_rdi
        \\ret
    );
}

pub export fn debug_print_rdi(val: u64) void {
    const serial = @import("../../kernel/fb.zig"); // Or wherever serial is
    // Actually just use outb directly for speed
    arch.cpu.outb(0x3F8, 'R');
    arch.cpu.outb(0x3F8, 'B');
    arch.cpu.outb(0x3F8, 'X');
    arch.cpu.outb(0x3F8, ':');
    // Print hex...
    _ = val;
}
