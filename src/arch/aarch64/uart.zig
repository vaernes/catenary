const std = @import("std");

/// Simple PL011 UART driver for QEMU 'virt' board.
pub const UART_BASE = 0x09000000;

pub const UART_DR   = UART_BASE + 0x00;
pub const UART_FR   = UART_BASE + 0x18;
pub const UART_LCRH = UART_BASE + 0x2C;
pub const UART_CR   = UART_BASE + 0x30;

pub fn init() void {
    // Basic PL011 init is usually not needed in QEMU, but we ensure it's enabled.
    // Standard QEMU UART is already correctly configured by the bootloader/hw.
}

pub fn putc(c: u8) void {
    const dr = @as(*volatile u32, @ptrFromInt(UART_DR));
    const fr = @as(*volatile u32, @ptrFromInt(UART_FR));

    // Wait for transmit FIFO not full
    while ((fr.* & (1 << 5)) != 0) {}
    dr.* = c;
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        putc(c);
    }
}

pub const Writer = struct {
    pub const Error = error{};
    pub const WriterType = std.io.Writer(*Writer, Error, writeFn);

    fn writeFn(context: *Writer, bytes: []const u8) Error!usize {
        _ = context;
        write(bytes);
        return bytes.len;
    }

    pub fn writer(self: *Writer) WriterType {
        return .{ .context = self };
    }
};

var global_writer = Writer{};

pub fn getWriter() Writer.WriterType {
    return global_writer.writer();
}
pub fn write(s: []const u8) void {
    for (s) |c| {
        putc(c);
    }
}

pub const Writer = struct {
    pub const Error = error{};
    pub const WriterType = std.io.Writer(*Writer, Error, writeFn);

    fn writeFn(context: *Writer, bytes: []const u8) Error!usize {
        _ = context;
        write(bytes);
        return bytes.len;
    }

    pub fn writer(self: *Writer) WriterType {
        return .{ .context = self };
    }
};

var global_writer = Writer{};

pub fn getWriter() Writer.WriterType {
    return global_writer.writer();
}
