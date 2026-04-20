const std = @import("std");
const lib = @import("lib.zig");

const SYS_REGISTER = 2;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_FB_DRAW = 16;
const SYS_MAP_RECV = 17;
const SYS_GET_VARDE_LOG = 21;

const BootstrapDescriptor = lib.BootstrapDescriptor;
const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;

const COLS: usize = 100; // 800px / 8px
const SHELL_START: u64 = 5;
const SHELL_ROWS: usize = 60;
const BOTTOM_ROW: u64 = SHELL_START + SHELL_ROWS;

var form_name: [32]u8 = [_]u8{0} ** 32;
var form_name_len: usize = 0;

// ── Row helpers ──────────────────────────────────────────────

fn emitRow(buf: [*]u8, dma_phys: u64, row: u64, token: u64) void {
    buf[COLS] = 0;
    _ = lib.syscall(SYS_FB_DRAW, dma_phys, (row << 32) | 0, token);
}

fn pad(buf: [*]u8, from: usize, to: usize, ch: u8) void {
    var i = from;
    while (i < to) : (i += 1) buf[i] = ch;
}

fn borderRow(buf: [*]u8, dma_phys: u64, row: u64, label: []const u8, right: []const u8, token: u64) void {
    buf[0] = '+';
    buf[1] = '-';
    buf[2] = '-';
    var p: usize = 3;
    if (label.len > 0) {
        buf[p] = '[';
        p += 1;
        buf[p] = ' ';
        p += 1;
        @memcpy(buf[p .. p + label.len], label);
        p += label.len;
        buf[p] = ' ';
        p += 1;
        buf[p] = ']';
        p += 1;
    }
    // Fill dashes leaving room for optional right-side label
    const right_start = COLS - 1 - right.len - 2;
    pad(buf, p, right_start, '-');
    p = right_start;
    if (right.len > 0) {
        @memcpy(buf[p .. p + right.len], right);
        p += right.len;
    }
    pad(buf, p, COLS - 1, '-');
    buf[COLS - 1] = '+';
    emitRow(buf, dma_phys, row, token);
}

fn contentRow(buf: [*]u8, dma_phys: u64, row: u64, text: []const u8, token: u64) void {
    buf[0] = '|';
    buf[1] = ' ';
    const len = @min(text.len, COLS - 4);
    @memcpy(buf[2 .. 2 + len], text[0..len]);
    pad(buf, 2 + len, COLS - 1, ' ');
    buf[COLS - 1] = '|';
    emitRow(buf, dma_phys, row, token);
}

fn blankRow(buf: [*]u8, dma_phys: u64, row: u64, token: u64) void {
    buf[0] = '|';
    pad(buf, 1, COLS - 1, ' ');
    buf[COLS - 1] = '|';
    emitRow(buf, dma_phys, row, token);
}

// ── Main draw ────────────────────────────────────────────────

fn drawTui(dma_phys: u64, token: u64) void {
    const buf: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA);

    // Row 0 : top border
    borderRow(buf, dma_phys, 0, "Catenary OS", "Varde Interactive GUI", token);

    // Row 1 : blank
    blankRow(buf, dma_phys, 1, token);

    // Row 2 : create-VM form
    {
        const prefix = "New VM:  ";
        const suffix = "_                                            [Enter] submit";
        @memcpy(buf[2 .. 2 + prefix.len], prefix);
        var p: usize = 2 + prefix.len;
        if (form_name_len > 0) {
            @memcpy(buf[p .. p + form_name_len], form_name[0..form_name_len]);
            p += form_name_len;
        }
        @memcpy(buf[p .. p + suffix.len], suffix);
        p += suffix.len;
        // Wrap as content row
        buf[0] = '|';
        buf[1] = ' ';
        pad(buf, p, COLS - 1, ' ');
        buf[COLS - 1] = '|';
        emitRow(buf, dma_phys, 2, token);
    }

    // Row 3 : blank
    blankRow(buf, dma_phys, 3, token);

    // Row 4 : separator with shell label
    borderRow(buf, dma_phys, 4, "Shell Log", "", token);

    // Rows 5..64 : shell history
    const log_addr: u64 = dma_phys + 2048;
    const history_len = lib.syscall(SYS_GET_VARDE_LOG, log_addr, 0, token);
    const hist: [*]const u8 = @ptrFromInt(DMA_BASE_VA + 2048);

    // Find last SHELL_ROWS lines by scanning backwards.
    var line_starts: [SHELL_ROWS + 1]usize = undefined;
    var n_lines: usize = 0;

    if (history_len > 0) {
        var i: usize = history_len;
        while (i > 0 and n_lines < SHELL_ROWS) {
            i -= 1;
            if (hist[i] == '\n' and i + 1 < history_len) {
                line_starts[n_lines] = i + 1;
                n_lines += 1;
            }
        }
        if (n_lines < SHELL_ROWS and i == 0) {
            line_starts[n_lines] = 0;
            n_lines += 1;
        }
    }

    // Render lines oldest-first, pad remaining rows.
    var row: u64 = SHELL_START;
    var li: usize = n_lines;
    while (li > 0) {
        li -= 1;
        const start = line_starts[li];
        var end = start;
        while (end < history_len and hist[end] != '\n') : (end += 1) {}
        const line_len = @min(end - start, COLS - 4);
        buf[0] = '|';
        buf[1] = ' ';
        if (line_len > 0)
            @memcpy(buf[2 .. 2 + line_len], hist[start .. start + line_len]);
        pad(buf, 2 + line_len, COLS - 1, ' ');
        buf[COLS - 1] = '|';
        emitRow(buf, dma_phys, row, token);
        row += 1;
    }
    // Fill remaining rows with blank bordered lines.
    while (row < BOTTOM_ROW) : (row += 1) {
        blankRow(buf, dma_phys, row, token);
    }

    // Bottom border : status bar
    borderRow(buf, dma_phys, BOTTOM_ROW, "windowd : endpoint 9", "v0.1.0", token);
}

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    _ = lib.syscall(SYS_REGISTER, 0, 9, token);
    lib.serialWrite("windowd: registered at endpoint 9\n");
    lib.serialWrite("windowd: starting TUI...\n");

    const dma_phys = lib.syscall(SYS_ALLOC_DMA, 2, 0, token);
    if (dma_phys == 0) while (true) asm volatile ("pause");

    drawTui(dma_phys, token);

    while (true) {
        const page_phys = lib.syscall(3, 0, 0, token); // SYS_RECV
        if (page_phys == 0) {
            asm volatile ("pause");
            continue;
        }
        const recv_va = lib.syscall(17, page_phys, 0, token); // SYS_MAP_RECV
        if (recv_va == 0) {
            _ = lib.syscall(4, page_phys, 0, token);
            continue;
        }

        const payload_hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
        if (payload_hdr.src.endpoint == 8) { // from inputd
            const evt: *align(1) const extern struct {
                event_type: u8,
                ascii: u8,
                scancode: u8,
            } = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);

            if (evt.ascii != 0) {
                if (evt.ascii == 0x08 and form_name_len > 0) { // backspace
                    form_name_len -= 1;
                } else if (evt.ascii == '\n') {
                    if (form_name_len > 0) {
                        const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 4096); // slot 1 VA
                        const local_node = lib.queryCurrentNode(bs, token, dma_phys + 4096, DMA_BASE_VA + 4096, 9) orelse lib.Ipv6Addr{ .bytes = bs.local_node };
                        const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
                        head.* = .{
                            .magic = lib.WireMagic,
                            .version = lib.WireVersion,
                            .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
                            .payload_len = @as(u32, @intCast(@sizeOf(lib.ControlHeader) + @sizeOf(lib.CreateMicrovmPayload))),
                            .auth_tag = 0,
                            .src = .{ .node = local_node, .endpoint = 9 },
                            .dst = .{ .node = local_node, .endpoint = 2 },
                        };
                        const ctrl: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
                        ctrl.* = .{
                            .op = .create_microvm,
                            .payload_len = @as(u32, @intCast(@sizeOf(lib.CreateMicrovmPayload))),
                        };
                        const create_payload: *align(1) lib.CreateMicrovmPayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
                        create_payload.* = .{
                            .mem_pages = 16384,
                            .vcpus = 1,
                            .kernel_phys = bs.linux_bzimage_phys,
                            .kernel_size = bs.linux_bzimage_size,
                            .initramfs_phys = bs.initramfs_phys,
                            .initramfs_size = bs.initramfs_size,
                            .name = [_]u8{0} ** 32,
                        };
                        @memcpy(create_payload.name[0..form_name_len], form_name[0..form_name_len]);

                        _ = lib.syscall(SYS_SEND_PAGE, dma_phys + 4096, 0, token);
                        form_name_len = 0;
                    }
                } else if (form_name_len < 31) {
                    form_name[form_name_len] = evt.ascii;
                    form_name_len += 1;
                }
                drawTui(dma_phys, token);
            }
        }

        _ = lib.syscall(4, page_phys, 0, token);
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
