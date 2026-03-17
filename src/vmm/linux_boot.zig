const std = @import("std");

pub const ParseError = error{
    ImageTooSmall,
    InvalidBootFlag,
    InvalidHeaderMagic,
};

pub const setup_header_offset: usize = 0x1F1;
pub const zero_page_size: usize = 4096;
pub const kernel_load_min_gpa: u64 = 0x0010_0000;
pub const default_guest_ram_bytes: u64 = 512 * 1024 * 1024;
pub const default_cmdline_gpa: u64 = 0x0002_0000;
pub const default_boot_params_gpa: u64 = 0x0000_7000;
pub const default_guest_stack_top_gpa: u64 = 0x0008_0000;
pub const default_guest_pml4_gpa: u64 = 0x0000_9000;
pub const default_guest_pdpt_gpa: u64 = 0x0000_A000;
pub const default_guest_pd_gpa: u64 = 0x0000_B000;

pub const ParsedBzImage = struct {
    image: []const u8,
    setup_sects: u8,
    setup_bytes: usize,
    protected_mode_offset: usize,
    protected_mode_size: usize,
    protocol_version: u16,
    loadflags: u8,
    xloadflags: u16,
    cmdline_size: u32,
    kernel_alignment: u32,
    relocatable_kernel: bool,
    code32_start: u32,
    init_size: u32,
    preferred_address: u64,
    handover_offset: u32,
};

const setup_sects_offset: usize = 0x1F1;
const boot_flag_offset: usize = 0x1FE;
const header_magic_offset: usize = 0x202;
const version_offset: usize = 0x206;
const loadflags_offset: usize = 0x211;
const code32_start_offset: usize = 0x214;
const kernel_alignment_offset: usize = 0x230;
const relocatable_kernel_offset: usize = 0x234;
const xloadflags_offset: usize = 0x236;
const cmdline_size_offset: usize = 0x238;
const pref_address_offset: usize = 0x258;
const init_size_offset: usize = 0x260;
const handover_offset_offset: usize = 0x264;
const type_of_loader_offset: usize = 0x210;
const cmd_line_ptr_offset: usize = 0x228;
const vid_mode_offset: usize = 0x1FA;
const alt_mem_k_offset: usize = 0x1E0;
const e820_entries_offset: usize = 0x1E8;
const sentinel_offset: usize = 0x1EF;
const e820_table_offset: usize = 0x2D0;

const e820_type_ram: u32 = 1;
const e820_type_reserved: u32 = 2;
const e820_entry_size: usize = 20;

pub const LaunchLayout = struct {
    boot_params_gpa: u64,
    cmdline_gpa: u64,
    kernel_load_gpa: u64,
    guest_stack_top_gpa: u64,
    guest_pml4_gpa: u64,
    guest_pdpt_gpa: u64,
    guest_pd_gpa: u64,
};

fn readLe16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readLe32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readLe64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn writeLe16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeLe32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn writeLe64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}

pub fn parseBzImage(image: []const u8) ParseError!ParsedBzImage {
    var parsed: ParsedBzImage = undefined;
    try parseBzImageInto(&parsed, image);
    return parsed;
}

pub fn parseBzImageInto(parsed: *ParsedBzImage, image: []const u8) ParseError!void {
    if (image.len < handover_offset_offset + 4) {
        return error.ImageTooSmall;
    }
    if (readLe16(image, boot_flag_offset) != 0xAA55) {
        return error.InvalidBootFlag;
    }
    if (readLe32(image, header_magic_offset) != 0x53726448) {
        return error.InvalidHeaderMagic;
    }

    const setup_sects = if (image[setup_sects_offset] == 0) 4 else image[setup_sects_offset];
    const setup_bytes = (@as(usize, setup_sects) + 1) * 512;
    if (image.len < setup_bytes) {
        return error.ImageTooSmall;
    }

    parsed.* = .{
        .image = image,
        .setup_sects = setup_sects,
        .setup_bytes = setup_bytes,
        .protected_mode_offset = setup_bytes,
        .protected_mode_size = image.len - setup_bytes,
        .protocol_version = readLe16(image, version_offset),
        .loadflags = image[loadflags_offset],
        .xloadflags = readLe16(image, xloadflags_offset),
        .cmdline_size = readLe32(image, cmdline_size_offset),
        .kernel_alignment = readLe32(image, kernel_alignment_offset),
        .relocatable_kernel = image[relocatable_kernel_offset] != 0,
        .code32_start = readLe32(image, code32_start_offset),
        .init_size = readLe32(image, init_size_offset),
        .preferred_address = readLe64(image, pref_address_offset),
        .handover_offset = readLe32(image, handover_offset_offset),
    };
}

pub fn protectedModeImage(parsed: *const ParsedBzImage) []const u8 {
    return parsed.image[parsed.protected_mode_offset..];
}

pub fn protectedModePageCount(parsed: *const ParsedBzImage, page_size: usize) usize {
    return (parsed.protected_mode_size + page_size - 1) / page_size;
}

pub fn bootParamsTemplate(parsed: *const ParsedBzImage) []const u8 {
    const header_end = @min(parsed.image.len, 0x0202 + @as(usize, parsed.image[0x0201]));
    return parsed.image[setup_header_offset..header_end];
}

pub fn defaultLayout(parsed: *const ParsedBzImage) LaunchLayout {
    const preferred = if (parsed.preferred_address != 0) parsed.preferred_address else parsed.code32_start;
    const kernel_load = @max(kernel_load_min_gpa, preferred & 0xFFFF_FFFF_FFFF_F000);
    return .{
        .boot_params_gpa = default_boot_params_gpa,
        .cmdline_gpa = default_cmdline_gpa,
        .kernel_load_gpa = kernel_load,
        .guest_stack_top_gpa = default_guest_stack_top_gpa,
        .guest_pml4_gpa = default_guest_pml4_gpa,
        .guest_pdpt_gpa = default_guest_pdpt_gpa,
        .guest_pd_gpa = default_guest_pd_gpa,
    };
}

fn writeE820Entry(page: []u8, index: usize, addr: u64, size: u64, entry_type: u32) void {
    const base = e820_table_offset + (index * e820_entry_size);
    writeLe64(page, base + 0, addr);
    writeLe64(page, base + 8, size);
    writeLe32(page, base + 16, entry_type);
}

pub fn buildBootParamsPage(parsed: *const ParsedBzImage, layout: LaunchLayout, cmdline: []const u8, guest_ram_bytes: u64) [zero_page_size]u8 {
    _ = cmdline;
    var page: [zero_page_size]u8 = [_]u8{0} ** zero_page_size;
    const template = bootParamsTemplate(parsed);
    std.mem.copyForwards(u8, page[setup_header_offset .. setup_header_offset + template.len], template);

    // Minimal mandatory setup-header fields for 64-bit Linux boot protocol.
    // Documentation: Documentation/x86/boot.rst
    page[type_of_loader_offset] = 0xFF; // Unspecified bootloader
    page[loadflags_offset] |= 1 << 7; // CAN_USE_HEAP
    writeLe32(page[0..], code32_start_offset, @as(u32, @truncate(layout.kernel_load_gpa)));
    writeLe32(page[0..], cmd_line_ptr_offset, @as(u32, @truncate(layout.cmdline_gpa)));
    writeLe16(page[0..], boot_flag_offset, 0xAA55);
    writeLe16(page[0..], vid_mode_offset, 0xFFFF);
    writeLe32(page[0..], alt_mem_k_offset, @as(u32, @truncate((guest_ram_bytes - 0x100000) / 1024)));
    page[e820_entries_offset] = 3;
    page[sentinel_offset] = 0xFF;

    // Present a bounded memory map with standard PC hole and EBDA/BIOS region reserved.
    // This helps avoid #PF at 0xFF000 during Linux's late boot probes.
    writeE820Entry(page[0..], 0, 0x00000000, 0x0009FC00, e820_type_ram);
    writeE820Entry(page[0..], 1, 0x0009FC00, 0x00060400, e820_type_reserved); // EBDA/BIOS/VGA hole
    writeE820Entry(page[0..], 2, 0x00100000, guest_ram_bytes - 0x100000, e820_type_ram);

    return page;
}

pub fn supports64BitBoot(parsed: *const ParsedBzImage) bool {
    return (parsed.xloadflags & 0x1) != 0;
}

pub fn kernelEntryOffset64(parsed: *const ParsedBzImage) u64 {
    _ = parsed;
    return 0x200;
}

pub fn initIdentityPageTables(pml4: *[512]u64, pdpt: *[512]u64, pd: *[512]u64, map_bytes: u64) void {
    @memset(pml4, 0);
    @memset(pdpt, 0);
    @memset(pd, 0);

    pml4[0] = default_guest_pdpt_gpa | 0x3;
    pdpt[0] = default_guest_pd_gpa | 0x3;

    const huge_page_size: u64 = 2 * 1024 * 1024;
    const pd_entries = @min(@as(usize, 512), @as(usize, @intCast((map_bytes + huge_page_size - 1) / huge_page_size)));
    var i: usize = 0;
    while (i < pd_entries) : (i += 1) {
        const phys = @as(u64, @intCast(i)) * huge_page_size;
        pd[i] = phys | 0x83; // present + writable + PS
    }
}
