const std = @import("std");
const color = @import("color.zig");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const inputd_proto = @import("../protocols/inputd_protocol.zig");
const InputEvent = inputd_proto.InputEvent;
const KeyCode = inputd_proto.KeyCode;

pub const ModalDialog = struct {
    rect: Rect = .{},
    title: [64]u8 = @splat(0),
    title_len: usize = 0,
    is_open: bool = false,
    border_color: u32 = color.COLOR_GOLDEN_YELLOW,
    header_bg: u32 = color.COLOR_TERRACOTTA,
    bg_color: u32 = color.COLOR_MODAL_BG,

    pub fn init(rect: Rect, title: []const u8) ModalDialog {
        var m = ModalDialog{ .rect = rect };
        m.setTitle(title);
        return m;
    }

    pub fn initCentered(w: u32, h: u32, screen_w: u32, screen_h: u32, title: []const u8) ModalDialog {
        const final_w = @min(w, screen_w);
        const final_h = @min(h, screen_h);
        const x = if (screen_w > final_w) (screen_w - final_w) / 2 else 0;
        const y = if (screen_h > final_h) (screen_h - final_h) / 2 else 0;

        var m = ModalDialog{
            .rect = Rect{ .x = x, .y = y, .w = final_w, .h = final_h },
        };
        m.setTitle(title);
        return m;
    }

    pub fn setTitle(self: *ModalDialog, title: []const u8) void {
        const n = @min(title.len, self.title.len);
        @memcpy(self.title[0..n], title[0..n]);
        self.title_len = n;
    }

    pub fn getTitle(self: *const ModalDialog) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn open(self: *ModalDialog) void {
        self.is_open = true;
    }

    pub fn close(self: *ModalDialog) void {
        self.is_open = false;
    }

    pub fn isOpen(self: ModalDialog) bool {
        return self.is_open;
    }

    pub fn handleKey(self: *ModalDialog, evt: InputEvent) bool {
        if (!self.is_open) return false;

        if (evt.key_code == .escape or evt.key_code == .f1 or evt.ascii == '?' or
            evt.ascii == 'q' or evt.key_code == .enter or evt.ascii == '\n' or evt.ascii == ' ')
        {
            self.close();
            return true;
        }
        // Trap all keys while open so background components do not receive stray inputs
        return true;
    }

    pub fn render(self: ModalDialog, surface: anytype) void {
        if (!self.is_open) return;

        // Border outline
        surface.fillRect(self.rect.x, self.rect.y, self.rect.w, self.rect.h, self.border_color);

        const bw: u32 = 2;
        const hh: u32 = 24;

        // Interior surface fill
        if (self.rect.w > bw * 2 and self.rect.h > hh + bw) {
            surface.fillRect(self.rect.x + bw, self.rect.y + hh, self.rect.w - bw * 2, self.rect.h - hh - bw, self.bg_color);
        }

        // Header bar fill
        if (self.rect.w > bw * 2 and self.rect.h > bw * 2) {
            surface.fillRect(self.rect.x + bw, self.rect.y + bw, self.rect.w - bw * 2, hh - bw, self.header_bg);
        }

        // Title text
        const title_str = self.getTitle();
        if (title_str.len > 0) {
            const row = (self.rect.y + 4) / 8;
            const col = (self.rect.x + 8) / 8;
            surface.drawText(row, col, color.COLOR_WHITE, self.header_bg, title_str);
        }
    }
};
