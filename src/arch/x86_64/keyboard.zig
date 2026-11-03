const cpu = @import("cpu.zig");
const idt = @import("idt.zig");

const KBD_DATA_PORT: u16 = 0x60;
const KBD_STATUS_PORT: u16 = 0x64;

var kbd_ring_buf: [256]u8 = undefined;
var kbd_ring_head: u8 = 0;
var kbd_ring_tail: u8 = 0;
var kbd_lock: bool = false;

fn acquireKbdLock() u64 {
    var flags: u64 = 0;
    asm volatile (
        \\pushfq
        \\popq %[flags]
        \\cli
        : [flags] "=r" (flags),
    );
    while (@atomicRmw(bool, &kbd_lock, .Xchg, true, .seq_cst)) {
        asm volatile ("pause");
    }
    return flags;
}

fn releaseKbdLock(flags: u64) void {
    @atomicStore(bool, &kbd_lock, false, .seq_cst);
    asm volatile (
        \\pushq %[flags]
        \\popfq
        :
        : [flags] "r" (flags),
    );
}

fn drainControllerLocked() void {
    while ((cpu.inb(KBD_STATUS_PORT) & 0x01) != 0) {
        const scancode = cpu.inb(KBD_DATA_PORT);
        const next = kbd_ring_head +% 1;
        if (next != kbd_ring_tail) {
            kbd_ring_buf[kbd_ring_head] = scancode;
            kbd_ring_head = next;
        }
    }
}

pub fn init() void {
    // Basic PS/2 keyboard initialization.
    idt.setGate(0x21, keyboardInterrupt, 0x8E);

    // Drain any leftover data in controller buffer
    while ((cpu.inb(KBD_STATUS_PORT) & 0x01) != 0) {
        _ = cpu.inb(KBD_DATA_PORT);
    }

    // Enable first PS/2 port
    cpu.outb(KBD_STATUS_PORT, 0xAE);
}

pub fn getChar() ?u8 {
    const scancode = getRawScancode() orelse return null;
    return scancodeToAscii(scancode);
}

pub fn getRawScancode() ?u8 {
    const flags = acquireKbdLock();
    defer releaseKbdLock(flags);
    if (kbd_ring_head == kbd_ring_tail) {
        drainControllerLocked();
    }
    if (kbd_ring_head == kbd_ring_tail) return null;
    const scancode = kbd_ring_buf[kbd_ring_tail];
    kbd_ring_tail +%= 1;
    return scancode;
}

fn scancodeToAscii(scancode: u8) ?u8 {
    // Very basic US-QWERTY mapping (Set 1)
    return switch (scancode) {
        0x1E => 'a',
        0x30 => 'b',
        0x2E => 'c',
        0x20 => 'd',
        0x12 => 'e',
        0x21 => 'f',
        0x22 => 'g',
        0x23 => 'h',
        0x17 => 'i',
        0x24 => 'j',
        0x25 => 'k',
        0x26 => 'l',
        0x32 => 'm',
        0x31 => 'n',
        0x18 => 'o',
        0x19 => 'p',
        0x10 => 'q',
        0x13 => 'r',
        0x1F => 's',
        0x14 => 't',
        0x16 => 'u',
        0x2F => 'v',
        0x11 => 'w',
        0x2D => 'x',
        0x15 => 'y',
        0x2C => 'z',
        0x02 => '1',
        0x03 => '2',
        0x04 => '3',
        0x05 => '4',
        0x06 => '5',
        0x07 => '6',
        0x08 => '7',
        0x09 => '8',
        0x0A => '9',
        0x0B => '0',
        0x1C => '\n',
        0x39 => ' ',
        0x0E => 0x08, // Backspace
        else => null,
    };
}

pub export fn catenary_keyboardInterruptBridge() callconv(.c) void {
    {
        const flags = acquireKbdLock();
        defer releaseKbdLock(flags);
        drainControllerLocked();
    }
    cpu.outb(0x20, 0x20); // Send EOI to master PIC
}

pub fn keyboardInterrupt() callconv(.naked) void {
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
        \\subq $512, %rsp
        \\fxsave64 (%rsp)
        \\callq catenary_keyboardInterruptBridge
        \\fxrstor64 (%rsp)
        \\addq $512, %rsp
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
