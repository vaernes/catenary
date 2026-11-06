const std = @import("std");

pub const PART_BASE_LBA: u64 = 8192;
pub const PART_SECTORS: u64 = 2048;
pub const MAX_PARTS: usize = 16;
pub const PART_MAGIC: u64 = 0x5452_4150_524E_524E;

pub const Header = extern struct {
    magic: u64,
    slot: u32,
    _pad: u32 = 0,
    start_lba: u64,
    sectors: u64,
    name: [32]u8,
};

pub fn startLba(slot: u32) u64 {
    return PART_BASE_LBA + @as(u64, slot) * PART_SECTORS;
}

pub fn isValidHeader(bytes: []const u8, slot: u32) bool {
    if (bytes.len < @sizeOf(Header)) return false;
    const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
    return header.magic == PART_MAGIC and
        header.slot == slot and
        header.start_lba == startLba(slot) and
        header.sectors == PART_SECTORS and
        std.mem.eql(u8, header.name[0..6], "rootfs");
}

test "partition headers validate identity, geometry, and name" {
    var bytes: [512]u8 = @splat(0);
    const header = Header{
        .magic = PART_MAGIC,
        .slot = 2,
        .start_lba = startLba(2),
        .sectors = PART_SECTORS,
        .name = "rootfs".* ++ @as([26]u8, @splat(0)),
    };
    @memcpy(bytes[0..@sizeOf(Header)], std.mem.asBytes(&header));

    try std.testing.expect(isValidHeader(&bytes, 2));
    try std.testing.expect(!isValidHeader(&bytes, 1));
    try std.testing.expect(!isValidHeader(bytes[0..8], 2));

    bytes[@offsetOf(Header, "magic")] = 0;
    try std.testing.expect(!isValidHeader(&bytes, 2));
}
