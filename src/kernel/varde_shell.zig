pub const HISTORY_SIZE = 4000;
pub var history_buf: [HISTORY_SIZE]u8 = [_]u8{0} ** HISTORY_SIZE;
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
const cpu = @import("../arch/x86_64/cpu.zig");
const service_registry = @import("../services/service_registry.zig");
const pmm = @import("pmm.zig");
const microvm_registry = @import("../vmm/microvm_registry.zig");
const main = @import("../main.zig");

const COM2_DATA: u16 = 0x2F8;
const COM2_LSR: u16 = 0x2FD; // Line Status Register
const LSR_DATA_READY: u8 = 1 << 0;
const LSR_TX_EMPTY: u8 = 1 << 5;

// Command line buffer. Commands longer than this are silently truncated.
var cmd_buf: [128]u8 = undefined;
var cmd_len: usize = 0;
var prompt_needed: bool = true;
/// Telnet IAC state machine: number of bytes still to skip.
var iac_skip: u8 = 0;

// Command history for navigation (UP/DOWN arrows)
const MAX_HISTORY = 16;
var history_cmds: [MAX_HISTORY][128]u8 = [_][128]u8{[_]u8{0} ** 128} ** MAX_HISTORY;
var history_lens: [MAX_HISTORY]usize = [_]usize{0} ** MAX_HISTORY;
var history_count: usize = 0;
var history_write_idx: usize = 0;
var browse_idx: isize = -1; // -1 means not browsing history
var esc_state: u8 = 0; // 0=normal, 1=ESC received, 2=ESC [ received

pub fn init() void {
    cpu.outb(COM2_DATA + 1, 0x00); // Disable all interrupts
    cpu.outb(COM2_DATA + 3, 0x80); // Enable DLAB (set baud rate divisor)
    cpu.outb(COM2_DATA + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
    cpu.outb(COM2_DATA + 1, 0x00); //                  (hi byte)
    cpu.outb(COM2_DATA + 3, 0x03); // 8 bits, no parity, one stop bit
    cpu.outb(COM2_DATA + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    cpu.outb(COM2_DATA + 4, 0x0B); // IRQs enabled, RTS/DSR set
}

inline fn rxReady() bool {
    const lsr = cpu.inb(COM2_LSR);
    return (lsr & LSR_DATA_READY) != 0 and lsr != 0xFF;
}

inline fn txReady() bool {
    return (cpu.inb(COM2_LSR) & LSR_TX_EMPTY) != 0;
}

fn writeByte(b: u8) void {
    while (!txReady()) {}
    cpu.outb(COM2_DATA, b);
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

fn cmdHelp() void {
    write("\r\n");
    write(main.OS_NAME);
    write(" v");
    writeDec(main.OS_VERSION.major);
    write(".");
    writeDec(main.OS_VERSION.minor);
    write(".");
    writeDec(main.OS_VERSION.patch);
    write("\r\n");
    write("The load-bearing span is secure.\r\n");
    write("  help     — this message\r\n");
    write("  status   — kernel phase and hardening\r\n");
    write("  top      — active process threads\r\n");
    write("  services — service registry slots\r\n");
    write("  vms      — list active MicroVM instances\r\n");
    write("  memory   — PMM page count\r\n");
    write("  halt     — halt the CPU\r\n");
}

fn cmdVms() void {
    write("\r\nMicroVM Registry Content:\r\n");
    write("  ID   State        Memory (Pages)   Cycles       Exits\r\n");
    var found: usize = 0;
    const count = microvm_registry.capacity();
    for (0..count) |i| {
        const slot = microvm_registry.lookup(@as(u32, @intCast(i + 1))) orelse continue;
        if (!slot.in_use) continue;
        found += 1;
        write("  ");
        writeDec(slot.instance_id);
        write("    ");
        write(@tagName(slot.state));
        write("     ");
        writeDec(slot.mem_pages);
        write("            ");
        writeDec(@as(u32, @truncate(slot.cpu_cycles / 1_000_000))); // Cycles in millions for brevity
        write("M      ");
        writeDec(@as(u32, @truncate(slot.exit_count)));
        write("\r\n");
    }
    if (found == 0) write("  (no active MicroVMs)\r\n");
}

fn cmdStatus() void {
    write("\r\nKernel status: ");
    write(main.OS_CODENAME);
    write("\r\n");
    // Report EFER NXE bit directly -- avoids depending on hardening module.
    const MSR_EFER: u32 = 0xC000_0080;
    const efer = cpu.rdmsr(MSR_EFER);
    write("NXE: ");
    write(if ((efer & (1 << 11)) != 0) "on" else "off");
    write("\r\n");
    // Report SMEP from CR4 bit 20.
    const cr4 = cpu.readCr4();
    write("SMEP: ");
    write(if ((cr4 & (1 << 20)) != 0) "on" else "off");
    write("\r\n");
}

fn cmdServices() void {
    write("\r\nService slots:\r\n");
    var found: usize = 0;
    for (0..service_registry.MAX_SERVICES) |i| {
        const slot = service_registry.getSlotByIndex(i) orelse continue;
        if (!slot.in_use) continue;
        found += 1;
        write("  [");
        writeDec(slot.service_id);
        write("] kind=");
        write(@tagName(slot.kind));
        write(" state=");
        write(@tagName(slot.state));
        write("\r\n");
    }
    if (found == 0) write("  (none)\r\n");
}

fn cmdMemory() void {
    write("\r\nPMM: page_size=4096\r\n");
    // Report highest tracked page if available via public accessor.
    // We report the next_search_page watermark (best available proxy).
    write("  (use 'status' for full kernel info)\r\n");
}

fn cmdTop() void {
    const scheduler = @import("scheduler.zig");
    const arch = @import("../arch.zig");

    write("\r\n=== THREAD TIME (TOP) ===\r\n");
    write("TID  SID  VMID State   Cpu   Ticks\r\n");
    write("--------------------------------------\r\n");

    // We read current TSC just once for the snapshot
    const now = arch.cpu.rdtsc();
    var sum: u64 = 0;

    // Compute total time first
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

        writeDec(t.id);
        write("\t");
        writeDec(t.sid);
        write("\t");
        writeDec(t.vmid);
        write("\t");

        switch (t.state) {
            .Running => write("Run  "),
            .Ready => write("Rdy  "),
            .Waiting => write("Wait "),
            .Empty => write("Unk  "),
        }
        write("\t");

        writeDec(pct);
        write("%\t");
        writeDec(tsc);
        write("\r\n");
    }
}

fn dispatch(cmd: []const u8) void {
    if (strEq(cmd, "help")) {
        cmdHelp();
    } else if (strEq(cmd, "top")) {
        cmdTop();
    } else if (strEq(cmd, "status")) {
        cmdStatus();
    } else if (strEq(cmd, "services")) {
        cmdServices();
    } else if (strEq(cmd, "vms")) {
        cmdVms();
    } else if (strEq(cmd, "memory")) {
        cmdMemory();
    } else if (strEq(cmd, "halt")) {
        write("\r\nHalting CPU.\r\n");
        while (true) asm volatile ("hlt");
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
    write("\r\nvarde> ");
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

pub fn handleChar(c: u8) void {
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
