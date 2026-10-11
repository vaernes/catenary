const std = @import("std");
const lib = @import("lib.zig");
const proto = @import("protocols/inputd_protocol.zig");

const SYS_REGISTER = lib.SYS_REGISTER;
const SYS_ALLOC_DMA = lib.SYS_ALLOC_DMA;
const SYS_SEND_PAGE = lib.SYS_SEND_PAGE;
const SYS_GET_KEY = lib.SYS_GET_KEY;
const SYS_YIELD = lib.SYS_YIELD;

const DMA_BASE_VA: u64 = lib.DMA_BASE_VA;
const BootstrapDescriptor = lib.BootstrapDescriptor;
const USER_BOOTSTRAP_VADDR: usize = lib.USER_BOOTSTRAP_VADDR;

const InputEventPayload = proto.InputEvent;
const KeyCode = proto.KeyCode;

// US-QWERTY scancode set 1, make codes 0x00..0x39. 0 = no printable mapping.
const NORMAL = "\x00\x001234567890-=\x00\x00qwertyuiop[]\x00\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
const SHIFTED = "\x00\x00!@#$%^&*()_+\x00\x00QWERTYUIOP{}\x00\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";

comptime {
    if (NORMAL.len != 58 or SHIFTED.len != 58) @compileError("keymap tables must cover scancodes 0x00..0x39");
}

const SC_LSHIFT: u8 = 0x2A;
const SC_RSHIFT: u8 = 0x36;
const SC_CTRL: u8 = 0x1D;
const SC_ALT: u8 = 0x38;
const SC_CAPS: u8 = 0x3A;

var extended: bool = false;
var shift_l: bool = false;
var shift_r: bool = false;
var ctrl: bool = false;
var alt: bool = false;
var caps: bool = false;

fn isLetter(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn functionKey(sc: u8) KeyCode {
    return switch (sc) {
        0x3B...0x44 => @enumFromInt(@intFromEnum(KeyCode.f1) + (sc - 0x3B)),
        0x57 => .f11,
        0x58 => .f12,
        else => .none,
    };
}

fn extendedKey(sc: u8) KeyCode {
    return switch (sc) {
        0x48 => .up,
        0x50 => .down,
        0x4B => .left,
        0x4D => .right,
        0x49 => .page_up,
        0x51 => .page_down,
        0x47 => .home,
        0x4F => .end,
        0x53 => .delete,
        0x52 => .insert,
        0x1C => .enter, // keypad enter
        else => .none,
    };
}

fn plainKey(sc: u8) KeyCode {
    return switch (sc) {
        0x01 => .escape,
        0x0E => .backspace,
        0x0F => .tab,
        0x1C => .enter,
        else => functionKey(sc),
    };
}

fn modifierBits() u8 {
    var m: u8 = 0;
    if (shift_l or shift_r) m |= proto.MOD_SHIFT;
    if (ctrl) m |= proto.MOD_CTRL;
    if (alt) m |= proto.MOD_ALT;
    if (caps) m |= proto.MOD_CAPS;
    return m;
}

fn translateAscii(sc: u8) u8 {
    if (sc >= NORMAL.len) return 0;
    const base = NORMAL[sc];
    if (base == 0) return 0;
    const shift = shift_l or shift_r;
    if (isLetter(base)) {
        return if (shift != caps) SHIFTED[sc] else base;
    }
    return if (shift) SHIFTED[sc] else base;
}

/// Feed one raw scancode byte through the decoder. Returns an event to send
/// when the byte completes a key press.
fn decode(byte: u8) ?InputEventPayload {
    if (byte == 0xE0) {
        extended = true;
        return null;
    }
    if (byte == 0xE1) return null; // Pause/Break prefix: ignored

    const is_break = (byte & 0x80) != 0;
    const sc = byte & 0x7F;
    const was_extended = extended;
    extended = false;

    // Modifier tracking (left and right variants share the base scancodes).
    switch (sc) {
        SC_LSHIFT => if (!was_extended) {
            shift_l = !is_break;
            return null;
        },
        SC_RSHIFT => if (!was_extended) {
            shift_r = !is_break;
            return null;
        },
        SC_CTRL => {
            ctrl = !is_break;
            return null;
        },
        SC_ALT => {
            alt = !is_break;
            return null;
        },
        SC_CAPS => if (!was_extended) {
            if (!is_break) caps = !caps;
            return null;
        },
        else => {},
    }
    if (is_break) return null;

    const key: KeyCode = if (was_extended) extendedKey(sc) else plainKey(sc);
    var ascii: u8 = 0;
    if (key == .none and !was_extended) ascii = translateAscii(sc);
    if (key == .none and ascii == 0) return null;

    return .{
        .event_type = .key_press,
        .ascii = ascii,
        .scancode = sc,
        .key_code = key,
        .modifiers = modifierBits(),
    };
}

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

    var local_node: ?lib.Ipv6Addr = null;

    // Input loop: poll the kernel scancode ring via SYS_GET_KEY (which yields
    // when empty) and forward decoded events over DIPC. inputd must never park
    // in SYS_RECV: only a DIPC send wakes a parked thread and nothing sends to
    // inputd, so a single idle poll would otherwise stop all keyboard input.
    lib.serialWrite("inputd: entering event loop\n");
    while (true) {
        const scancode_val = lib.syscall(SYS_GET_KEY, 0, 0, token);
        if (scancode_val == 0xFFFFFFFF) {
            _ = lib.syscall(SYS_YIELD, 0, 0, token);
            continue;
        }

        const evt = decode(@truncate(scancode_val)) orelse continue;

        if (local_node == null) {
            local_node = lib.queryCurrentNode(bs, token, dipc_phys, DMA_BASE_VA, 8) orelse lib.Ipv6Addr{ .bytes = bs.local_node };
        }
        const node = local_node.?;

        const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA);
        const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
        header.* = .{
            .magic = lib.WireMagic,
            .version = lib.WireVersion,
            .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
            .payload_len = @as(u32, @intCast(@sizeOf(InputEventPayload))),
            .auth_tag = 0,
            .src = .{ .node = node, .endpoint = 8 }, // inputd
            .dst = .{ .node = node, .endpoint = 9 }, // windowd
        };
        const payload: *align(1) InputEventPayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
        payload.* = evt;

        _ = lib.syscall(SYS_SEND_PAGE, dipc_phys, 0, token);
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
