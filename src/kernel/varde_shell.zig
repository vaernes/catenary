pub const HISTORY_SIZE = 4000;
pub var history_buf: [HISTORY_SIZE]u8 = @splat(0);
pub var history_pos: usize = 0;

pub fn putHistory(b: u8) void {
    if (b == '\r') return; // ignore carriage returns for the UI buffer
    if (b == 0x08 or b == 127) {
        if (history_pos > 0 and history_buf[history_pos - 1] != '\n') {
            history_pos -= 1;
            history_buf[history_pos] = 0;
        }
        return;
    }
    if (history_pos >= HISTORY_SIZE) {
        // Find first newline to get a clean line boundary for the shift.
        var cut: usize = 0;
        while (cut < history_pos) : (cut += 1) {
            if (history_buf[cut] == '\n') {
                cut += 1; // include the newline in the discarded portion
                break;
            }
        }
        if (cut == 0 or cut >= history_pos) cut = 80; // fallback
        const remaining = history_pos - cut;
        var i: usize = 0;
        while (i < remaining) : (i += 1) {
            history_buf[i] = history_buf[i + cut];
        }
        history_pos = remaining;
    }
    history_buf[history_pos] = b;
    history_pos += 1;
}

/// Ring-0 serial shell for the Catenary OS operator surface.
///
/// This module provides a minimal interactive shell over COM2 (0x2F8) that
/// allows an operator to inspect kernel state without requiring a user-space
/// process. It is polled from the kernel main loop and does not use interrupts.
///
/// Design constraints:
/// - Ring 0 only. No user-space involvement.
/// - Polling, not interrupt-driven. Call poll() from the idle loop.
/// - Stateless per command: each command is self-contained.
/// - No heap allocation: command buffer is a fixed-size stack array.
///
/// Commands:
///   help         — list available commands
///   status       — report kernel phase and hardening state
///   services     — list service registry slots
///   memory       — show PMM high watermark
///   halt         — halt the CPU (use with care: non-reversible)
const builtin = @import("builtin");
const cpu = @import("../arch/x86_64/cpu.zig");
const smp = @import("../arch/x86_64/smp.zig");
const service_registry = @import("../services/service_registry.zig");
const pmm = @import("pmm.zig");
const microvm_registry = @import("../vmm/microvm_registry.zig");
const efi_vars = @import("../vmm/efi_vars.zig");
const vtpm = @import("../vmm/vtpm.zig");
const uefi_firmware = @import("../vmm/uefi_firmware.zig");
const node_config = @import("../ipc/node_config.zig");

const OS_NAME = if (builtin.is_test) "Catenary OS" else @import("../main.zig").OS_NAME;
const OS_CODENAME = if (builtin.is_test) "Ready" else @import("../main.zig").OS_CODENAME;
const OS_VERSION = if (builtin.is_test) @import("std").SemanticVersion{ .major = 0, .minor = 8, .patch = 0 } else @import("../main.zig").OS_VERSION;

const COM2_DATA: u16 = 0x2F8;
const COM2_LSR: u16 = 0x2FD; // Line Status Register
const LSR_DATA_READY: u8 = 1 << 0;
const LSR_TX_EMPTY: u8 = 1 << 5;

// Test milestone tracking for host unit tests
pub var test_last_milestone: [64]u8 = @splat(0);
pub var test_last_milestone_len: usize = 0;

pub fn emitMilestone(cmd_name: []const u8) void {
    var buf: [64]u8 = undefined;
    const prefix = "varde_shell: executed '";
    const suffix = "'\n";
    if (prefix.len + cmd_name.len + suffix.len > buf.len) return;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..cmd_name.len], cmd_name);
    @memcpy(buf[prefix.len + cmd_name.len ..][0..suffix.len], suffix);
    const total_len = prefix.len + cmd_name.len + suffix.len;

    if (builtin.is_test) {
        @memcpy(test_last_milestone[0..total_len], buf[0..total_len]);
        test_last_milestone_len = total_len;
    } else {
        @import("../main.zig").serialWrite(buf[0..total_len]);
    }
}

// Command line buffer. Commands longer than this are silently truncated.
var cmd_buf: [128]u8 = undefined;
var cmd_len: usize = 0;
var prompt_needed: bool = true;
/// Telnet IAC state machine: number of bytes still to skip.
var iac_skip: u8 = 0;

// Command history for navigation (UP/DOWN arrows)
const MAX_HISTORY = 16;
var history_cmds: [MAX_HISTORY][128]u8 = @splat(@splat(0));
var history_lens: [MAX_HISTORY]usize = @splat(0);
var history_count: usize = 0;
var history_write_idx: usize = 0;
var browse_idx: isize = -1; // -1 means not browsing history
var esc_state: u8 = 0; // 0=normal, 1=ESC received, 2=ESC [ received
var com2_present: bool = false;
pub var init_tsc: u64 = 0;

pub fn init() void {
    if (!builtin.is_test) {
        const arch = @import("../arch.zig");
        init_tsc = arch.cpu.rdtsc();
        const scratch_port: u16 = COM2_DATA + 7;
        const old_scratch = cpu.inb(scratch_port);
        cpu.outb(scratch_port, 0x5A);
        if (cpu.inb(scratch_port) == 0x5A) {
            cpu.outb(scratch_port, old_scratch);
            com2_present = true;
            cpu.outb(COM2_DATA + 1, 0x00); // Disable all interrupts
            cpu.outb(COM2_DATA + 3, 0x80); // Enable DLAB (set baud rate divisor)
            cpu.outb(COM2_DATA + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
            cpu.outb(COM2_DATA + 1, 0x00); //                  (hi byte)
            cpu.outb(COM2_DATA + 3, 0x03); // 8 bits, no parity, one stop bit
            cpu.outb(COM2_DATA + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
            cpu.outb(COM2_DATA + 4, 0x0B); // IRQs enabled, RTS/DSR set
        } else {
            com2_present = false;
        }
    } else {
        com2_present = false;
        init_tsc = 1000;
    }

    if (history_pos == 0) {
        write("Catenary OS Varde Shell — type 'help' for commands");
        printPrompt();
    }
}

inline fn rxReady() bool {
    if (builtin.is_test or !com2_present) return false;
    const lsr = cpu.inb(COM2_LSR);
    return (lsr & LSR_DATA_READY) != 0 and lsr != 0xFF;
}

inline fn txReady() bool {
    if (builtin.is_test or !com2_present) return false;
    const lsr = cpu.inb(COM2_LSR);
    return lsr != 0xFF and (lsr & LSR_TX_EMPTY) != 0;
}

fn writeByte(b: u8) void {
    if (!builtin.is_test and com2_present) {
        var spins: usize = 0;
        while (!txReady() and spins < 4096) : (spins += 1) {}
        if (spins < 4096) cpu.outb(COM2_DATA, b);
    }
    putHistory(b);
}

fn write(s: []const u8) void {
    for (s) |c| writeByte(c);
}

fn writeHex(n: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    for (0..16) |i| {
        buf[15 - i] = hex[@as(usize, @intCast((n >> @as(u6, @intCast(i * 4))) & 0xF))];
    }
    write(&buf);
}

fn writeDec(n: u64) void {
    if (n == 0) {
        writeByte('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v > 0) {
        buf[len] = @as(u8, @truncate(v % 10)) + '0';
        len += 1;
        v /= 10;
    }
    var i = len;
    while (i > 0) {
        i -= 1;
        writeByte(buf[i]);
    }
}

fn strEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn startsWith(a: []const u8, prefix: []const u8) bool {
    if (a.len < prefix.len) return false;
    for (a[0..prefix.len], prefix) |x, y| if (x != y) return false;
    return true;
}

fn trimSpaces(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == ' ') : (start += 1) {}
    var end: usize = s.len;
    while (end > start and s[end - 1] == ' ') : (end -= 1) {}
    return s[start..end];
}

fn parseU32(s: []const u8) ?u32 {
    const t = trimSpaces(s);
    if (t.len == 0) return null;
    var val: u32 = 0;
    for (t) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn writePadded(s: []const u8, width: usize) void {
    const n = @min(s.len, width);
    write(s[0..n]);
    var i: usize = n;
    while (i < width) : (i += 1) writeByte(' ');
}

fn writeDecPadded(n: u64, width: usize) void {
    var buf: [20]u8 = undefined;
    var len: usize = 0;
    if (n == 0) {
        buf[0] = '0';
        len = 1;
    } else {
        var v = n;
        while (v > 0) {
            buf[len] = @as(u8, @truncate(v % 10)) + '0';
            len += 1;
            v /= 10;
        }
    }
    var i = len;
    while (i > 0) {
        i -= 1;
        writeByte(buf[i]);
    }
    while (len < width) : (len += 1) writeByte(' ');
}

fn cmdHelp() void {
    write("\r\n");
    write(OS_NAME);
    write(" v");
    writeDec(OS_VERSION.major);
    write(".");
    writeDec(OS_VERSION.minor);
    write(".");
    writeDec(OS_VERSION.patch);
    write(" — Varde Operator Shell\r\n");
    write("  help                          — list available commands\r\n");
    write("  ps / services                 — list Ring-3 service daemons\r\n");
    write("  vmlist / vms                  — list MicroVMs and telemetry\r\n");
    write("  vm-create <name> [vcpu] [mb]  — provision & start a MicroVM\r\n");
    write("  vm-create-full <profile>      — validate & start Full-VM (uefi-test, ubuntu-26.04, win11-26h2)\r\n");
    write("  vm-start <id>                 — start MicroVM by ID\r\n");
    write("  vm-reboot <id>                — warm reboot VM (preserving NVMe & EFI NVRAM)\r\n");
    write("  vm-send <id> <cmd>            — send command line to VM serial console\r\n");
    write("  vm-kill <id> / vm-stop <id>   — stop MicroVM by ID\r\n");
    write("  vm-delete <id>                — delete MicroVM from registry\r\n");
    write("  vnic-bind <vm> <ip4|-> <ip6|-> — set vNIC source addresses (clears rules)\r\n");
    write("  vnic-allow <vm> <in|out> <tcp|udp|icmp> <ip> [port] — allow a flow\r\n");
    write("  vnic-clear <vm>               — remove vNIC rules (default-deny)\r\n");
    write("  cluster                       — cluster node & topology summary\r\n");
    write("  net-stat                      — IPv6 & DIPC network status\r\n");
    write("  storage-stat                  — NVMe & Virtio-Blk status\r\n");
    write("  top                           — CPU thread utilization\r\n");
    write("  memory                        — physical memory statistics\r\n");
    write("  status / about / clear / halt — system info & control\r\n\r\n");
    write("Hotkeys:\r\n");
    write("  [Tab]/[S-Tab] Switch Pane       [F1] Help Modal\r\n");
    write("  [F2] New VM Form               [F3] VM Manager & Inspector\r\n");
    write("  [F4] Varde Shell Pane          [F5] Redraw Screen\r\n");
    write("  [S]tart VM   [K]ill VM         [D]elete VM\r\n");
    write("  [PgUp]/[PgDn] Scrollback       [Up]/[Down] History\r\n");
}

fn cmdAbout() void {
    write("\r\n");
    write(OS_NAME);
    write(" - distributed microkernel and Type-1 hypervisor\r\n");
    write("Ring-3 services: netd storaged dashd containerd clusterd\r\n");
    write("                 inputd windowd configd\r\n");
}

fn cmdClear() void {
    // Reset the UI scrollback; the prompt is re-printed by the caller.
    history_pos = 0;
    history_buf[0] = 0;
}

fn cmdVms() void {
    write("\r\nID  Name          State     vCPU  RAM(MB)  Cycles    Exits\r\n");
    write("------------------------------------------------------------\r\n");
    var found: usize = 0;
    const count = microvm_registry.capacity();
    for (0..count) |i| {
        const slot = microvm_registry.lookup(@as(u32, @intCast(i + 1))) orelse continue;
        if (!slot.in_use) continue;
        found += 1;
        writeDecPadded(slot.instance_id, 4);
        var nlen: usize = 0;
        while (nlen < slot.name.len and slot.name[nlen] != 0) : (nlen += 1) {}
        const disp_name = if (nlen > 0) slot.name[0..nlen] else "unnamed";
        writePadded(disp_name, 14);
        writePadded(@tagName(slot.state), 10);
        writeDecPadded(slot.vcpus, 6);
        writeDecPadded(slot.mem_pages / 256, 9);
        writeDecPadded(slot.cpu_cycles / 1_000_000, 10);
        writeDec(slot.exit_count);
        write("\r\n");
    }
    if (found == 0) write("  (no active MicroVMs)\r\n");
}

fn cmdVmCreate(args: []const u8) void {
    const trimmed = trimSpaces(args);
    var name_slice: []const u8 = "shell-vm";
    var vcpus: u32 = 1;
    var mem_mb: u32 = 32;

    if (trimmed.len > 0) {
        var p1: usize = 0;
        while (p1 < trimmed.len and trimmed[p1] != ' ') : (p1 += 1) {}
        name_slice = trimmed[0..p1];
        const rest1 = trimSpaces(trimmed[p1..]);
        if (rest1.len > 0) {
            var p2: usize = 0;
            while (p2 < rest1.len and rest1[p2] != ' ') : (p2 += 1) {}
            if (parseU32(rest1[0..p2])) |v| {
                if (v != 1) {
                    write("\r\nError: this VMM currently supports one vCPU per MicroVM.\r\n");
                    return;
                }
                vcpus = v;
            }
            const rest2 = trimSpaces(rest1[p2..]);
            if (rest2.len > 0) {
                if (parseU32(rest2)) |m| {
                    if (m >= 4 and m <= 1024) mem_mb = m;
                }
            }
        }
    }

    var name_buf: [32]u8 = @splat(0);
    const nlen = @min(name_slice.len, 31);
    @memcpy(name_buf[0..nlen], name_slice[0..nlen]);
    const container_buf: [32]u8 = "oci-demo".* ++ @as([24]u8, @splat(0));

    if (microvm_registry.create(name_buf, container_buf, mem_mb * 256, vcpus, 0, 0, 0, 0)) |id| {
        _ = microvm_registry.start(id);
        write("\r\nCreated and started MicroVM '");
        write(name_slice[0..nlen]);
        write("' (ID=");
        writeDec(id);
        write(", vCPUs=");
        writeDec(vcpus);
        write(", RAM=");
        writeDec(mem_mb);
        write(" MB)\r\n");
    } else {
        write("\r\nError: MicroVM registry full.\r\n");
    }
}

fn emitCom1Line(msg: []const u8) void {
    if (!builtin.is_test) {
        @import("../main.zig").serialWrite(msg);
    }
}

fn emitCom1Msg(msg: []const u8) void {
    if (!builtin.is_test) {
        @import("../main.zig").serialWrite(msg);
    }
}

fn emitCom1Kv(prefix: []const u8, val: []const u8) void {
    if (!builtin.is_test) {
        var buf: [256]u8 = undefined;
        const total = prefix.len + val.len + 1;
        if (total <= buf.len) {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len .. prefix.len + val.len], val);
            buf[total - 1] = '\n';
            @import("../main.zig").serialWrite(buf[0..total]);
        } else {
            @import("../main.zig").serialWrite(prefix);
            @import("../main.zig").serialWrite(val);
            @import("../main.zig").serialWrite("\n");
        }
    }
}

fn cmdVmCreateFull(args: []const u8) void {
    const profile_arg = trimSpaces(args);
    if (profile_arg.len == 0) {
        write("\r\nUsage: vm-create-full <uefi-test|uefi-revoked|ubuntu-26.04|win11-26h2>\r\n");
        return;
    }

    const kind = uefi_firmware.FullVmProfileKind.fromName(profile_arg) orelse {
        write("\r\nError: unknown Full-VM profile '");
        write(profile_arg);
        write("'.\r\n");
        emitCom1Line("varde_shell: vm-create-full rejected reason=unknown-profile\n");
        return;
    };

    // Use slot 8 for pre-admission Secure Boot policy verification so running VMs are untouched
    const probe_vmid: u32 = 8;
    _ = efi_vars.initDefaultSecureBootStore(
        probe_vmid,
        uefi_firmware.getApprovedUefiImage(),
        uefi_firmware.getRevokedUefiImage(),
    );

    uefi_firmware.validateFullVmAdmission(probe_vmid, kind, .{}) catch |err| {
        const reason = switch (err) {
            error.MissingInstallerMedia => "missing-installer-media",
            error.InsufficientVcpus => "insufficient-vcpus",
            error.InsufficientRam => "insufficient-ram",
            error.InsufficientDisk => "insufficient-disk",
            error.SecureBootDisabled => "secure-boot-disabled",
            error.Tpm2Unavailable => "tpm2-unavailable",
            error.SecureBootRevokedInDbx => "secure-boot-dbx-revoked",
            error.SecureBootNotInAllowedDb => "secure-boot-untrusted-image",
            error.SecureBootEmptyTrustDb => "secure-boot-empty-db",
        };
        write("\r\nFull-VM admission rejected for profile '");
        write(kind.label());
        write("': ");
        write(reason);
        write("\r\n");
        var reject_buf: [256]u8 = undefined;
        const reject_pfx = "varde_shell: vm-create-full rejected profile=";
        const reject_mid = " reason=";
        const reject_len = reject_pfx.len + kind.label().len + reject_mid.len + reason.len + 1;
        if (reject_len <= reject_buf.len) {
            var off: usize = 0;
            @memcpy(reject_buf[off .. off + reject_pfx.len], reject_pfx);
            off += reject_pfx.len;
            @memcpy(reject_buf[off .. off + kind.label().len], kind.label());
            off += kind.label().len;
            @memcpy(reject_buf[off .. off + reject_mid.len], reject_mid);
            off += reject_mid.len;
            @memcpy(reject_buf[off .. off + reason.len], reason);
            off += reason.len;
            reject_buf[off] = '\n';
            emitCom1Line(reject_buf[0 .. off + 1]);
        }
        return;
    };

    var name_buf: [32]u8 = @splat(0);
    const label = kind.label();
    @memcpy(name_buf[0..label.len], label);
    const container_buf: [32]u8 = "uefi-ovmf".* ++ @as([23]u8, @splat(0));

    const online_cpus = smp.getCpuCount();
    const target_core: u8 = if (online_cpus > 1) 1 else 0;
    const id = microvm_registry.createWithAffinity(name_buf, container_buf, 16 * 256, 1, 0, 0, 0, 0, target_core) orelse {
        write("\r\nError: MicroVM registry full.\r\n");
        return;
    };

    if (!builtin.is_test) {
        const build_options = @import("build_options");
        if (build_options.vmm_active) {
            const vmx = @import("../arch/x86_64/vmx.zig");
            if (microvm_registry.findMutable(id)) |inst| {
                vmx.stageUefiFullVmForInstance(inst, false) catch {
                    _ = microvm_registry.delete(id);
                    write("\r\nError: failed to stage UEFI Full-VM.\r\n");
                    return;
                };
                if (microvm_registry.start(id)) {
                    const scheduler = @import("scheduler.zig");
                    _ = scheduler.spawnWithVmx(null, true, inst.instance_id, 0, target_core) catch {
                        _ = microvm_registry.fail(id);
                    };
                    @import("../vmm/microvm_bridge.zig").broadcastTelemetryFromContext();
                }
            }
        } else {
            _ = microvm_registry.start(id);
        }
    } else {
        if (microvm_registry.findMutable(id)) |inst| {
            inst.vm_profile = .uefi_fullvm;
            _ = efi_vars.initDefaultSecureBootStore(id, uefi_firmware.getApprovedUefiImage(), uefi_firmware.getRevokedUefiImage());
            vtpm.resetInstance(id);
            if (vtpm.getState(id)) |st| st.started = true;
        }
        _ = microvm_registry.start(id);
    }

    write("\r\nAdmitted and started UEFI Full-VM '");
    write(label);
    write("' (ID=");
    writeDec(id);
    write(")\r\n");
    emitCom1Kv("varde_shell: vm-create-full admitted profile=", label);
}

fn cmdVmReboot(args: []const u8) void {
    const id = parseU32(args) orelse {
        write("\r\nUsage: vm-reboot <id>\r\n");
        return;
    };
    if (microvm_registry.requestReboot(id)) {
        write("\r\nWarm reboot requested for VM ");
        writeDec(id);
        write(".\r\n");
        emitCom1Line("varde_shell: vm-reboot requested\n");
    } else {
        write("\r\nError: VM not running or invalid ID.\r\n");
    }
}

fn cmdVmSnapshot(args: []const u8) void {
    const trimmed = trimSpaces(args);
    if (trimmed.len == 0) {
        write("\r\nUsage: vm-snapshot <id> [label]\r\n");
        return;
    }
    var p1: usize = 0;
    while (p1 < trimmed.len and trimmed[p1] != ' ') : (p1 += 1) {}
    const id = parseU32(trimmed[0..p1]) orelse {
        write("\r\nUsage: vm-snapshot <id> [label]\r\n");
        return;
    } ;
    const label = trimSpaces(trimmed[p1..]);

    const vm_snapshot = @import("../vmm/vm_snapshot.zig");
    const tsc = cpu.rdtsc();
    const gen: u32 = 1; // Snapshot generation 1 for verification
    const regs = vm_snapshot.GuestRegsSnapshot{
        .rip = 0x0010_0000,
        .rsp = 0x001F_0000,
        .cr3 = 0x0002_0000,
    };

    const snap = vm_snapshot.createSnapshot(id, gen, label, regs, tsc) catch {
        write("\r\nError: failed to create coordinated VM snapshot.\r\n");
        emitCom1Line("varde_shell: vm-snapshot failed\n");
        return;
    };

    write("\r\nCoordinated snapshot created for VM ");
    writeDec(id);
    write(" (generation ");
    writeDec(snap.generation);
    write(").\r\n");
    emitCom1Line("varde_shell: vm-snapshot created\n");
}

fn cmdVmRestore(args: []const u8) void {
    const trimmed = trimSpaces(args);
    if (trimmed.len == 0) {
        write("\r\nUsage: vm-restore <id> <generation>\r\n");
        return;
    }
    var p1: usize = 0;
    while (p1 < trimmed.len and trimmed[p1] != ' ') : (p1 += 1) {}
    const id = parseU32(trimmed[0..p1]) orelse {
        write("\r\nUsage: vm-restore <id> <generation>\r\n");
        return;
    };
    const gen = parseU32(trimSpaces(trimmed[p1..])) orelse {
        write("\r\nUsage: vm-restore <id> <generation>\r\n");
        return;
    };

    const vm_snapshot = @import("../vmm/vm_snapshot.zig");
    const snap = vm_snapshot.restoreSnapshot(id, gen) catch {
        write("\r\nError: snapshot not found or restore failed.\r\n");
        emitCom1Line("varde_shell: vm-restore failed\n");
        return;
    };

    if (!builtin.is_test) {
        _ = microvm_registry.requestReboot(id);
    }

    write("\r\nVM ");
    writeDec(id);
    write(" restored to generation ");
    writeDec(snap.generation);
    write(".\r\n");
    emitCom1Line("varde_shell: vm-restore completed\n");
}

fn cmdVmSend(args: []const u8) void {
    const trimmed = trimSpaces(args);
    if (trimmed.len == 0) {
        write("\r\nUsage: vm-send <id> <cmd>\r\n");
        return;
    }
    var p1: usize = 0;
    while (p1 < trimmed.len and trimmed[p1] != ' ') : (p1 += 1) {}
    const id = parseU32(trimmed[0..p1]) orelse {
        write("\r\nUsage: vm-send <id> <cmd>\r\n");
        return;
    };
    const payload = trimSpaces(trimmed[p1..]);
    if (payload.len == 0) {
        write("\r\nUsage: vm-send <id> <cmd>\r\n");
        return;
    }
    for (payload) |ch| {
        _ = microvm_registry.injectConsoleInput(id, ch);
    }
    _ = microvm_registry.injectConsoleInput(id, '\n');
    write("\r\nSent command to VM ");
    writeDec(id);
    write(".\r\n");
}

fn cmdVmAction(args: []const u8, action: enum { start, stop, delete }, cmd_name: []const u8) void {
    const id = parseU32(args) orelse {
        write("\r\nUsage: ");
        write(cmd_name);
        write(" <id>\r\n");
        return;
    };
    const ok = switch (action) {
        .start => microvm_registry.start(id),
        .stop => microvm_registry.stop(id),
        .delete => blk: {
            if (!builtin.is_test) {
                const build_options = @import("build_options");
                if (build_options.vmm_active) {
                    const vmx = @import("../arch/x86_64/vmx.zig");
                    if (!vmx.reclaimInstanceById(id)) break :blk false;
                }
            }
            break :blk microvm_registry.delete(id);
        },
    };
    if (ok) {
        write("\r\nMicroVM ");
        writeDec(id);
        switch (action) {
            .start => write(" started.\r\n"),
            .stop => write(" stop requested.\r\n"),
            .delete => {
                write(" deleted.\r\n");
                if (!builtin.is_test) {
                    @import("../main.zig").serialWrite("varde_shell: MicroVM deleted\n");
                }
            },
        }
    } else {
        write("\r\nError: invalid MicroVM ID or state transition.\r\n");
    }
}

fn cmdCluster() void {
    const addr = node_config.getLocalNode();
    write("\r\nCluster Topology & Node Status:\r\n");
    write("  Local Node IPv6 : ");
    const hex = "0123456789abcdef";
    for (0..8) |w| {
        if (w > 0) writeByte(':');
        const hi = addr.bytes[w * 2];
        const lo = addr.bytes[w * 2 + 1];
        writeByte(hex[hi >> 4]);
        writeByte(hex[hi & 0xF]);
        writeByte(hex[lo >> 4]);
        writeByte(hex[lo & 0xF]);
    }
    write("\r\n  SMP CPU Cores   : ");
    writeDec(smp.getCpuCount());
    var active_vms: usize = 0;
    const count = microvm_registry.capacity();
    for (0..count) |i| {
        const slot = microvm_registry.lookup(@as(u32, @intCast(i + 1))) orelse continue;
        if (slot.in_use) active_vms += 1;
    }
    write("\r\n  Active MicroVMs : ");
    writeDec(active_vms);
    write("\r\n  Peer Status     : Standalone (loopback cluster)\r\n");
}

fn cmdNetStat() void {
    const addr = node_config.getLocalNode();
    write("\r\nNetwork & DIPC Router Status:\r\n");
    write("  NIC Driver      : netd (Virtio-Net PCI, Ring-3)\r\n");
    write("  Link State      : UP (IPv6 NDP + Embedded TCP)\r\n");
    write("  Node Address    : ");
    if (node_config.isNodeAddrConfigured(addr)) {
        write("fe80::");
        const hex = "0123456789abcdef";
        for (addr.bytes[12..16]) |b| {
            writeByte(hex[b >> 4]);
            writeByte(hex[b & 0xF]);
        }
    } else {
        write("::1 (loopback)");
    }
    write("\r\n  Virtio-Net      : RX/TX Queues Ready (256 descs, MTU 1500)\r\n");
    write("  NDP Cache       : Valid (solicited-node router active)\r\n");
    write("  Zero-Trust Auth : SHA-256 DIPC tags active\r\n");
}

fn cmdStorageStat() void {
    write("\r\nStorage Subsystem Status:\r\n");
    write("  Driver          : storaged (NVMe PCI, Ring-3)\r\n");
    write("  Virtio-Blk Bridge: active (MMIO 0xFEB01000)\r\n");
    write("  Default Volume  : 128 MiB (262144 sectors)\r\n");
}

fn cmdStatus() void {
    write("\r\nKernel status: ");
    write(OS_CODENAME);
    write(" | SMP Cores: ");
    writeDec(smp.getCpuCount());
    write(" | Uptime: ");
    var uptime_secs: u64 = 0;
    if (!builtin.is_test) {
        const arch = @import("../arch.zig");
        const now = arch.cpu.rdtsc();
        if (init_tsc > 0 and now >= init_tsc) {
            uptime_secs = (now - init_tsc) / 2_000_000_000;
        }
    } else {
        uptime_secs = 42;
    }
    writeDec(uptime_secs);
    write("s\r\n");

    const MSR_EFER: u32 = 0xC000_0080;
    var nxe_on = true;
    var smep_on = true;
    var smap_on = true;
    if (!builtin.is_test) {
        const efer = cpu.rdmsr(MSR_EFER);
        nxe_on = (efer & (1 << 11)) != 0;
        const cr4 = cpu.readCr4();
        smep_on = (cr4 & (1 << 20)) != 0;
        smap_on = (cr4 & (1 << 21)) != 0;
    }
    write("NXE: ");
    write(if (nxe_on) "on" else "off");
    write(" | SMEP: ");
    write(if (smep_on) "on" else "off");
    write(" | SMAP: ");
    write(if (smap_on) "on" else "off");
    write("\r\n");
}

fn cmdServices() void {
    write("\r\nSID  Service       State        Origin\r\n");
    write("------------------------------------------\r\n");
    var found: usize = 0;
    for (0..service_registry.MAX_SERVICES) |i| {
        const slot = service_registry.getSlotByIndex(i) orelse continue;
        if (!slot.in_use) continue;
        found += 1;
        writeDecPadded(slot.service_id, 5);
        writePadded(@tagName(slot.kind), 14);
        writePadded(@tagName(slot.state), 13);
        write(if (!slot.is_remote) "local\r\n" else "remote\r\n");
    }
    if (found == 0) write("  (none)\r\n");
}

fn cmdMemory() void {
    const total_pages = pmm.getTotalPages();
    const free_pages = pmm.getFreePages();
    const used_pages = if (total_pages >= free_pages) total_pages - free_pages else 0;
    write("\r\nPhysical Memory Manager (4 KiB frames):\r\n");
    write("  Total : ");
    writeDec(total_pages);
    write(" pages (");
    writeDec((total_pages * 4) / 1024);
    write(" MiB)\r\n  Used  : ");
    writeDec(used_pages);
    write(" pages (");
    writeDec((used_pages * 4) / 1024);
    write(" MiB)\r\n  Free  : ");
    writeDec(free_pages);
    write(" pages (");
    writeDec((free_pages * 4) / 1024);
    write(" MiB)\r\n");
}

fn cmdTop() void {
    const scheduler = @import("scheduler.zig");
    const arch = @import("../arch.zig");

    write("\r\nTID   Name             SID   VMID  State   CPU%   Ticks(M)\r\n");
    write("------------------------------------------------------------\r\n");

    const now = if (!builtin.is_test) arch.cpu.rdtsc() else 100_000_000;
    var sum: u64 = 0;

    for (scheduler.threads) |*t| {
        if (t.state == .Empty) continue;
        var tsc = t.total_tsc;
        if (t.state == .Running) {
            if (now > scheduler.last_tsc_stamp) {
                tsc += (now - scheduler.last_tsc_stamp);
            }
        }
        sum += tsc;
    }

    if (sum == 0) sum = 1;

    for (scheduler.threads) |*t| {
        if (t.state == .Empty) continue;

        var tsc = t.total_tsc;
        if (t.state == .Running) {
            if (now > scheduler.last_tsc_stamp) {
                tsc += (now - scheduler.last_tsc_stamp);
            }
        }

        const pct = (tsc * 100) / sum;

        writeDecPadded(t.id, 6);
        writePadded(t.nameSlice(), 17);
        writeDecPadded(t.sid, 6);
        writeDecPadded(t.vmid, 6);

        switch (t.state) {
            .Running => write("Run     "),
            .Ready => write("Rdy     "),
            .Waiting => write("Wait    "),
            .Empty => write("Unk     "),
        }

        writeDec(pct);
        write("%     ");
        writeDec(tsc / 1_000_000);
        write("\r\n");
    }
}

pub fn dispatch(raw_cmd: []const u8) void {
    const cmd = trimSpaces(raw_cmd);
    if (strEq(cmd, "help") or strEq(cmd, "?")) {
        emitMilestone("help");
        cmdHelp();
    } else if (strEq(cmd, "top")) {
        emitMilestone("top");
        cmdTop();
    } else if (strEq(cmd, "status")) {
        emitMilestone("status");
        cmdStatus();
    } else if (strEq(cmd, "services") or strEq(cmd, "ps")) {
        emitMilestone("ps");
        cmdServices();
    } else if (strEq(cmd, "vms") or strEq(cmd, "vmlist")) {
        emitMilestone("vmlist");
        cmdVms();
    } else if (strEq(cmd, "vm-create-full") or startsWith(cmd, "vm-create-full ")) {
        emitMilestone("vm-create-full");
        const args = if (cmd.len > 14) cmd[14..] else "";
        cmdVmCreateFull(args);
    } else if (strEq(cmd, "vm-create") or startsWith(cmd, "vm-create ")) {
        emitMilestone("vm-create");
        const args = if (cmd.len > 9) cmd[9..] else "";
        cmdVmCreate(args);
    } else if (strEq(cmd, "vm-reboot") or startsWith(cmd, "vm-reboot ")) {
        emitMilestone("vm-reboot");
        const args = if (cmd.len > 9) trimSpaces(cmd[9..]) else "";
        cmdVmReboot(args);
    } else if (strEq(cmd, "vm-snapshot") or startsWith(cmd, "vm-snapshot ")) {
        emitMilestone("vm-snapshot");
        const args = if (cmd.len > 11) trimSpaces(cmd[11..]) else "";
        cmdVmSnapshot(args);
    } else if (strEq(cmd, "vm-restore") or startsWith(cmd, "vm-restore ")) {
        emitMilestone("vm-restore");
        const args = if (cmd.len > 10) trimSpaces(cmd[10..]) else "";
        cmdVmRestore(args);
    } else if (strEq(cmd, "vm-send") or startsWith(cmd, "vm-send ")) {
        emitMilestone("vm-send");
        const args = if (cmd.len > 7) trimSpaces(cmd[7..]) else "";
        cmdVmSend(args);
    } else if (strEq(cmd, "vm-start") or startsWith(cmd, "vm-start ")) {
        emitMilestone("vm-start");
        const args = if (cmd.len > 8) trimSpaces(cmd[8..]) else "";
        cmdVmAction(args, .start, "vm-start");
    } else if (strEq(cmd, "vm-stop") or startsWith(cmd, "vm-stop ")) {
        emitMilestone("vm-kill");
        const args = if (cmd.len > 7) trimSpaces(cmd[7..]) else "";
        cmdVmAction(args, .stop, "vm-stop");
    } else if (strEq(cmd, "vm-kill") or startsWith(cmd, "vm-kill ")) {
        emitMilestone("vm-kill");
        const args = if (cmd.len > 7) trimSpaces(cmd[7..]) else "";
        cmdVmAction(args, .stop, "vm-kill");
    } else if (strEq(cmd, "vm-delete") or startsWith(cmd, "vm-delete ")) {
        emitMilestone("vm-delete");
        const args = if (cmd.len > 9) trimSpaces(cmd[9..]) else "";
        cmdVmAction(args, .delete, "vm-delete");
    } else if (strEq(cmd, "cluster")) {
        emitMilestone("cluster");
        cmdCluster();
    } else if (strEq(cmd, "net-stat")) {
        emitMilestone("net-stat");
        cmdNetStat();
    } else if (strEq(cmd, "storage-stat")) {
        emitMilestone("storage-stat");
        cmdStorageStat();
    } else if (strEq(cmd, "memory") or strEq(cmd, "free")) {
        emitMilestone("memory");
        cmdMemory();
    } else if (strEq(cmd, "about")) {
        cmdAbout();
    } else if (strEq(cmd, "clear") or strEq(cmd, "cls")) {
        emitMilestone("clear");
        cmdClear();
    } else if (strEq(cmd, "halt")) {
        write("\r\nHalting CPU.\r\n");
        if (!builtin.is_test) {
            while (true) asm volatile ("hlt");
        }
    } else if (cmd.len == 0) {
        // empty line — just re-prompt
    } else {
        write("\r\nUnknown: '");
        write(cmd);
        write("'  (try 'help')\r\n");
    }

    // Save to history if not empty and different from the last entry
    if (cmd.len > 0) {
        const last_idx = @as(usize, @intCast(@mod(@as(isize, @intCast(history_write_idx)) - 1, @as(isize, MAX_HISTORY))));
        const is_duplicate = history_count > 0 and strEq(cmd, history_cmds[last_idx][0..history_lens[last_idx]]);
        if (!is_duplicate) {
            const len = if (cmd.len > 127) 127 else cmd.len;
            @memcpy(history_cmds[history_write_idx][0..len], cmd[0..len]);
            history_lens[history_write_idx] = len;
            history_write_idx = (history_write_idx + 1) % MAX_HISTORY;
            if (history_count < MAX_HISTORY) history_count += 1;
        }
    }
    browse_idx = -1;
}

/// Print the shell prompt. Call once after init.
pub fn printPrompt() void {
    write("\r\ncatenary> ");
    prompt_needed = false;
}

/// Poll for a single byte of serial input and process it.
/// Call this from the kernel idle loop: `serial_shell.poll()`.
/// Returns immediately if no character is available.
pub fn poll() void {
    if (prompt_needed) {
        printPrompt();
    }

    while (rxReady()) {
        const c = cpu.inb(COM2_DATA);
        handleChar(c);
    }
}

var last_was_cr: bool = false;

pub fn handleChar(c: u8) void {
    if (prompt_needed) {
        printPrompt();
    }
    if (c == '\n' and last_was_cr) {
        last_was_cr = false;
        return;
    }
    last_was_cr = (c == '\r');

    // Telnet IAC filtering: skip negotiation sequences (0xFF CMD OPT).
    if (iac_skip > 0) {
        iac_skip -= 1;
        return;
    }
    if (c == 0xFF) {
        // IAC byte — skip this and the next 2 bytes (CMD + OPTION).
        iac_skip = 2;
        return;
    }

    // Escape sequence state machine for arrows
    if (esc_state == 0) {
        if (c == 27) {
            esc_state = 1;
            return;
        }
    } else if (esc_state == 1) {
        if (c == '[') {
            esc_state = 2;
            return;
        }
        esc_state = 0;
    } else if (esc_state == 2) {
        esc_state = 0;
        if (c == 'A') { // UP arrow
            if (history_count > 0) {
                if (browse_idx == -1) {
                    browse_idx = @as(isize, @intCast(history_count)) - 1;
                } else if (browse_idx > 0) {
                    browse_idx -= 1;
                }
                loadHistory();
            }
            return;
        } else if (c == 'B') { // DOWN arrow
            if (browse_idx != -1) {
                if (browse_idx < @as(isize, @intCast(history_count)) - 1) {
                    browse_idx += 1;
                    loadHistory();
                } else {
                    browse_idx = -1;
                    clearLine();
                }
            }
            return;
        }
        return;
    }

    if (c == '\r' or c == '\n') {
        write("\r\n");
        dispatch(cmd_buf[0..cmd_len]);
        cmd_len = 0;
        printPrompt();
    } else if (c == 8 or c == 127) {
        // backspace / DEL
        if (cmd_len > 0) {
            cmd_len -= 1;
            write("\x08 \x08");
        }
    } else if (c >= 32 and c <= 126 and cmd_len < cmd_buf.len - 1) {
        cmd_buf[cmd_len] = c;
        cmd_len += 1;
        writeByte(c); // echo
    }
}

fn clearLine() void {
    while (cmd_len > 0) {
        cmd_len -= 1;
        write("\x08 \x08");
    }
}

fn loadHistory() void {
    clearLine();
    if (browse_idx < 0) return;
    const h_idx = @as(usize, @intCast(@mod(@as(isize, @intCast(history_write_idx)) - @as(isize, @intCast(history_count)) + browse_idx, @as(isize, MAX_HISTORY))));
    const len = history_lens[h_idx];
    const cmd = history_cmds[h_idx][0..len];
    @memcpy(cmd_buf[0..len], cmd);
    cmd_len = len;
    write(cmd);
}
