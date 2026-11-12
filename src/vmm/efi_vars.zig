const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Crc32 = std.hash.Crc32;

pub const MAX_VMS: usize = 8;
pub const EFI_VAR_MMIO_BASE: u64 = 0xFE00_2000;
pub const EFI_VAR_MMIO_SIZE: u64 = 0x1000;
pub const EFI_VAR_MAGIC: u32 = 0x4546_4956; // "EFIV"
pub const MAX_DB_HASHES: usize = 4;

// MMIO Register offsets (32-bit aligned)
pub const REG_MAGIC: u64 = 0x000;
pub const REG_STATUS: u64 = 0x004;
pub const REG_SECURE_BOOT: u64 = 0x008;
pub const REG_SETUP_MODE: u64 = 0x00C;
pub const REG_BOOT_ORDER: u64 = 0x010;
pub const REG_BOOT0001: u64 = 0x014;
pub const REG_BOOT_COUNT: u64 = 0x018;
pub const REG_GENERATION: u64 = 0x01C;
pub const REG_CRC32: u64 = 0x020;
pub const REG_CMD: u64 = 0x024;
pub const REG_LAST_AUTH_RESULT: u64 = 0x028;

// Commands written to REG_CMD
pub const CMD_COMMIT_NV: u32 = 0x01;
pub const CMD_RELOAD_NV: u32 = 0x02;
pub const CMD_VERIFY_CRC: u32 = 0x03;

// Status bits in REG_STATUS
pub const STATUS_READY: u32 = 1 << 0;
pub const STATUS_COMMITTED: u32 = 1 << 1;
pub const STATUS_CRC_OK: u32 = 1 << 2;
pub const STATUS_PK_ENROLLED: u32 = 1 << 3;
pub const STATUS_KEK_ENROLLED: u32 = 1 << 4;
pub const STATUS_DB_ENROLLED: u32 = 1 << 5;
pub const STATUS_DBX_ENROLLED: u32 = 1 << 6;

pub const SecureBootError = error{
    InvalidVmId,
    EmptyTrustDatabase,
    RevokedInDbx,
    NotInAllowedDb,
};

pub const NvPayload = extern struct {
    boot_order: u32 = 0,
    boot0001: u32 = 0,
    boot_count: u32 = 0,
    generation: u32 = 0,
};

pub const VmEfiVarStore = struct {
    initialized: bool = false,
    secure_boot_enabled: bool = true,
    setup_mode: bool = false,
    pk_enrolled: bool = true,
    kek_enrolled: bool = true,
    db_count: usize = 0,
    db_hashes: [MAX_DB_HASHES][32]u8 = @splat(@splat(0)),
    dbx_count: usize = 0,
    dbx_hashes: [MAX_DB_HASHES][32]u8 = @splat(@splat(0)),

    // Active runtime variables
    boot_order: u32 = 0,
    boot0001: u32 = 0,
    boot_count: u32 = 0,
    generation: u32 = 0,
    crc32: u32 = 0,
    status: u32 = STATUS_READY,
    last_auth_result: u32 = 0,

    // Persistent Non-Volatile (NV) shadow across warm reboots
    nv_committed: bool = false,
    nv_payload: NvPayload = .{},
    nv_crc32: u32 = 0,

    pub fn computePayloadCrc(payload: NvPayload) u32 {
        return Crc32.hash(std.mem.asBytes(&payload));
    }

    pub fn updateStatusFlags(self: *VmEfiVarStore) void {
        var flags: u32 = STATUS_READY;
        if (self.nv_committed) flags |= STATUS_COMMITTED;
        if (self.crc32 == computePayloadCrc(.{
            .boot_order = self.boot_order,
            .boot0001 = self.boot0001,
            .boot_count = self.boot_count,
            .generation = self.generation,
        })) {
            flags |= STATUS_CRC_OK;
        }
        if (self.pk_enrolled) flags |= STATUS_PK_ENROLLED;
        if (self.kek_enrolled) flags |= STATUS_KEK_ENROLLED;
        if (self.db_count > 0) flags |= STATUS_DB_ENROLLED;
        if (self.dbx_count > 0) flags |= STATUS_DBX_ENROLLED;
        self.status = flags;
    }

    pub fn commitNv(self: *VmEfiVarStore) void {
        self.generation +%= 1;
        self.nv_payload = .{
            .boot_order = self.boot_order,
            .boot0001 = self.boot0001,
            .boot_count = self.boot_count,
            .generation = self.generation,
        };
        self.nv_crc32 = computePayloadCrc(self.nv_payload);
        self.crc32 = self.nv_crc32;
        self.nv_committed = true;
        self.updateStatusFlags();
    }

    pub fn reloadFromNv(self: *VmEfiVarStore) bool {
        if (!self.nv_committed) return false;
        const expected = computePayloadCrc(self.nv_payload);
        if (expected != self.nv_crc32) {
            self.status &= ~STATUS_CRC_OK;
            return false;
        }
        self.boot_order = self.nv_payload.boot_order;
        self.boot0001 = self.nv_payload.boot0001;
        self.boot_count = self.nv_payload.boot_count;
        self.generation = self.nv_payload.generation;
        self.crc32 = self.nv_crc32;
        self.updateStatusFlags();
        return true;
    }
};

var stores: [MAX_VMS]VmEfiVarStore = @splat(.{});

fn slotIndex(vmid: u32) ?usize {
    if (vmid == 0 or vmid > MAX_VMS) return null;
    return @as(usize, vmid - 1);
}

pub fn getStore(vmid: u32) ?*VmEfiVarStore {
    const idx = slotIndex(vmid) orelse return null;
    return &stores[idx];
}

pub fn initDefaultSecureBootStore(vmid: u32, approved_image: []const u8, revoked_image: []const u8) bool {
    const store = getStore(vmid) orelse return false;
    if (!store.initialized) {
        store.* = .{
            .initialized = true,
            .secure_boot_enabled = true,
            .setup_mode = false,
            .pk_enrolled = true,
            .kek_enrolled = true,
        };
    }
    store.db_count = 1;
    Sha256.hash(approved_image, &store.db_hashes[0], .{});
    store.dbx_count = 1;
    Sha256.hash(revoked_image, &store.dbx_hashes[0], .{});
    store.crc32 = VmEfiVarStore.computePayloadCrc(.{
        .boot_order = store.boot_order,
        .boot0001 = store.boot0001,
        .boot_count = store.boot_count,
        .generation = store.generation,
    });
    store.updateStatusFlags();
    return true;
}

pub fn enrollAllowedImage(vmid: u32, image: []const u8) bool {
    const store = getStore(vmid) orelse return false;
    if (store.db_count >= MAX_DB_HASHES) return false;
    Sha256.hash(image, &store.db_hashes[store.db_count], .{});
    store.db_count += 1;
    store.updateStatusFlags();
    return true;
}

pub fn enrollRevokedImage(vmid: u32, image: []const u8) bool {
    const store = getStore(vmid) orelse return false;
    if (store.dbx_count >= MAX_DB_HASHES) return false;
    Sha256.hash(image, &store.dbx_hashes[store.dbx_count], .{});
    store.dbx_count += 1;
    store.updateStatusFlags();
    return true;
}

pub fn verifyBootImage(vmid: u32, image: []const u8) SecureBootError!void {
    const store = getStore(vmid) orelse return error.InvalidVmId;
    if (!store.secure_boot_enabled) {
        store.last_auth_result = 1;
        return;
    }
    if (store.setup_mode or !store.pk_enrolled or !store.kek_enrolled or store.db_count == 0) {
        store.last_auth_result = 0xE1;
        return error.EmptyTrustDatabase;
    }

    var digest: [32]u8 = undefined;
    Sha256.hash(image, &digest, .{});

    var i: usize = 0;
    while (i < store.dbx_count) : (i += 1) {
        if (std.mem.eql(u8, &store.dbx_hashes[i], &digest)) {
            store.last_auth_result = 0xE2;
            return error.RevokedInDbx;
        }
    }

    var allowed = false;
    i = 0;
    while (i < store.db_count) : (i += 1) {
        if (std.mem.eql(u8, &store.db_hashes[i], &digest)) {
            allowed = true;
            break;
        }
    }
    if (!allowed) {
        store.last_auth_result = 0xE3;
        return error.NotInAllowedDb;
    }
    store.last_auth_result = 1;
}

pub fn resetForReboot(vmid: u32) void {
    const store = getStore(vmid) orelse return;
    _ = store.reloadFromNv();
}

pub fn resetInstance(vmid: u32) void {
    const store = getStore(vmid) orelse return;
    store.* = .{};
}

pub fn mmioRead(vmid: u32, offset: u64) u32 {
    const store = getStore(vmid) orelse return 0;
    store.updateStatusFlags();
    return switch (offset) {
        REG_MAGIC => EFI_VAR_MAGIC,
        REG_STATUS => store.status,
        REG_SECURE_BOOT => if (store.secure_boot_enabled) 1 else 0,
        REG_SETUP_MODE => if (store.setup_mode) 1 else 0,
        REG_BOOT_ORDER => store.boot_order,
        REG_BOOT0001 => store.boot0001,
        REG_BOOT_COUNT => store.boot_count,
        REG_GENERATION => store.generation,
        REG_CRC32 => store.crc32,
        REG_LAST_AUTH_RESULT => store.last_auth_result,
        else => 0,
    };
}

pub fn mmioWrite(vmid: u32, offset: u64, value: u32) void {
    const store = getStore(vmid) orelse return;
    switch (offset) {
        REG_BOOT_ORDER => {
            store.boot_order = value;
            store.updateStatusFlags();
        },
        REG_BOOT0001 => {
            store.boot0001 = value;
            store.updateStatusFlags();
        },
        REG_BOOT_COUNT => {
            store.boot_count = value;
            store.updateStatusFlags();
        },
        REG_CMD => switch (value) {
            CMD_COMMIT_NV => store.commitNv(),
            CMD_RELOAD_NV => _ = store.reloadFromNv(),
            CMD_VERIFY_CRC => store.updateStatusFlags(),
            else => {},
        },
        else => {},
    }
}

test "efi_vars: Secure Boot rejects empty DB, dbx-revoked image, and unenrolled image" {
    resetInstance(1);
    const approved = "UEFI-IMAGE-APPROVED-V1";
    const revoked = "UEFI-IMAGE-REVOKED-CVE";
    const unknown = "UEFI-IMAGE-UNSIGNED";

    // Before enrolling DB, Secure Boot fails closed with EmptyTrustDatabase
    try std.testing.expectError(error.EmptyTrustDatabase, verifyBootImage(1, approved));

    try std.testing.expect(initDefaultSecureBootStore(1, approved, revoked));

    // Approved image passes verification
    try verifyBootImage(1, approved);

    // Revoked image in dbx is rejected even if also enrolled in db
    _ = enrollAllowedImage(1, revoked);
    try std.testing.expectError(error.RevokedInDbx, verifyBootImage(1, revoked));

    // Unknown image not in db is rejected
    try std.testing.expectError(error.NotInAllowedDb, verifyBootImage(1, unknown));
}

test "efi_vars: NV variables persist across warm reboot and wipe on resetInstance" {
    resetInstance(2);
    const approved = "UEFI-IMAGE-APPROVED-V1";
    const revoked = "UEFI-IMAGE-REVOKED-CVE";
    try std.testing.expect(initDefaultSecureBootStore(2, approved, revoked));

    try std.testing.expectEqual(EFI_VAR_MAGIC, mmioRead(2, REG_MAGIC));
    mmioWrite(2, REG_BOOT_ORDER, 1);
    mmioWrite(2, REG_BOOT0001, 0x0001_0001);
    mmioWrite(2, REG_BOOT_COUNT, 1);
    mmioWrite(2, REG_CMD, CMD_COMMIT_NV);

    try std.testing.expect((mmioRead(2, REG_STATUS) & STATUS_COMMITTED) != 0);
    try std.testing.expect((mmioRead(2, REG_STATUS) & STATUS_CRC_OK) != 0);
    try std.testing.expectEqual(@as(u32, 1), mmioRead(2, REG_GENERATION));

    // Clobber volatile copies without committing, then trigger warm reboot reload
    mmioWrite(2, REG_BOOT_COUNT, 99);
    resetForReboot(2);
    try std.testing.expectEqual(@as(u32, 1), mmioRead(2, REG_BOOT_COUNT));
    try std.testing.expectEqual(@as(u32, 0x0001_0001), mmioRead(2, REG_BOOT0001));

    // Full teardown wipes NV state
    resetInstance(2);
    try std.testing.expectEqual(@as(u32, 0), mmioRead(2, REG_BOOT_COUNT));
    try std.testing.expectEqual(@as(u32, 0), mmioRead(2, REG_GENERATION));
}
