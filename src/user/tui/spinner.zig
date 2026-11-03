const std = @import("std");
const color = @import("color.zig");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const inputd_proto = @import("../protocols/inputd_protocol.zig");
const InputEvent = inputd_proto.InputEvent;
const KeyCode = inputd_proto.KeyCode;

pub const NumberSpinner = struct {
    rect: Rect = .{},
    value: u32 = 1,
    min: u32 = 1,
    max: u32 = 4,
    step: u32 = 1,
    suffix: [16]u8 = @splat(0),
    suffix_len: usize = 0,
    is_focused: bool = true,

    pub fn init(rect: Rect, value: u32, min_val: u32, max_val: u32, step: u32, suffix: []const u8) NumberSpinner {
        const true_min = @min(min_val, max_val);
        const true_max = @max(min_val, max_val);
        const clamped_val = @max(true_min, @min(value, true_max));
        var s = NumberSpinner{
            .rect = rect,
            .value = clamped_val,
            .min = true_min,
            .max = true_max,
            .step = if (step == 0) 1 else step,
        };
        s.setSuffix(suffix);
        return s;
    }

    pub fn initSimple(min_val: u32, max_val: u32, default_val: u32, step: u32) NumberSpinner {
        return init(Rect{}, default_val, min_val, max_val, step, "");
    }

    pub fn setSuffix(self: *NumberSpinner, suffix: []const u8) void {
        const n = @min(suffix.len, self.suffix.len);
        @memcpy(self.suffix[0..n], suffix[0..n]);
        self.suffix_len = n;
    }

    pub fn getSuffix(self: *const NumberSpinner) []const u8 {
        return self.suffix[0..self.suffix_len];
    }

    pub fn getValue(self: NumberSpinner) u32 {
        return self.value;
    }

    pub fn setValue(self: *NumberSpinner, val: u32) void {
        self.value = std.math.clamp(val, self.min, self.max);
    }

    pub fn stepUp(self: *NumberSpinner) bool {
        if (self.value >= self.max) return false;
        if (self.step > self.max - self.value) {
            self.value = self.max;
        } else {
            self.value += self.step;
        }
        return true;
    }

    pub fn increment(self: *NumberSpinner) bool {
        return self.stepUp();
    }

    pub fn stepDown(self: *NumberSpinner) bool {
        if (self.value <= self.min) return false;
        if (self.step > self.value - self.min) {
            self.value = self.min;
        } else {
            self.value -= self.step;
        }
        return true;
    }

    pub fn decrement(self: *NumberSpinner) bool {
        return self.stepDown();
    }

    pub fn setFocused(self: *NumberSpinner, focused: bool) void {
        self.is_focused = focused;
    }

    pub fn handleKey(self: *NumberSpinner, evt: InputEvent) bool {
        if (!self.is_focused) return false;

        if (evt.key_code == .left or evt.key_code == .down) {
            return self.stepDown();
        }
        if (evt.key_code == .right or evt.key_code == .up) {
            return self.stepUp();
        }
        if (evt.ascii >= '0' and evt.ascii <= '9') {
            const digit = @as(u32, evt.ascii - '0');
            if (digit >= self.min and digit <= self.max) {
                if (self.value != digit) {
                    self.value = digit;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn render(self: NumberSpinner, surface: anytype) void {
        surface.fillRect(self.rect.x, self.rect.y, self.rect.w, self.rect.h, color.COLOR_INPUT_BG);
        const bounds = self.rect.toCellBounds();
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " < {d}{s} > ", .{ self.value, self.getSuffix() }) catch " < ? > ";
        const fg = if (self.is_focused) color.COLOR_HIGHLIGHT else color.COLOR_WHITE;
        if (bounds.rows > 0 and bounds.cols > 0) {
            surface.drawText(bounds.row, bounds.col, fg, color.COLOR_INPUT_BG, text);
        }
    }
};
