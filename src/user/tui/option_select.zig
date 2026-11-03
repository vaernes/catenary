const std = @import("std");
const color = @import("color.zig");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const inputd_proto = @import("../protocols/inputd_protocol.zig");
const InputEvent = inputd_proto.InputEvent;
const KeyCode = inputd_proto.KeyCode;

pub const MAX_OPTIONS: usize = 16;
pub const MAX_OPTION_LABEL_LEN: usize = 32;

pub const OptionSelect = struct {
    rect: Rect = .{},
    options: [MAX_OPTIONS][MAX_OPTION_LABEL_LEN]u8 = @splat(@splat(0)),
    option_lens: [MAX_OPTIONS]usize = @splat(0),
    option_count: usize = 0,
    selected_idx: usize = 0,
    is_focused: bool = true,
    wrap: bool = true,

    pub fn init(rect: Rect, options_list: []const []const u8, default_idx: usize) OptionSelect {
        var os = OptionSelect{ .rect = rect };
        const count = @min(options_list.len, MAX_OPTIONS);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const opt = options_list[i];
            const len = @min(opt.len, MAX_OPTION_LABEL_LEN);
            @memcpy(os.options[i][0..len], opt[0..len]);
            os.option_lens[i] = len;
        }
        os.option_count = count;
        os.selected_idx = if (count > 0) @min(default_idx, count - 1) else 0;
        return os;
    }

    pub fn initList(options_list: []const []const u8, default_idx: usize) OptionSelect {
        return init(Rect{}, options_list, default_idx);
    }

    pub fn getSelected(self: *const OptionSelect) []const u8 {
        if (self.option_count == 0) return "";
        return self.options[self.selected_idx][0..self.option_lens[self.selected_idx]];
    }

    pub fn getSelectedIndex(self: OptionSelect) usize {
        return self.selected_idx;
    }

    pub fn setSelectedIndex(self: *OptionSelect, idx: usize) void {
        if (self.option_count == 0) {
            self.selected_idx = 0;
            return;
        }
        self.selected_idx = @min(idx, self.option_count - 1);
    }

    pub fn selectNext(self: *OptionSelect) bool {
        if (self.option_count <= 1) return false;
        if (self.selected_idx + 1 < self.option_count) {
            self.selected_idx += 1;
            return true;
        } else if (self.wrap) {
            self.selected_idx = 0;
            return true;
        }
        return false;
    }

    pub fn next(self: *OptionSelect) void {
        _ = self.selectNext();
    }

    pub fn selectPrev(self: *OptionSelect) bool {
        if (self.option_count <= 1) return false;
        if (self.selected_idx > 0) {
            self.selected_idx -= 1;
            return true;
        } else if (self.wrap) {
            self.selected_idx = self.option_count - 1;
            return true;
        }
        return false;
    }

    pub fn previous(self: *OptionSelect) void {
        _ = self.selectPrev();
    }

    pub fn prev(self: *OptionSelect) void {
        _ = self.selectPrev();
    }

    pub fn setFocused(self: *OptionSelect, focused: bool) void {
        self.is_focused = focused;
    }

    pub fn handleKey(self: *OptionSelect, evt: InputEvent) bool {
        if (!self.is_focused) return false;

        if (evt.key_code == .right or evt.key_code == .down) {
            return self.selectNext();
        }
        if (evt.key_code == .left or evt.key_code == .up) {
            return self.selectPrev();
        }
        return false;
    }

    pub fn render(self: OptionSelect, surface: anytype) void {
        surface.fillRect(self.rect.x, self.rect.y, self.rect.w, self.rect.h, color.COLOR_INPUT_BG);
        const bounds = self.rect.toCellBounds();
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " < {s} > ", .{ self.getSelected() }) catch " < ... > ";
        const fg = if (self.is_focused) color.COLOR_HIGHLIGHT else color.COLOR_WHITE;
        if (bounds.rows > 0 and bounds.cols > 0) {
            surface.drawText(bounds.row, bounds.col, fg, color.COLOR_INPUT_BG, text);
        }
    }
};
