/// Kernel W^X (Write XOR Execute) Enforcement.
///
/// After boot, walk the active kernel page tables and verify that no
/// page is simultaneously Writable (PTE bit 1) and Executable (NX bit 63
/// clear).  If a violation is found it is fixed by setting the NX bit on
/// the offending PTE and the violation is reported via serial.
///
/// This module is invoked once during late boot, after the PMM, HHDM,
/// and initial hardening pass have completed.
///
/// W^X is a fundamental code integrity invariant:
///   • Code pages (.text) must be executable but NOT writable.
///   • Data pages (.data, .bss, stacks) must be writable but NOT executable.
///   • If an attacker finds a write primitive, W^X prevents turning it into
///     code execution by ensuring no page can serve both roles.
const builtin = @import("builtin");

const ENTRY_PRESENT: u64 = 1 << 0;
const ENTRY_RW: u64 = 1 << 1;
const ENTRY_LARGE: u64 = 1 << 7;
const ENTRY_NX: u64 = @as(u64, 1) << 63;
const PAGE_MASK: u64 = 0x000F_FFFF_FFFF_F000;

fn serialWrite(s: []const u8) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    for (s) |c| {
        asm volatile ("outb %al, %dx"
            :
            : [al] "{al}" (c),
              [dx] "{dx}" (@as(u16, 0x3F8)),
        );
    }
}

fn printHex(n: u64) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        asm volatile ("outb %al, %dx"
            :
            : [al] "{al}" (hex[nibble]),
              [dx] "{dx}" (@as(u16, 0x3F8)),
        );
        if (shift >= 4) shift -= 4;
    }
}

fn tablePtr(table_phys: u64, hhdm_offset: u64) [*]u64 {
    return @ptrFromInt((table_phys & PAGE_MASK) + hhdm_offset);
}

/// Audit result returned by `enforce`.
pub const AuditResult = struct {
    pages_audited: u64 = 0,
    violations_found: u64 = 0,
    violations_fixed: u64 = 0,
};

/// Walk the kernel-half (indices 256..511) of the active PML4 and enforce
/// W^X on every present leaf PTE.  Returns an audit summary.
///
/// Only operates on the higher-half because the lower-half belongs to
/// per-service user address spaces and is managed separately.
pub fn enforce(hhdm_offset: u64) AuditResult {
    if (comptime builtin.cpu.arch != .x86_64) return .{};

    var result: AuditResult = .{};
    const cr3 = asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64),
    );
    const pml4 = tablePtr(cr3, hhdm_offset);

    // Walk kernel-half PML4 entries (indices 256..511).
    var pml4_idx: usize = 256;
    while (pml4_idx < 512) : (pml4_idx += 1) {
        const pml4e = pml4[pml4_idx];
        if ((pml4e & ENTRY_PRESENT) == 0) continue;

        const pdpt = tablePtr(pml4e, hhdm_offset);
        var pdpt_idx: usize = 0;
        while (pdpt_idx < 512) : (pdpt_idx += 1) {
            const pdpte = pdpt[pdpt_idx];
            if ((pdpte & ENTRY_PRESENT) == 0) continue;
            // 1 GiB large page — check at this level.
            if ((pdpte & ENTRY_LARGE) != 0) {
                result.pages_audited += 1;
                if (isWxViolation(pdpte)) {
                    result.violations_found += 1;
                    pdpt[pdpt_idx] = pdpte | ENTRY_NX;
                    result.violations_fixed += 1;
                }
                continue;
            }

            const pd = tablePtr(pdpte, hhdm_offset);
            var pd_idx: usize = 0;
            while (pd_idx < 512) : (pd_idx += 1) {
                const pde = pd[pd_idx];
                if ((pde & ENTRY_PRESENT) == 0) continue;
                // 2 MiB large page.
                if ((pde & ENTRY_LARGE) != 0) {
                    result.pages_audited += 1;
                    if (isWxViolation(pde)) {
                        result.violations_found += 1;
                        pd[pd_idx] = pde | ENTRY_NX;
                        result.violations_fixed += 1;
                    }
                    continue;
                }

                const pt = tablePtr(pde, hhdm_offset);
                var pt_idx: usize = 0;
                while (pt_idx < 512) : (pt_idx += 1) {
                    const pte = pt[pt_idx];
                    if ((pte & ENTRY_PRESENT) == 0) continue;
                    result.pages_audited += 1;
                    if (isWxViolation(pte)) {
                        result.violations_found += 1;
                        pt[pt_idx] = pte | ENTRY_NX;
                        result.violations_fixed += 1;
                    }
                }
            }
        }
    }

    // Report summary.
    serialWrite("W^X audit: ");
    printHex(result.pages_audited);
    serialWrite(" pages checked, ");
    printHex(result.violations_found);
    serialWrite(" violations found, ");
    printHex(result.violations_fixed);
    serialWrite(" fixed\n");

    // Flush TLB to make NX fixes take effect.
    if (result.violations_fixed > 0) {
        const cr3_val = asm volatile ("mov %%cr3, %[result]"
            : [result] "=r" (-> u64),
        );
        asm volatile ("mov %[value], %%cr3"
            :
            : [value] "r" (cr3_val),
            : .{ .memory = true });
    }

    return result;
}

/// A W^X violation is a page that is both writable (RW=1) and executable
/// (NX=0).
inline fn isWxViolation(entry: u64) bool {
    const writable = (entry & ENTRY_RW) != 0;
    const executable = (entry & ENTRY_NX) == 0;
    return writable and executable;
}
