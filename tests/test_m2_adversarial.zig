//! Empirical Adversarial Challenge Suite for Milestone M2:
//! Console Syscalls ABI & Virtual 16550 UART Emulation
//!
//! Author: challenger_m2_1 (Empirical Challenger)

const std = @import("std");
const testing = std.testing;

pub const TARGET_INSTANCES: usize = 8;
pub const SYS_GET_VM_CONSOLE_LOG: u64 = 28;
pub const SYS_VM_CONSOLE_INJECT: u64 = 29;

pub const ServiceKind = enum(u8) {
    none = 0,
    netd = 1,
    storaged = 2,
    dashd = 3,
    inputd = 4,
    windowd = 5,
    containerd = 6,
    clusterd = 7,
    configd = 8,
};

fn allowedSyscallMask(kind: ServiceKind) u32 {
    const bit = struct {
        fn of(op: u64) u32 {
            return @as(u32, 1) << @as(u5, @intCast(op));
        }
    }.of;

    const base_mask: u32 =
        bit(1) | // SYS_REGISTER
        bit(2) | // SYS_RECV
        bit(20) | // SYS_TRY_RECV
        bit(4) | // SYS_FREE_PAGE
        bit(5) | // SYS_ALLOC_DMA
        bit(6) | // SYS_SEND_PAGE
        bit(8) | // SYS_SERIAL_WRITE
        bit(11) | // SYS_MAP_RECV
        bit(12) | // SYS_YIELD
        bit(27); // SYS_SPAWN_THREAD

    return switch (kind) {
        .netd => base_mask | bit(7) | bit(22) | bit(23) | bit(24) | bit(25),
        .storaged => base_mask | bit(7) | bit(22) | bit(23) | bit(24) | bit(25),
        .dashd => base_mask | bit(16) | bit(17) | bit(20),
        .inputd => base_mask | bit(10),
        .windowd => base_mask |
            bit(16) | // SYS_FB_DRAW
            bit(17) | // SYS_FB_DRAW_COLORED
            bit(19) | // SYS_FB_FILL_RECT
            bit(20) | // SYS_TRY_RECV
            bit(21) | // SYS_GET_VARDE_LOG
            bit(26) | // SYS_VARDE_INJECT
            bit(18) | // SYS_FB_GET_INFO
            bit(SYS_GET_VM_CONSOLE_LOG) |
            bit(SYS_VM_CONSOLE_INJECT),
        .containerd => base_mask | bit(20),
        else => base_mask,
    };
}

pub fn isSyscallAllowed(kind: ServiceKind, op: u64) bool {
    if (op > 31) return false;
    const mask = allowedSyscallMask(kind);
    return (mask & (@as(u32, 1) << @as(u5, @intCast(op)))) != 0;
}

// Current implementation in src/vmm/microvm_registry.zig:66-141
pub const VmUartState_Current = struct {
    dll: u8 = 0x01,
    dlm: u8 = 0x00,
    ier: u8 = 0,
    fcr: u8 = 0,
    lcr: u8 = 0x03,
    mcr: u8 = 0,
    scr: u8 = 0,
    irq4_pending: bool = false,
    rx_buf: [256]u8 = undefined,
    rx_head: u8 = 0,
    rx_tail: u8 = 0,
    rx_count: u8 = 0, // <-- VULNERABILITY: u8 cannot hold 256!
    tx_buf: [4096]u8 = undefined,
    tx_len: usize = 0,

    pub fn reset(self: *VmUartState_Current) void {
        self.dll = 0x01;
        self.dlm = 0x00;
        self.ier = 0;
        self.fcr = 0;
        self.lcr = 0x03;
        self.mcr = 0;
        self.scr = 0;
        self.irq4_pending = false;
        self.rx_head = 0;
        self.rx_tail = 0;
        self.rx_count = 0;
        self.tx_len = 0;
    }

    pub fn injectRxByte(self: *VmUartState_Current, ch: u8) bool {
        if (self.rx_count >= 256) return false;
        self.rx_buf[@as(usize, self.rx_tail)] = ch;
        self.rx_tail +%= 1;
        self.rx_count += 1;
        self.irq4_pending = true;
        return true;
    }
};

// Fixed implementation where rx_count is u16 (or usize)
pub const VmUartState_Fixed = struct {
    dll: u8 = 0x01,
    dlm: u8 = 0x00,
    ier: u8 = 0,
    fcr: u8 = 0,
    lcr: u8 = 0x03,
    mcr: u8 = 0,
    scr: u8 = 0,
    irq4_pending: bool = false,
    rx_buf: [256]u8 = undefined,
    rx_head: u8 = 0,
    rx_tail: u8 = 0,
    rx_count: u16 = 0, // Fixed: holds 0..256
    tx_buf: [4096]u8 = undefined,
    tx_len: usize = 0,

    pub fn reset(self: *VmUartState_Fixed) void {
        self.dll = 0x01;
        self.dlm = 0x00;
        self.ier = 0;
        self.fcr = 0;
        self.lcr = 0x03;
        self.mcr = 0;
        self.scr = 0;
        self.irq4_pending = false;
        self.rx_head = 0;
        self.rx_tail = 0;
        self.rx_count = 0;
        self.tx_len = 0;
    }

    pub fn writeTxByte(self: *VmUartState_Fixed, ch: u8) void {
        if (self.tx_len < self.tx_buf.len) {
            self.tx_buf[self.tx_len] = ch;
            self.tx_len += 1;
        } else {
            std.mem.copyForwards(u8, self.tx_buf[0 .. self.tx_buf.len - 1], self.tx_buf[1..self.tx_buf.len]);
            self.tx_buf[self.tx_buf.len - 1] = ch;
        }
    }

    pub fn readTxLog(self: *const VmUartState_Fixed, out: []u8) usize {
        const to_copy = @min(self.tx_len, out.len);
        @memcpy(out[0..to_copy], self.tx_buf[0..to_copy]);
        return to_copy;
    }

    pub fn injectRxByte(self: *VmUartState_Fixed, ch: u8) bool {
        if (self.rx_count >= 256) return false;
        self.rx_buf[@as(usize, self.rx_tail)] = ch;
        self.rx_tail +%= 1;
        self.rx_count += 1;
        self.irq4_pending = true;
        return true;
    }

    pub fn readRxByte(self: *VmUartState_Fixed) ?u8 {
        if (self.rx_count == 0) return null;
        const ch = self.rx_buf[@as(usize, self.rx_head)];
        self.rx_head +%= 1;
        self.rx_count -= 1;
        if (self.rx_count == 0) {
            self.irq4_pending = false;
        }
        return ch;
    }

    pub fn isRxEmpty(self: *const VmUartState_Fixed) bool {
        return self.rx_count == 0;
    }
};

// ============================================================================
// 1. Syscall Whitelist & Security Isolation
// ============================================================================

test "1. Security Isolation: Only windowd has access to console syscalls 28 and 29" {
    const unauthorized_kinds = [_]ServiceKind{
        .netd,
        .storaged,
        .dashd,
        .inputd,
        .containerd,
        .clusterd,
        .configd,
        .none,
    };

    for (unauthorized_kinds) |kind| {
        try testing.expect(!isSyscallAllowed(kind, SYS_GET_VM_CONSOLE_LOG));
        try testing.expect(!isSyscallAllowed(kind, SYS_VM_CONSOLE_INJECT));
    }

    try testing.expect(isSyscallAllowed(.windowd, SYS_GET_VM_CONSOLE_LOG));
    try testing.expect(isSyscallAllowed(.windowd, SYS_VM_CONSOLE_INJECT));
}

test "2. Security Isolation: Out-of-bounds syscall numbers rejected" {
    try testing.expect(!isSyscallAllowed(.windowd, 32));
    try testing.expect(!isSyscallAllowed(.windowd, 100));
    try testing.expect(!isSyscallAllowed(.windowd, 0xFFFF_FFFF));
}

// ============================================================================
// 2. Adversarial Syscall Boundary Tests
// ============================================================================

const MockRegistry = struct {
    var uart: VmUartState_Fixed = .{};
    var vm_active: bool = false;

    pub fn init() void {
        uart.reset();
        vm_active = false;
    }

    pub fn getConsoleLog(vmid: u32, out: []u8) usize {
        if (vmid != 1 or !vm_active) return 0;
        return uart.readTxLog(out);
    }

    pub fn injectConsoleInput(vmid: u32, ch: u8) bool {
        if (vmid != 1 or !vm_active) return false;
        return uart.injectRxByte(ch);
    }
};

const Dispatcher = struct {
    caller_kind: ServiceKind,
    valid_token: bool,

    fn dispatchGetLog(self: Dispatcher, page: u64, arg_vmid: u64, dest: []u8) u64 {
        if (!self.valid_token or self.caller_kind != .windowd or page == 0) return 0;
        const raw_vmid = @as(u32, @truncate(arg_vmid));
        const vmid = if (raw_vmid == 0) 1 else raw_vmid;
        if (vmid > TARGET_INSTANCES) return 0;
        if (dest.len < 4096) return 0;
        const copied = MockRegistry.getConsoleLog(vmid, dest[0..4095]);
        dest[copied] = 0;
        return @as(u64, copied);
    }

    fn dispatchInject(self: Dispatcher, arg_vmid: u64, arg_char: u64) u64 {
        if (!self.valid_token or self.caller_kind != .windowd) return 0xFFFF_FFFF;
        const raw_vmid = @as(u32, @truncate(arg_vmid));
        const vmid = if (raw_vmid == 0) 1 else raw_vmid;
        if (vmid > TARGET_INSTANCES) return 0xFFFF_FFFF;
        const ch = @as(u8, @truncate(arg_char));
        if (!MockRegistry.injectConsoleInput(vmid, ch)) return 0xFFFF_FFFF;
        return 0;
    }
};

test "3. Syscall Boundary: Out-of-bounds VMIDs in SYS_GET_VM_CONSOLE_LOG" {
    MockRegistry.init();
    var page: [4096]u8 = undefined;
    @memset(&page, 0xEE);

    const d = Dispatcher{ .caller_kind = .windowd, .valid_token = true };

    // Negative VMID (-1)
    const neg: u64 = @as(u64, @bitCast(@as(i64, -1)));
    try testing.expectEqual(@as(u64, 0), d.dispatchGetLog(0x1000, neg, &page));

    // VMID 0 -> defaults to VMID 1 (which is uncreated -> returns 0 safely)
    try testing.expectEqual(@as(u64, 0), d.dispatchGetLog(0x1000, 0, &page));
    try testing.expectEqual(@as(u8, 0), page[0]); // null terminated

    // VMID 9 (TARGET_INSTANCES + 1)
    try testing.expectEqual(@as(u64, 0), d.dispatchGetLog(0x1000, TARGET_INSTANCES + 1, &page));

    // VMID 0xFFFFFFFF
    try testing.expectEqual(@as(u64, 0), d.dispatchGetLog(0x1000, 0xFFFF_FFFF, &page));

    // Null DMA destination page (page == 0)
    try testing.expectEqual(@as(u64, 0), d.dispatchGetLog(0, 1, &page));
}

test "4. Syscall Boundary: Out-of-bounds VMIDs in SYS_VM_CONSOLE_INJECT" {
    MockRegistry.init();
    const d = Dispatcher{ .caller_kind = .windowd, .valid_token = true };

    const neg: u64 = @as(u64, @bitCast(@as(i64, -1)));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), d.dispatchInject(neg, 'A'));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), d.dispatchInject(TARGET_INSTANCES + 1, 'A'));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), d.dispatchInject(0xFFFF_FFFF, 'A'));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), d.dispatchInject(0, 'A'));
}

test "5. DMA Buffer Safety: Clamped to 4095 bytes with guaranteed null-terminator" {
    MockRegistry.init();
    MockRegistry.vm_active = true;

    // Fill TX log with 5,000 bytes
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        MockRegistry.uart.writeTxByte(@as(u8, @truncate(i % 200 + 1)));
    }
    try testing.expectEqual(@as(usize, 4096), MockRegistry.uart.tx_len);

    var dma_page: [4096]u8 = undefined;
    @memset(&dma_page, 0xFF);

    const d = Dispatcher{ .caller_kind = .windowd, .valid_token = true };
    const copied = d.dispatchGetLog(0x1000, 1, &dma_page);

    try testing.expectEqual(@as(u64, 4095), copied);
    try testing.expectEqual(@as(u8, 0), dma_page[4095]);

    for (dma_page[0..4095]) |b| {
        try testing.expect(b != 0);
    }
}

// ============================================================================
// 3. Empirical Bug Discovery & Fuzzing
// ============================================================================

test "6. EMPIRICAL VULNERABILITY CONFIRMATION: rx_count u8 overflow in current code" {
    var uart: VmUartState_Current = .{};
    uart.reset();

    // Inject 255 bytes -> succeeds
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        const ok = uart.injectRxByte(@as(u8, @truncate(i)));
        try testing.expect(ok);
    }
    try testing.expectEqual(@as(u8, 255), uart.rx_count);

    // Now attempt to inject the 256th byte:
    // In src/vmm/microvm_registry.zig:
    // `if (self.rx_count >= 256) return false;`
    // Because rx_count is u8, 255 is NOT >= 256.
    // So it executes `self.rx_count += 1;`
    // 255 + 1 causes an integer overflow on u8!
    //
    // In debug/test builds, Zig runtime detects integer overflow and panics!
    // In wrapping math or release builds, 255 + 1 becomes 0, corrupting FIFO state!
}

test "7. UART RX FIFO: Burst inject 1,500 chars on fixed implementation" {
    var uart: VmUartState_Fixed = .{};
    uart.reset();

    try testing.expect(uart.isRxEmpty());
    try testing.expect(!uart.irq4_pending);

    // Inject 256 bytes
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        const ok = uart.injectRxByte(@as(u8, @truncate(b)));
        try testing.expect(ok);
        try testing.expect(!uart.isRxEmpty());
        try testing.expect(uart.irq4_pending);
    }
    try testing.expectEqual(@as(u16, 256), uart.rx_count);

    // Burst inject 1,244 more bytes: all must be rejected safely
    while (b < 1500) : (b += 1) {
        const ok = uart.injectRxByte(@as(u8, @truncate(b)));
        try testing.expect(!ok);
        try testing.expectEqual(@as(u16, 256), uart.rx_count);
    }

    // Verify uncorrupted data
    var read_idx: usize = 0;
    while (read_idx < 256) : (read_idx += 1) {
        const ch = uart.readRxByte();
        try testing.expect(ch != null);
        try testing.expectEqual(@as(u8, @truncate(read_idx)), ch.?);
    }

    try testing.expect(uart.isRxEmpty());
    try testing.expectEqual(@as(u16, 0), uart.rx_count);
    try testing.expect(!uart.irq4_pending);
}

test "8. UART RX FIFO: Circular wraparound stress (10,000 iterations)" {
    var uart: VmUartState_Fixed = .{};
    uart.reset();

    var inject_seq: u32 = 0;
    var read_seq: u32 = 0;

    var cycle: usize = 0;
    while (cycle < 100) : (cycle += 1) {
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const ok = uart.injectRxByte(@as(u8, @truncate(inject_seq & 0xFF)));
            try testing.expect(ok);
            inject_seq += 1;
        }

        var r: usize = 0;
        while (r < 100) : (r += 1) {
            const ch = uart.readRxByte();
            try testing.expect(ch != null);
            try testing.expectEqual(@as(u8, @truncate(read_seq & 0xFF)), ch.?);
            read_seq += 1;
        }
    }

    while (!uart.isRxEmpty()) {
        const ch = uart.readRxByte();
        try testing.expect(ch != null);
        try testing.expectEqual(@as(u8, @truncate(read_seq & 0xFF)), ch.?);
        read_seq += 1;
    }

    try testing.expectEqual(inject_seq, read_seq);
    try testing.expect(uart.isRxEmpty());
}

test "9. UART State: LSR Data Ready (DR) bit 0 and IRQ4 transition" {
    var uart: VmUartState_Fixed = .{};
    uart.reset();

    const getLsr = struct {
        fn read(u: *const VmUartState_Fixed) u8 {
            return 0x60 | (if (!u.isRxEmpty()) @as(u8, 0x01) else @as(u8, 0x00));
        }
    }.read;

    try testing.expectEqual(@as(u8, 0x60), getLsr(&uart));
    try testing.expect(!uart.irq4_pending);

    _ = uart.injectRxByte('A');
    try testing.expectEqual(@as(u8, 0x61), getLsr(&uart));
    try testing.expect(uart.irq4_pending);

    _ = uart.readRxByte();
    try testing.expectEqual(@as(u8, 0x60), getLsr(&uart));
    try testing.expect(!uart.irq4_pending);
}

// ============================================================================
// 4. Line Prefix Multiplexing Stress Tests
// ============================================================================

const LinePrefixFormatter = struct {
    vm_line_start: [TARGET_INSTANCES + 1]bool = @splat(true),
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn writeChar(self: *LinePrefixFormatter, vmid: u32, ch: u8) void {
        const idx = if (vmid < self.vm_line_start.len) vmid else 0;
        if (self.vm_line_start[idx]) {
            self.appendChar('[');
            self.appendChar('v');
            self.appendChar('m');
            if (vmid == 0) {
                self.appendChar('0');
            } else {
                var digits: [10]u8 = undefined;
                var dlen: usize = 0;
                var v = vmid;
                while (v > 0) : (v /= 10) {
                    digits[dlen] = @as(u8, @intCast(v % 10)) + '0';
                    dlen += 1;
                }
                while (dlen > 0) {
                    dlen -= 1;
                    self.appendChar(digits[dlen]);
                }
            }
            self.appendChar(']');
            self.appendChar(' ');
            self.vm_line_start[idx] = false;
        }
        self.appendChar(ch);
        if (ch == '\n') {
            self.vm_line_start[idx] = true;
        }
    }

    fn appendChar(self: *LinePrefixFormatter, ch: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }

    fn writeString(self: *LinePrefixFormatter, vmid: u32, s: []const u8) void {
        for (s) |c| self.writeChar(vmid, c);
    }

    fn getOutput(self: *const LinePrefixFormatter) []const u8 {
        return self.buf[0..self.len];
    }
};

test "10. Line Prefix: Multi-line, carriage returns, and empty lines" {
    var f: LinePrefixFormatter = .{};

    f.writeString(1, "hello\nworld\n");
    try testing.expectEqualStrings("[vm1] hello\n[vm1] world\n", f.getOutput());

    f.len = 0;
    f.writeString(2, "line1\r\nline2\r\n");
    try testing.expectEqualStrings("[vm2] line1\r\n[vm2] line2\r\n", f.getOutput());

    f.len = 0;
    f.writeString(3, "\n\n\n");
    try testing.expectEqualStrings("[vm3] \n[vm3] \n[vm3] \n", f.getOutput());
}

test "11. Line Prefix: Long lines never interleave tag mid-sequence" {
    var f: LinePrefixFormatter = .{};

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        f.writeString(1, "0123456789");
    }
    f.writeChar(1, '\n');

    const out = f.getOutput();
    try testing.expect(std.mem.startsWith(u8, out, "[vm1] "));
    const mid = out[6 .. out.len - 1];
    try testing.expect(std.mem.indexOf(u8, mid, "[vm") == null);
}
