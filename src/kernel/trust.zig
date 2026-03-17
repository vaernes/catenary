const std = @import("std");

pub const KernelManifest = struct {
    magic: u64 = 0x4341544D414E4946, // "CATMANIF"
    version: u32 = 1,
    kernel_base_physical: u64,
    kernel_size: u64,
    boot_time_entropy: u64,
    capability_seed: u64,

    // Future placeholders for measured boot
    load_address_virtual: u64,
    entry_point_virtual: u64,

    pub fn report(self: KernelManifest, serialWrite: *const fn ([]const u8) void, printHex: *const fn (u64) void) void {
        serialWrite("--- KERNEL TRUST MANIFEST ---\n");
        serialWrite("Base Phys: ");
        printHex(self.kernel_base_physical);
        serialWrite("\n");
        serialWrite("Size     : ");
        printHex(self.kernel_size);
        serialWrite("\n");
        serialWrite("Entropy  : ");
        printHex(self.boot_time_entropy);
        serialWrite("\n");
        serialWrite("Cap Seed : ");
        printHex(self.capability_seed);
        serialWrite("\n");
        serialWrite("-----------------------------\n");
    }
};

pub var global_manifest: ?KernelManifest = null;

// Use a fixed address in the kernel BSS or data section that we know is writable
var global_manifest_storage: KernelManifest = undefined;
pub var global_manifest_ptr: *KernelManifest = &global_manifest_storage;

fn writeManifest(dst: *KernelManifest, src: KernelManifest) void {
    dst.magic = src.magic;
    dst.version = src.version;
    dst.kernel_base_physical = src.kernel_base_physical;
    dst.kernel_size = src.kernel_size;
    dst.boot_time_entropy = src.boot_time_entropy;
    dst.capability_seed = src.capability_seed;
    dst.load_address_virtual = src.load_address_virtual;
    dst.entry_point_virtual = src.entry_point_virtual;
}

pub fn storeManifest(manifest: KernelManifest) *KernelManifest {
    writeManifest(&global_manifest_storage, manifest);
    return global_manifest_ptr;
}
