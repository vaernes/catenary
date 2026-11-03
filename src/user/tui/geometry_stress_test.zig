const std = @import("std");
const testing = std.testing;
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const Point = geometry.Point;
const CellBounds = geometry.CellBounds;
const DamageTracker = geometry.DamageTracker;
const MAX_DAMAGE_RECTS = geometry.MAX_DAMAGE_RECTS;

// ============================================================================
// 1. Degenerate Rects Stress Tests
// ============================================================================

test "stress: degenerate rects basic properties" {
    const zero_w = Rect.init(10, 20, 0, 30);
    const zero_h = Rect.init(10, 20, 30, 0);
    const zero_both = Rect.init(10, 20, 0, 0);
    const zero_all = Rect.init(0, 0, 0, 0);

    try testing.expect(zero_w.isEmpty());
    try testing.expect(zero_h.isEmpty());
    try testing.expect(zero_both.isEmpty());
    try testing.expect(zero_all.isEmpty());

    // Degenerate rects contain no points
    try testing.expect(!zero_w.contains(10, 20));
    try testing.expect(!zero_h.contains(10, 20));
    try testing.expect(!zero_both.contains(10, 20));
    try testing.expect(!zero_all.contains(0, 0));

    try testing.expect(!zero_w.containsPoint(Point{ .x = 10, .y = 20 }));
    try testing.expect(!zero_h.containsPoint(Point{ .x = 10, .y = 20 }));
    try testing.expect(!zero_both.containsPoint(Point{ .x = 10, .y = 20 }));
    try testing.expect(!zero_all.containsPoint(Point{ .x = 0, .y = 0 }));

    // Degenerate rects never intersect anything
    const normal = Rect.init(0, 0, 100, 100);
    try testing.expect(!zero_w.intersects(normal));
    try testing.expect(!normal.intersects(zero_w));
    try testing.expect(!zero_h.intersects(normal));
    try testing.expect(!normal.intersects(zero_h));
    try testing.expect(!zero_both.intersects(normal));
    try testing.expect(!normal.intersects(zero_both));
    try testing.expect(!zero_all.intersects(zero_all));

    // Degenerate rects are never adjacent
    try testing.expect(!zero_w.adjacent(normal));
    try testing.expect(!normal.adjacent(zero_w));
    try testing.expect(!zero_h.adjacent(normal));
    try testing.expect(!normal.adjacent(zero_h));
    try testing.expect(!zero_all.adjacent(zero_all));

    // Intersection with degenerate rect is null
    try testing.expect(zero_w.intersection(normal) == null);
    try testing.expect(normal.intersection(zero_w) == null);
    try testing.expect(zero_both.intersection(zero_h) == null);

    // Union with degenerate rect yields the non-empty rect
    try testing.expectEqual(normal, normal.unionRect(zero_w));
    try testing.expectEqual(normal, zero_w.unionRect(normal));
    try testing.expectEqual(normal, normal.unionRect(zero_h));
    try testing.expectEqual(normal, zero_h.unionRect(normal));
    try testing.expectEqual(normal, normal.unionRect(zero_both));
    try testing.expectEqual(normal, zero_both.unionRect(normal));

    // Union of two degenerate rects yields an empty rect
    const u_zeros = zero_w.unionRect(zero_h);
    try testing.expect(u_zeros.isEmpty());
}

test "stress: DamageTracker ignores degenerate damage rects" {
    var dt = DamageTracker.init();
    dt.clear();
    try testing.expect(!dt.hasDamage());
    try testing.expectEqual(@as(?Rect, null), dt.getDirtyBounds());
    try testing.expectEqual(@as(usize, 0), dt.count);

    // Add various degenerate rects
    dt.addDamage(Rect.init(10, 10, 0, 100));
    try testing.expect(!dt.hasDamage());
    try testing.expectEqual(@as(usize, 0), dt.count);

    dt.addDamage(Rect.init(10, 10, 100, 0));
    try testing.expect(!dt.hasDamage());
    try testing.expectEqual(@as(usize, 0), dt.count);

    dt.addDamage(Rect.init(10, 10, 0, 0));
    try testing.expect(!dt.hasDamage());
    try testing.expectEqual(@as(usize, 0), dt.count);

    dt.addDamage(Rect.init(0, 0, 0, 0));
    try testing.expect(!dt.hasDamage());
    try testing.expectEqual(@as(usize, 0), dt.count);

    // Querying with degenerate rects always returns false
    try testing.expect(!dt.isDirty(Rect.init(0, 0, 0, 0)));
    try testing.expect(!dt.isDirty(Rect.init(10, 10, 0, 50)));
    try testing.expect(!dt.isDirty(Rect.init(10, 10, 50, 0)));

    // Now add valid damage and verify degenerate queries still return false
    dt.addDamage(Rect.init(0, 0, 100, 100));
    try testing.expect(dt.hasDamage());
    try testing.expect(dt.isDirty(Rect.init(10, 10, 10, 10)));
    try testing.expect(!dt.isDirty(Rect.init(10, 10, 0, 10)));
    try testing.expect(!dt.isDirty(Rect.init(10, 10, 10, 0)));
    try testing.expect(!dt.isDirty(Rect.init(10, 10, 0, 0)));

    // Even when all dirty, degenerate queries return false
    dt.markAllDirty();
    try testing.expect(dt.isDirty(Rect.init(0, 0, 10, 10)));
    try testing.expect(!dt.isDirty(Rect.init(0, 0, 0, 0)));
    try testing.expect(!dt.isDirty(Rect.init(10, 10, 0, 10)));
    try testing.expect(!dt.isDirty(Rect.init(10, 10, 10, 0)));
}

test "stress: overflowing screen coordinates in DamageTracker" {
    // Screen bounds 800x600
    var dt = DamageTracker.initWithBounds(Rect.init(0, 0, 800, 600));
    dt.clear();

    // Damage extending beyond right/bottom of screen bounds
    const overflow_rect = Rect.init(750, 550, 200, 200); // extends to 950, 750
    dt.addDamage(overflow_rect);

    try testing.expect(dt.hasDamage());
    const bounds = dt.getDirtyBounds().?;
    try testing.expectEqual(@as(u32, 750), bounds.x);
    try testing.expectEqual(@as(u32, 550), bounds.y);
    try testing.expectEqual(@as(u32, 200), bounds.w);
    try testing.expectEqual(@as(u32, 200), bounds.h);

    // Queries overlapping the damaged area outside standard screen
    try testing.expect(dt.isDirty(Rect.init(800, 600, 50, 50)));
    // Queries inside screen bounds that overlap the damaged region
    try testing.expect(dt.isDirty(Rect.init(780, 580, 10, 10)));
    // Disjoint query
    try testing.expect(!dt.isDirty(Rect.init(0, 0, 100, 100)));
}

test "stress: large coordinate bounds below u32 overflow threshold" {
    // Testing very large coordinates (up to millions of pixels, e.g. virtual canvas)
    const large1 = Rect.init(1_000_000, 2_000_000, 500_000, 500_000);
    const large2 = Rect.init(1_200_000, 2_200_000, 500_000, 500_000);

    try testing.expect(large1.intersects(large2));
    const isect = large1.intersection(large2).?;
    try testing.expectEqual(@as(u32, 1_200_000), isect.x);
    try testing.expectEqual(@as(u32, 2_200_000), isect.y);
    try testing.expectEqual(@as(u32, 300_000), isect.w);
    try testing.expectEqual(@as(u32, 300_000), isect.h);

    const union_large = large1.unionRect(large2);
    try testing.expectEqual(@as(u32, 1_000_000), union_large.x);
    try testing.expectEqual(@as(u32, 2_000_000), union_large.y);
    try testing.expectEqual(@as(u32, 700_000), union_large.w);
    try testing.expectEqual(@as(u32, 700_000), union_large.h);
}

test "stress: cell coordinate conversion on degenerate and boundary rects" {
    // Degenerate zero-dimension rects
    const z_rect = Rect.init(16, 24, 0, 0);
    const z_cells = z_rect.toCellRect();
    try testing.expectEqual(@as(u32, 2), z_cells.x);
    try testing.expectEqual(@as(u32, 3), z_cells.y);
    try testing.expectEqual(@as(u32, 0), z_cells.w); // (0 + 7) / 8 = 0
    try testing.expectEqual(@as(u32, 0), z_cells.h);

    const z_bounds = z_rect.toCellBounds();
    try testing.expectEqual(@as(u32, 2), z_bounds.col);
    try testing.expectEqual(@as(u32, 3), z_bounds.row);
    try testing.expectEqual(@as(u32, 0), z_bounds.cols);
    try testing.expectEqual(@as(u32, 0), z_bounds.rows);

    // 1-pixel rects must occupy 1 full cell
    const one_pixel = Rect.init(0, 0, 1, 1);
    const one_cells = one_pixel.toCellRect();
    try testing.expectEqual(@as(u32, 1), one_cells.w);
    try testing.expectEqual(@as(u32, 1), one_cells.h);

    // 7-pixel and 8-pixel and 9-pixel rects
    const r7 = Rect.init(0, 0, 7, 7).toCellRect();
    try testing.expectEqual(@as(u32, 1), r7.w);
    try testing.expectEqual(@as(u32, 1), r7.h);

    const r8 = Rect.init(0, 0, 8, 8).toCellRect();
    try testing.expectEqual(@as(u32, 1), r8.w);
    try testing.expectEqual(@as(u32, 1), r8.h);

    const r9 = Rect.init(0, 0, 9, 9).toCellRect();
    try testing.expectEqual(@as(u32, 2), r9.w);
    try testing.expectEqual(@as(u32, 2), r9.h);
}

// ============================================================================
// 2. Damage Coalescing (>32 Distinct Rects)
// ============================================================================

test "stress: damage coalescing at 32 and 33 distinct disjoint rects" {
    var dt = DamageTracker.init();
    dt.clear();

    // Add exactly 32 distinct disjoint rects along x axis:
    // rect 0: [0..10], gap [10..20], rect 1: [20..30], ..., rect 31: [620..630]
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const r = Rect.init(i * 20, 0, 10, 10);
        dt.addDamage(r);
        try testing.expectEqual(@as(usize, i + 1), dt.count);
        try testing.expectEqual(@as(usize, i + 1), dt.rect_count);
    }

    try testing.expectEqual(@as(usize, 32), dt.count);
    const bb32 = dt.getBoundingBox().?;
    try testing.expectEqual(@as(u32, 0), bb32.x);
    try testing.expectEqual(@as(u32, 0), bb32.y);
    try testing.expectEqual(@as(u32, 630), bb32.w);
    try testing.expectEqual(@as(u32, 10), bb32.h);

    // Verify all 32 rects are dirty
    i = 0;
    while (i < 32) : (i += 1) {
        try testing.expect(dt.isDirty(Rect.init(i * 20, 0, 10, 10)));
    }
    // Verify gaps are NOT dirty
    i = 0;
    while (i < 31) : (i += 1) {
        try testing.expect(!dt.isDirty(Rect.init(i * 20 + 10, 0, 10, 10)));
    }

    // Now add the 33rd distinct disjoint rect: [640..650]
    const r33 = Rect.init(640, 0, 10, 10);
    dt.addDamage(r33);

    // Buffer has coalesced to 1 bounding box rect
    try testing.expectEqual(@as(usize, 1), dt.count);
    try testing.expectEqual(@as(usize, 1), dt.rect_count);

    const bb33 = dt.getBoundingBox().?;
    try testing.expectEqual(@as(u32, 0), bb33.x);
    try testing.expectEqual(@as(u32, 0), bb33.y);
    try testing.expectEqual(@as(u32, 650), bb33.w);
    try testing.expectEqual(@as(u32, 10), bb33.h);

    // CRITICAL: Verify NO damage is missed for all 33 rects!
    i = 0;
    while (i < 32) : (i += 1) {
        try testing.expect(dt.isDirty(Rect.init(i * 20, 0, 10, 10)));
    }
    try testing.expect(dt.isDirty(r33));

    // Regions outside the bounding box must still be NOT dirty
    try testing.expect(!dt.isDirty(Rect.init(660, 0, 10, 10)));
    try testing.expect(!dt.isDirty(Rect.init(0, 20, 10, 10)));
    try testing.expect(!dt.isDirty(Rect.init(500, 500, 50, 50)));
}

test "stress: multi-cycle coalescing (overflow at 33, 65, 97)" {
    var dt = DamageTracker.init();
    dt.clear();

    // Cycle 1: rects 1..32 (count 1..32) -> rect 33 triggers coalesce (count -> 1)
    var idx: u32 = 0;
    while (idx < 32) : (idx += 1) {
        dt.addDamage(Rect.init(idx * 20, 0, 10, 10));
    }
    try testing.expectEqual(@as(usize, 32), dt.count);
    dt.addDamage(Rect.init(32 * 20, 0, 10, 10)); // #33
    try testing.expectEqual(@as(usize, 1), dt.count);

    // Cycle 2: add 31 disjoint rects on row y=100 (count becomes 32) -> add #65 (triggers coalesce to 1)
    idx = 0;
    while (idx < 31) : (idx += 1) {
        dt.addDamage(Rect.init(idx * 20, 100, 10, 10));
    }
    try testing.expectEqual(@as(usize, 32), dt.count);
    dt.addDamage(Rect.init(31 * 20, 100, 10, 10)); // #65 total
    try testing.expectEqual(@as(usize, 1), dt.count);

    // Cycle 3: add 31 disjoint rects on row y=200 -> add #97
    idx = 0;
    while (idx < 31) : (idx += 1) {
        dt.addDamage(Rect.init(idx * 20, 200, 10, 10));
    }
    try testing.expectEqual(@as(usize, 32), dt.count);
    dt.addDamage(Rect.init(31 * 20, 200, 10, 10)); // #97 total
    try testing.expectEqual(@as(usize, 1), dt.count);

    // Verify bounding box spans across all 3 rows (y: 0..210)
    const bb = dt.getBoundingBox().?;
    try testing.expectEqual(@as(u32, 0), bb.x);
    try testing.expectEqual(@as(u32, 0), bb.y);
    try testing.expectEqual(@as(u32, 650), bb.w);
    try testing.expectEqual(@as(u32, 210), bb.h);

    // Verify damage is preserved across all 3 rows
    try testing.expect(dt.isDirty(Rect.init(0, 0, 10, 10)));
    try testing.expect(dt.isDirty(Rect.init(300, 100, 10, 10)));
    try testing.expect(dt.isDirty(Rect.init(600, 200, 10, 10)));

    // Verify area outside bounding box is clean
    try testing.expect(!dt.isDirty(Rect.init(700, 300, 50, 50)));
}

test "stress: multi-stage coalescing up to 100 distinct rects" {
    var dt = DamageTracker.init();
    dt.clear();

    // Add 100 distinct 5x5 rects at grid locations:
    // row = i / 10, col = i % 10
    // x = col * 30, y = row * 30, w = 5, h = 5
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const col = i % 10;
        const row = i / 10;
        const r = Rect.init(col * 30, row * 30, 5, 5);
        dt.addDamage(r);
    }

    // Verify bounding box spans col 0..9 and row 0..9
    // min_x = 0, max_x = 9*30 + 5 = 275 -> w = 275
    // min_y = 0, max_y = 9*30 + 5 = 275 -> h = 275
    const bb = dt.getBoundingBox().?;
    try testing.expectEqual(@as(u32, 0), bb.x);
    try testing.expectEqual(@as(u32, 0), bb.y);
    try testing.expectEqual(@as(u32, 275), bb.w);
    try testing.expectEqual(@as(u32, 275), bb.h);

    // Verify all 100 rects are marked dirty (zero damage missed)
    i = 0;
    while (i < 100) : (i += 1) {
        const col = i % 10;
        const row = i / 10;
        const r = Rect.init(col * 30, row * 30, 5, 5);
        try testing.expect(dt.isDirty(r));
    }

    // Area completely outside the 100-rect bounds must be clean
    try testing.expect(!dt.isDirty(Rect.init(300, 300, 50, 50)));
    try testing.expect(!dt.isDirty(Rect.init(500, 100, 10, 10)));
}

test "stress: coalescing of adjacent and contiguous strips" {
    var dt = DamageTracker.init();
    dt.clear();

    // Adding 50 horizontally adjacent rects of 10x10
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        dt.addDamage(Rect.init(i * 10, 0, 10, 10));
        // Because each is adjacent to the prior rect, they immediately coalesce into rects[0]
        try testing.expectEqual(@as(usize, 1), dt.count);
    }

    try testing.expectEqual(@as(usize, 1), dt.count);
    const rects = dt.getRects();
    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(u32, 0), rects[0].x);
    try testing.expectEqual(@as(u32, 0), rects[0].y);
    try testing.expectEqual(@as(u32, 500), rects[0].w);
    try testing.expectEqual(@as(u32, 10), rects[0].h);

    try testing.expect(dt.isDirty(Rect.init(250, 0, 10, 10)));
    try testing.expect(!dt.isDirty(Rect.init(500, 0, 10, 10))); // Touching end, not intersecting
}

// ============================================================================
// 3. isDirty Queries: Disjoint, Touching, Nested, Overlapping
// ============================================================================

test "stress: isDirty queries comprehensive classification" {
    var dt = DamageTracker.init();
    dt.clear();

    // Base damage: x: 100..150, y: 100..150
    dt.addDamage(Rect.init(100, 100, 50, 50));

    // --- 1. Disjoint Queries (Must be false) ---
    try testing.expect(!dt.isDirty(Rect.init(0, 0, 50, 50)));
    try testing.expect(!dt.isDirty(Rect.init(200, 200, 50, 50)));
    try testing.expect(!dt.isDirty(Rect.init(100, 0, 50, 50)));
    try testing.expect(!dt.isDirty(Rect.init(0, 100, 50, 50)));
    try testing.expect(!dt.isDirty(Rect.init(100, 200, 50, 50)));
    try testing.expect(!dt.isDirty(Rect.init(200, 100, 50, 50)));

    // --- 2. Touching Queries (Sharing boundary edges/corners: half-open intervals do NOT intersect) ---
    // Right touch: x: 150..200
    try testing.expect(!dt.isDirty(Rect.init(150, 100, 50, 50)));
    // Left touch: x: 50..100
    try testing.expect(!dt.isDirty(Rect.init(50, 100, 50, 50)));
    // Bottom touch: y: 150..200
    try testing.expect(!dt.isDirty(Rect.init(100, 150, 50, 50)));
    // Top touch: y: 50..100
    try testing.expect(!dt.isDirty(Rect.init(100, 50, 50, 50)));
    // Corner touches
    try testing.expect(!dt.isDirty(Rect.init(150, 150, 50, 50)));
    try testing.expect(!dt.isDirty(Rect.init(50, 50, 50, 50)));
    try testing.expect(!dt.isDirty(Rect.init(150, 50, 50, 50)));
    try testing.expect(!dt.isDirty(Rect.init(50, 150, 50, 50)));

    // --- 3. Nested Queries (Must be true) ---
    // Identical
    try testing.expect(dt.isDirty(Rect.init(100, 100, 50, 50)));
    // Strict interior
    try testing.expect(dt.isDirty(Rect.init(110, 110, 30, 30)));
    // 1x1 at top-left
    try testing.expect(dt.isDirty(Rect.init(100, 100, 1, 1)));
    // 1x1 at bottom-right interior pixel
    try testing.expect(dt.isDirty(Rect.init(149, 149, 1, 1)));
    // Enclosing superset
    try testing.expect(dt.isDirty(Rect.init(90, 90, 70, 70)));
    try testing.expect(dt.isDirty(Rect.init(0, 0, 800, 600)));

    // --- 4. Overlapping Queries (Must be true) ---
    // Overlap top-left corner by 1 pixel
    try testing.expect(dt.isDirty(Rect.init(90, 90, 11, 11))); // x: 90..101, y: 90..101 -> overlaps [100, 100]
    // Overlap bottom-right corner by 1 pixel
    try testing.expect(dt.isDirty(Rect.init(149, 149, 10, 10))); // x: 149..159, y: 149..159 -> overlaps [149, 149]
    // Overlap left edge
    try testing.expect(dt.isDirty(Rect.init(95, 110, 10, 30)));
    // Overlap right edge
    try testing.expect(dt.isDirty(Rect.init(145, 110, 10, 30)));
    // Overlap top edge
    try testing.expect(dt.isDirty(Rect.init(110, 95, 30, 10)));
    // Overlap bottom edge
    try testing.expect(dt.isDirty(Rect.init(110, 145, 30, 10)));

    // Cross-cutting horizontal strip
    try testing.expect(dt.isDirty(Rect.init(50, 120, 200, 10)));
    // Cross-cutting vertical strip
    try testing.expect(dt.isDirty(Rect.init(120, 50, 10, 200)));
}

test "stress: multi-rect hole discrimination" {
    var dt = DamageTracker.init();
    dt.clear();

    // Four corner damage rects leaving a large central hole
    // D1: [10, 10, 20, 20]   (10..30, 10..30)
    // D2: [100, 10, 20, 20]  (100..120, 10..30)
    // D3: [10, 100, 20, 20]  (10..30, 100..120)
    // D4: [100, 100, 20, 20] (100..120, 100..120)
    dt.addDamage(Rect.init(10, 10, 20, 20));
    dt.addDamage(Rect.init(100, 10, 20, 20));
    dt.addDamage(Rect.init(10, 100, 20, 20));
    dt.addDamage(Rect.init(100, 100, 20, 20));

    try testing.expectEqual(@as(usize, 4), dt.count);

    // Bounding box spans [10, 10, 110, 110]
    const bb = dt.getBoundingBox().?;
    try testing.expectEqual(@as(u32, 10), bb.x);
    try testing.expectEqual(@as(u32, 10), bb.y);
    try testing.expectEqual(@as(u32, 110), bb.w);
    try testing.expectEqual(@as(u32, 110), bb.h);

    // Central hole: [40, 40, 50, 50] is inside bounding box, but disjoint from all 4 rects
    try testing.expect(!dt.isDirty(Rect.init(40, 40, 50, 50)));

    // Individual damaged rects must be dirty
    try testing.expect(dt.isDirty(Rect.init(10, 10, 20, 20)));
    try testing.expect(dt.isDirty(Rect.init(100, 10, 20, 20)));
    try testing.expect(dt.isDirty(Rect.init(10, 100, 20, 20)));
    try testing.expect(dt.isDirty(Rect.init(100, 100, 20, 20)));

    // A rect crossing through the hole and touching D1 and D2 must be dirty
    try testing.expect(dt.isDirty(Rect.init(25, 15, 80, 10)));
}

// ============================================================================
// 4. Random Oracle Generator & Differential Verification
// ============================================================================

test "stress: 1000-rect random fuzz and oracle verification" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE_1234);
    const rand = prng.random();

    var dt = DamageTracker.init();
    dt.clear();

    const OracleRect = struct {
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    };
    var history: [1000]OracleRect = undefined;

    var oracle_min_x: u32 = std.math.maxInt(u32);
    var oracle_min_y: u32 = std.math.maxInt(u32);
    var oracle_max_x: u32 = 0;
    var oracle_max_y: u32 = 0;

    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        // Random dimensions within 800x600 screen
        const x = rand.uintLessThan(u32, 750);
        const y = rand.uintLessThan(u32, 550);
        const w = rand.uintLessThan(u32, 50) + 1; // 1..50
        const h = rand.uintLessThan(u32, 50) + 1; // 1..50

        const r = Rect.init(x, y, w, h);
        dt.addDamage(r);

        history[n] = .{ .x = x, .y = y, .w = w, .h = h };

        oracle_min_x = @min(oracle_min_x, x);
        oracle_min_y = @min(oracle_min_y, y);
        oracle_max_x = @max(oracle_max_x, x + w);
        oracle_max_y = @max(oracle_max_y, y + h);

        // Verify bounding box invariant after each insertion
        const bb = dt.getBoundingBox().?;
        try testing.expectEqual(oracle_min_x, bb.x);
        try testing.expectEqual(oracle_min_y, bb.y);
        try testing.expectEqual(oracle_max_x - oracle_min_x, bb.w);
        try testing.expectEqual(oracle_max_y - oracle_min_y, bb.h);
    }

    // Verify ZERO DAMAGE MISSED: Every single one of the 1000 added rects must report dirty!
    for (history[0..1000]) |hr| {
        const r = Rect.init(hr.x, hr.y, hr.w, hr.h);
        try testing.expect(dt.isDirty(r));
    }

    // Verify completely disjoint outside rect is NOT dirty
    const outside = Rect.init(oracle_max_x + 50, oracle_max_y + 50, 10, 10);
    try testing.expect(!dt.isDirty(outside));
}

test "stress: lifecycle idempotency and reset sequences" {
    var dt = DamageTracker.initWithBounds(Rect.init(0, 0, 1024, 768));

    // Initially all dirty
    try testing.expect(dt.isDirty(Rect.init(500, 500, 10, 10)));
    try testing.expect(dt.hasDamage());
    try testing.expectEqual(@as(u32, 1024), dt.getDirtyBounds().?.w);

    // Multiple clears
    dt.clear();
    dt.clear();
    try testing.expect(!dt.hasDamage());
    try testing.expect(!dt.isDirty(Rect.init(500, 500, 10, 10)));

    // Multiple markAllDirty
    dt.markAllDirty();
    dt.markAllDirty();
    try testing.expect(dt.hasDamage());
    try testing.expect(dt.isDirty(Rect.init(500, 500, 10, 10)));
    try testing.expectEqual(@as(u32, 1024), dt.getDirtyBounds().?.w);

    // Clear and re-populate
    dt.clear();
    dt.addDamage(Rect.init(10, 10, 20, 20));
    try testing.expectEqual(@as(usize, 1), dt.count);
    dt.clear();
    try testing.expectEqual(@as(usize, 0), dt.count);
    try testing.expect(!dt.hasDamage());
}

test "stress: nested and superset damage insertions" {
    var dt = DamageTracker.init();
    dt.clear();

    // Add base rect: [50, 50, 100, 100]
    dt.addDamage(Rect.init(50, 50, 100, 100));
    try testing.expectEqual(@as(usize, 1), dt.count);

    // Add nested rect strictly inside: [70, 70, 20, 20]
    dt.addDamage(Rect.init(70, 70, 20, 20));
    // Must coalesce into the existing rect without creating a duplicate slot
    try testing.expectEqual(@as(usize, 1), dt.count);
    try testing.expectEqual(@as(u32, 50), dt.getRects()[0].x);
    try testing.expectEqual(@as(u32, 50), dt.getRects()[0].y);
    try testing.expectEqual(@as(u32, 100), dt.getRects()[0].w);
    try testing.expectEqual(@as(u32, 100), dt.getRects()[0].h);

    // Add superset rect enclosing the existing rect: [30, 30, 150, 150]
    dt.addDamage(Rect.init(30, 30, 150, 150));
    try testing.expectEqual(@as(usize, 1), dt.count);
    try testing.expectEqual(@as(u32, 30), dt.getRects()[0].x);
    try testing.expectEqual(@as(u32, 30), dt.getRects()[0].y);
    try testing.expectEqual(@as(u32, 150), dt.getRects()[0].w);
    try testing.expectEqual(@as(u32, 150), dt.getRects()[0].h);
}

test "stress: post-coalescence query classification (>32 rects)" {
    var dt = DamageTracker.init();
    dt.clear();

    // Add 33 disjoint rects on row y=100
    // rect 0: [0..10], ..., rect 32: [640..650]
    var i: u32 = 0;
    while (i < 33) : (i += 1) {
        dt.addDamage(Rect.init(i * 20, 100, 10, 10));
    }

    try testing.expectEqual(@as(usize, 1), dt.count);
    const bb = dt.getBoundingBox().?;
    try testing.expectEqual(@as(u32, 0), bb.x);
    try testing.expectEqual(@as(u32, 100), bb.y);
    try testing.expectEqual(@as(u32, 650), bb.w);
    try testing.expectEqual(@as(u32, 10), bb.h);

    // 1. All damaged rects report dirty (no damage missed)
    i = 0;
    while (i < 33) : (i += 1) {
        try testing.expect(dt.isDirty(Rect.init(i * 20, 100, 10, 10)));
    }

    // 2. Rect touching outer edge of coalesced bounding box is NOT dirty
    // Touching left outer edge: x: 0 - 20 = -20 (not representable in u32), but touching right:
    try testing.expect(!dt.isDirty(Rect.init(650, 100, 50, 10)));
    // Touching top outer edge: y: 90..100
    try testing.expect(!dt.isDirty(Rect.init(0, 90, 100, 10)));
    // Touching bottom outer edge: y: 110..120
    try testing.expect(!dt.isDirty(Rect.init(0, 110, 100, 10)));

    // 3. Rect overlapping outer edge of coalesced bounding box IS dirty
    // Overlap right boundary: x: 649..659
    try testing.expect(dt.isDirty(Rect.init(649, 100, 10, 10)));
    // Overlap top boundary: y: 99..101
    try testing.expect(dt.isDirty(Rect.init(100, 99, 10, 2)));

    // 4. Rect completely disjoint is NOT dirty
    try testing.expect(!dt.isDirty(Rect.init(700, 200, 50, 50)));
}

