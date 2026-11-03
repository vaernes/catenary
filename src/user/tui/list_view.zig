const std = @import("std");
const color = @import("color.zig");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const inputd_proto = @import("../protocols/inputd_protocol.zig");
const InputEvent = inputd_proto.InputEvent;
const KeyCode = inputd_proto.KeyCode;

pub const ListView = struct {
    rect: Rect = .{},
    item_count: usize = 0,
    selected_idx: usize = 0,
    visible_rows: usize = 7,
    top_idx: usize = 0,
    is_focused: bool = true,

    pub fn init(rect: Rect, visible_rows: usize) ListView {
        return .{
            .rect = rect,
            .visible_rows = if (visible_rows == 0) 1 else visible_rows,
        };
    }

    pub fn initWithRows(visible_rows: usize) ListView {
        return init(Rect{}, visible_rows);
    }

    pub fn setItemCount(self: *ListView, count: usize) void {
        self.item_count = count;
        if (count == 0) {
            self.selected_idx = 0;
            self.top_idx = 0;
        } else if (self.selected_idx >= count) {
            self.selected_idx = count - 1;
            self.syncScroll();
        } else {
            self.syncScroll();
        }
    }

    pub fn getSelectedIndex(self: ListView) usize {
        return self.selected_idx;
    }

    pub fn getSelectedItemIndex(self: ListView) ?usize {
        if (self.item_count == 0) return null;
        return self.selected_idx;
    }

    pub fn setSelectedIndex(self: *ListView, idx: usize) void {
        if (self.item_count == 0) {
            self.selected_idx = 0;
            self.top_idx = 0;
            return;
        }
        self.selected_idx = @min(idx, self.item_count - 1);
        self.syncScroll();
    }

    pub fn moveUp(self: *ListView) bool {
        if (self.item_count == 0 or self.selected_idx == 0) return false;
        self.selected_idx -= 1;
        self.syncScroll();
        return true;
    }

    pub fn selectPrev(self: *ListView) bool {
        return self.moveUp();
    }

    pub fn moveDown(self: *ListView) bool {
        if (self.item_count == 0 or self.selected_idx >= self.item_count - 1) return false;
        self.selected_idx += 1;
        self.syncScroll();
        return true;
    }

    pub fn selectNext(self: *ListView) bool {
        return self.moveDown();
    }

    pub fn pageUp(self: *ListView) bool {
        if (self.item_count == 0 or self.selected_idx == 0) return false;
        const vrows = if (self.visible_rows == 0) 1 else self.visible_rows;
        if (self.selected_idx >= vrows) {
            self.selected_idx -= vrows;
        } else {
            self.selected_idx = 0;
        }
        self.syncScroll();
        return true;
    }

    pub fn pageDown(self: *ListView) bool {
        if (self.item_count == 0 or self.selected_idx >= self.item_count - 1) return false;
        const vrows = if (self.visible_rows == 0) 1 else self.visible_rows;
        if (self.item_count - self.selected_idx > vrows) {
            self.selected_idx += vrows;
        } else {
            self.selected_idx = self.item_count - 1;
        }
        self.syncScroll();
        return true;
    }

    pub fn moveHome(self: *ListView) bool {
        if (self.item_count == 0 or self.selected_idx == 0) return false;
        self.selected_idx = 0;
        self.syncScroll();
        return true;
    }

    pub fn selectFirst(self: *ListView) void {
        _ = self.moveHome();
    }

    pub fn moveEnd(self: *ListView) bool {
        if (self.item_count == 0 or self.selected_idx == self.item_count - 1) return false;
        self.selected_idx = self.item_count - 1;
        self.syncScroll();
        return true;
    }

    pub fn selectLast(self: *ListView) void {
        _ = self.moveEnd();
    }

    pub fn syncScroll(self: *ListView) void {
        if (self.item_count == 0) {
            self.top_idx = 0;
            return;
        }
        const vrows = if (self.visible_rows == 0) 1 else self.visible_rows;
        if (self.selected_idx < self.top_idx) {
            self.top_idx = self.selected_idx;
        } else if (self.selected_idx - self.top_idx >= vrows) {
            self.top_idx = self.selected_idx - vrows + 1;
        }
        if (self.item_count > vrows) {
            const max_top = self.item_count - vrows;
            if (self.top_idx > max_top) self.top_idx = max_top;
        } else {
            self.top_idx = 0;
        }
    }

    pub fn isRowVisible(self: ListView, idx: usize) bool {
        if (idx >= self.item_count) return false;
        const vrows = if (self.visible_rows == 0) 1 else self.visible_rows;
        return idx >= self.top_idx and (idx - self.top_idx) < vrows;
    }

    pub fn setFocused(self: *ListView, focused: bool) void {
        self.is_focused = focused;
    }

    pub fn handleKey(self: *ListView, evt: InputEvent) bool {
        if (!self.is_focused) return false;

        if (evt.key_code == .up) return self.moveUp();
        if (evt.key_code == .down) return self.moveDown();
        if (evt.key_code == .page_up) return self.pageUp();
        if (evt.key_code == .page_down) return self.pageDown();
        if (evt.key_code == .home) return self.moveHome();
        if (evt.key_code == .end) return self.moveEnd();
        return false;
    }
};
