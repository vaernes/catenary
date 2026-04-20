const cpu = @import("cpu.zig");

pub const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb_offset: u16 = 104,
};

var gdt: [7]u64 align(16) = undefined;
var gdtr: cpu.DescriptorTablePointer = undefined;

// Dedicated 16KB stack for IST1 (double-fault handler).
// Must survive for the entire kernel lifetime.
var ist1_stack: [16384]u8 align(16) linksection(".bss") = undefined;

var tss: Tss align(16) = .{
    .iopb_offset = @sizeOf(Tss),
};

pub fn init() void {
    gdt[0] = 0; // Null descriptor
    gdt[1] = 0x00af9a000000ffff; // Kernel code (0x08)
    gdt[2] = 0x00af92000000ffff; // Kernel data (0x10)
    gdt[3] = 0x00affb0000000000; // User code (0x18) - DPL 3, Long Mode, Readable
    gdt[4] = 0x00aff30000000000; // User data (0x20) - DPL 3, Writable, Long Mode (Ignored but present)

    // Populate IST1 with the dedicated double-fault stack.
    tss.ist1 = @intFromPtr(&ist1_stack) + ist1_stack.len;

    // TSS Descriptor (Task State Segment) - 16 bytes in x86_64
    const tss_ptr = @intFromPtr(&tss);
    const tss_limit = @as(u64, @sizeOf(Tss) - 1);

    gdt[5] = (tss_limit & 0xFFFF) |
        ((tss_ptr & 0xFFFFFF) << 16) |
        (0x89 << 40) | // Present, Type 9 (Available 64-bit TSS)
        (((tss_limit >> 16) & 0x0F) << 48) |
        (((tss_ptr >> 24) & 0xFF) << 56);
    gdt[6] = (tss_ptr >> 32);

    gdtr = cpu.DescriptorTablePointer{
        .limit = @as(u16, (7 * 8) - 1),
        .base = @intFromPtr(&gdt),
    };

    cpu.lgdt(&gdtr);

    // Reload segments because Limine might have loaded CS=0x28, which overlaps with our TSS!
    asm volatile (
        \\mov $0x10, %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\mov %ax, %fs
        \\mov %ax, %gs
        \\mov %ax, %ss
        \\pushq $0x08
        \\pushq $1f
        \\lretq
        \\1:
    );

    cpu.ltr(0x28);
}

pub const USER_CODE_SELECTOR: u16 = 0x18;
pub const USER_DATA_SELECTOR: u16 = 0x20;
pub const KERNEL_CODE_SELECTOR: u16 = 0x08;
pub const KERNEL_DATA_SELECTOR: u16 = 0x10;

pub fn setKernelRsp0(rsp: u64) void {
    tss.rsp0 = rsp;
}

pub fn getKernelRsp0() u64 {
    return tss.rsp0;
}

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var buf: [16]u8 = undefined;
    for (0..16) |i| {
        buf[15 - i] = hex[@as(u8, @intCast((n >> @as(u6, @intCast(i * 4))) & 0xF))];
    }
    for (buf) |c| cpu.outb(0x3F8, c);
}

pub fn tssBase() u64 {
    return @intFromPtr(&tss);
}
