const std = @import("std");

pub const ACPI_TABLES_GPA: u64 = 0x000E_0000;
pub const ACPI_REGION_SIZE: usize = 4096;
pub const ACPI_RSDP_OFFSET: usize = 0x000;
pub const ACPI_RSDT_OFFSET: usize = 0x100;
pub const ACPI_XSDT_OFFSET: usize = 0x200;
pub const ACPI_FADT_OFFSET: usize = 0x300;
pub const ACPI_MADT_OFFSET: usize = 0x400;
pub const ACPI_MCFG_OFFSET: usize = 0x500;
pub const ACPI_TPM2_OFFSET: usize = 0x600;
pub const RSDP_OFFSET: usize = ACPI_RSDP_OFFSET;
pub const RSDT_OFFSET: usize = ACPI_RSDT_OFFSET;
pub const XSDT_OFFSET: usize = ACPI_XSDT_OFFSET;
pub const FADT_OFFSET: usize = ACPI_FADT_OFFSET;
pub const MADT_OFFSET: usize = ACPI_MADT_OFFSET;
pub const MCFG_OFFSET: usize = ACPI_MCFG_OFFSET;
pub const TPM2_OFFSET: usize = ACPI_TPM2_OFFSET;

pub const CMOS_INDEX_PORT: u16 = 0x70;
pub const CMOS_DATA_PORT: u16 = 0x71;
pub const PCI_MAX_BUS0_DEVS: usize = 4;

pub const GOP_MMIO_BASE: u64 = 0xFD00_0000;
pub const GOP_MMIO_SIZE: u64 = 0x1000;
pub const GOP_MAGIC: u32 = 0x4347_4F50; // 'CGOP'
pub const GOP_DEFAULT_WIDTH: u32 = 1024;
pub const GOP_DEFAULT_HEIGHT: u32 = 768;

pub const PCI_HOST_VENDOR_DEVICE: u32 = 0x29C0_8086; // 00:00.0 Intel Q35 Host Bridge
pub const PCI_GOP_VENDOR_DEVICE: u32 = 0x1111_1AF4; // 00:01.0 Catenary GOP Display Adapter
pub const PCI_NET_VENDOR_DEVICE: u32 = 0x1041_1AF4; // 00:02.0 Virtio Network Controller
pub const PCI_BLK_VENDOR_DEVICE: u32 = 0x1042_1AF4; // 00:03.0 Virtio Block Controller

pub const VmRtcState = struct {
    index: u8 = 0,
    nmi_disabled: bool = false,
    cmos: [128]u8 = initDefaultCmos(),

    fn initDefaultCmos() [128]u8 {
        var data: [128]u8 = @splat(0);
        data[0x00] = 0x00; // Seconds (BCD)
        data[0x02] = 0x15; // Minutes (BCD)
        data[0x04] = 0x12; // Hours (BCD)
        data[0x06] = 0x04; // Day of week
        data[0x07] = 0x11; // Day of month (BCD)
        data[0x08] = 0x11; // Month (BCD)
        data[0x09] = 0x26; // Year (BCD -> 2026)
        data[0x0A] = 0x26; // Status Register A (32.768 kHz divider, UIP=0)
        data[0x0B] = 0x02; // Status Register B (24-hour mode)
        data[0x0C] = 0x00; // Status Register C
        data[0x0D] = 0x80; // Status Register D (RTC power/battery valid)
        data[0x32] = 0x20; // Century (BCD -> 20xx)
        return data;
    }

    pub fn reset(self: *VmRtcState) void {
        self.* = .{};
    }

    pub fn writePort70(self: *VmRtcState, val: u8) void {
        self.nmi_disabled = (val & 0x80) != 0;
        self.index = val & 0x7F;
    }

    pub fn readPort70(self: *const VmRtcState) u8 {
        return (if (self.nmi_disabled) @as(u8, 0x80) else 0) | (self.index & 0x7F);
    }

    pub fn readPort71(self: *const VmRtcState) u8 {
        return self.cmos[self.index & 0x7F];
    }

    pub fn writePort71(self: *VmRtcState, val: u8) void {
        const idx = self.index & 0x7F;
        // Status Registers C and D are read-only in MC146818
        if (idx == 0x0C or idx == 0x0D) return;
        self.cmos[idx] = val;
    }

    pub fn ioIn(self: *const VmRtcState, port: u16) u8 {
        return switch (port) {
            CMOS_INDEX_PORT => self.readPort70(),
            CMOS_DATA_PORT => self.readPort71(),
            else => 0xFF,
        };
    }

    pub fn ioOut(self: *VmRtcState, port: u16, val: u8) void {
        switch (port) {
            CMOS_INDEX_PORT => self.writePort70(val),
            CMOS_DATA_PORT => self.writePort71(val),
            else => {},
        }
    }
};

pub const VmGopState = struct {
    pub const REG_MAGIC: u64 = 0x000;
    pub const REG_WIDTH: u64 = 0x004;
    pub const REG_HEIGHT: u64 = 0x008;
    pub const REG_PITCH: u64 = 0x00C;
    pub const REG_BPP: u64 = 0x010;
    pub const REG_FORMAT: u64 = 0x014;
    pub const REG_STATUS: u64 = 0x018;
    pub const REG_FLUSH: u64 = 0x01C;
    pub const VRAM_WINDOW_OFFSET: u64 = 0x100;
    pub const STATUS_ACTIVE: u32 = 1;
    pub const STATUS_VRAM_DIRTY: u32 = 2;

    width: u32 = 1024,
    height: u32 = 768,
    pitch: u32 = 4096,
    bpp: u32 = 32,
    pixel_format: u32 = 1, // 1 = BGRX8888
    active: bool = false,
    frame_count: u32 = 0,
    last_pixel: u32 = 0,

    pub fn reset(self: *VmGopState) void {
        self.* = .{};
    }

    pub fn handleRead(self: *const VmGopState, offset: u64) u32 {
        return switch (offset & 0xFFF) {
            0x000 => GOP_MAGIC,
            0x004 => self.width,
            0x008 => self.height,
            0x00C => self.pitch,
            0x010 => self.bpp,
            0x014 => self.pixel_format,
            0x018 => if (self.active) 1 else 0,
            0x01C => self.frame_count,
            0x020 => self.last_pixel,
            else => self.last_pixel,
        };
    }

    pub fn mmioRead(self: *const VmGopState, offset: u64) u32 {
        return self.handleRead(offset);
    }

    pub fn handleWrite(self: *VmGopState, offset: u64, value: u32) void {
        const off = offset & 0xFFF;
        switch (off) {
            0x004 => if (value >= 640 and value <= 1920) {
                self.width = value;
                self.pitch = value * 4;
            },
            0x008 => if (value >= 480 and value <= 1080) {
                self.height = value;
            },
            0x018 => {
                self.active = (value != 0);
                if (self.active) self.frame_count +%= 1;
            },
            0x01C => {
                self.active = true;
                self.frame_count +%= 1;
            },
            else => {
                if (off >= 0x100) {
                    self.last_pixel = value;
                    if (!self.active) self.active = true;
                }
            },
        }
    }

    pub fn mmioWrite(self: *VmGopState, offset: u64, value: u32) void {
        self.handleWrite(offset, value);
    }
};

pub fn pciReadDword(dev_commands: *const [4]u16, addr: u32) u32 {
    if ((addr & 0x8000_0000) == 0) return 0xFFFF_FFFF;

    const bus = @as(u8, @truncate(addr >> 16));
    const device = @as(u5, @truncate((addr >> 11) & 0x1F));
    const function = @as(u3, @truncate((addr >> 8) & 0x7));
    const reg = @as(u8, @truncate(addr & 0xFC));

    if (bus != 0 or function != 0 or device >= 4) return 0xFFFF_FFFF;

    const cmd_status: u32 = @as(u32, dev_commands[device]) | (0x0010 << 16);
    return switch (device) {
        0 => switch (reg) {
            0x00 => PCI_HOST_VENDOR_DEVICE,
            0x04 => cmd_status,
            0x08 => 0x0600_0000, // Host bridge
            0x2C => 0x0001_1AF4,
            else => 0,
        },
        1 => switch (reg) {
            0x00 => PCI_GOP_VENDOR_DEVICE,
            0x04 => cmd_status,
            0x08 => 0x0300_0001, // VGA / GOP Display controller
            0x10 => @as(u32, @truncate(GOP_MMIO_BASE)) | 0x08, // Prefetchable MMIO BAR0
            0x2C => 0x0011_1AF4,
            else => 0,
        },
        2 => switch (reg) {
            0x00 => PCI_NET_VENDOR_DEVICE,
            0x04 => cmd_status,
            0x08 => 0x0200_0001, // Ethernet controller
            0x10 => 0xFE00_0000, // Virtio-Net MMIO BAR0
            0x2C => 0x0001_1AF4,
            0x3C => 0x0000_010B, // IRQ 11, INTA#
            else => 0,
        },
        3 => switch (reg) {
            0x00 => PCI_BLK_VENDOR_DEVICE,
            0x04 => cmd_status,
            0x08 => 0x0100_0001, // Mass storage controller
            0x10 => 0xFE00_1000, // Virtio-Blk MMIO BAR0
            0x2C => 0x0002_1AF4,
            0x3C => 0x0000_010E, // IRQ 14, INTA#
            else => 0,
        },
        else => 0xFFFF_FFFF,
    };
}

pub fn pciWriteDword(dev_commands: *[4]u16, addr: u32, value: u32, mask: u32) void {
    if ((addr & 0x8000_0000) == 0) return;

    const bus = @as(u8, @truncate(addr >> 16));
    const device = @as(u5, @truncate((addr >> 11) & 0x1F));
    const function = @as(u3, @truncate((addr >> 8) & 0x7));
    const reg = @as(u8, @truncate(addr & 0xFC));

    if (bus != 0 or function != 0 or device >= 4) return;

    if (reg == 0x04) {
        const current = @as(u32, dev_commands[device]);
        const merged = (current & ~mask) | (value & mask);
        dev_commands[device] = @as(u16, @truncate(merged & 0x0000_FFFF));
    }
}

fn computeChecksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| {
        sum +%= b;
    }
    return 0 -% sum;
}

pub fn checksumValid(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| {
        sum +%= b;
    }
    return sum == 0;
}

fn writeAcpiHeader(
    buf: []u8,
    signature: *const [4]u8,
    length: u32,
    revision: u8,
    oem_table_id: *const [8]u8,
) void {
    @memcpy(buf[0..4], signature);
    std.mem.writeInt(u32, buf[4..8], length, .little);
    buf[8] = revision;
    buf[9] = 0; // checksum filled after body is populated
    @memcpy(buf[10..16], "CATENA");
    @memcpy(buf[16..24], oem_table_id);
    std.mem.writeInt(u32, buf[24..28], 1, .little); // OEM revision
    @memcpy(buf[28..32], "CTNY"); // Creator ID
    std.mem.writeInt(u32, buf[32..36], 1, .little); // Creator revision
}

fn finalizeAcpiTable(buf: []u8, length: usize) void {
    buf[9] = 0;
    buf[9] = computeChecksum(buf[0..length]);
}

/// Populate ACPI 2.0+ RSDP, RSDT, XSDT, FADT, MADT, MCFG, and TPM2 tables in a 4 KiB page
/// mapped at `ACPI_TABLES_GPA` (0x000E_0000).
pub fn buildGuestAcpiTables(page: *[4096]u8, vcpus: u32) void {
    @memset(page, 0);

    const rsdt_gpa: u32 = @intCast(ACPI_TABLES_GPA + ACPI_RSDT_OFFSET);
    const xsdt_gpa: u64 = ACPI_TABLES_GPA + ACPI_XSDT_OFFSET;
    const fadt_gpa: u32 = @intCast(ACPI_TABLES_GPA + ACPI_FADT_OFFSET);
    const madt_gpa: u32 = @intCast(ACPI_TABLES_GPA + ACPI_MADT_OFFSET);
    const mcfg_gpa: u32 = @intCast(ACPI_TABLES_GPA + ACPI_MCFG_OFFSET);
    const tpm2_gpa: u32 = @intCast(ACPI_TABLES_GPA + ACPI_TPM2_OFFSET);

    // 1. RSDP v2 at +0x000 (36 bytes)
    const rsdp = page[ACPI_RSDP_OFFSET .. ACPI_RSDP_OFFSET + 36];
    @memcpy(rsdp[0..8], "RSD PTR ");
    rsdp[8] = 0; // v1 checksum
    @memcpy(rsdp[9..15], "CATENA");
    rsdp[15] = 2; // ACPI 2.0+
    std.mem.writeInt(u32, rsdp[16..20], rsdt_gpa, .little);
    std.mem.writeInt(u32, rsdp[20..24], 36, .little);
    std.mem.writeInt(u64, rsdp[24..32], xsdt_gpa, .little);
    rsdp[8] = computeChecksum(rsdp[0..20]);
    rsdp[32] = computeChecksum(rsdp[0..36]);

    // 2. RSDT at +0x100 (36 + 4*4 = 52 bytes)
    const rsdt_len: usize = 36 + 16;
    const rsdt = page[ACPI_RSDT_OFFSET .. ACPI_RSDT_OFFSET + rsdt_len];
    writeAcpiHeader(rsdt, "RSDT", @intCast(rsdt_len), 1, "CATERSDT");
    std.mem.writeInt(u32, rsdt[36..40], fadt_gpa, .little);
    std.mem.writeInt(u32, rsdt[40..44], madt_gpa, .little);
    std.mem.writeInt(u32, rsdt[44..48], mcfg_gpa, .little);
    std.mem.writeInt(u32, rsdt[48..52], tpm2_gpa, .little);
    finalizeAcpiTable(rsdt, rsdt_len);

    // 3. XSDT at +0x200 (36 + 4*8 = 68 bytes)
    const xsdt_len: usize = 36 + 32;
    const xsdt = page[ACPI_XSDT_OFFSET .. ACPI_XSDT_OFFSET + xsdt_len];
    writeAcpiHeader(xsdt, "XSDT", @intCast(xsdt_len), 1, "CATEXSDT");
    std.mem.writeInt(u64, xsdt[36..44], fadt_gpa, .little);
    std.mem.writeInt(u64, xsdt[44..52], madt_gpa, .little);
    std.mem.writeInt(u64, xsdt[52..60], mcfg_gpa, .little);
    std.mem.writeInt(u64, xsdt[60..68], tpm2_gpa, .little);
    finalizeAcpiTable(xsdt, xsdt_len);

    // 4. FADT ("FACP") at +0x300 (116 bytes)
    const fadt_len: usize = 116;
    const fadt = page[ACPI_FADT_OFFSET .. ACPI_FADT_OFFSET + fadt_len];
    writeAcpiHeader(fadt, "FACP", @intCast(fadt_len), 6, "CATEFADT");
    fadt[45] = 1; // Preferred PM profile: Desktop/Workstation
    std.mem.writeInt(u16, fadt[46..48], 9, .little); // SCI_INT = 9
    std.mem.writeInt(u32, fadt[64..68], 0x0604, .little); // PM1a_CNT_BLK
    fadt[89] = 4; // PM1_CNT_LEN
    fadt[108] = 0x32; // CENTURY register in CMOS
    std.mem.writeInt(u32, fadt[112..116], (1 << 20), .little); // HW_REDUCED_ACPI flag
    finalizeAcpiTable(fadt, fadt_len);

    // 5. MADT ("APIC") at +0x400
    const clamped_vcpus: usize = @min(@max(@as(usize, vcpus), 1), 8);
    const madt_len: usize = 44 + (clamped_vcpus * 8) + 12;
    const madt = page[ACPI_MADT_OFFSET .. ACPI_MADT_OFFSET + madt_len];
    writeAcpiHeader(madt, "APIC", @intCast(madt_len), 4, "CATEMADT");
    std.mem.writeInt(u32, madt[36..40], 0xFEE0_0000, .little); // Local APIC physical address
    std.mem.writeInt(u32, madt[40..44], 1, .little); // PCAT_COMPAT
    var off: usize = 44;
    for (0..clamped_vcpus) |cpu_i| {
        madt[off + 0] = 0; // Processor Local APIC
        madt[off + 1] = 8; // Length
        madt[off + 2] = @intCast(cpu_i); // ACPI Processor UID
        madt[off + 3] = @intCast(cpu_i); // APIC ID
        std.mem.writeInt(u32, madt[off + 4 ..][0..4], 1, .little); // Enabled
        off += 8;
    }
    // I/O APIC structure (12 bytes)
    madt[off + 0] = 1; // I/O APIC type
    madt[off + 1] = 12; // Length
    madt[off + 2] = 0; // I/O APIC ID
    madt[off + 3] = 0; // Reserved
    std.mem.writeInt(u32, madt[off + 4 ..][0..4], 0xFEC0_0000, .little);
    std.mem.writeInt(u32, madt[off + 8 ..][0..4], 0, .little); // Global System Interrupt Base
    finalizeAcpiTable(madt, madt_len);

    // 6. MCFG ("MCFG") at +0x500 (60 bytes)
    const mcfg_len: usize = 60;
    const mcfg = page[ACPI_MCFG_OFFSET .. ACPI_MCFG_OFFSET + mcfg_len];
    writeAcpiHeader(mcfg, "MCFG", @intCast(mcfg_len), 1, "CATEMCFG");
    std.mem.writeInt(u64, mcfg[44..52], 0xE000_0000, .little); // PCIe ECAM base
    std.mem.writeInt(u16, mcfg[52..54], 0, .little); // PCI Segment Group 0
    mcfg[54] = 0; // Start bus 0
    mcfg[55] = 0; // End bus 0
    finalizeAcpiTable(mcfg, mcfg_len);

    // 7. TPM2 ("TPM2") at +0x600 (52 bytes)
    const tpm2_len: usize = 52;
    const tpm2 = page[ACPI_TPM2_OFFSET .. ACPI_TPM2_OFFSET + tpm2_len];
    writeAcpiHeader(tpm2, "TPM2", @intCast(tpm2_len), 4, "CATETPM2");
    std.mem.writeInt(u16, tpm2[36..38], 0, .little); // Platform Class: Client
    std.mem.writeInt(u64, tpm2[40..48], 0xFED4_0040, .little); // CRB Control Area GPA
    std.mem.writeInt(u32, tpm2[48..52], 7, .little); // Start Method 7 = Command Response Buffer
    finalizeAcpiTable(tpm2, tpm2_len);
}

pub fn verifyGuestAcpiTables(page: *const [4096]u8) bool {
    const rsdp = page[ACPI_RSDP_OFFSET .. ACPI_RSDP_OFFSET + 36];
    if (!std.mem.eql(u8, rsdp[0..8], "RSD PTR ")) return false;
    if (!checksumValid(rsdp[0..20]) or !checksumValid(rsdp[0..36])) return false;

    const offsets = [_]struct { off: usize, sig: *const [4]u8 }{
        .{ .off = ACPI_RSDT_OFFSET, .sig = "RSDT" },
        .{ .off = ACPI_XSDT_OFFSET, .sig = "XSDT" },
        .{ .off = ACPI_FADT_OFFSET, .sig = "FACP" },
        .{ .off = ACPI_MADT_OFFSET, .sig = "APIC" },
        .{ .off = ACPI_MCFG_OFFSET, .sig = "MCFG" },
        .{ .off = ACPI_TPM2_OFFSET, .sig = "TPM2" },
    };

    for (offsets) |entry| {
        const hdr = page[entry.off .. entry.off + 36];
        if (!std.mem.eql(u8, hdr[0..4], entry.sig)) return false;
        const len = std.mem.readInt(u32, hdr[4..8], .little);
        if (len < 36 or entry.off + len > page.len) return false;
        if (!checksumValid(page[entry.off .. entry.off + len])) return false;
    }
    return true;
}

test "ACPI 2.0+ table generation and checksum verification" {
    var page: [4096]u8 = undefined;
    buildGuestAcpiTables(&page, 2);
    try std.testing.expect(verifyGuestAcpiTables(&page));

    // Corrupting a byte in MADT must invalidate table verification
    page[ACPI_MADT_OFFSET + 44] ^= 0xFF;
    try std.testing.expect(!verifyGuestAcpiTables(&page));
}

test "MC146818 CMOS RTC and multi-device PCI bus enumeration" {
    var rtc: VmRtcState = .{};
    rtc.writePort70(0x09); // Year register
    try std.testing.expectEqual(@as(u8, 0x26), rtc.readPort71());
    rtc.writePort70(0x32); // Century register
    try std.testing.expectEqual(@as(u8, 0x20), rtc.readPort71());

    // Read-only Status Register D ignores guest writes
    rtc.writePort70(0x0D);
    rtc.writePort71(0x00);
    try std.testing.expectEqual(@as(u8, 0x80), rtc.readPort71());

    var cmds: [4]u16 = @splat(0);
    try std.testing.expectEqual(PCI_HOST_VENDOR_DEVICE, pciReadDword(&cmds, 0x8000_0000 | (0 << 11)));
    try std.testing.expectEqual(PCI_GOP_VENDOR_DEVICE, pciReadDword(&cmds, 0x8000_0000 | (1 << 11)));
    try std.testing.expectEqual(PCI_NET_VENDOR_DEVICE, pciReadDword(&cmds, 0x8000_0000 | (2 << 11)));
    try std.testing.expectEqual(PCI_BLK_VENDOR_DEVICE, pciReadDword(&cmds, 0x8000_0000 | (3 << 11)));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), pciReadDword(&cmds, 0x8000_0000 | (4 << 11)));

    var gop: VmGopState = .{};
    try std.testing.expectEqual(GOP_MAGIC, gop.handleRead(0x000));
    try std.testing.expectEqual(@as(u32, 1024), gop.handleRead(0x004));
    try std.testing.expectEqual(@as(u32, 768), gop.handleRead(0x008));
    gop.handleWrite(0x018, 1);
    gop.handleWrite(0x100, 0x005B_C0EB);
    try std.testing.expect(gop.active);
    try std.testing.expectEqual(@as(u32, 1), gop.frame_count);
    try std.testing.expectEqual(@as(u32, 0x005B_C0EB), gop.last_pixel);
}
