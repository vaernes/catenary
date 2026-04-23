/// inputd DIPC protocol
///
/// Endpoint: ReservedEndpoint.inputd (8)
///
/// inputd polls the PS/2 keyboard scancode buffer via SYS_GET_KEY and
/// broadcasts an InputEvent to windowd on every key-make event.
/// It does not receive inbound DIPC messages.
///
/// Message format (sent FROM inputd to windowd):
///   PageHeader    (lib.DIPC_HEADER_SIZE bytes)
///   InputEvent    (8 bytes, extern-padded to u64 alignment)
pub const MAGIC: u32 = 0x494E5054; // 'INPT'
pub const VERSION: u16 = 1;

// ---------------------------------------------------------------------------
// Events sent FROM inputd → windowd
// ---------------------------------------------------------------------------

pub const EventType = enum(u8) {
    /// A key was pressed (make code only; break codes are filtered).
    key_press = 1,
};

/// Keyboard event broadcast to windowd's endpoint.
/// Only make-code events are sent; key releases are dropped.
pub const InputEvent = extern struct {
    event_type: EventType,
    /// ASCII character derived from the scancode (0 if no mapping).
    ascii: u8,
    /// Raw PS/2 set-1 make scancode.
    scancode: u8,
    _reserved: [5]u8 = [_]u8{0} ** 5,
};

comptime {
    if (@sizeOf(InputEvent) != 8) @compileError("InputEvent must be 8 bytes");
}
