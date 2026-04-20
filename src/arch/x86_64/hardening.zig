const cpu = @import("cpu.zig");

pub const BaselineReport = struct {
    nx_supported: bool = false,
    nx_enabled: bool = false,
    smep_supported: bool = false,
    smep_enabled: bool = false,
    smap_supported: bool = false,
    smap_enabled: bool = false,
    umip_supported: bool = false,
    umip_enabled: bool = false,
};

const MSR_EFER: u32 = 0xC000_0080;
const EFER_NXE: u64 = 1 << 11;
const CR0_PE: u64 = 1 << 0;
const CR0_MP: u64 = 1 << 1;
const CR0_EM: u64 = 1 << 2;
const CR0_TS: u64 = 1 << 3;
const CR0_ET: u64 = 1 << 4;
const CR0_NE: u64 = 1 << 5;
const CR0_PG: u64 = 1 << 31;
const CR4_OSFXSR: u64 = 1 << 9;
const CR4_OSXMMEXCPT: u64 = 1 << 10;
const CR4_SMEP: u64 = 1 << 20;
const CR4_SMAP: u64 = 1 << 21;
const CR4_UMIP: u64 = 1 << 11;
const CPUID_EXT_NX_EDX_BIT: u32 = 20;
const CPUID_STD_SSE_EDX_BIT: u32 = 25;
const CPUID_STD_SSE2_EDX_BIT: u32 = 26;
const CPUID_STRUCT_EXT_SMEP_EBX_BIT: u32 = 7;
const CPUID_STRUCT_EXT_SMAP_EBX_BIT: u32 = 20;
const CPUID_STRUCT_EXT_UMIP_ECX_BIT: u32 = 2;

fn cpuidBitSet(value: u32, bit: u32) bool {
    return (value & (@as(u32, 1) << @as(u5, @intCast(bit)))) != 0;
}

pub fn applyBaseline() BaselineReport {
    var report: BaselineReport = .{};

    const basic = cpu.cpuid(0, 0);
    const extended = cpu.cpuid(0x8000_0000, 0);

    // Ensure compiler-emitted XMM instructions are legal in early kernel code.
    if (basic.eax >= 1) {
        const std_features = cpu.cpuid(1, 0);
        const sse_ok = cpuidBitSet(std_features.edx, CPUID_STD_SSE_EDX_BIT) and
            cpuidBitSet(std_features.edx, CPUID_STD_SSE2_EDX_BIT);
        if (sse_ok) {
            var cr0 = cpu.readCr0();
            cr0 |= CR0_MP | CR0_NE | CR0_ET;
            cr0 &= ~(CR0_EM | CR0_TS);
            cpu.writeCr0(cr0);

            var cr4 = cpu.readCr4();
            cr4 |= CR4_OSFXSR | CR4_OSXMMEXCPT;
            cpu.writeCr4(cr4);

            // Initialize FPU/x87
            asm volatile ("finit");
        }
    }

    if (extended.eax >= 0x8000_0001) {
        const ext_features = cpu.cpuid(0x8000_0001, 0);
        report.nx_supported = cpuidBitSet(ext_features.edx, CPUID_EXT_NX_EDX_BIT);
        if (report.nx_supported) {
            var efer = cpu.rdmsr(MSR_EFER);
            efer |= EFER_NXE;
            cpu.wrmsr(MSR_EFER, efer);
            report.nx_enabled = (cpu.rdmsr(MSR_EFER) & EFER_NXE) != 0;
        }
    }

    if (basic.eax >= 7) {
        const structured = cpu.cpuid(7, 0);
        report.smep_supported = cpuidBitSet(structured.ebx, CPUID_STRUCT_EXT_SMEP_EBX_BIT);
        report.smap_supported = cpuidBitSet(structured.ebx, CPUID_STRUCT_EXT_SMAP_EBX_BIT);
        report.umip_supported = cpuidBitSet(structured.ecx, CPUID_STRUCT_EXT_UMIP_ECX_BIT);
        if (report.smep_supported or report.smap_supported or report.umip_supported) {
            var cr4 = cpu.readCr4();
            if (report.smep_supported) cr4 |= CR4_SMEP;
            if (report.smap_supported) cr4 |= CR4_SMAP;
            if (report.umip_supported) cr4 |= CR4_UMIP;
            cpu.writeCr4(cr4);
            const applied = cpu.readCr4();
            report.smep_enabled = (applied & CR4_SMEP) != 0;
            report.smap_enabled = (applied & CR4_SMAP) != 0;
            report.umip_enabled = (applied & CR4_UMIP) != 0;
        }
    }

    return report;
}
