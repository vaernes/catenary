const std = @import("std");

/// Catenary OS Official Visual Identity & Branding Color Palette (docs/BRANDING.md)
pub const COLOR_SEA_GRAY: u32 = 0x004A4E69; // Main background, bedrock, inert borders, bottom bar
pub const COLOR_TERRACOTTA: u32 = 0x00E2725B; // Primary arch color, inactive panel headers, default buttons
pub const COLOR_GOLDEN_YELLOW: u32 = 0x00FFC300; // Active cluster nodes, warnings, button focus, title highlights
pub const COLOR_HIGHLIGHT: u32 = 0x005BC0EB; // Focused panel borders/headers, selected list items, text cursor
pub const COLOR_GREEN: u32 = 0x0000CC44; // Status Green: running MicroVMs, healthy cluster peers, success
pub const COLOR_RED: u32 = 0x00FF4444; // Status Red: stopped/killed VMs, input validation errors, failure
pub const COLOR_WHITE: u32 = 0x00FFFFFF; // Text White: primary text content, unselected items
pub const COLOR_DIM: u32 = 0x00888888; // Text Dim: field placeholders, disabled options, secondary metadata
pub const COLOR_PANEL_BG: u32 = 0x002B2D42; // Panel Background: interior fill of standard panels
pub const COLOR_INPUT_BG: u32 = 0x001A1C2E; // Input Background: editable text field box, spinner box, option box
pub const COLOR_MODAL_BG: u32 = 0x001F2033; // Modal Background: centered dialog backdrop

// Convenience Aliases matching documentation names
pub const SeaGray = COLOR_SEA_GRAY;
pub const Terracotta = COLOR_TERRACOTTA;
pub const GoldenYellow = COLOR_GOLDEN_YELLOW;
pub const HighlightCyan = COLOR_HIGHLIGHT;
pub const StatusGreen = COLOR_GREEN;
pub const StatusRed = COLOR_RED;
pub const TextWhite = COLOR_WHITE;
pub const TextDim = COLOR_DIM;
pub const PanelBg = COLOR_PANEL_BG;
pub const InputBg = COLOR_INPUT_BG;
pub const ModalBg = COLOR_MODAL_BG;

// Short UPPER_CASE Aliases
pub const SEA_GRAY = COLOR_SEA_GRAY;
pub const TERRACOTTA = COLOR_TERRACOTTA;
pub const GOLDEN_YELLOW = COLOR_GOLDEN_YELLOW;
pub const HIGHLIGHT = COLOR_HIGHLIGHT;
pub const GREEN = COLOR_GREEN;
pub const RED = COLOR_RED;
pub const WHITE = COLOR_WHITE;
pub const DIM = COLOR_DIM;
pub const PANEL_BG = COLOR_PANEL_BG;
pub const INPUT_BG = COLOR_INPUT_BG;
pub const MODAL_BG = COLOR_MODAL_BG;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn toRgb(color: u32) Rgb {
    return .{
        .r = @as(u8, @truncate((color >> 16) & 0xFF)),
        .g = @as(u8, @truncate((color >> 8) & 0xFF)),
        .b = @as(u8, @truncate(color & 0xFF)),
    };
}

pub fn fromRgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}
