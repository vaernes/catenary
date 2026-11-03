const std = @import("std");
const color = @import("color.zig");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;

pub const Panel = struct {
    rect: Rect,
    title: [48]u8 = @splat(0),
    title_len: usize = 0,
    is_focused: bool = false,
    header_height: u32 = 20,
    border_width: u32 = 2,
    border_color_focused: u32 = color.COLOR_HIGHLIGHT,
    border_color_unfocused: u32 = color.COLOR_SEA_GRAY,
    header_color_focused: u32 = color.COLOR_HIGHLIGHT,
    header_color_unfocused: u32 = color.COLOR_TERRACOTTA,
    bg_color: u32 = color.COLOR_PANEL_BG,

    pub fn init(rect: Rect, title: []const u8) Panel {
        var p = Panel{ .rect = rect };
        p.setTitle(title);
        return p;
    }

    pub fn setTitle(self: *Panel, title: []const u8) void {
        const n = @min(title.len, self.title.len);
        @memcpy(self.title[0..n], title[0..n]);
        self.title_len = n;
    }

    pub fn getTitle(self: *const Panel) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn setFocused(self: *Panel, focused: bool) void {
        self.is_focused = focused;
    }

    pub fn innerRect(self: Panel) Rect {
        const b = self.border_width;
        if (self.rect.w <= b * 2 or self.rect.h <= self.header_height + b * 2) {
            return Rect{ .x = self.rect.x, .y = self.rect.y, .w = 0, .h = 0 };
        }
        return Rect{
            .x = self.rect.x + b,
            .y = self.rect.y + self.header_height,
            .w = self.rect.w - b * 2,
            .h = self.rect.h - self.header_height - b,
        };
    }

    pub fn contentStartRow(self: Panel) u32 {
        return (self.rect.y + self.header_height) / 8 + 1;
    }

    pub fn contentStartCol(self: Panel) u32 {
        return (self.rect.x + self.border_width) / 8 + 1;
    }

    pub fn render(self: Panel, surface: anytype) void {
        const border_color = if (self.is_focused) self.border_color_focused else self.border_color_unfocused;
        const header_color = if (self.is_focused) self.header_color_focused else self.header_color_unfocused;

        // Outer border fill
        surface.fillRect(self.rect.x, self.rect.y, self.rect.w, self.rect.h, border_color);

        // Interior surface fill
        const inner = self.innerRect();
        if (inner.w > 0 and inner.h > 0) {
            surface.fillRect(inner.x, inner.y, inner.w, inner.h, self.bg_color);
        }

        // Header bar fill
        if (self.rect.w > self.border_width * 2 and self.header_height > self.border_width) {
            surface.fillRect(
                self.rect.x + self.border_width,
                self.rect.y + self.border_width,
                self.rect.w - self.border_width * 2,
                self.header_height - self.border_width,
                header_color,
            );
        }

        // Title text
        const title_str = self.getTitle();
        if (title_str.len > 0) {
            const row = (self.rect.y + 4) / 8;
            const col = (self.rect.x + 8) / 8;
            surface.drawText(row, col, color.COLOR_WHITE, header_color, title_str);
        }
    }
};
