const std = @import("std");

pub const Point = struct {
    x: u32 = 0,
    y: u32 = 0,
};

pub const CellBounds = struct {
    col: u32 = 0,
    row: u32 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
};

pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn init(x: u32, y: u32, w: u32, h: u32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn fromCells(col: u32, row: u32, cols: u32, rows: u32) Rect {
        return .{
            .x = col * 8,
            .y = row * 8,
            .w = cols * 8,
            .h = rows * 8,
        };
    }

    pub fn right(self: Rect) u32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) u32 {
        return self.y + self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w == 0 or self.h == 0;
    }

    pub fn contains(self: Rect, px: u32, py: u32) bool {
        if (self.isEmpty()) return false;
        return px >= self.x and px < self.right() and
            py >= self.y and py < self.bottom();
    }

    pub fn containsPoint(self: Rect, pt: Point) bool {
        return self.contains(pt.x, pt.y);
    }

    pub fn containsXY(self: Rect, px: u32, py: u32) bool {
        return self.contains(px, py);
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        if (self.isEmpty() or other.isEmpty()) return false;
        return self.x < other.right() and self.right() > other.x and
            self.y < other.bottom() and self.bottom() > other.y;
    }

    pub fn adjacent(self: Rect, other: Rect) bool {
        if (self.isEmpty() or other.isEmpty()) return false;
        const touching_x = (self.right() == other.x or other.right() == self.x) and
            (self.y < other.bottom() and self.bottom() > other.y);
        const touching_y = (self.bottom() == other.y or other.bottom() == self.y) and
            (self.x < other.right() and self.right() > other.x);
        return touching_x or touching_y;
    }

    pub fn unionRect(self: Rect, other: Rect) Rect {
        if (self.isEmpty()) return other;
        if (other.isEmpty()) return self;
        const min_x = @min(self.x, other.x);
        const min_y = @min(self.y, other.y);
        const max_x = @max(self.right(), other.right());
        const max_y = @max(self.bottom(), other.bottom());
        return .{
            .x = min_x,
            .y = min_y,
            .w = max_x - min_x,
            .h = max_y - min_y,
        };
    }

    pub fn unionWith(self: Rect, other: Rect) Rect {
        return self.unionRect(other);
    }

    pub fn intersection(self: Rect, other: Rect) ?Rect {
        if (!self.intersects(other)) return null;
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.right(), other.right());
        const y2 = @min(self.bottom(), other.bottom());
        if (x2 <= x1 or y2 <= y1) return null;
        return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
    }

    pub fn toCellRect(self: Rect) Rect {
        const b = self.toCellBounds();
        return .{ .x = b.col, .y = b.row, .w = b.cols, .h = b.rows };
    }

    pub fn toCellBounds(self: Rect) CellBounds {
        if (self.isEmpty()) return .{
            .col = self.x / 8,
            .row = self.y / 8,
            .cols = 0,
            .rows = 0,
        };
        const col = self.x / 8;
        const row = self.y / 8;
        const end_col = (self.right() + 7) / 8;
        const end_row = (self.bottom() + 7) / 8;
        return .{
            .col = col,
            .row = row,
            .cols = if (end_col > col) end_col - col else 0,
            .rows = if (end_row > row) end_row - row else 0,
        };
    }
};

pub const MAX_DAMAGE_RECTS: usize = 32;

pub const DamageTracker = struct {
    dirty_bounds: ?Rect = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 },
    is_all_dirty: bool = true,
    rects: [MAX_DAMAGE_RECTS]Rect = undefined,
    count: usize = 0,
    rect_count: usize = 0,
    screen_bounds: Rect = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 },

    pub fn init() DamageTracker {
        return .{
            .dirty_bounds = Rect{ .x = 0, .y = 0, .w = 800, .h = 600 },
            .is_all_dirty = true,
            .count = 0,
            .rect_count = 0,
        };
    }

    pub fn initWithBounds(screen_bounds: Rect) DamageTracker {
        return .{
            .dirty_bounds = screen_bounds,
            .is_all_dirty = true,
            .count = 0,
            .rect_count = 0,
            .screen_bounds = screen_bounds,
        };
    }

    pub fn clear(self: *DamageTracker) void {
        self.dirty_bounds = null;
        self.is_all_dirty = false;
        self.count = 0;
        self.rect_count = 0;
    }

    pub fn markAllDirty(self: *DamageTracker) void {
        self.is_all_dirty = true;
        self.dirty_bounds = self.screen_bounds;
        self.count = 0;
        self.rect_count = 0;
    }

    pub fn addDamage(self: *DamageTracker, rect: Rect) void {
        if (rect.isEmpty()) return;
        if (self.is_all_dirty) return;

        if (self.dirty_bounds) |cur| {
            self.dirty_bounds = cur.unionRect(rect);
        } else {
            self.dirty_bounds = rect;
        }

        for (self.rects[0..self.count]) |*existing| {
            if (existing.intersects(rect) or existing.adjacent(rect)) {
                existing.* = existing.unionRect(rect);
                return;
            }
        }

        if (self.count < MAX_DAMAGE_RECTS) {
            self.rects[self.count] = rect;
            self.count += 1;
            self.rect_count = self.count;
        } else {
            self.rects[0] = self.dirty_bounds.?;
            self.count = 1;
            self.rect_count = 1;
        }
    }

    pub fn isDirty(self: DamageTracker, rect: Rect) bool {
        if (rect.isEmpty()) return false;
        if (self.is_all_dirty) return true;
        const bounds = self.dirty_bounds orelse return false;
        if (!bounds.intersects(rect)) return false;
        if (self.count == 0) return true;
        for (self.rects[0..self.count]) |r| {
            if (r.intersects(rect)) return true;
        }
        return false;
    }

    pub fn getDirtyBounds(self: DamageTracker) ?Rect {
        if (self.is_all_dirty) return self.screen_bounds;
        return self.dirty_bounds;
    }

    pub fn getBoundingBox(self: DamageTracker) ?Rect {
        return self.getDirtyBounds();
    }

    pub fn hasDamage(self: DamageTracker) bool {
        return self.is_all_dirty or self.count > 0 or self.dirty_bounds != null;
    }

    pub fn getRects(self: DamageTracker) []const Rect {
        return self.rects[0..self.count];
    }
};
