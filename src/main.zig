const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const limine = @import("kernel/limine.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pmm = @import("kernel/pmm.zig");
const scheduler = @import("kernel/scheduler.zig");
const timer = @import("arch/x86_64/timer.zig");
const arch = @import("arch.zig");
const selftest = @import("kernel/selftest.zig");
const varde_shell = @import("kernel/varde_shell.zig");
const trust = @import("kernel/trust.zig");
const dipc = @import("ipc/dipc.zig");
const manager = @import("ipc/manager.zig");
const node_config = @import("ipc/node_config.zig");
const fb = @import("kernel/fb.zig");
const elf_loader = @import("services/elf_loader.zig");
const service_launch = @import("services/service_launch.zig");
const service_registry = @import("services/service_registry.zig");
const task_loader = @import("services/task_loader.zig");
const service_manager = @import("services/service_manager.zig");
const keyboard = if (builtin.cpu.arch == .x86_64) @import("arch/x86_64/keyboard.zig") else struct {};
const user_mode = if (builtin.cpu.arch == .x86_64) @import("arch/x86_64/user_mode.zig") else struct {};
const hvm = if (builtin.cpu.arch == .x86_64) @import("arch/x86_64/hvm.zig") else struct {};

pub const OS_NAME = "Catenary OS";
pub const OS_VERSION = std.SemanticVersion.parse(build_options.os_version_str) catch std.SemanticVersion{ .major = 0, .minor = 0, .patch = 0 };
pub const OS_CODENAME = "Ready";
pub const BUILD_COMMIT = build_options.commit_id;

var uart_com1_present: bool = true;

pub export var limine_memmap_request: limine.MemmapRequest = .{};
pub export var limine_hhdm_request: limine.HhdmRequest = .{};
pub export var limine_kernel_file_request: limine.KernelFileRequest = .{};
pub export var limine_kernel_address_request: limine.KernelAddressRequest = .{};
pub export var limine_framebuffer_request: limine.FramebufferRequest = .{};

var internal_mod_netd = limine.InternalModule{
    .path = "../modules/netd.elf",
    .cmdline = "",
    .flags = 1, // LIMINE_INTERNAL_MODULE_REQUIRED
};
var internal_mod_storaged = limine.InternalModule{
    .path = "../modules/storaged.elf",
    .cmdline = "",
    .flags = 1, // LIMINE_INTERNAL_MODULE_REQUIRED
};

var internal_mod_dashd = limine.InternalModule{
    .path = "../modules/dashd.elf",
    .cmdline = "",
    .flags = 1, // LIMINE_INTERNAL_MODULE_REQUIRED
};

var internal_mod_containerd = limine.InternalModule{
    .path = "../modules/containerd.elf",
    .cmdline = "",
    .flags = 1, // LIMINE_INTERNAL_MODULE_REQUIRED
};

var internal_mod_clusterd = limine.InternalModule{
    .path = "../modules/clusterd.elf",
    .cmdline = "",
    .flags = 1, // LIMINE_INTERNAL_MODULE_REQUIRED
};

var internal_mod_inputd = limine.InternalModule{
    .path = "../modules/inputd.elf",
    .cmdline = "",
    .flags = 1, // LIMINE_INTERNAL_MODULE_REQUIRED
};

var internal_mod_windowd = limine.InternalModule{
    .path = "../modules/windowd.elf",
    .cmdline = "",
    .flags = 1, // LIMINE_INTERNAL_MODULE_REQUIRED
};

var internal_mod_configd = limine.InternalModule{
    .path = "../modules/configd.elf",
    .cmdline = "",
    .flags = 1, // LIMINE_INTERNAL_MODULE_REQUIRED
};

var module_array = [_]?[*]limine.InternalModule{
    @ptrCast(&internal_mod_netd),
    @ptrCast(&internal_mod_storaged),
    @ptrCast(&internal_mod_dashd),
    @ptrCast(&internal_mod_containerd),
    @ptrCast(&internal_mod_clusterd),
    @ptrCast(&internal_mod_inputd),
    @ptrCast(&internal_mod_windowd),
    @ptrCast(&internal_mod_configd),
};

pub export var limine_module_request: limine.ModuleRequest = if (build_options.services_active) .{
    .revision = 1,
    .response = null,
    .internal_module_count = module_array.len,
    .internal_modules = @ptrCast(&module_array),
} else .{};

pub export var limine_stack_request: limine.StackSizeRequest = .{ .stack_size = 65536 };

pub fn serialWrite(s: []const u8) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        for (s) |c| {
            if (uart_com1_present) {
                outb(0x3F8, c);
            } else {
                outb(0xE9, c);
            }
        }
    }
}

fn bootLog(s: []const u8) void {
    serialWrite(s);
    if (comptime builtin.cpu.arch == .x86_64) {
        fb.printString(s);
    }
}

inline fn outb(port: u16, val: u8) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("outb %[val], %[port]"
            :
            : [val] "{al}" (val),
              [port] "{dx}" (port),
        );
    }
}

fn initUartCom1() void {
    if (comptime builtin.cpu.arch != .x86_64) return;

    const scratch_port: u16 = 0x3FB;
    const scratch_old = arch.cpu.inb(scratch_port);
    outb(scratch_port, 0x5A);
    if (arch.cpu.inb(scratch_port) != 0x5A) {
        uart_com1_present = false;
        return;
    }
    outb(scratch_port, scratch_old);
    uart_com1_present = true;

    // Disable interrupts while programming UART.
    outb(0x3F9, 0x00);
    // Enable DLAB to set baud divisor.
    outb(0x3FB, 0x80);
    // 115200 / 3 = 38400 baud.
    outb(0x3F8, 0x03);
    outb(0x3F9, 0x00);
    // 8 bits, no parity, one stop bit.
    outb(0x3FB, 0x03);
    // Enable FIFO, clear queues, 14-byte threshold.
    outb(0x3FA, 0xC7);
    // IRQs disabled, RTS/DSR set.
    outb(0x3FC, 0x03);
}

var thread_a_id: u32 = undefined;
var timer_initialized_early: bool = false;

fn printHardeningState(name: []const u8, enabled: bool, supported: bool) void {
    bootLog("Hardening ");
    bootLog(name);
    bootLog(": ");
    if (enabled) {
        bootLog("enabled\n");
    } else if (supported) {
        bootLog("supported, deferred\n");
    } else {
        bootLog("unsupported\n");
    }
}

fn reportHardeningBaseline(report: arch.hardening.BaselineReport) void {
    printHardeningState("NXE", report.nx_enabled, report.nx_supported);
    printHardeningState("SMEP", report.smep_enabled, report.smep_supported);
    printHardeningState("SMAP", report.smap_enabled, report.smap_supported);
}

const KERNEL_LINKER_VIRT_BASE: u64 = 0xFFFF_FFFF_8100_0000;

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    // Write directly via outb to avoid stack-allocated buf + slice call chain.
    var shift: u6 = 60;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        if (uart_com1_present) {
            outb(0x3F8, hex[nibble]);
        } else {
            outb(0xE9, hex[nibble]);
        }
        if (shift >= 4) shift -= 4;
    }
}

fn printDec(n: u64) void {
    if (n == 0) {
        if (uart_com1_present) outb(0x3F8, '0') else outb(0xE9, '0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 0;
    var temp = n;
    while (temp > 0) {
        buf[i] = @as(u8, @intCast(temp % 10)) + '0';
        temp /= 10;
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        const c = buf[i];
        if (uart_com1_present) {
            outb(0x3F8, c);
        } else {
            outb(0xE9, c);
        }
    }
}

export fn memset(dest: [*]u8, c: u8, n: usize) [*]u8 {
    for (0..n) |i| {
        dest[i] = c;
    }
    return dest;
}

export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    for (0..n) |i| {
        dest[i] = src[i];
    }
    return dest;
}

fn threadA() void {
    arch.cpu.sti();
    while (true) {
        if (scheduler.receive() != null) {}
        arch.cpu.pause();
    }
}

fn threadB() void {
    arch.cpu.sti();
    while (true) {
        arch.cpu.pause();
    }
}

var hhdm_offset_global: u64 = 0;

pub export fn _kernel_main() callconv(.c) noreturn {
    initUartCom1();
    bootLog(OS_NAME);
    bootLog(" v");
    printDec(OS_VERSION.major);
    bootLog(".");
    printDec(OS_VERSION.minor);
    bootLog(".");
    printDec(OS_VERSION.patch);
    bootLog(" (");
    bootLog(OS_CODENAME);
    bootLog(") (rev ");
    bootLog(BUILD_COMMIT);
    bootLog(") booting...\n");
    bootLog("Boot config: services=");
    bootLog(if (build_options.services_active) "on" else "off");
    bootLog(" vmm=");
    bootLog(if (build_options.vmm_active) "on" else "off");
    bootLog(" linux_guest=");
    bootLog(if (build_options.vmm_launch_linux) "on" else "off");
    bootLog("\n");

    gdt.init();
    bootLog("GDT initialized.\n");

    idt.init();
    bootLog("IDT initialized.\n");

    if (comptime builtin.cpu.arch == .x86_64) {
        keyboard.init();
        bootLog("Keyboard initialized.\n");
    }

    const hardening = arch.hardening.applyBaseline();
    reportHardeningBaseline(hardening);

    fb.init(&limine_framebuffer_request, bootLog);
    fb.clear(0x004A4E69); // Sea Gray background
    fb.drawRect(0, 0, 800, 20, 0x00E2725B); // Terracotta bar

    if (limine_stack_request.response) |_| {
        bootLog("Stack size request: OK\n");
    } else {
        bootLog("Stack size request: No response\n");
    }

    if (limine_memmap_request.response) |memmap| {
        if (limine_hhdm_request.response) |hhdm| {
            hhdm_offset_global = hhdm.offset;
            pmm.init(memmap, hhdm.offset);
            bootLog("PMM initialized.\n");

            scheduler.init(hhdm.offset);
            bootLog("Scheduler initialized.\n");

            const ent = arch.cpu.rdtsc();
            // Define the manifest outside the loop.
            var virtual_base: u64 = 0xFFFFFFFF80000000;
            var physical_base: u64 = 0x1000000;
            var kernel_size: u64 = 0x50000;

            if (limine_kernel_file_request.response) |kfile_resp| {
                if (kfile_resp.kernel_file) |kfile| {
                    physical_base = @intFromPtr(kfile.address);
                    kernel_size = kfile.size;
                    bootLog("Kernel image identified.\n");
                }
            }

            if (limine_kernel_address_request.response) |kaddr_resp| {
                virtual_base = kaddr_resp.virtual_base;
                physical_base = kaddr_resp.physical_base;
                // Record the KASLR slide so paging checks have a single
                // authoritative source for the kernel virtual base.
                arch.paging.initKasrl(virtual_base);
                bootLog("Kernel address identified.\n");
            }

            const manifest = trust.KernelManifest{
                .kernel_base_physical = physical_base,
                .kernel_size = kernel_size,
                .boot_time_entropy = ent,
                .capability_seed = ent ^ 0xC4A7_E2D1_5F30_9B6C,
                .load_address_virtual = virtual_base,
                .entry_point_virtual = virtual_base,
            };
            _ = trust.storeManifest(manifest);
            dipc.setAuthKey(manifest.capability_seed ^ 0xD19C_A77E_2045_B68F);
            service_registry.init();
            if (comptime builtin.cpu.arch == .x86_64) {
                user_mode.installHandlers(hhdm.offset);
                user_mode.ensureKernelEntryStack() catch |err| {
                    bootLog("Failed to ensure kernel entry stack: ");
                    bootLog(@errorName(err));
                    bootLog("\n");
                };
            }
            if (build_options.services_active) {
                service_manager.bootAll(hhdm.offset, node_config.getLocalNode()) catch |err| {
                    bootLog("Service Manager bootAll failed: ");
                    bootLog(@errorName(err));
                    bootLog("\n");
                };
            }
            bootLog("Service Manager finished.\n");
            bootLog("Manifest stored.\n");

            // Verify kernel mappings canonicality
            if (arch.paging.isCanonical(virtual_base)) {
                // bootLog("Kernel address is canonical.\n");
            } else {
                bootLog("CRITICAL: Kernel virtual base is non-canonical!\n");
                while (true) arch.cpu.halt();
            }

            if (virtual_base != KERNEL_LINKER_VIRT_BASE) {
                bootLog("CRITICAL: KASLR/linker base mismatch: ");
                printHex(virtual_base);
                bootLog(" expected ");
                printHex(KERNEL_LINKER_VIRT_BASE);
                bootLog("\n");
                while (true) arch.cpu.halt();
            }

            if (!selftest.run(bootLog)) {
                bootLog("selftest: fatal\n");
                while (true) arch.cpu.halt();
            }

            manager.init(hhdm.offset);
            if (comptime builtin.cpu.arch == .x86_64) {
                if (build_options.vmm_active) {
                    timer.init();
                    bootLog("Timer initialized.\n");
                    timer_initialized_early = true;
                    hvm.init(memmap, hhdm.offset, manager.endpointTable());
                }
            }
        } else {
            bootLog("HHDM request failed.\n");
        }
    } else {
        bootLog("Memmap request failed.\n");
    }

    if (!build_options.vmm_active) {
        bootLog("Scheduler: starting demo worker threads.\n");
        thread_a_id = scheduler.spawn(threadA) catch |err| {
            bootLog("Spawn A failed: ");
            bootLog(@errorName(err));
            bootLog("\n");
            while (true) arch.cpu.halt();
        };
        _ = scheduler.spawn(threadB) catch |err| {
            bootLog("Spawn B failed: ");
            bootLog(@errorName(err));
            bootLog("\n");
        };
    }

    if (!timer_initialized_early) {
        timer.init();
        bootLog("Timer initialized.\n");
    }

    bootLog("Catenary OS checks complete. Starting scheduler...\n");

    // Idle loop: enable interrupts, poll serial shell for operator input.
    // The shell is polled on every iteration; CPU halts between polls to
    // avoid monopolising the bus. An interrupt-driven serial driver and a
    // proper scheduler yield belong to a later phase.
    varde_shell.init();
    if (comptime builtin.cpu.arch == .x86_64) {
        idt.enableInterrupts();
    }

    const vmm_bridge = @import("vmm/microvm_bridge.zig");
    vmm_bridge.init();
    vmm_bridge.setBridgeContext(hhdm_offset_global, manager.endpointTable());

    while (true) {
        varde_shell.poll();
        scheduler.schedule();
        vmm_bridge.broadcastTelemetry(hhdm_offset_global, manager.endpointTable());
        if (build_options.services_active) {
            _ = @import("services/service_registry.zig");
        }
        arch.cpu.pause();
    }
}

pub export var limine_base_revision: [3]u64 = .{
    0xf9562b2d5c95a6c8,
    0x6a7b384944536bdc,
    1,
};

pub export var limine_requests_start: u64 linksection(".limine_requests_start") = 0;
pub export var limine_requests_end: u64 linksection(".limine_requests_end") = 0;
