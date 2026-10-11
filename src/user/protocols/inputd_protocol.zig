/// inputd DIPC protocol
///
/// Endpoint: ReservedEndpoint.inputd (8)
///
/// inputd polls the PS/2 keyboard scancode buffer via SYS_GET_KEY, decodes
/// scancode set 1 (including 0xE0-extended keys and modifier state) and sends
/// an InputEvent to windowd on every key press (including typematic repeats).
/// It does not receive inbound DIPC messages.
///
/// Message format (sent FROM inputd to windowd):
///   PageHeader    (lib.DIPC_HEADER_SIZE bytes)
///   InputEvent    (8 bytes)
pub const MAGIC: u32 = 0x494E5054; // 'INPT'
pub const VERSION: u16 = 2;

pub const EventType = enum(u8) {
    /// A key was pressed (or auto-repeated). Releases are consumed by inputd.
    key_press = 1,
};

/// Non-printable key identifiers. Printable keys are reported through
/// `InputEvent.ascii` with `key_code == .none`.
pub const KeyCode = enum(u8) {
    none = 0,
    enter = 1,
    backspace = 2,
    tab = 3,
    escape = 4,
    up = 5,
    down = 6,
    left = 7,
    right = 8,
    page_up = 9,
    page_down = 10,
    home = 11,
    end = 12,
    delete = 13,
    insert = 14,
    f1 = 32,
    f2 = 33,
    f3 = 34,
    f4 = 35,
    f5 = 36,
    f6 = 37,
    f7 = 38,
    f8 = 39,
    f9 = 40,
    f10 = 41,
    f11 = 42,
    f12 = 43,
    _,
};

pub const MOD_SHIFT: u8 = 0x01;
pub const MOD_CTRL: u8 = 0x02;
pub const MOD_ALT: u8 = 0x04;
pub const MOD_CAPS: u8 = 0x08;

/// Keyboard event sent to windowd's endpoint.
pub const InputEvent = extern struct {
    event_type: EventType,
    /// Printable ASCII (32..126) after Shift/CapsLock translation, else 0.
    ascii: u8,
    /// Raw PS/2 set-1 make scancode (extended keys keep their low 7 bits).
    scancode: u8,
    key_code: KeyCode = .none,
    /// Bitmask of MOD_* flags active when the key went down.
    modifiers: u8 = 0,
    _reserved: [3]u8 = [_]u8{0} ** 3,
};

comptime {
    if (@sizeOf(InputEvent) != 8) @compileError("InputEvent must be 8 bytes");
}
