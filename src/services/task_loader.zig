const std = @import("std");
const pmm = @import("../kernel/pmm.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const paging = @import("../arch/x86_64/paging.zig");
const elf_loader = @import("elf_loader.zig");
const main = @import("../main.zig");

// Note: In a real kernel we'd have a more robust task/process structure.
// This is the Service Manager code to load netd and storaged.

const PAGE_SIZE: u64 = 4096;
const ENTRY_USER: u64 = 1 << 2;
const ENTRY_WRITE: u64 = 1 << 1;
const ENTRY_PRESENT: u64 = 1 << 0;

pub const USER_PAGE_FLAGS: u64 = ENTRY_USER | ENTRY_WRITE | ENTRY_PRESENT;
pub const USER_STACK_TOP_VADDR: u64 = 0x0000_7FFF_FFFF_0000;
pub const USER_BOOTSTRAP_VADDR: u64 = USER_STACK_TOP_VADDR - (64 * PAGE_SIZE);

pub const LoadedTask = struct {
    cr3: u64,
    entry: u64,
    stack_top: u64,
};

pub const LoadError = error{
    ElfParseError,
    OutOfMemory,
    MappingFailed,
};

pub fn mapPageInAddressSpace(cr3: u64, hhdm_offset: u64, virt: u64, phys: u64, flags: u64) LoadError!void {
    const old_cr3 = cpu.readCr3();
    cpu.writeCr3(cr3);
    defer cpu.writeCr3(old_cr3);

    paging.map(hhdm_offset, virt, phys, flags) catch |err| {
        main.serialWrite("task_loader: paging.map failed: ");
        if (err == error.AlreadyMapped) {
            main.serialWrite("AlreadyMapped\n");
        } else if (err == error.InvalidAddress) {
            main.serialWrite("InvalidAddress\n");
        } else {
            main.serialWrite("Other\n");
        }
        return error.MappingFailed;
    };
}

/// Loads an ELF module from Limine memory into a newly allocated user address space.
/// Returns the physical address of the PML4 (CR3) and the entry point.
pub fn loadElfIntoNewSpace(elf_bytes: []const u8, hhdm_offset: u64) LoadError!LoadedTask {
    const loaded = elf_loader.parseInMem(elf_bytes) catch return error.ElfParseError;

    // 1. Allocate a new PML4 for the task.
    const pml4_phys = pmm.allocPage() orelse return error.OutOfMemory;
    const pml4_virt: [*]u64 = @ptrFromInt(pml4_phys + hhdm_offset);

    // Clear PML4
    for (0..512) |i| pml4_virt[i] = 0;

    // 2. Clone the kernel's higher-half mappings into the new PML4.
    // This allows the task to switch to kernel mode via interrupts/syscalls.
    const current_pml4: [*]u64 = @ptrFromInt(cpu.readCr3() + hhdm_offset);
    // Clone indices 256..511 (higher half)
    for (256..512) |i| {
        pml4_virt[i] = current_pml4[i];
    }

    // 3. Temporary switch to the new address space to use the generic paging.map function.
    // Or we could modify paging.map to take a PML4.
    // Since we're in Ring 0, we can safely flip CR3 as long as the kernel mappings are identical.
    const old_cr3 = cpu.readCr3();
    cpu.writeCr3(pml4_phys);
    defer cpu.writeCr3(old_cr3);

    // 4. Map and copy PT_LOAD segments.
    // Re-parse program headers to iterate segments.
    const hdr: *const elf_loader.Elf64_Ehdr = @ptrCast(@alignCast(elf_bytes.ptr));
    for (0..hdr.e_phnum) |i| {
        const ph_offset = hdr.e_phoff + (i * hdr.e_phentsize);
        const ph: *const elf_loader.Elf64_Phdr = @ptrCast(@alignCast(&elf_bytes[ph_offset]));

        if (ph.p_type == std.elf.PT_LOAD) {
            const start_vaddr = ph.p_vaddr & ~(PAGE_SIZE - 1);
            const end_vaddr = (ph.p_vaddr + ph.p_memsz + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);

            var vaddr = start_vaddr;
            while (vaddr < end_vaddr) : (vaddr += PAGE_SIZE) {
                const user_frame = pmm.allocPage() orelse return error.OutOfMemory;

                // Map the frame into the new address space with USER | WRITE | PRESENT bits.
                paging.map(hhdm_offset, vaddr, user_frame, USER_PAGE_FLAGS) catch return error.MappingFailed;

                // Zero the frame first
                const frame_ptr: [*]u8 = @ptrFromInt(user_frame + hhdm_offset);
                for (0..4096) |byte_idx| frame_ptr[byte_idx] = 0;

                // Copy data if within filesz
                if (vaddr < ph.p_vaddr + ph.p_filesz) {
                    const copy_start = if (vaddr < ph.p_vaddr) ph.p_vaddr else vaddr;
                    const copy_end = if (vaddr + PAGE_SIZE > ph.p_vaddr + ph.p_filesz) ph.p_vaddr + ph.p_filesz else vaddr + PAGE_SIZE;
                    const len = copy_end - copy_start;

                    const src_offset = ph.p_offset + (copy_start - ph.p_vaddr);
                    const dest_offset = copy_start - vaddr;

                    for (0..len) |j| {
                        frame_ptr[dest_offset + j] = elf_bytes[src_offset + j];
                    }
                }
            }
        }
    }

    // 5. Setup a user stack.
    const stack_pages = 32; // 128KB stack
    const stack_top_vaddr = USER_STACK_TOP_VADDR;
    for (0..stack_pages) |i| {
        const stack_frame = pmm.allocPage() orelse return error.OutOfMemory;
        const vaddr = stack_top_vaddr - ((i + 1) * PAGE_SIZE);
        paging.map(hhdm_offset, vaddr, stack_frame, USER_PAGE_FLAGS) catch {
            main.serialWrite("task_loader: stack map failed\n");
            return error.MappingFailed;
        };
    }

    return .{ .cr3 = pml4_phys, .entry = loaded.entry, .stack_top = stack_top_vaddr };
}
