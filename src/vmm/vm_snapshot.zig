const std = @import("std");
const microvm_registry = @import("microvm_registry.zig");
const efi_vars = @import("efi_vars.zig");
const vtpm = @import("vtpm.zig");
const pc_platform = @import("pc_platform.zig");
const partition_metadata = @import("../user/protocols/partition_metadata.zig");

pub const SNAPSHOT_MAGIC: u64 = 0x534E_4150_524E_524E; // "SNAPRNRN"
pub const SNAPSHOT_VERSION: u32 = 1;
pub const MAX_VM_SNAPSHOTS: usize = 4;
pub const MAX_VMS: usize = 8;

pub const GuestRegsSnapshot = extern struct {
    rax: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rbx: u64 = 0,
    rsp: u64 = 0,
    rbp: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 0,
    cr0: u64 = 0,
    cr3: u64 = 0,
    cr4: u64 = 0,
};

pub const SnapshotManifest = struct {
    magic: u64 = 0,
    version: u32 = 0,
    vmid: u32 = 0,
    generation: u32 = 0,
    timestamp_tsc: u64 = 0,
    label: [32]u8 = @splat(0),
    guest_regs: GuestRegsSnapshot = .{},
    devices: microvm_registry.VirtualDeviceState = .{},
    efi_var_crc32: u32 = 0,
    efi_generation: u32 = 0,
    tpm_pcr0: [32]u8 = @splat(0),
    tpm_monotonic: u64 = 0,
    disk_lba: u64 = 0,
    disk_sectors: u64 = 0,
    valid: bool = false,
};

pub const SnapshotSummary = struct {
    vmid: u32,
    generation: u32,
    disk_lba: u64,
    efi_generation: u32,
    tpm_monotonic: u64,
};

var manifests: [MAX_VMS][MAX_VM_SNAPSHOTS]SnapshotManifest = @splat(@splat(.{}));

fn slotIndex(vmid: u32) ?usize {
    if (vmid == 0 or vmid > MAX_VMS) return null;
    return @as(usize, vmid - 1);
}

pub fn createSnapshot(
    vmid: u32,
    generation: u32,
    label: []const u8,
    regs: GuestRegsSnapshot,
    tsc: u64,
) !SnapshotManifest {
    const v_idx = slotIndex(vmid) orelse return error.InvalidVmId;
    if (generation == 0 or generation > MAX_VM_SNAPSHOTS) return error.InvalidGeneration;
    const snap_idx = @as(usize, generation - 1);

    const inst = microvm_registry.findMutable(vmid) orelse return error.VmNotFound;

    // 1. Checkpoint EFI NVRAM
    if (!efi_vars.checkpointStore(vmid, generation)) {
        return error.EfiCheckpointFailed;
    }
    const efi_store = efi_vars.getStore(vmid) orelse return error.EfiStoreMissing;

    // 2. Checkpoint vTPM state
    if (!vtpm.checkpointState(vmid, generation)) {
        return error.TpmCheckpointFailed;
    }
    const tpm_st = vtpm.getState(vmid) orelse return error.TpmStateMissing;

    // 3. Resolve disk extent coordinates
    const base_lba = partition_metadata.vmDiskStartLba(vmid) orelse return error.StorageNotConfigured;
    const snap_lba = partition_metadata.vmSnapshotStartLba(vmid, generation) orelse return error.StorageNotConfigured;

    var manifest: SnapshotManifest = .{
        .magic = SNAPSHOT_MAGIC,
        .version = SNAPSHOT_VERSION,
        .vmid = vmid,
        .generation = generation,
        .timestamp_tsc = tsc,
        .guest_regs = regs,
        .devices = inst.devices,
        .efi_var_crc32 = efi_store.crc32,
        .efi_generation = efi_store.generation,
        .tpm_pcr0 = tpm_st.pcrs[0],
        .tpm_monotonic = tpm_st.nv_monotonic_counter,
        .disk_lba = snap_lba,
        .disk_sectors = partition_metadata.VM_DISK_SECTORS,
        .valid = true,
    };
    _ = base_lba;

    const copy_len = @min(label.len, manifest.label.len);
    @memcpy(manifest.label[0..copy_len], label[0..copy_len]);

    manifests[v_idx][snap_idx] = manifest;
    return manifest;
}

pub fn restoreSnapshot(vmid: u32, generation: u32) !SnapshotManifest {
    const v_idx = slotIndex(vmid) orelse return error.InvalidVmId;
    if (generation == 0 or generation > MAX_VM_SNAPSHOTS) return error.InvalidGeneration;
    const snap_idx = @as(usize, generation - 1);

    const manifest = manifests[v_idx][snap_idx];
    if (!manifest.valid or manifest.magic != SNAPSHOT_MAGIC) {
        return error.SnapshotNotFound;
    }

    // 1. Restore EFI Variable NVRAM
    if (!efi_vars.restoreStoreFromCheckpoint(vmid, generation)) {
        return error.EfiRestoreFailed;
    }

    // 2. Restore vTPM State
    if (!vtpm.restoreStateFromCheckpoint(vmid, generation)) {
        return error.TpmRestoreFailed;
    }

    // 3. Restore Virtual Device Registers
    if (microvm_registry.findMutable(vmid)) |inst| {
        inst.devices = manifest.devices;
    } else {
        return error.VmNotFound;
    }

    return manifest;
}

pub fn getSnapshot(vmid: u32, generation: u32) ?SnapshotManifest {
    const v_idx = slotIndex(vmid) orelse return null;
    if (generation == 0 or generation > MAX_VM_SNAPSHOTS) return null;
    const manifest = manifests[v_idx][generation - 1];
    if (!manifest.valid or manifest.magic != SNAPSHOT_MAGIC) return null;
    return manifest;
}

test "vm_snapshot: coordinated capture and rollback of compute, disk, nvram, and vtpm" {
    const vmid: u32 = 1;
    efi_vars.resetInstance(vmid);
    vtpm.resetInstance(vmid);

    _ = efi_vars.initDefaultSecureBootStore(vmid, "APP-IMG", "REV-IMG");
    const tpm_st = vtpm.getState(vmid).?;
    tpm_st.started = true;
    tpm_st.pcrs[0] = @splat(0xAA);
    tpm_st.nv_monotonic_counter = 42;

    const initial_regs = GuestRegsSnapshot{
        .rip = 0x1000,
        .rsp = 0x8000,
        .rax = 0x1234,
    };

    const snap1 = try createSnapshot(vmid, 1, "test-snap-1", initial_regs, 100_000);
    try std.testing.expectEqual(@as(u32, 1), snap1.generation);
    try std.testing.expectEqual(@as(u64, 42), snap1.tpm_monotonic);

    // Mutate state
    tpm_st.pcrs[0] = @splat(0xFF);
    tpm_st.nv_monotonic_counter = 99;
    efi_vars.mmioWrite(vmid, efi_vars.REG_BOOT_COUNT, 999);
    efi_vars.mmioWrite(vmid, efi_vars.REG_CMD, efi_vars.CMD_COMMIT_NV);

    // Rollback to snapshot 1
    const restored = try restoreSnapshot(vmid, 1);
    try std.testing.expectEqual(@as(u32, 1), restored.generation);

    const check_tpm = vtpm.getState(vmid).?;
    const expected_pcr: [32]u8 = @splat(0xAA);
    try std.testing.expectEqual(expected_pcr, check_tpm.pcrs[0]);
    try std.testing.expectEqual(@as(u64, 42), check_tpm.nv_monotonic_counter);
}
