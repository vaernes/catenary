const std = @import("std");

pub const ElfError = error{
    BadMagic,
    Not64Bit,
    NotLittleEndian,
    NotExecutable,
    BadArchitecture,
    BadProgramHeaderSize,
    ProgramHeaderOutOfBounds,
    SegmentFileLargerThanMemory,
    SegmentOutOfBounds,
    SegmentRangeOverflow,
};

pub const Elf64_Ehdr = std.elf.Elf64_Ehdr;
pub const Elf64_Phdr = std.elf.Elf64_Phdr;

pub const LoadedElf = struct {
    entry: u64,
    load_min: u64,
    load_max: u64,
};

/// Parses an ELF completely mapped in memory (from Limine module wrapper)
/// and calculates its load boundaries and entry point.
pub fn parseInMem(elf_bytes: []const u8) ElfError!LoadedElf {
    if (elf_bytes.len < @sizeOf(Elf64_Ehdr)) return error.BadMagic;

    const hdr: *const Elf64_Ehdr = @ptrCast(@alignCast(elf_bytes.ptr));
    if (!std.mem.eql(u8, hdr.e_ident[0..4], std.elf.MAGIC)) return error.BadMagic;
    if (hdr.e_ident[std.elf.EI_CLASS] != std.elf.ELFCLASS64) return error.Not64Bit;
    if (hdr.e_ident[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) return error.NotLittleEndian;
    if (@intFromEnum(hdr.e_type) != @intFromEnum(std.elf.ET.EXEC)) return error.NotExecutable;
    if (@intFromEnum(hdr.e_machine) != @intFromEnum(std.elf.EM.X86_64)) return error.BadArchitecture;

    if (hdr.e_phentsize < @sizeOf(Elf64_Phdr)) return error.BadProgramHeaderSize;

    // Bounds check program headers
    const ph_start = hdr.e_phoff;
    const ph_size = std.math.mul(u64, @as(u64, hdr.e_phnum), @as(u64, hdr.e_phentsize)) catch return error.ProgramHeaderOutOfBounds;
    const ph_end = std.math.add(u64, ph_start, ph_size) catch return error.ProgramHeaderOutOfBounds;
    if (ph_end > elf_bytes.len) return error.ProgramHeaderOutOfBounds;

    var res: LoadedElf = .{
        .entry = hdr.e_entry,
        .load_min = ~@as(u64, 0),
        .load_max = 0,
    };

    for (0..hdr.e_phnum) |i| {
        const ph_index_offset = std.math.mul(u64, @as(u64, @intCast(i)), @as(u64, hdr.e_phentsize)) catch return error.ProgramHeaderOutOfBounds;
        const ph_offset = ph_start + ph_index_offset;
        const ph_struct_end = ph_offset + @sizeOf(Elf64_Phdr);
        if (ph_struct_end > ph_end or ph_struct_end > elf_bytes.len) return error.ProgramHeaderOutOfBounds;

        const ph: *const Elf64_Phdr = @ptrCast(@alignCast(&elf_bytes[ph_offset]));
        if (ph.p_type == std.elf.PT_LOAD) {
            const vaddr_start = ph.p_vaddr;
            const vaddr_end = std.math.add(u64, ph.p_vaddr, ph.p_memsz) catch return error.SegmentRangeOverflow;
            if (ph.p_filesz > ph.p_memsz) return error.SegmentFileLargerThanMemory;

            const segment_file_end = std.math.add(u64, ph.p_offset, ph.p_filesz) catch return error.SegmentOutOfBounds;
            if (segment_file_end > elf_bytes.len) return error.SegmentOutOfBounds;

            if (vaddr_start < res.load_min) res.load_min = vaddr_start;
            if (vaddr_end > res.load_max) res.load_max = vaddr_end;
        }
    }

    return res;
}
