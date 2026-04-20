const std = @import("std");
const lib = @import("lib.zig");



const SYS_REGISTER = 2;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_GET_KEY = 8; // Custom lib.syscall to pop a scancode

const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;

const BootstrapDescriptor = lib.BootstrapDescriptor;

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;



// Map scancodes to simple ASCII
fn scancodeToAscii(scancode: u8) ?u8 {
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
        0x0E => 0x08,
        else => null,
    };
}

const InputEventPayload = extern struct {
    event_type: u8,
    ascii: u8,
    scancode: u8,
    _reserved: [5]u8 = [_]u8{0} ** 5,
};

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    lib.serialWrite("inputd: starting\n");
    _ = lib.syscall(SYS_REGISTER, 0, 8, token); // Register at endpoint 8 for inputd
    lib.serialWrite("inputd: registered at endpoint 8\n");

    const dipc_phys = lib.syscall(SYS_ALLOC_DMA, 1, 0, token);
    if (dipc_phys == 0) {
        lib.serialWrite("inputd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    // Input loop: poll the kernel buffer via SYS_GET_KEY, then broadcast via DIPC
    lib.serialWrite("inputd: entering event loop\n");
    while (true) {
        const scancode_val = lib.syscall(SYS_GET_KEY, 0, 0, token);
        if (scancode_val != 0xFFFFFFFF) {
            const scancode: u8 = @truncate(scancode_val);
            if ((scancode & 0x80) == 0) { // Only Make codes for now
                if (scancodeToAscii(scancode)) |c| {
                    // Send to dashd as a simple raw DIPC payload.
                    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA);
                    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };
                    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
                    header.* = .{
                        .magic = lib.WireMagic,
                        .version = lib.WireVersion,
                        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
                        .payload_len = @as(u32, @intCast(@sizeOf(InputEventPayload))),
                        .auth_tag = 0,
                        .src = .{ .node = local_node, .endpoint = 8 },
                        .dst = .{ .node = local_node, .endpoint = bs.reserved_dashd_endpoint },
                    };

                    const payload: *align(1) InputEventPayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
                    payload.* = .{
                        .event_type = 1,
                        .ascii = c,
                        .scancode = scancode,
                    };

                    _ = lib.syscall(SYS_SEND_PAGE, dipc_phys, 0, token);
                }
            }
        } else {
            // Wait briefly before polling again
            for (0..100000) |_| asm volatile ("pause");
        }
    }
}
