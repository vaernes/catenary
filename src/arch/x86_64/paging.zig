pub const cpu = @import("cpu.zig");
const pmm = @import("../../kernel/pmm.zig");

pub const UpdateError = error{ NotMapped, InvalidAddress, AlreadyMapped, OutOfMemory, LargePageConflict };

const ENTRY_PRESENT: u64 = 1 << 0;
const ENTRY_RW: u64 = 1 << 1;
const ENTRY_USER: u64 = 1 << 2;
const ENTRY_ACCESSED: u64 = 1 << 5;
const ENTRY_DIRTY: u64 = 1 << 6;
const ENTRY_LARGE: u64 = 1 << 7;
const ENTRY_NX: u64 = @as(u64, 1) << 63;
const PAGE_MASK: u64 = 0x000F_FFFF_FFFF_F000;
const PHYS_MASK_1G: u64 = 0x000F_FFFF_C000_0000;
const PHYS_MASK_2M: u64 = 0x000F_FFFF_FFE0_0000;

pub fn isCanonical(addr: u64) bool {
    const sign = (addr >> 47) & 1;
    const upper = addr >> 48;
    return (sign == 0 and upper == 0) or (sign == 1 and upper == 0xFFFF);
}

pub fn translate1GiBLargePage(pdpte: u64, virt: u64) u64 {
    return (pdpte & PHYS_MASK_1G) | (virt & 0x3FFF_FFFF);
}

pub fn translate2MiBLargePage(pde: u64, virt: u64) u64 {
    return (pde & PHYS_MASK_2M) | (virt & 0x1F_FFFF);
}

/// Represents the virtual address range occupied by the kernel.
pub const KernelRange = struct {
    virtual_start: u64,
    virtual_end: u64,
    physical_start: u64,

    pub fn includes(self: KernelRange, virt: u64) bool {
        return virt >= self.virtual_start and virt < self.virtual_end;
    }
};

/// KASLR hook: tracks the kernel virtual slide applied at boot.
///
/// At boot Limine reports the actual virtual_base via KernelAddressRequest.
/// We record the slide (actual_virtual_base - KERNEL_DEFAULT_VIRT_BASE) here so
/// that any future code path that needs to re-derive a kernel virtual address
/// from a symbol or offset does so consistently.
///
/// A full KASLR implementation would pick slide_offset from boot-time entropy
/// and pass it to the bootloader. For now we record the slide Limine already
/// chose so callers have a single authoritative source to read.
pub const KasrlState = struct {
    /// Difference between the actual kernel virtual base and the link-time
    /// default (0xFFFF_FFFF_8100_0000). Zero if loaded at the default address.
    slide_offset: i64 = 0,
    /// Actual virtual base as reported by Limine KernelAddressRequest.
    virtual_base: u64 = 0,
    /// Whether init() has been called.
    initialized: bool = false,
};

/// Module-level singleton. Populated during early boot from Limine responses.
pub var kaslr: KasrlState = .{};

const KERNEL_DEFAULT_VIRT_BASE: u64 = 0xFFFF_FFFF_8100_0000;

/// Record the kernel virtual base reported by the bootloader and compute the
/// KASLR slide. Must be called before any bounds check that uses KasrlState.
pub fn initKasrl(actual_virtual_base: u64) void {
    kaslr.virtual_base = actual_virtual_base;
    kaslr.slide_offset = @as(i64, @bitCast(actual_virtual_base)) -
        @as(i64, @bitCast(KERNEL_DEFAULT_VIRT_BASE));
    kaslr.initialized = true;
}

/// Check that `virt` falls inside `range`. Returns false for any address
/// outside the kernel's mapped region (potential out-of-bounds access).
///
/// Use this at kernel/user privilege transitions and before following any
/// pointer derived from user-supplied data. Does not replace hardware SMEP/SMAP
/// enforcement but adds an explicit software bounds assertion.
pub fn checkKernelBounds(range: KernelRange, virt: u64) bool {
    return range.includes(virt);
}

/// Create an unmapped guard page at `virt`.
///
/// Guard pages are used to bound kernel stacks, guard-paged allocations, and
/// isolated service memory regions. An access to a guard page triggers a
/// #PF(present=0) which the kernel can distinguish from a legitimate miss.
///
/// This is a best-effort operation: if the page is not currently mapped we
/// treat it as already guarded (nothing to unmap) and return success.
pub fn mapGuardPage(hhdm_offset: u64, virt: u64) void {
    unmap(hhdm_offset, virt) catch {};
}

fn tablePtr(table_phys: u64, hhdm_offset: u64) [*]u64 {
    return @ptrFromInt((table_phys & PAGE_MASK) + hhdm_offset);
}

fn allocPageTable(hhdm_offset: u64) UpdateError!u64 {
    const table_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const table = tablePtr(table_phys, hhdm_offset);
    for (0..512) |i| {
        table[i] = 0;
    }
    return table_phys;
}

fn ensureChildTable(entry: *u64, hhdm_offset: u64, inherit_user: bool) UpdateError![*]u64 {
    if ((entry.* & ENTRY_PRESENT) == 0) {
        const child_phys = try allocPageTable(hhdm_offset);
        entry.* = (child_phys & PAGE_MASK) | ENTRY_PRESENT | ENTRY_RW;
        if (inherit_user) entry.* |= ENTRY_USER;
    } else if ((entry.* & ENTRY_LARGE) != 0) {
        return error.LargePageConflict;
    }
    return tablePtr(entry.*, hhdm_offset);
}

fn invlpg(addr: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (@as(*const u8, @ptrFromInt(addr))),
        : .{ .memory = true });
}

pub fn unmap(hhdm_offset: u64, virt: u64) UpdateError!void {
    const pml4 = tablePtr(cpu.readCr3(), hhdm_offset);
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pml4e = &pml4[@as(usize, @intCast(pml4_idx))];
    if ((pml4e.* & ENTRY_PRESENT) == 0) return error.NotMapped;

    const pdpt = tablePtr(pml4e.*, hhdm_offset);
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pdpte = &pdpt[@as(usize, @intCast(pdpt_idx))];
    if ((pdpte.* & ENTRY_PRESENT) == 0) return error.NotMapped;

    const pd = tablePtr(pdpte.*, hhdm_offset);
    const pd_idx = (virt >> 21) & 0x1FF;
    const pde = &pd[@as(usize, @intCast(pd_idx))];
    if ((pde.* & ENTRY_PRESENT) == 0) return error.NotMapped;

    const pt = tablePtr(pde.*, hhdm_offset);
    const pt_idx = (virt >> 12) & 0x1FF;
    const pte = &pt[@as(usize, @intCast(pt_idx))];
    if ((pte.* & ENTRY_PRESENT) == 0) return error.NotMapped;

    pte.* = 0;
    invlpg(virt);
}

// Marks an already-mapped linear address as user-accessible in the current host page tables.
// This is intentionally narrow and only used for the bring-up CPL3 demo.
pub fn markUserAccessible(hhdm_offset: u64, virt: u64) UpdateError!void {
    const pml4 = tablePtr(cpu.readCr3(), hhdm_offset);
    const pml4e = &pml4[@as(usize, @intCast((virt >> 39) & 0x1FF))];
    if ((pml4e.* & 1) == 0) return error.NotMapped;
    pml4e.* |= ENTRY_USER;
    // Ensure NX is set for user data pages by default unless explicitly executable
    pml4e.* |= ENTRY_NX;

    const pdpt = tablePtr(pml4e.*, hhdm_offset);
    const pdpte = &pdpt[@as(usize, @intCast((virt >> 30) & 0x1FF))];
    if ((pdpte.* & 1) == 0) return error.NotMapped;
    pdpte.* |= ENTRY_USER;
    pdpte.* |= ENTRY_NX;
    // If PDPT maps a 1GiB large page, stop here and do not descend to PDE/PTE.
    if ((pdpte.* & ENTRY_LARGE) != 0) {
        invlpg(virt);
        return;
    }

    const pd = tablePtr(pdpte.*, hhdm_offset);
    const pde = &pd[@as(usize, @intCast((virt >> 21) & 0x1FF))];
    if ((pde.* & 1) == 0) return error.NotMapped;
    pde.* |= ENTRY_USER;
    pde.* |= ENTRY_NX;
    if ((pde.* & ENTRY_LARGE) != 0) {
        invlpg(virt);
        return;
    }

    const pt = tablePtr(pde.*, hhdm_offset);
    const pte = &pt[@as(usize, @intCast((virt >> 12) & 0x1FF))];
    if ((pte.* & 1) == 0) return error.NotMapped;
    pte.* |= ENTRY_USER;
    pte.* |= ENTRY_NX; // Default to NX for user mappings
    invlpg(virt);
}

pub fn mapUserPage(hhdm_offset: u64, pml4_phys: u64, virt: u64, phys: u64, flags: u64) UpdateError!void {
    if (!isCanonical(virt)) return error.InvalidAddress;
    const is_user = (flags & ENTRY_USER) != 0;

    const pml4 = tablePtr(pml4_phys, hhdm_offset);
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pml4e = &pml4[@as(usize, @intCast(pml4_idx))];

    // Ensure PML4E is user-accessible if this is a user mapping
    if (is_user) pml4e.* |= ENTRY_USER;
    const pdpt = try ensureChildTable(pml4e, hhdm_offset, is_user);

    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pdpte = &pdpt[@as(usize, @intCast(pdpt_idx))];
    if (is_user) pdpte.* |= ENTRY_USER;
    const pd = try ensureChildTable(pdpte, hhdm_offset, is_user);

    const pd_idx = (virt >> 21) & 0x1FF;
    const pde = &pd[@as(usize, @intCast(pd_idx))];
    if (is_user) pde.* |= ENTRY_USER;
    const pt = try ensureChildTable(pde, hhdm_offset, is_user);

    const pt_idx = (virt >> 12) & 0x1FF;
    const pte = &pt[@as(usize, @intCast(pt_idx))];

    if ((pte.* & ENTRY_PRESENT) != 0) return error.AlreadyMapped;

    pte.* = (phys & PAGE_MASK) | flags | ENTRY_PRESENT;
    invlpg(virt);
}

pub fn map(hhdm_offset: u64, virt: u64, phys: u64, flags: u64) UpdateError!void {
    if (!isCanonical(virt)) return error.InvalidAddress;
    const is_user = (flags & ENTRY_USER) != 0;

    const pml4 = tablePtr(cpu.readCr3(), hhdm_offset);
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pml4e = &pml4[@as(usize, @intCast(pml4_idx))];
    const pdpt = try ensureChildTable(pml4e, hhdm_offset, is_user);

    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pdpte = &pdpt[@as(usize, @intCast(pdpt_idx))];
    const pd = try ensureChildTable(pdpte, hhdm_offset, is_user);

    const pd_idx = (virt >> 21) & 0x1FF;
    const pde = &pd[@as(usize, @intCast(pd_idx))];
    const pt = try ensureChildTable(pde, hhdm_offset, is_user);

    const pt_idx = (virt >> 12) & 0x1FF;
    const pte = &pt[@as(usize, @intCast(pt_idx))];

    if ((pte.* & ENTRY_PRESENT) != 0) return error.AlreadyMapped;

    pte.* = (phys & PAGE_MASK) | flags | ENTRY_PRESENT;
    invlpg(virt);
}

pub fn translate(hhdm_offset: u64, virt: u64) ?u64 {
    if (!isCanonical(virt)) return null;

    const pml4 = tablePtr(cpu.readCr3(), hhdm_offset);
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pml4e = pml4[@as(usize, @intCast(pml4_idx))];
    if ((pml4e & 1) == 0) return null;

    const pdpt = tablePtr(pml4e, hhdm_offset);
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pdpte = pdpt[@as(usize, @intCast(pdpt_idx))];
    if ((pdpte & 1) == 0) return null;
    if ((pdpte & ENTRY_LARGE) != 0) return translate1GiBLargePage(pdpte, virt);

    const pd = tablePtr(pdpte, hhdm_offset);
    const pd_idx = (virt >> 21) & 0x1FF;
    const pde = pd[@as(usize, @intCast(pd_idx))];
    if ((pde & 1) == 0) return null;
    if ((pde & ENTRY_LARGE) != 0) return translate2MiBLargePage(pde, virt);

    const pt = tablePtr(pde, hhdm_offset);
    const pt_idx = (virt >> 12) & 0x1FF;
    const pte = pt[@as(usize, @intCast(pt_idx))];
    if ((pte & 1) == 0) return null;

    return (pte & PAGE_MASK) | (virt & 0xFFF);
}

pub fn cloneKernelPml4(hhdm_offset: u64) ?u64 {
    const kernel_pml4_phys = cpu.readCr3() & PAGE_MASK;
    const new_pml4_phys = pmm.allocPage() orelse return null;

    const src = tablePtr(kernel_pml4_phys, hhdm_offset);
    const dst = tablePtr(new_pml4_phys, hhdm_offset);

    // Copy all 512 entries to clone the kernel mapping (including HHDM)
    for (0..512) |i| {
        dst[i] = src[i];
    }

    return new_pml4_phys;
}

pub fn loadPml4(pml4_phys: u64) void {
    cpu.writeCr3(pml4_phys & PAGE_MASK);
}
