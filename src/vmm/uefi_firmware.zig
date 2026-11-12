const std = @import("std");
const efi_vars = @import("efi_vars.zig");
const pc_platform = @import("pc_platform.zig");
const vtpm = @import("vtpm.zig");

pub const UEFI_ROM_GPA: u64 = 0xFFF0_0000;
pub const UEFI_ROM_SIZE: usize = 0x1000;
pub const UEFI_CODE_GPA: u64 = 0x0010_0000;
pub const UEFI_STACK_TOP_GPA: u64 = 0x0018_0000;

// Guest RAM layout used by the UEFI firmware Virtio-Blk driver
pub const VIRTIO_DESC_GPA: u64 = 0x0011_0000;
pub const VIRTIO_AVAIL_GPA: u64 = 0x0011_1000;
pub const VIRTIO_USED_GPA: u64 = 0x0011_2000;
pub const VIRTIO_REQ_HDR_GPA: u64 = 0x0011_3000;
pub const VIRTIO_STATUS_GPA: u64 = 0x0011_3100;
pub const VIRTIO_DATA_BUF_GPA: u64 = 0x0011_4000;
pub const SERIAL_CMD_BUF_GPA: u64 = 0x0011_5000;

pub const FullVmProfileKind = enum(u8) {
    uefi_direct = 1,
    uefi_revoked = 2,
    ubuntu_26_04 = 3,
    windows_11_26h2 = 4,

    pub fn fromName(name: []const u8) ?FullVmProfileKind {
        if (std.mem.eql(u8, name, "uefi-test") or std.mem.eql(u8, name, "uefi-direct")) return .uefi_direct;
        if (std.mem.eql(u8, name, "uefi-revoked")) return .uefi_revoked;
        if (std.mem.eql(u8, name, "ubuntu-26.04")) return .ubuntu_26_04;
        if (std.mem.eql(u8, name, "win11-26h2") or std.mem.eql(u8, name, "windows-11-26h2")) return .windows_11_26h2;
        return null;
    }

    pub fn label(self: FullVmProfileKind) []const u8 {
        return switch (self) {
            .uefi_direct => "uefi-test",
            .uefi_revoked => "uefi-revoked",
            .ubuntu_26_04 => "ubuntu-26.04",
            .windows_11_26h2 => "win11-26h2",
        };
    }
};

pub const ProfileRequirements = struct {
    min_vcpus: u16,
    min_ram_mib: u32,
    min_disk_mib: u32,
    requires_secure_boot: bool,
    requires_tpm2: bool,
    requires_external_installer_iso: bool,
};

pub fn requirementsForProfile(kind: FullVmProfileKind) ProfileRequirements {
    return switch (kind) {
        .uefi_direct, .uefi_revoked => .{
            .min_vcpus = 1,
            .min_ram_mib = 16,
            .min_disk_mib = 1,
            .requires_secure_boot = true,
            .requires_tpm2 = true,
            .requires_external_installer_iso = false,
        },
        .ubuntu_26_04 => .{
            .min_vcpus = 2,
            .min_ram_mib = 4096,
            .min_disk_mib = 20 * 1024,
            .requires_secure_boot = true,
            .requires_tpm2 = true,
            .requires_external_installer_iso = true,
        },
        .windows_11_26h2 => .{
            .min_vcpus = 2,
            .min_ram_mib = 4096,
            .min_disk_mib = 64 * 1024,
            .requires_secure_boot = true,
            .requires_tpm2 = true,
            .requires_external_installer_iso = true,
        },
    };
}

pub const HostVmCapabilities = struct {
    allocated_vcpus: u16 = 1,
    allocated_ram_mib: u32 = 16,
    allocated_disk_mib: u32 = 1,
    secure_boot_ready: bool = true,
    tpm2_ready: bool = true,
    has_external_installer_iso: bool = false,
};

pub const AdmissionError = error{
    MissingInstallerMedia,
    InsufficientVcpus,
    InsufficientRam,
    InsufficientDisk,
    SecureBootDisabled,
    Tpm2Unavailable,
    SecureBootRevokedInDbx,
    SecureBootNotInAllowedDb,
    SecureBootEmptyTrustDb,
};

pub fn validateFullVmAdmission(
    vmid: ?u32,
    kind: FullVmProfileKind,
    caps: HostVmCapabilities,
) AdmissionError!void {
    const req = requirementsForProfile(kind);
    if (req.requires_external_installer_iso and !caps.has_external_installer_iso) {
        return error.MissingInstallerMedia;
    }
    if (caps.allocated_vcpus < req.min_vcpus) return error.InsufficientVcpus;
    if (caps.allocated_ram_mib < req.min_ram_mib) return error.InsufficientRam;
    if (caps.allocated_disk_mib < req.min_disk_mib) return error.InsufficientDisk;
    if (req.requires_secure_boot and !caps.secure_boot_ready) return error.SecureBootDisabled;
    if (req.requires_tpm2 and !caps.tpm2_ready) return error.Tpm2Unavailable;

    const image = switch (kind) {
        .uefi_revoked => getRevokedUefiImage(),
        else => getApprovedUefiImage(),
    };
    if (vmid) |id| {
        efi_vars.verifyBootImage(id, image) catch |err| switch (err) {
            error.EmptyTrustDatabase, error.InvalidVmId => return error.SecureBootEmptyTrustDb,
            error.RevokedInDbx => return error.SecureBootRevokedInDbx,
            error.NotInAllowedDb => return error.SecureBootNotInAllowedDb,
        };
    } else {
        var ephemeral = efi_vars.createDefaultStore(getApprovedUefiImage(), getRevokedUefiImage());
        efi_vars.verifyBootImageStore(&ephemeral, image) catch |err| switch (err) {
            error.EmptyTrustDatabase, error.InvalidVmId => return error.SecureBootEmptyTrustDb,
            error.RevokedInDbx => return error.SecureBootRevokedInDbx,
            error.NotInAllowedDb => return error.SecureBootNotInAllowedDb,
        };
    }
}

pub fn buildResetVectorPage(out_page: *[UEFI_ROM_SIZE]u8) void {
    @memset(out_page, 0x90); // NOP sled fill
    // At offset 0x000 (and 0xFF0 near top of 4K page):
    // movabs rax, UEFI_CODE_GPA (48 B8 <u64>)
    // jmp rax (FF E0)
    const stub = [_]u8{
        0x48, 0xB8,
        @truncate(UEFI_CODE_GPA),
        @truncate(UEFI_CODE_GPA >> 8),
        @truncate(UEFI_CODE_GPA >> 16),
        @truncate(UEFI_CODE_GPA >> 24),
        @truncate(UEFI_CODE_GPA >> 32),
        @truncate(UEFI_CODE_GPA >> 40),
        @truncate(UEFI_CODE_GPA >> 48),
        @truncate(UEFI_CODE_GPA >> 56),
        0xFF, 0xE0,
    };
    @memcpy(out_page[0..stub.len], &stub);
    @memcpy(out_page[0xFF0 .. 0xFF0 + stub.len], &stub);
}

const CodeBuilder = struct {
    buf: [8192]u8 = @splat(0xCC),
    len: usize = 0,
    check_id: usize = 0,

    fn emit(self: *CodeBuilder, bytes: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn emitU32(self: *CodeBuilder, v: u32) void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        self.emit(&tmp);
    }

    fn emitU64(self: *CodeBuilder, v: u64) void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, v, .little);
        self.emit(&tmp);
    }

    // mov eax, imm32
    fn movEaxImm32(self: *CodeBuilder, v: u32) void {
        self.emit(&.{0xB8});
        self.emitU32(v);
    }

    // movabs rbx, imm64
    fn movRbxImm64(self: *CodeBuilder, v: u64) void {
        self.emit(&.{ 0x48, 0xBB });
        self.emitU64(v);
    }

    // mov eax, [rbx] (32-bit read into eax — matches vmx.zig MMIO read to regs.rax)
    fn loadEaxFromRbx(self: *CodeBuilder) void {
        self.emit(&.{ 0x8B, 0x03 });
    }

    // mov [rbx], eax (32-bit write from eax — matches vmx.zig decodeMmioWrite)
    fn storeEaxToRbx(self: *CodeBuilder) void {
        self.emit(&.{ 0x89, 0x03 });
    }

    fn mmioWrite32(self: *CodeBuilder, addr: u64, val: u32) void {
        self.movRbxImm64(addr);
        self.movEaxImm32(val);
        self.storeEaxToRbx();
    }

    fn mmioRead32IntoEax(self: *CodeBuilder, addr: u64) void {
        self.movRbxImm64(addr);
        self.loadEaxFromRbx();
    }

    // Compare EAX with imm32; if not equal, print "!<id>\n" on COM1 and halt forever.
    fn expectEaxEq(self: *CodeBuilder, expected: u32) void {
        const id: u8 = 'A' + @as(u8, @intCast(self.check_id % 26));
        self.check_id += 1;
        // cmp eax, imm32
        self.emit(&.{0x3D});
        self.emitU32(expected);
        // je +17 (skip the 17-byte failure block)
        self.emit(&.{ 0x74, 0x11 });
        // mov dx, 0x3F8; mov al, '!'; out dx, al; mov al, id; out dx, al; mov al, '\n'; out dx, al
        self.emit(&.{ 0x66, 0xBA, 0xF8, 0x03, 0xB0, '!', 0xEE, 0xB0, id, 0xEE, 0xB0, 0x0A, 0xEE });
        // cli; hlt; jmp -3 (back to hlt)
        self.emit(&.{ 0xFA, 0xF4, 0xEB, 0xFD });
    }

    fn outbCom1Char(self: *CodeBuilder, ch: u8) void {
        // mov dx, 0x3F8 (66 BA F8 03)
        // mov al, ch (B0 <ch>)
        // out dx, al (EE)
        self.emit(&.{ 0x66, 0xBA, 0xF8, 0x03, 0xB0, ch, 0xEE });
    }

    fn printCom1(self: *CodeBuilder, text: []const u8) void {
        for (text) |ch| {
            self.outbCom1Char(ch);
        }
    }

    fn pciCheckVendorDevice(self: *CodeBuilder, dev: u8, expected_id: u32) void {
        const addr: u32 = 0x8000_0000 | (@as(u32, dev) << 11);
        // mov dx, 0xCF8; mov eax, addr; out dx, eax
        self.emit(&.{ 0x66, 0xBA, 0xF8, 0x0C });
        self.movEaxImm32(addr);
        self.emit(&.{0xEF});
        // mov dx, 0xCFC; in eax, dx
        self.emit(&.{ 0x66, 0xBA, 0xFC, 0x0C, 0xED });
        self.expectEaxEq(expected_id);
    }

    fn writeCrbBytes(self: *CodeBuilder, cmd: []const u8) void {
        var off: usize = 0;
        while (off < cmd.len) : (off += 4) {
            var word_bytes: [4]u8 = @splat(0);
            const rem = @min(4, cmd.len - off);
            @memcpy(word_bytes[0..rem], cmd[off .. off + rem]);
            const word = std.mem.readInt(u32, &word_bytes, .little);
            self.mmioWrite32(vtpm.TPM_CRB_MMIO_BASE + vtpm.CRB_DATA_BUFFER_OFFSET + off, word);
        }
    }

    fn runTpmCmdAndExpectRc(self: *CodeBuilder, cmd: []const u8, expected_rc: u32) void {
        self.writeCrbBytes(cmd);
        self.mmioWrite32(vtpm.TPM_CRB_MMIO_BASE + vtpm.REG_CTRL_START, 1);
        // Response code is at offset 6..10 in big-endian; read aligned dword at offset 4..8 and 8..12 or read byte-swapped
        // Wait: at offset 4..8, bytes [4,5] = low 16 bits of size (0x00, size_lo), bytes [6,7] = high 16 bits of RC (0x00, 0x00)
        // At offset 8..12, bytes [8,9] = low 16 bits of RC (big-endian)!
        // Let's check: RC is big-endian u32 at data_buffer[6..10].
        // So data_buffer[8] = (expected_rc >> 8) & 0xFF, data_buffer[9] = expected_rc & 0xFF!
        // When we read 32-bit little-endian at CRB_DATA_BUFFER_OFFSET + 8, the low 16 bits of EAX are data_buffer[8..10]!
        self.mmioRead32IntoEax(vtpm.TPM_CRB_MMIO_BASE + vtpm.CRB_DATA_BUFFER_OFFSET + 8);
        // Mask EAX to low 16 bits: and eax, 0xFFFF (25 FF FF 00 00)
        self.emit(&.{ 0x25, 0xFF, 0xFF, 0x00, 0x00 });
        const be_low16: u32 = ((expected_rc & 0xFF) << 8) | ((expected_rc >> 8) & 0xFF);
        self.expectEaxEq(be_low16);
    }

    fn emitVirtioDesc(self: *CodeBuilder, idx: u16, addr: u64, len: u32, flags: u16, next: u16) void {
        const base = VIRTIO_DESC_GPA + (@as(u64, idx) * 16);
        self.mmioWrite32(base + 0, @truncate(addr));
        self.mmioWrite32(base + 4, @truncate(addr >> 32));
        self.mmioWrite32(base + 8, len);
        const flags_next: u32 = @as(u32, flags) | (@as(u32, next) << 16);
        self.mmioWrite32(base + 12, flags_next);
    }

    fn emitWaitForUsedIdx(self: *CodeBuilder, expected_used_idx: u16) void {
        // Loop:
        //   read VIRTIO_BLK_MMIO_BASE + 0x060 (InterruptStatus) -> triggers vmx.zig scheduler.schedule() so storaged runs!
        //   read VIRTIO_USED_GPA (flags_and_idx: high 16 bits = used->idx)
        //   shr eax, 16
        //   cmp eax, expected_used_idx
        //   jne Loop
        const loop_start = self.len;
        self.mmioRead32IntoEax(0xFE00_1060);
        self.mmioRead32IntoEax(VIRTIO_USED_GPA);
        // shr eax, 16 (C1 E8 10)
        self.emit(&.{ 0xC1, 0xE8, 0x10 });
        // cmp eax, expected_used_idx (3D <u32>)
        self.emit(&.{0x3D});
        self.emitU32(expected_used_idx);
        // jne loop_start (75 <rel8>)
        const rel: i8 = @intCast(@as(isize, @intCast(loop_start)) - @as(isize, @intCast(self.len + 2)));
        self.emit(&.{ 0x75, @bitCast(rel) });
        // Also verify status byte at VIRTIO_STATUS_GPA == 0
        self.mmioRead32IntoEax(VIRTIO_STATUS_GPA);
        self.emit(&.{ 0x25, 0xFF, 0x00, 0x00, 0x00 });
        self.expectEaxEq(0);
    }
};

fn buildApprovedImageComptime() [8192]u8 {
    @setEvalBranchQuota(200_000);
    var cb = CodeBuilder{};

    // 1. Verify ACPI 2.0+ tables at 0x000E_0000
    cb.mmioRead32IntoEax(pc_platform.ACPI_TABLES_GPA + pc_platform.RSDP_OFFSET);
    cb.expectEaxEq(0x2044_5352); // "RSD "
    cb.mmioRead32IntoEax(pc_platform.ACPI_TABLES_GPA + pc_platform.RSDT_OFFSET);
    cb.expectEaxEq(0x5444_5352); // "RSDT"
    cb.mmioRead32IntoEax(pc_platform.ACPI_TABLES_GPA + pc_platform.XSDT_OFFSET);
    cb.expectEaxEq(0x5444_5358); // "XSDT"
    cb.mmioRead32IntoEax(pc_platform.ACPI_TABLES_GPA + pc_platform.FADT_OFFSET);
    cb.expectEaxEq(0x5043_4146); // "FACP"
    cb.mmioRead32IntoEax(pc_platform.ACPI_TABLES_GPA + pc_platform.MADT_OFFSET);
    cb.expectEaxEq(0x4349_5041); // "APIC"
    cb.mmioRead32IntoEax(pc_platform.ACPI_TABLES_GPA + pc_platform.MCFG_OFFSET);
    cb.expectEaxEq(0x4746_434D); // "MCFG"
    cb.mmioRead32IntoEax(pc_platform.ACPI_TABLES_GPA + pc_platform.TPM2_OFFSET);
    cb.expectEaxEq(0x324D_5054); // "TPM2"
    cb.printCom1("uefi_vm: ACPI RSDP+XSDT+FACP+APIC+MCFG+TPM2 verified\n");

    // 2. Verify CMOS RTC (0x70/0x71) and PCI Bus 0 enumeration (0xCF8/0xCFC)
    // out 0x70, 0x09; in al, 0x71
    cb.emit(&.{ 0x31, 0xC0, 0xB0, 0x09, 0xE6, 0x70, 0xE4, 0x71 });
    cb.expectEaxEq(0x26);
    cb.pciCheckVendorDevice(0, 0x29C0_8086);
    cb.pciCheckVendorDevice(1, 0x1111_1AF4);
    cb.pciCheckVendorDevice(2, 0x1041_1AF4);
    cb.pciCheckVendorDevice(3, 0x1042_1AF4);
    cb.printCom1("uefi_vm: PCI bus enumerated devs=4 (host,gop,net,blk)\n");

    // 3. Verify & activate GOP Framebuffer (0xFD00_0000)
    cb.mmioRead32IntoEax(pc_platform.GOP_MMIO_BASE + pc_platform.VmGopState.REG_MAGIC);
    cb.expectEaxEq(pc_platform.GOP_MAGIC);
    cb.mmioRead32IntoEax(pc_platform.GOP_MMIO_BASE + pc_platform.VmGopState.REG_WIDTH);
    cb.expectEaxEq(pc_platform.GOP_DEFAULT_WIDTH);
    cb.mmioRead32IntoEax(pc_platform.GOP_MMIO_BASE + pc_platform.VmGopState.REG_HEIGHT);
    cb.expectEaxEq(pc_platform.GOP_DEFAULT_HEIGHT);
    cb.mmioWrite32(pc_platform.GOP_MMIO_BASE + pc_platform.VmGopState.VRAM_WINDOW_OFFSET, 0x0022_AAFF);
    cb.mmioWrite32(pc_platform.GOP_MMIO_BASE + pc_platform.VmGopState.REG_FLUSH, 1);
    cb.mmioRead32IntoEax(pc_platform.GOP_MMIO_BASE + pc_platform.VmGopState.REG_STATUS);
    cb.expectEaxEq(pc_platform.VmGopState.STATUS_ACTIVE);
    cb.printCom1("uefi_vm: GOP framebuffer 1024x768x32 active\n");

    // 4. Exercise TPM 2.0 CRB at 0xFED4_0000
    cb.mmioRead32IntoEax(vtpm.TPM_CRB_MMIO_BASE + vtpm.REG_INTF_ID);
    cb.expectEaxEq(0x0000_4011);
    cb.mmioWrite32(vtpm.TPM_CRB_MMIO_BASE + vtpm.REG_CTRL_REQ, 1);

    const startup_cmd = [_]u8{
        0x80, 0x01, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x01, 0x44, 0x00, 0x00,
    };
    cb.runTpmCmdAndExpectRc(&startup_cmd, vtpm.TPM_RC_SUCCESS);

    const selftest_cmd = [_]u8{
        0x80, 0x01, 0x00, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x01, 0x43, 0x01,
    };
    cb.runTpmCmdAndExpectRc(&selftest_cmd, vtpm.TPM_RC_SUCCESS);

    var extend_cmd: [46]u8 = @splat(0xA5);
    std.mem.writeInt(u16, extend_cmd[0..2], vtpm.TPM_ST_SESSIONS, .big);
    std.mem.writeInt(u32, extend_cmd[2..6], 46, .big);
    std.mem.writeInt(u32, extend_cmd[6..10], vtpm.TPM_CC_PCR_EXTEND, .big);
    std.mem.writeInt(u32, extend_cmd[10..14], 0, .big);
    cb.runTpmCmdAndExpectRc(&extend_cmd, vtpm.TPM_RC_SUCCESS);

    const create_cmd = [_]u8{
        0x80, 0x02, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x01, 0x53,
        0x00, 0x08, 'V',  'M',  'K',  '-',  '2',  '0',  '2',  '6',
    };
    cb.runTpmCmdAndExpectRc(&create_cmd, vtpm.TPM_RC_SUCCESS);

    const unseal_cmd = [_]u8{
        0x80, 0x02, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x01, 0x5E,
    };
    cb.runTpmCmdAndExpectRc(&unseal_cmd, vtpm.TPM_RC_SUCCESS);
    // Verify unsealed secret bytes at offset 12..16 == "VMK-" (0x2D4B_4D56)
    cb.mmioRead32IntoEax(vtpm.TPM_CRB_MMIO_BASE + vtpm.CRB_DATA_BUFFER_OFFSET + 12);
    cb.expectEaxEq(0x2D4B_4D56);
    cb.printCom1("uefi_vm: TPM 2.0 startup+selftest+PCR0+seal+unseal OK\n");

    // Extend PCR[0] again so policy no longer matches, then verify Unseal fails with TPM_RC_POLICY_FAIL
    cb.runTpmCmdAndExpectRc(&extend_cmd, vtpm.TPM_RC_SUCCESS);
    cb.runTpmCmdAndExpectRc(&unseal_cmd, vtpm.TPM_RC_POLICY_FAIL);
    cb.printCom1("uefi_vm: TPM 2.0 PCR mismatch unseal rejected\n");

    // 5. Persistent EFI Variable Store at 0xFE00_2000
    cb.mmioRead32IntoEax(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_MAGIC);
    cb.expectEaxEq(efi_vars.EFI_VAR_MAGIC);
    cb.mmioRead32IntoEax(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_SECURE_BOOT);
    cb.expectEaxEq(1);

    // Check REG_BOOT_COUNT: if 0 -> first boot; else -> warm reboot recovery!
    cb.mmioRead32IntoEax(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_BOOT_COUNT);
    // cmp eax, 0 (83 F8 00)
    cb.emit(&.{ 0x83, 0xF8, 0x00 });
    // jne reboot_branch (0F 85 <rel32>)
    cb.emit(&.{ 0x0F, 0x85 });
    const jne_reboot_patch = cb.len;
    cb.emitU32(0);

    // First boot branch:
    cb.mmioWrite32(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_BOOT_ORDER, 1);
    cb.mmioWrite32(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_BOOT0001, 0x0001_0001);
    cb.mmioWrite32(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_BOOT_COUNT, 1);
    cb.mmioWrite32(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_CMD, efi_vars.CMD_COMMIT_NV);
    cb.printCom1("uefi_vm: EFI vars persisted boot_count=1\n");
    // jmp after_efi_branch (E9 <rel32>)
    cb.emit(&.{0xE9});
    const jmp_after_efi_patch = cb.len;
    cb.emitU32(0);

    // Reboot branch target:
    const reboot_branch_pos = cb.len;
    std.mem.writeInt(
        u32,
        cb.buf[jne_reboot_patch..][0..4],
        @bitCast(@as(i32, @intCast(reboot_branch_pos - (jne_reboot_patch + 4)))),
        .little,
    );
    cb.mmioRead32IntoEax(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_BOOT0001);
    cb.expectEaxEq(0x0001_0001);
    cb.mmioWrite32(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_BOOT_COUNT, 2);
    cb.mmioWrite32(efi_vars.EFI_VAR_MMIO_BASE + efi_vars.REG_CMD, efi_vars.CMD_COMMIT_NV);
    cb.printCom1("uefi_vm: EFI vars recovered boot_count=2\n");

    const after_efi_pos = cb.len;
    std.mem.writeInt(
        u32,
        cb.buf[jmp_after_efi_patch..][0..4],
        @bitCast(@as(i32, @intCast(after_efi_pos - (jmp_after_efi_patch + 4)))),
        .little,
    );

    // 6. Initialize Virtio-Blk MMIO at 0xFE00_1000
    cb.mmioWrite32(0xFE00_1070, 0); // Status = Reset
    cb.mmioWrite32(0xFE00_1070, 3); // ACKNOWLEDGE | DRIVER
    cb.mmioWrite32(0xFE00_1024, 0); // DriverFeaturesSel = 0
    cb.mmioWrite32(0xFE00_1020, 0x200); // VIRTIO_BLK_F_FLUSH
    cb.mmioWrite32(0xFE00_1070, 11); // FEATURES_OK
    cb.mmioWrite32(0xFE00_1030, 0); // QueueSel = 0
    cb.mmioWrite32(0xFE00_1038, 8); // QueueNum = 8
    cb.mmioWrite32(0xFE00_1080, @truncate(VIRTIO_DESC_GPA));
    cb.mmioWrite32(0xFE00_1084, 0);
    cb.mmioWrite32(0xFE00_1090, @truncate(VIRTIO_AVAIL_GPA));
    cb.mmioWrite32(0xFE00_1094, 0);
    cb.mmioWrite32(0xFE00_10A0, @truncate(VIRTIO_USED_GPA));
    cb.mmioWrite32(0xFE00_10A4, 0);
    cb.mmioWrite32(0xFE00_1044, 1); // QueueReady = 1
    cb.mmioWrite32(0xFE00_1070, 15); // DRIVER_OK
    // Zero avail and used ring headers
    cb.mmioWrite32(VIRTIO_AVAIL_GPA, 0);
    cb.mmioWrite32(VIRTIO_USED_GPA, 0);

    cb.printCom1("uefi_vm: ready\n");

    // 7. Interactive command loop on COM1 (0x3F8)
    // Read first character of line, consume until '\n', dispatch on first unique character:
    //   'h' -> help
    //   'd' + 6th char 'w' ("disk-write") -> FUA write + flush "CATENARY-UEFI-PERSIST"
    //   'd' + 6th char 'v' ("disk-verify") -> readback sector 0 and verify "CATENARY-UEFI-PERSIST"
    const cmd_loop_pos = cb.len;
    // Clear command buffer (8 bytes at SERIAL_CMD_BUF_GPA)
    cb.mmioWrite32(SERIAL_CMD_BUF_GPA, 0);
    cb.mmioWrite32(SERIAL_CMD_BUF_GPA + 4, 0);
    // xor r12, r12 (4D 31 E4) -> char index
    cb.emit(&.{ 0x4D, 0x31, 0xE4 });

    const poll_char_pos = cb.len;
    // Check LSR (0x3FD) bit 0:
    // mov dx, 0x3FD; in al, dx; test al, 1; jnz +3; hlt; jmp -12 (0xF4)
    cb.emit(&.{ 0x66, 0xBA, 0xFD, 0x03, 0xEC, 0xA8, 0x01, 0x75, 0x03, 0xF4, 0xEB, 0xF4 });
    // Read char from 0x3F8: mov dx, 0x3F8; in al, dx
    cb.emit(&.{ 0x66, 0xBA, 0xF8, 0x03, 0xEC });
    // Ignore '\r' (0x0D): cmp al, 0x0D; je poll_char_pos
    cb.emit(&.{ 0x3C, 0x0D });
    const je_cr_rel: i8 = @intCast(@as(isize, @intCast(poll_char_pos)) - @as(isize, @intCast(cb.len + 2)));
    cb.emit(&.{ 0x74, @bitCast(je_cr_rel) });
    // Check '\n' (0x0A): cmp al, 0x0A; je line_done (+25 bytes = 0x19)
    cb.emit(&.{ 0x3C, 0x0A, 0x74, 0x19 });
    // If r12 < 8, store al at SERIAL_CMD_BUF_GPA + r12:
    // cmp r12, 8 (49 83 FC 08); jae skip_store (73 0E)
    // movabs rbx, SERIAL_CMD_BUF_GPA (48 BB <u64>)
    // mov [rbx + r12], al (42 88 04 23)
    // inc r12 (49 FF C4)
    cb.emit(&.{ 0x49, 0x83, 0xFC, 0x08, 0x73, 0x11 });
    cb.movRbxImm64(SERIAL_CMD_BUF_GPA);
    cb.emit(&.{ 0x42, 0x88, 0x04, 0x23, 0x49, 0xFF, 0xC4 });
    const jmp_poll_rel: i8 = @intCast(@as(isize, @intCast(poll_char_pos)) - @as(isize, @intCast(cb.len + 2)));
    cb.emit(&.{ 0xEB, @bitCast(jmp_poll_rel) });

    // line_done:
    // Read first 4 bytes at SERIAL_CMD_BUF_GPA into EAX
    cb.mmioRead32IntoEax(SERIAL_CMD_BUF_GPA);
    // Check "help" (0x706C_6568):
    cb.emit(&.{0x3D});
    cb.emitU32(0x706C_6568);
    cb.emit(&.{ 0x0F, 0x85 });
    const jne_not_help_patch = cb.len;
    cb.emitU32(0);

    cb.printCom1("uefi_vm: commands: help disk-write disk-verify\n");
    cb.emit(&.{0xE9});
    const jmp_loop_from_help = cb.len;
    cb.emitU32(@bitCast(@as(i32, @intCast(@as(isize, @intCast(cmd_loop_pos)) - @as(isize, @intCast(jmp_loop_from_help + 4))))));

    const not_help_pos = cb.len;
    std.mem.writeInt(
        u32,
        cb.buf[jne_not_help_patch..][0..4],
        @bitCast(@as(i32, @intCast(not_help_pos - (jne_not_help_patch + 4)))),
        .little,
    );

    // Check bytes 4..8 at SERIAL_CMD_BUF_GPA + 4:
    // For "disk-write", bytes 4..8 are "-wri" (0x6972_772D)
    // For "disk-verify", bytes 4..8 are "-ver" (0x7265_762D)
    cb.mmioRead32IntoEax(SERIAL_CMD_BUF_GPA + 4);
    cb.emit(&.{0x3D});
    cb.emitU32(0x6972_772D); // "-wri"
    cb.emit(&.{ 0x0F, 0x85 });
    const jne_not_write_patch = cb.len;
    cb.emitU32(0);

    // === disk-write handler ===
    // 1. Write "CATENARY-UEFI-PERSIST" into VIRTIO_DATA_BUF_GPA (21 bytes = 6 dwords)
    const tag = "CATENARY-UEFI-PERSIST\x00\x00\x00";
    comptime var ti: usize = 0;
    inline while (ti < 24) : (ti += 4) {
        const w = comptime std.mem.readInt(u32, tag[ti..][0..4], .little);
        cb.mmioWrite32(VIRTIO_DATA_BUF_GPA + ti, w);
    }
    // 2. RequestHeader at VIRTIO_REQ_HDR_GPA: type = VIRTIO_BLK_T_OUT | VIRTIO_BLK_T_FUA (0x11), sector = 0
    cb.mmioWrite32(VIRTIO_REQ_HDR_GPA + 0, 0x11);
    cb.mmioWrite32(VIRTIO_REQ_HDR_GPA + 4, 0);
    cb.mmioWrite32(VIRTIO_REQ_HDR_GPA + 8, 0);
    cb.mmioWrite32(VIRTIO_REQ_HDR_GPA + 12, 0);
    cb.mmioWrite32(VIRTIO_STATUS_GPA, 0xFF);

    // Descriptors 0 -> 1 -> 2
    cb.emitVirtioDesc(0, VIRTIO_REQ_HDR_GPA, 16, 1, 1); // NEXT
    cb.emitVirtioDesc(1, VIRTIO_DATA_BUF_GPA, 512, 1, 2); // NEXT (device-readable)
    cb.emitVirtioDesc(2, VIRTIO_STATUS_GPA, 1, 2, 0); // WRITE

    // Avail ring: flags=0, idx=1, ring[0]=0
    cb.mmioWrite32(VIRTIO_AVAIL_GPA + 0, 0x0001_0000);
    cb.mmioWrite32(VIRTIO_AVAIL_GPA + 4, 0);
    // Notify Queue 0
    cb.mmioWrite32(0xFE00_1050, 0);
    cb.emitWaitForUsedIdx(1);

    // 3. Submit VIRTIO_BLK_T_FLUSH (type = 4) using descriptors 0 -> 1
    cb.mmioWrite32(VIRTIO_REQ_HDR_GPA + 0, 4);
    cb.mmioWrite32(VIRTIO_STATUS_GPA, 0xFF);
    cb.emitVirtioDesc(0, VIRTIO_REQ_HDR_GPA, 16, 1, 1); // NEXT
    cb.emitVirtioDesc(1, VIRTIO_STATUS_GPA, 1, 2, 0); // WRITE
    // Avail ring: flags=0, idx=2, ring[1]=0
    cb.mmioWrite32(VIRTIO_AVAIL_GPA + 0, 0x0002_0000);
    cb.mmioWrite32(VIRTIO_AVAIL_GPA + 4, 0);
    cb.mmioWrite32(0xFE00_1050, 0);
    cb.emitWaitForUsedIdx(2);

    cb.printCom1("uefi_vm: disk FUA write+flush OK tag=CATENARY-UEFI-PERSIST\n");
    cb.emit(&.{0xE9});
    const jmp_loop_from_write = cb.len;
    cb.emitU32(@bitCast(@as(i32, @intCast(@as(isize, @intCast(cmd_loop_pos)) - @as(isize, @intCast(jmp_loop_from_write + 4))))));

    const not_write_pos = cb.len;
    std.mem.writeInt(
        u32,
        cb.buf[jne_not_write_patch..][0..4],
        @bitCast(@as(i32, @intCast(not_write_pos - (jne_not_write_patch + 4)))),
        .little,
    );

    // Check "-ver" (0x7265_762D) for "disk-verify"
    cb.emit(&.{0x3D});
    cb.emitU32(0x7265_762D);
    cb.emit(&.{ 0x0F, 0x85 });
    const jne_not_verify_patch = cb.len;
    cb.emitU32(0);

    // === disk-verify handler ===
    // Clear readback buffer first so we prove data comes from storaged NVMe disk extent
    comptime var ci: usize = 0;
    inline while (ci < 24) : (ci += 4) {
        cb.mmioWrite32(VIRTIO_DATA_BUF_GPA + ci, 0);
    }
    // RequestHeader: type = VIRTIO_BLK_T_IN (0), sector = 0
    cb.mmioWrite32(VIRTIO_REQ_HDR_GPA + 0, 0);
    cb.mmioWrite32(VIRTIO_REQ_HDR_GPA + 4, 0);
    cb.mmioWrite32(VIRTIO_REQ_HDR_GPA + 8, 0);
    cb.mmioWrite32(VIRTIO_REQ_HDR_GPA + 12, 0);
    cb.mmioWrite32(VIRTIO_STATUS_GPA, 0xFF);

    cb.emitVirtioDesc(0, VIRTIO_REQ_HDR_GPA, 16, 1, 1); // NEXT
    cb.emitVirtioDesc(1, VIRTIO_DATA_BUF_GPA, 512, 3, 2); // WRITE | NEXT
    cb.emitVirtioDesc(2, VIRTIO_STATUS_GPA, 1, 2, 0); // WRITE

    // Avail ring: flags=0, idx=1, ring[0]=0
    cb.mmioWrite32(VIRTIO_AVAIL_GPA + 0, 0x0001_0000);
    cb.mmioWrite32(VIRTIO_AVAIL_GPA + 4, 0);
    cb.mmioWrite32(0xFE00_1050, 0);
    cb.emitWaitForUsedIdx(1);

    // Verify all 5 dwords of "CATENARY-UEFI-PERSIST"
    comptime var vi: usize = 0;
    inline while (vi < 20) : (vi += 4) {
        const expected_w = comptime std.mem.readInt(u32, tag[vi..][0..4], .little);
        cb.mmioRead32IntoEax(VIRTIO_DATA_BUF_GPA + vi);
        cb.expectEaxEq(expected_w);
    }
    cb.printCom1("uefi_vm: disk readback after reboot OK tag=CATENARY-UEFI-PERSIST\n");

    const not_verify_pos = cb.len;
    std.mem.writeInt(
        u32,
        cb.buf[jne_not_verify_patch..][0..4],
        @bitCast(@as(i32, @intCast(not_verify_pos - (jne_not_verify_patch + 4)))),
        .little,
    );

    cb.emit(&.{0xE9});
    const jmp_loop_end = cb.len;
    cb.emitU32(@bitCast(@as(i32, @intCast(@as(isize, @intCast(cmd_loop_pos)) - @as(isize, @intCast(jmp_loop_end + 4))))));

    return cb.buf;
}

const approved_uefi_image: [8192]u8 = buildApprovedImageComptime();
const revoked_uefi_image = "MZ-PE32+-UEFI-REVOKED-BOOTX64-CVE-2026-DBX-BLOCKED".*;

pub fn getApprovedUefiImage() []const u8 {
    return &approved_uefi_image;
}

pub fn getRevokedUefiImage() []const u8 {
    return &revoked_uefi_image;
}

test "uefi_firmware: profile admission enforces external media, resources, and Secure Boot dbx" {
    efi_vars.resetInstance(1);
    try std.testing.expect(efi_vars.initDefaultSecureBootStore(
        1,
        getApprovedUefiImage(),
        getRevokedUefiImage(),
    ));

    // 1. Ubuntu 26.04 and Windows 11 26H2 fail closed when external installer media is absent
    try std.testing.expectError(
        error.MissingInstallerMedia,
        validateFullVmAdmission(1, .ubuntu_26_04, .{}),
    );
    try std.testing.expectError(
        error.MissingInstallerMedia,
        validateFullVmAdmission(1, .windows_11_26h2, .{}),
    );

    // 2. Even with installer media present, insufficient RAM/disk/vCPUs fail closed
    try std.testing.expectError(
        error.InsufficientVcpus,
        validateFullVmAdmission(1, .windows_11_26h2, .{
            .allocated_vcpus = 1,
            .allocated_ram_mib = 4096,
            .allocated_disk_mib = 64 * 1024,
            .has_external_installer_iso = true,
        }),
    );
    try std.testing.expectError(
        error.InsufficientRam,
        validateFullVmAdmission(1, .ubuntu_26_04, .{
            .allocated_vcpus = 2,
            .allocated_ram_mib = 512,
            .allocated_disk_mib = 20 * 1024,
            .has_external_installer_iso = true,
        }),
    );

    // 3. Revoked UEFI image fails closed with SecureBootRevokedInDbx
    try std.testing.expectError(
        error.SecureBootRevokedInDbx,
        validateFullVmAdmission(1, .uefi_revoked, .{}),
    );

    // 4. Approved direct UEFI Full-VM passes admission
    try validateFullVmAdmission(1, .uefi_direct, .{});
}

test "uefi_firmware: reset vector page jumps to UEFI_CODE_GPA" {
    var rom: [UEFI_ROM_SIZE]u8 = undefined;
    buildResetVectorPage(&rom);
    try std.testing.expectEqual(@as(u8, 0x48), rom[0]);
    try std.testing.expectEqual(@as(u8, 0xB8), rom[1]);
    try std.testing.expectEqual(UEFI_CODE_GPA, std.mem.readInt(u64, rom[2..10], .little));
    try std.testing.expectEqual(@as(u8, 0xFF), rom[10]);
    try std.testing.expectEqual(@as(u8, 0xE0), rom[11]);
}
