const std = @import("std");
const testing = std.testing;

const tui = @import("mod.zig");
const color = tui.color;
const geometry = tui.geometry;
const Rect = geometry.Rect;
const Point = geometry.Point;
const CellBounds = geometry.CellBounds;
const DamageTracker = geometry.DamageTracker;
const Panel = tui.Panel;
const TextInput = tui.TextInput;
const MAX_TEXT_INPUT_LEN = tui.text_input.MAX_TEXT_INPUT_LEN;
const NumberSpinner = tui.NumberSpinner;
const OptionSelect = tui.OptionSelect;
const ListView = tui.ListView;
const Button = tui.Button;
const ModalDialog = tui.ModalDialog;

const inputd_proto = @import("../protocols/inputd_protocol.zig");
const InputEvent = inputd_proto.InputEvent;
const KeyCode = inputd_proto.KeyCode;

// Helper constructors for deterministic event simulation
fn makeKey(key_code: KeyCode) InputEvent {
    return .{
        .event_type = .key_press,
        .ascii = 0,
        .scancode = 0,
        .key_code = key_code,
        .modifiers = 0,
    };
}

fn makeAscii(ch: u8) InputEvent {
    return .{
        .event_type = .key_press,
        .ascii = ch,
        .scancode = 0,
        .key_code = .none,
        .modifiers = 0,
    };
}

// ============================================================================
// 1. Color Palette & RGB Conversions
// ============================================================================

test "tui: color palette constants and branding conformity" {
    try testing.expectEqual(@as(u32, 0x004A4E69), color.COLOR_SEA_GRAY);
    try testing.expectEqual(@as(u32, 0x00E2725B), color.COLOR_TERRACOTTA);
    try testing.expectEqual(@as(u32, 0x00FFC300), color.COLOR_GOLDEN_YELLOW);
    try testing.expectEqual(@as(u32, 0x005BC0EB), color.COLOR_HIGHLIGHT);
    try testing.expectEqual(@as(u32, 0x0000CC44), color.COLOR_GREEN);
    try testing.expectEqual(@as(u32, 0x00FF4444), color.COLOR_RED);
    try testing.expectEqual(@as(u32, 0x00FFFFFF), color.COLOR_WHITE);
    try testing.expectEqual(@as(u32, 0x00888888), color.COLOR_DIM);
    try testing.expectEqual(@as(u32, 0x002B2D42), color.COLOR_PANEL_BG);
    try testing.expectEqual(@as(u32, 0x001A1C2E), color.COLOR_INPUT_BG);
    try testing.expectEqual(@as(u32, 0x001F2033), color.COLOR_MODAL_BG);

    // Aliases
    try testing.expectEqual(color.COLOR_SEA_GRAY, color.SeaGray);
    try testing.expectEqual(color.COLOR_TERRACOTTA, color.Terracotta);
    try testing.expectEqual(color.COLOR_GOLDEN_YELLOW, color.GoldenYellow);
    try testing.expectEqual(color.COLOR_HIGHLIGHT, color.HighlightCyan);
    try testing.expectEqual(color.COLOR_GREEN, color.StatusGreen);
    try testing.expectEqual(color.COLOR_RED, color.StatusRed);
    try testing.expectEqual(color.COLOR_WHITE, color.TextWhite);
    try testing.expectEqual(color.COLOR_DIM, color.TextDim);
    try testing.expectEqual(color.COLOR_PANEL_BG, color.PanelBg);
    try testing.expectEqual(color.COLOR_INPUT_BG, color.InputBg);
    try testing.expectEqual(color.COLOR_MODAL_BG, color.ModalBg);

    try testing.expectEqual(color.COLOR_SEA_GRAY, color.SEA_GRAY);
    try testing.expectEqual(color.COLOR_TERRACOTTA, color.TERRACOTTA);
}

test "tui: RGB pack and unpack helpers" {
    const rgb = color.toRgb(color.COLOR_TERRACOTTA);
    try testing.expectEqual(@as(u8, 0xE2), rgb.r);
    try testing.expectEqual(@as(u8, 0x72), rgb.g);
    try testing.expectEqual(@as(u8, 0x5B), rgb.b);

    const packed_color = color.fromRgb(rgb.r, rgb.g, rgb.b);
    try testing.expectEqual(color.COLOR_TERRACOTTA, packed_color);

    const white_rgb = color.toRgb(0x00FFFFFF);
    try testing.expectEqual(@as(u8, 0xFF), white_rgb.r);
    try testing.expectEqual(@as(u8, 0xFF), white_rgb.g);
    try testing.expectEqual(@as(u8, 0xFF), white_rgb.b);
}

// ============================================================================
// 2. Geometry: Point, Rect & DamageTracker
// ============================================================================

test "tui: Rect contains standard and boundary coordinates" {
    const r = Rect.init(10, 20, 30, 40);

    // Top-left corner and interior points
    try testing.expect(r.contains(10, 20));
    try testing.expect(r.contains(25, 35));
    try testing.expect(r.contains(39, 59));
    try testing.expect(r.containsPoint(Point{ .x = 10, .y = 20 }));
    try testing.expect(r.containsXY(25, 35));

    // Half-open boundary exclusions: [x, x+w) by [y, y+h)
    try testing.expect(!r.contains(40, 60));
    try testing.expect(!r.contains(40, 20));
    try testing.expect(!r.contains(10, 60));

    // Strictly external coordinates
    try testing.expect(!r.contains(9, 20));
    try testing.expect(!r.contains(10, 19));
    try testing.expect(!r.contains(41, 30));
    try testing.expect(!r.contains(25, 61));
}

test "tui: Rect zero dimensions cannot contain points" {
    const zero_w = Rect.init(10, 20, 0, 40);
    const zero_h = Rect.init(10, 20, 30, 0);
    const zero_both = Rect.init(10, 20, 0, 0);

    try testing.expect(!zero_w.contains(10, 20));
    try testing.expect(!zero_h.contains(10, 20));
    try testing.expect(!zero_both.contains(10, 20));
}

test "tui: Rect intersects and adjacent" {
    const r1 = Rect.init(10, 10, 20, 20); // x: 10..30, y: 10..30

    const r_overlap = Rect.init(25, 25, 20, 20);
    try testing.expect(r1.intersects(r_overlap));
    try testing.expect(r_overlap.intersects(r1));

    // Touching borders: adjacent but NOT intersecting
    const r_touch_right = Rect.init(30, 10, 20, 20);
    const r_touch_bottom = Rect.init(10, 30, 20, 20);
    try testing.expect(!r1.intersects(r_touch_right));
    try testing.expect(!r1.intersects(r_touch_bottom));
    try testing.expect(r1.adjacent(r_touch_right));
    try testing.expect(r1.adjacent(r_touch_bottom));

    // Disjoint
    const r_disjoint = Rect.init(100, 100, 10, 10);
    try testing.expect(!r1.intersects(r_disjoint));
    try testing.expect(!r1.adjacent(r_disjoint));

    // Empty rect never intersects
    const r_empty = Rect.init(15, 15, 0, 0);
    try testing.expect(!r1.intersects(r_empty));
}

test "tui: Rect union and intersection" {
    const r1 = Rect.init(10, 10, 50, 50);
    const r2 = Rect.init(30, 30, 50, 50);

    const u = r1.unionRect(r2);
    try testing.expectEqual(@as(u32, 10), u.x);
    try testing.expectEqual(@as(u32, 10), u.y);
    try testing.expectEqual(@as(u32, 70), u.w);
    try testing.expectEqual(@as(u32, 70), u.h);

    const isect = r1.intersection(r2).?;
    try testing.expectEqual(@as(u32, 30), isect.x);
    try testing.expectEqual(@as(u32, 30), isect.y);
    try testing.expectEqual(@as(u32, 30), isect.w);
    try testing.expectEqual(@as(u32, 30), isect.h);

    const r_disjoint = Rect.init(200, 200, 10, 10);
    try testing.expect(r1.intersection(r_disjoint) == null);

    // Union with empty rect returns non-empty rect
    const empty = Rect.init(0, 0, 0, 0);
    try testing.expectEqual(r1, r1.unionRect(empty));
    try testing.expectEqual(r1, empty.unionRect(r1));
}

test "tui: Rect cell coordinate conversion" {
    const r = Rect.init(16, 24, 32, 40);
    const cell_rect = r.toCellRect();
    try testing.expectEqual(@as(u32, 2), cell_rect.x);
    try testing.expectEqual(@as(u32, 3), cell_rect.y);
    try testing.expectEqual(@as(u32, 4), cell_rect.w);
    try testing.expectEqual(@as(u32, 5), cell_rect.h);

    const bounds = r.toCellBounds();
    try testing.expectEqual(@as(u32, 2), bounds.col);
    try testing.expectEqual(@as(u32, 3), bounds.row);
    try testing.expectEqual(@as(u32, 4), bounds.cols);
    try testing.expectEqual(@as(u32, 5), bounds.rows);

    const from_cells = Rect.fromCells(2, 3, 4, 5);
    try testing.expectEqual(@as(u32, 16), from_cells.x);
    try testing.expectEqual(@as(u32, 24), from_cells.y);
    try testing.expectEqual(@as(u32, 32), from_cells.w);
    try testing.expectEqual(@as(u32, 40), from_cells.h);
}

test "tui: DamageTracker dirty region tracking and clear" {
    var dt = DamageTracker.init();
    try testing.expect(dt.isDirty(Rect.init(0, 0, 10, 10)));
    try testing.expect(dt.hasDamage());

    dt.clear();
    try testing.expect(!dt.isDirty(Rect.init(0, 0, 10, 10)));
    try testing.expect(!dt.hasDamage());

    dt.addDamage(Rect.init(100, 100, 50, 50));
    try testing.expect(dt.isDirty(Rect.init(120, 120, 10, 10)));
    try testing.expect(!dt.isDirty(Rect.init(0, 0, 10, 10)));

    dt.addDamage(Rect.init(0, 0, 10, 10));
    try testing.expect(dt.isDirty(Rect.init(0, 0, 10, 10)));
    try testing.expect(dt.isDirty(Rect.init(120, 120, 10, 10)));

    dt.markAllDirty();
    try testing.expect(dt.isDirty(Rect.init(0, 0, 800, 600)));
    try testing.expect(dt.isDirty(Rect.init(400, 300, 10, 10)));
}

test "tui: DamageTracker zero dimension damage is ignored" {
    var dt = DamageTracker.init();
    dt.clear();

    dt.addDamage(Rect.init(50, 50, 0, 10));
    dt.addDamage(Rect.init(50, 50, 10, 0));
    try testing.expect(!dt.hasDamage());
    try testing.expect(!dt.isDirty(Rect.init(50, 50, 20, 20)));
}

// ============================================================================
// 3. Panel Component
// ============================================================================

test "tui: Panel initialization, title clamping, and innerRect" {
    var p = Panel.init(Rect.init(10, 10, 200, 150), "VM Manager (F2)");
    try testing.expectEqualStrings("VM Manager (F2)", p.getTitle());
    try testing.expect(!p.is_focused);

    p.setFocused(true);
    try testing.expect(p.is_focused);

    const inner = p.innerRect();
    try testing.expectEqual(@as(u32, 12), inner.x); // 10 + 2 (border)
    try testing.expectEqual(@as(u32, 30), inner.y); // 10 + 20 (header)
    try testing.expectEqual(@as(u32, 196), inner.w); // 200 - 4 (border * 2)
    try testing.expectEqual(@as(u32, 128), inner.h); // 150 - 20 (header) - 2 (border)

    try testing.expectEqual(@as(u32, 4), p.contentStartRow());
    try testing.expectEqual(@as(u32, 2), p.contentStartCol());
}

test "tui: Panel title truncation at 48 characters" {
    var p = Panel.init(Rect.init(0, 0, 300, 200), "01234567890123456789012345678901234567890123456789extra");
    try testing.expectEqual(@as(usize, 48), p.title_len);
    try testing.expectEqualStrings("012345678901234567890123456789012345678901234567", p.getTitle());
}

test "tui: Panel degenerate dimensions clamp innerRect to zero" {
    const tiny_p = Panel.init(Rect.init(0, 0, 4, 15), "Tiny");
    const inner = tiny_p.innerRect();
    try testing.expectEqual(@as(u32, 0), inner.w);
    try testing.expectEqual(@as(u32, 0), inner.h);
}

// ============================================================================
// 4. TextInput Component
// ============================================================================

test "tui: TextInput initial state, setText, and clear" {
    var ti = TextInput.init(Rect.init(0, 0, 200, 20), 31);
    try testing.expectEqualStrings("", ti.getText());
    try testing.expectEqual(@as(usize, 0), ti.cursor_pos);
    try testing.expectEqual(@as(usize, 0), ti.len);

    ti.setText("alpine-node-01");
    try testing.expectEqualStrings("alpine-node-01", ti.getText());
    try testing.expectEqual(@as(usize, 14), ti.cursor_pos);
    try testing.expectEqual(@as(usize, 14), ti.len);

    ti.clear();
    try testing.expectEqualStrings("", ti.getText());
    try testing.expectEqual(@as(usize, 0), ti.cursor_pos);
}

test "tui: TextInput cursor navigation and boundaries" {
    var ti = TextInput.init(Rect.init(0, 0, 200, 20), 10);
    ti.setText("abc");

    ti.cursorHome();
    try testing.expectEqual(@as(usize, 0), ti.cursor_pos);
    try testing.expect(!ti.moveCursorLeft()); // Clamps at 0

    try testing.expect(ti.moveCursorRight());
    try testing.expectEqual(@as(usize, 1), ti.cursor_pos);

    ti.cursorEnd();
    try testing.expectEqual(@as(usize, 3), ti.cursor_pos);
    try testing.expect(!ti.moveCursorRight()); // Clamps at len
}

test "tui: TextInput character insertion, shifting, and mid-string editing" {
    var ti = TextInput.init(Rect.init(0, 0, 200, 20), 10);
    ti.setFocused(true);

    _ = ti.handleKey(makeAscii('a'));
    _ = ti.handleKey(makeAscii('c'));
    try testing.expectEqualStrings("ac", ti.getText());

    _ = ti.handleKey(makeKey(.left));
    try testing.expectEqual(@as(usize, 1), ti.cursor_pos);

    _ = ti.handleKey(makeAscii('b'));
    try testing.expectEqualStrings("abc", ti.getText());
    try testing.expectEqual(@as(usize, 2), ti.cursor_pos);

    _ = ti.handleKey(makeKey(.home));
    try testing.expectEqual(@as(usize, 0), ti.cursor_pos);

    _ = ti.handleKey(makeKey(.delete));
    try testing.expectEqualStrings("bc", ti.getText());

    _ = ti.handleKey(makeKey(.end));
    _ = ti.handleKey(makeKey(.backspace));
    try testing.expectEqualStrings("b", ti.getText());
}

test "tui: TextInput max_len enforcement rejects extra characters" {
    var ti = TextInput.init(Rect.init(0, 0, 100, 20), 4);
    ti.setText("abcd");
    try testing.expectEqual(@as(usize, 4), ti.len);

    // 5th character rejected
    try testing.expect(!ti.insertChar('e'));
    try testing.expectEqualStrings("abcd", ti.getText());
    try testing.expectEqual(@as(usize, 4), ti.len);

    // Non-printable character rejected
    ti.clear();
    try testing.expect(!ti.insertChar(10));
    try testing.expect(!ti.insertChar(127));
    try testing.expectEqual(@as(usize, 0), ti.len);
}

test "tui: TextInput unfocused ignores input" {
    var ti = TextInput.init(Rect.init(0, 0, 100, 20), 10);
    ti.setFocused(false);

    try testing.expect(!ti.handleKey(makeAscii('a')));
    try testing.expect(!ti.handleKey(makeKey(.left)));
    try testing.expectEqualStrings("", ti.getText());
}

// ============================================================================
// 5. NumberSpinner Component
// ============================================================================

test "tui: NumberSpinner stepping, clamping, and direct typing" {
    var sp = NumberSpinner.init(Rect.init(0, 0, 100, 20), 2, 1, 4, 1, " cores");
    sp.setFocused(true);

    try testing.expectEqual(@as(u32, 2), sp.getValue());
    try testing.expectEqualStrings(" cores", sp.getSuffix());

    // Step up
    try testing.expect(sp.handleKey(makeKey(.right)));
    try testing.expectEqual(@as(u32, 3), sp.getValue());

    try testing.expect(sp.handleKey(makeKey(.up)));
    try testing.expectEqual(@as(u32, 4), sp.getValue());

    // Clamps at max
    try testing.expect(!sp.handleKey(makeKey(.right)));
    try testing.expectEqual(@as(u32, 4), sp.getValue());

    // Step down
    try testing.expect(sp.handleKey(makeKey(.left)));
    try testing.expectEqual(@as(u32, 3), sp.getValue());

    try testing.expect(sp.handleKey(makeKey(.down)));
    try testing.expectEqual(@as(u32, 2), sp.getValue());

    _ = sp.handleKey(makeKey(.down));
    try testing.expectEqual(@as(u32, 1), sp.getValue());

    // Clamps at min
    try testing.expect(!sp.handleKey(makeKey(.down)));
    try testing.expectEqual(@as(u32, 1), sp.getValue());

    // Direct digit typing
    try testing.expect(sp.handleKey(makeAscii('3')));
    try testing.expectEqual(@as(u32, 3), sp.getValue());

    // Typing out of range digit is rejected
    try testing.expect(!sp.handleKey(makeAscii('9')));
    try testing.expectEqual(@as(u32, 3), sp.getValue());
}

test "tui: NumberSpinner setValue clamping and init bounds check" {
    var sp = NumberSpinner.initSimple(1, 4, 10, 1);
    try testing.expectEqual(@as(u32, 4), sp.getValue()); // Clamped to max

    sp.setValue(100);
    try testing.expectEqual(@as(u32, 4), sp.getValue());

    sp.setValue(0);
    try testing.expectEqual(@as(u32, 1), sp.getValue());
}

// ============================================================================
// 6. OptionSelect Component
// ============================================================================

test "tui: OptionSelect cyclical option wrapping" {
    const opts = [_][]const u8{ "16 MB", "32 MB", "64 MB" };
    var os = OptionSelect.init(Rect.init(0, 0, 100, 20), &opts, 0);
    os.setFocused(true);

    try testing.expectEqualStrings("16 MB", os.getSelected());
    try testing.expectEqual(@as(usize, 0), os.getSelectedIndex());

    try testing.expect(os.handleKey(makeKey(.right)));
    try testing.expectEqualStrings("32 MB", os.getSelected());

    try testing.expect(os.handleKey(makeKey(.right)));
    try testing.expectEqualStrings("64 MB", os.getSelected());

    // Wraps forward to 0
    try testing.expect(os.handleKey(makeKey(.right)));
    try testing.expectEqualStrings("16 MB", os.getSelected());
    try testing.expectEqual(@as(usize, 0), os.getSelectedIndex());

    // Wraps backward to end
    try testing.expect(os.handleKey(makeKey(.left)));
    try testing.expectEqualStrings("64 MB", os.getSelected());
    try testing.expectEqual(@as(usize, 2), os.getSelectedIndex());
}

test "tui: OptionSelect single option and empty list edge cases" {
    const single = [_][]const u8{"OnlyOne"};
    var os_single = OptionSelect.initList(&single, 0);

    try testing.expect(!os_single.selectNext());
    try testing.expect(!os_single.selectPrev());
    try testing.expectEqualStrings("OnlyOne", os_single.getSelected());

    const empty: []const []const u8 = &.{};
    var os_empty = OptionSelect.initList(empty, 0);
    try testing.expect(!os_empty.selectNext());
    try testing.expect(!os_empty.selectPrev());
    try testing.expectEqualStrings("", os_empty.getSelected());
}

// ============================================================================
// 7. ListView Component
// ============================================================================

test "tui: ListView selection, viewport scroll tracking, and page jumping" {
    var lv = ListView.init(Rect.init(0, 0, 200, 100), 3); // 3 visible rows
    lv.setItemCount(6);
    lv.setFocused(true);

    try testing.expectEqual(@as(usize, 0), lv.getSelectedIndex());
    try testing.expectEqual(@as(usize, 0), lv.top_idx);
    try testing.expect(lv.isRowVisible(0));
    try testing.expect(lv.isRowVisible(2));
    try testing.expect(!lv.isRowVisible(3));

    // Move within viewport
    try testing.expect(lv.handleKey(makeKey(.down)));
    try testing.expectEqual(@as(usize, 1), lv.getSelectedIndex());
    try testing.expectEqual(@as(usize, 0), lv.top_idx);

    try testing.expect(lv.handleKey(makeKey(.down)));
    try testing.expectEqual(@as(usize, 2), lv.getSelectedIndex());
    try testing.expectEqual(@as(usize, 0), lv.top_idx);

    // Scroll down: moves top_idx
    try testing.expect(lv.handleKey(makeKey(.down)));
    try testing.expectEqual(@as(usize, 3), lv.getSelectedIndex());
    try testing.expectEqual(@as(usize, 1), lv.top_idx);
    try testing.expect(lv.isRowVisible(3));
    try testing.expect(!lv.isRowVisible(0));

    // End jump
    try testing.expect(lv.handleKey(makeKey(.end)));
    try testing.expectEqual(@as(usize, 5), lv.getSelectedIndex());
    try testing.expectEqual(@as(usize, 3), lv.top_idx); // 6 - 3 = 3

    // Clamps at bottom
    try testing.expect(!lv.handleKey(makeKey(.down)));

    // Home jump
    try testing.expect(lv.handleKey(makeKey(.home)));
    try testing.expectEqual(@as(usize, 0), lv.getSelectedIndex());
    try testing.expectEqual(@as(usize, 0), lv.top_idx);

    // Clamps at top
    try testing.expect(!lv.handleKey(makeKey(.up)));

    // Page down jump
    try testing.expect(lv.handleKey(makeKey(.page_down)));
    try testing.expectEqual(@as(usize, 3), lv.getSelectedIndex());
    try testing.expectEqual(@as(usize, 1), lv.top_idx);

    // Page up jump
    try testing.expect(lv.handleKey(makeKey(.page_up)));
    try testing.expectEqual(@as(usize, 0), lv.getSelectedIndex());
    try testing.expectEqual(@as(usize, 0), lv.top_idx);
}

test "tui: ListView empty list and shrinking count clamping" {
    var lv = ListView.initWithRows(4);
    try testing.expect(!lv.moveDown());
    try testing.expect(!lv.moveUp());

    lv.setItemCount(8);
    lv.selectLast();
    try testing.expectEqual(@as(usize, 7), lv.getSelectedIndex());

    // Shrink count below selected index
    lv.setItemCount(3);
    try testing.expectEqual(@as(usize, 2), lv.getSelectedIndex());
}

// ============================================================================
// 8. Button Component
// ============================================================================

test "tui: Button activation on Enter, newline, and Space" {
    var btn = Button.init(Rect.init(0, 0, 100, 20), "CREATE");
    btn.setFocused(true);

    try testing.expect(!btn.is_pressed);

    // Enter
    try testing.expect(btn.handleKey(makeKey(.enter)));
    try testing.expect(btn.is_pressed);

    btn.setPressed(false);
    // Newline '\n'
    try testing.expect(btn.handleKey(makeAscii('\n')));
    try testing.expect(btn.is_pressed);

    btn.setPressed(false);
    // Space
    try testing.expect(btn.handleKey(makeAscii(' ')));
    try testing.expect(btn.is_pressed);

    // Unrelated keys do not activate
    btn.setPressed(false);
    try testing.expect(!btn.handleKey(makeKey(.tab)));
    try testing.expect(!btn.handleKey(makeKey(.escape)));
    try testing.expect(!btn.handleKey(makeAscii('x')));
    try testing.expect(!btn.is_pressed);

    // Disabled button ignores trigger
    btn.enabled = false;
    try testing.expect(!btn.handleKey(makeKey(.enter)));
    try testing.expect(!btn.is_pressed);

    // Loss of focus clears pressed
    btn.enabled = true;
    _ = btn.trigger();
    try testing.expect(btn.is_pressed);
    btn.setFocused(false);
    try testing.expect(!btn.is_pressed);
}

// ============================================================================
// 9. ModalDialog Component
// ============================================================================

test "tui: ModalDialog centering calculation and key trapping" {
    var modal = ModalDialog.initCentered(400, 300, 800, 600, "System Help (F1)");
    try testing.expectEqual(@as(u32, 200), modal.rect.x);
    try testing.expectEqual(@as(u32, 150), modal.rect.y);
    try testing.expectEqual(@as(u32, 400), modal.rect.w);
    try testing.expectEqual(@as(u32, 300), modal.rect.h);
    try testing.expectEqualStrings("System Help (F1)", modal.getTitle());
    try testing.expect(!modal.isOpen());

    // When closed, events pass through
    try testing.expect(!modal.handleKey(makeKey(.escape)));
    try testing.expect(!modal.handleKey(makeAscii('a')));

    // Open dialog
    modal.open();
    try testing.expect(modal.isOpen());

    // Traps arbitrary keys without closing
    try testing.expect(modal.handleKey(makeAscii('x')));
    try testing.expect(modal.isOpen());

    try testing.expect(modal.handleKey(makeKey(.down)));
    try testing.expect(modal.isOpen());

    // Dismisses on Escape
    try testing.expect(modal.handleKey(makeKey(.escape)));
    try testing.expect(!modal.isOpen());

    // Reopen and dismiss on 'q'
    modal.open();
    try testing.expect(modal.handleKey(makeAscii('q')));
    try testing.expect(!modal.isOpen());

    // Reopen and dismiss on F1
    modal.open();
    try testing.expect(modal.handleKey(makeKey(.f1)));
    try testing.expect(!modal.isOpen());
}

test "tui: ModalDialog dimension clamping when larger than screen" {
    const modal = ModalDialog.initCentered(1000, 800, 800, 600, "Oversized");
    try testing.expectEqual(@as(u32, 800), modal.rect.w);
    try testing.expectEqual(@as(u32, 600), modal.rect.h);
    try testing.expectEqual(@as(u32, 0), modal.rect.x);
    try testing.expectEqual(@as(u32, 0), modal.rect.y);
}

// ============================================================================
// 10. Duck-Typed Mock Surface Rendering
// ============================================================================

const MockSurface = struct {
    fill_count: usize = 0,
    text_count: usize = 0,
    last_fill_color: u32 = 0,
    last_text_color: u32 = 0,

    pub fn fillRect(self: *MockSurface, x: u32, y: u32, w: u32, h: u32, fill_color: u32) void {
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        self.fill_count += 1;
        self.last_fill_color = fill_color;
    }

    pub fn drawText(self: *MockSurface, row: u32, col: u32, fg: u32, bg: u32, text: []const u8) void {
        _ = row;
        _ = col;
        _ = bg;
        _ = text;
        self.text_count += 1;
        self.last_text_color = fg;
    }
};

test "tui: duck-typed mock surface rendering across widgets" {
    var surf = MockSurface{};

    // Panel render
    var panel = Panel.init(Rect.init(0, 0, 160, 80), "Test Panel");
    panel.render(&surf);
    try testing.expect(surf.fill_count > 0);
    try testing.expect(surf.text_count > 0);

    // TextInput render
    var input = TextInput.init(Rect.init(10, 10, 80, 20), 16);
    input.setText("hello");
    surf.fill_count = 0;
    surf.text_count = 0;
    input.render(&surf);
    try testing.expect(surf.fill_count > 0);
    try testing.expect(surf.text_count > 0);

    // NumberSpinner render
    var spinner = NumberSpinner.init(Rect.init(10, 40, 80, 20), 2, 1, 4, 1, " vCPU");
    surf.fill_count = 0;
    surf.text_count = 0;
    spinner.render(&surf);
    try testing.expect(surf.fill_count > 0);
    try testing.expect(surf.text_count > 0);

    // OptionSelect render
    const opts = [_][]const u8{ "opt1", "opt2" };
    var opt_sel = OptionSelect.init(Rect.init(10, 70, 80, 20), &opts, 0);
    surf.fill_count = 0;
    surf.text_count = 0;
    opt_sel.render(&surf);
    try testing.expect(surf.fill_count > 0);
    try testing.expect(surf.text_count > 0);

    // Button render
    var btn = Button.init(Rect.init(10, 100, 80, 20), "OK");
    surf.fill_count = 0;
    surf.text_count = 0;
    btn.render(&surf);
    try testing.expect(surf.fill_count > 0);
    try testing.expect(surf.text_count > 0);

    // ModalDialog render
    var modal = ModalDialog.init(Rect.init(50, 50, 200, 150), "Dialog");
    modal.open();
    surf.fill_count = 0;
    surf.text_count = 0;
    modal.render(&surf);
    try testing.expect(surf.fill_count > 0);
    try testing.expect(surf.text_count > 0);
}

test "tui: NumberSpinner arithmetic overflow and underflow protection" {
    // 1. Boundary check near maxInt(u32): value = maxInt - 1, step = 2, max = maxInt
    var sp_max = NumberSpinner.init(
        Rect.init(0, 0, 100, 20),
        std.math.maxInt(u32) - 1,
        0,
        std.math.maxInt(u32),
        2,
        "",
    );
    // Must clamp to max without panic
    try testing.expect(sp_max.stepUp());
    try testing.expectEqual(std.math.maxInt(u32), sp_max.getValue());
    // Subsequent step returns false
    try testing.expect(!sp_max.stepUp());
    try testing.expectEqual(std.math.maxInt(u32), sp_max.getValue());

    // 2. Step size larger than remaining headroom
    var sp_huge = NumberSpinner.init(
        Rect.init(0, 0, 100, 20),
        10,
        0,
        50,
        std.math.maxInt(u32),
        "",
    );
    try testing.expect(sp_huge.stepUp());
    try testing.expectEqual(@as(u32, 50), sp_huge.getValue());
    try testing.expect(!sp_huge.stepUp());

    // 3. Boundary check near min: value = 1, step = 5, min = 0
    var sp_min = NumberSpinner.init(
        Rect.init(0, 0, 100, 20),
        1,
        0,
        100,
        5,
        "",
    );
    try testing.expect(sp_min.stepDown());
    try testing.expectEqual(@as(u32, 0), sp_min.getValue());
    try testing.expect(!sp_min.stepDown());
    try testing.expectEqual(@as(u32, 0), sp_min.getValue());

    // 4. Step down with huge step size
    var sp_huge_down = NumberSpinner.init(
        Rect.init(0, 0, 100, 20),
        100,
        10,
        500,
        std.math.maxInt(u32),
        "",
    );
    try testing.expect(sp_huge_down.stepDown());
    try testing.expectEqual(@as(u32, 10), sp_huge_down.getValue());
    try testing.expect(!sp_huge_down.stepDown());
}

test "tui: ListView empty list and partial viewport visibility invariants" {
    // 1. Empty list: no row must ever be reported as visible
    var lv = ListView.initWithRows(5);
    try testing.expectEqual(@as(usize, 0), lv.item_count);
    var idx: usize = 0;
    while (idx < 10) : (idx += 1) {
        try testing.expect(!lv.isRowVisible(idx));
    }

    // 2. Short list (2 items, 5 visible rows)
    lv.setItemCount(2);
    try testing.expect(lv.isRowVisible(0));
    try testing.expect(lv.isRowVisible(1));
    // Rows 2..4 are within viewport height but outside item_count
    try testing.expect(!lv.isRowVisible(2));
    try testing.expect(!lv.isRowVisible(3));
    try testing.expect(!lv.isRowVisible(4));
    try testing.expect(!lv.isRowVisible(5));

    // 3. Viewport scroll tracking with active items
    lv.setItemCount(10);
    lv.top_idx = 3; // rows 3..7 visible
    try testing.expect(!lv.isRowVisible(2)); // above viewport
    try testing.expect(lv.isRowVisible(3));
    try testing.expect(lv.isRowVisible(7));
    try testing.expect(!lv.isRowVisible(8)); // below viewport
    try testing.expect(!lv.isRowVisible(10)); // beyond item_count
}

test "tui: TextInput MAX_TEXT_INPUT_LEN full capacity and null terminator safety" {
    // 1. Capacity initialized to MAX_TEXT_INPUT_LEN (64)
    var ti = TextInput.init(Rect.init(0, 0, 200, 20), MAX_TEXT_INPUT_LEN);
    try testing.expectEqual(MAX_TEXT_INPUT_LEN, ti.max_len);

    // 2. Insert 64 characters
    var i: usize = 0;
    while (i < MAX_TEXT_INPUT_LEN) : (i += 1) {
        const ok = ti.insertChar('A' + @as(u8, @intCast(i % 26)));
        try testing.expect(ok);
    }
    try testing.expectEqual(MAX_TEXT_INPUT_LEN, ti.len);
    try testing.expectEqual(MAX_TEXT_INPUT_LEN, ti.cursor_pos);
    try testing.expectEqual(MAX_TEXT_INPUT_LEN, ti.getText().len);

    // 3. Verify null terminator at index 64 without overrun
    try testing.expectEqual(@as(u8, 0), ti.buffer[MAX_TEXT_INPUT_LEN]);

    // 4. 65th character must be rejected safely
    try testing.expect(!ti.insertChar('!'));
    try testing.expectEqual(MAX_TEXT_INPUT_LEN, ti.len);

    // 5. setText with full 64-character string
    const text_64 = "1234567890123456789012345678901234567890123456789012345678901234";
    try testing.expectEqual(@as(usize, 64), text_64.len);
    ti.setText(text_64);
    try testing.expectEqual(@as(usize, 64), ti.len);
    try testing.expectEqualStrings(text_64, ti.getText());
    try testing.expectEqual(@as(u8, 0), ti.buffer[64]);

    // 6. Struct literal initialization with max_len = 64
    var ti_struct = TextInput{
        .rect = Rect.init(0, 0, 100, 20),
        .max_len = MAX_TEXT_INPUT_LEN,
    };
    ti_struct.setText(text_64);
    try testing.expectEqual(@as(usize, 64), ti_struct.len);
    try testing.expectEqualStrings(text_64, ti_struct.getText());
    try testing.expectEqual(@as(u8, 0), ti_struct.buffer[64]);
}

test "tui: Rect toCellRect and toCellBounds sub-cell offset spanning" {
    // 1. Rectangle starting at x = 7, y = 15 with w = 2, h = 3 spans:
    //    x: 7..9 -> cell 0 and cell 1 (cols = 2)
    //    y: 15..18 -> cell 1 and cell 2 (rows = 2)
    const r_span = Rect.init(7, 15, 2, 3);
    const bounds = r_span.toCellBounds();
    try testing.expectEqual(@as(u32, 0), bounds.col);
    try testing.expectEqual(@as(u32, 1), bounds.row);
    try testing.expectEqual(@as(u32, 2), bounds.cols);
    try testing.expectEqual(@as(u32, 2), bounds.rows);

    const cell_rect = r_span.toCellRect();
    try testing.expectEqual(@as(u32, 0), cell_rect.x);
    try testing.expectEqual(@as(u32, 1), cell_rect.y);
    try testing.expectEqual(@as(u32, 2), cell_rect.w);
    try testing.expectEqual(@as(u32, 2), cell_rect.h);

    // 2. Empty rectangles with sub-cell offsets must yield 0 cols and 0 rows
    const empty_w = Rect.init(7, 15, 0, 10);
    try testing.expectEqual(@as(u32, 0), empty_w.toCellBounds().cols);
    try testing.expectEqual(@as(u32, 0), empty_w.toCellRect().w);

    const empty_h = Rect.init(7, 15, 10, 0);
    try testing.expectEqual(@as(u32, 0), empty_h.toCellBounds().rows);
    try testing.expectEqual(@as(u32, 0), empty_h.toCellRect().h);
}
