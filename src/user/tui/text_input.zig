const std = @import("std");
const color = @import("color.zig");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const inputd_proto = @import("../protocols/inputd_protocol.zig");
const InputEvent = inputd_proto.InputEvent;
const KeyCode = inputd_proto.KeyCode;

pub const MAX_TEXT_INPUT_LEN: usize = 96;

pub const TextInput = struct {
    rect: Rect = .{},
    buffer: [MAX_TEXT_INPUT_LEN + 1]u8 = @splat(0),
    len: usize = 0,
    cursor_pos: usize = 0,
    max_len: usize = 31,
    is_focused: bool = true,
    text_color: u32 = color.COLOR_WHITE,
    bg_color: u32 = color.COLOR_INPUT_BG,
    focused_color: u32 = color.COLOR_HIGHLIGHT,

    pub fn init(rect: Rect, max_len: usize) TextInput {
        return .{
            .rect = rect,
            .max_len = @min(max_len, MAX_TEXT_INPUT_LEN),
        };
    }

    pub fn initWithCapacity(max_len: usize) TextInput {
        return init(Rect{}, max_len);
    }

    pub fn getText(self: *const TextInput) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn setText(self: *TextInput, text: []const u8) void {
        const n = @min(text.len, self.max_len);
        @memcpy(self.buffer[0..n], text[0..n]);
        self.len = n;
        self.cursor_pos = n;
        self.buffer[n] = 0;
    }

    pub fn clear(self: *TextInput) void {
        self.len = 0;
        self.cursor_pos = 0;
        self.buffer[0] = 0;
    }

    pub fn setFocused(self: *TextInput, focused: bool) void {
        self.is_focused = focused;
    }

    pub fn moveCursorLeft(self: *TextInput) bool {
        if (self.cursor_pos > 0) {
            self.cursor_pos -= 1;
            return true;
        }
        return false;
    }

    pub fn cursorLeft(self: *TextInput) void {
        _ = self.moveCursorLeft();
    }

    pub fn moveCursorRight(self: *TextInput) bool {
        if (self.cursor_pos < self.len) {
            self.cursor_pos += 1;
            return true;
        }
        return false;
    }

    pub fn cursorRight(self: *TextInput) void {
        _ = self.moveCursorRight();
    }

    pub fn moveCursorHome(self: *TextInput) bool {
        if (self.cursor_pos != 0) {
            self.cursor_pos = 0;
            return true;
        }
        return false;
    }

    pub fn cursorHome(self: *TextInput) void {
        _ = self.moveCursorHome();
    }

    pub fn moveCursorEnd(self: *TextInput) bool {
        if (self.cursor_pos != self.len) {
            self.cursor_pos = self.len;
            return true;
        }
        return false;
    }

    pub fn cursorEnd(self: *TextInput) void {
        _ = self.moveCursorEnd();
    }

    pub fn insertChar(self: *TextInput, c: u8) bool {
        if (self.len >= self.max_len) return false;
        if (c < 32 or c > 126) return false;

        if (self.cursor_pos == self.len) {
            self.buffer[self.len] = c;
            self.len += 1;
            self.cursor_pos += 1;
            self.buffer[self.len] = 0;
            return true;
        }

        var i = self.len;
        while (i > self.cursor_pos) : (i -= 1) {
            self.buffer[i] = self.buffer[i - 1];
        }
        self.buffer[self.cursor_pos] = c;
        self.len += 1;
        self.cursor_pos += 1;
        self.buffer[self.len] = 0;
        return true;
    }

    pub fn deleteBackward(self: *TextInput) bool {
        if (self.cursor_pos == 0) return false;

        if (self.cursor_pos == self.len) {
            self.len -= 1;
            self.cursor_pos -= 1;
            self.buffer[self.len] = 0;
            return true;
        }

        var i = self.cursor_pos - 1;
        while (i + 1 < self.len) : (i += 1) {
            self.buffer[i] = self.buffer[i + 1];
        }
        self.len -= 1;
        self.cursor_pos -= 1;
        self.buffer[self.len] = 0;
        return true;
    }

    pub fn deleteForward(self: *TextInput) bool {
        if (self.cursor_pos >= self.len) return false;

        var i = self.cursor_pos;
        while (i + 1 < self.len) : (i += 1) {
            self.buffer[i] = self.buffer[i + 1];
        }
        self.len -= 1;
        self.buffer[self.len] = 0;
        return true;
    }

    pub fn handleKey(self: *TextInput, evt: InputEvent) bool {
        if (!self.is_focused) return false;

        if (evt.key_code == .left) return self.moveCursorLeft();
        if (evt.key_code == .right) return self.moveCursorRight();
        if (evt.key_code == .home) return self.moveCursorHome();
        if (evt.key_code == .end) return self.moveCursorEnd();

        if (evt.key_code == .backspace or evt.ascii == 0x08) {
            return self.deleteBackward();
        }
        if (evt.key_code == .delete) {
            return self.deleteForward();
        }
        if (evt.ascii >= 32 and evt.ascii <= 126) {
            return self.insertChar(evt.ascii);
        }
        return false;
    }

    pub fn render(self: TextInput, surface: anytype) void {
        surface.fillRect(self.rect.x, self.rect.y, self.rect.w, self.rect.h, self.bg_color);
        const bounds = self.rect.toCellBounds();
        var disp_buf: [MAX_TEXT_INPUT_LEN + 16]u8 = undefined;
        var p: usize = 0;
        disp_buf[p] = ' ';
        p += 1;

        const max_display = if (bounds.cols > 3) bounds.cols - 3 else 0;
        const visible_len = @min(self.len, @min(disp_buf.len - 4, max_display));
        if (visible_len > 0) {
            @memcpy(disp_buf[p..][0..visible_len], self.buffer[0..visible_len]);
            p += visible_len;
        }

        if (self.is_focused and p < disp_buf.len) {
            disp_buf[p] = '_';
            p += 1;
        }

        while (p < bounds.cols and p < disp_buf.len) : (p += 1) {
            disp_buf[p] = ' ';
        }

        const fg = if (self.is_focused) self.focused_color else self.text_color;
        if (bounds.rows > 0 and bounds.cols > 0 and p > 0) {
            surface.drawText(bounds.row, bounds.col, fg, self.bg_color, disp_buf[0..p]);
        }
    }
};
