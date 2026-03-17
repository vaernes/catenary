const paging = @import("../arch/x86_64/paging.zig");

const TestCase = struct {
    name: []const u8,
    run: *const fn () bool,
};

fn testCanonicalAddresses() bool {
    return paging.isCanonical(0x0000_0000_0000_0000) and
        paging.isCanonical(0x0000_7FFF_FFFF_FFFF) and
        paging.isCanonical(0xFFFF_8000_0000_0000) and
        paging.isCanonical(0xFFFF_FFFF_FFFF_FFFF) and
        !paging.isCanonical(0x0000_8000_0000_0000) and
        !paging.isCanonical(0xFFFF_7FFF_FFFF_FFFF);
}

fn testLargePageTranslationMasks() bool {
    const pdpte: u64 = 0x0000_0001_4000_0083;
    const virt_1g: u64 = 0xFFFF_8000_1234_5678;
    const got_1g = paging.translate1GiBLargePage(pdpte, virt_1g);
    const want_1g: u64 = 0x0000_0001_5234_5678;

    const pde: u64 = 0x0000_0000_0080_0083;
    const virt_2m: u64 = 0xFFFF_8000_0023_4567;
    const got_2m = paging.translate2MiBLargePage(pde, virt_2m);
    const want_2m: u64 = 0x0000_0000_0083_4567;

    return got_1g == want_1g and got_2m == want_2m;
}

const pmm = @import("pmm.zig");
fn testPmmContiguousAligned() bool {
    const p1 = pmm.allocContiguousAligned(4, 8) orelse return false;
    if ((p1 / 4096) % 8 != 0) return false;
    const p2 = pmm.allocContiguousAligned(4, 8) orelse return false;
    if ((p2 / 4096) % 8 != 0) return false;
    if (p1 == p2) return false;

    pmm.freePage(p1);
    pmm.freePage(p1 + 4096);
    pmm.freePage(p1 + 8192);
    pmm.freePage(p1 + 12288);
    pmm.freePage(p2);
    pmm.freePage(p2 + 4096);
    pmm.freePage(p2 + 8192);
    pmm.freePage(p2 + 12288);
    return true;
}

fn writeLine(serialWrite: *const fn ([]const u8) void, s: []const u8) void {
    serialWrite(s);
    serialWrite("\n");
}

pub fn run(serialWrite: *const fn ([]const u8) void) bool {
    const tests = [_]TestCase{
        .{ .name = "paging.canonical", .run = testCanonicalAddresses },
        .{ .name = "paging.large_masks", .run = testLargePageTranslationMasks },
        .{ .name = "pmm.contiguous_aligned", .run = testPmmContiguousAligned },
    };

    writeLine(serialWrite, "selftest: start");

    var all_passed = true;
    for (tests) |t| {
        if (t.run()) {
            serialWrite("selftest: PASS ");
            writeLine(serialWrite, t.name);
        } else {
            serialWrite("selftest: FAIL ");
            writeLine(serialWrite, t.name);
            all_passed = false;
        }
    }

    writeLine(serialWrite, "selftest: done");
    return all_passed;
}
