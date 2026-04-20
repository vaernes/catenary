const std = @import("std");
const build_options = @import("build_options");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const host_paging = @import("paging.zig");
const limine = @import("../../kernel/limine.zig");
const pmm = @import("../../kernel/pmm.zig");
const linux_boot = @import("../../vmm/linux_boot.zig");
const microvm_registry = @import("../../vmm/microvm_registry.zig");
const virtio_net = @import("../../vmm/virtio_net.zig");
const virtio_blk = @import("../../vmm/virtio_blk.zig");
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

const DEFAULT_CMDLINE = "console=ttyS0,115200 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel nokaslr noapictimer rdinit=/init";
const GUEST_BOOT_GDT_GPA: u64 = 0x0000_6000;
const GUEST_EBDA_SEGMENT: u16 = 0x9FC0;
const GUEST_BASE_MEMORY_KB: u16 = 639;
const GUEST_IDENTITY_PD_TABLES: usize = 8; // 8 * 1GiB mapped via 2MiB leaves
const GUEST_IDENTITY_MAP_BYTES: u64 = @as(u64, GUEST_IDENTITY_PD_TABLES) * 1024 * 1024 * 1024;
const EPT_PREFAULT_WINDOW_PAGES_DEMO: usize = 512; // 512 * 4KiB = 2MiB
const EPT_PREFAULT_WINDOW_PAGES_LINUX: usize = 512; // map 2 MiB per Linux EPT violation to reduce boot-time VMEXIT churn
const MAX_GUEST_MAPS: usize = 262144;
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
var lapic_regs: [LAPIC_REG_WORDS]u32 = [_]u32{0} ** LAPIC_REG_WORDS;
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
var vmx_msr_bitmap align(4096) = [_]u8{0} ** 4096;

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

fn pciConfigReadDword(addr: u32) u32 {
    if ((addr & PCI_CONFIG_ADDRESS_ENABLE) == 0) return 0xFFFF_FFFF;

    const bus = @as(u8, @truncate(addr >> 16));
    const device = @as(u5, @truncate((addr >> 11) & 0x1F));
    const function = @as(u3, @truncate((addr >> 8) & 0x7));
    const reg = @as(u8, @truncate(addr & 0xFC));

    if (bus != 0 or device != 0 or function != 0) return 0xFFFF_FFFF;

    return switch (reg) {
        0x00 => PCI_ROOT_VENDOR_DEVICE,
        0x04 => pci_root_command,
        0x08 => PCI_ROOT_CLASS_REVISION,
        0x0C => 0,
        0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x30, 0x34, 0x3C => 0,
        else => 0,
    };
}

fn pciConfigWriteDword(addr: u32, value: u32, mask: u32) void {
    if ((addr & PCI_CONFIG_ADDRESS_ENABLE) == 0) return;

    const bus = @as(u8, @truncate(addr >> 16));
    const device = @as(u5, @truncate((addr >> 11) & 0x1F));
    const function = @as(u3, @truncate((addr >> 8) & 0x7));
    const reg = @as(u8, @truncate(addr & 0xFC));

    if (bus != 0 or device != 0 or function != 0) return;

    switch (reg) {
        0x04 => {
            const current = @as(u32, pci_root_command);
            const merged = (current & ~mask) | (value & mask);
            pci_root_command = @as(u16, @truncate(merged & 0x0000_FFFF));
        },
        else => {},
    }
}

fn handlePciConfigIo(port: u16, is_in: bool, size: u8, regs: *GuestRegs) bool {
    if (port == PCI_CONFIG_ADDRESS_PORT and size == 4) {
        if (is_in) {
            writeGuestIoValue(regs, 4, pci_config_address);
        } else {
            pci_config_address = readGuestIoValue(regs, 4) & 0x8000_FFFC;
        }
        return true;
    }

    if (port >= PCI_CONFIG_DATA_PORT and port <= PCI_CONFIG_DATA_PORT + 3) {
        const data_offset = @as(u8, @truncate(port - PCI_CONFIG_DATA_PORT));
        const shift = @as(u5, @truncate(data_offset * 8));
        const full = pciConfigReadDword(pci_config_address);
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
            pciConfigWriteDword(pci_config_address, shifted, mask);
        }
        return true;
    }

    return false;
}

fn lapicRegIndex(offset: u64) ?usize {
    if (offset >= LAPIC_MMIO_SIZE or (offset & 0xF) != 0) return null;
    return @as(usize, @intCast(offset >> 2));
}

fn lapicWriteRaw(offset: u32, value: u32) void {
    const idx = lapicRegIndex(@as(u64, offset)) orelse return;
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
    vmx_start_tsc = 0;
    ept_violation_count = 0;
    guest_linux_entry_active = false;
}

fn translateHostVirtToPhys(virt: u64) ?u64 {
    return host_paging.translate(vmx_hhdm_offset, virt);
}

fn allocFromPool() VmxError!u64 {
    const instance_id = current_instance_id orelse return error.VmxonFailed;
    const inst = microvm_registry.findMutable(instance_id) orelse return error.VmxonFailed;

    if (inst.pool_phys == null) {
        // Allocate a contiguous block for the pool if not already present
        // In a real system we might use smaller chunks, but for now we follow the 1:1 mapping goal.
        // pmm.allocPages(inst.mem_pages) would be ideal, but assume pmm.allocPage() for now as we did before.
        // Actually, previous code used a static [GUEST_POOL_PAGES]u8 pool.
        // To isolate, we should allocate uniquely per instance.
    }

    if (inst.pool_used >= inst.mem_pages) {
        serialWrite("VMX: instance guest pool exhausted used=0x");
        printHex(inst.pool_used);
        serialWrite("\n");
        return error.OutOfMemory;
    }

    // For now, satisfy one-by-one from PMM to ensure isolation.
    const phys = pmm.allocPage() orelse return error.OutOfMemory;
    inst.pool_used += 1;
    clearPage(phys);
    return phys;
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

const GuestPageMap = struct {
    gpa: u64,
    hpa: u64,
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
    layout: linux_boot.LaunchLayout,
    guest_rip: u64,
    guest_rsp: u64,
    guest_cr3: u64,
    boot_params_gpa: u64,
    guest_rsi: u64,
};

var vmxon_region_phys: ?u64 = null;
var microvm_table: ?*void = null;
var vmx_host_stack_phys: ?u64 = null;

var current_instance_id: ?u32 = null;

var vmx_hhdm_offset: u64 = 0;

var guest_maps: [MAX_GUEST_MAPS]GuestPageMap = undefined;
var guest_map_count: usize = 0;
var vmexit_count: usize = 0;
var vmx_start_tsc: u64 = 0;
var ept_violation_count: u64 = 0;
var guest_linux_entry_active: bool = false;
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
var staged_launch_state: GuestLaunchState = .{
    .layout = .{
        .boot_params_gpa = 0,
        .cmdline_gpa = 0,
        .kernel_load_gpa = 0,
        .guest_stack_top_gpa = 0,
        .guest_pml4_gpa = 0,
        .guest_pdpt_gpa = 0,
        .guest_pd_gpa = 0,
    },
    .guest_rip = 0,
    .guest_rsp = 0,
    .guest_cr3 = 0,
    .boot_params_gpa = 0,
    .guest_rsi = 0,
};

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
    for (s) |c| {
        cpu.outb(0x3F8, c);
    }
}

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        cpu.outb(0x3F8, hex[nibble]);
        if (shift >= 4) shift -= 4;
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

fn allocZeroedPage() VmxError!u64 {
    // Replace PMM allocation with static pool allocation to avoid corruption
    // of live kernel memory by guest staging.
    return try allocFromPool();
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

fn eptMapPage(gpa: u64, hpa: u64) VmxError!void {
    try eptMapPageEx(gpa, hpa, EPT_LEAF_FLAGS);
}

fn eptMapPageEx(gpa: u64, hpa: u64, flags: u64) VmxError!void {
    if (comptime !VMX_USE_EPT) {
        return;
    }

    const instance_id = current_instance_id orelse return error.Unsupported;
    const instance = (microvm_registry.findMutable(instance_id) orelse return error.Unsupported);
    if (instance.ept_pml4_phys == null) {
        instance.ept_pml4_phys = pmm.allocPage() orelse return error.OutOfMemory;
        clearPage(instance.ept_pml4_phys.?);
    }

    const root = instance.ept_pml4_phys.?;
    const pml4 = eptTablePtr(root);
    const pml4e = &pml4[@as(usize, @intCast((gpa >> 39) & 0x1FF))];
    const pdpt = try eptEnsureTable(pml4e);

    const pdpte = &pdpt[@as(usize, @intCast((gpa >> 30) & 0x1FF))];
    const pd = try eptEnsureTable(pdpte);

    const pde = &pd[@as(usize, @intCast((gpa >> 21) & 0x1FF))];
    const pt = try eptEnsureTable(pde);

    const pte = &pt[@as(usize, @intCast((gpa >> 12) & 0x1FF))];
    pte.* = (hpa & 0x000F_FFFF_FFFF_F000) | flags;
}

fn findGuestPageHpa(gpa: u64) ?u64 {
    const aligned = gpa & 0x000F_FFFF_FFFF_F000;
    var i: usize = 0;
    while (i < guest_map_count) : (i += 1) {
        if (guest_maps[i].gpa == aligned) return guest_maps[i].hpa;
    }
    return null;
}

fn ensureGuestPage(gpa: u64) VmxError!u64 {
    const aligned = gpa & 0x000F_FFFF_FFFF_F000;
    if (findGuestPageHpa(aligned)) |hpa| return hpa;
    if (guest_linux_entry_active and aligned >= linux_boot.default_guest_ram_bytes) {
        // Allow mapping standard APIC/IOAPIC MMIO area so the guest can read 0 instead of crashing.
        if (aligned < 0xFEC00000 or aligned >= 0xFF000000) {
            serialWrite("VMX: guest ram limit exceeded gpa=0x");
            printHex(aligned);
            serialWrite(" limit=0x");
            printHex(linux_boot.default_guest_ram_bytes);
            serialWrite("\n");
            return error.GuestTooLarge;
        }
    }
    if (guest_map_count >= guest_maps.len) {
        serialWrite("VMX: guest map overflow used=0x");
        printHex(guest_map_count);
        serialWrite(" total=0x");
        printHex(guest_maps.len);
        serialWrite("\n");
        return error.GuestMapOverflow;
    }

    const hpa = try allocZeroedPage();
    try eptMapPage(aligned, hpa);
    guest_maps[guest_map_count] = .{ .gpa = aligned, .hpa = hpa };
    guest_map_count += 1;
    return hpa;
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

fn stageLinuxGuest() VmxError!void {
    serialWrite("VMX: stage S0\n");
    const image = guest_image_blob.get();
    serialWrite("VMX: stage S1\n");
    serialWrite("VMX: image ptr=0x");
    printHex(@intFromPtr(image.ptr));
    serialWrite(" len=0x");
    printHex(image.len);
    serialWrite("\n");
    linux_boot.parseBzImageInto(&staged_parsed_image, image) catch {
        serialWrite("VMX: stage S2 fallback guest payload\n");

        const fallback_layout: linux_boot.LaunchLayout = .{
            .boot_params_gpa = linux_boot.default_boot_params_gpa,
            .cmdline_gpa = linux_boot.default_cmdline_gpa,
            .kernel_load_gpa = linux_boot.kernel_load_min_gpa,
            .guest_stack_top_gpa = linux_boot.default_guest_stack_top_gpa,
            .guest_pml4_gpa = linux_boot.default_guest_pml4_gpa,
            .guest_pdpt_gpa = linux_boot.default_guest_pdpt_gpa,
            .guest_pd_gpa = linux_boot.default_guest_pd_gpa,
        };

        return stageFallbackGuest(fallback_layout);
    };

    serialWrite("VMX: stage S2 parsed bzImage\n");
    const layout = linux_boot.defaultLayout(&staged_parsed_image);

    return stageParsedGuest(&staged_parsed_image, layout);
}

fn stageFallbackGuest(layout: linux_boot.LaunchLayout) VmxError!void {
    serialWrite("VMX: stage S3\n");

    // Required pages for boot params, cmdline, stack, and guest paging roots.
    try seedGuestLowMemoryPage();
    try buildGuestBootGdt();
    _ = try ensureGuestPage(layout.boot_params_gpa);
    _ = try ensureGuestPage(layout.cmdline_gpa);
    _ = try ensureGuestPage(layout.guest_stack_top_gpa - pmm.PAGE_SIZE);
    _ = try ensureGuestPage(layout.guest_pml4_gpa);
    _ = try ensureGuestPage(layout.guest_pdpt_gpa);
    _ = try ensureGuestPage(layout.guest_pd_gpa);
    serialWrite("VMX: stage S4\n");

    const boot_params_page: [linux_boot.zero_page_size]u8 = [_]u8{0} ** linux_boot.zero_page_size;
    const guest_stub: [8]u8 = .{ 0xB8, 0x45, 0x54, 0x41, 0x43, 0x0F, 0xA2, 0xF4 }; // mov eax,'CATE'; cpuid; hlt
    try copyIntoGuest(layout.boot_params_gpa, boot_params_page[0..]);
    try copyIntoGuest(layout.cmdline_gpa, DEFAULT_CMDLINE ++ "\x00");
    try copyIntoGuest(layout.kernel_load_gpa, guest_stub[0..]);
    serialWrite("VMX: stage S5\n");
    const entry_gpa = layout.kernel_load_gpa;
    return finalizeLaunchState(layout, entry_gpa, false, 8, DEFAULT_CMDLINE.len + 1);
}

fn stageParsedGuest(parsed: *const linux_boot.ParsedBzImage, layout: linux_boot.LaunchLayout) VmxError!void {
    serialWrite("VMX: stage S3\n");

    try seedGuestLowMemoryPage();
    try buildGuestBootGdt();
    _ = try ensureGuestPage(layout.boot_params_gpa);
    _ = try ensureGuestPage(layout.cmdline_gpa);
    _ = try ensureGuestPage(layout.guest_stack_top_gpa - pmm.PAGE_SIZE);
    _ = try ensureGuestPage(layout.guest_pml4_gpa);
    _ = try ensureGuestPage(layout.guest_pdpt_gpa);
    _ = try ensureGuestPage(layout.guest_pd_gpa);
    serialWrite("VMX: stage S4\n");

    const protected = linux_boot.protectedModeImage(parsed);
    const cmdline = DEFAULT_CMDLINE ++ "\x00";

    // Load the initramfs at a fixed GPA above the kernel region.
    const initramfs_data = guest_initramfs_blob.get();
    const initrd_gpa: u64 = linux_boot.default_initrd_gpa;
    try copyIntoGuest(initrd_gpa, initramfs_data);
    serialWrite("VMX: initramfs loaded gpa=0x");
    printHex(initrd_gpa);
    serialWrite(" size=0x");
    printHex(initramfs_data.len);
    serialWrite("\n");

    const boot_params_page = linux_boot.buildBootParamsPage(parsed, layout, cmdline, linux_boot.default_guest_ram_bytes, initrd_gpa, initramfs_data.len);

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
        serialWrite("VMX: stage S5 using linux entry gpa=0x");
        printHex(entry_gpa);
        serialWrite("\n");
    } else {
        serialWrite("VMX: stage S5 using demo entry gpa=0x");
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
    serialWrite("VMX: stage S5\n");

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

    serialWrite("VMX: stage S6\n");

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
    guest_linux_entry_active = use_linux_entry;
}

fn loadControlFields(vmx_basic: u64) VmxError!void {
    serialWrite("VMX: ctrl C0\n");
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
        const id = current_instance_id orelse return error.Unsupported;
        const inst = microvm_registry.findMutable(id) orelse return error.Unsupported;
        const eptp = (inst.ept_pml4_phys.? & 0x000F_FFFF_FFFF_F000) | EPT_MEMTYPE_WB | ((@as(u64, 4) - 1) << 3);
        try vmwriteChecked(VMCS_CTRL_EPT_POINTER, eptp);
    }

    if (preferLinuxEntry() and (pin_based & PIN_BASED_PREEMPTION_TIMER) != 0) {
        try vmwriteChecked(VMCS_VMX_PREEMPTION_TIMER_VALUE, PREEMPTION_TIMER_INITIAL);
        preemption_timer_active = true;
    }
}

fn loadHostState() VmxError!void {
    serialWrite("VMX: host H0\n");
    var host_rsp = readRsp();
    if (vmx_host_stack_phys != null) {
        host_rsp = vmx_host_stack_phys.? + vmx_hhdm_offset + pmm.PAGE_SIZE;
    }

    cpu.sgdtInto(&vmx_host_gdtr);
    cpu.sidtInto(&vmx_host_idtr);

    try vmwriteChecked(VMCS_HOST_CR0, cpu.readCr0());
    try vmwriteChecked(VMCS_HOST_CR3, cpu.readCr3());
    try vmwriteChecked(VMCS_HOST_CR4, cpu.readCr4());
    try vmwriteChecked(VMCS_HOST_CS_SELECTOR, cpu.readCs() & 0xFFF8);
    try vmwriteChecked(VMCS_HOST_SS_SELECTOR, cpu.readSs() & 0xFFF8);
    try vmwriteChecked(VMCS_HOST_DS_SELECTOR, cpu.readDs() & 0xFFF8);
    try vmwriteChecked(VMCS_HOST_ES_SELECTOR, cpu.readEs() & 0xFFF8);
    try vmwriteChecked(VMCS_HOST_FS_SELECTOR, cpu.readFs() & 0xFFF8);
    try vmwriteChecked(VMCS_HOST_GS_SELECTOR, cpu.readGs() & 0xFFF8);
    try vmwriteChecked(VMCS_HOST_TR_SELECTOR, cpu.readTr() & 0xFFF8);
    try vmwriteChecked(VMCS_HOST_SYSENTER_CS, cpu.rdmsr(0x174));
    try vmwriteChecked(VMCS_HOST_FS_BASE, cpu.rdmsr(IA32_FS_BASE));
    try vmwriteChecked(VMCS_HOST_GS_BASE, cpu.rdmsr(IA32_GS_BASE));
    try vmwriteChecked(VMCS_HOST_TR_BASE, gdt.tssBase());
    try vmwriteChecked(VMCS_HOST_GDTR_BASE, vmx_host_gdtr.base);
    try vmwriteChecked(VMCS_HOST_IDTR_BASE, vmx_host_idtr.base);
    try vmwriteChecked(VMCS_HOST_SYSENTER_ESP, cpu.rdmsr(0x175));
    try vmwriteChecked(VMCS_HOST_SYSENTER_EIP, cpu.rdmsr(0x176));
    try vmwriteChecked(VMCS_HOST_RSP, host_rsp);
    try vmwriteChecked(VMCS_HOST_RIP, @intFromPtr(&vmexitStub));
    try vmwriteChecked(VMCS_HOST_IA32_PAT, cpu.rdmsr(IA32_PAT));
    try vmwriteChecked(VMCS_HOST_IA32_EFER, cpu.rdmsr(IA32_EFER));
    serialWrite("VMX: host H1\n");
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
    const serial_dlab = (serial_lcr & 0x80) != 0;

    if (handlePciConfigIo(port, is_in, size, regs)) {
        advanceGuestRip();
        return;
    }

    if (port == 0x20 or port == 0x21 or port == 0xA0 or port == 0xA1) {
        handlePicIo(port, is_in, regs);
    } else if (port >= 0x40 and port <= 0x43) {
        handlePitIo(port, is_in, regs);
    } else if (port == 0x61) {
        handlePort61(is_in, regs);
    } else if (port == 0x3F8) {
        if (is_in) {
            const value: u8 = if (serial_dlab) serial_dll else 0;
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
        } else {
            const value = @as(u8, @truncate(regs.rax));
            if (serial_dlab) {
                serial_dll = value;
            } else {
                const s = [_]u8{value};
                serialWrite(&s);
            }
        }
    } else if (port == 0x3F9) {
        if (is_in) {
            const value: u8 = if (serial_dlab) serial_dlm else serial_ier;
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
        } else {
            const value = @as(u8, @truncate(regs.rax));
            if (serial_dlab) {
                serial_dlm = value;
            } else {
                serial_ier = value;
                if ((serial_ier & 0x02) != 0 and (pic_master_imr & 0x10) == 0) {
                    serial_irq4_pending = true;
                } else if ((serial_ier & 0x02) == 0) {
                    serial_irq4_pending = false;
                }
            }
        }
    } else if (port == 0x3FA) {
        if (is_in) {
            var value: u8 = if ((serial_ier & 0x02) != 0) 0x02 else 0x01;
            if ((serial_fcr & 0x01) != 0) value |= 0xC0;
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | value;
        } else {
            serial_fcr = @as(u8, @truncate(regs.rax));
        }
    } else if (port == 0x3FB) {
        if (is_in) {
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | serial_lcr;
        } else {
            serial_lcr = @as(u8, @truncate(regs.rax));
        }
    } else if (port == 0x3FC) {
        if (is_in) {
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | serial_mcr;
        } else {
            serial_mcr = @as(u8, @truncate(regs.rax));
        }
    } else if (port == 0x3FD and is_in) {
        // COM1 LSR (Line Status Register) - THRE+TEMT always set (no physical TX FIFO)
        regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | 0x60;
    } else if (port == 0x3FE and is_in) {
        // COM1 MSR - report DCD+DSR+CTS asserted (no delta bits)
        regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | 0xB0;
    } else if (port == 0x3FF) {
        if (is_in) {
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | serial_scr;
        } else {
            serial_scr = @as(u8, @truncate(regs.rax));
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

    var val: u32 = 0;
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
        const vmid = current_instance_id orelse return false;
        const offset = gpa - VIRTIO_DEV_MMIO_BASE;
        if (is_write) {
            virtio_net.handleWrite(vmid, offset, val);
        } else {
            regs.rax = virtio_net.handleRead(vmid, offset);
        }
        advanceGuestRip();
        return true;
    }
    if (gpa >= VIRTIO_BLK_MMIO_BASE and gpa < VIRTIO_BLK_MMIO_BASE + VIRTIO_BLK_MMIO_SIZE) {
        const vmid = current_instance_id orelse return false;
        const offset = gpa - VIRTIO_BLK_MMIO_BASE;
        if (is_write) {
            virtio_blk.handleWrite(vmid, offset, val);
        } else {
            regs.rax = virtio_blk.handleRead(vmid, offset);
        }
        advanceGuestRip();
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
        serialWrite(" maps=0x");
        printHex(guest_map_count);
        serialWrite("\n");
    }

    const window_pages: usize = if (guest_linux_entry_active)
        EPT_PREFAULT_WINDOW_PAGES_LINUX
    else
        EPT_PREFAULT_WINDOW_PAGES_DEMO;
    // Align window base to window_pages * PAGE_SIZE boundary so prefaulted
    // pages are always contiguous and cover the faulting address.
    const window_size: u64 = @as(u64, window_pages) * pmm.PAGE_SIZE;
    const window_base = (gpa / window_size) * window_size;

    for (0..window_pages) |i| {
        const page_gpa = window_base + (@as(u64, @intCast(i)) * pmm.PAGE_SIZE);
        _ = ensureGuestPage(page_gpa) catch |err| {
            serialWrite("VMX: ept-violation map failed err=0x");
            printHex(@intFromError(err));
            serialWrite(" maps=0x");
            printHex(guest_map_count);
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
        const vmid = current_instance_id orelse return false;
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
        const vmid = current_instance_id orelse return false;
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

fn handlePicIo(port: u16, is_in: bool, regs: *GuestRegs) void {
    const is_master = (port == 0x20 or port == 0x21);
    const is_data = (port == 0x21 or port == 0xA1);

    if (is_in) {
        if (is_data) {
            const val: u8 = if (is_master) pic_master_imr else pic_slave_imr;
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | val;
        } else {
            // IRR/ISR read (OCW3) - return 0
            regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00);
        }
    } else {
        const val = @as(u8, @truncate(regs.rax));
        if (is_data) {
            if (is_master) {
                if (pic_master_icw_step > 0) {
                    switch (pic_master_icw_step) {
                        1 => {
                            pic_master_vector_base = val & 0xF8;
                            pic_master_icw_step = 2;
                        },
                        2 => {
                            pic_master_icw_step = 3;
                        },
                        3 => {
                            pic_master_icw_step = 0;
                        },
                        else => {
                            pic_master_icw_step = 0;
                        },
                    }
                } else {
                    pic_master_imr = val;
                }
            } else {
                if (pic_slave_icw_step > 0) {
                    switch (pic_slave_icw_step) {
                        1 => {
                            pic_slave_vector_base = val & 0xF8;
                            pic_slave_icw_step = 2;
                        },
                        2 => {
                            pic_slave_icw_step = 3;
                        },
                        3 => {
                            pic_slave_icw_step = 0;
                        },
                        else => {
                            pic_slave_icw_step = 0;
                        },
                    }
                } else {
                    pic_slave_imr = val;
                }
            }
        } else {
            // Command port write
            if ((val & 0x10) != 0) {
                // ICW1 - start initialization sequence
                if (is_master) {
                    pic_master_icw_step = 1;
                    pic_master_imr = 0;
                } else {
                    pic_slave_icw_step = 1;
                    pic_slave_imr = 0;
                }
            }
            // EOI (0x20) and OCW3 accepted silently
        }
    }
}

fn handlePitIo(port: u16, is_in: bool, regs: *GuestRegs) void {
    if (is_in) {
        // PIT counter reads - return 0
        regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00);
        return;
    }

    const val = @as(u8, @truncate(regs.rax));
    if (port == 0x43) {
        // Mode/Command register - handle channel 0 programming
        const channel = (val >> 6) & 0x3;
        if (channel == 0) {
            pit_channel0_mode = (val >> 1) & 0x7;
            const access = (val >> 4) & 0x3;
            if (access == 3) {
                // lobyte/hibyte access mode
                pit_write_lsb_next = true;
            }
        }
        // Channel 2 command bytes accepted silently (calibration uses port 0x61 output)
    } else if (port == 0x40) {
        // Channel 0 data
        if (pit_write_lsb_next) {
            pit_reload_low = val;
            pit_write_lsb_next = false;
        } else {
            pit_channel0_reload = (@as(u16, val) << 8) | pit_reload_low;
            pit_write_lsb_next = true;
            if (!pit_configured) {
                pit_configured = true;
                serialWrite("VMX: PIT configured reload=0x");
                printHex(pit_channel0_reload);
                serialWrite(" mode=");
                printHex(pit_channel0_mode);
                serialWrite("\n");
            }
            // Arm the preemption timer for interrupt delivery
            if (preemption_timer_active) {
                _ = vmwrite(VMCS_VMX_PREEMPTION_TIMER_VALUE, PREEMPTION_TIMER_RELOAD);
            }
        }
    }
    // Port 0x41, 0x42 writes accepted silently (channel 1/2 data)
}

fn handlePort61(is_in: bool, regs: *GuestRegs) void {
    if (is_in) {
        // Toggle timer 2 output (bit 5) periodically to unblock TSC calibration.
        // Linux's PIT-based calibration polls this bit waiting for it to change.
        port_61_reads += 1;
        if ((port_61_reads & 0xFF) == 0) {
            port_61_value ^= 0x20;
        }
        regs.rax = (regs.rax & 0xFFFF_FFFF_FFFF_FF00) | port_61_value;
    } else {
        port_61_value = @as(u8, @truncate(regs.rax));
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

    // Inject COM1 THRE interrupt (IRQ4) when the ttyS0 driver has THRI enabled.
    // This drives interrupt-mode TX so userspace write() calls reach the serial port.
    if (serial_irq4_pending) {
        if (guest_interruptible) {
            const vector: u64 = @as(u64, pic_master_vector_base) + 4;
            _ = vmwrite(VMCS_VM_ENTRY_INTR_INFO, vector | (VM_ENTRY_INTR_TYPE_EXTERNAL << 8) | (1 << 31));
            serial_irq4_pending = false;
            return; // one interrupt per VMENTRY
        }
        // Interrupt window will let us retry
        const proc = vmread(VMCS_CTRL_CPU_BASED) orelse return;
        _ = vmwrite(VMCS_CTRL_CPU_BASED, proc | PRIMARY_CTL_INTERRUPT_WINDOW);
        return;
    }

    if (!timer_irq_pending) return;

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
    const vector: u64 = pic_master_vector_base;
    const entry_info: u64 = vector | (VM_ENTRY_INTR_TYPE_EXTERNAL << 8) | (1 << 31);
    _ = vmwrite(VMCS_VM_ENTRY_INTR_INFO, entry_info);
    timer_irq_pending = false;
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
    if (pit_configured) {
        timer_irq_pending = true;
        _ = vmwrite(VMCS_VMX_PREEMPTION_TIMER_VALUE, PREEMPTION_TIMER_RELOAD);
        if (timer_exit_count <= 3) {
            serialWrite("VMX: preemption timer fired count=0x");
            printHex(timer_exit_count);
            serialWrite(" pit_cfg=");
            printHex(if (pit_configured) @as(u64, 1) else @as(u64, 0));
            serialWrite("\n");
        }
    } else {
        // PIT not yet programmed; use long interval to reduce overhead
        _ = vmwrite(VMCS_VMX_PREEMPTION_TIMER_VALUE, PREEMPTION_TIMER_INITIAL);
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
            // The Catenary PIT fired while the Linux guest was running.  ACK
            // the PIC master and yield to the Catenary scheduler so that Ring-3
            // services continue to make progress alongside the guest.
            cpu.outb(0x20, 0x20); // EOI to PIC master
            if (build_options.services_active) {
                const scheduler = @import("../../kernel/scheduler.zig");
                scheduler.schedule();
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
            timer_irq_pending = true;
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
        VMEXIT_REASON_APIC_ACCESS => {
            advanceGuestRip();
            return true;
        },
        else => {
            return false;
        },
    }
}

fn drainMicrovmIngress() void {
    while (microvm_bridge.dequeue()) |entry| {
        virtio_net.injectPacket(entry.microvm_id, dipc.payloadFromPage(vmx_hhdm_offset, entry.page_phys));
        pmm.freePage(entry.page_phys);
    }
}

pub export fn catenary_vmx_vmexit_bridge(regs: *GuestRegs) u8 {
    const tsc_end = cpu.rdtsc();
    if (vmx_start_tsc != 0) {
        const delta = tsc_end -% vmx_start_tsc;
        if (current_instance_id) |id| {
            if (microvm_registry.findMutable(id)) |inst| {
                inst.cpu_cycles += delta;
                inst.exit_count += 1;
            }
        }
    }

    // dispatch_vmexit (vmm/microvm_bridge.zig handles Blk/Telemetry;
    // virtio_net.zig handles TX packets from the guest and routes to netd).
    const should_resume = dispatchVmexit(regs);

    drainMicrovmIngress();

    if (should_resume) {
        tryInjectTimerIrq();
        vmx_start_tsc = cpu.rdtsc();
        return 1;
    }

    // Capture exit state back into thread-local/instance-local if we were scheduled.
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
        \\callq catenary_vmx_guest_done
    );
}

pub fn findGuestPageHpaPublic(gpa: u64) ?u64 {
    return findGuestPageHpa(gpa);
}

pub fn injectGuestInterrupt(vmid: u32, vector: u8) void {
    _ = vmid; // Multi-VM support would require mapping vmid to VMCS
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

pub fn translateGpaToHpa(vmid: u32, gpa: u64) ?u64 {
    _ = vmid;
    return findGuestPageHpa(gpa);
}

fn handleVmExit(instance: *microvm_registry.Instance) !void {
    _ = instance;
    // The ASM bridge calls dispatchVmexit and tryInjectTimerIrq.
    // If it returns 0, we are here.
}

pub fn init(memmap: *limine.MemmapResponse, hhdm_offset: u64, table: *const endpoint_table.EndpointTable) !void {
    _ = memmap;
    vmx_hhdm_offset = hhdm_offset;
    microvm_bridge.setBridgeContext(hhdm_offset, table);

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

    if (!vmxon(vmxon_region_phys.?)) return error.VmxonFailed;

    serialWrite("vmx: global vmxon active\n");

    if (microvm_registry.create(GUEST_POOL_PAGES, 1, 0, 0, 0, 0)) |id| {
        current_instance_id = id;
    } else {
        serialWrite("VMX: failed to create microvm instance\n");
        return error.OutOfMemory;
    }

    resetGuestDeviceState();

    stageLinuxGuest() catch {
        serialWrite("VMX: stage failed\n");
        return;
    };

    if (build_options.services_active) {
        serialWrite("VMX: staged guest ready; waiting for service launch\n");
        return;
    }

    const scheduler = @import("../../kernel/scheduler.zig");
    _ = scheduler.spawnWithVmx(null, true, current_instance_id.?, 0) catch {
        serialWrite("VMX: failed to spawn vmx thread\n");
    };
}

pub fn launchStagedInstance() !u32 {
    const id = current_instance_id orelse return error.Unsupported;
    const inst = microvm_registry.findMutable(id) orelse return error.Unsupported;

    if (inst.state == .running) return id;
    if (inst.state != .created) return error.Unsupported;
    if (!microvm_registry.start(id)) return error.Unsupported;

    const scheduler = @import("../../kernel/scheduler.zig");
    _ = try scheduler.spawnWithVmx(null, true, id, 0);
    return id;
}

pub fn setupVmcs(instance: *microvm_registry.Instance) !void {
    const basic = cpu.rdmsr(IA32_VMX_BASIC);
    const revision_id: u32 = @as(u32, @truncate(basic & 0x7FFF_FFFF));

    if (vmx_host_stack_phys == null) {
        vmx_host_stack_phys = pmm.allocPage() orelse return error.OutOfMemory;
    }

    if (instance.ept_pml4_phys == null) {
        instance.ept_pml4_phys = pmm.allocPage() orelse return error.OutOfMemory;
        clearPage(instance.ept_pml4_phys.?);
    }

    _ = try ensureRegion(&instance.vmcs_phys, vmx_hhdm_offset, revision_id);

    if (!vmclear(instance.vmcs_phys.?)) return error.VmclearFailed;
    if (!vmptrld(instance.vmcs_phys.?)) return error.VmptrldFailed;

    current_instance_id = instance.instance_id;

    try loadControlFields(basic);
    try loadHostState();
    try loadGuestState(&staged_launch_state);
}

pub fn resumeInstance(instance: *microvm_registry.Instance) !void {
    if (instance.vmcs_phys == null) {
        try setupVmcs(instance);
        serialWrite("VMX: entering guest via vmlaunch\n");
        vmx_start_tsc = cpu.rdtsc();
        if (!vmlaunchWithGuestRsi(staged_launch_state.guest_rsi)) {
            serialWrite("VMX: vmlaunch failed err=0x");
            printHex(vmread(VMCS_VM_INSTRUCTION_ERROR) orelse 0);
            serialWrite("\n");
            return error.VmlaunchFailed;
        }
        return;
    }

    const tsc_start = cpu.rdtsc();

    // Switch to this instance's VMCS
    if (!vmptrld(instance.vmcs_phys.?)) return error.VmptrldFailed;

    serialWrite("VMX: entering guest via vmresume\n");
    if (!vmresumeWithGuestRsi(staged_launch_state.guest_rsi)) {
        serialWrite("VMX: vmresume failed err=0x");
        printHex(vmread(VMCS_VM_INSTRUCTION_ERROR) orelse 0);
        serialWrite("\n");
        return error.VmresumeFailed;
    }

    const tsc_end = cpu.rdtsc();
    instance.cpu_cycles += (tsc_end - tsc_start);
    instance.exit_count += 1;

    // Handle the VM-exit (ASM bridge logic if we return here)
    try handleVmExit(instance);
}
