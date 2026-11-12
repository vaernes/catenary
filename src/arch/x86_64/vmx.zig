const std = @import("std");
const build_options = @import("build_options");
const cpu = @import("cpu.zig");
const smp = @import("smp.zig");
const gdt = @import("gdt.zig");
const host_paging = @import("paging.zig");
const limine = @import("../../kernel/limine.zig");
const pmm = @import("../../kernel/pmm.zig");
const linux_boot = @import("../../vmm/linux_boot.zig");
const microvm_registry = @import("../../vmm/microvm_registry.zig");
const virtio_net = @import("../../vmm/virtio_net.zig");
const virtio_blk = @import("../../vmm/virtio_blk.zig");
const pc_platform = @import("../../vmm/pc_platform.zig");
const efi_vars = @import("../../vmm/efi_vars.zig");
const vtpm = @import("../../vmm/vtpm.zig");
const uefi_firmware = @import("../../vmm/uefi_firmware.zig");
const buffer_grant = @import("../../vmm/buffer_grant.zig");
const dipc = @import("../../ipc/dipc.zig");
const microvm_bridge = @import("../../vmm/microvm_bridge.zig");
const guest_image_blob = @import("guest_image_blob");
const guest_initramfs_blob = @import("guest_initramfs_blob");

const endpoint_table = @import("../../ipc/endpoint_table.zig");

const IA32_FEATURE_CONTROL: u32 = 0x3A;
const IA32_VMX_BASIC: u32 = 0x480;
const IA32_VMX_PINBASED_CTLS: u32 = 0x481;
const IA32_VMX_PROCBASED_CTLS: u32 = 0x482;
const IA32_VMX_EXIT_CTLS: u32 = 0x483;
const IA32_VMX_ENTRY_CTLS: u32 = 0x484;
const IA32_VMX_CR0_FIXED0: u32 = 0x486;
const IA32_VMX_CR0_FIXED1: u32 = 0x487;
const IA32_VMX_CR4_FIXED0: u32 = 0x488;
const IA32_VMX_CR4_FIXED1: u32 = 0x489;
const IA32_VMX_TRUE_PINBASED_CTLS: u32 = 0x48D;
const IA32_VMX_TRUE_PROCBASED_CTLS: u32 = 0x48E;
const IA32_VMX_TRUE_EXIT_CTLS: u32 = 0x48F;
const IA32_VMX_TRUE_ENTRY_CTLS: u32 = 0x490;
const IA32_VMX_PROCBASED_CTLS2: u32 = 0x48B;
const IA32_VMX_TRUE_PROCBASED_CTLS2: u32 = 0x48B;
const IA32_VMX_EPT_VPID_CAP: u32 = 0x48C;
const IA32_APIC_BASE: u32 = 0x1B;
const IA32_BIOS_SIGN_ID: u32 = 0x8B;
const IA32_MTRRCAP: u32 = 0xFE;
const IA32_FS_BASE: u32 = 0xC0000100;
const IA32_GS_BASE: u32 = 0xC0000101;
const IA32_EFER: u32 = 0xC0000080;
const IA32_PAT: u32 = 0x277;
const IA32_ARCH_CAPABILITIES: u32 = 0x10A;
const IA32_MISC_ENABLE: u32 = 0x1A0;
const AMD64_PATCH_LEVEL: u32 = 0xC0011029;
const MSR_CORE_PERF_FIXED_CTR_CTRL: u32 = 0x38D;
const MSR_CORE_PERF_GLOBAL_STATUS: u32 = 0x38E;
const MSR_CORE_PERF_GLOBAL_CTRL: u32 = 0x38F;
const MSR_CORE_PERF_GLOBAL_OVF_CTRL: u32 = 0x390;
const MSR_SNB_UNC_PERF_GLOBAL_CTRL: u32 = 0x391;
const MSR_SNB_UNC_FIXED_CTR_CTRL: u32 = 0x394;
const MSR_SNB_UNC_FIXED_CTR: u32 = 0x395;

const FEATURE_CONTROL_LOCK: u64 = 1 << 0;
const FEATURE_CONTROL_VMXON_OUTSIDE_SMX: u64 = 1 << 2;
const CR4_VMXE: u64 = 1 << 13;

const VMCS_VM_INSTRUCTION_ERROR: u64 = 0x4400;
const VMCS_VM_EXIT_REASON: u64 = 0x4402;
const VMCS_VM_EXIT_INTERRUPTION_INFO: u64 = 0x4404;
const VMCS_VM_EXIT_INTERRUPTION_ERROR_CODE: u64 = 0x4406;
const VMCS_VM_EXIT_INSTRUCTION_LEN: u64 = 0x440C;
const VMCS_EXIT_QUALIFICATION: u64 = 0x6400;
const VMCS_GUEST_PHYSICAL_ADDRESS: u64 = 0x2400;
const VMCS_GUEST_LINEAR_ADDRESS: u64 = 0x640A;

const VMCS_CTRL_PIN_BASED: u64 = 0x4000;
const VMCS_CTRL_CPU_BASED: u64 = 0x4002;
const VMCS_CTRL_EXCEPTION_BITMAP: u64 = 0x4004;
const VMCS_CTRL_VMEXIT: u64 = 0x400C;
const VMCS_CTRL_VMENTRY: u64 = 0x4012;
const VMCS_CTRL_SECONDARY_CPU_BASED: u64 = 0x401E;
const VMCS_CTRL_EPT_POINTER: u64 = 0x201A;
const VMCS_CTRL_MSR_BITMAPS: u64 = 0x2004;
const VMCS_CTRL_CR0_GUEST_HOST_MASK: u64 = 0x6000;
const VMCS_CTRL_CR4_GUEST_HOST_MASK: u64 = 0x6002;
const VMCS_CTRL_CR0_READ_SHADOW: u64 = 0x6004;
const VMCS_CTRL_CR4_READ_SHADOW: u64 = 0x6006;

const VMEXIT_REASON_EXCEPTION_NMI: u64 = 0;
const VMEXIT_REASON_EXTERNAL_INTERRUPT: u64 = 1;
const VMEXIT_REASON_TRIPLE_FAULT: u64 = 2;
const VMEXIT_REASON_INIT_SIGNAL: u64 = 3;
const VMEXIT_REASON_CPUID: u64 = 10;
const VMEXIT_REASON_HLT: u64 = 12;
const VMEXIT_REASON_INVD: u64 = 13;
const VMEXIT_REASON_INVLPG: u64 = 14;
const VMEXIT_REASON_RDPMC: u64 = 15;
const VMEXIT_REASON_IO_INSTRUCTION: u64 = 30;
const VMEXIT_REASON_MSR_READ: u64 = 31;
const VMEXIT_REASON_MSR_WRITE: u64 = 32;
const VMEXIT_REASON_APIC_ACCESS: u64 = 44;
const VMEXIT_REASON_EPT_VIOLATION: u64 = 48;
const VMEXIT_REASON_EPT_MISCONFIG: u64 = 33;
const VMEXIT_REASON_WBINVD: u64 = 54;
const VMEXIT_REASON_XSETBV: u64 = 55;
const VMEXIT_REASON_VMCALL: u64 = 18;
const VMEXIT_REASON_VMCLEAR: u64 = 19;
const VMEXIT_REASON_VMLAUNCH: u64 = 20;
const VMEXIT_REASON_VMPTRLD: u64 = 21;
const VMEXIT_REASON_VMPTRST: u64 = 22;
const VMEXIT_REASON_VMREAD: u64 = 23;
const VMEXIT_REASON_VMRESUME: u64 = 24;
const VMEXIT_REASON_VMWRITE: u64 = 25;
const VMEXIT_REASON_VMXOFF: u64 = 26;
const VMEXIT_REASON_VMXON: u64 = 27;

const VMCS_GUEST_ES_SELECTOR: u64 = 0x0800;
const VMCS_GUEST_CS_SELECTOR: u64 = 0x0802;
const VMCS_GUEST_SS_SELECTOR: u64 = 0x0804;
const VMCS_GUEST_DS_SELECTOR: u64 = 0x0806;
const VMCS_GUEST_FS_SELECTOR: u64 = 0x0808;
const VMCS_GUEST_GS_SELECTOR: u64 = 0x080A;
const VMCS_GUEST_LDTR_SELECTOR: u64 = 0x080C;
const VMCS_GUEST_TR_SELECTOR: u64 = 0x080E;

const VMCS_GUEST_ES_LIMIT: u64 = 0x4800;
const VMCS_GUEST_CS_LIMIT: u64 = 0x4802;
const VMCS_GUEST_SS_LIMIT: u64 = 0x4804;
const VMCS_GUEST_DS_LIMIT: u64 = 0x4806;
const VMCS_GUEST_FS_LIMIT: u64 = 0x4808;
const VMCS_GUEST_GS_LIMIT: u64 = 0x480A;
const VMCS_GUEST_LDTR_LIMIT: u64 = 0x480C;
const VMCS_GUEST_TR_LIMIT: u64 = 0x480E;
const VMCS_GUEST_GDTR_LIMIT: u64 = 0x4810;
const VMCS_GUEST_IDTR_LIMIT: u64 = 0x4812;

const VMCS_GUEST_ES_ACCESS_RIGHTS: u64 = 0x4814;
const VMCS_GUEST_CS_ACCESS_RIGHTS: u64 = 0x4816;
const VMCS_GUEST_SS_ACCESS_RIGHTS: u64 = 0x4818;
const VMCS_GUEST_DS_ACCESS_RIGHTS: u64 = 0x481A;
const VMCS_GUEST_FS_ACCESS_RIGHTS: u64 = 0x481C;
const VMCS_GUEST_GS_ACCESS_RIGHTS: u64 = 0x481E;
const VMCS_GUEST_LDTR_ACCESS_RIGHTS: u64 = 0x4820;
const VMCS_GUEST_TR_ACCESS_RIGHTS: u64 = 0x4822;
const VMCS_GUEST_INTERRUPTIBILITY: u64 = 0x4824;
const VMCS_GUEST_ACTIVITY_STATE: u64 = 0x4826;
const VMCS_GUEST_SYSENTER_CS: u64 = 0x482A;

const VMCS_GUEST_CR0: u64 = 0x6800;
const VMCS_GUEST_CR3: u64 = 0x6802;
const VMCS_GUEST_CR4: u64 = 0x6804;
const VMCS_GUEST_ES_BASE: u64 = 0x6806;
const VMCS_GUEST_CS_BASE: u64 = 0x6808;
const VMCS_GUEST_SS_BASE: u64 = 0x680A;
const VMCS_GUEST_DS_BASE: u64 = 0x680C;
const VMCS_GUEST_FS_BASE: u64 = 0x680E;
const VMCS_GUEST_GS_BASE: u64 = 0x6810;
const VMCS_GUEST_LDTR_BASE: u64 = 0x6812;
const VMCS_GUEST_TR_BASE: u64 = 0x6814;
const VMCS_GUEST_GDTR_BASE: u64 = 0x6816;
const VMCS_GUEST_IDTR_BASE: u64 = 0x6818;
const VMCS_GUEST_DR7: u64 = 0x681A;
const VMCS_GUEST_RSP: u64 = 0x681C;
const VMCS_GUEST_RIP: u64 = 0x681E;
const VMCS_GUEST_RFLAGS: u64 = 0x6820;
const VMCS_GUEST_PENDING_DBG_EXCEPTIONS: u64 = 0x6822;
const VMCS_GUEST_SYSENTER_ESP: u64 = 0x6824;
const VMCS_GUEST_SYSENTER_EIP: u64 = 0x6826;

const VMCS_GUEST_VMCS_LINK_POINTER: u64 = 0x2800;
const VMCS_GUEST_IA32_PAT: u64 = 0x2804;
const VMCS_GUEST_IA32_EFER: u64 = 0x2806;

const VMCS_HOST_ES_SELECTOR: u64 = 0x0C00;
const VMCS_HOST_CS_SELECTOR: u64 = 0x0C02;
const VMCS_HOST_SS_SELECTOR: u64 = 0x0C04;
const VMCS_HOST_DS_SELECTOR: u64 = 0x0C06;
const VMCS_HOST_FS_SELECTOR: u64 = 0x0C08;
const VMCS_HOST_GS_SELECTOR: u64 = 0x0C0A;
const VMCS_HOST_TR_SELECTOR: u64 = 0x0C0C;
const VMCS_HOST_SYSENTER_CS: u64 = 0x4C00;

const VMCS_HOST_CR0: u64 = 0x6C00;
const VMCS_HOST_CR3: u64 = 0x6C02;
const VMCS_HOST_CR4: u64 = 0x6C04;
const VMCS_HOST_FS_BASE: u64 = 0x6C06;
const VMCS_HOST_GS_BASE: u64 = 0x6C08;
const VMCS_HOST_TR_BASE: u64 = 0x6C0A;
const VMCS_HOST_GDTR_BASE: u64 = 0x6C0C;
const VMCS_HOST_IDTR_BASE: u64 = 0x6C0E;
const VMCS_HOST_SYSENTER_ESP: u64 = 0x6C10;
const VMCS_HOST_SYSENTER_EIP: u64 = 0x6C12;
const VMCS_HOST_RSP: u64 = 0x6C14;
const VMCS_HOST_RIP: u64 = 0x6C16;

const VMCS_HOST_IA32_PAT: u64 = 0x2C00;
const VMCS_HOST_IA32_EFER: u64 = 0x2C02;

const LAPIC_MMIO_BASE: u64 = 0xFEE00000;
const LAPIC_MMIO_SIZE: u64 = 0x1000;
const LAPIC_REG_WORDS: usize = 0x1000 / 4;
const APIC_ID_REG: u32 = 0x020;
const APIC_LVR_REG: u32 = 0x030;
const APIC_TASKPRI_REG: u32 = 0x080;
const APIC_EOI_REG: u32 = 0x0B0;
const APIC_LDR_REG: u32 = 0x0D0;
const APIC_DFR_REG: u32 = 0x0E0;
const APIC_SPIV_REG: u32 = 0x0F0;
const APIC_ESR_REG: u32 = 0x280;
const APIC_LVTCMCI_REG: u32 = 0x2F0;
const APIC_ICR_REG: u32 = 0x300;
const APIC_ICR2_REG: u32 = 0x310;
const APIC_LVTT_REG: u32 = 0x320;
const APIC_LVTTHMR_REG: u32 = 0x330;
const APIC_LVTPC_REG: u32 = 0x340;
const APIC_LVT0_REG: u32 = 0x350;
const APIC_LVT1_REG: u32 = 0x360;
const APIC_LVTERR_REG: u32 = 0x370;
const APIC_TMICT_REG: u32 = 0x380;
const APIC_TMCCT_REG: u32 = 0x390;
const APIC_TDCR_REG: u32 = 0x3E0;
const APIC_SELF_IPI_REG: u32 = 0x3F0;
const APIC_VERSION_VALUE: u32 = 0x0005_0014;
const APIC_LVT_MASKED: u32 = 1 << 16;

const EPT_MEMTYPE_WB: u64 = 6;
const EPT_TABLE_FLAGS: u64 = 0x7;
const EPT_LEAF_FLAGS: u64 = 0x7 | (EPT_MEMTYPE_WB << 3);

const PRIMARY_CTL_HLT_EXITING: u32 = 1 << 7;
const PRIMARY_CTL_IO_EXITING: u32 = 1 << 24;
const PRIMARY_CTL_MSR_BITMAPS: u32 = 1 << 28;
const PRIMARY_CTL_MSR_EXITING: u32 = (1 << 28) | (1 << 29);
const PRIMARY_CTL_SECONDARY: u32 = 1 << 31;

const SECONDARY_CTL_ENABLE_EPT: u32 = 1 << 1;
const EXIT_CTL_HOST_IA32E: u32 = 1 << 9;
const EXIT_CTL_SAVE_PAT: u32 = 1 << 18;
const EXIT_CTL_LOAD_PAT: u32 = 1 << 19;
const EXIT_CTL_SAVE_EFER: u32 = 1 << 20;
const EXIT_CTL_LOAD_EFER: u32 = 1 << 21;
const EXIT_CTL_ACK_INTERRUPT: u32 = 1 << 15;
const PIN_BASED_EXTERNAL_INTERRUPT_EXITING: u32 = 1 << 0;

const ENTRY_CTL_IA32E_GUEST: u32 = 1 << 9;
const ENTRY_CTL_LOAD_PAT: u32 = 1 << 14;
const ENTRY_CTL_LOAD_EFER: u32 = 1 << 15;
const PIN_BASED_PREEMPTION_TIMER: u32 = 1 << 6;
const PRIMARY_CTL_INTERRUPT_WINDOW: u32 = 1 << 2;
const VMCS_VMX_PREEMPTION_TIMER_VALUE: u64 = 0x482E;
const VMCS_VM_ENTRY_INTR_INFO: u64 = 0x4016;
const VM_ENTRY_INTR_TYPE_EXTERNAL: u64 = 0;
const VM_ENTRY_INTR_TYPE_NMI: u64 = 2;
const VMEXIT_REASON_INTERRUPT_WINDOW: u64 = 7;
const VMEXIT_REASON_PREEMPTION_TIMER: u64 = 52;
const VMEXIT_REASON_CR_ACCESS: u64 = 28;
const DEMO_EXIT_CPUID_LEAF: u32 = 0x4341_5445; // 'CATE'
const X86_NMI_VECTOR: u8 = 2;
const APIC_DEST_MODE_LOGICAL: u32 = 1 << 11;
const APIC_DELIVERY_MODE_NMI: u32 = 4;
const APIC_DEST_SHORTHAND_SELF: u32 = 1;
const APIC_DEST_SHORTHAND_ALL_INC_SELF: u32 = 2;
const APIC_DEST_SHORTHAND_ALL_EX_SELF: u32 = 3;
const LINUX_DEBUG_EXCEPTION_BITMAP: u32 =
    (@as(u32, 1) << 0) | // #DE
    (@as(u32, 1) << 6) | // #UD
    (@as(u32, 1) << 8) | // #DF
    (@as(u32, 1) << 13) | // #GP
    0; // #PF

const DEFAULT_CMDLINE = "console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel nokaslr noapictimer iomem=relaxed rdinit=/init";
const GUEST_BOOT_GDT_GPA: u64 = 0x0000_6000;
const GUEST_EBDA_SEGMENT: u16 = 0x9FC0;
const GUEST_BASE_MEMORY_KB: u16 = 639;
const GUEST_IDENTITY_PD_TABLES: usize = 8; // 8 * 1GiB mapped via 2MiB leaves
const GUEST_IDENTITY_MAP_BYTES: u64 = @as(u64, GUEST_IDENTITY_PD_TABLES) * 1024 * 1024 * 1024;
const EPT_PREFAULT_WINDOW_PAGES_DEMO: usize = 512; // 512 * 4KiB = 2MiB
const EPT_PREFAULT_WINDOW_PAGES_LINUX: usize = 512; // map 2 MiB per Linux EPT violation to reduce boot-time VMEXIT churn
const EPT_GPA_LIMIT: u64 = 1 << 48;
const GUEST_POOL_PAGES: usize = 65536;
const PREEMPTION_TIMER_INITIAL: u32 = 0x7FFFFFFF;
const PREEMPTION_TIMER_RELOAD: u32 = 100000; // ~1ms at 100MHz preemption timer freq
const PCI_CONFIG_ADDRESS_PORT: u16 = 0x0CF8;
const PCI_CONFIG_DATA_PORT: u16 = 0x0CFC;
const PCI_CONFIG_ADDRESS_ENABLE: u32 = 0x8000_0000;
const PCI_ROOT_VENDOR_DEVICE: u32 = 0x29C0_8086; // Intel Q35 host bridge
const PCI_ROOT_CLASS_REVISION: u32 = 0x0600_0000;
var pic_master_imr: u8 = 0xFF;
var pic_slave_imr: u8 = 0xFF;
var pic_master_icw_step: u8 = 0;
var pic_slave_icw_step: u8 = 0;
var pic_master_vector_base: u8 = 0x20; // Correct IRQ 0 vector per Linux expectation
var pic_slave_vector_base: u8 = 0x28;

// -- 8254 PIT emulation state --
var pit_channel0_reload: u16 = 0;
var pit_channel0_mode: u8 = 0;
var pit_write_lsb_next: bool = true;
var pit_reload_low: u8 = 0;
var pit_configured: bool = false;

// -- Interrupt injection state --
var timer_irq_pending: bool = false;
var lapic_nmi_pending: bool = false;
var preemption_timer_active: bool = false;
var guest_apic_base: u64 = 0x0000_0000_FEE0_0900;
var lapic_regs: [LAPIC_REG_WORDS]u32 = @splat(0);
// COM1 (ttyS0) IER shadow and THRE IRQ4 pending flag
var serial_dll: u8 = 0x01;
var serial_dlm: u8 = 0x00;
var serial_ier: u8 = 0;
var serial_fcr: u8 = 0;
var serial_lcr: u8 = 0x03;
var serial_mcr: u8 = 0;
var serial_scr: u8 = 0;
var serial_irq4_pending: bool = false;
var timer_inject_count: u64 = 0;
var timer_exit_count: u64 = 0;
var unknown_msr_read_logs: u8 = 0;
var unknown_msr_write_logs: u8 = 0;
var pci_config_address: u32 = 0;
var pci_root_command: u16 = 0;
var vmx_msr_bitmap: [4096]u8 align(4096) = @splat(0);

// -- Port 0x61 (System Control Port B) emulation --
var port_61_value: u8 = 0;
var port_61_reads: u32 = 0;

fn ioMask(size: u8) u64 {
    return switch (size) {
        1 => 0xFF,
        2 => 0xFFFF,
        4 => 0xFFFF_FFFF,
        else => 0xFF,
    };
}

fn ioAccessSize(qualification: u64) u8 {
    return switch (@as(u3, @truncate(qualification & 0x7))) {
        0 => 1,
        1 => 2,
        3 => 4,
        else => 1,
    };
}

fn readGuestIoValue(regs: *const GuestRegs, size: u8) u32 {
    return @as(u32, @truncate(regs.rax & ioMask(size)));
}

fn writeGuestIoValue(regs: *GuestRegs, size: u8, value: u32) void {
    switch (size) {
        1 => regs.rax = (regs.rax & ~@as(u64, 0xFF)) | (value & 0xFF),
        2 => regs.rax = (regs.rax & ~@as(u64, 0xFFFF)) | (value & 0xFFFF),
        4 => regs.rax = value,
        else => regs.rax = (regs.rax & ~@as(u64, 0xFF)) | (value & 0xFF),
    }
}

fn setMsrBitmapBit(msr: u32, intercept_read: bool, intercept_write: bool) void {
    const is_high = msr >= 0xC000_0000 and msr <= 0xC000_1FFF;
    const is_low = msr <= 0x1FFF;
    if (!is_low and !is_high) return;

    const bit_index: usize = if (is_low) msr else msr - 0xC000_0000;
    const byte_index = bit_index >> 3;
    const bit = @as(u3, @truncate(bit_index & 7));
    const read_base: usize = if (is_low) 0 else 1024;
    const write_base: usize = if (is_low) 2048 else 3072;

    if (intercept_read) vmx_msr_bitmap[read_base + byte_index] |= @as(u8, 1) << bit;
    if (intercept_write) vmx_msr_bitmap[write_base + byte_index] |= @as(u8, 1) << bit;
}

fn configureMsrBitmap() VmxError!void {
    @memset(vmx_msr_bitmap[0..], 0);

    setMsrBitmapBit(IA32_BIOS_SIGN_ID, true, false);
    setMsrBitmapBit(IA32_MTRRCAP, true, false);
    setMsrBitmapBit(IA32_ARCH_CAPABILITIES, true, false);
    setMsrBitmapBit(IA32_MISC_ENABLE, true, false);

    setMsrBitmapBit(MSR_CORE_PERF_FIXED_CTR_CTRL, true, true);
    setMsrBitmapBit(MSR_CORE_PERF_GLOBAL_STATUS, true, false);
    setMsrBitmapBit(MSR_CORE_PERF_GLOBAL_CTRL, true, true);
    setMsrBitmapBit(MSR_CORE_PERF_GLOBAL_OVF_CTRL, true, true);
    setMsrBitmapBit(MSR_SNB_UNC_PERF_GLOBAL_CTRL, true, true);
    setMsrBitmapBit(MSR_SNB_UNC_FIXED_CTR_CTRL, true, true);
    setMsrBitmapBit(MSR_SNB_UNC_FIXED_CTR, true, false);

    const bitmap_hpa = translateHostVirtToPhys(@intFromPtr(&vmx_msr_bitmap)) orelse return error.Unsupported;
    try vmwriteChecked(VMCS_CTRL_MSR_BITMAPS, bitmap_hpa);
}

fn pciConfigReadDword(maybe_inst: ?*microvm_registry.Instance, addr: u32) u32 {
    if (maybe_inst) |inst| {
        return pc_platform.pciReadDword(&inst.devices.pci.dev_commands, addr);
    }
    var fallback_cmds: [pc_platform.PCI_MAX_BUS0_DEVS]u16 = .{ pci_root_command, 0, 0, 0 };
    return pc_platform.pciReadDword(&fallback_cmds, addr);
}

fn pciConfigWriteDword(maybe_inst: ?*microvm_registry.Instance, addr: u32, value: u32, mask: u32) void {
    if (maybe_inst) |inst| {
        pc_platform.pciWriteDword(&inst.devices.pci.dev_commands, addr, value, mask);
        inst.devices.pci.root_command = inst.devices.pci.dev_commands[0];
        return;
    }
    var fallback_cmds: [pc_platform.PCI_MAX_BUS0_DEVS]u16 = .{ pci_root_command, 0, 0, 0 };
    pc_platform.pciWriteDword(&fallback_cmds, addr, value, mask);
    pci_root_command = fallback_cmds[0];
}

fn handlePciConfigIo(maybe_inst: ?*microvm_registry.Instance, port: u16, is_in: bool, size: u8, regs: *GuestRegs) bool {
    const cfg_addr_ptr: *u32 = if (maybe_inst) |inst| &inst.devices.pci.config_address else &pci_config_address;
    if (port == PCI_CONFIG_ADDRESS_PORT and size == 4) {
        if (is_in) {
            writeGuestIoValue(regs, 4, cfg_addr_ptr.*);
        } else {
            cfg_addr_ptr.* = readGuestIoValue(regs, 4) & 0x8000_FFFC;
        }
        return true;
    }

    if (port >= PCI_CONFIG_DATA_PORT and port <= PCI_CONFIG_DATA_PORT + 3) {
        const data_offset = @as(u8, @truncate(port - PCI_CONFIG_DATA_PORT));
        const shift = @as(u5, @truncate(data_offset * 8));
        const full = pciConfigReadDword(maybe_inst, cfg_addr_ptr.*);
        const value = switch (size) {
            1 => (full >> shift) & 0xFF,
            2 => (full >> shift) & 0xFFFF,
            4 => full,
            else => full & 0xFF,
        };

        if (is_in) {
            writeGuestIoValue(regs, size, value);
        } else {
            const mask = @as(u32, @truncate(ioMask(size))) << shift;
            const shifted = readGuestIoValue(regs, size) << shift;
            pciConfigWriteDword(maybe_inst, cfg_addr_ptr.*, shifted, mask);
        }
        return true;
    }

    return false;
}

fn lapicRegIndex(offset: u64) ?usize {
    if (offset >= LAPIC_MMIO_SIZE or (offset & 0xF) != 0) return null;
    return @as(usize, @intCast(offset >> 2));
}

fn lapicWriteRaw( offset: u32, value: u32) void {
    const idx = lapicRegIndex(@as(u64, offset)) orelse return;
    if (getCurrentInstanceId()) |vmid| {
        if (microvm_registry.findMutable(vmid)) |inst| {
            inst.devices.lapic.regs[idx] = value;
        }
    }
    lapic_regs[idx] = value;
}

fn resetLapicState() void {
    @memset(lapic_regs[0..], 0);
    lapicWriteRaw(APIC_ID_REG, 0);
    lapicWriteRaw(APIC_LVR_REG, APIC_VERSION_VALUE);
    lapicWriteRaw(APIC_TASKPRI_REG, 0);
    lapicWriteRaw(APIC_DFR_REG, 0xFFFF_FFFF);
    lapicWriteRaw(APIC_LDR_REG, 0);
    lapicWriteRaw(APIC_SPIV_REG, 0xFF);
    lapicWriteRaw(APIC_LVTCMCI_REG, APIC_LVT_MASKED);
    lapicWriteRaw(APIC_LVTT_REG, APIC_LVT_MASKED);
    lapicWriteRaw(APIC_LVTTHMR_REG, APIC_LVT_MASKED);
    lapicWriteRaw(APIC_LVTPC_REG, APIC_LVT_MASKED);
    lapicWriteRaw(APIC_LVT0_REG, APIC_LVT_MASKED);
    lapicWriteRaw(APIC_LVT1_REG, APIC_LVT_MASKED);
    lapicWriteRaw(APIC_LVTERR_REG, APIC_LVT_MASKED);
    lapicWriteRaw(APIC_ESR_REG, 0);
    lapicWriteRaw(APIC_ICR_REG, 0);
    lapicWriteRaw(APIC_ICR2_REG, 0);
    lapicWriteRaw(APIC_TMICT_REG, 0);
    lapicWriteRaw(APIC_TMCCT_REG, 0);
    lapicWriteRaw(APIC_TDCR_REG, 0);
}

fn lapicRead(offset: u64) u32 {
    const idx = lapicRegIndex(offset) orelse return 0;
    if (getCurrentInstanceId()) |vmid| {
        if (microvm_registry.findMutable(vmid)) |inst| {
            if (offset == APIC_LVR_REG and inst.devices.lapic.regs[idx] == 0) {
                return APIC_VERSION_VALUE;
            }
            return inst.devices.lapic.regs[idx];
        }
    }
    return lapic_regs[idx];
}

fn lapicLocalPhysicalId() u8 {
    return @as(u8, @truncate(lapicRead(APIC_ID_REG) >> 24));
}

fn lapicLocalLogicalId() u8 {
    return @as(u8, @truncate(lapicRead(APIC_LDR_REG) >> 24));
}

fn lapicIcrTargetsLocal(icr_low: u32) bool {
    const shorthand = @as(u2, @truncate((icr_low >> 18) & 0x3));
    switch (shorthand) {
        APIC_DEST_SHORTHAND_SELF, APIC_DEST_SHORTHAND_ALL_INC_SELF => return true,
        APIC_DEST_SHORTHAND_ALL_EX_SELF => return false,
        else => {},
    }

    const destination = @as(u8, @truncate(lapicRead(APIC_ICR2_REG) >> 24));
    if ((icr_low & APIC_DEST_MODE_LOGICAL) != 0) {
        const local_logical = lapicLocalLogicalId();
        if (local_logical != 0) {
            return (destination & local_logical) != 0;
        }
        return destination == 0x01;
    }

    return destination == lapicLocalPhysicalId();
}

fn queueLapicIcrDelivery(icr_low: u32) void {
    const delivery_mode = (icr_low >> 8) & 0x7;
    if (delivery_mode == APIC_DELIVERY_MODE_NMI and lapicIcrTargetsLocal(icr_low)) {
        lapic_nmi_pending = true;
    }
}

fn lapicWrite(offset: u64, value: u32) void {
    const reg = @as(u32, @intCast(offset));
    switch (reg) {
        APIC_ID_REG => lapicWriteRaw(APIC_ID_REG, value & 0xFF00_0000),
        APIC_LVR_REG => {},
        APIC_TASKPRI_REG => lapicWriteRaw(APIC_TASKPRI_REG, value & 0xFF),
        APIC_EOI_REG => {},
        APIC_LDR_REG => lapicWriteRaw(APIC_LDR_REG, value & 0xFF00_0000),
        APIC_DFR_REG => lapicWriteRaw(APIC_DFR_REG, value | 0x0FFF_FFFF),
        APIC_SPIV_REG => lapicWriteRaw(APIC_SPIV_REG, value & 0x3FF),
        APIC_ESR_REG => lapicWriteRaw(APIC_ESR_REG, 0),
        APIC_ICR2_REG => lapicWriteRaw(APIC_ICR2_REG, value & 0xFF00_0000),
        APIC_ICR_REG => {
            lapicWriteRaw(APIC_ICR_REG, value);
            queueLapicIcrDelivery(value);
        },
        APIC_LVTCMCI_REG, APIC_LVTT_REG, APIC_LVTTHMR_REG, APIC_LVTPC_REG, APIC_LVT0_REG, APIC_LVT1_REG, APIC_LVTERR_REG => lapicWriteRaw(reg, value),
        APIC_TMICT_REG => {
            lapicWriteRaw(APIC_TMICT_REG, value);
            lapicWriteRaw(APIC_TMCCT_REG, value);
        },
        APIC_TDCR_REG => lapicWriteRaw(APIC_TDCR_REG, value & 0xB),
        APIC_SELF_IPI_REG => {},
        else => {
            if (lapicRegIndex(offset) != null) {
                lapicWriteRaw(reg, value);
            }
        },
    }
}

fn resetGuestDeviceState() void {
    pic_master_imr = 0xFF;
    pic_slave_imr = 0xFF;
    pic_master_icw_step = 0;
    pic_slave_icw_step = 0;
    pic_master_vector_base = 0x20;
    pic_slave_vector_base = 0x28;

    pit_channel0_reload = 0;
    pit_channel0_mode = 0;
    pit_write_lsb_next = true;
    pit_reload_low = 0;
    pit_configured = false;

    timer_irq_pending = false;
    lapic_nmi_pending = false;
    preemption_timer_active = false;
    guest_apic_base = 0x0000_0000_FEE0_0900;
    resetLapicState();

    serial_dll = 0x01;
    serial_dlm = 0x00;
    serial_ier = 0;
    serial_fcr = 0;
    serial_lcr = 0x03;
    serial_mcr = 0;
    serial_scr = 0;
    serial_irq4_pending = false;

    timer_inject_count = 0;
    timer_exit_count = 0;
    unknown_msr_read_logs = 0;
    unknown_msr_write_logs = 0;

    pci_config_address = 0;
    pci_root_command = 0;

    port_61_value = 0;
    port_61_reads = 0;

    vmexit_count = 0;
    per_cpu_vmx_start_tsc = @splat(0);
    vmx_start_tsc = 0;
    ept_violation_count = 0;
    guest_linux_entry_active = false;
    vm_serial_line_len = @splat(0);
}

fn translateHostVirtToPhys(virt: u64) ?u64 {
    return host_paging.translate(vmx_hhdm_offset, virt);
}

fn guestRamBytes(inst: *const microvm_registry.Instance) u64 {
    return if (inst.mem_pages > 0)
        @as(u64, inst.mem_pages) * pmm.PAGE_SIZE
    else
        linux_boot.default_guest_ram_bytes;
}

fn isGuestMmioWindow(gpa: u64) bool {
    return (gpa >= 0xFD00_0000 and gpa < 0xFF00_0000) or
        (gpa >= uefi_firmware.UEFI_ROM_GPA and gpa < uefi_firmware.UEFI_ROM_GPA + uefi_firmware.UEFI_ROM_SIZE);
}

fn guestPoolCapacityPages(inst: *const microvm_registry.Instance) u64 {
    const guest_pages = guestRamBytes(inst) / @as(u64, pmm.PAGE_SIZE);
    const leaf_tables = (guest_pages + 511) / 512;
    const directory_tables = (guest_pages + 262_143) / 262_144;
    return guest_pages + leaf_tables + directory_tables + 16;
}

fn chooseInitrdGpa(guest_ram_bytes: u64, kernel_gpa: u64, kernel_size: usize, initrd_size: usize) VmxError!u64 {
    const kernel_bytes: u64 = @intCast(kernel_size);
    const initrd_bytes: u64 = @intCast(initrd_size);
    if (initrd_bytes > guest_ram_bytes) return error.GuestTooLarge;

    const kernel_end = std.math.add(u64, kernel_gpa, kernel_bytes) catch return error.GuestTooLarge;
    const initrd_gpa = (guest_ram_bytes - initrd_bytes) & ~(@as(u64, pmm.PAGE_SIZE) - 1);
    if (initrd_gpa < kernel_end or initrd_gpa + initrd_bytes > guest_ram_bytes) {
        return error.GuestTooLarge;
    }
    return initrd_gpa;
}

fn allocFromPoolForInstance(inst: *microvm_registry.Instance) VmxError!u64 {
    if (inst.pool_used >= guestPoolCapacityPages(inst)) {
        serialWrite("VMX: instance guest pool exhausted used=0x");
        printHex(inst.pool_used);
        serialWrite("\n");
        return error.OutOfMemory;
    }

    const phys = pmm.allocPage() orelse return error.OutOfMemory;
    inst.pool_used += 1;
    clearPage(phys);
    return phys;
}

fn allocFromPool() VmxError!u64 {
    const instance_id = getCurrentInstanceId() orelse return error.VmxonFailed;
    const inst = microvm_registry.findMutable(instance_id) orelse return error.VmxonFailed;
    return allocFromPoolForInstance(inst);
}
const VMX_MAX_LOW_PHYS: u64 = 0x4000_0000; // 1 GiB
const VMX_USE_EPT: bool = true;

const VmxError = error{
    Unsupported,
    VmxUnsupported,
    FeatureControlDenied,
    OutOfMemory,
    VmxonFailed,
    VmclearFailed,
    VmptrldFailed,
    VmwriteFailed,
    VmxoffFailed,
    GuestImageInvalid,
    GuestUnsupported,
    GuestTooLarge,
    GuestMapOverflow,
    VmlaunchFailed,
    VmresumeFailed,
};

const GuestRegs = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rbp: u64,
    rsi: u64,
    rdi: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
};

const GuestLaunchState = struct {
    layout: linux_boot.LaunchLayout = .{
        .boot_params_gpa = 0,
        .cmdline_gpa = 0,
        .kernel_load_gpa = 0,
        .guest_stack_top_gpa = 0,
        .guest_pml4_gpa = 0,
        .guest_pdpt_gpa = 0,
        .guest_pd_gpa = 0,
    },
    guest_rip: u64 = 0,
    guest_rsp: u64 = 0,
    guest_cr3: u64 = 0,
    boot_params_gpa: u64 = 0,
    guest_rsi: u64 = 0,
};

// Per-CPU VMXON physical regions and host exit stack frames
pub var per_cpu_vmxon: [smp.MAX_CPUS]?u64 = @splat(null);
pub var per_cpu_host_stack: [smp.MAX_CPUS]?u64 = @splat(null);
pub var current_instance_per_cpu: [smp.MAX_CPUS]?u32 = @splat(null);

// Backwards-compatible aliases
pub var vmxon_region_phys: ?u64 = null;
pub var microvm_table: ?*void = null;
pub var vmx_host_stack_phys: ?u64 = null;
pub var current_instance_id: ?u32 = null;

var vmx_hhdm_offset: u64 = 0;
var vmx_host_cr3: u64 = 0;
const HOST_STACK_PAGES: u64 = 4;
var vmexit_count: usize = 0;
pub var per_cpu_vmx_start_tsc: [smp.MAX_CPUS]u64 = @splat(0);
pub var vmx_start_tsc: u64 = 0;
var ept_violation_count: u64 = 0;
var guest_linux_entry_active: bool = false;
const VM_SERIAL_LINE_CAPACITY: usize = 512;
var vm_serial_line: [microvm_registry.TARGET_INSTANCES + 1][VM_SERIAL_LINE_CAPACITY]u8 = undefined;
var vm_serial_line_len: [microvm_registry.TARGET_INSTANCES + 1]usize = @splat(0);
var vmx_host_gdtr: cpu.DescriptorTablePointer = .{ .limit = 0, .base = 0 };
var vmx_host_idtr: cpu.DescriptorTablePointer = .{ .limit = 0, .base = 0 };
var staged_parsed_image: linux_boot.ParsedBzImage = .{
    .image = &[_]u8{},
    .setup_sects = 0,
    .setup_bytes = 0,
    .protected_mode_offset = 0,
    .protected_mode_size = 0,
    .protocol_version = 0,
    .loadflags = 0,
    .xloadflags = 0,
    .cmdline_size = 0,
    .kernel_alignment = 0,
    .relocatable_kernel = false,
    .code32_start = 0,
    .init_size = 0,
    .preferred_address = 0,
    .handover_offset = 0,
};
pub var per_instance_launch_state: [microvm_registry.TARGET_INSTANCES + 1]GuestLaunchState = @splat(.{});
var staged_launch_state: GuestLaunchState = .{};

pub fn getLaunchRsiForInstance(instance: *const microvm_registry.Instance) u64 {
    if (instance.launch_rsi != 0) return instance.launch_rsi;
    if (instance.instance_id < per_instance_launch_state.len and per_instance_launch_state[instance.instance_id].guest_rsi != 0) {
        return per_instance_launch_state[instance.instance_id].guest_rsi;
    }
    return staged_launch_state.guest_rsi;
}

inline fn preferLinuxEntry() bool {
    return build_options.vmm_launch_linux;
}

inline fn updateMax(max_value: *u64, candidate_end: u64) void {
    if (candidate_end > max_value.*) {
        max_value.* = candidate_end;
    }
}

fn checkedEnd(base: u64, len: u64) VmxError!u64 {
    if (len == 0) return base;
    return std.math.add(u64, base, len - 1) catch return error.GuestTooLarge;
}

fn validateIdentityMapWindow(layout: linux_boot.LaunchLayout, kernel_span: u64, entry_gpa: u64, cmdline_len: usize) VmxError!void {
    var required_max: u64 = 0;

    updateMax(&required_max, try checkedEnd(layout.boot_params_gpa, linux_boot.zero_page_size));
    updateMax(&required_max, try checkedEnd(layout.cmdline_gpa, @as(u64, @intCast(cmdline_len))));
    updateMax(&required_max, try checkedEnd(layout.kernel_load_gpa, kernel_span));
    updateMax(&required_max, try checkedEnd(layout.guest_stack_top_gpa - pmm.PAGE_SIZE, pmm.PAGE_SIZE));
    updateMax(&required_max, try checkedEnd(layout.guest_pml4_gpa, pmm.PAGE_SIZE));
    updateMax(&required_max, try checkedEnd(layout.guest_pdpt_gpa, pmm.PAGE_SIZE));
    updateMax(&required_max, try checkedEnd(layout.guest_pd_gpa, @as(u64, GUEST_IDENTITY_PD_TABLES) * pmm.PAGE_SIZE));
    updateMax(&required_max, entry_gpa);

    if (required_max >= GUEST_IDENTITY_MAP_BYTES) {
        serialWrite("VMX: stage map window too small required=0x");
        printHex(required_max);
        serialWrite(" map=0x");
        printHex(GUEST_IDENTITY_MAP_BYTES);
        serialWrite("\n");
        return error.GuestTooLarge;
    }
}

fn serialWrite(s: []const u8) void {
    smp.serialAcquire();
    defer smp.serialRelease();
    for (s) |c| {
        cpu.outb(0x3F8, c);
    }
}

fn writeCom1CharWithPrefix(vmid: u32, ch: u8) void {
    smp.serialAcquire();
    defer smp.serialRelease();
    const idx: usize = if (vmid < vm_serial_line.len) @intCast(vmid) else 0;
    if (ch != '\n' and vm_serial_line_len[idx] < VM_SERIAL_LINE_CAPACITY) {
        vm_serial_line[idx][vm_serial_line_len[idx]] = ch;
        vm_serial_line_len[idx] += 1;
        return;
    }

    const buffered = vm_serial_line_len[idx];
    if (buffered > 0 or ch == '\n') {
        cpu.outb(0x3F8, '[');
        cpu.outb(0x3F8, 'v');
        cpu.outb(0x3F8, 'm');
        printDec(vmid);
        cpu.outb(0x3F8, ']');
        cpu.outb(0x3F8, ' ');
        for (vm_serial_line[idx][0..buffered]) |buffered_ch| {
            cpu.outb(0x3F8, buffered_ch);
        }
        if (ch == '\n') {
            cpu.outb(0x3F8, '\n');
        }
        vm_serial_line_len[idx] = 0;
    }

    if (ch != '\n') {
        vm_serial_line[idx][0] = ch;
        vm_serial_line_len[idx] = 1;
    }
}

fn printHex(n: u64) void {
    smp.serialAcquire();
    defer smp.serialRelease();
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        cpu.outb(0x3F8, hex[nibble]);
        if (shift >= 4) shift -= 4;
    }
}

fn printDec(val: u64) void {
    smp.serialAcquire();
    defer smp.serialRelease();
    if (val == 0) {
        cpu.outb(0x3F8, '0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = val;
    while (v > 0) : (v /= 10) {
        buf[len] = @as(u8, @intCast(v % 10)) + '0';
        len += 1;
    }
    var j: usize = len;
    while (j > 0) {
        j -= 1;
        cpu.outb(0x3F8, buf[j]);
    }
}

fn vmxInstructionSucceeded(flag: u8) bool {
    return flag == 0;
}

fn vmxon(region_phys: u64) bool {
    var operand: u64 = region_phys;
    var failed: u8 = 0;
    asm volatile (
        \\vmxon (%[ptr])
        \\setna %[failed]
        : [failed] "=r" (failed),
        : [ptr] "r" (&operand),
        : .{ .memory = true, .cc = true });
    return vmxInstructionSucceeded(failed);
}

fn vmclear(region_phys: u64) bool {
    var operand: u64 = region_phys;
    var failed: u8 = 0;
    asm volatile (
        \\vmclear (%[ptr])
        \\setna %[failed]
        : [failed] "=r" (failed),
        : [ptr] "r" (&operand),
        : .{ .memory = true, .cc = true });
    return vmxInstructionSucceeded(failed);
}

fn vmptrld(region_phys: u64) bool {
    var operand: u64 = region_phys;
    var failed: u8 = 0;
    asm volatile (
        \\vmptrld (%[ptr])
        \\setna %[failed]
        : [failed] "=r" (failed),
        : [ptr] "r" (&operand),
        : .{ .memory = true, .cc = true });
    return vmxInstructionSucceeded(failed);
}

const InveptDescriptor = extern struct {
    eptp: u64,
    reserved: u64 = 0,
};

fn invept(invept_type: u64, eptp: u64) bool {
    var desc = InveptDescriptor{ .eptp = eptp };
    var failed: u8 = 0;
    asm volatile (
        \\invept (%[desc]), %[kind]
        \\setna %[failed]
        : [failed] "=r" (failed),
        : [desc] "r" (&desc),
          [kind] "r" (invept_type),
        : .{ .memory = true, .cc = true });
    return vmxInstructionSucceeded(failed);
}

fn invalidateEptRoot(root_phys: u64) bool {
    if (@import("builtin").is_test) return true;
    const core_id = smp.getCurrentCpuId();
    if (core_id < smp.MAX_CPUS and per_cpu_vmxon[core_id] == null) return true;

    const eptp = (root_phys & 0x000F_FFFF_FFFF_F000) | EPT_MEMTYPE_WB | ((@as(u64, 4) - 1) << 3);
    const cap = cpu.rdmsr(IA32_VMX_EPT_VPID_CAP);
    const supports_single = (cap & (@as(u64, 1) << 25)) != 0;
    const supports_all = (cap & (@as(u64, 1) << 26)) != 0;
    if (supports_single and invept(1, eptp)) return true;
    if (supports_all and invept(2, 0)) return true;
    return !supports_single and !supports_all;
}

fn vmxoff() bool {
    var failed: u8 = 0;
    asm volatile (
        \\vmxoff
        \\setna %[failed]
        : [failed] "=r" (failed),
        :
        : .{ .memory = true, .cc = true });
    return vmxInstructionSucceeded(failed);
}

fn vmwrite(field: u64, value: u64) bool {
    var failed: u8 = 0;
    asm volatile (
        \\vmwrite %[value], %[field]
        \\setna %[failed]
        : [failed] "=r" (failed),
        : [value] "r" (value),
          [field] "r" (field),
        : .{ .memory = true, .cc = true });
    return vmxInstructionSucceeded(failed);
}

fn vmread(field: u64) ?u64 {
    var value: u64 = 0;
    var failed: u8 = 0;
    asm volatile (
        \\vmread %[field], %[value]
        \\setna %[failed]
        : [value] "=r" (value),
          [failed] "=r" (failed),
        : [field] "r" (field),
        : .{ .memory = true, .cc = true });
    if (!vmxInstructionSucceeded(failed)) return null;
    return value;
}

fn vmlaunchWithGuestRsi(guest_rsi: u64) bool {
    var failed: u8 = 0;
    asm volatile (
        \\xor %%rax, %%rax
        \\xor %%rbx, %%rbx
        \\xor %%rcx, %%rcx
        \\xor %%rdx, %%rdx
        \\xor %%rdi, %%rdi
        \\xor %%rbp, %%rbp
        \\xor %%r8, %%r8
        \\xor %%r9, %%r9
        \\xor %%r10, %%r10
        \\xor %%r11, %%r11
        \\xor %%r12, %%r12
        \\xor %%r13, %%r13
        \\xor %%r14, %%r14
        \\xor %%r15, %%r15
        \\mov %[guest_rsi], %%rsi
        \\vmlaunch
        \\setna %[failed]
        : [failed] "=r" (failed),
        : [guest_rsi] "r" (guest_rsi),
        : .{ .memory = true, .cc = true });
    return vmxInstructionSucceeded(failed);
}

fn vmresumeWithGuestRsi(guest_rsi: u64) bool {
    var failed: u8 = 0;
    asm volatile (
        \\xor %%rax, %%rax
        \\xor %%rbx, %%rbx
        \\xor %%rcx, %%rcx
        \\xor %%rdx, %%rdx
        \\xor %%rdi, %%rdi
        \\xor %%rbp, %%rbp
        \\xor %%r8, %%r8
        \\xor %%r9, %%r9
        \\xor %%r10, %%r10
        \\xor %%r11, %%r11
        \\xor %%r12, %%r12
        \\xor %%r13, %%r13
        \\xor %%r14, %%r14
        \\xor %%r15, %%r15
        \\mov %[guest_rsi], %%rsi
        \\vmresume
        \\setna %[failed]
        : [failed] "=r" (failed),
        : [guest_rsi] "r" (guest_rsi),
        : .{ .memory = true, .cc = true });
    return vmxInstructionSucceeded(failed);
}

fn readRsp() u64 {
    return asm volatile ("mov %%rsp, %[rsp]"
        : [rsp] "=r" (-> u64),
    );
}

fn vmexitReasonName(reason: u64) []const u8 {
    return switch (reason) {
        VMEXIT_REASON_EXCEPTION_NMI => "exception-or-nmi",
        VMEXIT_REASON_EXTERNAL_INTERRUPT => "external-interrupt",
        VMEXIT_REASON_TRIPLE_FAULT => "triple-fault",
        VMEXIT_REASON_INIT_SIGNAL => "init-signal",
        VMEXIT_REASON_CPUID => "cpuid",
        VMEXIT_REASON_HLT => "hlt",
        VMEXIT_REASON_INVD => "invd-wbinvd",
        VMEXIT_REASON_INVLPG => "invlpg",
        VMEXIT_REASON_RDPMC => "rdpmc",
        VMEXIT_REASON_IO_INSTRUCTION => "io-instruction",
        VMEXIT_REASON_MSR_READ => "msr-read",
        VMEXIT_REASON_MSR_WRITE => "msr-write",
        VMEXIT_REASON_APIC_ACCESS => "apic-access",
        VMEXIT_REASON_EPT_VIOLATION => "ept-violation",
        VMEXIT_REASON_EPT_MISCONFIG => "ept-misconfig",
        VMEXIT_REASON_WBINVD => "wbinvd",
        VMEXIT_REASON_XSETBV => "xsetbv",
        VMEXIT_REASON_PREEMPTION_TIMER => "preemption-timer",
        VMEXIT_REASON_INTERRUPT_WINDOW => "interrupt-window",
        VMEXIT_REASON_CR_ACCESS => "cr-access",
        VMEXIT_REASON_VMCALL => "vmcall",
        VMEXIT_REASON_VMCLEAR => "vmclear",
        VMEXIT_REASON_VMLAUNCH => "vmlaunch",
        VMEXIT_REASON_VMPTRLD => "vmptrld",
        VMEXIT_REASON_VMPTRST => "vmptrst",
        VMEXIT_REASON_VMREAD => "vmread",
        VMEXIT_REASON_VMRESUME => "vmresume",
        VMEXIT_REASON_VMWRITE => "vmwrite",
        VMEXIT_REASON_VMXOFF => "vmxoff",
        VMEXIT_REASON_VMXON => "vmxon",
        else => "unknown",
    };
}

fn adjustVmxControls(ctl_msr: u32, requested: u32) u32 {
    const raw = cpu.rdmsr(ctl_msr);
    const fixed0 = @as(u32, @truncate(raw));
    const fixed1 = @as(u32, @truncate(raw >> 32));
    return (requested | fixed0) & fixed1;
}

fn usesTrueControlMsrs(vmx_basic: u64) bool {
    return ((vmx_basic >> 55) & 1) != 0;
}

fn vmwriteChecked(field: u64, value: u64) VmxError!void {
    if (vmwrite(field, value)) return;

    serialWrite("VMX: vmwrite failed field=");
    printHex(field);
    if (vmread(VMCS_VM_INSTRUCTION_ERROR)) |instr_err| {
        serialWrite(" err=");
        printHex(instr_err);
    }
    serialWrite("\n");
    return error.VmwriteFailed;
}

fn sanitizeCrValue(current: u64, fixed0_msr: u32, fixed1_msr: u32) u64 {
    const fixed0 = cpu.rdmsr(fixed0_msr);
    const fixed1 = cpu.rdmsr(fixed1_msr);
    return (current | fixed0) & fixed1;
}

fn ensureFeatureControl() VmxError!void {
    var fc = cpu.rdmsr(IA32_FEATURE_CONTROL);
    if ((fc & FEATURE_CONTROL_LOCK) == 0) {
        fc |= FEATURE_CONTROL_LOCK | FEATURE_CONTROL_VMXON_OUTSIDE_SMX;
        cpu.wrmsr(IA32_FEATURE_CONTROL, fc);
    }

    fc = cpu.rdmsr(IA32_FEATURE_CONTROL);
    if ((fc & FEATURE_CONTROL_VMXON_OUTSIDE_SMX) == 0) {
        return error.FeatureControlDenied;
    }
}

fn ensureRegion(region_phys_ptr: *?u64, hhdm_offset: u64, revision_id: u32) VmxError!u64 {
    if (region_phys_ptr.* == null) {
        region_phys_ptr.* = pmm.allocPage() orelse return error.OutOfMemory;
    }

    const region_phys = region_phys_ptr.*.?;
    const region = @as([*]u8, @ptrFromInt(region_phys + hhdm_offset));
    for (0..pmm.PAGE_SIZE) |i| {
        region[i] = 0;
    }
    @as(*u32, @ptrFromInt(region_phys + hhdm_offset)).* = revision_id;
    return region_phys;
}

fn clearPage(phys: u64) void {
    const base: [*]u8 = @ptrFromInt(phys + vmx_hhdm_offset);
    for (0..pmm.PAGE_SIZE) |i| {
        base[i] = 0;
    }
}

pub fn setHhdmOffset(offset: u64) void {
    vmx_hhdm_offset = offset;
}

pub fn getCurrentInstanceId() ?u32 {
    const cpu_id = smp.getCurrentCpuId();
    if (cpu_id < smp.MAX_CPUS) {
        return current_instance_per_cpu[cpu_id] orelse current_instance_id;
    }
    return current_instance_id;
}

pub fn setCurrentInstanceId(vmid: ?u32) void {
    const cpu_id = smp.getCurrentCpuId();
    if (cpu_id < smp.MAX_CPUS) {
        current_instance_per_cpu[cpu_id] = vmid;
    }
    current_instance_id = vmid;
}

pub fn ensureHostStackForCpu(cpu_id: usize) VmxError!u64 {
    const id = if (cpu_id < smp.MAX_CPUS) cpu_id else 0;
    if (per_cpu_host_stack[id] == null) {
        per_cpu_host_stack[id] = pmm.allocContiguousAligned(HOST_STACK_PAGES, 1) orelse return error.OutOfMemory;
        if (id == 0) {
            vmx_host_stack_phys = per_cpu_host_stack[0];
        }
    }
    return per_cpu_host_stack[id].?;
}

fn allocZeroedPage() VmxError!u64 {
    return try allocFromPool();
}

fn allocZeroedPageForInstance(inst: *microvm_registry.Instance) VmxError!u64 {
    return try allocFromPoolForInstance(inst);
}

fn eptTablePtr(table_phys: u64) [*]u64 {
    return @ptrFromInt((table_phys & 0x000F_FFFF_FFFF_F000) + vmx_hhdm_offset);
}

const VIRTIO_DEV_MMIO_BASE: u64 = 0xFE000000;
const VIRTIO_DEV_MMIO_SIZE: u64 = 0x1000;
const VIRTIO_BLK_MMIO_BASE: u64 = 0xFE001000;
const VIRTIO_BLK_MMIO_SIZE: u64 = 0x1000;

fn eptEnsureTable(entry: *u64) VmxError![*]u64 {
    if ((entry.* & 1) == 0) {
        const child = try allocZeroedPage();
        entry.* = (child & 0x000F_FFFF_FFFF_F000) | EPT_TABLE_FLAGS;
    }
    return eptTablePtr(entry.*);
}

fn eptEnsureTableForInstance(entry: *u64, inst: *microvm_registry.Instance) VmxError![*]u64 {
    if ((entry.* & 1) == 0) {
        const child = try allocZeroedPageForInstance(inst);
        entry.* = (child & 0x000F_FFFF_FFFF_F000) | EPT_TABLE_FLAGS;
    }
    return eptTablePtr(entry.*);
}

fn eptMapPageForInstance(inst: *microvm_registry.Instance, gpa: u64, hpa: u64, flags: u64) VmxError!void {
    if (!isSupportedEptGpa(gpa)) return error.GuestTooLarge;
    if (comptime !VMX_USE_EPT) return;

    if (inst.ept_pml4_phys == null) {
        inst.ept_pml4_phys = pmm.allocPage() orelse return error.OutOfMemory;
        clearPage(inst.ept_pml4_phys.?);
    }

    const root = inst.ept_pml4_phys.?;
    const pml4 = eptTablePtr(root);
    const pml4e = &pml4[@as(usize, @intCast((gpa >> 39) & 0x1FF))];
    const pdpt = try eptEnsureTableForInstance(pml4e, inst);

    const pdpte = &pdpt[@as(usize, @intCast((gpa >> 30) & 0x1FF))];
    const pd = try eptEnsureTableForInstance(pdpte, inst);

    const pde = &pd[@as(usize, @intCast((gpa >> 21) & 0x1FF))];
    const pt = try eptEnsureTableForInstance(pde, inst);

    const pte = &pt[@as(usize, @intCast((gpa >> 12) & 0x1FF))];
    pte.* = (hpa & 0x000F_FFFF_FFFF_F000) | flags;
}

fn eptMapPageEx(gpa: u64, hpa: u64, flags: u64) VmxError!void {
    if (comptime !VMX_USE_EPT) return;
    const instance_id = getCurrentInstanceId() orelse return error.Unsupported;
    const instance = (microvm_registry.findMutable(instance_id) orelse return error.Unsupported);
    return eptMapPageForInstance(instance, gpa, hpa, flags);
}

fn eptMapPage(gpa: u64, hpa: u64) VmxError!void {
    try eptMapPageEx(gpa, hpa, EPT_LEAF_FLAGS);
}

/// Walk the 4-level EPT page table hierarchy (PML4 -> PDPT -> PD -> PT)
/// to translate a Guest Physical Address (GPA) to a Host Physical Address (HPA).
///
/// Returns the translated HPA preserving in-page offset, or null if unmapped.
pub fn translateEptGpaToHpa(root_phys: u64, gpa: u64) ?u64 {
    if (root_phys == 0 or vmx_hhdm_offset == 0 or !isSupportedEptGpa(gpa)) return null;

    // Level 4: PML4
    const pml4_phys = root_phys & 0x000F_FFFF_FFFF_F000;
    const pml4: [*]const u64 = @ptrFromInt(pml4_phys + vmx_hhdm_offset);
    const pml4_idx = @as(usize, @intCast((gpa >> 39) & 0x1FF));
    const pml4e = pml4[pml4_idx];
    if ((pml4e & 0x7) == 0) return null;

    // Level 3: PDPT
    const pdpt_phys = pml4e & 0x000F_FFFF_FFFF_F000;
    const pdpt: [*]const u64 = @ptrFromInt(pdpt_phys + vmx_hhdm_offset);
    const pdpt_idx = @as(usize, @intCast((gpa >> 30) & 0x1FF));
    const pdpte = pdpt[pdpt_idx];
    if ((pdpte & 0x7) == 0) return null;

    // Check for 1 GiB large page (bit 7)
    if ((pdpte & (1 << 7)) != 0) {
        return (pdpte & 0x000F_FFFF_C000_0000) | (gpa & 0x3FFF_FFFF);
    }

    // Level 2: PD
    const pd_phys = pdpte & 0x000F_FFFF_FFFF_F000;
    const pd: [*]const u64 = @ptrFromInt(pd_phys + vmx_hhdm_offset);
    const pd_idx = @as(usize, @intCast((gpa >> 21) & 0x1FF));
    const pde = pd[pd_idx];
    if ((pde & 0x7) == 0) return null;

    // Check for 2 MiB large page (bit 7)
    if ((pde & (1 << 7)) != 0) {
        return (pde & 0x000F_FFFF_FFE0_0000) | (gpa & 0x1F_FFFF);
    }

    // Level 1: PT
    const pt_phys = pde & 0x000F_FFFF_FFFF_F000;
    const pt: [*]const u64 = @ptrFromInt(pt_phys + vmx_hhdm_offset);
    const pt_idx = @as(usize, @intCast((gpa >> 12) & 0x1FF));
    const pte = pt[pt_idx];
    if ((pte & 0x7) == 0) return null;

    // 4 KiB page translation
    return (pte & 0x000F_FFFF_FFFF_F000) | (gpa & 0xFFF);
}

fn isSupportedEptGpa(gpa: u64) bool {
    return gpa < EPT_GPA_LIMIT;
}

pub fn translateGpaToHpa(vmid: u32, gpa: u64) ?u64 {
    const inst = microvm_registry.lookup(vmid) orelse return null;
    const root = inst.ept_pml4_phys orelse return null;
    return translateEptGpaToHpa(root, gpa);
}

fn findGuestPageHpa(gpa: u64) ?u64 {
    const cpu_id = smp.getCurrentCpuId();
    const inst_id = if (cpu_id < smp.MAX_CPUS)
        (current_instance_per_cpu[cpu_id] orelse current_instance_id)
    else
        current_instance_id;
    const id = inst_id orelse return null;
    return translateGpaToHpa(id, gpa);
}

pub fn findGuestPageHpaPublic(gpa: u64) ?u64 {
    return findGuestPageHpa(gpa);
}

fn ensureGuestPageForInstance(inst: *microvm_registry.Instance, gpa: u64) VmxError!u64 {
    if (!isSupportedEptGpa(gpa)) return error.GuestTooLarge;
    const aligned = gpa & 0x000F_FFFF_FFFF_F000;
    if (aligned >= guestRamBytes(inst) and !isGuestMmioWindow(aligned)) return error.GuestTooLarge;
    if (inst.ept_pml4_phys) |root| {
        if (translateEptGpaToHpa(root, aligned)) |hpa| {
            return hpa & 0x000F_FFFF_FFFF_F000;
        }
    }

    const hpa = try allocZeroedPageForInstance(inst);
    try eptMapPageForInstance(inst, aligned, hpa, EPT_LEAF_FLAGS);
    return hpa;
}

test "EPT rejects GPAs outside the four-level address range" {
    try std.testing.expect(isSupportedEptGpa(0));
    try std.testing.expect(isSupportedEptGpa(EPT_GPA_LIMIT - 1));
    try std.testing.expect(!isSupportedEptGpa(EPT_GPA_LIMIT));
    try std.testing.expect(!isSupportedEptGpa(0xFFFF_FFFF_FFFF_FFFF));
}

fn copyIntoGuestForInstance(inst: *microvm_registry.Instance, gpa_base: u64, data: []const u8) VmxError!void {
    var offset: usize = 0;
    while (offset < data.len) {
        const cur_gpa = gpa_base + @as(u64, @intCast(offset));
        const page_gpa = cur_gpa & ~@as(u64, 0xFFF);
        const page_off = @as(usize, @intCast(cur_gpa & 0xFFF));
        const hpa = try ensureGuestPageForInstance(inst, page_gpa);
        const dst: [*]u8 = @ptrFromInt(hpa + vmx_hhdm_offset);
        const avail = pmm.PAGE_SIZE - page_off;
        const remaining = data.len - offset;
        const n = @min(avail, remaining);
        std.mem.copyForwards(u8, dst[page_off .. page_off + n], data[offset .. offset + n]);
        offset += n;
    }
}

fn guestPagePtrForInstance(inst: *const microvm_registry.Instance, gpa: u64) ?[*]u8 {
    const root = inst.ept_pml4_phys orelse return null;
    const hpa = translateEptGpaToHpa(root, gpa) orelse return null;
    return @ptrFromInt((hpa & 0x000F_FFFF_FFFF_F000) + vmx_hhdm_offset);
}

fn ensureGuestPage(gpa: u64) VmxError!u64 {
    const instance_id = getCurrentInstanceId() orelse return error.Unsupported;
    const inst = microvm_registry.findMutable(instance_id) orelse return error.Unsupported;
    return ensureGuestPageForInstance(inst, gpa);
}

fn guestPagePtr(gpa: u64) ?[*]u8 {
    const hpa = findGuestPageHpa(gpa) orelse return null;
    return @ptrFromInt(hpa + vmx_hhdm_offset);
}

fn seedGuestLowMemoryPage() VmxError!void {
    const low_hpa = try ensureGuestPage(0);
    const low: [*]u8 = @ptrFromInt(low_hpa + vmx_hhdm_offset);

    // Seed the BIOS Data Area with the conventional memory / EBDA view that
    // matches the reserved low-memory hole we advertise via E820.
    std.mem.writeInt(u16, low[0x40E..0x410], GUEST_EBDA_SEGMENT, .little);
    std.mem.writeInt(u16, low[0x413..0x415], GUEST_BASE_MEMORY_KB, .little);
}

fn buildGuestBootGdt() VmxError!void {
    const gdt_hpa = try ensureGuestPage(GUEST_BOOT_GDT_GPA);
    const gdt_page: [*]u8 = @ptrFromInt(gdt_hpa + vmx_hhdm_offset);
    const gdt_entries = @as(*[512]u64, @ptrCast(@alignCast(gdt_page)));

    @memset(gdt_entries, 0);
    gdt_entries[2] = 0x00af9a000000ffff; // __BOOT_CS selector 0x10
    gdt_entries[3] = 0x00af92000000ffff; // __BOOT_DS selector 0x18
}

fn copyIntoGuest(gpa_base: u64, data: []const u8) VmxError!void {
    var offset: usize = 0;
    while (offset < data.len) {
        const cur_gpa = gpa_base + @as(u64, @intCast(offset));
        const page_gpa = cur_gpa & 0x000F_FFFF_FFFF_F000;
        const page_off = @as(usize, @intCast(cur_gpa & 0xFFF));
        const hpa = try ensureGuestPage(page_gpa);
        const dst: [*]u8 = @ptrFromInt(hpa + vmx_hhdm_offset);
        const avail = pmm.PAGE_SIZE - page_off;
        const remaining = data.len - offset;
        const n = @min(avail, remaining);
        std.mem.copyForwards(u8, dst[page_off .. page_off + n], data[offset .. offset + n]);
        offset += n;
    }
}

pub fn stageGuestForInstance(inst: *microvm_registry.Instance) VmxError!void {
    serialWrite("VMX: staging payload for VM ");
    printDec(inst.instance_id);
    serialWrite("\n");

    if (inst.ept_pml4_phys == null) {
        inst.ept_pml4_phys = pmm.allocPage() orelse return error.OutOfMemory;
        clearPage(inst.ept_pml4_phys.?);
    }

    // Seed low memory BIOS Data Area & boot GDT
    const low_hpa = try ensureGuestPageForInstance(inst, 0);
    const low: [*]u8 = @ptrFromInt(low_hpa + vmx_hhdm_offset);
    std.mem.writeInt(u16, low[0x40E..0x410], GUEST_EBDA_SEGMENT, .little);
    std.mem.writeInt(u16, low[0x413..0x415], GUEST_BASE_MEMORY_KB, .little);

    const gdt_hpa = try ensureGuestPageForInstance(inst, GUEST_BOOT_GDT_GPA);
    const gdt_page: [*]u8 = @ptrFromInt(gdt_hpa + vmx_hhdm_offset);
    const gdt_entries = @as(*[512]u64, @ptrCast(@alignCast(gdt_page)));
    @memset(gdt_entries, 0);
    gdt_entries[2] = 0x00af9a000000ffff; // __BOOT_CS selector 0x10
    gdt_entries[3] = 0x00af92000000ffff; // __BOOT_DS selector 0x18

    // Parse guest image (either from instance buffer or embedded kernel blob)
    const image_slice: []const u8 = if (inst.kernel_phys != 0 and inst.kernel_size != 0)
        @as([*]const u8, @ptrFromInt(inst.kernel_phys + vmx_hhdm_offset))[0..inst.kernel_size]
    else
        guest_image_blob.get();

    var parsed = staged_parsed_image;
    linux_boot.parseBzImageInto(&parsed, image_slice) catch {
        serialWrite("VMX: bzImage parse failed for VM ");
        printDec(inst.instance_id);
        serialWrite("\n");
        return error.GuestImageInvalid;
    };

    const layout = linux_boot.defaultLayout(&parsed);

    // Ensure boot structure pages
    _ = try ensureGuestPageForInstance(inst, layout.boot_params_gpa);
    _ = try ensureGuestPageForInstance(inst, layout.cmdline_gpa);
    _ = try ensureGuestPageForInstance(inst, layout.guest_stack_top_gpa - pmm.PAGE_SIZE);
    _ = try ensureGuestPageForInstance(inst, layout.guest_pml4_gpa);
    _ = try ensureGuestPageForInstance(inst, layout.guest_pdpt_gpa);
    _ = try ensureGuestPageForInstance(inst, layout.guest_pd_gpa);

    for (0..GUEST_IDENTITY_PD_TABLES) |i| {
        const pd_gpa_i = layout.guest_pd_gpa + (@as(u64, @intCast(i)) * pmm.PAGE_SIZE);
        _ = try ensureGuestPageForInstance(inst, pd_gpa_i);
    }

    // Populate initramfs
    const initrd_slice: []const u8 = if (inst.initramfs_phys != 0 and inst.initramfs_size != 0)
        @as([*]const u8, @ptrFromInt(inst.initramfs_phys + vmx_hhdm_offset))[0..inst.initramfs_size]
    else
        guest_initramfs_blob.get();

    const guest_ram = guestRamBytes(inst);
    const protected = linux_boot.protectedModeImage(&parsed);
    const initrd_gpa = try chooseInitrdGpa(guest_ram, layout.kernel_load_gpa, protected.len, initrd_slice.len);
    try copyIntoGuestForInstance(inst, initrd_gpa, initrd_slice);

    // Boot params & cmdline
    const cmdline = DEFAULT_CMDLINE ++ "\x00";
    const bp_ptr = @as(*[linux_boot.zero_page_size]u8, @ptrCast(@alignCast(guestPagePtrForInstance(inst, layout.boot_params_gpa).?)));
    linux_boot.buildBootParamsPageInto(bp_ptr, &parsed, layout, cmdline, guest_ram, initrd_gpa, initrd_slice.len);

    try copyIntoGuestForInstance(inst, layout.cmdline_gpa, cmdline);
    try copyIntoGuestForInstance(inst, layout.kernel_load_gpa, protected);

    // Build guest identity tables
    const pml4 = @as(*[512]u64, @ptrCast(@alignCast(guestPagePtrForInstance(inst, layout.guest_pml4_gpa).?)));
    const pdpt = @as(*[512]u64, @ptrCast(@alignCast(guestPagePtrForInstance(inst, layout.guest_pdpt_gpa).?)));
    @memset(pml4, 0);
    @memset(pdpt, 0);
    pml4[0] = (layout.guest_pdpt_gpa & 0x000F_FFFF_FFFF_F000) | 0x3;
    pml4[256] = pml4[0];

    const huge_page_size: u64 = 2 * 1024 * 1024;
    for (0..GUEST_IDENTITY_PD_TABLES) |pdpt_i| {
        const pd_gpa_i = layout.guest_pd_gpa + (@as(u64, @intCast(pdpt_i)) * pmm.PAGE_SIZE);
        const pd_i = @as(*[512]u64, @ptrCast(@alignCast(guestPagePtrForInstance(inst, pd_gpa_i).?)));
        @memset(pd_i, 0);
        pdpt[pdpt_i] = (pd_gpa_i & 0x000F_FFFF_FFFF_F000) | 0x3;
        for (0..512) |pd_i_entry| {
            const page_index = (@as(u64, @intCast(pdpt_i)) * 512) + @as(u64, @intCast(pd_i_entry));
            pd_i[pd_i_entry] = (page_index * huge_page_size) | 0x83;
        }
    }

    // Launch state configuration
    const entry_off = linux_boot.kernelEntryOffset64(&parsed);
    const entry_gpa = layout.kernel_load_gpa + entry_off;
    const stack_top = ((layout.guest_stack_top_gpa) - 16) & ~@as(u64, 0xF);

    const launch_state: GuestLaunchState = .{
        .layout = layout,
        .guest_rip = entry_gpa,
        .guest_rsp = stack_top,
        .guest_cr3 = layout.guest_pml4_gpa,
        .boot_params_gpa = layout.boot_params_gpa,
        .guest_rsi = layout.boot_params_gpa,
    };
    if (inst.instance_id < per_instance_launch_state.len) {
        per_instance_launch_state[inst.instance_id] = launch_state;
    }
    staged_launch_state = launch_state;
    inst.launch_rsi = layout.boot_params_gpa;
    guest_linux_entry_active = true;

    // Milestone required by PROJECT.md & test harness
    smp.serialAcquire();
    serialWrite("VMX: initialized EPT root for VM ");
    printDec(inst.instance_id);
    serialWrite("\n");
    smp.serialRelease();
}

pub fn stageUefiFullVmForInstance(inst: *microvm_registry.Instance, is_warm_reboot: bool) VmxError!void {
    inst.vm_profile = .uefi_fullvm;
    const approved_img = uefi_firmware.getApprovedUefiImage();
    const revoked_img = uefi_firmware.getRevokedUefiImage();

    if (!is_warm_reboot) {
        efi_vars.resetInstance(inst.instance_id);
        if (!efi_vars.initDefaultSecureBootStore(inst.instance_id, approved_img, revoked_img)) {
            return error.GuestImageInvalid;
        }
        vtpm.resetInstance(inst.instance_id);
    } else {
        efi_vars.resetForReboot(inst.instance_id);
        vtpm.resetForReboot(inst.instance_id);
        virtio_blk.resetInstance(inst.instance_id);
        virtio_net.resetInstance(inst.instance_id);
        inst.devices.pic.reset();
        inst.devices.pit.reset();
        inst.devices.lapic.reset();
        inst.devices.pci.reset();
        inst.devices.rtc.reset();
        inst.devices.gop.reset();
    }

    // Verify Secure Boot policy before staging firmware into guest RAM
    efi_vars.verifyBootImage(inst.instance_id, approved_img) catch {
        serialWrite("VMX: Secure Boot rejected UEFI image for VM ");
        printDec(inst.instance_id);
        serialWrite("\n");
        return error.GuestImageInvalid;
    };

    if (inst.ept_pml4_phys == null) {
        inst.ept_pml4_phys = pmm.allocPage() orelse return error.OutOfMemory;
        clearPage(inst.ept_pml4_phys.?);
    }

    // Seed low memory BIOS Data Area & boot GDT
    const low_hpa = try ensureGuestPageForInstance(inst, 0);
    const low: [*]u8 = @ptrFromInt(low_hpa + vmx_hhdm_offset);
    std.mem.writeInt(u16, low[0x40E..0x410], GUEST_EBDA_SEGMENT, .little);
    std.mem.writeInt(u16, low[0x413..0x415], GUEST_BASE_MEMORY_KB, .little);

    const gdt_hpa = try ensureGuestPageForInstance(inst, GUEST_BOOT_GDT_GPA);
    const gdt_page: [*]u8 = @ptrFromInt(gdt_hpa + vmx_hhdm_offset);
    const gdt_entries = @as(*[512]u64, @ptrCast(@alignCast(gdt_page)));
    @memset(gdt_entries, 0);
    gdt_entries[2] = 0x00af9a000000ffff; // 64-bit code selector 0x10
    gdt_entries[3] = 0x00af92000000ffff; // 64-bit data selector 0x18

    // Build and verify ACPI 2.0+ tables (RSDP, RSDT, XSDT, FACP, APIC, MCFG, TPM2) at 0x000E_0000
    const acpi_hpa = try ensureGuestPageForInstance(inst, pc_platform.ACPI_TABLES_GPA);
    const acpi_page = @as(*[pc_platform.ACPI_REGION_SIZE]u8, @ptrFromInt(acpi_hpa + vmx_hhdm_offset));
    pc_platform.buildGuestAcpiTables(acpi_page, @intCast(inst.vcpus));
    if (!pc_platform.verifyGuestAcpiTables(acpi_page)) return error.GuestImageInvalid;

    // Stage UEFI firmware code at 0x0010_0000
    try copyIntoGuestForInstance(inst, uefi_firmware.UEFI_CODE_GPA, approved_img);

    // Pre-map and zero Virtio-Blk queue, descriptor, request, data, and serial command pages
    const scratch_pages = [_]u64{
        uefi_firmware.VIRTIO_DESC_GPA,
        uefi_firmware.VIRTIO_AVAIL_GPA,
        uefi_firmware.VIRTIO_USED_GPA,
        uefi_firmware.VIRTIO_REQ_HDR_GPA,
        uefi_firmware.VIRTIO_DATA_BUF_GPA,
        uefi_firmware.SERIAL_CMD_BUF_GPA,
        uefi_firmware.UEFI_STACK_TOP_GPA - pmm.PAGE_SIZE,
    };
    for (scratch_pages) |page_gpa| {
        const hpa = try ensureGuestPageForInstance(inst, page_gpa);
        clearPage(hpa);
    }

    // Stage UEFI Firmware Reset Vector ROM at 0xFFF0_0000
    const rom_hpa = try ensureGuestPageForInstance(inst, uefi_firmware.UEFI_ROM_GPA);
    const rom_page = @as(*[uefi_firmware.UEFI_ROM_SIZE]u8, @ptrFromInt(rom_hpa + vmx_hhdm_offset));
    uefi_firmware.buildResetVectorPage(rom_page);

    // Build guest 64-bit identity page tables (0..8 GiB via 2 MiB leaves)
    const pml4_gpa: u64 = 0x0009_0000;
    const pdpt_gpa: u64 = 0x0009_1000;
    const pd_base_gpa: u64 = 0x0009_2000;
    _ = try ensureGuestPageForInstance(inst, pml4_gpa);
    _ = try ensureGuestPageForInstance(inst, pdpt_gpa);
    for (0..GUEST_IDENTITY_PD_TABLES) |i| {
        _ = try ensureGuestPageForInstance(inst, pd_base_gpa + (@as(u64, @intCast(i)) * pmm.PAGE_SIZE));
    }

    const pml4 = @as(*[512]u64, @ptrCast(@alignCast(guestPagePtrForInstance(inst, pml4_gpa).?)));
    const pdpt = @as(*[512]u64, @ptrCast(@alignCast(guestPagePtrForInstance(inst, pdpt_gpa).?)));
    @memset(pml4, 0);
    @memset(pdpt, 0);
    pml4[0] = (pdpt_gpa & 0x000F_FFFF_FFFF_F000) | 0x3;
    pml4[256] = pml4[0];

    const huge_page_size: u64 = 2 * 1024 * 1024;
    for (0..GUEST_IDENTITY_PD_TABLES) |pdpt_i| {
        const pd_gpa_i = pd_base_gpa + (@as(u64, @intCast(pdpt_i)) * pmm.PAGE_SIZE);
        const pd_i = @as(*[512]u64, @ptrCast(@alignCast(guestPagePtrForInstance(inst, pd_gpa_i).?)));
        @memset(pd_i, 0);
        pdpt[pdpt_i] = (pd_gpa_i & 0x000F_FFFF_FFFF_F000) | 0x3;
        for (0..512) |pd_i_entry| {
            const page_index = (@as(u64, @intCast(pdpt_i)) * 512) + @as(u64, @intCast(pd_i_entry));
            pd_i[pd_i_entry] = (page_index * huge_page_size) | 0x83;
        }
    }

    const stack_top = (uefi_firmware.UEFI_STACK_TOP_GPA - 16) & ~@as(u64, 0xF);
    const launch_state: GuestLaunchState = .{
        .layout = .{
            .boot_params_gpa = pc_platform.ACPI_TABLES_GPA,
            .cmdline_gpa = 0,
            .kernel_load_gpa = uefi_firmware.UEFI_CODE_GPA,
            .guest_stack_top_gpa = uefi_firmware.UEFI_STACK_TOP_GPA,
            .guest_pml4_gpa = pml4_gpa,
            .guest_pdpt_gpa = pdpt_gpa,
            .guest_pd_gpa = pd_base_gpa,
        },
        .guest_rip = uefi_firmware.UEFI_ROM_GPA,
        .guest_rsp = stack_top,
        .guest_cr3 = pml4_gpa,
        .boot_params_gpa = pc_platform.ACPI_TABLES_GPA,
        .guest_rsi = pc_platform.ACPI_TABLES_GPA,
    };
    if (inst.instance_id < per_instance_launch_state.len) {
        per_instance_launch_state[inst.instance_id] = launch_state;
    }
    staged_launch_state = launch_state;
    inst.launch_rsi = pc_platform.ACPI_TABLES_GPA;
    guest_linux_entry_active = true;

    smp.serialAcquire();
    serialWrite("VMX: initialized EPT root for VM ");
    printDec(inst.instance_id);
    serialWrite("\n");
    serialWrite("VMX: staged UEFI Full-VM for VM ");
    printDec(inst.instance_id);
    serialWrite(" warm_reboot=");
    printDec(if (is_warm_reboot) 1 else 0);
    serialWrite("\n");
    smp.serialRelease();
}

fn stageLinuxGuest() VmxError!void {
    const id = current_instance_id orelse return error.Unsupported;
    const inst = microvm_registry.findMutable(id) orelse return error.Unsupported;
    return stageGuestForInstance(inst);
}

fn stageFallbackGuest(layout: linux_boot.LaunchLayout) VmxError!void {
    serialWrite("VMX: staging fallback guest image\n");

    // Required pages for boot params, cmdline, stack, and guest paging roots.
    try seedGuestLowMemoryPage();
    try buildGuestBootGdt();
    _ = try ensureGuestPage(layout.boot_params_gpa);
    _ = try ensureGuestPage(layout.cmdline_gpa);
    _ = try ensureGuestPage(layout.guest_stack_top_gpa - pmm.PAGE_SIZE);
    _ = try ensureGuestPage(layout.guest_pml4_gpa);
    _ = try ensureGuestPage(layout.guest_pdpt_gpa);
    _ = try ensureGuestPage(layout.guest_pd_gpa);

    const boot_params_page: [linux_boot.zero_page_size]u8 = @splat(0);
    const guest_stub: [8]u8 = .{ 0xB8, 0x45, 0x54, 0x41, 0x43, 0x0F, 0xA2, 0xF4 }; // mov eax,'CATE'; cpuid; hlt
    try copyIntoGuest(layout.boot_params_gpa, boot_params_page[0..]);
    try copyIntoGuest(layout.cmdline_gpa, DEFAULT_CMDLINE ++ "\x00");
    try copyIntoGuest(layout.kernel_load_gpa, guest_stub[0..]);
    const entry_gpa = layout.kernel_load_gpa;
    return finalizeLaunchState(layout, entry_gpa, false, 8, DEFAULT_CMDLINE.len + 1);
}

fn stageParsedGuest(parsed: *const linux_boot.ParsedBzImage, layout: linux_boot.LaunchLayout) VmxError!void {
    try seedGuestLowMemoryPage();
    try buildGuestBootGdt();
    _ = try ensureGuestPage(layout.boot_params_gpa);
    _ = try ensureGuestPage(layout.cmdline_gpa);
    _ = try ensureGuestPage(layout.guest_stack_top_gpa - pmm.PAGE_SIZE);
    _ = try ensureGuestPage(layout.guest_pml4_gpa);
    _ = try ensureGuestPage(layout.guest_pdpt_gpa);
    _ = try ensureGuestPage(layout.guest_pd_gpa);

    const protected = linux_boot.protectedModeImage(parsed);
    const cmdline = DEFAULT_CMDLINE ++ "\x00";

    const instance_id = getCurrentInstanceId() orelse return error.Unsupported;
    const inst = microvm_registry.findMutable(instance_id) orelse return error.Unsupported;
    const guest_ram = guestRamBytes(inst);
    const initramfs_data = guest_initramfs_blob.get();
    const initrd_gpa = try chooseInitrdGpa(guest_ram, layout.kernel_load_gpa, protected.len, initramfs_data.len);
    try copyIntoGuest(initrd_gpa, initramfs_data);
    serialWrite("VMX: initramfs loaded gpa=0x");
    printHex(initrd_gpa);
    serialWrite(" size=0x");
    printHex(initramfs_data.len);
    serialWrite("\n");

    const boot_params_page = linux_boot.buildBootParamsPage(parsed, layout, cmdline, guest_ram, initrd_gpa, initramfs_data.len);

    try copyIntoGuest(layout.boot_params_gpa, boot_params_page[0..]);
    try copyIntoGuest(layout.cmdline_gpa, cmdline);
    try copyIntoGuest(layout.kernel_load_gpa, protected);

    // Keep deterministic clean-exit entry while validating parse/copy path.
    const demo_stub_gpa: u64 = 0x000C_0000;
    const guest_stub: [8]u8 = .{ 0xB8, 0x45, 0x54, 0x41, 0x43, 0x0F, 0xA2, 0xF4 }; // mov eax,'CATE'; cpuid; hlt
    try copyIntoGuest(demo_stub_gpa, guest_stub[0..]);

    var entry_gpa = demo_stub_gpa;
    const use_linux_entry = preferLinuxEntry() and linux_boot.supports64BitBoot(parsed);
    if (use_linux_entry) {
        const entry_off = linux_boot.kernelEntryOffset64(parsed);
        entry_gpa = layout.kernel_load_gpa + entry_off;
        serialWrite("VMX: guest entry mode=linux gpa=0x");
        printHex(entry_gpa);
        serialWrite("\n");
    } else {
        serialWrite("VMX: guest entry mode=demo gpa=0x");
        printHex(entry_gpa);
        serialWrite("\n");
    }

    const kernel_span = @max(
        protected.len,
        @as(usize, @intCast(parsed.init_size)),
    );
    return finalizeLaunchState(layout, entry_gpa, use_linux_entry, kernel_span, cmdline.len);
}

fn finalizeLaunchState(layout: linux_boot.LaunchLayout, entry_gpa: u64, use_linux_entry: bool, kernel_span: usize, cmdline_len: usize) VmxError!void {
    try validateIdentityMapWindow(layout, @as(u64, @intCast(kernel_span)), entry_gpa, cmdline_len);

    // Reserve additional PD tables to widen identity mapping for Linux handoff.
    for (0..GUEST_IDENTITY_PD_TABLES) |i| {
        const pd_gpa_i = layout.guest_pd_gpa + (@as(u64, @intCast(i)) * pmm.PAGE_SIZE);
        _ = try ensureGuestPage(pd_gpa_i);
    }

    const pml4 = @as(*[512]u64, @ptrCast(@alignCast(guestPagePtr(layout.guest_pml4_gpa).?)));
    const pdpt = @as(*[512]u64, @ptrCast(@alignCast(guestPagePtr(layout.guest_pdpt_gpa).?)));

    @memset(pml4, 0);
    @memset(pdpt, 0);

    const first_pd_hpa = findGuestPageHpa(layout.guest_pd_gpa) orelse return error.GuestImageInvalid;
    if (VMX_USE_EPT) {
        pml4[0] = (layout.guest_pdpt_gpa & 0x000F_FFFF_FFFF_F000) | 0x3;
        pml4[256] = pml4[0];
    } else {
        const pdpt_hpa = findGuestPageHpa(layout.guest_pdpt_gpa) orelse return error.GuestImageInvalid;
        pml4[0] = (pdpt_hpa & 0x000F_FFFF_FFFF_F000) | 0x3;
        pml4[256] = pml4[0];
    }

    const huge_page_size: u64 = 2 * 1024 * 1024;
    for (0..GUEST_IDENTITY_PD_TABLES) |pdpt_i| {
        const pd_gpa_i = layout.guest_pd_gpa + (@as(u64, @intCast(pdpt_i)) * pmm.PAGE_SIZE);
        const pd_hpa_i = findGuestPageHpa(pd_gpa_i) orelse return error.GuestImageInvalid;
        const pd_i = @as(*[512]u64, @ptrCast(@alignCast(guestPagePtr(pd_gpa_i).?)));
        @memset(pd_i, 0);

        if (VMX_USE_EPT) {
            pdpt[pdpt_i] = (pd_gpa_i & 0x000F_FFFF_FFFF_F000) | 0x3;
        } else {
            pdpt[pdpt_i] = (pd_hpa_i & 0x000F_FFFF_FFFF_F000) | 0x3;
        }

        for (0..512) |pd_i_entry| {
            const page_index = (@as(u64, @intCast(pdpt_i)) * 512) + @as(u64, @intCast(pd_i_entry));
            const phys = page_index * huge_page_size;
            pd_i[pd_i_entry] = phys | 0x83; // present + writable + 2MiB page
        }
    }

    const boot_params_hpa = findGuestPageHpa(layout.boot_params_gpa) orelse return error.GuestImageInvalid;
    const entry_hpa = findGuestPageHpa(entry_gpa) orelse return error.GuestImageInvalid;
    const stack_hpa = findGuestPageHpa(layout.guest_stack_top_gpa - pmm.PAGE_SIZE) orelse return error.GuestImageInvalid;
    const pml4_hpa = findGuestPageHpa(layout.guest_pml4_gpa) orelse return error.GuestImageInvalid;
    _ = first_pd_hpa;

    const entry = if (VMX_USE_EPT) entry_gpa else entry_hpa;
    const stack_top = if (VMX_USE_EPT)
        ((layout.guest_stack_top_gpa) - 16) & ~@as(u64, 0xF)
    else
        ((stack_hpa + pmm.PAGE_SIZE) - 16) & ~@as(u64, 0xF);
    const guest_cr3 = if (VMX_USE_EPT) layout.guest_pml4_gpa else pml4_hpa;
    const boot_params_entry = if (VMX_USE_EPT) layout.boot_params_gpa else boot_params_hpa;

    staged_launch_state = .{
        .layout = layout,
        .guest_rip = entry,
        .guest_rsp = stack_top,
        .guest_cr3 = guest_cr3,
        .boot_params_gpa = boot_params_entry,
        .guest_rsi = if (use_linux_entry) boot_params_entry else 0,
    };
    if (current_instance_id) |id| {
        if (id < per_instance_launch_state.len) {
            per_instance_launch_state[id] = staged_launch_state;
        }
        if (microvm_registry.findMutable(id)) |inst| {
            inst.launch_rsi = staged_launch_state.guest_rsi;
        }
    }
    guest_linux_entry_active = use_linux_entry;

    serialWrite("VMX: guest launch state ready entry=0x");
    printHex(entry);
    serialWrite(" cr3=0x");
    printHex(guest_cr3);
    serialWrite("\n");
}

fn loadControlFields(vmx_basic: u64, instance: *microvm_registry.Instance) VmxError!void {
    const use_true = usesTrueControlMsrs(vmx_basic);
    const pin_msr = if (use_true) IA32_VMX_TRUE_PINBASED_CTLS else IA32_VMX_PINBASED_CTLS;
    const proc_msr = if (use_true) IA32_VMX_TRUE_PROCBASED_CTLS else IA32_VMX_PROCBASED_CTLS;
    const exit_msr = if (use_true) IA32_VMX_TRUE_EXIT_CTLS else IA32_VMX_EXIT_CTLS;
    const entry_msr = if (use_true) IA32_VMX_TRUE_ENTRY_CTLS else IA32_VMX_ENTRY_CTLS;
    const proc2_msr = if (use_true) IA32_VMX_TRUE_PROCBASED_CTLS2 else IA32_VMX_PROCBASED_CTLS2;

    const pin_requested: u32 = if (preferLinuxEntry())
        PIN_BASED_PREEMPTION_TIMER | PIN_BASED_EXTERNAL_INTERRUPT_EXITING
    else
        0;
    const pin_based = adjustVmxControls(pin_msr, pin_requested);
    const proc_based_requested = PRIMARY_CTL_HLT_EXITING | PRIMARY_CTL_IO_EXITING | PRIMARY_CTL_MSR_EXITING |
        (if (VMX_USE_EPT) PRIMARY_CTL_SECONDARY else 0);
    const proc_based = adjustVmxControls(proc_msr, proc_based_requested);
    const proc2_based = if (VMX_USE_EPT)
        adjustVmxControls(proc2_msr, SECONDARY_CTL_ENABLE_EPT)
    else
        adjustVmxControls(proc2_msr, 0);

    const vmexit_requested = EXIT_CTL_HOST_IA32E | EXIT_CTL_SAVE_PAT | EXIT_CTL_LOAD_PAT | EXIT_CTL_SAVE_EFER | EXIT_CTL_LOAD_EFER |
        (if (preferLinuxEntry()) EXIT_CTL_ACK_INTERRUPT else 0);
    const vmexit = adjustVmxControls(exit_msr, vmexit_requested);
    const vmentry_requested = ENTRY_CTL_IA32E_GUEST | ENTRY_CTL_LOAD_PAT | ENTRY_CTL_LOAD_EFER;
    const vmentry = adjustVmxControls(entry_msr, vmentry_requested);

    try vmwriteChecked(VMCS_CTRL_PIN_BASED, pin_based);
    try vmwriteChecked(VMCS_CTRL_CPU_BASED, proc_based);
    if (VMX_USE_EPT) {
        try vmwriteChecked(VMCS_CTRL_SECONDARY_CPU_BASED, proc2_based);
    }
    try configureMsrBitmap();
    const exception_bitmap: u32 = if (preferLinuxEntry()) (@as(u32, 1) << 8) else 0; // Only #DF for Linux
    try vmwriteChecked(VMCS_CTRL_EXCEPTION_BITMAP, exception_bitmap);
    try vmwriteChecked(VMCS_CTRL_VMEXIT, vmexit);
    try vmwriteChecked(VMCS_CTRL_VMENTRY, vmentry);
    serialWrite("VMX: ctrl C1\n");

    if (VMX_USE_EPT) {
        const root = instance.ept_pml4_phys orelse return error.Unsupported;
        const eptp = (root & 0x000F_FFFF_FFFF_F000) | EPT_MEMTYPE_WB | ((@as(u64, 4) - 1) << 3);
        try vmwriteChecked(VMCS_CTRL_EPT_POINTER, eptp);
    }

    if (preferLinuxEntry() and (pin_based & PIN_BASED_PREEMPTION_TIMER) != 0) {
        try vmwriteChecked(VMCS_VMX_PREEMPTION_TIMER_VALUE, PREEMPTION_TIMER_INITIAL);
        preemption_timer_active = true;
    }
}

fn loadHostStateForCore(core_id: usize) VmxError!void {
    serialWrite("VMX: host H0\n");
    const stack_phys = try ensureHostStackForCpu(core_id);
    const stack_top = stack_phys + vmx_hhdm_offset + (HOST_STACK_PAGES * pmm.PAGE_SIZE);
    const host_rsp = (stack_top & ~@as(u64, 0xF)) - 8;

    var local_gdtr: cpu.DescriptorTablePointer = .{ .limit = 0, .base = 0 };
    var local_idtr: cpu.DescriptorTablePointer = .{ .limit = 0, .base = 0 };
    cpu.sgdtInto(&local_gdtr);
    cpu.sidtInto(&local_idtr);

    try vmwriteChecked(VMCS_HOST_CR0, cpu.readCr0());
    try vmwriteChecked(VMCS_HOST_CR3, if (vmx_host_cr3 != 0) vmx_host_cr3 else cpu.readCr3());
    try vmwriteChecked(VMCS_HOST_CR4, cpu.readCr4());
    try vmwriteChecked(VMCS_HOST_CS_SELECTOR, gdt.KERNEL_CODE_SELECTOR);
    try vmwriteChecked(VMCS_HOST_SS_SELECTOR, gdt.KERNEL_DATA_SELECTOR);
    try vmwriteChecked(VMCS_HOST_DS_SELECTOR, gdt.KERNEL_DATA_SELECTOR);
    try vmwriteChecked(VMCS_HOST_ES_SELECTOR, gdt.KERNEL_DATA_SELECTOR);
    try vmwriteChecked(VMCS_HOST_FS_SELECTOR, gdt.KERNEL_DATA_SELECTOR);
    try vmwriteChecked(VMCS_HOST_GS_SELECTOR, gdt.KERNEL_DATA_SELECTOR);
    try vmwriteChecked(VMCS_HOST_TR_SELECTOR, @as(u64, gdt.tssSelectorForCpu(core_id)));
    try vmwriteChecked(VMCS_HOST_SYSENTER_CS, cpu.rdmsr(0x174));
    try vmwriteChecked(VMCS_HOST_FS_BASE, cpu.rdmsr(IA32_FS_BASE));
    try vmwriteChecked(VMCS_HOST_GS_BASE, cpu.rdmsr(IA32_GS_BASE));
    try vmwriteChecked(VMCS_HOST_TR_BASE, gdt.tssBaseForCpu(core_id));
    try vmwriteChecked(VMCS_HOST_GDTR_BASE, local_gdtr.base);
    try vmwriteChecked(VMCS_HOST_IDTR_BASE, local_idtr.base);
    try vmwriteChecked(VMCS_HOST_SYSENTER_ESP, cpu.rdmsr(0x175));
    try vmwriteChecked(VMCS_HOST_SYSENTER_EIP, cpu.rdmsr(0x176));
    try vmwriteChecked(VMCS_HOST_RSP, host_rsp);
    try vmwriteChecked(VMCS_HOST_RIP, @intFromPtr(&vmexitStub));
    try vmwriteChecked(VMCS_HOST_IA32_PAT, cpu.rdmsr(IA32_PAT));
    try vmwriteChecked(VMCS_HOST_IA32_EFER, cpu.rdmsr(IA32_EFER));
    serialWrite("VMX: host H1\n");
}

fn loadHostState() VmxError!void {
    const core_id = smp.getCurrentCpuId();
    return loadHostStateForCore(core_id);
}

fn loadGuestState(launch: *const GuestLaunchState) VmxError!void {
    serialWrite("VMX: guest G0\n");
    const guest_cr0 = sanitizeCrValue(cpu.readCr0(), IA32_VMX_CR0_FIXED0, IA32_VMX_CR0_FIXED1);
    const linux_boot_cr4_requested: u64 = @as(u64, 1) << 5; // CR4.PAE required for IA-32e paging
    const guest_cr4_requested = if (guest_linux_entry_active) linux_boot_cr4_requested else cpu.readCr4();
    const guest_cr4 = sanitizeCrValue(guest_cr4_requested, IA32_VMX_CR4_FIXED0, IA32_VMX_CR4_FIXED1);
    const guest_cr4_shadow = guest_cr4;
    const guest_cr4_mask = if (guest_linux_entry_active) guest_cr4 & ~linux_boot_cr4_requested else 0;
    const host_efer = cpu.rdmsr(IA32_EFER);
    const guest_efer = host_efer | (1 << 8) | (1 << 10);

    try vmwriteChecked(VMCS_GUEST_CR0, guest_cr0);
    try vmwriteChecked(VMCS_GUEST_CR3, launch.guest_cr3);
    try vmwriteChecked(VMCS_GUEST_CR4, guest_cr4);
    try vmwriteChecked(VMCS_CTRL_CR0_GUEST_HOST_MASK, 0);
    try vmwriteChecked(VMCS_CTRL_CR4_GUEST_HOST_MASK, guest_cr4_mask);
    try vmwriteChecked(VMCS_CTRL_CR0_READ_SHADOW, guest_cr0);
    try vmwriteChecked(VMCS_CTRL_CR4_READ_SHADOW, guest_cr4_shadow);

    // Linux 64-bit boot protocol expects __BOOT_CS=0x10 and __BOOT_DS=0x18
    // with flat 4 GiB segment semantics at entry.
    try vmwriteChecked(VMCS_GUEST_ES_SELECTOR, 0x18);
    try vmwriteChecked(VMCS_GUEST_CS_SELECTOR, 0x10);
    try vmwriteChecked(VMCS_GUEST_SS_SELECTOR, 0x18);
    try vmwriteChecked(VMCS_GUEST_DS_SELECTOR, 0x18);
    try vmwriteChecked(VMCS_GUEST_FS_SELECTOR, 0x18);
    try vmwriteChecked(VMCS_GUEST_GS_SELECTOR, 0x18);
    try vmwriteChecked(VMCS_GUEST_LDTR_SELECTOR, 0);
    try vmwriteChecked(VMCS_GUEST_TR_SELECTOR, cpu.readTr() & 0xFFF8);

    try vmwriteChecked(VMCS_GUEST_ES_LIMIT, 0xFFFF);
    try vmwriteChecked(VMCS_GUEST_CS_LIMIT, 0xFFFF);
    try vmwriteChecked(VMCS_GUEST_SS_LIMIT, 0xFFFF);
    try vmwriteChecked(VMCS_GUEST_DS_LIMIT, 0xFFFF);
    try vmwriteChecked(VMCS_GUEST_FS_LIMIT, 0xFFFF);
    try vmwriteChecked(VMCS_GUEST_GS_LIMIT, 0xFFFF);
    try vmwriteChecked(VMCS_GUEST_LDTR_LIMIT, 0);
    try vmwriteChecked(VMCS_GUEST_TR_LIMIT, 0x67);
    try vmwriteChecked(VMCS_GUEST_GDTR_LIMIT, 0x1F);
    try vmwriteChecked(VMCS_GUEST_IDTR_LIMIT, 0xFFFF);

    try vmwriteChecked(VMCS_GUEST_ES_ACCESS_RIGHTS, 0xC093);
    try vmwriteChecked(VMCS_GUEST_CS_ACCESS_RIGHTS, 0xA09B);
    try vmwriteChecked(VMCS_GUEST_SS_ACCESS_RIGHTS, 0xC093);
    try vmwriteChecked(VMCS_GUEST_DS_ACCESS_RIGHTS, 0xC093);
    try vmwriteChecked(VMCS_GUEST_FS_ACCESS_RIGHTS, 0xC093);
    try vmwriteChecked(VMCS_GUEST_GS_ACCESS_RIGHTS, 0xC093);
    try vmwriteChecked(VMCS_GUEST_LDTR_ACCESS_RIGHTS, 0x10000);
    try vmwriteChecked(VMCS_GUEST_TR_ACCESS_RIGHTS, 0x008B);
    try vmwriteChecked(VMCS_GUEST_INTERRUPTIBILITY, 0);
    try vmwriteChecked(VMCS_GUEST_ACTIVITY_STATE, 0);
    try vmwriteChecked(VMCS_GUEST_SYSENTER_CS, 0);

    try vmwriteChecked(VMCS_GUEST_ES_BASE, 0);
    try vmwriteChecked(VMCS_GUEST_CS_BASE, 0);
    try vmwriteChecked(VMCS_GUEST_SS_BASE, 0);
    try vmwriteChecked(VMCS_GUEST_DS_BASE, 0);
    try vmwriteChecked(VMCS_GUEST_FS_BASE, 0);
    try vmwriteChecked(VMCS_GUEST_GS_BASE, 0);
    try vmwriteChecked(VMCS_GUEST_LDTR_BASE, 0);
    try vmwriteChecked(VMCS_GUEST_TR_BASE, 0);
    try vmwriteChecked(VMCS_GUEST_GDTR_BASE, GUEST_BOOT_GDT_GPA);
    try vmwriteChecked(VMCS_GUEST_IDTR_BASE, 0);
    try vmwriteChecked(VMCS_GUEST_DR7, 0x400);
    try vmwriteChecked(VMCS_GUEST_RSP, launch.guest_rsp);
    try vmwriteChecked(VMCS_GUEST_RIP, launch.guest_rip);
    try vmwriteChecked(VMCS_GUEST_RFLAGS, 0x2);
    try vmwriteChecked(VMCS_GUEST_PENDING_DBG_EXCEPTIONS, 0);
    try vmwriteChecked(VMCS_GUEST_SYSENTER_ESP, 0);
    try vmwriteChecked(VMCS_GUEST_SYSENTER_EIP, 0);

    try vmwriteChecked(VMCS_GUEST_VMCS_LINK_POINTER, 0xFFFF_FFFF_FFFF_FFFF);
    try vmwriteChecked(VMCS_GUEST_IA32_PAT, cpu.rdmsr(IA32_PAT));
    try vmwriteChecked(VMCS_GUEST_IA32_EFER, guest_efer);
    serialWrite("VMX: guest G1\n");
}

fn advanceGuestRip() void {
    const rip = vmread(VMCS_GUEST_RIP) orelse return;
    const len = vmread(VMCS_VM_EXIT_INSTRUCTION_LEN) orelse 0;
    _ = vmwrite(VMCS_GUEST_RIP, rip + len);
}

fn handleCpuid(regs: *GuestRegs) void {
    const leaf = @as(u32, @truncate(regs.rax));
    const subleaf = @as(u32, @truncate(regs.rcx));
    var out = cpu.cpuid(leaf, subleaf);

    // Hide KVM and hypervisor presence from the guest so it doesn't try
    // to use paravirtualized clocks or MSRs that we don't emulate.
    if (leaf == 1) {
        out.ecx &= ~@as(u32, 1 << 31); // Clear HYPERVISOR bit
        out.ecx &= ~@as(u32, 1 << 21); // Hide x2APIC; only xAPIC-style behavior is emulated.
        out.ecx &= ~@as(u32, 1 << 24); // Hide TSC-deadline timer; LAPIC deadline MSRs are not emulated.
    } else if (leaf == 0xA) {
        out.eax = 0;
        out.ebx = 0;
        out.ecx = 0;
        out.edx = 0;
    } else if (leaf >= 0x40000000 and leaf <= 0x400000FF) {
        out.eax = 0;
        out.ebx = 0;
        out.ecx = 0;
        out.edx = 0;
    }

    regs.rax = out.eax;
    regs.rbx = out.ebx;
    regs.rcx = out.ecx;
    regs.rdx = out.edx;
    advanceGuestRip();
}

fn handleMsrRead(regs: *GuestRegs) void {
    const msr = @as(u32, @truncate(regs.rcx));
    const value: u64 = switch (msr) {
        IA32_APIC_BASE => guest_apic_base,
        IA32_EFER, IA32_PAT, IA32_FS_BASE, IA32_GS_BASE => cpu.rdmsr(msr),
        IA32_BIOS_SIGN_ID,
        IA32_MTRRCAP,
        IA32_ARCH_CAPABILITIES,
        IA32_MISC_ENABLE,
        AMD64_PATCH_LEVEL,
        MSR_CORE_PERF_FIXED_CTR_CTRL,
        MSR_CORE_PERF_GLOBAL_STATUS,
        MSR_CORE_PERF_GLOBAL_CTRL,
        MSR_CORE_PERF_GLOBAL_OVF_CTRL,
        MSR_SNB_UNC_PERF_GLOBAL_CTRL,
        MSR_SNB_UNC_FIXED_CTR_CTRL,
        MSR_SNB_UNC_FIXED_CTR,
        => 0,
        else => blk: {
            if (guest_linux_entry_active and unknown_msr_read_logs < 8) {
                const rip = vmread(VMCS_GUEST_RIP) orelse 0;
                serialWrite("VMX: unhandled msr-read msr=0x");
                printHex(msr);
                serialWrite(" rip=0x");
                printHex(rip);
                serialWrite("\n");
                unknown_msr_read_logs += 1;
            }
            break :blk 0;
        },
    };
    regs.rax = value & 0xFFFF_FFFF;
    regs.rdx = value >> 32;
    advanceGuestRip();
}

fn handleMsrWrite(regs: *GuestRegs) void {
    const msr = @as(u32, @truncate(regs.rcx));
    const value = (regs.rdx << 32) | (regs.rax & 0xFFFF_FFFF);
    switch (msr) {
        IA32_APIC_BASE => {
            guest_apic_base = (value & 0x0000_0000_FFFF_FD00) | 0x0000_0000_FEE0_0000;
        },
        IA32_FS_BASE, IA32_GS_BASE, IA32_EFER => cpu.wrmsr(msr, value),
        MSR_CORE_PERF_FIXED_CTR_CTRL,
        MSR_CORE_PERF_GLOBAL_CTRL,
        MSR_CORE_PERF_GLOBAL_OVF_CTRL,
        MSR_SNB_UNC_PERF_GLOBAL_CTRL,
        MSR_SNB_UNC_FIXED_CTR_CTRL,
        => {},
        else => {
            if (guest_linux_entry_active and unknown_msr_write_logs < 8) {
                const rip = vmread(VMCS_GUEST_RIP) orelse 0;
                serialWrite("VMX: unhandled msr-write msr=0x");
                printHex(msr);
                serialWrite(" val=0x");
                printHex(value);
                serialWrite(" rip=0x");
                printHex(rip);
                serialWrite("\n");
                unknown_msr_write_logs += 1;
            }
        },
    }
    advanceGuestRip();
}

fn handleIoExit(regs: *GuestRegs) void {
    const qualification = vmread(VMCS_EXIT_QUALIFICATION) orelse 0;
    const port = @as(u16, @truncate(qualification >> 16));
    const size = ioAccessSize(qualification);
    const is_in = (qualification & 8) != 0;

    const active_vmid = getCurrentInstanceId();
    const maybe_inst = if (active_vmid) |id| microvm_registry.findMutable(id) else null;

    if (handlePciConfigIo(maybe_inst, port, is_in, size, regs)) {
        advanceGuestRip();
        return;
    }

    const serial_dlab = if (maybe_inst) |inst|
        (inst.devices.uart.lcr & 0x80) != 0
    else
        (serial_lcr & 0x80) != 0;

    if (port == 0x20 or port == 0x21 or port == 0xA0 or port == 0xA1) {
        handlePicIo(maybe_inst, port, is_in, regs);
    } else if (port >= 0x40 and port <= 0x43) {
        handlePitIo(maybe_inst, port, is_in, regs);
    } else if (port == 0x61) {
        handlePort61(maybe_inst, is_in, regs);
    } else if (port == pc_platform.CMOS_INDEX_PORT or port == pc_platform.CMOS_DATA_PORT) {
        if (is_in) {
            const val: u8 = if (maybe_inst) |inst| inst.devices.rtc.ioIn(port) else 0x26;
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | val;
        } else {
            const val = @as(u8, @truncate(regs.rax));
            if (maybe_inst) |inst| {
                inst.devices.rtc.ioOut(port, val);
            }
        }
    } else if (port == 0x3F8) {
        if (is_in) {
            if (serial_dlab) {
                const value: u8 = if (maybe_inst) |inst| inst.devices.uart.dll else serial_dll;
                regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
            } else {
                const value: u8 = if (active_vmid) |id|
                    (microvm_registry.readConsoleInput(id) orelse 0)
                else
                    0;
                regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
            }
        } else {
            const value = @as(u8, @truncate(regs.rax));
            if (serial_dlab) {
                if (maybe_inst) |inst| {
                    inst.devices.uart.dll = value;
                } else {
                    serial_dll = value;
                }
            } else {
                if (maybe_inst) |inst| {
                    const flags = microvm_registry.lock();
                    inst.devices.uart.writeTxByte(value);
                    microvm_registry.unlock(flags);
                }
                if (active_vmid) |vmid| {
                    writeCom1CharWithPrefix(vmid, value);
                } else {
                    const s = [_]u8{value};
                    serialWrite(&s);
                }
            }
        }
    } else if (port == 0x3F9) {
        if (is_in) {
            const value: u8 = if (serial_dlab)
                (if (maybe_inst) |inst| inst.devices.uart.dlm else serial_dlm)
            else
                (if (maybe_inst) |inst| inst.devices.uart.ier else serial_ier);
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
        } else {
            const value = @as(u8, @truncate(regs.rax));
            if (serial_dlab) {
                if (maybe_inst) |inst| {
                    inst.devices.uart.dlm = value;
                } else {
                    serial_dlm = value;
                }
            } else {
                const rx_non_empty = if (active_vmid) |id| microvm_registry.hasConsoleInput(id) else false;
                const rda_active = (value & 0x01) != 0 and rx_non_empty;
                const thre_active = (value & 0x02) != 0;
                const pic_imr = if (maybe_inst) |inst| inst.devices.pic.master_imr else pic_master_imr;
                if (maybe_inst) |inst| {
                    microvm_registry.configureConsoleUartInterrupt(inst.instance_id, value, (pic_imr & 0x10) == 0);
                } else {
                    serial_ier = value;
                    if ((rda_active or thre_active) and (pic_imr & 0x10) == 0) {
                        serial_irq4_pending = true;
                    } else if (!rda_active and !thre_active) {
                        serial_irq4_pending = false;
                    }
                }
            }
        }
    } else if (port == 0x3FA) {
        if (is_in) {
            const ier = if (maybe_inst) |inst| inst.devices.uart.ier else serial_ier;
            const fcr = if (maybe_inst) |inst| inst.devices.uart.fcr else serial_fcr;
            const rx_non_empty = if (active_vmid) |id| microvm_registry.hasConsoleInput(id) else false;
            var value: u8 = 0x01;
            if (rx_non_empty and (ier & 0x01) != 0) {
                value = 0x04; // Received Data Available (RDA) pending
            } else if ((ier & 0x02) != 0) {
                value = 0x02; // Transmitter Holding Register Empty (THRE) pending
            }
            if ((fcr & 0x01) != 0) value |= 0xC0;
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
        } else {
            const value = @as(u8, @truncate(regs.rax));
            if (maybe_inst) |inst| {
                inst.devices.uart.fcr = value;
            } else {
                serial_fcr = value;
            }
        }
    } else if (port == 0x3FB) {
        if (is_in) {
            const value = if (maybe_inst) |inst| inst.devices.uart.lcr else serial_lcr;
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
        } else {
            const value = @as(u8, @truncate(regs.rax));
            if (maybe_inst) |inst| {
                inst.devices.uart.lcr = value;
            } else {
                serial_lcr = value;
            }
        }
    } else if (port == 0x3FC) {
        if (is_in) {
            const value = if (maybe_inst) |inst| inst.devices.uart.mcr else serial_mcr;
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
        } else {
            const value = @as(u8, @truncate(regs.rax));
            if (maybe_inst) |inst| {
                inst.devices.uart.mcr = value;
            } else {
                serial_mcr = value;
            }
        }
    } else if (port == 0x3FD and is_in) {
        // COM1 LSR: bits 5 and 6 (THRE and TEMT) asserted (0x60).
        // Assert bit 0 (Data Ready) if !isRxEmpty().
        var lsr: u8 = 0x60;
        if (active_vmid) |id| {
            if (microvm_registry.hasConsoleInput(id)) lsr |= 0x01;
        }
        regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | lsr;
    } else if (port == 0x3FE and is_in) {
        // COM1 MSR - report DCD+DSR+CTS asserted (no delta bits)
        regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | 0xB0;
    } else if (port == 0x3FF) {
        if (is_in) {
            const value = if (maybe_inst) |inst| inst.devices.uart.scr else serial_scr;
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
        } else {
            const value = @as(u8, @truncate(regs.rax));
            if (maybe_inst) |inst| {
                inst.devices.uart.scr = value;
            } else {
                serial_scr = value;
            }
        }
    } else if (is_in) {
        writeGuestIoValue(regs, size, 0);
    }

    advanceGuestRip();
}

fn decodeMmioWrite(rip_ptr: [*]const u8, regs: *GuestRegs) u32 {
    var i: usize = 0;
    var rex_r = false;
    if (rip_ptr[i] >= 0x40 and rip_ptr[i] <= 0x4F) {
        if ((rip_ptr[i] & 0x04) != 0) rex_r = true;
        i += 1;
    }
    var reg_idx: u8 = 0;
    if (rip_ptr[i] == 0x89) {
        i += 1;
        const modrm = rip_ptr[i];
        reg_idx = (modrm >> 3) & 7;
        if (rex_r) {
            reg_idx += 8;
        }
    } else if (rip_ptr[i] == 0xA3) {
        reg_idx = 0;
    } else if (rip_ptr[i] == 0xC7) {
        i += 1;
    }
    const val: u64 = switch (reg_idx) {
        0 => regs.rax,
        1 => regs.rcx,
        2 => regs.rdx,
        3 => regs.rbx,
        4 => 0,
        5 => regs.rbp,
        6 => regs.rsi,
        7 => regs.rdi,
        8 => regs.r8,
        9 => regs.r9,
        10 => regs.r10,
        11 => regs.r11,
        12 => regs.r12,
        13 => regs.r13,
        14 => regs.r14,
        15 => regs.r15,
        else => regs.rax,
    };
    return @as(u32, @truncate(val));
}

fn translateGlaToGpa(gla: u64) ?u64 {
    const cr0 = vmread(VMCS_GUEST_CR0) orelse 0;
    if ((cr0 & (1 << 31)) == 0) return gla;
    const cr3 = vmread(VMCS_GUEST_CR3) orelse 0;
    const pml4_gpa = cr3 & 0x000F_FFFF_FFFF_F000;
    const pml4_ptr = guestPagePtr(pml4_gpa) orelse return null;
    const pml4 = @as(*const [512]u64, @ptrCast(@alignCast(pml4_ptr)));
    const pml4e = pml4[@as(usize, @intCast((gla >> 39) & 0x1FF))];
    if ((pml4e & 1) == 0) return null;

    const pdpt_gpa = pml4e & 0x000F_FFFF_FFFF_F000;
    const pdpt_ptr = guestPagePtr(pdpt_gpa) orelse return null;
    const pdpt = @as(*const [512]u64, @ptrCast(@alignCast(pdpt_ptr)));
    const pdpte = pdpt[@as(usize, @intCast((gla >> 30) & 0x1FF))];
    if ((pdpte & 1) == 0) return null;
    if ((pdpte & (1 << 7)) != 0) return (pdpte & 0x000F_FFFF_C000_0000) | (gla & 0x3FFF_FFFF);

    const pd_gpa = pdpte & 0x000F_FFFF_FFFF_F000;
    const pd_ptr = guestPagePtr(pd_gpa) orelse return null;
    const pd = @as(*const [512]u64, @ptrCast(@alignCast(pd_ptr)));
    const pde = pd[@as(usize, @intCast((gla >> 21) & 0x1FF))];
    if ((pde & 1) == 0) return null;
    if ((pde & (1 << 7)) != 0) return (pde & 0x000F_FFFF_FFE0_0000) | (gla & 0x1F_FFFF);

    const pt_gpa = pde & 0x000F_FFFF_FFFF_F000;
    const pt_ptr = guestPagePtr(pt_gpa) orelse return null;
    const pt = @as(*const [512]u64, @ptrCast(@alignCast(pt_ptr)));
    const pte = pt[@as(usize, @intCast((gla >> 12) & 0x1FF))];
    if ((pte & 1) == 0) return null;
    return (pte & 0x000F_FFFF_FFFF_F000) | (gla & 0xFFF);
}

fn handleEptViolation(regs: *GuestRegs) bool {
    const gpa = vmread(VMCS_GUEST_PHYSICAL_ADDRESS) orelse 0;
    const gla = vmread(VMCS_GUEST_LINEAR_ADDRESS) orelse 0;
    const rip = vmread(VMCS_GUEST_RIP) orelse 0;
    const qualification = vmread(VMCS_EXIT_QUALIFICATION) orelse 0;
    const is_write = (qualification & 2) != 0;

    var val: u32 = @as(u32, @truncate(regs.rax));
    if (is_write) {
        if (translateGlaToGpa(rip)) |rip_gpa| {
            if (guestPagePtr(rip_gpa & 0x000F_FFFF_FFFF_F000)) |page| {
                const rip_off = rip_gpa & 0xFFF;
                const rip_ptr: [*]const u8 = page + rip_off;
                val = decodeMmioWrite(rip_ptr, regs);
            }
        }
    }

    if (gpa >= VIRTIO_DEV_MMIO_BASE and gpa < VIRTIO_DEV_MMIO_BASE + VIRTIO_DEV_MMIO_SIZE) {
        const vmid = getCurrentInstanceId() orelse return false;
        const offset = gpa - VIRTIO_DEV_MMIO_BASE;
        if (is_write) {
            virtio_net.handleWrite(vmid, offset, val);
        } else {
            regs.rax = virtio_net.handleRead(vmid, offset);
        }
        advanceGuestRip();
        if (build_options.services_active and ((is_write and offset == 0x050) or (!is_write and offset == 0x060))) {
            const scheduler = @import("../../kernel/scheduler.zig");
            const core_id = smp.getCurrentCpuId();
            asm volatile ("sti");
            scheduler.schedule();
            asm volatile ("cli");
            if (microvm_registry.findMutable(vmid)) |inst| {
                if (inst.vmcs_phys) |vmcs| {
                    if (vmptrld(vmcs)) {
                        inst.vmcs_active_cpu = @intCast(core_id);
                    }
                }
            }
        }
        return true;
    }
    if (gpa >= VIRTIO_BLK_MMIO_BASE and gpa < VIRTIO_BLK_MMIO_BASE + VIRTIO_BLK_MMIO_SIZE) {
        const vmid = getCurrentInstanceId() orelse return false;
        const offset = gpa - VIRTIO_BLK_MMIO_BASE;
        if (is_write) {
            virtio_blk.handleWrite(vmid, offset, val);
        } else {
            regs.rax = virtio_blk.handleRead(vmid, offset);
        }
        advanceGuestRip();
        if (build_options.services_active and ((is_write and offset == 0x050) or (!is_write and offset == 0x060))) {
            const scheduler = @import("../../kernel/scheduler.zig");
            const core_id = smp.getCurrentCpuId();
            asm volatile ("sti");
            scheduler.schedule();
            asm volatile ("cli");
            if (microvm_registry.findMutable(vmid)) |inst| {
                if (inst.vmcs_phys) |vmcs| {
                    if (vmptrld(vmcs)) {
                        inst.vmcs_active_cpu = @intCast(core_id);
                    }
                }
            }
        }
        return true;
    }
    if (gpa >= LAPIC_MMIO_BASE and gpa < LAPIC_MMIO_BASE + LAPIC_MMIO_SIZE) {
        const offset = gpa - LAPIC_MMIO_BASE;
        if (is_write) {
            lapicWrite(offset, val);
        } else {
            regs.rax = lapicRead(offset);
        }
        advanceGuestRip();
        return true;
    }
    if (gpa >= pc_platform.GOP_MMIO_BASE and gpa < pc_platform.GOP_MMIO_BASE + pc_platform.GOP_MMIO_SIZE) {
        const vmid = getCurrentInstanceId() orelse return false;
        const inst = microvm_registry.findMutable(vmid) orelse return false;
        const offset = gpa - pc_platform.GOP_MMIO_BASE;
        if (is_write) {
            inst.devices.gop.mmioWrite(offset, val);
        } else {
            regs.rax = inst.devices.gop.mmioRead(offset);
        }
        advanceGuestRip();
        return true;
    }
    if (gpa >= efi_vars.EFI_VAR_MMIO_BASE and gpa < efi_vars.EFI_VAR_MMIO_BASE + efi_vars.EFI_VAR_MMIO_SIZE) {
        const vmid = getCurrentInstanceId() orelse return false;
        const offset = gpa - efi_vars.EFI_VAR_MMIO_BASE;
        if (is_write) {
            efi_vars.mmioWrite(vmid, offset, val);
        } else {
            regs.rax = efi_vars.mmioRead(vmid, offset);
        }
        advanceGuestRip();
        return true;
    }
    if (gpa >= vtpm.TPM_CRB_MMIO_BASE and gpa < vtpm.TPM_CRB_MMIO_BASE + vtpm.TPM_CRB_MMIO_SIZE) {
        const vmid = getCurrentInstanceId() orelse return false;
        const offset = gpa - vtpm.TPM_CRB_MMIO_BASE;
        if (is_write) {
            vtpm.mmioWrite(vmid, offset, val);
        } else {
            regs.rax = vtpm.mmioRead(vmid, offset);
        }
        advanceGuestRip();
        return true;
    }

    ept_violation_count += 1;
    if (!guest_linux_entry_active or ept_violation_count < 10) {
        serialWrite("VMX: ept-violation gpa=0x");
        printHex(gpa);
        serialWrite(" gla=0x");
        printHex(gla);
        serialWrite(" rip=0x");
        printHex(rip);
        serialWrite("\n");
    }

    if ((ept_violation_count & 0x1FF) == 0) {
        serialWrite("VMX: ept-progress exits=0x");
        printHex(ept_violation_count);
        serialWrite("\n");
    }

    const window_pages: usize = if (guest_linux_entry_active)
        EPT_PREFAULT_WINDOW_PAGES_LINUX
    else
        EPT_PREFAULT_WINDOW_PAGES_DEMO;
    // Align window base to window_pages * PAGE_SIZE boundary so prefaulted
    // pages are always contiguous and cover the faulting address.
    const window_size: u64 = @as(u64, @intCast(window_pages)) * pmm.PAGE_SIZE;
    const window_base = (gpa / window_size) * window_size;
    const vmid = getCurrentInstanceId() orelse return false;
    const inst = microvm_registry.findMutable(vmid) orelse return false;
    const guest_ram_bytes = guestRamBytes(inst);
    if (gpa >= guest_ram_bytes and !isGuestMmioWindow(gpa)) {
        smp.serialAcquire();
        serialWrite("VMX: guest GPA exceeds configured RAM vm=");
        printDec(vmid);
        serialWrite(" gpa=0x");
        printHex(gpa);
        serialWrite(" ram=0x");
        printHex(guest_ram_bytes);
        serialWrite("\n");
        smp.serialRelease();
        return false;
    }
    const page_size: u64 = pmm.PAGE_SIZE;
    const pages_to_map = if (gpa >= guest_ram_bytes)
        1
    else blk: {
        const remaining_pages = (guest_ram_bytes - window_base + page_size - 1) / page_size;
        break :blk @min(window_pages, @as(usize, @intCast(remaining_pages)));
    };

    for (0..pages_to_map) |i| {
        const page_gpa = window_base + (@as(u64, @intCast(i)) * pmm.PAGE_SIZE);
        _ = ensureGuestPage(page_gpa) catch |err| {
            serialWrite("VMX: ept-violation map failed err=0x");
            printHex(@intFromError(err));
            serialWrite("\n");
            return false;
        };
    }
    return true;
}

fn handleEptMisconfig(regs: *GuestRegs) bool {
    const gpa = vmread(VMCS_GUEST_PHYSICAL_ADDRESS) orelse 0;
    const qualification = vmread(VMCS_EXIT_QUALIFICATION) orelse 0;
    const is_write = (qualification & 2) != 0;

    if (gpa >= VIRTIO_DEV_MMIO_BASE and gpa < VIRTIO_DEV_MMIO_BASE + VIRTIO_DEV_MMIO_SIZE) {
        const vmid = getCurrentInstanceId() orelse return false;
        const offset = gpa - VIRTIO_DEV_MMIO_BASE;
        if (is_write) {
            virtio_net.handleWrite(vmid, offset, @as(u32, @truncate(regs.rax)));
        } else {
            regs.rax = virtio_net.handleRead(vmid, offset);
        }
        advanceGuestRip();
        return true;
    }
    if (gpa >= VIRTIO_BLK_MMIO_BASE and gpa < VIRTIO_BLK_MMIO_BASE + VIRTIO_BLK_MMIO_SIZE) {
        const vmid = getCurrentInstanceId() orelse return false;
        const offset = gpa - VIRTIO_BLK_MMIO_BASE;
        if (is_write) {
            virtio_blk.handleWrite(vmid, offset, @as(u32, @truncate(regs.rax)));
        } else {
            regs.rax = virtio_blk.handleRead(vmid, offset);
        }
        advanceGuestRip();
        return true;
    }
    return false;
}

fn handleExceptionExit() void {
    const intr_info = vmread(VMCS_VM_EXIT_INTERRUPTION_INFO) orelse 0;
    const vector = intr_info & 0xFF;
    const intr_type = (intr_info >> 8) & 0x7;
    const has_error_code = ((intr_info >> 11) & 0x1) != 0;
    const valid = ((intr_info >> 31) & 0x1) != 0;
    const rip = vmread(VMCS_GUEST_RIP) orelse 0;
    const gla = vmread(VMCS_GUEST_LINEAR_ADDRESS) orelse 0;
    const gpa = vmread(VMCS_GUEST_PHYSICAL_ADDRESS) orelse 0;

    serialWrite("VMX: exception-exit valid=");
    printHex(if (valid) 1 else 0);
    serialWrite(" vector=0x");
    printHex(vector);
    serialWrite(" type=0x");
    printHex(intr_type);
    serialWrite(" rip=0x");
    printHex(rip);
    serialWrite(" gla=0x");
    printHex(gla);
    serialWrite(" gpa=0x");
    printHex(gpa);
    if (has_error_code) {
        serialWrite(" err=0x");
        printHex(vmread(VMCS_VM_EXIT_INTERRUPTION_ERROR_CODE) orelse 0);
    }
    serialWrite("\n");

    if (vector == 13) {
        serialWrite("VMX: Guest General Protection Fault detected\n");
        const code_base = vmread(VMCS_GUEST_CS_BASE) orelse 0;
        const code_limit = vmread(VMCS_GUEST_CS_LIMIT) orelse 0;
        const code_ar = vmread(VMCS_GUEST_CS_ACCESS_RIGHTS) orelse 0;
        serialWrite("VMX: Guest CS: base=0x");
        printHex(code_base);
        serialWrite(" limit=0x");
        printHex(code_limit);
        serialWrite(" ar=0x");
        printHex(code_ar);
        serialWrite("\n");

        const ss_base = vmread(VMCS_GUEST_SS_BASE) orelse 0;
        const ss_ar = vmread(VMCS_GUEST_SS_ACCESS_RIGHTS) orelse 0;
        serialWrite("VMX: Guest SS: base=0x");
        printHex(ss_base);
        serialWrite(" ar=0x");
        printHex(ss_ar);
        serialWrite("\n");

        const tr_base = vmread(VMCS_GUEST_TR_BASE) orelse 0;
        const tr_limit = vmread(VMCS_GUEST_TR_LIMIT) orelse 0;
        const tr_ar = vmread(VMCS_GUEST_TR_ACCESS_RIGHTS) orelse 0;
        serialWrite("VMX: Guest TR: base=0x");
        printHex(tr_base);
        serialWrite(" limit=0x");
        printHex(tr_limit);
        serialWrite(" ar=0x");
        printHex(tr_ar);
        serialWrite("\n");
    }

    if (vector == 14) {
        dumpGuestPageWalk(gla);
        if (gla >= 0xFE000 and gla <= 0x100000) {
            serialWrite("VMX: Memory dump near 0xFF000:\n");
            dumpGuestBytes(0xFF000, 64);
            const inst_phys = findGuestPageHpa(rip) orelse 0;
            if (inst_phys != 0) {
                serialWrite("VMX: Instructions at pf rip:\n");
                dumpGuestBytes(rip, 32);
            }
        }
    }
}

fn dumpGuestPageWalk(gla: u64) void {
    const cr3 = vmread(VMCS_GUEST_CR3) orelse 0;
    serialWrite("VMX: guest-walk cr3=0x");
    printHex(cr3);
    serialWrite(" gla=0x");
    printHex(gla);
    serialWrite("\n");

    const pml4_gpa = cr3 & 0x000F_FFFF_FFFF_F000;
    const pml4_ptr = guestPagePtr(pml4_gpa) orelse {
        serialWrite("VMX: guest-walk missing pml4 gpa=0x");
        printHex(pml4_gpa);
        serialWrite("\n");
        return;
    };
    const pml4 = @as(*const [512]u64, @ptrCast(@alignCast(pml4_ptr)));
    const pml4_index: usize = @intCast((gla >> 39) & 0x1FF);
    const pml4e = pml4[pml4_index];
    serialWrite("VMX: guest-walk pml4e=0x");
    printHex(pml4e);
    serialWrite("\n");
    if ((pml4e & 1) == 0) return;

    const pdpt_gpa = pml4e & 0x000F_FFFF_FFFF_F000;
    const pdpt_ptr = guestPagePtr(pdpt_gpa) orelse {
        serialWrite("VMX: guest-walk missing pdpt gpa=0x");
        printHex(pdpt_gpa);
        serialWrite("\n");
        return;
    };
    const pdpt = @as(*const [512]u64, @ptrCast(@alignCast(pdpt_ptr)));
    const pdpt_index: usize = @intCast((gla >> 30) & 0x1FF);
    const pdpte = pdpt[pdpt_index];
    serialWrite("VMX: guest-walk pdpte=0x");
    printHex(pdpte);
    serialWrite("\n");
    if ((pdpte & 1) == 0 or (pdpte & (1 << 7)) != 0) return;

    const pd_gpa = pdpte & 0x000F_FFFF_FFFF_F000;
    const pd_ptr = guestPagePtr(pd_gpa) orelse {
        serialWrite("VMX: guest-walk missing pd gpa=0x");
        printHex(pd_gpa);
        serialWrite("\n");
        return;
    };
    const pd = @as(*const [512]u64, @ptrCast(@alignCast(pd_ptr)));
    const pd_index: usize = @intCast((gla >> 21) & 0x1FF);
    const pde = pd[pd_index];
    serialWrite("VMX: guest-walk pde=0x");
    printHex(pde);
    serialWrite("\n");
    if ((pde & 1) == 0 or (pde & (1 << 7)) != 0) return;

    const pt_gpa = pde & 0x000F_FFFF_FFFF_F000;
    const pt_ptr = guestPagePtr(pt_gpa) orelse {
        serialWrite("VMX: guest-walk missing pt gpa=0x");
        printHex(pt_gpa);
        serialWrite("\n");
        return;
    };
    const pt = @as(*const [512]u64, @ptrCast(@alignCast(pt_ptr)));
    const pt_index: usize = @intCast((gla >> 12) & 0x1FF);
    const pte = pt[pt_index];
    serialWrite("VMX: guest-walk pte=0x");
    printHex(pte);
    serialWrite("\n");
}

fn dumpGuestBytes(gpa: u64, count: usize) void {
    const page_gpa = gpa & 0x000F_FFFF_FFFF_F000;
    const page_ptr = guestPagePtr(page_gpa) orelse {
        serialWrite("VMX: guest-bytes missing gpa=0x");
        printHex(page_gpa);
        serialWrite("\n");
        return;
    };
    const page_off: usize = @intCast(gpa & 0xFFF);
    const limit = @min(count, pmm.PAGE_SIZE - page_off);
    const bytes = page_ptr[page_off .. page_off + limit];

    serialWrite("VMX: guest-bytes gpa=0x");
    printHex(gpa);
    serialWrite(" data=");
    for (bytes) |b| {
        const hi: u8 = @intCast((b >> 4) & 0xF);
        const lo: u8 = @intCast(b & 0xF);
        cpu.outb(0x3F8, "0123456789ABCDEF"[hi]);
        cpu.outb(0x3F8, "0123456789ABCDEF"[lo]);
    }
    serialWrite("\n");
}

fn handlePicIo(maybe_inst: ?*microvm_registry.Instance, port: u16, is_in: bool, regs: *GuestRegs) void {
    const is_master = (port == 0x20 or port == 0x21);
    const is_data = (port == 0x21 or port == 0xA1);

    const icw_step: *u8 = if (maybe_inst) |inst|
        (if (is_master) &inst.devices.pic.master_icw_step else &inst.devices.pic.slave_icw_step)
    else
        (if (is_master) &pic_master_icw_step else &pic_slave_icw_step);

    const vector_base: *u8 = if (maybe_inst) |inst|
        (if (is_master) &inst.devices.pic.master_vector_base else &inst.devices.pic.slave_vector_base)
    else
        (if (is_master) &pic_master_vector_base else &pic_slave_vector_base);

    const imr: *u8 = if (maybe_inst) |inst|
        (if (is_master) &inst.devices.pic.master_imr else &inst.devices.pic.slave_imr)
    else
        (if (is_master) &pic_master_imr else &pic_slave_imr);

    if (is_in) {
        if (is_data) {
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | imr.*;
        } else {
            // IRR/ISR read (OCW3) - return 0
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00);
        }
    } else {
        const val = @as(u8, @truncate(regs.rax));
        if (is_data) {
            if (icw_step.* > 0) {
                switch (icw_step.*) {
                    1 => {
                        vector_base.* = val & 0xF8;
                        icw_step.* = 2;
                    },
                    2 => {
                        icw_step.* = 3;
                    },
                    3 => {
                        icw_step.* = 0;
                    },
                    else => {
                        icw_step.* = 0;
                    },
                }
            } else {
                imr.* = val;
            }
        } else {
            // Command port write
            if ((val & 0x10) != 0) {
                // ICW1 - start initialization sequence
                icw_step.* = 1;
                imr.* = 0;
            }
            // EOI (0x20) and OCW3 accepted silently
        }
    }
}

fn handlePitIo(maybe_inst: ?*microvm_registry.Instance, port: u16, is_in: bool, regs: *GuestRegs) void {
    if (is_in) {
        // PIT counter reads - return 0
        regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00);
        return;
    }

    const channel0_mode: *u8 = if (maybe_inst) |inst| &inst.devices.pit.channel0_mode else &pit_channel0_mode;
    const write_lsb_next: *bool = if (maybe_inst) |inst| &inst.devices.pit.write_lsb_next else &pit_write_lsb_next;
    const reload_low: *u8 = if (maybe_inst) |inst| &inst.devices.pit.reload_low else &pit_reload_low;
    const channel0_reload: *u16 = if (maybe_inst) |inst| &inst.devices.pit.channel0_reload else &pit_channel0_reload;
    const configured: *bool = if (maybe_inst) |inst| &inst.devices.pit.configured else &pit_configured;

    const val = @as(u8, @truncate(regs.rax));
    if (port == 0x43) {
        // Mode/Command register - handle channel 0 programming
        const channel = (val >> 6) & 0x3;
        if (channel == 0) {
            channel0_mode.* = (val >> 1) & 0x7;
            const access = (val >> 4) & 0x3;
            if (access == 3) {
                // lobyte/hibyte access mode
                write_lsb_next.* = true;
            }
        }
        // Channel 2 command bytes accepted silently (calibration uses port 0x61 output)
    } else if (port == 0x40) {
        // Channel 0 data
        if (write_lsb_next.*) {
            reload_low.* = val;
            write_lsb_next.* = false;
        } else {
            channel0_reload.* = (@as(u16, val) << 8) | reload_low.*;
            write_lsb_next.* = true;
            if (!configured.*) {
                configured.* = true;
                serialWrite("VMX: PIT configured reload=0x");
                printHex(channel0_reload.*);
                serialWrite(" mode=");
                printHex(channel0_mode.*);
                serialWrite("\n");
            }
            // Arm the preemption timer for interrupt delivery
            const pt_active = if (maybe_inst) |inst| (inst.devices.misc.preemption_timer_active or preemption_timer_active) else preemption_timer_active;
            if (pt_active) {
                _ = vmwrite(VMCS_VMX_PREEMPTION_TIMER_VALUE, PREEMPTION_TIMER_RELOAD);
            }
        }
    }
    // Port 0x41, 0x42 writes accepted silently (channel 1/2 data)
}

fn handlePort61(maybe_inst: ?*microvm_registry.Instance, is_in: bool, regs: *GuestRegs) void {
    const port_val: *u8 = if (maybe_inst) |inst| &inst.devices.misc.port_61_value else &port_61_value;
    const port_reads: *u32 = if (maybe_inst) |inst| &inst.devices.misc.port_61_reads else &port_61_reads;

    if (is_in) {
        // Toggle timer 2 output (bit 5) periodically to unblock TSC calibration.
        // Linux's PIT-based calibration polls this bit waiting for it to change.
        port_reads.* += 1;
        if ((port_reads.* & 0xFF) == 0) {
            port_val.* ^= 0x20;
        }
        regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | port_val.*;
    } else {
        port_val.* = @as(u8, @truncate(regs.rax));
    }
}

fn tryInjectTimerIrq() void {
    const interruptibility = vmread(VMCS_GUEST_INTERRUPTIBILITY) orelse return;
    if (lapic_nmi_pending) {
        if ((interruptibility & (@as(u64, 1) << 3)) == 0) {
            const entry_info: u64 = @as(u64, X86_NMI_VECTOR) |
                (VM_ENTRY_INTR_TYPE_NMI << 8) |
                (@as(u64, 1) << 31);
            _ = vmwrite(VMCS_VM_ENTRY_INTR_INFO, entry_info);
            lapic_nmi_pending = false;
            return;
        }
        return;
    }

    const rflags = vmread(VMCS_GUEST_RFLAGS) orelse return;
    const guest_interruptible = (rflags & (1 << 9)) != 0 and (interruptibility & 0x3) == 0;

    const core_id = smp.getCurrentCpuId();
    const active_vmid = if (core_id < smp.MAX_CPUS) current_instance_per_cpu[core_id] else current_instance_id;
    const maybe_inst = if (active_vmid) |id| microvm_registry.findMutable(id) else null;

    const irq4_pending: bool = if (active_vmid) |id|
        microvm_registry.consoleUartInterruptPending(id, guest_interruptible)
    else
        serial_irq4_pending;

    // Inject COM1 THRE / RDA interrupt (IRQ4) when the ttyS0 driver has interrupts enabled.
    // This drives interrupt-mode TX so userspace write() calls reach the serial port.
    if (irq4_pending) {
        if (guest_interruptible) {
            const pic_base: u8 = if (maybe_inst) |inst| inst.devices.pic.master_vector_base else pic_master_vector_base;
            const vector: u64 = @as(u64, pic_base) + 4;
            _ = vmwrite(VMCS_VM_ENTRY_INTR_INFO, vector | (VM_ENTRY_INTR_TYPE_EXTERNAL << 8) | (1 << 31));
            if (active_vmid == null) {
                serial_irq4_pending = false;
            }
            return; // one interrupt per VMENTRY
        }
        // Interrupt window will let us retry
        const proc = vmread(VMCS_CTRL_CPU_BASED) orelse return;
        _ = vmwrite(VMCS_CTRL_CPU_BASED, proc | PRIMARY_CTL_INTERRUPT_WINDOW);
        return;
    }

    const pit_timer_pending: bool = if (maybe_inst) |inst| inst.devices.pit.timer_irq_pending else timer_irq_pending;
    if (!pit_timer_pending) return;

    // Guest must have IF=1 and no STI/MOV-SS blocking
    if (!guest_interruptible) {
        // Enable interrupt-window exiting to retry when guest becomes interruptible
        const proc = vmread(VMCS_CTRL_CPU_BASED) orelse return;
        _ = vmwrite(VMCS_CTRL_CPU_BASED, proc | PRIMARY_CTL_INTERRUPT_WINDOW);
        if (timer_inject_count == 0) {
            serialWrite("VMX: timer inject deferred IF=0x");
            printHex((rflags >> 9) & 1);
            serialWrite(" intblk=0x");
            printHex(interruptibility);
            serialWrite("\n");
        }
        return;
    }

    // Inject timer interrupt: IRQ 0 → vector = pic_master_vector_base
    const pic_base: u8 = if (maybe_inst) |inst| inst.devices.pic.master_vector_base else pic_master_vector_base;
    const vector: u64 = pic_base;
    const entry_info: u64 = vector | (VM_ENTRY_INTR_TYPE_EXTERNAL << 8) | (1 << 31);
    _ = vmwrite(VMCS_VM_ENTRY_INTR_INFO, entry_info);
    if (maybe_inst) |inst| {
        inst.devices.pit.timer_irq_pending = false;
    } else {
        timer_irq_pending = false;
    }
    timer_inject_count += 1;
    if (timer_inject_count <= 3) {
        serialWrite("VMX: timer IRQ injected vec=0x");
        printHex(vector);
        serialWrite(" count=0x");
        printHex(timer_inject_count);
        serialWrite("\n");
    }
}

fn handlePreemptionTimerExit() bool {
    timer_exit_count += 1;
    const core_id = smp.getCurrentCpuId();
    const active_vmid = if (core_id < smp.MAX_CPUS) current_instance_per_cpu[core_id] else current_instance_id;
    const maybe_inst = if (active_vmid) |id| microvm_registry.findMutable(id) else null;

    const is_pit_configured = if (maybe_inst) |inst| inst.devices.pit.configured else pit_configured;
    if (is_pit_configured) {
        if (maybe_inst) |inst| {
            inst.devices.pit.timer_irq_pending = true;
        } else {
            timer_irq_pending = true;
        }
        _ = vmwrite(VMCS_VMX_PREEMPTION_TIMER_VALUE, PREEMPTION_TIMER_RELOAD);
        if (timer_exit_count <= 3) {
            serialWrite("VMX: preemption timer fired count=0x");
            printHex(timer_exit_count);
            serialWrite(" pit_cfg=");
            printHex(if (is_pit_configured) @as(u64, 1) else @as(u64, 0));
            serialWrite("\n");
        }
    } else {
        // PIT not yet programmed; use long interval to reduce overhead
        _ = vmwrite(VMCS_VMX_PREEMPTION_TIMER_VALUE, PREEMPTION_TIMER_INITIAL);
    }
    if (build_options.services_active) {
        const scheduler = @import("../../kernel/scheduler.zig");
        asm volatile ("sti");
        scheduler.schedule();
        asm volatile ("cli");
    }
    return true;
}

fn handleInterruptWindowExit() bool {
    // Disable interrupt-window exiting
    const proc = vmread(VMCS_CTRL_CPU_BASED) orelse return false;
    _ = vmwrite(VMCS_CTRL_CPU_BASED, proc & ~@as(u64, PRIMARY_CTL_INTERRUPT_WINDOW));
    // Try injecting the deferred interrupt now
    tryInjectTimerIrq();
    return true;
}

fn readGuestReg(regs: *GuestRegs, reg: u4) u64 {
    return switch (reg) {
        0 => regs.rax,
        1 => regs.rcx,
        2 => regs.rdx,
        3 => regs.rbx,
        4 => vmread(VMCS_GUEST_RSP) orelse 0,
        5 => regs.rbp,
        6 => regs.rsi,
        7 => regs.rdi,
        8 => regs.r8,
        9 => regs.r9,
        10 => regs.r10,
        11 => regs.r11,
        12 => regs.r12,
        13 => regs.r13,
        14 => regs.r14,
        15 => regs.r15,
    };
}

fn writeGuestReg(regs: *GuestRegs, reg: u4, val: u64) void {
    switch (reg) {
        0 => {
            regs.rax = val;
        },
        1 => {
            regs.rcx = val;
        },
        2 => {
            regs.rdx = val;
        },
        3 => {
            regs.rbx = val;
        },
        4 => {
            _ = vmwrite(VMCS_GUEST_RSP, val);
        },
        5 => {
            regs.rbp = val;
        },
        6 => {
            regs.rsi = val;
        },
        7 => {
            regs.rdi = val;
        },
        8 => {
            regs.r8 = val;
        },
        9 => {
            regs.r9 = val;
        },
        10 => {
            regs.r10 = val;
        },
        11 => {
            regs.r11 = val;
        },
        12 => {
            regs.r12 = val;
        },
        13 => {
            regs.r13 = val;
        },
        14 => {
            regs.r14 = val;
        },
        15 => {
            regs.r15 = val;
        },
    }
}

fn handleCrAccess(regs: *GuestRegs) void {
    const qualification = vmread(VMCS_EXIT_QUALIFICATION) orelse 0;
    const cr_num = @as(u4, @truncate(qualification & 0xF));
    const access_type = @as(u2, @truncate((qualification >> 4) & 0x3));
    const reg_num = @as(u4, @truncate((qualification >> 8) & 0xF));

    if (access_type == 0) {
        // MOV to CR
        const val = readGuestReg(regs, reg_num);
        if (cr_num == 0) {
            const sanitized = sanitizeCrValue(val, IA32_VMX_CR0_FIXED0, IA32_VMX_CR0_FIXED1);
            _ = vmwrite(VMCS_GUEST_CR0, sanitized);
            _ = vmwrite(VMCS_CTRL_CR0_READ_SHADOW, val);
        } else if (cr_num == 4) {
            const sanitized = sanitizeCrValue(val, IA32_VMX_CR4_FIXED0, IA32_VMX_CR4_FIXED1);
            _ = vmwrite(VMCS_GUEST_CR4, sanitized);
            _ = vmwrite(VMCS_CTRL_CR4_READ_SHADOW, val);
        }
    } else if (access_type == 1) {
        // MOV from CR
        if (cr_num == 0) {
            const val = vmread(VMCS_CTRL_CR0_READ_SHADOW) orelse 0;
            writeGuestReg(regs, reg_num, val);
        } else if (cr_num == 4) {
            const val = vmread(VMCS_CTRL_CR4_READ_SHADOW) orelse 0;
            writeGuestReg(regs, reg_num, val);
        }
    }
    // CLTS (access_type 2) and LMSW (access_type 3) accepted silently
    advanceGuestRip();
}

fn dispatchVmexit(regs: *GuestRegs) bool {
    const raw_reason = vmread(VMCS_VM_EXIT_REASON) orelse {
        serialWrite("VMX: vmread(VM_EXIT_REASON) failed\n");
        return false;
    };

    vmexit_count += 1;
    const reason = raw_reason & 0xFFFF;
    const is_spam = reason == VMEXIT_REASON_EPT_VIOLATION or
        reason == VMEXIT_REASON_EXTERNAL_INTERRUPT or
        reason == VMEXIT_REASON_XSETBV or
        reason == VMEXIT_REASON_CPUID or
        reason == VMEXIT_REASON_MSR_READ or
        reason == VMEXIT_REASON_IO_INSTRUCTION or
        reason == VMEXIT_REASON_MSR_WRITE or
        reason == VMEXIT_REASON_PREEMPTION_TIMER or
        reason == VMEXIT_REASON_INTERRUPT_WINDOW or
        reason == VMEXIT_REASON_HLT or
        reason == VMEXIT_REASON_CR_ACCESS;
    if (!(guest_linux_entry_active and is_spam)) {
        serialWrite("VMX: vm-exit reason=");
        serialWrite(vmexitReasonName(reason));
        serialWrite(" (0x");
        printHex(reason);
        serialWrite(")\n");
    }

    // drainMicrovmIngress();

    switch (reason) {
        VMEXIT_REASON_EXCEPTION_NMI => {
            handleExceptionExit();
            return false;
        },
        VMEXIT_REASON_CPUID => {
            const leaf = @as(u32, @truncate(regs.rax));
            handleCpuid(regs);
            if (leaf == DEMO_EXIT_CPUID_LEAF) {
                serialWrite("phase6: vmm launch demo: clean guest exit\n");
                return false;
            }
            return true;
        },
        VMEXIT_REASON_IO_INSTRUCTION => {
            handleIoExit(regs);
            return true;
        },
        VMEXIT_REASON_MSR_READ => {
            handleMsrRead(regs);
            return true;
        },
        VMEXIT_REASON_MSR_WRITE => {
            handleMsrWrite(regs);
            return true;
        },
        VMEXIT_REASON_EXTERNAL_INTERRUPT => {
            // An external host interrupt fired while the guest was running.
            // Because EXIT_CTL_ACK_INTERRUPT is set, the CPU already acknowledged
            // the vector at the PIC on VM-exit; dispatch IRQ1 (0x21) to the keyboard
            // bridge so the 8042 buffer is drained before EOI, or ACK IRQ0 (0x20).
            const intr_info = vmread(VMCS_VM_EXIT_INTERRUPTION_INFO) orelse 0;
            const vec = @as(u8, @truncate(intr_info & 0xFF));
            if (vec == 0x21) {
                const kbd = @import("keyboard.zig");
                kbd.catenary_keyboardInterruptBridge();
            } else {
                cpu.outb(0x20, 0x20); // EOI to PIC master
            }
            if (build_options.services_active) {
                const scheduler = @import("../../kernel/scheduler.zig");
                asm volatile ("sti");
                scheduler.schedule();
                asm volatile ("cli");
            }
            return true;
        },
        VMEXIT_REASON_XSETBV => {
            const ecx = @as(u32, @truncate(regs.rcx));
            const eax = @as(u32, @truncate(regs.rax));
            const edx = @as(u32, @truncate(regs.rdx));
            const val = (@as(u64, edx) << 32) | eax;
            cpu.xsetbv(ecx, val);
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_EPT_VIOLATION => {
            return handleEptViolation(regs);
        },
        VMEXIT_REASON_EPT_MISCONFIG => {
            return handleEptMisconfig(regs);
        },
        VMEXIT_REASON_PREEMPTION_TIMER => {
            return handlePreemptionTimerExit();
        },
        VMEXIT_REASON_INTERRUPT_WINDOW => {
            return handleInterruptWindowExit();
        },
        VMEXIT_REASON_CR_ACCESS => {
            handleCrAccess(regs);
            return true;
        },
        VMEXIT_REASON_HLT => {
            advanceGuestRip();
            // Linux often HLTs when idling. We should trigger a timer interrupt
            // to ensure it doesn't sleep forever if we haven't injected one recently.
            const core_id = smp.getCurrentCpuId();
            const active_vmid = if (core_id < smp.MAX_CPUS) current_instance_per_cpu[core_id] else current_instance_id;
            const maybe_inst = if (active_vmid) |id| microvm_registry.findMutable(id) else null;
            if (maybe_inst) |inst| {
                inst.devices.pit.timer_irq_pending = true;
            } else {
                timer_irq_pending = true;
            }
            if (build_options.services_active) {
                const scheduler = @import("../../kernel/scheduler.zig");
                asm volatile ("sti");
                scheduler.schedule();
                asm volatile ("cli");
                if (maybe_inst) |inst| {
                    if (inst.vmcs_phys) |vmcs| {
                        if (vmptrld(vmcs)) {
                            inst.vmcs_active_cpu = @intCast(core_id);
                        }
                    }
                }
            }
            tryInjectTimerIrq();
            return true;
        },
        VMEXIT_REASON_TRIPLE_FAULT => {
            serialWrite("VMX: guest triple fault\n");
            return false;
        },
        VMEXIT_REASON_INVD, VMEXIT_REASON_WBINVD, VMEXIT_REASON_INVLPG => {
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_RDPMC => {
            regs.rax = 0;
            regs.rdx = 0;
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_INIT_SIGNAL => {
            return true;
        },
        VMEXIT_REASON_VMCALL => {
            // Emulate nested L1 hypercall or report unsupported to guest
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_VMXON => {
            const nested_vmx = @import("../../vmm/nested_vmx.zig");
            if (getCurrentInstanceId()) |vmid| {
                _ = nested_vmx.handleVmxon(vmid, regs.rax) catch {};
                smp.serialAcquire();
                serialWrite("VMX: nested VMXON executed for VM ");
                printDec(vmid);
                serialWrite("\n");
                smp.serialRelease();
            }
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_VMXOFF => {
            const nested_vmx = @import("../../vmm/nested_vmx.zig");
            if (getCurrentInstanceId()) |vmid| {
                _ = nested_vmx.handleVmxoff(vmid) catch {};
                smp.serialAcquire();
                serialWrite("VMX: nested VMXOFF executed for VM ");
                printDec(vmid);
                serialWrite("\n");
                smp.serialRelease();
            }
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_VMPTRLD => {
            const nested_vmx = @import("../../vmm/nested_vmx.zig");
            if (getCurrentInstanceId()) |vmid| {
                _ = nested_vmx.handleVmptrld(vmid, regs.rax) catch {};
                smp.serialAcquire();
                serialWrite("VMX: nested VMPTRLD executed for VM ");
                printDec(vmid);
                serialWrite("\n");
                smp.serialRelease();
            }
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_VMCLEAR => {
            const nested_vmx = @import("../../vmm/nested_vmx.zig");
            if (getCurrentInstanceId()) |vmid| {
                _ = nested_vmx.handleVmclear(vmid, regs.rax) catch {};
            }
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_VMLAUNCH => {
            const nested_vmx = @import("../../vmm/nested_vmx.zig");
            if (getCurrentInstanceId()) |vmid| {
                _ = nested_vmx.handleVmlaunch(vmid) catch {};
                smp.serialAcquire();
                serialWrite("VMX: nested VMLAUNCH executed for VM ");
                printDec(vmid);
                serialWrite("\n");
                smp.serialRelease();
            }
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_VMRESUME => {
            const nested_vmx = @import("../../vmm/nested_vmx.zig");
            if (getCurrentInstanceId()) |vmid| {
                _ = nested_vmx.handleVmresume(vmid) catch {};
                smp.serialAcquire();
                serialWrite("VMX: nested VMRESUME executed for VM ");
                printDec(vmid);
                serialWrite("\n");
                smp.serialRelease();
            }
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_VMREAD => {
            regs.rax = 0;
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_VMWRITE => {
            advanceGuestRip();
            return true;
        },
        VMEXIT_REASON_APIC_ACCESS => {
            advanceGuestRip();
            return true;
        },
        else => {
            return false;
        },
    }
}

fn drainMicrovmIngress(active_vmid: ?u32) void {
    const vmid = active_vmid orelse return;
    while (microvm_bridge.dequeueForVm(vmid)) |entry| {
        virtio_net.injectPacket(entry.microvm_id, dipc.payloadSliceFromPage(vmx_hhdm_offset, entry.page_phys));
        dipc.freePageMessage(entry.page_phys);
    }
}

fn performWarmReboot(inst: *microvm_registry.Instance, regs: *GuestRegs) void {
    inst.reboot_requested = false;
    if (@import("builtin").is_test) return;
    if (inst.vm_profile == .uefi_fullvm) {
        stageUefiFullVmForInstance(inst, true) catch |err| {
            serialWrite("VMX: warm reboot restage failed err=0x");
            printHex(@intFromError(err));
            serialWrite("\n");
            return;
        };
    } else {
        virtio_blk.resetInstance(inst.instance_id);
        virtio_net.resetInstance(inst.instance_id);
        inst.devices.pic.reset();
        inst.devices.pit.reset();
        inst.devices.lapic.reset();
        inst.devices.pci.reset();
        stageGuestForInstance(inst) catch return;
    }

    const launch_state: *const GuestLaunchState = if (inst.instance_id < per_instance_launch_state.len)
        &per_instance_launch_state[inst.instance_id]
    else
        &staged_launch_state;
    loadGuestState(launch_state) catch {};
    regs.* = std.mem.zeroes(GuestRegs);
    regs.rsi = launch_state.guest_rsi;

    smp.serialAcquire();
    serialWrite("VMX: warm reboot completed for VM ");
    printDec(inst.instance_id);
    serialWrite("\n");
    smp.serialRelease();
}

pub fn restoreVmRegistersFromSnapshot(inst: *microvm_registry.Instance, snap: *const @import("../../vmm/vm_snapshot.zig").SnapshotManifest) void {
    if (inst.vmcs_phys) |vmcs| {
        _ = vmptrld(vmcs);
        _ = vmwrite(VMCS_GUEST_RIP, snap.guest_regs.rip);
        _ = vmwrite(VMCS_GUEST_RSP, snap.guest_regs.rsp);
        _ = vmwrite(VMCS_GUEST_RFLAGS, snap.guest_regs.rflags);
        if (snap.guest_regs.cr3 != 0) {
            _ = vmwrite(VMCS_GUEST_CR3, snap.guest_regs.cr3);
        }
    }
}

pub export fn catenary_vmx_vmexit_bridge(regs: *GuestRegs) u8 {
    const tsc_end = cpu.rdtsc();
    const core_id = smp.getCurrentCpuId();
    const active_vmid = if (core_id < smp.MAX_CPUS) current_instance_per_cpu[core_id] else current_instance_id;
    const start_tsc = if (core_id < smp.MAX_CPUS) per_cpu_vmx_start_tsc[core_id] else vmx_start_tsc;
    if (start_tsc != 0) {
        const delta = tsc_end -% start_tsc;
        if (active_vmid) |id| {
            if (microvm_registry.findMutable(id)) |inst| {
                inst.cpu_cycles += delta;
                inst.exit_count += 1;
            }
        }
    }

    // dispatch_vmexit (vmm/microvm_bridge.zig handles Blk/Telemetry;
    // virtio_net.zig handles TX packets from the guest and routes to netd).
    var should_resume = dispatchVmexit(regs);
    if (should_resume) {
        should_resume = if (active_vmid) |id|
            microvm_registry.isRunning(id)
        else
            false;
    }
    if (!should_resume) {
        if (active_vmid) |id| {
            if (microvm_registry.findMutable(id)) |inst| {
                if (inst.vmcs_phys) |vmcs| {
                    if (vmclear(vmcs)) {
                        inst.vmcs_active_cpu = null;
                    }
                }
            }
            if (!microvm_registry.completeStop(id)) {
                _ = microvm_registry.fail(id);
            }
        }
        if (core_id < smp.MAX_CPUS) {
            current_instance_per_cpu[core_id] = null;
        }
        if (current_instance_id == active_vmid) {
            current_instance_id = null;
        }
    }

    if (should_resume) {
        drainMicrovmIngress(active_vmid);
    }

    // Broadcast telemetry immediately on early exits or final exit (for single-exit test guests),
    // and throttle during continuous Linux execution so dashd's receive queue is not flooded.
    if (vmexit_count <= 4 or !should_resume or (vmexit_count & 0xFF) == 0) {
        microvm_bridge.broadcastTelemetryFromContext();
    }

    if (should_resume) {
        if (active_vmid) |id| {
            if (microvm_registry.findMutable(id)) |inst| {
                if (inst.vmcs_phys) |vmcs| {
                    if (vmptrld(vmcs)) {
                        inst.vmcs_active_cpu = @intCast(core_id);
                    }
                }
                if (inst.reboot_requested) {
                    performWarmReboot(inst, regs);
                }
                if (inst.pause_requested) {
                    inst.is_paused = true;
                    inst.state = .paused;
                    smp.serialAcquire();
                    serialWrite("VMX: VM ");
                    printDec(inst.instance_id);
                    serialWrite(" execution paused\n");
                    smp.serialRelease();
                    return 0; // Suspend VM resume
                }
            }
        }
        tryInjectTimerIrq();
        const now = cpu.rdtsc();
        if (core_id < smp.MAX_CPUS) {
            per_cpu_vmx_start_tsc[core_id] = now;
        }
        vmx_start_tsc = now;
        return 1;
    }

    // Capture exit state back into thread-local/instance-local if we were scheduled.
    if (core_id < smp.MAX_CPUS) {
        per_cpu_vmx_start_tsc[core_id] = 0;
    }
    vmx_start_tsc = 0;
    return 0;
}

pub export fn catenary_vmx_vmresume_failed() void {
    serialWrite("VMX: vmresume failed err=0x");
    printHex(vmread(VMCS_VM_INSTRUCTION_ERROR) orelse 0);
    serialWrite("\n");
}

fn vmexitStub() callconv(.naked) noreturn {
    asm volatile (
        \\pushq %r15
        \\pushq %r14
        \\pushq %r13
        \\pushq %r12
        \\pushq %r11
        \\pushq %r10
        \\pushq %r9
        \\pushq %r8
        \\pushq %rdi
        \\pushq %rsi
        \\pushq %rbp
        \\pushq %rdx
        \\pushq %rcx
        \\pushq %rbx
        \\pushq %rax
        \\movq %rsp, %rdi
        \\callq catenary_vmx_vmexit_bridge
        \\testb %al, %al
        \\jz 2f
        \\popq %rax
        \\popq %rbx
        \\popq %rcx
        \\popq %rdx
        \\popq %rbp
        \\popq %rsi
        \\popq %rdi
        \\popq %r8
        \\popq %r9
        \\popq %r10
        \\popq %r11
        \\popq %r12
        \\popq %r13
        \\popq %r14
        \\popq %r15
        \\vmresume
        \\setna %al
        \\testb %al, %al
        \\jz 2f
        \\callq catenary_vmx_vmresume_failed
        \\2:
        \\addq $120, %rsp
        \\andq $-16, %rsp
        \\callq catenary_vmx_guest_done
    );
}

pub fn injectGuestInterrupt(vmid: u32, irq_or_vector: u8) void {
    const active = getCurrentInstanceId() orelse return;
    if (active != vmid) return;
    const maybe_inst = microvm_registry.findMutable(vmid);
    const vector: u8 = if (irq_or_vector < 8) blk: {
        const imr = if (maybe_inst) |inst| inst.devices.pic.master_imr else pic_master_imr;
        if ((imr & (@as(u8, 1) << @intCast(irq_or_vector))) != 0) return;
        const base = if (maybe_inst) |inst| inst.devices.pic.master_vector_base else pic_master_vector_base;
        break :blk base +% irq_or_vector;
    } else if (irq_or_vector < 16) blk: {
        const slave_line: u3 = @intCast(irq_or_vector - 8);
        const s_imr = if (maybe_inst) |inst| inst.devices.pic.slave_imr else pic_slave_imr;
        if ((s_imr & (@as(u8, 1) << slave_line)) != 0) return;
        const base = if (maybe_inst) |inst| inst.devices.pic.slave_vector_base else pic_slave_vector_base;
        break :blk base +% (irq_or_vector - 8);
    } else irq_or_vector;
    if (vector < 32) return;
    const interruptibility = vmread(VMCS_GUEST_INTERRUPTIBILITY) orelse return;
    const rflags = vmread(VMCS_GUEST_RFLAGS) orelse return;
    if ((rflags & (1 << 9)) == 0 or (interruptibility & 0x3) != 0) return;
    const entry_info: u64 = @as(u64, vector) | (VM_ENTRY_INTR_TYPE_EXTERNAL << 8) | (1 << 31);
    _ = vmwrite(VMCS_VM_ENTRY_INTR_INFO, entry_info);
}

pub fn isVmxSupported() bool {
    const leaf1 = cpu.cpuid(1, 0);
    if ((leaf1.ecx & (@as(u32, 1) << 5)) == 0) return false;

    const feature_control = cpu.rdmsr(IA32_FEATURE_CONTROL);
    const lock_bit_set = (feature_control & 0x1) != 0;
    const vmxon_outside_smx = (feature_control & (1 << 2)) != 0;
    if (lock_bit_set and !vmxon_outside_smx) return false;
    return true;
}

pub fn initApCore(ap_idx: usize) void {
    if (ap_idx >= smp.MAX_CPUS) return;
    if (!build_options.vmm_active) return;
    if (!isVmxSupported()) {
        smp.serialAcquire();
        defer smp.serialRelease();
        for ("vmx: AP core ") |c| cpu.outb(0x3F8, c);
        printDec(ap_idx);
        for (" VMX unsupported\n") |c| cpu.outb(0x3F8, c);
        return;
    }

    // 0. Ensure CR0.NE (bit 5) is enabled (Intel SDM Vol 3C Section 31.1.1: CR0.NE must be 1 in VMX operation)
    cpu.writeCr0(cpu.readCr0() | (@as(u64, 1) << 5));

    // 1. Enable CR4.VMXE
    cpu.writeCr4(cpu.readCr4() | CR4_VMXE);

    // 2. Enable CR4.OSXSAVE if supported
    if (cpu.cpuid(1, 0).ecx & (@as(u32, 1) << 26) != 0) {
        cpu.writeCr4(cpu.readCr4() | cpu.CR4_OSXSAVE);
    }

    // 3. Ensure IA32_FEATURE_CONTROL lock and SMX bits
    ensureFeatureControl() catch |err| {
        smp.serialAcquire();
        defer smp.serialRelease();
        for ("vmx: AP core ") |c| cpu.outb(0x3F8, c);
        printDec(ap_idx);
        for (" feature control failed: ") |c| cpu.outb(0x3F8, c);
        for (@errorName(err)) |c| cpu.outb(0x3F8, c);
        cpu.outb(0x3F8, '\n');
        return;
    };

    // 4. Ensure per-core VMXON region
    const basic = cpu.rdmsr(IA32_VMX_BASIC);
    const revision: u32 = @as(u32, @truncate(basic & 0x7FFF_FFFF));
    const vmxon_phys = ensureRegion(&per_cpu_vmxon[ap_idx], vmx_hhdm_offset, revision) catch |err| {
        smp.serialAcquire();
        defer smp.serialRelease();
        for ("vmx: AP core ") |c| cpu.outb(0x3F8, c);
        printDec(ap_idx);
        for (" alloc vmxon failed: ") |c| cpu.outb(0x3F8, c);
        for (@errorName(err)) |c| cpu.outb(0x3F8, c);
        cpu.outb(0x3F8, '\n');
        return;
    };

    // 5. Ensure per-core host exit stack
    _ = ensureHostStackForCpu(ap_idx) catch |err| {
        smp.serialAcquire();
        defer smp.serialRelease();
        for ("vmx: AP core ") |c| cpu.outb(0x3F8, c);
        printDec(ap_idx);
        for (" alloc host stack failed: ") |c| cpu.outb(0x3F8, c);
        for (@errorName(err)) |c| cpu.outb(0x3F8, c);
        cpu.outb(0x3F8, '\n');
        return;
    };

    // 6. Execute VMXON
    if (!vmxon(vmxon_phys)) {
        smp.serialAcquire();
        defer smp.serialRelease();
        for ("vmx: AP core ") |c| cpu.outb(0x3F8, c);
        printDec(ap_idx);
        for (" vmxon failed\n") |c| cpu.outb(0x3F8, c);
        return;
    }

    // 7. Test harness milestone log: "smp: AP core <id> VMX active"
    smp.serialAcquire();
    defer smp.serialRelease();
    for ("smp: AP core ") |c| cpu.outb(0x3F8, c);
    printDec(ap_idx);
    for (" VMX active\n") |c| cpu.outb(0x3F8, c);
}

fn handleVmExit(instance: *microvm_registry.Instance) !void {
    _ = instance;
    // The ASM bridge calls dispatchVmexit and tryInjectTimerIrq.
    // If it returns 0, we are here.
}

pub fn init(memmap: *limine.MemmapResponse, hhdm_offset: u64, table: *const endpoint_table.EndpointTable) !void {
    _ = memmap;
    vmx_hhdm_offset = hhdm_offset;
    vmx_host_cr3 = cpu.readCr3();
    microvm_bridge.setBridgeContext(hhdm_offset, table);
    virtio_net.hhdm_offset = hhdm_offset;
    virtio_net.system_endpoint_table = table;
    virtio_net.gpa_to_hpa_fn = translateGpaToHpa;

    if (!isVmxSupported()) return error.VmxUnsupported;

    cpu.writeCr4(cpu.readCr4() | CR4_VMXE);
    // Enable OSXSAVE so the host can execute XSETBV when handling guest
    // XSETBV VMEXITs.  loadHostState() captures CR4 into VMCS_HOST_CR4,
    // so this bit is also restored after every VMEXIT.
    if (cpu.cpuid(1, 0).ecx & (@as(u32, 1) << 26) != 0) {
        cpu.writeCr4(cpu.readCr4() | cpu.CR4_OSXSAVE);
    }
    try ensureFeatureControl();

    const vmx_basic = cpu.rdmsr(IA32_VMX_BASIC);
    const revision: u32 = @as(u32, @truncate(vmx_basic & 0x7FFF_FFFF));
    vmxon_region_phys = pmm.allocPage();
    const vmxon_region = vmx_hhdm_offset + vmxon_region_phys.?;
    @as(*u32, @ptrFromInt(vmxon_region)).* = revision;
    per_cpu_vmxon[0] = vmxon_region_phys;
    _ = try ensureHostStackForCpu(0);

    if (!vmxon(vmxon_region_phys.?)) return error.VmxonFailed;

    serialWrite("vmx: global vmxon active\n");

    const default_vm_name: [32]u8 = "linux-vm-1".* ++ @as([22]u8, @splat(0));
    const default_vm_container: [32]u8 = "oci-demo".* ++ @as([24]u8, @splat(0));
    if (microvm_registry.create(default_vm_name, default_vm_container, GUEST_POOL_PAGES, 1, 0, 0, 0, 0)) |id| {
        current_instance_id = id;
        current_instance_per_cpu[0] = id;
    } else {
        serialWrite("VMX: failed to create microvm instance\n");
        return error.OutOfMemory;
    }

    resetGuestDeviceState();

    const inst = microvm_registry.findMutable(current_instance_id.?) orelse return error.OutOfMemory;
    stageGuestForInstance(inst) catch {
        serialWrite("VMX: stage failed\n");
        return;
    };

    if (build_options.services_active) {
        serialWrite("VMX: staged guest ready; waiting for service launch\n");
        return;
    }

    const scheduler = @import("../../kernel/scheduler.zig");
    _ = scheduler.spawnWithVmx(null, true, current_instance_id.?, 0, inst.pinned_cpu) catch {
        serialWrite("VMX: failed to spawn vmx thread\n");
    };
}

pub fn launchStagedInstance() !u32 {
    const id = getCurrentInstanceId() orelse current_instance_id orelse return error.Unsupported;
    const inst = microvm_registry.findMutable(id) orelse return error.Unsupported;

    if (inst.state != .created) return error.Unsupported;
    if (!microvm_registry.start(id)) return error.Unsupported;

    const scheduler = @import("../../kernel/scheduler.zig");
    _ = try scheduler.spawnWithVmx(null, true, id, 0, inst.pinned_cpu);
    return id;
}

pub fn setupVmcs(instance: *microvm_registry.Instance, core_id: usize) !void {
    if (core_id >= smp.MAX_CPUS) return error.Unsupported;

    const basic = cpu.rdmsr(IA32_VMX_BASIC);
    const revision_id: u32 = @as(u32, @truncate(basic & 0x7FFF_FFFF));

    _ = try ensureHostStackForCpu(core_id);

    if (instance.ept_pml4_phys == null) {
        instance.ept_pml4_phys = pmm.allocPage() orelse return error.OutOfMemory;
        clearPage(instance.ept_pml4_phys.?);
    }

    _ = try ensureRegion(&instance.vmcs_phys, vmx_hhdm_offset, revision_id);

    if (!vmclear(instance.vmcs_phys.?)) return error.VmclearFailed;
    instance.vmcs_active_cpu = null;
    if (!vmptrld(instance.vmcs_phys.?)) return error.VmptrldFailed;
    instance.vmcs_active_cpu = @intCast(smp.getCurrentCpuId());

    current_instance_per_cpu[core_id] = instance.instance_id;
    if (core_id == smp.getCurrentCpuId()) {
        current_instance_id = instance.instance_id;
    }

    try loadControlFields(basic, instance);
    try loadHostStateForCore(core_id);
    const launch_state: *const GuestLaunchState = if (instance.instance_id < per_instance_launch_state.len and per_instance_launch_state[instance.instance_id].guest_rip != 0)
        &per_instance_launch_state[instance.instance_id]
    else
        &staged_launch_state;
    try loadGuestState(launch_state);

    if (core_id != smp.getCurrentCpuId()) {
        if (vmclear(instance.vmcs_phys.?)) {
            instance.vmcs_active_cpu = null;
        }
        const caller_core = smp.getCurrentCpuId();
        if (caller_core < smp.MAX_CPUS) {
            if (current_instance_per_cpu[caller_core]) |prev_id| {
                if (microvm_registry.findMutable(prev_id)) |prev_inst| {
                    if (prev_inst.vmcs_phys) |prev_vmcs| {
                        if (vmptrld(prev_vmcs)) {
                            prev_inst.vmcs_active_cpu = @intCast(caller_core);
                        }
                    }
                }
            }
        }
    }
}

pub fn setupVmcsForCpu(instance: *microvm_registry.Instance, core_id: usize) !void {
    return setupVmcs(instance, core_id);
}

pub fn resumeInstance(instance: *microvm_registry.Instance) !void {
    const core_id = smp.getCurrentCpuId();
    if (core_id < smp.MAX_CPUS) {
        current_instance_per_cpu[core_id] = instance.instance_id;
    }
    current_instance_id = instance.instance_id;

    const launch_rsi: u64 = getLaunchRsiForInstance(instance);

    if (instance.exit_count == 0) {
        if (instance.vmcs_phys == null) {
            try setupVmcs(instance, core_id);
        } else {
            if (!vmptrld(instance.vmcs_phys.?)) return error.VmptrldFailed;
            instance.vmcs_active_cpu = @intCast(core_id);
        }

        smp.serialAcquire();
        serialWrite("[SMP core ");
        printDec(core_id);
        serialWrite("] entering guest via vmlaunch\n");
        serialWrite("VMX: launching VM ");
        printDec(instance.instance_id);
        serialWrite(" on core ");
        printDec(core_id);
        serialWrite("\n");
        serialWrite("VMX: entering guest via vmlaunch\n");
        smp.serialRelease();

        const now = cpu.rdtsc();
        if (core_id < smp.MAX_CPUS) {
            per_cpu_vmx_start_tsc[core_id] = now;
        }
        vmx_start_tsc = now;
        if (!vmlaunchWithGuestRsi(launch_rsi)) {
            serialWrite("VMX: vmlaunch failed err=0x");
            printHex(vmread(VMCS_VM_INSTRUCTION_ERROR) orelse 0);
            serialWrite("\n");
            if (instance.vmcs_phys) |vmcs| {
                if (vmclear(vmcs)) instance.vmcs_active_cpu = null;
            }
            return error.VmlaunchFailed;
        }
        return;
    }

    const tsc_start = cpu.rdtsc();

    // Switch to this instance's VMCS
    if (!vmptrld(instance.vmcs_phys.?)) return error.VmptrldFailed;
    instance.vmcs_active_cpu = @intCast(core_id);

    smp.serialAcquire();
    serialWrite("[SMP core ");
    printDec(core_id);
    serialWrite("] entering guest via vmresume\n");
    smp.serialRelease();

    const resume_now = cpu.rdtsc();
    if (core_id < smp.MAX_CPUS) {
        per_cpu_vmx_start_tsc[core_id] = resume_now;
    }
    vmx_start_tsc = resume_now;

    if (!vmresumeWithGuestRsi(launch_rsi)) {
        serialWrite("VMX: vmresume failed err=0x");
        printHex(vmread(VMCS_VM_INSTRUCTION_ERROR) orelse 0);
        serialWrite("\n");
        if (instance.vmcs_phys) |vmcs| {
            if (vmclear(vmcs)) instance.vmcs_active_cpu = null;
        }
        return error.VmresumeFailed;
    }

    const tsc_end = cpu.rdtsc();
    instance.cpu_cycles += (tsc_end - tsc_start);
    instance.exit_count += 1;

    // Handle the VM-exit (ASM bridge logic if we return here)
    try handleVmExit(instance);
}

fn freeInstancePoolPage(instance: *microvm_registry.Instance, phys: u64) void {
    clearPage(phys);
    pmm.freePage(phys);
    if (instance.pool_used > 0) {
        instance.pool_used -= 1;
    }
}

fn freeEptHierarchy(instance: *microvm_registry.Instance, root_phys: u64) void {
    const pml4 = eptTablePtr(root_phys);
    for (0..512) |idx4| {
        const pml4e = pml4[idx4];
        if ((pml4e & 0x7) == 0) continue;
        const pdpt_phys = pml4e & 0x000F_FFFF_FFFF_F000;
        const pdpt = eptTablePtr(pdpt_phys);
        for (0..512) |idx3| {
            const pdpte = pdpt[idx3];
            if ((pdpte & 0x7) == 0) continue;
            if ((pdpte & (1 << 7)) != 0) {
                freeInstancePoolPage(instance, pdpte & 0x000F_FFFF_C000_0000);
                continue;
            }
            const pd_phys = pdpte & 0x000F_FFFF_FFFF_F000;
            const pd = eptTablePtr(pd_phys);
            for (0..512) |idx2| {
                const pde = pd[idx2];
                if ((pde & 0x7) == 0) continue;
                if ((pde & (1 << 7)) != 0) {
                    freeInstancePoolPage(instance, pde & 0x000F_FFFF_FFE0_0000);
                    continue;
                }
                const pt_phys = pde & 0x000F_FFFF_FFFF_F000;
                const pt = eptTablePtr(pt_phys);
                for (0..512) |idx1| {
                    const pte = pt[idx1];
                    if ((pte & 0x7) == 0) continue;
                    freeInstancePoolPage(instance, pte & 0x000F_FFFF_FFFF_F000);
                }
                freeInstancePoolPage(instance, pt_phys);
            }
            freeInstancePoolPage(instance, pd_phys);
        }
        freeInstancePoolPage(instance, pdpt_phys);
    }
    clearPage(root_phys);
    pmm.freePage(root_phys);
}

pub fn reclaimInstanceResources(instance: *microvm_registry.Instance) bool {
    if (instance.state == .running or instance.state == .stopping) return false;
    if (!@import("builtin").is_test) {
        const scheduler = @import("../../kernel/scheduler.zig");
        if (scheduler.hasActiveVmxThread(instance.instance_id)) return false;
    }

    if (instance.vmcs_phys) |vmcs| {
        if (instance.vmcs_active_cpu) |active_cpu| {
            if (@import("builtin").is_test) {
                instance.vmcs_active_cpu = null;
            } else {
                const current_cpu = smp.getCurrentCpuId();
                if (active_cpu != @as(u8, @intCast(current_cpu))) return false;
                if (!vmclear(vmcs)) return false;
                instance.vmcs_active_cpu = null;
            }
        }
    }

    if (instance.ept_pml4_phys) |root_phys| {
        if (!invalidateEptRoot(root_phys)) return false;
        freeEptHierarchy(instance, root_phys);
        instance.ept_pml4_phys = null;
    }

    if (instance.vmcs_phys) |vmcs| {
        clearPage(vmcs);
        pmm.freePage(vmcs);
        instance.vmcs_phys = null;
    }

    if (instance.pool_phys) |pool| {
        clearPage(pool);
        pmm.freePage(pool);
        instance.pool_phys = null;
    }

    if (instance.pool_used != 0) return false;

    if (!@import("builtin").is_test) {
        const scheduler = @import("../../kernel/scheduler.zig");
        if (!scheduler.reclaimVmxThreadForVm(instance.instance_id)) return false;
    }

    microvm_bridge.dropForVm(instance.instance_id);
    virtio_net.resetInstance(instance.instance_id);
    virtio_blk.resetInstance(instance.instance_id);
    efi_vars.resetInstance(instance.instance_id);
    vtpm.resetInstance(instance.instance_id);
    buffer_grant.releaseAllForVm(instance.instance_id);
    if (instance.instance_id < per_instance_launch_state.len) {
        per_instance_launch_state[instance.instance_id] = .{};
    }
    if (instance.instance_id < vm_serial_line_len.len) {
        vm_serial_line_len[instance.instance_id] = 0;
    }
    return true;
}

pub fn reclaimInstanceById(instance_id: u32) bool {
    const inst = microvm_registry.findMutable(instance_id) orelse return false;
    return reclaimInstanceResources(inst);
}

test "VM resource reclamation zeroes and frees EPT tables, guest leaves, and VMCS" {
    const TestState = struct {
        var vmx_reclaim_test_backing: [32][4096]u8 align(4096) = undefined;
    };
    @memset(std.mem.asBytes(&TestState.vmx_reclaim_test_backing), 0);
    const hhdm = @intFromPtr(&TestState.vmx_reclaim_test_backing);
    var entry = limine.MemmapEntry{
        .base = 0,
        .length = @sizeOf(@TypeOf(TestState.vmx_reclaim_test_backing)),
        .kind = limine.MEMMAP_USABLE,
    };
    var entries = [_]*limine.MemmapEntry{&entry};
    var memmap = limine.MemmapResponse{
        .revision = 0,
        .entry_count = 1,
        .entries = @ptrCast(&entries),
    };
    pmm.init(&memmap, hhdm);
    setHhdmOffset(hhdm);
    defer setHhdmOffset(0);

    microvm_registry.init();
    virtio_net.init();
    virtio_blk.init();
    microvm_bridge.init();

    const free_before = pmm.getFreePages();
    const vm_name: [32]u8 = @splat(0);
    const vm_container: [32]u8 = @splat(0);
    const vmid = microvm_registry.create(vm_name, vm_container, 16, 1, 0, 0, 0, 0) orelse return error.TestUnexpectedResult;
    const inst = microvm_registry.findMutable(vmid) orelse return error.TestUnexpectedResult;

    const gpa0_hpa = try ensureGuestPageForInstance(inst, 0x0000);
    const gpa1_hpa = try ensureGuestPageForInstance(inst, 0x1000);
    const vmcs_page = pmm.allocPage() orelse return error.TestUnexpectedResult;
    inst.vmcs_phys = vmcs_page;
    inst.state = .running;

    try copyIntoGuestForInstance(inst, 0x0000, "secret-guest-ram");
    try std.testing.expect(inst.ept_pml4_phys != null);
    try std.testing.expect(inst.pool_used > 0);
    try std.testing.expect(pmm.getFreePages() < free_before);

    // Running VM cannot be reclaimed or deleted.
    try std.testing.expect(!reclaimInstanceById(vmid));
    try std.testing.expect(!microvm_registry.delete(vmid));

    // Stop and complete VM exit, then reclaim and delete.
    try std.testing.expect(microvm_registry.stop(vmid));
    try std.testing.expect(microvm_registry.completeStop(vmid));
    try std.testing.expect(reclaimInstanceById(vmid));
    try std.testing.expectEqual(@as(?u64, null), inst.ept_pml4_phys);
    try std.testing.expectEqual(@as(?u64, null), inst.vmcs_phys);
    try std.testing.expectEqual(@as(u64, 0), inst.pool_used);
    try std.testing.expectEqual(free_before, pmm.getFreePages());

    const zero_page: [4096]u8 = @splat(0);
    const page0_slice = @as([*]const u8, @ptrFromInt(gpa0_hpa + hhdm))[0..4096];
    const page1_slice = @as([*]const u8, @ptrFromInt(gpa1_hpa + hhdm))[0..4096];
    try std.testing.expectEqualSlices(u8, &zero_page, page0_slice);
    try std.testing.expectEqualSlices(u8, &zero_page, page1_slice);
    try std.testing.expect(microvm_registry.delete(vmid));
}
