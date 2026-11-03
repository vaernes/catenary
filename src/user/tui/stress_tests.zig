const std = @import("std");
const testing = std.testing;

const tui = @import("mod.zig");
const color = tui.color;
const geometry = tui.geometry;
const Rect = geometry.Rect;
const DamageTracker = geometry.DamageTracker;
const TextInput = tui.TextInput;
const NumberSpinner = tui.NumberSpinner;
const OptionSelect = tui.OptionSelect;
const ListView = tui.ListView;
const Button = tui.Button;
const ModalDialog = tui.ModalDialog;
const Panel = tui.Panel;

const inputd_proto = @import("../protocols/inputd_protocol.zig");
const InputEvent = inputd_proto.InputEvent;
const KeyCode = inputd_proto.KeyCode;

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

const MockSurface = struct {
    fill_calls: usize = 0,
    text_calls: usize = 0,

    pub fn fillRect(self: *MockSurface, x: u32, y: u32, w: u32, h: u32, c: u32) void {
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        _ = c;
        self.fill_calls += 1;
    }

    pub fn drawText(self: *MockSurface, row: u32, col: u32, fg: u32, bg: u32, text: []const u8) void {
        _ = row;
        _ = col;
        _ = fg;
        _ = bg;
        _ = text;
        self.text_calls += 1;
    }
};

// ============================================================================
// 1. TextInput Stress Tests
// ============================================================================

test "stress text_input: fill to 64 bytes and capacity boundary" {
    var ti = TextInput.init(Rect.init(0, 0, 160, 16), 64);
    // Capacity allows full MAX_TEXT_INPUT_LEN = 64 characters
    try testing.expectEqual(@as(usize, 64), ti.max_len);

    // Insert 64 ASCII characters
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const ok = ti.insertChar('A');
        try testing.expect(ok);
    }
    try testing.expectEqual(@as(usize, 64), ti.len);
    try testing.expectEqual(@as(usize, 64), ti.cursor_pos);
    try testing.expectEqual(@as(usize, 64), ti.getText().len);
    try testing.expectEqual(@as(u8, 0), ti.buffer[64]);

    // 65th insertion must be safely rejected without panicking
    const extra_ok = ti.insertChar('Z');
    try testing.expect(!extra_ok);
    try testing.expectEqual(@as(usize, 64), ti.len);

    // Verify handleKey also safely rejects on full buffer
    const evt_full = makeAscii('X');
    try testing.expect(!ti.handleKey(evt_full));

    // Verify render on full buffer does not overflow or panic
    var surface = MockSurface{};
    ti.render(&surface);
    try testing.expect(surface.fill_calls > 0);
    try testing.expect(surface.text_calls > 0);
}

test "stress text_input: setText with >= 64 bytes" {
    var ti = TextInput.init(Rect.init(0, 0, 160, 16), 64);
    const long_text = "01234567890123456789012345678901234567890123456789012345678901234567890123456789";
    try testing.expect(long_text.len > 64);

    ti.setText(long_text);
    try testing.expectEqual(@as(usize, 64), ti.len);
    try testing.expectEqual(@as(usize, 64), ti.cursor_pos);
    try testing.expectEqualStrings(long_text[0..64], ti.getText());
    try testing.expectEqual(@as(u8, 0), ti.buffer[64]);

    var surface = MockSurface{};
    ti.render(&surface);
}

test "stress text_input: delete and backspace at position 0" {
    var ti = TextInput.initWithCapacity(32);

    // Empty input: backspace at 0
    try testing.expect(!ti.deleteBackward());
    try testing.expect(!ti.handleKey(makeKey(.backspace)));
    try testing.expect(!ti.handleKey(makeAscii(0x08)));
    try testing.expectEqual(@as(usize, 0), ti.len);
    try testing.expectEqual(@as(usize, 0), ti.cursor_pos);

    // Empty input: delete at 0
    try testing.expect(!ti.deleteForward());
    try testing.expect(!ti.handleKey(makeKey(.delete)));
    try testing.expectEqual(@as(usize, 0), ti.len);
    try testing.expectEqual(@as(usize, 0), ti.cursor_pos);

    // Populate with text, then move cursor to position 0
    ti.setText("NornirOS");
    try testing.expectEqual(@as(usize, 8), ti.len);
    try testing.expectEqual(@as(usize, 8), ti.cursor_pos);

    ti.cursorHome();
    try testing.expectEqual(@as(usize, 0), ti.cursor_pos);

    // Backspace at position 0 must return false and not alter buffer
    try testing.expect(!ti.deleteBackward());
    try testing.expect(!ti.handleKey(makeKey(.backspace)));
    try testing.expectEqualStrings("NornirOS", ti.getText());
    try testing.expectEqual(@as(usize, 0), ti.cursor_pos);

    // Delete at position 0 deletes character 'N' and shifts remaining
    try testing.expect(ti.deleteForward());
    try testing.expectEqualStrings("ornirOS", ti.getText());
    try testing.expectEqual(@as(usize, 0), ti.cursor_pos);
    try testing.expectEqual(@as(usize, 7), ti.len);

    // Delete remaining characters one by one at pos 0 until empty
    while (ti.len > 0) {
        try testing.expect(ti.deleteForward());
        try testing.expectEqual(@as(usize, 0), ti.cursor_pos);
    }
    try testing.expectEqual(@as(usize, 0), ti.len);
    try testing.expectEqualStrings("", ti.getText());

    // Once empty, delete at 0 returns false again
    try testing.expect(!ti.deleteForward());
}

test "stress text_input: mid-string insertions and deletions" {
    var ti = TextInput.initWithCapacity(32);
    ti.setText("AC");
    ti.cursorHome();
    _ = ti.moveCursorRight(); // cursor is at 1 (between 'A' and 'C')

    // Insert 'B'
    _ = ti.insertChar('B');
    try testing.expectEqualStrings("ABC", ti.getText());
    try testing.expectEqual(@as(usize, 2), ti.cursor_pos);

    // Backspace mid-string: should delete 'B'
    _ = ti.deleteBackward();
    try testing.expectEqualStrings("AC", ti.getText());
    try testing.expectEqual(@as(usize, 1), ti.cursor_pos);

    // Delete mid-string: should delete 'C'
    _ = ti.deleteForward();
    try testing.expectEqualStrings("A", ti.getText());
    try testing.expectEqual(@as(usize, 1), ti.cursor_pos);

    // Repeated mid-string insertions
    ti.setText("start-end");
    ti.cursorHome();
    var step: usize = 0;
    while (step < 6) : (step += 1) {
        _ = ti.moveCursorRight();
    }
    // Cursor is after "start-"
    try testing.expectEqual(@as(usize, 6), ti.cursor_pos);

    const mid = "MIDDLE-";
    for (mid) |c| {
        try testing.expect(ti.insertChar(c));
    }
    try testing.expectEqualStrings("start-MIDDLE-end", ti.getText());
}

test "stress text_input: non-ASCII and control characters rejection" {
    var ti = TextInput.initWithCapacity(32);

    // Reject control characters (0..31 except backspace in handleKey)
    var c: u8 = 0;
    while (c < 32) : (c += 1) {
        if (c == 0x08) continue; // backspace handled separately
        try testing.expect(!ti.insertChar(c));
        try testing.expect(!ti.handleKey(makeAscii(c)));
    }

    // Reject DEL (127) and high-bit non-ASCII (128..255)
    var hi: u16 = 127;
    while (hi <= 255) : (hi += 1) {
        const byte = @as(u8, @intCast(hi));
        try testing.expect(!ti.insertChar(byte));
        try testing.expect(!ti.handleKey(makeAscii(byte)));
    }

    // Buffer remains completely untouched
    try testing.expectEqual(@as(usize, 0), ti.len);
    try testing.expectEqualStrings("", ti.getText());
}

// ============================================================================
// 2. NumberSpinner Stress Tests
// ============================================================================

test "stress spinner: step below min" {
    var sp = NumberSpinner.init(Rect.init(0, 0, 100, 16), 2, 2, 10, 1, " vCPUs");
    try testing.expectEqual(@as(u32, 2), sp.getValue());

    // Single stepDown at min returns false
    try testing.expect(!sp.stepDown());
    try testing.expectEqual(@as(u32, 2), sp.getValue());

    // 1,000 repeated stepDown calls must remain clamped at min and return false
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try testing.expect(!sp.stepDown());
        try testing.expect(!sp.handleKey(makeKey(.down)));
        try testing.expect(!sp.handleKey(makeKey(.left)));
    }
    try testing.expectEqual(@as(u32, 2), sp.getValue());
}

test "stress spinner: step above max" {
    var sp = NumberSpinner.init(Rect.init(0, 0, 100, 16), 8, 1, 8, 2, " vCPUs");
    try testing.expectEqual(@as(u32, 8), sp.getValue());

    // Single stepUp at max returns false
    try testing.expect(!sp.stepUp());
    try testing.expectEqual(@as(u32, 8), sp.getValue());

    // 1,000 repeated stepUp calls must remain clamped at max and return false
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try testing.expect(!sp.stepUp());
        try testing.expect(!sp.handleKey(makeKey(.up)));
        try testing.expect(!sp.handleKey(makeKey(.right)));
    }
    try testing.expectEqual(@as(u32, 8), sp.getValue());
}

test "stress spinner: step with step size > max" {
    // min = 1, max = 5, step = 100
    var sp = NumberSpinner.init(Rect.init(0, 0, 100, 16), 1, 1, 5, 100, "");
    try testing.expectEqual(@as(u32, 1), sp.getValue());

    // StepUp jumps directly to max (5) and returns true
    try testing.expect(sp.stepUp());
    try testing.expectEqual(@as(u32, 5), sp.getValue());

    // Second stepUp returns false
    try testing.expect(!sp.stepUp());
    try testing.expectEqual(@as(u32, 5), sp.getValue());

    // StepDown jumps directly to min (1) and returns true
    try testing.expect(sp.stepDown());
    try testing.expectEqual(@as(u32, 1), sp.getValue());

    // Second stepDown returns false
    try testing.expect(!sp.stepDown());
    try testing.expectEqual(@as(u32, 1), sp.getValue());
}

test "stress spinner: large step clamping without overflow" {
    // Normal operation with large step <= max - value
    var sp = NumberSpinner.init(Rect{}, 1, 1, 100, 50, "");
    try testing.expect(sp.stepUp());
    try testing.expectEqual(@as(u32, 51), sp.getValue());
    try testing.expect(sp.stepUp());
    try testing.expectEqual(@as(u32, 100), sp.getValue());
}

test "stress spinner: arithmetic overflow boundary protection" {
    // 1. stepUp near maxInt(u32)
    var sp_max = NumberSpinner.init(Rect{}, std.math.maxInt(u32) - 1, 0, std.math.maxInt(u32), 2, "");
    try testing.expect(sp_max.stepUp());
    try testing.expectEqual(std.math.maxInt(u32), sp_max.getValue());
    try testing.expect(!sp_max.stepUp());
    try testing.expectEqual(std.math.maxInt(u32), sp_max.getValue());

    // 2. stepDown near maxInt(u32) with large min and step
    var sp_min = NumberSpinner.init(Rect{}, std.math.maxInt(u32), std.math.maxInt(u32) - 5, std.math.maxInt(u32), 10, "");
    try testing.expect(sp_min.stepDown());
    try testing.expectEqual(std.math.maxInt(u32) - 5, sp_min.getValue());
    try testing.expect(!sp_min.stepDown());
    try testing.expectEqual(std.math.maxInt(u32) - 5, sp_min.getValue());

    // 3. stepDown near 0
    var sp_zero = NumberSpinner.init(Rect{}, 1, 0, 10, 5, "");
    try testing.expect(sp_zero.stepDown());
    try testing.expectEqual(@as(u32, 0), sp_zero.getValue());
    try testing.expect(!sp_zero.stepDown());
}

test "stress spinner: rapid alternating keys 10,000 iterations" {
    var sp = NumberSpinner.initSimple(1, 16, 1, 1);
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        if (i % 2 == 0) {
            _ = sp.handleKey(makeKey(.up));
        } else {
            _ = sp.handleKey(makeKey(.down));
        }
        try testing.expect(sp.getValue() >= 1);
        try testing.expect(sp.getValue() <= 16);
    }
}

test "stress spinner: digit typing boundaries" {
    var sp = NumberSpinner.initSimple(2, 6, 4, 1);

    // Digit below min (e.g. '0' or '1') rejected
    try testing.expect(!sp.handleKey(makeAscii('0')));
    try testing.expect(!sp.handleKey(makeAscii('1')));
    try testing.expectEqual(@as(u32, 4), sp.getValue());

    // Digit above max (e.g. '7', '8', '9') rejected
    try testing.expect(!sp.handleKey(makeAscii('7')));
    try testing.expect(!sp.handleKey(makeAscii('9')));
    try testing.expectEqual(@as(u32, 4), sp.getValue());

    // Same digit returns false (no change)
    try testing.expect(!sp.handleKey(makeAscii('4')));
    try testing.expectEqual(@as(u32, 4), sp.getValue());

    // Valid digit changes value
    try testing.expect(sp.handleKey(makeAscii('2')));
    try testing.expectEqual(@as(u32, 2), sp.getValue());
    try testing.expect(sp.handleKey(makeAscii('6')));
    try testing.expectEqual(@as(u32, 6), sp.getValue());
}

// ============================================================================
// 3. OptionSelect Stress Tests
// ============================================================================

test "stress option_select: empty option list" {
    var os = OptionSelect.initList(&.{}, 0);
    try testing.expectEqual(@as(usize, 0), os.option_count);
    try testing.expectEqual(@as(usize, 0), os.getSelectedIndex());
    try testing.expectEqualStrings("", os.getSelected());

    // Navigation calls must return false and not crash
    try testing.expect(!os.selectNext());
    try testing.expect(!os.selectPrev());
    try testing.expect(!os.handleKey(makeKey(.down)));
    try testing.expect(!os.handleKey(makeKey(.up)));
    try testing.expectEqual(@as(usize, 0), os.getSelectedIndex());
    try testing.expectEqualStrings("", os.getSelected());

    // setSelectedIndex must be safe on empty
    os.setSelectedIndex(10);
    try testing.expectEqual(@as(usize, 0), os.getSelectedIndex());

    // Render must not panic
    var surface = MockSurface{};
    os.render(&surface);
    try testing.expect(surface.fill_calls > 0);
}

test "stress option_select: single option list" {
    const single = [_][]const u8{"OnlyOption"};
    var os = OptionSelect.initList(&single, 0);
    try testing.expectEqual(@as(usize, 1), os.option_count);
    try testing.expectEqual(@as(usize, 0), os.getSelectedIndex());
    try testing.expectEqualStrings("OnlyOption", os.getSelected());

    // Single option cannot step next or prev
    try testing.expect(!os.selectNext());
    try testing.expect(!os.selectPrev());
    try testing.expectEqual(@as(usize, 0), os.getSelectedIndex());
    try testing.expectEqualStrings("OnlyOption", os.getSelected());
}

test "stress option_select: wrapping forward and backward 100 times" {
    const items = [_][]const u8{ "Opt0", "Opt1", "Opt2" };
    var os = OptionSelect.initList(&items, 0);
    try testing.expectEqual(@as(usize, 3), os.option_count);

    // Wrap forward 100 times: (0 + 100) % 3 = 1 -> "Opt1"
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(os.selectNext());
    }
    try testing.expectEqual(@as(usize, 1), os.getSelectedIndex());
    try testing.expectEqualStrings("Opt1", os.getSelected());

    // Wrap backward 100 times: (1 - 100) % 3 = 0 -> "Opt0"
    i = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(os.selectPrev());
    }
    try testing.expectEqual(@as(usize, 0), os.getSelectedIndex());
    try testing.expectEqualStrings("Opt0", os.getSelected());

    // Without wrapping: verify stopping at ends
    os.wrap = false;
    os.setSelectedIndex(2);
    try testing.expect(!os.selectNext());
    try testing.expectEqual(@as(usize, 2), os.getSelectedIndex());

    os.setSelectedIndex(0);
    try testing.expect(!os.selectPrev());
    try testing.expectEqual(@as(usize, 0), os.getSelectedIndex());
}

// ============================================================================
// 4. ListView Stress Tests
// ============================================================================

test "stress list_view: zero items navigation clamping" {
    var lv = ListView.initWithRows(5);
    try testing.expectEqual(@as(usize, 0), lv.item_count);
    try testing.expectEqual(@as(usize, 0), lv.selected_idx);
    try testing.expectEqual(@as(usize, 0), lv.top_idx);

    // All navigation operations return false on empty list
    try testing.expect(!lv.moveUp());
    try testing.expect(!lv.moveDown());
    try testing.expect(!lv.pageUp());
    try testing.expect(!lv.pageDown());
    try testing.expect(!lv.moveHome());
    try testing.expect(!lv.moveEnd());
    try testing.expect(!lv.handleKey(makeKey(.up)));
    try testing.expect(!lv.handleKey(makeKey(.down)));
    try testing.expect(!lv.handleKey(makeKey(.page_up)));
    try testing.expect(!lv.handleKey(makeKey(.page_down)));

    // setSelectedIndex on empty
    lv.setSelectedIndex(10);
    try testing.expectEqual(@as(usize, 0), lv.selected_idx);
    try testing.expectEqual(@as(usize, 0), lv.top_idx);
}

test "stress list_view: zero items visibility defect reproduction" {
    var lv = ListView.initWithRows(5);
    // CHALLENGE RESOLVED: isRowVisible(idx) checks `idx < item_count`.
    // Consequently, when item_count == 0, rows return false (no phantom rows).
    try testing.expect(lv.isRowVisible(0) == false);
    try testing.expect(lv.isRowVisible(4) == false);
    try testing.expect(lv.isRowVisible(5) == false);

    // Short list test: 2 items with 5 visible rows
    lv.setItemCount(2);
    try testing.expect(lv.isRowVisible(0) == true);
    try testing.expect(lv.isRowVisible(1) == true);
    try testing.expect(lv.isRowVisible(2) == false);
    try testing.expect(lv.isRowVisible(4) == false);
    try testing.expect(lv.isRowVisible(5) == false);
}

test "stress list_view: 10,000 items and rapid page navigation" {
    var lv = ListView.initWithRows(10);
    lv.setItemCount(10000);
    try testing.expectEqual(@as(usize, 10000), lv.item_count);
    try testing.expectEqual(@as(usize, 0), lv.selected_idx);
    try testing.expectEqual(@as(usize, 0), lv.top_idx);

    // Rapid page down to end
    var pages: usize = 0;
    while (pages < 1500) : (pages += 1) {
        _ = lv.pageDown();
    }
    try testing.expectEqual(@as(usize, 9999), lv.selected_idx);
    try testing.expectEqual(@as(usize, 9990), lv.top_idx);
    try testing.expect(lv.isRowVisible(9999));
    try testing.expect(lv.isRowVisible(9990));
    try testing.expect(!lv.isRowVisible(9989));
    try testing.expect(!lv.isRowVisible(10000));

    // Repeated pageDown at bottom returns false
    try testing.expect(!lv.pageDown());

    // Rapid page up to start
    pages = 0;
    while (pages < 1500) : (pages += 1) {
        _ = lv.pageUp();
    }
    try testing.expectEqual(@as(usize, 0), lv.selected_idx);
    try testing.expectEqual(@as(usize, 0), lv.top_idx);
    try testing.expect(lv.isRowVisible(0));
    try testing.expect(lv.isRowVisible(9));
    try testing.expect(!lv.isRowVisible(10));

    // Repeated pageUp at top returns false
    try testing.expect(!lv.pageUp());

    // Test moveEnd and moveHome
    try testing.expect(lv.moveEnd());
    try testing.expectEqual(@as(usize, 9999), lv.selected_idx);
    try testing.expectEqual(@as(usize, 9990), lv.top_idx);

    try testing.expect(lv.moveHome());
    try testing.expectEqual(@as(usize, 0), lv.selected_idx);
    try testing.expectEqual(@as(usize, 0), lv.top_idx);
}

test "stress list_view: shrinking items while selected" {
    var lv = ListView.initWithRows(5);
    lv.setItemCount(100);
    lv.setSelectedIndex(95);
    try testing.expectEqual(@as(usize, 95), lv.selected_idx);

    // Shrink count to 50
    lv.setItemCount(50);
    try testing.expectEqual(@as(usize, 49), lv.selected_idx);
    try testing.expect(lv.selected_idx < lv.item_count);
    try testing.expect(lv.top_idx <= lv.selected_idx);

    // Shrink count to 10
    lv.setItemCount(10);
    try testing.expectEqual(@as(usize, 9), lv.selected_idx);
    try testing.expect(lv.selected_idx < lv.item_count);

    // Shrink count to 1
    lv.setItemCount(1);
    try testing.expectEqual(@as(usize, 0), lv.selected_idx);
    try testing.expectEqual(@as(usize, 0), lv.top_idx);

    // Shrink count to 0
    lv.setItemCount(0);
    try testing.expectEqual(@as(usize, 0), lv.selected_idx);
    try testing.expectEqual(@as(usize, 0), lv.top_idx);
}

// ============================================================================
// 5. DamageTracker Stress Tests
// ============================================================================

test "stress damage_tracker: 1000 non-overlapping rect additions" {
    var dt = DamageTracker.initWithBounds(Rect.init(0, 0, 10000, 10000));
    dt.clear();
    try testing.expect(!dt.hasDamage());

    // Add 1000 non-overlapping 10x10 rects
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const r = Rect.init(i * 20, 0, 10, 10);
        dt.addDamage(r);
        try testing.expect(dt.hasDamage());
        try testing.expect(dt.isDirty(r));
    }

    // Verify bounds encompass all damage
    const bb = dt.getBoundingBox().?;
    try testing.expect(bb.x == 0);
    try testing.expect(bb.w >= 1000 * 20 - 10);
}

// ============================================================================
// 6. Integrated Fuzz / Random Walk Stress Test (50,000 steps)
// ============================================================================

test "stress integrated: 50,000 random events across all widgets" {
    var prng = std.Random.DefaultPrng.init(0xCA7E_9A81);
    const rand = prng.random();

    var ti = TextInput.initWithCapacity(64);
    var sp = NumberSpinner.initSimple(1, 32, 1, 1);
    const opts = [_][]const u8{ "OptA", "OptB", "OptC", "OptD" };
    var os = OptionSelect.initList(&opts, 0);
    var lv = ListView.initWithRows(8);
    lv.setItemCount(500);

    const key_codes = [_]KeyCode{
        .none, .enter, .backspace, .tab, .escape,
        .up, .down, .left, .right, .page_up,
        .page_down, .home, .end, .delete,
    };

    var step: usize = 0;
    while (step < 50000) : (step += 1) {
        const is_ascii = rand.boolean();
        const evt = if (is_ascii)
            InputEvent{
                .event_type = .key_press,
                .ascii = rand.intRangeAtMost(u8, 0, 255),
                .scancode = 0,
                .key_code = .none,
                .modifiers = 0,
            }
        else
            InputEvent{
                .event_type = .key_press,
                .ascii = 0,
                .scancode = 0,
                .key_code = key_codes[rand.intRangeLessThan(usize, 0, key_codes.len)],
                .modifiers = 0,
            };

        // Feed event to all widgets
        _ = ti.handleKey(evt);
        _ = sp.handleKey(evt);
        _ = os.handleKey(evt);
        _ = lv.handleKey(evt);

        // Periodically shrink/grow listview
        if (step % 500 == 0) {
            const new_count = rand.intRangeAtMost(usize, 0, 1000);
            lv.setItemCount(new_count);
        }

        // Periodically render mock surface
        if (step % 2000 == 0) {
            var surface = MockSurface{};
            ti.render(&surface);
            sp.render(&surface);
            os.render(&surface);
        }

        // Assert invariants
        try testing.expect(ti.len <= ti.max_len);
        try testing.expect(ti.cursor_pos <= ti.len);
        try testing.expect(sp.getValue() >= sp.min and sp.getValue() <= sp.max);
        if (os.option_count > 0) {
            try testing.expect(os.getSelectedIndex() < os.option_count);
        }
        if (lv.item_count > 0) {
            try testing.expect(lv.getSelectedIndex() < lv.item_count);
            try testing.expect(lv.top_idx <= lv.selected_idx);
        }
    }
}
