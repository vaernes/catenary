const std = @import("std");
const color = @import("color.zig");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const inputd_proto = @import("../protocols/inputd_protocol.zig");
const InputEvent = inputd_proto.InputEvent;
const KeyCode = inputd_proto.KeyCode;

pub const Button = struct {
    rect: Rect = .{},
    label: [32]u8 = @splat(0),
    label_len: usize = 0,
    is_focused: bool = true,
    is_pressed: bool = false,
    enabled: bool = true,

    pub fn init(rect: Rect, label: []const u8) Button {
        var b = Button{ .rect = rect };
        b.setLabel(label);
        return b;
    }

    pub fn initLabel(label: []const u8) Button {
        return init(Rect{}, label);
    }

    pub fn setLabel(self: *Button, label: []const u8) void {
        const n = @min(label.len, self.label.len);
        @memcpy(self.label[0..n], label[0..n]);
        self.label_len = n;
    }

    pub fn getLabel(self: *const Button) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn setFocused(self: *Button, focused: bool) void {
        self.is_focused = focused;
        if (!focused) self.is_pressed = false;
    }

    pub fn setPressed(self: *Button, pressed: bool) void {
        self.is_pressed = pressed;
    }

    pub fn trigger(self: *Button) bool {
        if (!self.enabled) return false;
        self.is_pressed = true;
        return true;
    }

    pub fn handleKey(self: *Button, evt: InputEvent) bool {
        if (!self.is_focused or !self.enabled) return false;

        if (evt.key_code == .enter or evt.ascii == '\n' or evt.ascii == ' ') {
            return self.trigger();
        }
        return false;
    }

    pub fn render(self: Button, surface: anytype) void {
        const bg = if (self.is_focused) color.COLOR_GOLDEN_YELLOW else color.COLOR_TERRACOTTA;
        const fg = if (self.is_focused) color.COLOR_INPUT_BG else color.COLOR_WHITE;

        surface.fillRect(self.rect.x, self.rect.y, self.rect.w, self.rect.h, bg);
        const bounds = self.rect.toCellBounds();
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " [ {s} ] ", .{ self.getLabel() }) catch self.getLabel();
        if (bounds.rows > 0 and bounds.cols > 0) {
            surface.drawText(bounds.row, bounds.col + 1, fg, bg, text);
        }
    }
};
