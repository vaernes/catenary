const std = @import("std");

pub const PART_BASE_LBA: u64 = 8192;
pub const PART_SECTORS: u64 = 2048;
pub const MAX_PARTS: usize = 16;
pub const JOURNAL_LBA: u64 = PART_BASE_LBA - 1;
pub const VM_DISK_BASE_LBA: u64 = PART_BASE_LBA + @as(u64, MAX_PARTS) * PART_SECTORS;
pub const VM_DISK_SECTORS: u64 = PART_SECTORS;
pub const MAX_VM_DISKS: u32 = 8;
pub const PART_MAGIC: u64 = 0x5452_4150_524E_524E;
pub const PART_VERSION: u32 = 2;
pub const PART_MAGIC_V2: u64 = 0x3252_4150_524E_524E;
pub const JOURNAL_MAGIC: u64 = 0x314C_4E4A_524E_524E;
pub const JOURNAL_VERSION: u32 = 1;

pub const Header = extern struct {
    magic: u64,
    slot: u32,
    version: u32,
    start_lba: u64,
    sectors: u64,
    checksum: u32,
    name: [28]u8,
};

pub const JournalRecord = extern struct {
    magic: u64,
    version: u32,
    slot: u32,
    transaction_id: u64,
    header: Header,
    checksum: u32,
    reserved: [4]u8,
};

comptime {
    if (@sizeOf(Header) != 64) @compileError("partition metadata header must remain 64 bytes");
    if (@sizeOf(JournalRecord) != 96) @compileError("partition journal record must remain 96 bytes");
}

const LegacyHeader = extern struct {
    magic: u64,
    slot: u32,
    _pad: u32,
    start_lba: u64,
    sectors: u64,
    name: [32]u8,
};

pub fn startLba(slot: u32) u64 {
    return PART_BASE_LBA + @as(u64, slot) * PART_SECTORS;
}

pub fn vmDiskStartLba(vmid: u32) ?u64 {
    if (vmid == 0 or vmid > MAX_VM_DISKS) return null;
    return VM_DISK_BASE_LBA + @as(u64, vmid - 1) * VM_DISK_SECTORS;
}

pub fn translateVmDiskRange(vmid: u32, guest_sector: u64, nlb: u32) ?u64 {
    if (nlb == 0) return null;
    const base_lba = vmDiskStartLba(vmid) orelse return null;
    const end_sector = std.math.add(u64, guest_sector, nlb) catch return null;
    if (end_sector > VM_DISK_SECTORS) return null;
    return std.math.add(u64, base_lba, guest_sector) catch null;
}

fn headerChecksum(header: *const Header) u32 {
    var copy = header.*;
    copy.checksum = 0;
    var crc: u32 = 0xFFFF_FFFF;
    for (std.mem.asBytes(&copy)) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            const mask = @as(u32, 0) -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return ~crc;
}

fn journalChecksum(record: *const JournalRecord) u32 {
    var copy = record.*;
    copy.checksum = 0;
    var crc: u32 = 0xFFFF_FFFF;
    for (std.mem.asBytes(&copy)) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            const mask = @as(u32, 0) -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return ~crc;
}

pub fn makeHeader(slot: u32) Header {
    var header = Header{
        .magic = PART_MAGIC_V2,
        .slot = slot,
        .version = PART_VERSION,
        .start_lba = startLba(slot),
        .sectors = PART_SECTORS,
        .checksum = 0,
        .name = @splat(0),
    };
    @memcpy(header.name[0..6], "rootfs");
    header.checksum = headerChecksum(&header);
    return header;
}

pub fn makeJournalSector(slot: u32, transaction_id: u64) [512]u8 {
    var sector: [512]u8 = @splat(0);
    var record = JournalRecord{
        .magic = JOURNAL_MAGIC,
        .version = JOURNAL_VERSION,
        .slot = slot,
        .transaction_id = transaction_id,
        .header = makeHeader(slot),
        .checksum = 0,
        .reserved = @splat(0),
    };
    record.checksum = journalChecksum(&record);
    @memcpy(sector[0..@sizeOf(JournalRecord)], std.mem.asBytes(&record));
    return sector;
}

pub fn readJournalRecord(bytes: []const u8) ?JournalRecord {
    if (bytes.len < 512) return null;
    const record = std.mem.bytesToValue(JournalRecord, bytes[0..@sizeOf(JournalRecord)]);
    if (record.magic != JOURNAL_MAGIC or record.version != JOURNAL_VERSION or
        record.slot >= MAX_PARTS or record.transaction_id == 0 or
        !std.mem.allEqual(u8, &record.reserved, 0) or
        record.checksum != journalChecksum(&record) or
        !isValidHeader(std.mem.asBytes(&record.header), record.slot) or
        !isEmptySector(bytes[@sizeOf(JournalRecord)..512]))
    {
        return null;
    }
    return record;
}

pub fn isValidHeader(bytes: []const u8, slot: u32) bool {
    if (bytes.len < @sizeOf(LegacyHeader)) return false;
    const legacy = std.mem.bytesToValue(LegacyHeader, bytes[0..@sizeOf(LegacyHeader)]);
    if (legacy.magic == PART_MAGIC and legacy._pad == 0 and
        legacy.slot == slot and legacy.start_lba == startLba(slot) and
        legacy.sectors == PART_SECTORS and std.mem.eql(u8, legacy.name[0..6], "rootfs"))
    {
        return true;
    }
    if (bytes.len < @sizeOf(Header)) return false;
    const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
    return header.magic == PART_MAGIC_V2 and
        header.slot == slot and
        header.version == PART_VERSION and
        header.start_lba == startLba(slot) and
        header.sectors == PART_SECTORS and
        std.mem.eql(u8, header.name[0..6], "rootfs") and
        header.checksum == headerChecksum(&header);
}

pub fn isEmptySector(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

test "partition headers validate identity, geometry, and name" {
    var bytes: [512]u8 = @splat(0);
    const header = makeHeader(2);
    @memcpy(bytes[0..@sizeOf(Header)], std.mem.asBytes(&header));

    try std.testing.expect(isValidHeader(&bytes, 2));
    try std.testing.expect(!isValidHeader(&bytes, 1));
    try std.testing.expect(!isValidHeader(bytes[0..8], 2));

    bytes[@offsetOf(Header, "sectors")] ^= 1;
    try std.testing.expect(!isValidHeader(&bytes, 2));
    try std.testing.expect(!isEmptySector(&bytes));

    const wrong_magic = makeHeader(2);
    var invalid = wrong_magic;
    invalid.magic = PART_MAGIC;
    invalid.checksum = headerChecksum(&invalid);
    @memcpy(bytes[0..@sizeOf(Header)], std.mem.asBytes(&invalid));
    try std.testing.expect(!isValidHeader(&bytes, 2));
}

test "legacy partition headers remain readable during metadata format upgrade" {
    var bytes: [512]u8 = @splat(0);
    const header = LegacyHeader{
        .magic = PART_MAGIC,
        .slot = 2,
        ._pad = 0,
        .start_lba = startLba(2),
        .sectors = PART_SECTORS,
        .name = "rootfs".* ++ @as([26]u8, @splat(0)),
    };
    @memcpy(bytes[0..@sizeOf(LegacyHeader)], std.mem.asBytes(&header));

    try std.testing.expect(isValidHeader(&bytes, 2));
    try std.testing.expect(!isValidHeader(&bytes, 3));
    try std.testing.expect(!isEmptySector(&bytes));
}

test "only zero-filled sectors are treated as unused metadata slots" {
    const empty: [512]u8 = @splat(0);
    try std.testing.expect(isEmptySector(&empty));

    var torn: [512]u8 = @splat(0);
    torn[0] = 0xFF;
    try std.testing.expect(!isEmptySector(&torn));
}

test "journal record validates and carries an idempotent header replay" {
    const sector = makeJournalSector(3, 7);
    const record = readJournalRecord(&sector) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), record.slot);
    try std.testing.expectEqual(@as(u64, 7), record.transaction_id);
    try std.testing.expect(isValidHeader(std.mem.asBytes(&record.header), 3));
    const empty: [512]u8 = @splat(0);
    try std.testing.expect(readJournalRecord(&empty) == null);
}

test "journal rejects torn, corrupted, invalid, and mismatched records" {
    const valid = makeJournalSector(3, 7);
    var torn = valid;
    torn[0] ^= 1;
    try std.testing.expect(readJournalRecord(&torn) == null);

    var trailing_data = valid;
    trailing_data[511] = 1;
    try std.testing.expect(readJournalRecord(&trailing_data) == null);

    var invalid_slot = makeJournalSector(3, 7);
    var record = std.mem.bytesToValue(JournalRecord, invalid_slot[0..@sizeOf(JournalRecord)]);
    record.slot = @intCast(MAX_PARTS);
    record.checksum = 0;
    record.checksum = journalChecksum(&record);
    @memcpy(invalid_slot[0..@sizeOf(JournalRecord)], std.mem.asBytes(&record));
    try std.testing.expect(readJournalRecord(&invalid_slot) == null);
}

test "per-VM disk extents stay disjoint from host partitions and bounded per VM" {
    const last_part_end = startLba(@intCast(MAX_PARTS - 1)) + PART_SECTORS;
    const vm1_base = vmDiskStartLba(1) orelse return error.TestUnexpectedResult;
    const vm2_base = vmDiskStartLba(2) orelse return error.TestUnexpectedResult;
    const vm8_base = vmDiskStartLba(MAX_VM_DISKS) orelse return error.TestUnexpectedResult;

    try std.testing.expect(vmDiskStartLba(0) == null);
    try std.testing.expect(vmDiskStartLba(MAX_VM_DISKS + 1) == null);
    try std.testing.expect(vm1_base >= last_part_end);
    try std.testing.expectEqual(vm1_base + VM_DISK_SECTORS, vm2_base);
    try std.testing.expectEqual(vm1_base + (@as(u64, MAX_VM_DISKS - 1) * VM_DISK_SECTORS), vm8_base);

    try std.testing.expectEqual(@as(?u64, vm1_base), translateVmDiskRange(1, 0, 1));
    try std.testing.expectEqual(@as(?u64, vm1_base + VM_DISK_SECTORS - 1), translateVmDiskRange(1, VM_DISK_SECTORS - 1, 1));
    try std.testing.expectEqual(@as(?u64, null), translateVmDiskRange(1, VM_DISK_SECTORS, 1));
    try std.testing.expectEqual(@as(?u64, null), translateVmDiskRange(1, VM_DISK_SECTORS - 1, 2));
    try std.testing.expectEqual(@as(?u64, null), translateVmDiskRange(1, 0, 0));
}
