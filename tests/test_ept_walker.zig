//! Comprehensive Empirical Stress Test for EPT Radix-Tree Walking and Memory Isolation
//!
//! Directly exercises the 4-level EPT translation algorithm as implemented in
//! src/arch/x86_64/vmx.zig (translateEptGpaToHpa) across all page levels:
//! - 4 KiB standard pages (PTE)
//! - 2 MiB large pages (PDE bit 7)
//! - 1 GiB large pages (PDPTE bit 7)

const std = @import("std");

/// Exact translation algorithm from src/arch/x86_64/vmx.zig:1128-1171
fn translateEptGpaToHpa(root_phys: u64, gpa: u64, hhdm_offset: u64) ?u64 {
    if (root_phys == 0 or hhdm_offset == 0 or gpa >= (1 << 48)) return null;

    // Level 4: PML4
    const pml4_phys = root_phys & 0x000F_FFFF_FFFF_F000;
    const pml4: [*]const u64 = @ptrFromInt(pml4_phys +% hhdm_offset);
    const pml4_idx = @as(usize, @intCast((gpa >> 39) & 0x1FF));
    const pml4e = pml4[pml4_idx];
    if ((pml4e & 0x7) == 0) return null;

    // Level 3: PDPT
    const pdpt_phys = pml4e & 0x000F_FFFF_FFFF_F000;
    const pdpt: [*]const u64 = @ptrFromInt(pdpt_phys +% hhdm_offset);
    const pdpt_idx = @as(usize, @intCast((gpa >> 30) & 0x1FF));
    const pdpte = pdpt[pdpt_idx];
    if ((pdpte & 0x7) == 0) return null;

    // Check for 1 GiB large page (bit 7)
    if ((pdpte & (1 << 7)) != 0) {
        return (pdpte & 0x000F_FFFF_C000_0000) | (gpa & 0x3FFF_FFFF);
    }

    // Level 2: PD
    const pd_phys = pdpte & 0x000F_FFFF_FFFF_F000;
    const pd: [*]const u64 = @ptrFromInt(pd_phys +% hhdm_offset);
    const pd_idx = @as(usize, @intCast((gpa >> 21) & 0x1FF));
    const pde = pd[pd_idx];
    if ((pde & 0x7) == 0) return null;

    // Check for 2 MiB large page (bit 7)
    if ((pde & (1 << 7)) != 0) {
        return (pde & 0x000F_FFFF_FFE0_0000) | (gpa & 0x1F_FFFF);
    }

    // Level 1: PT
    const pt_phys = pde & 0x000F_FFFF_FFFF_F000;
    const pt: [*]const u64 = @ptrFromInt(pt_phys +% hhdm_offset);
    const pt_idx = @as(usize, @intCast((gpa >> 12) & 0x1FF));
    const pte = pt[pt_idx];
    if ((pte & 0x7) == 0) return null;

    // 4 KiB page translation
    return (pte & 0x000F_FFFF_FFFF_F000) | (gpa & 0xFFF);
}

const HHDM_MOCK: u64 = 0xFFFF_8000_0000_0000;
const PageTable = [512]u64;

const TestMemory = struct {
    pml4: PageTable align(4096) = @splat(0),
    pdpt: PageTable align(4096) = @splat(0),
    pd: PageTable align(4096) = @splat(0),
    pt: PageTable align(4096) = @splat(0),

    pub fn toPhys(self: *TestMemory, ptr: anytype) u64 {
        _ = self;
        return @intFromPtr(ptr) -% HHDM_MOCK;
    }

    pub fn getRootPhys(self: *TestMemory) u64 {
        return self.toPhys(&self.pml4);
    }
};

test "EPT Walker: 4 KiB Page Translation & In-Page Offset Math" {
    var mem: TestMemory = .{};
    const root = mem.getRootPhys();

    // Map GPA 0x0000_1234_5678_9ABC
    const test_gpa: u64 = 0x0000_1234_5678_9ABC;
    const target_hpa_frame: u64 = 0x0000_8888_9999_0000;

    const pml4_idx = (test_gpa >> 39) & 0x1FF;
    const pdpt_idx = (test_gpa >> 30) & 0x1FF;
    const pd_idx = (test_gpa >> 21) & 0x1FF;
    const pt_idx = (test_gpa >> 12) & 0x1FF;
    const offset = test_gpa & 0xFFF;

    mem.pml4[pml4_idx] = (mem.toPhys(&mem.pdpt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    mem.pdpt[pdpt_idx] = (mem.toPhys(&mem.pd) & 0x000F_FFFF_FFFF_F000) | 0x7;
    mem.pd[pd_idx] = (mem.toPhys(&mem.pt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    mem.pt[pt_idx] = target_hpa_frame | 0x7; // Read, Write, Execute

    const translated = translateEptGpaToHpa(root, test_gpa, HHDM_MOCK);
    try std.testing.expect(translated != null);
    try std.testing.expectEqual(target_hpa_frame | offset, translated.?);
}

test "EPT Walker: 2 MiB Large Page Translation & In-Page Offset Math" {
    var mem: TestMemory = .{};
    const root = mem.getRootPhys();

    // GPA: 0x0020_5ABC (inside 2 MiB page starting at 0x0020_0000)
    const test_gpa: u64 = 0x0020_5ABC;
    const huge_hpa_frame: u64 = 0x0000_4000_0000; // 2 MiB aligned

    const pml4_idx = (test_gpa >> 39) & 0x1FF;
    const pdpt_idx = (test_gpa >> 30) & 0x1FF;
    const pd_idx = (test_gpa >> 21) & 0x1FF;
    const offset = test_gpa & 0x1F_FFFF;

    mem.pml4[pml4_idx] = (mem.toPhys(&mem.pdpt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    mem.pdpt[pdpt_idx] = (mem.toPhys(&mem.pd) & 0x000F_FFFF_FFFF_F000) | 0x7;
    // Set bit 7 (large page) + flags (0x87)
    mem.pd[pd_idx] = huge_hpa_frame | 0x87;

    const translated = translateEptGpaToHpa(root, test_gpa, HHDM_MOCK);
    try std.testing.expect(translated != null);
    try std.testing.expectEqual(huge_hpa_frame | offset, translated.?);
}

test "EPT Walker: 1 GiB Large Page Translation & In-Page Offset Math" {
    var mem: TestMemory = .{};
    const root = mem.getRootPhys();

    // GPA: 0x4005_4321 (inside 1 GiB page starting at 0x4000_0000)
    const test_gpa: u64 = 0x4005_4321;
    const gig_hpa_frame: u64 = 0x0000_8000_0000; // 1 GiB aligned

    const pml4_idx = (test_gpa >> 39) & 0x1FF;
    const pdpt_idx = (test_gpa >> 30) & 0x1FF;
    const offset = test_gpa & 0x3FFF_FFFF;

    mem.pml4[pml4_idx] = (mem.toPhys(&mem.pdpt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    // Set bit 7 (large page) + flags (0x87) on PDPTE
    mem.pdpt[pdpt_idx] = gig_hpa_frame | 0x87;

    const translated = translateEptGpaToHpa(root, test_gpa, HHDM_MOCK);
    try std.testing.expect(translated != null);
    try std.testing.expectEqual(gig_hpa_frame | offset, translated.?);
}

test "EPT Walker: Boundary GPAs (0x0, 0xFFF, 0x1FFFFFFF, 1GB)" {
    var mem: TestMemory = .{};
    const root = mem.getRootPhys();

    // Setup identity PDPT & PD pointers
    mem.pml4[0] = (mem.toPhys(&mem.pdpt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    mem.pdpt[0] = (mem.toPhys(&mem.pd) & 0x000F_FFFF_FFFF_F000) | 0x7;
    mem.pd[0] = (mem.toPhys(&mem.pt) & 0x000F_FFFF_FFFF_F000) | 0x7;

    // 1. GPA 0x0000_0000 (page 0, start)
    const hpa_zero: u64 = 0x1000_0000;
    mem.pt[0] = hpa_zero | 0x7;
    try std.testing.expectEqual(hpa_zero, translateEptGpaToHpa(root, 0x0, HHDM_MOCK));

    // 2. GPA 0x0000_0FFF (page 0, last byte)
    try std.testing.expectEqual(hpa_zero | 0xFFF, translateEptGpaToHpa(root, 0xFFF, HHDM_MOCK));

    // 3. GPA 0x1FFF_FFFF (512 MiB - 1 boundary)
    const gpa_512m_boundary: u64 = 0x1FFF_FFFF;
    const pml4_i = (gpa_512m_boundary >> 39) & 0x1FF; // 0
    const pdpt_i = (gpa_512m_boundary >> 30) & 0x1FF; // 0
    const pd_i = (gpa_512m_boundary >> 21) & 0x1FF; // 255
    const pt_i = (gpa_512m_boundary >> 12) & 0x1FF; // 511
    try std.testing.expectEqual(@as(usize, 0), pml4_i);
    try std.testing.expectEqual(@as(usize, 0), pdpt_i);
    try std.testing.expectEqual(@as(usize, 255), pd_i);
    try std.testing.expectEqual(@as(usize, 511), pt_i);

    // Map 2MiB huge page at PD index 255
    const hpa_huge_512: u64 = 0x3000_0000;
    mem.pd[255] = hpa_huge_512 | 0x87;
    const res_512m = translateEptGpaToHpa(root, gpa_512m_boundary, HHDM_MOCK);
    try std.testing.expect(res_512m != null);
    try std.testing.expectEqual(hpa_huge_512 | (gpa_512m_boundary & 0x1F_FFFF), res_512m.?);

    // 4. GPA 1GB (0x4000_0000) — PDPT index 1
    const gpa_1gb: u64 = 0x4000_0000;
    const pdpt_1g_idx = (gpa_1gb >> 30) & 0x1FF;
    try std.testing.expectEqual(@as(usize, 1), pdpt_1g_idx);
    // Unmapped by default
    try std.testing.expect(translateEptGpaToHpa(root, gpa_1gb, HHDM_MOCK) == null);

    // Map 1GB page at PDPT index 1
    const hpa_1g: u64 = 0x8000_0000;
    mem.pdpt[1] = hpa_1g | 0x87;
    try std.testing.expectEqual(hpa_1g, translateEptGpaToHpa(root, gpa_1gb, HHDM_MOCK));
    // Test boundary at 1GB + 0x3FFF_FFFF (2GB - 1)
    try std.testing.expectEqual(hpa_1g | 0x3FFF_FFFF, translateEptGpaToHpa(root, gpa_1gb | 0x3FFF_FFFF, HHDM_MOCK));
}

test "EPT Walker: Unmapped and Invalid Entries" {
    var mem: TestMemory = .{};
    const root = mem.getRootPhys();

    // 1. root_phys == 0
    try std.testing.expect(translateEptGpaToHpa(0, 0x1000, HHDM_MOCK) == null);

    // 2. hhdm_offset == 0
    try std.testing.expect(translateEptGpaToHpa(root, 0x1000, 0) == null);

    // 3. Unmapped PML4 entry (PML4E == 0)
    try std.testing.expect(translateEptGpaToHpa(root, 0x1000, HHDM_MOCK) == null);

    // 4. PML4E present but flags == 0 (no read/write/exec)
    mem.pml4[0] = mem.toPhys(&mem.pdpt) & 0x000F_FFFF_FFFF_F000; // flags = 0
    try std.testing.expect(translateEptGpaToHpa(root, 0x1000, HHDM_MOCK) == null);

    // Set valid PML4 flags
    mem.pml4[0] |= 0x7;

    // 5. Unmapped PDPT entry (PDPTE == 0)
    try std.testing.expect(translateEptGpaToHpa(root, 0x1000, HHDM_MOCK) == null);

    // 6. PDPTE present but flags == 0
    mem.pdpt[0] = mem.toPhys(&mem.pd) & 0x000F_FFFF_FFFF_F000;
    try std.testing.expect(translateEptGpaToHpa(root, 0x1000, HHDM_MOCK) == null);

    // Set valid PDPT flags
    mem.pdpt[0] |= 0x7;

    // 7. Unmapped PD entry (PDE == 0)
    try std.testing.expect(translateEptGpaToHpa(root, 0x1000, HHDM_MOCK) == null);

    // 8. PDE present but flags == 0
    mem.pd[0] = mem.toPhys(&mem.pt) & 0x000F_FFFF_FFFF_F000;
    try std.testing.expect(translateEptGpaToHpa(root, 0x1000, HHDM_MOCK) == null);

    // Set valid PD flags
    mem.pd[0] |= 0x7;

    // 9. Unmapped PT entry (PTE == 0)
    try std.testing.expect(translateEptGpaToHpa(root, 0x1000, HHDM_MOCK) == null);
}

test "EPT Walker: Intel SDM Flag Masking (No Flag Leakage into HPA)" {
    var mem: TestMemory = .{};
    const root = mem.getRootPhys();

    mem.pml4[0] = (mem.toPhys(&mem.pdpt) & 0x000F_FFFF_FFFF_F000) | 0x7;

    // 1. 1 GiB page with dirty (bit 9), accessed (bit 8), large (bit 7), memtype (bits 5:3 = 6 WB), RWX (0x7)
    // Flags = 0x3F7
    const hpa_1g_base: u64 = 0x4000_0000;
    mem.pdpt[1] = hpa_1g_base | 0x3F7;
    const res_1g = translateEptGpaToHpa(root, 0x4000_0000, HHDM_MOCK);
    try std.testing.expect(res_1g != null);
    try std.testing.expectEqual(hpa_1g_base, res_1g.?); // Flags must be cleanly stripped!

    // 2. 2 MiB page with all flag bits set (bits 20:0 except alignment)
    mem.pdpt[0] = (mem.toPhys(&mem.pd) & 0x000F_FFFF_FFFF_F000) | 0x7;
    const hpa_2m_base: u64 = 0x2000_0000;
    mem.pd[0] = hpa_2m_base | 0x1F_FFFF; // All lower bits set
    const res_2m = translateEptGpaToHpa(root, 0x0, HHDM_MOCK);
    try std.testing.expect(res_2m != null);
    try std.testing.expectEqual(hpa_2m_base, res_2m.?); // Lower 21 bits stripped!

    // 3. 4 KiB page with all flag bits set (bits 11:0)
    mem.pd[1] = (mem.toPhys(&mem.pt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    const hpa_4k_base: u64 = 0x1000_0000;
    mem.pt[0] = hpa_4k_base | 0xFFF; // All lower bits set
    const res_4k = translateEptGpaToHpa(root, 0x20_0000, HHDM_MOCK);
    try std.testing.expect(res_4k != null);
    try std.testing.expectEqual(hpa_4k_base, res_4k.?); // Lower 12 bits stripped!
}

test "EPT Isolation: Multi-Instance Separate Roots (No Memory Aliasing)" {
    var inst1_mem: TestMemory = .{};
    var inst2_mem: TestMemory = .{};

    const root1 = inst1_mem.getRootPhys();
    const root2 = inst2_mem.getRootPhys();

    try std.testing.expect(root1 != root2);

    // Setup Instance 1: GPA 0x100000 -> HPA 0x50100000
    inst1_mem.pml4[0] = (inst1_mem.toPhys(&inst1_mem.pdpt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    inst1_mem.pdpt[0] = (inst1_mem.toPhys(&inst1_mem.pd) & 0x000F_FFFF_FFFF_F000) | 0x7;
    inst1_mem.pd[0] = (inst1_mem.toPhys(&inst1_mem.pt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    const hpa_inst1: u64 = 0x5010_0000;
    inst1_mem.pt[0x100] = hpa_inst1 | 0x7;

    // Setup Instance 2: Identical GPA 0x100000 -> HPA 0x60100000 (Distinct!)
    inst2_mem.pml4[0] = (inst2_mem.toPhys(&inst2_mem.pdpt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    inst2_mem.pdpt[0] = (inst2_mem.toPhys(&inst2_mem.pd) & 0x000F_FFFF_FFFF_F000) | 0x7;
    inst2_mem.pd[0] = (inst2_mem.toPhys(&inst2_mem.pt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    const hpa_inst2: u64 = 0x6010_0000;
    inst2_mem.pt[0x100] = hpa_inst2 | 0x7;

    const gpa_shared: u64 = 0x100000;
    const trans1 = translateEptGpaToHpa(root1, gpa_shared, HHDM_MOCK);
    const trans2 = translateEptGpaToHpa(root2, gpa_shared, HHDM_MOCK);

    try std.testing.expect(trans1 != null);
    try std.testing.expect(trans2 != null);
    try std.testing.expectEqual(hpa_inst1, trans1.?);
    try std.testing.expectEqual(hpa_inst2, trans2.?);
    try std.testing.expect(trans1.? != trans2.?);

    // Modify Instance 1 page table: Unmap the page
    inst1_mem.pt[0x100] = 0;
    try std.testing.expect(translateEptGpaToHpa(root1, gpa_shared, HHDM_MOCK) == null);

    // Verify Instance 2 is completely undisturbed
    const trans2_after = translateEptGpaToHpa(root2, gpa_shared, HHDM_MOCK);
    try std.testing.expect(trans2_after != null);
    try std.testing.expectEqual(hpa_inst2, trans2_after.?);
}

test "EPT Walker: Rejects GPAs outside the four-level address range" {
    var mem: TestMemory = .{};
    const root = mem.getRootPhys();

    mem.pml4[0] = (mem.toPhys(&mem.pdpt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    mem.pdpt[0] = (mem.toPhys(&mem.pd) & 0x000F_FFFF_FFFF_F000) | 0x7;
    mem.pd[0] = (mem.toPhys(&mem.pt) & 0x000F_FFFF_FFFF_F000) | 0x7;
    const hpa_zero: u64 = 0x1000_0000;
    mem.pt[0] = hpa_zero | 0x7;

    // Normal translation of GPA 0x0
    try std.testing.expectEqual(hpa_zero, translateEptGpaToHpa(root, 0x0, HHDM_MOCK));

    // GPA bit 48 is outside the four-level EPT address range and must not alias
    // the PML4[0] mapping.
    const gpa_bit48: u64 = 0x0001_0000_0000_0000;
    const res_bit48 = translateEptGpaToHpa(root, gpa_bit48, HHDM_MOCK);
    try std.testing.expect(res_bit48 == null);
}
