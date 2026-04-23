/// windowd DIPC protocol
///
/// Endpoint: ReservedEndpoint.windowd (9)
///
/// windowd renders the TUI compositor onto the kernel framebuffer.
/// It accepts:
///   - InputEvent messages from inputd (keyboard input)
///   - VmSnapshotListPayload replies from kernel_control (via lib.ControlOp.list_microvms)
///
/// windowd itself sends only kernel_control requests (list_microvms).
/// The inbound service-to-service message format from inputd is defined here.
///
/// Message format (inbound from inputd):
///   PageHeader  (lib.DIPC_HEADER_SIZE bytes)
///   InputEvent  (8 bytes — see inputd_protocol.InputEvent)

pub const MAGIC: u32 = 0x57494E44; // 'WIND'
pub const VERSION: u16 = 1;

// ---------------------------------------------------------------------------
// Re-export the canonical input event type for windowd consumers.
// ---------------------------------------------------------------------------

/// Keyboard event as received from inputd.
/// Mirrors inputd_protocol.InputEvent — kept here so windowd can import a
/// single protocol file without a cross-module dependency on inputd_protocol.
pub const InputEvent = extern struct {
    event_type: u8,
    /// ASCII character (0 if no mapping for this scancode).
    ascii: u8,
    /// Raw PS/2 set-1 make scancode.
    scancode: u8,
    _reserved: [5]u8 = [_]u8{0} ** 5,
};

comptime {
    if (@sizeOf(InputEvent) != 8) @compileError("InputEvent must be 8 bytes");
}

// ---------------------------------------------------------------------------
// Future inbound ops (not yet implemented in the service loop, but defined
// here as the intended extension point for inter-service window management).
// ---------------------------------------------------------------------------

pub const Op = enum(u16) {
    /// Keyboard event from inputd.  Payload: InputEvent.
    input_event = 1,

    /// Request a full redraw of the TUI (e.g., after a resolution change).
    /// Payload: none.
    force_redraw = 2,
};

pub const WindowdHeader = extern struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    op: Op,
    payload_len: u32,
    _pad: u32 = 0,
};
