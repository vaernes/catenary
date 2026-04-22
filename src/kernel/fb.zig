const std = @import("std");
const limine = @import("limine.zig");

var framebuffer: ?*limine.Framebuffer = null;

pub fn init(request: *limine.FramebufferRequest, serialWrite: fn ([]const u8) void) void {
    if (request.response) |resp| {
        if (resp.framebuffer_count > 0) {
            framebuffer = resp.framebuffers[0];
            serialWrite("Display: framebuffer ready\n");
        } else {
            serialWrite("Display: no framebuffer available\n");
        }
    } else {
        serialWrite("Display: framebuffer request unavailable\n");
    }
}

pub fn drawRect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    const fb = framebuffer orelse return;

    var dy: u32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < w) : (dx += 1) {
            const offset = (y + dy) * (@as(u32, @truncate(fb.pitch)) / 4) + (x + dx);
            @as(*u32, @ptrFromInt(@intFromPtr(fb.address) + offset * 4)).* = color;
        }
    }
}

pub fn getFramebufferInfo() ?struct { width: u32, height: u32 } {
    const fb = framebuffer orelse return null;
    return .{
        .width = @as(u32, @truncate(fb.width)),
        .height = @as(u32, @truncate(fb.height)),
    };
}

pub fn clear(color: u32) void {
    const fb = framebuffer orelse return;
    drawRect(0, 0, @as(u32, @truncate(fb.width)), @as(u32, @truncate(fb.height)), color);
}

const font = @import("font.zig");

var cursor_x: u32 = 0;
var cursor_y: u32 = 20; // Start below the white bar
pub const CharWidth = 8;
pub const CharHeight = 8;

// Branding Colors
pub const ColorSeaGray = 0x004A4E69;
pub const ColorTerracotta = 0x00E2725B;
pub const ColorGoldenYellow = 0x00FFC300;
pub const ColorWhite = 0x00FFFFFF;

pub fn drawChar(x: u32, y: u32, c: u8, fg: u32, bg: u32) void {
    const fb_ptr = framebuffer orelse return;
    if (x + CharWidth > fb_ptr.width or y + CharHeight > fb_ptr.height) return;

    const glyph = font.font8x8[if (c < 128) c else 0];

    var dy: u32 = 0;
    while (dy < CharHeight) : (dy += 1) {
        const row = glyph[dy];
        var dx: u32 = 0;
        while (dx < CharWidth) : (dx += 1) {
            const pixel_color = if ((row & (@as(u8, 1) << @as(u3, @intCast(dx)))) != 0) fg else bg;
            const offset = (y + dy) * (@as(u32, @truncate(fb_ptr.pitch)) / 4) + (x + dx);
            @as(*u32, @ptrFromInt(@intFromPtr(fb_ptr.address) + offset * 4)).* = pixel_color;
        }
    }
}

pub fn printChar(c: u8) void {
    const fb_ptr = framebuffer orelse return;

    if (c == '\n') {
        cursor_x = 0;
        cursor_y += CharHeight;
    } else if (c == '\r') {
        cursor_x = 0;
    } else if (c == '\x08' or c == 127) { // backspace
        if (cursor_x >= CharWidth) {
            cursor_x -= CharWidth;
            drawChar(cursor_x, cursor_y, ' ', ColorWhite, ColorSeaGray);
        }
    } else {
        drawChar(cursor_x, cursor_y, c, ColorWhite, ColorSeaGray); // White on Sea Gray
        cursor_x += CharWidth;
    }

    // Scroll handling
    if (cursor_x + CharWidth > fb_ptr.width) {
        cursor_x = 0;
        cursor_y += CharHeight;
    }
    if (cursor_y + CharHeight > fb_ptr.height) {
        scroll();
        cursor_y -= CharHeight;
    }
}

pub fn scroll() void {
    const fb = framebuffer orelse return;
    const stride = @as(u32, @truncate(fb.pitch)) / 4;
    const start_y = 20;
    const height = @as(u32, @truncate(fb.height));
    const width = @as(u32, @truncate(fb.width));

    // Shift everything up by CharHeight starting from y=20+CharHeight
    var y: u32 = start_y;
    while (y < height - CharHeight) : (y += 1) {
        const src_start = (y + CharHeight) * stride;
        const dst_start = y * stride;
        const src: [*]u32 = @ptrFromInt(@intFromPtr(fb.address) + src_start * 4);
        const dst: [*]u32 = @ptrFromInt(@intFromPtr(fb.address) + dst_start * 4);
        @memcpy(dst[0..width], src[0..width]);
    }

    // Clear the last line with Sea Gray
    drawRect(0, height - CharHeight, width, CharHeight, ColorSeaGray);
}

pub fn printString(s: []const u8) void {
    for (s) |c| {
        printChar(c);
    }
}
