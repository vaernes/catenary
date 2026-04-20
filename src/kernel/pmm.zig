const std = @import("std");
const limine = @import("limine.zig");
const builtin = @import("builtin");

/// Physical Memory Manager (PMM).
///
/// Invariants:
/// 1. Page Ownership: Ring 0 owns the allocation bitmap. Physical pages are
///    either "kernel-private" (bitmap bit set) or "available" (bit clear).
///    When a page is allocated, it is marked as private.
/// 2. User Space Isolation: User space (Ring 3) NEVER directly accesses the
///    PMM bitmap or allocation logic. Any memory allocated for user space
///    remains kernel-owned until explicitly mapped into the user address space.
/// 3. Lifetime: Physical frames are managed through this PMM and can be
///    reclaimed via `freePage`/`freeGuardedRegion` when the caller's ownership
///    ends.
///
/// Allocator Bounds Discipline (memory-security roadmap):
/// - All allocations are page-granular. Sub-page allocations are not tracked.
///   Callers must not write beyond the PAGE_SIZE boundary of any allocation.
/// - Guard-paged regions: `allocGuardedRegion` provides a (data_phys, n_pages)
///   pair backed by a leading and trailing guard page that must be left unmapped
///   in the page tables via paging.mapGuardPage(). A #PF on either guard page
///   indicates a stack or buffer overflow.
/// - Future direction: introduce a slab layer above this PMM for sub-page
///   objects. The slab layer is responsible for red-zone tracking and inline
///   canary words to detect linear overflows before they reach the next object.
pub const PAGE_SIZE = 4096;

var mem_bitmap: [*]u8 = undefined;
var highest_page: usize = 0;
var bitmap_size_in_bytes: usize = 0;
var initialized: bool = false;
var next_search_page: usize = 1;

pub fn init(memmap: *limine.MemmapResponse, hhdm_offset: u64) void {
    var highest_addr: u64 = 0;
    const entries = memmap.entries[0..memmap.entry_count];

    for (entries) |entry| {
        if (entry.kind == limine.MEMMAP_USABLE or entry.kind == limine.MEMMAP_ACPI_RECLAIMABLE) {
            const top = entry.base + entry.length;
            if (top > highest_addr) {
                highest_addr = top;
            }
        }
    }

    highest_page = highest_addr / PAGE_SIZE;
    bitmap_size_in_bytes = (highest_page / 8) + 1;
    const bitmap_pages = (bitmap_size_in_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

    // Find somewhere to put the bitmap
    var bitmap_phys: u64 = 0;
    var found_bitmap_place = false;
    for (entries) |entry| {
        if (entry.kind == limine.MEMMAP_USABLE and entry.length >= bitmap_pages * PAGE_SIZE) {
            bitmap_phys = entry.base;
            found_bitmap_place = true;
            break;
        }
    }

    if (!found_bitmap_place) return;

    mem_bitmap = @ptrFromInt(bitmap_phys + hhdm_offset);
    {
        // Use manual loop instead of @memset to avoid potential SIMD/alignment issues in early kernel.
        var i: usize = 0;
        while (i < bitmap_size_in_bytes) : (i += 1) {
            mem_bitmap[i] = 0xFF;
        }
    }

    for (entries) |entry| {
        if (entry.kind == limine.MEMMAP_USABLE) {
            const start = entry.base / PAGE_SIZE;
            const size = entry.length / PAGE_SIZE;
            for (0..size) |i| {
                clearBit(start + i);
            }
        }
    }

    // Mark the bitmap itself as used
    const bitmap_start = bitmap_phys / PAGE_SIZE;
    for (0..bitmap_pages) |i| {
        setBit(bitmap_start + i);
    }

    // Mark page 0 as reserved
    setBit(0);

    // Mark kernel memory as reserved
    for (entries) |entry| {
        if (entry.kind == limine.MEMMAP_KERNEL_AND_MODULES) {
            const start = entry.base / PAGE_SIZE;
            const count = (entry.length + PAGE_SIZE - 1) / PAGE_SIZE;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                setBit(start + i);
            }
        }
    }

    next_search_page = bitmap_start + bitmap_pages;
    if (next_search_page == 0 or next_search_page >= highest_page) {
        next_search_page = 1;
    }

    initialized = true;
}

pub fn setBit(bit: usize) void {
    mem_bitmap[bit / 8] |= (@as(u8, 1) << @as(u3, @truncate(bit % 8)));
}

pub fn clearBit(bit: usize) void {
    mem_bitmap[bit / 8] &= ~(@as(u8, 1) << @as(u3, @truncate(bit % 8)));
}

pub fn testBit(bit: usize) bool {
    return (mem_bitmap[bit / 8] & (@as(u8, 1) << @as(u3, @truncate(bit % 8)))) != 0;
}

pub fn allocPage() ?u64 {
    if (!initialized) return null;

    var page = next_search_page;
    while (page < highest_page) : (page += 1) {
        if (!testBit(page)) {
            setBit(page);
            next_search_page = page + 1;
            if (next_search_page >= highest_page) {
                next_search_page = 1;
            }
            return @as(u64, page) * PAGE_SIZE;
        }
    }

    page = 1;
    while (page < next_search_page) : (page += 1) {
        if (!testBit(page)) {
            setBit(page);
            next_search_page = page + 1;
            if (next_search_page >= highest_page) {
                next_search_page = 1;
            }
            return @as(u64, page) * PAGE_SIZE;
        }
    }

    return null;
}

pub fn allocContiguousAligned(n_pages: u64, alignment_pages: u64) ?u64 {
    if (!initialized) return null;
    if (n_pages == 0) return null;
    if (alignment_pages == 0) return null;

    var page: usize = 1;
    while (page + n_pages <= highest_page) {
        // Find next aligned page
        const aligned_page = (page + alignment_pages - 1) & ~(alignment_pages - 1);
        if (aligned_page + n_pages > highest_page) break;

        var found = true;
        var i: usize = 0;
        while (i < n_pages) : (i += 1) {
            if (testBit(aligned_page + i)) {
                found = false;
                page = aligned_page + i + 1;
                break;
            }
        }
        if (found) {
            i = 0;
            while (i < n_pages) : (i += 1) {
                setBit(aligned_page + i);
            }
            return @as(u64, aligned_page) * PAGE_SIZE;
        }
    }
    return null;
}

pub fn allocContiguous(n_pages: u64) ?u64 {
    if (!initialized) return null;
    if (n_pages == 0) return null;

    var page: usize = 1;
    while (page + n_pages <= highest_page) {
        var found = true;
        var i: usize = 0;
        while (i < n_pages) : (i += 1) {
            if (testBit(page + i)) {
                found = false;
                page += i + 1;
                break;
            }
        }
        if (found) {
            i = 0;
            while (i < n_pages) : (i += 1) {
                setBit(page + i);
            }
            return @as(u64, page) * PAGE_SIZE;
        }
    }
    return null;
}
/// Zero a physical page via the HHDM mapping.
/// Used to scrub page contents before returning to the free pool so that
/// a subsequent allocator cannot observe secrets left by the previous owner.
var hhdm_offset_cached: u64 = 0;

pub fn setHhdmOffset(offset: u64) void {
    hhdm_offset_cached = offset;
}

fn zeroPage(phys_addr: u64) void {
    if (hhdm_offset_cached == 0) return; // Too early; HHDM not yet known.
    const ptr: [*]u8 = @ptrFromInt(phys_addr + hhdm_offset_cached);
    // Manual loop to avoid hidden SIMD/alignment requirements in early kernel.
    var i: usize = 0;
    while (i < PAGE_SIZE) : (i += 1) {
        ptr[i] = 0;
    }
}

fn serialWriteSecurity(s: []const u8) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    for (s) |c| {
        asm volatile ("outb %al, %dx"
            :
            : [al] "{al}" (c),
              [dx] "{dx}" (@as(u16, 0x3F8)),
        );
    }
}

pub fn freePage(phys_addr: u64) void {
    if (!initialized) return;
    const page = phys_addr / PAGE_SIZE;
    if (page >= highest_page) return;

    // Double-free detection: if the page is already free, log and bail.
    if (!testBit(page)) {
        serialWriteSecurity("PMM: DOUBLE-FREE detected page=0x");
        // Best-effort hex print of page number
        const hex = "0123456789ABCDEF";
        var shift: u6 = 60;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const nibble: usize = @intCast((@as(u64, page) >> shift) & 0xF);
            serialWriteSecurity(hex[nibble..][0..1]);
            if (shift >= 4) shift -= 4;
        }
        serialWriteSecurity("\n");
        return;
    }

    // Zero the page before returning it to the pool to prevent
    // information leakage between services/MicroVMs.
    zeroPage(phys_addr);

    clearBit(page);
    if (page != 0 and page < next_search_page) {
        next_search_page = @as(usize, @intCast(page));
    }
}

/// A contiguous run of physical pages with guard pages at each end.
///
/// Layout (physical address space):
///   [guard_low_phys]      ← must remain unmapped (paging.mapGuardPage)
///   [data_phys .. data_phys + n_pages * PAGE_SIZE)  ← usable data region
///   [guard_high_phys]     ← must remain unmapped (paging.mapGuardPage)
///
/// The caller is responsible for calling paging.mapGuardPage() on both
/// guard addresses before the region is used. Failure to do so means the
/// guard pages are mapped and will not trap linear overflows.
pub const GuardedRegion = struct {
    guard_low_phys: u64,
    data_phys: u64,
    n_pages: usize,
    guard_high_phys: u64,
};

fn reserveContiguous(pages: usize) ?usize {
    if (!initialized or pages == 0) return null;
    if (pages >= highest_page) return null;

    var run_start: usize = 1;
    while (run_start + pages <= highest_page) : (run_start += 1) {
        var ok = true;
        var i: usize = 0;
        while (i < pages) : (i += 1) {
            if (testBit(run_start + i)) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;

        i = 0;
        while (i < pages) : (i += 1) {
            setBit(run_start + i);
        }

        next_search_page = run_start + pages;
        if (next_search_page >= highest_page) {
            next_search_page = 1;
        }
        return run_start;
    }

    return null;
}

/// Allocate `n_pages` data pages bracketed by one guard page at each end.
/// Returns null if the PMM cannot satisfy one contiguous run of n_pages + 2 pages.
///
/// NOTE: The data region is physically contiguous. This keeps the
/// GuardedRegion contract simple (single base + count).
pub fn allocGuardedRegion(n_pages: usize) ?GuardedRegion {
    if (n_pages == 0) return null;

    const total_pages = n_pages + 2;
    const start_page = reserveContiguous(total_pages) orelse return null;

    const guard_low = @as(u64, @intCast(start_page)) * PAGE_SIZE;
    const data_first = @as(u64, @intCast(start_page + 1)) * PAGE_SIZE;
    const guard_high = @as(u64, @intCast(start_page + 1 + n_pages)) * PAGE_SIZE;

    return GuardedRegion{
        .guard_low_phys = guard_low,
        .data_phys = data_first,
        .n_pages = n_pages,
        .guard_high_phys = guard_high,
    };
}

/// Free a previously allocated guarded region (guards + data pages).
pub fn freeGuardedRegion(region: GuardedRegion) void {
    if (!initialized) return;

    // Zero the data pages (not the guard pages — they're unmapped).
    var d: usize = 0;
    while (d < region.n_pages) : (d += 1) {
        zeroPage(region.data_phys + @as(u64, d) * PAGE_SIZE);
    }

    const start_page = @as(usize, @intCast(region.guard_low_phys / PAGE_SIZE));
    const total_pages = region.n_pages + 2;
    var i: usize = 0;
    while (i < total_pages) : (i += 1) {
        clearBit(start_page + i);
    }

    if (start_page != 0 and start_page < next_search_page) {
        next_search_page = start_page;
    }
}

test "allocPage reuses freed page" {
    var bitmap: [8]u8 = [_]u8{0xFF} ** 8;

    mem_bitmap = &bitmap;
    highest_page = 64;
    bitmap_size_in_bytes = bitmap.len;
    initialized = true;
    next_search_page = 1;

    clearBit(2);
    clearBit(4);

    const first = allocPage() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2 * PAGE_SIZE), first);

    freePage(first);
    const second = allocPage() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(first, second);
}

test "guarded region alloc/free roundtrip" {
    var bitmap: [8]u8 = [_]u8{0xFF} ** 8;

    mem_bitmap = &bitmap;
    highest_page = 64;
    bitmap_size_in_bytes = bitmap.len;
    initialized = true;
    next_search_page = 1;

    // Make pages [10..15] available to satisfy n_pages=4 (+2 guards).
    for (10..16) |p| clearBit(p);

    const region = allocGuardedRegion(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 10 * PAGE_SIZE), region.guard_low_phys);
    try std.testing.expectEqual(@as(u64, 11 * PAGE_SIZE), region.data_phys);
    try std.testing.expectEqual(@as(usize, 4), region.n_pages);
    try std.testing.expectEqual(@as(u64, 15 * PAGE_SIZE), region.guard_high_phys);

    freeGuardedRegion(region);
    const region2 = allocGuardedRegion(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(region.guard_low_phys, region2.guard_low_phys);
}

pub fn getTotalPages() usize {
    return highest_page;
}

pub fn getFreePages() usize {
    return 0; // Stub
}
