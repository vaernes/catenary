// Limine bootloader protocol structures for Catenary OS.
// Reference: https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md
//
// All Limine requests share a common header:
//   id[0] and id[1] = common magic
//   id[2] and id[3] = feature-specific magic

const std = @import("std");

pub const COMMON_MAGIC_0: u64 = 0xc7b1dd30df4c8b88;
pub const COMMON_MAGIC_1: u64 = 0x0a82e883a194f07b;

pub const RequestId = [4]u64;

pub const COMMON_ID: [2]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1 };

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    kind: u64,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]*MemmapEntry,
};

pub const MemmapRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,
    response: ?*MemmapResponse = null,
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

pub const File = extern struct {
    revision: u64,
    address: [*]u8,
    size: u64,
    path: [*:0]const u8,
    cmdline: [*:0]const u8,
    media_type: u32,
    _unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_guid: [16]u8,
    gpt_part_guid: [16]u8,
    part_uuid: [16]u8,
};

pub const KernelFileResponse = extern struct {
    revision: u64,
    kernel_file: ?*File,
};

pub const KernelFileRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69 },
    revision: u64 = 0,
    response: ?*KernelFileResponse = null,
};

pub const KernelAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

pub const KernelAddressRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    revision: u64 = 0,
    response: ?*KernelAddressResponse = null,
};

pub const MEMMAP_USABLE = 0;
pub const MEMMAP_RESERVED = 1;
pub const MEMMAP_ACPI_RECLAIMABLE = 2;
pub const MEMMAP_ACPI_NVS = 3;
pub const MEMMAP_BAD_MEMORY = 4;
pub const MEMMAP_BOOTLOADER_RECLAIMABLE = 5;
pub const MEMMAP_KERNEL_AND_MODULES = 6;
pub const MEMMAP_FRAMEBUFFER = 7;

pub const VideoMode = extern struct {
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    _unused: [7]u8,
    edid_size: u64,
    edid: ?[*]u8,
    mode_count: u64,
    modes: [*]*VideoMode,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]*Framebuffer,
};

pub const FramebufferRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,
    response: ?*FramebufferResponse = null,
};

pub const StackSizeResponse = extern struct {
    revision: u64,
};

pub const StackSizeRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d },
    revision: u64 = 0,
    response: ?*StackSizeResponse = null,
    stack_size: u64,
};



pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules: ?[*]?[*]File,
};

pub const InternalModule = extern struct {
    path: [*]const u8,
    cmdline: [*]const u8,
    flags: u64,
};

pub const ModuleRequest = extern struct {
    id: [4]u64 = .{ COMMON_MAGIC_0, COMMON_MAGIC_1, 0x3e7e279702be32af, 0xca1c4f3bd1280cee },
    revision: u64 = 1,
    response: ?*ModuleResponse = null,
    internal_module_count: u64 = 0,
    internal_modules: ?[*]?[*]InternalModule = null,
};
