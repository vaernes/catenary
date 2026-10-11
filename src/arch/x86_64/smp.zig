/// smp.zig — Symmetric Multi-Processing (SMP) AP core bring-up for Catenary OS.
///
/// Uses standard xAPIC MMIO via Limine HHDM at 0xFEE00000.
/// APs start via INIT-SIPI-SIPI at physical page 0x8000 (trampoline).
/// Trampoline transitions 16-bit real mode -> 32-bit protected mode -> 64-bit long mode.
const std = @import("std");
const builtin = @import("builtin");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const idt = @import("idt.zig");
const gdt = @import("gdt.zig");

pub const MAX_CPUS: usize = 8;

pub const CpuCore = struct {
    id: u32,
    lapic_id: u32,
    online: bool,
    is_bsp: bool,
};

var cpus: [MAX_CPUS]CpuCore = [_]CpuCore{.{
    .id = 0,
    .lapic_id = 0,
    .online = true,
    .is_bsp = true,
}} ** MAX_CPUS;

var cpu_count: usize = 1;

// ---------------------------------------------------------------------------
// Synchronization and Serial Helpers
// ---------------------------------------------------------------------------

var ap_online_flag: bool = false;
var serial_lock: bool = false;
var serial_lock_depth: [MAX_CPUS]u32 = [_]u32{0} ** MAX_CPUS;
var serial_saved_flags: [MAX_CPUS]u64 = [_]u64{0} ** MAX_CPUS;

pub fn serialAcquire() void {
    var flags: u64 = 0;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\pushfq
            \\popq %[flags]
            \\cli
            : [flags] "=r" (flags),
        );
    }
    const cpu_id = getCurrentCpuId();
    if (serial_lock_depth[cpu_id] > 0) {
        serial_lock_depth[cpu_id] += 1;
        return;
    }
    while (@atomicRmw(bool, &serial_lock, .Xchg, true, .seq_cst)) {
        asm volatile ("pause");
    }
    serial_saved_flags[cpu_id] = flags;
    serial_lock_depth[cpu_id] = 1;
}

pub fn serialRelease() void {
    const cpu_id = getCurrentCpuId();
    if (serial_lock_depth[cpu_id] > 1) {
        serial_lock_depth[cpu_id] -= 1;
        return;
    }
    serial_lock_depth[cpu_id] = 0;
    const flags = serial_saved_flags[cpu_id];
    @atomicStore(bool, &serial_lock, false, .seq_cst);
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\pushq %[flags]
            \\popfq
            :
            : [flags] "r" (flags),
        );
    }
}

fn serialWrite(s: []const u8) void {
    for (s) |c| cpu.outb(0x3F8, c);
}

fn serialWriteDec(n: u64) void {
    if (n == 0) {
        cpu.outb(0x3F8, '0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = n;
    while (v > 0) {
        i -= 1;
        buf[i] = @as(u8, @intCast(v % 10)) + '0';
        v /= 10;
    }
    for (buf[i..]) |c| cpu.outb(0x3F8, c);
}

fn serialWriteHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        cpu.outb(0x3F8, hex[@as(usize, @intCast((n >> shift) & 0xF))]);
        if (shift >= 4) shift -= 4;
    }
}

// ---------------------------------------------------------------------------
// Accurate RDTSC Timing Helpers
// ---------------------------------------------------------------------------

fn delayMs(ms: u64) void {
    const start = cpu.rdtsc();
    const target = ms * 2_500_000;
    while (cpu.rdtsc() -% start < target) {
        asm volatile ("pause");
    }
}

fn delay10ms() void {
    delayMs(10);
}

fn delay200us() void {
    const start = cpu.rdtsc();
    const target = 500_000;
    while (cpu.rdtsc() -% start < target) {
        asm volatile ("pause");
    }
}

// ---------------------------------------------------------------------------
// xAPIC MMIO via HHDM
// ---------------------------------------------------------------------------

const LAPIC_PHYS_BASE: u64 = 0xFEE0_0000;
var g_lapic_va: u64 = 0;
const SVR: usize = 0x0F0;
const ICR_LOW: usize = 0x300;
const ICR_HIGH: usize = 0x310;

fn lapicRead(offset: usize) u32 {
    const reg: *volatile u32 = @ptrFromInt(g_lapic_va + offset);
    return reg.*;
}

fn lapicWrite(offset: usize, val: u32) void {
    const reg: *volatile u32 = @ptrFromInt(g_lapic_va + offset);
    reg.* = val;
}

fn lapicWaitIdle() void {
    var i: u32 = 0;
    while (i < 100_000) : (i += 1) {
        if ((lapicRead(ICR_LOW) & (1 << 12)) == 0) return;
        asm volatile ("pause");
    }
}

// ---------------------------------------------------------------------------
// Per-AP Stacks
// ---------------------------------------------------------------------------

var ap_stacks: [7][4096]u8 align(16) = [_][4096]u8{[_]u8{0} ** 4096} ** 7;

// ---------------------------------------------------------------------------
// AP Entry Point (called from 64-bit trampoline stub)
// ---------------------------------------------------------------------------

export fn apEntry(ap_idx: u64) callconv(.c) noreturn {
    // 1. Load kernel IDT
    cpu.lidt(&idt.idtr);

    // 2. Load kernel GDT
    cpu.lgdt(&gdt.gdtr);

    // 3. Reload segment registers with kernel descriptors:
    // - Data segments (DS, ES, FS, GS, SS) reloaded with 0x10 (Kernel Data DPL 0)
    // - Code segment (CS) reloaded with 0x08 (Kernel Code DPL 0) via 64-bit far return
    asm volatile (
        \\mov $0x10, %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\mov %ax, %fs
        \\mov %ax, %gs
        \\mov %ax, %ss
        \\pushq $0x08
        \\leaq 1f(%rip), %rax
        \\pushq %rax
        \\lretq
        \\1:
    );

    // 4. Load per-CPU Task Register (TR)
    cpu.ltr(gdt.tssSelectorForCpu(@as(usize, @intCast(ap_idx))));

    // 5. Ensure interrupts are disabled
    asm volatile ("cli");

    // 5. Enable SSE / FPU on AP
    var cr0 = cpu.readCr0();
    cr0 &= ~@as(u64, 1 << 2); // clear EM
    cr0 |= (1 << 1);          // set MP
    cpu.writeCr0(cr0);

    var cr4 = cpu.readCr4();
    cr4 |= (1 << 9) | (1 << 10); // OSFXSR | OSXMMEXCPT
    cpu.writeCr4(cr4);

    // 6. Thread-safe serial logging: must match "smp: AP core"
    serialAcquire();
    serialWrite("smp: AP core ");
    serialWriteDec(ap_idx);
    serialWrite(" online\n");
    serialRelease();

    // 7. Handshake with BSP: mark online
    @atomicStore(bool, &ap_online_flag, true, .seq_cst);

    // 8. AP Scheduler Loop
    const scheduler = @import("../../kernel/scheduler.zig");
    scheduler.apScheduleLoop(@as(usize, @intCast(ap_idx)));
}

// ---------------------------------------------------------------------------
// Trampoline: 16 -> 32 -> 64-bit startup at physical 0x8000
// ---------------------------------------------------------------------------

fn writeTrampoline(hhdm: u64, bsp_cr3: u64) void {
    const base: u64 = hhdm + 0x8000;
    const t: [*]volatile u8 = @ptrFromInt(base);

    // Zero entire trampoline page
    for (0..0x1000) |i| t[i] = 0;

    // GDTR pointer at 0x80: limit=31 (0x1F), base=0x00008090
    t[0x80] = 0x1F;
    t[0x81] = 0x00;
    t[0x82] = 0x90;
    t[0x83] = 0x80;
    t[0x84] = 0x00;
    t[0x85] = 0x00;

    // GDT table at 0x90:
    const gdt_slice: [*]volatile u64 = @ptrFromInt(base + 0x90);
    gdt_slice[0] = 0x0000000000000000;
    gdt_slice[1] = 0x00CF9A000000FFFF;
    gdt_slice[2] = 0x00CF92000000FFFF;
    gdt_slice[3] = 0x00AF9A000000FFFF;

    // Data slots
    @as(*volatile u64, @ptrFromInt(base + 0xB0)).* = bsp_cr3;
    @as(*volatile u64, @ptrFromInt(base + 0xB8)).* = @intFromPtr(&apEntry);

    // 16-bit real-mode stub at 0x00
    const s16 = [_]u8{
        0xFA,                          // cli
        0xFC,                          // cld
        0x31, 0xC0,                    // xor ax, ax
        0x8E, 0xD8,                    // mov ds, ax
        0x8E, 0xC0,                    // mov es, ax
        0x8E, 0xD0,                    // mov ss, ax
        0x0F, 0x01, 0x16, 0x80, 0x80, // lgdt [0x8080]
        0x0F, 0x20, 0xC0,              // mov eax, cr0
        0x0C, 0x01,                    // or al, 1
        0x0F, 0x22, 0xC0,              // mov cr0, eax
        0x66, 0xEA, 0x30, 0x80, 0x00, 0x00, 0x08, 0x00, // jmpf 0x08:0x8030
    };
    for (s16, 0..) |b, i| t[i] = b;

    // 32-bit protected-mode stub at 0x30
    // Order per Intel SDM 9.8.5: PAE -> EFER.LME|NXE -> CR3 -> CR0.PG -> Long Mode Jump
    const s32 = [_]u8{
        0x66, 0xB8, 0x10, 0x00,        // mov ax, 0x10
        0x8E, 0xD8,                    // mov ds, ax
        0x8E, 0xC0,                    // mov es, ax
        0x8E, 0xD0,                    // mov ss, ax
        0x0F, 0x20, 0xE0,              // mov eax, cr4
        0x83, 0xC8, 0x20,              // or eax, 0x20 (enable CR4.PAE)
        0x0F, 0x22, 0xE0,              // mov cr4, eax
        0xB9, 0x80, 0x00, 0x00, 0xC0, // mov ecx, 0xC0000080 (IA32_EFER MSR)
        0x0F, 0x32,                    // rdmsr
        0x0D, 0x00, 0x09, 0x00, 0x00, // or eax, 0x900 (enable EFER.LME | EFER.NXE)
        0x0F, 0x30,                    // wrmsr
        0xA1, 0xB0, 0x80, 0x00, 0x00, // mov eax, [0x80B0] (load CR3 physical address)
        0x0F, 0x22, 0xD8,              // mov cr3, eax
        0x0F, 0x20, 0xC0,              // mov eax, cr0
        0x0D, 0x01, 0x00, 0x00, 0x80, // or eax, 0x80000001 (enable CR0.PG and CR0.PE)
        0x0F, 0x22, 0xC0,              // mov cr0, eax
        0xEA, 0x00, 0x81, 0x00, 0x00, 0x18, 0x00, // jmpf 0x18:0x8100
    };
    for (s32, 0..) |b, i| t[0x30 + i] = b;

    // 64-bit long-mode stub at 0x100
    const s64 = [_]u8{
        0x48, 0xB8, 0xC0, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov rax, 0x80C0
        0x48, 0x8B, 0x20,                                           // mov rsp, [rax]
        0x48, 0x83, 0xEC, 0x08,                                     // sub rsp, 8 (align for SysV ABI)
        0x48, 0xB8, 0xC8, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov rax, 0x80C8
        0x48, 0x8B, 0x38,                                           // mov rdi, [rax]
        0x48, 0xB8, 0xB8, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov rax, 0x80B8
        0x48, 0x8B, 0x00,                                           // mov rax, [rax]
        0xFF, 0xE0,                                                 // jmp rax
        0xF4, 0xEB, 0xFD,                                           // hlt; jmp -3
    };
    for (s64, 0..) |b, i| t[0x100 + i] = b;
}

fn setApParams(hhdm: u64, stack_top: u64, ap_idx: u64) void {
    const base: u64 = hhdm + 0x8000;
    @as(*volatile u64, @ptrFromInt(base + 0xC0)).* = stack_top;
    @as(*volatile u64, @ptrFromInt(base + 0xC8)).* = ap_idx;
}

// ---------------------------------------------------------------------------
// Public Init: AP bring-up via INIT-SIPI-SIPI
// ---------------------------------------------------------------------------

pub fn init(hhdm_offset: u64) void {
    const c1 = cpu.cpuid(1, 0);
    const bsp_apic_id: u8 = @truncate(c1.ebx >> 24);
    const max_ids: u8     = @truncate((c1.ebx >> 16) & 0xFF);
    cpus[0].lapic_id = bsp_apic_id;

    serialAcquire();
    serialWrite("SMP: BSP LAPIC_ID=0x");
    serialWriteHex(bsp_apic_id);
    serialWrite(" logical=");
    serialWriteDec(max_ids);
    serialWrite("\n");
    serialRelease();

    var ap_count: u32 = if (max_ids > 1) @as(u32, max_ids) - 1 else 0;
    if (ap_count == 0) {
        serialAcquire();
        serialWrite("SMP: single-core, skipping AP bringup\n");
        serialRelease();
        return;
    }

    if (ap_count > 7) {
        ap_count = 7;
    }

    // Set up xAPIC MMIO via Limine HHDM
    g_lapic_va = hhdm_offset + LAPIC_PHYS_BASE;

    // Software enable LAPIC via SVR (bit 8 = 1, spurious vector = 0xFF)
    const svr = lapicRead(SVR);
    lapicWrite(SVR, svr | 0x100 | 0xFF);

    // Identity-map physical page 0x8000 in PML4 so AP can execute trampoline after paging is enabled
    paging.map(hhdm_offset, 0x8000, 0x8000, 0x03) catch |err| {
        if (err != error.AlreadyMapped) {
            serialAcquire();
            serialWrite("SMP: failed to identity map trampoline\n");
            serialRelease();
            return;
        }
    };

    // Read BSP CR3 to share page tables with APs, masking PCID/cache flags
    const bsp_cr3 = cpu.readCr3() & ~@as(u64, 0xFFF);

    // Prepare trampoline at physical 0x8000
    writeTrampoline(hhdm_offset, bsp_cr3);

    serialAcquire();
    serialWrite("SMP: trampoline prepared at phys 0x8000\n");
    serialRelease();

    var online_count: u32 = 0;

    // Sequentially bring up each AP
    var i: usize = 0;
    while (i < ap_count) : (i += 1) {
        const ap_idx: u64 = i + 1;
        const target_apic_id: u32 = @as(u32, @intCast(i + 1));
        const stack_top: u64 = @intFromPtr(&ap_stacks[i]) + 4096;

        setApParams(hhdm_offset, stack_top, ap_idx);
        @atomicStore(bool, &ap_online_flag, false, .seq_cst);

        // Targeted INIT IPI
        lapicWaitIdle();
        lapicWrite(ICR_HIGH, target_apic_id << 24);
        lapicWrite(ICR_LOW, 0x00004500);
        lapicWaitIdle();
        delay10ms();

        // Targeted SIPI #1 (vector 0x08 -> physical 0x8000)
        lapicWrite(ICR_HIGH, target_apic_id << 24);
        lapicWrite(ICR_LOW, 0x00004608);
        lapicWaitIdle();

        // Wait up to 10ms for AP to acknowledge SIPI #1
        var waited: u32 = 0;
        while (waited < 10) : (waited += 1) {
            if (@atomicLoad(bool, &ap_online_flag, .seq_cst)) break;
            delay10ms();
        }

        // Only send SIPI #2 if AP did not respond to SIPI #1
        if (!@atomicLoad(bool, &ap_online_flag, .seq_cst)) {
            lapicWrite(ICR_HIGH, target_apic_id << 24);
            lapicWrite(ICR_LOW, 0x00004608);
            lapicWaitIdle();

            waited = 0;
            while (waited < 10) : (waited += 1) {
                if (@atomicLoad(bool, &ap_online_flag, .seq_cst)) break;
                delay10ms();
            }
        }

        if (@atomicLoad(bool, &ap_online_flag, .seq_cst)) {
            cpus[i + 1].online = true;
            cpus[i + 1].lapic_id = target_apic_id;
            cpus[i + 1].id = @as(u32, @intCast(i + 1));
            cpus[i + 1].is_bsp = false;
            online_count += 1;
        } else {
            serialAcquire();
            serialWrite("SMP: AP core ");
            serialWriteDec(ap_idx);
            serialWrite(" failed to respond to SIPI\n");
            serialRelease();
        }
    }

    cpu_count = 1 + online_count;
    serialAcquire();
    serialWrite("SMP: ");
    serialWriteDec(online_count);
    serialWrite("/");
    serialWriteDec(ap_count);
    serialWrite(" AP(s) online, total=");
    serialWriteDec(cpu_count);
    serialWrite("\n");
    serialRelease();
}

pub fn getCpuCount() usize {
    return cpu_count;
}

pub fn isBsp() bool {
    return cpus[0].is_bsp;
}

pub fn getCurrentCpuId() usize {
    if (comptime builtin.cpu.arch == .x86_64) {
        const c1 = cpu.cpuid(1, 0);
        const lapic_id: u32 = @as(u32, @intCast((c1.ebx >> 24) & 0xFF));
        for (0..cpu_count) |i| {
            if (cpus[i].lapic_id == lapic_id) return i;
        }
        if (lapic_id < MAX_CPUS) return lapic_id;
    }
    return 0;
}
