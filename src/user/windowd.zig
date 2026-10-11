const std = @import("std");
const lib = @import("lib.zig");

// Syscall ops (mirrors lib.zig constants)
const SYS_REGISTER = lib.SYS_REGISTER;
const SYS_TRY_RECV = lib.SYS_TRY_RECV;
const SYS_MAP_RECV = lib.SYS_MAP_RECV;
const SYS_FREE_PAGE = lib.SYS_FREE_PAGE;
const SYS_ALLOC_DMA = lib.SYS_ALLOC_DMA;
const SYS_SEND_PAGE = lib.SYS_SEND_PAGE;
const SYS_FB_DRAW_COLORED = lib.SYS_FB_DRAW_COLORED;
const SYS_FB_FILL_RECT = lib.SYS_FB_FILL_RECT;
const SYS_GET_VARDE_LOG = lib.SYS_GET_VARDE_LOG;
const SYS_VARDE_INJECT = lib.SYS_VARDE_INJECT;
const SYS_FB_GET_INFO = lib.SYS_FB_GET_INFO;

const USER_BOOTSTRAP_VADDR: usize = lib.USER_BOOTSTRAP_VADDR;
const DMA_BASE_VA: u64 = lib.DMA_BASE_VA;

// DMA page layout (each slot = 4096 bytes)
const DMA_TEXT_SLOT: u64 = 0;
const DMA_LOG_SLOT: u64 = 1;
const DMA_SCRATCH_SLOT: u64 = 2;
const DMA_NUM_PAGES: u64 = 4;

var COLS: usize = 100;
var ROWS: usize = 75;
var SCREEN_WIDTH: u32 = 800;
var SCREEN_HEIGHT: u32 = 600;

// Branding palette
const COLOR_SEA_GRAY: u32 = 0x004A4E69;
const COLOR_TERRACOTTA: u32 = 0x00E2725B;
const COLOR_GOLDEN_YELLOW: u32 = 0x00FFC300;
const COLOR_WHITE: u32 = 0x00FFFFFF;
const COLOR_GREEN: u32 = 0x0000CC44;
const COLOR_RED: u32 = 0x00FF4444;
const COLOR_HIGHLIGHT: u32 = 0x005BC0EB;
const COLOR_DIM: u32 = 0x00888888;

// --- UI State ---
var focused_pane: u8 = 0; // 0=VM Manager, 1=New VM Form, 2=Shell
var focused_form_field: u8 = 0; // 0=name, 1=vcpus, 2=mem
var form_name: [32]u8 = [_]u8{0} ** 32;
var form_name_len: usize = 0;
var form_container: [32]u8 = [_]u8{0} ** 32;
var form_container_len: usize = 0;
var form_vcpus: [4]u8 = "1   ".*;
var form_vcpus_len: usize = 1;
var form_mem: [10]u8 = "16384     ".*;
var form_mem_len: usize = 5;
var form_error: []const u8 = "";

var microvm_list: [16]struct { name: [32]u8, status: []const u8, id: u32 } = undefined;
var microvm_count: usize = 0;
var needs_vm_refresh: bool = true;
var needs_redraw: bool = true;

const proto_dashd = @import("protocols/dashd_protocol.zig");

// Cluster node view, aggregated from dashd's telemetry summary.
const MAX_NODES: usize = 8;
const NodeRow = struct {
    used: bool = false,
    addr: [16]u8 = [_]u8{0} ** 16,
    vms: u32 = 0,
    cycles: u64 = 0,
    exits: u64 = 0,
};
var node_rows: [MAX_NODES]NodeRow = [_]NodeRow{.{}} ** MAX_NODES;

const proto_inputd = @import("protocols/inputd_protocol.zig");
const InputEventPayload = proto_inputd.InputEvent;

// --- Main ────────────────────────────────────────────────────────────────────

pub export fn umain() noreturn {
    lib.serialWrite("windowd: starting\n");
    const bs: *const lib.BootstrapDescriptor =
        lib.ptrFrom(*const lib.BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    _ = lib.syscall(SYS_REGISTER, 0, @intFromEnum(lib.ReservedEndpoint.windowd), token);
    lib.serialWrite("windowd: registered at endpoint 9\n");

    // Allocate DMA pages
    const dma_phys = lib.syscall(SYS_ALLOC_DMA, DMA_NUM_PAGES, 0, token);
    if (dma_phys == 0) while (true) asm volatile ("pause");

    if (lib.getFramebufferInfo()) |info| {
        if (info.width > 0) {
            SCREEN_WIDTH = info.width;
            SCREEN_HEIGHT = info.height;
            COLS = SCREEN_WIDTH / 8;
            ROWS = SCREEN_HEIGHT / 8;
        }
    }

    // Initial paint
    lib.fillRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, COLOR_SEA_GRAY, token);
    drawTui(dma_phys, token);

    var last_poll: u64 = 0;
    var last_shell_len: usize = 0;

    while (true) {
        if (needs_vm_refresh or last_poll > 800_000) {
            requestVmList(bs, dma_phys, token);
            requestClusterSummary(dma_phys, token);
            needs_vm_refresh = false;
            last_poll = 0;
        }

        const page_phys = lib.syscall(SYS_TRY_RECV, 0, 0, token);
        if (page_phys != 0) {
            const page_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (page_va != 0) {
                handleMessage(page_va, token);
                _ = lib.syscall(SYS_FREE_PAGE, lib.DIPC_RECV_VA, 0, token);
                needs_redraw = true;
            }
        }

        const log_phys = dma_phys + DMA_LOG_SLOT * lib.PAGE_SIZE;
        const current_shell_len = lib.syscall(SYS_GET_VARDE_LOG, log_phys, 0, token);
        if (current_shell_len != last_shell_len) {
            last_shell_len = @intCast(current_shell_len);
            needs_redraw = true;
        }

        if (needs_redraw) {
            drawTui(dma_phys, token);
            needs_redraw = false;
        }

        last_poll += 1;
        _ = lib.syscall(lib.SYS_RECV, 0, 0, token);
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
}

fn requestVmList(bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64) void {
    const scratch_phys = dma_phys + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const scratch_va = DMA_BASE_VA + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    lib.sendControl(bs, scratch_phys, scratch_va, token, .list_microvms, &[_]u8{});
}

fn requestClusterSummary(dma_phys: u64, token: u64) void {
    const scratch_phys = dma_phys + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const scratch_va = DMA_BASE_VA + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const body_len = @sizeOf(proto_dashd.DashdHeader) + @sizeOf(proto_dashd.TelemetrySummaryRequest);
    const scratch: [*]u8 = lib.ptrFrom([*]u8, scratch_va);
    const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    head.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(body_len)),
        .auth_tag = 0,
        .src = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @intFromEnum(lib.ReservedEndpoint.windowd) },
        .dst = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @intFromEnum(lib.ReservedEndpoint.dashd) },
    };
    const dh: *align(1) proto_dashd.DashdHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    dh.* = .{ .op = .telemetry_summary_request, .payload_len = @sizeOf(proto_dashd.TelemetrySummaryRequest) };
    const req: *align(1) proto_dashd.TelemetrySummaryRequest = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + @sizeOf(proto_dashd.DashdHeader));
    req.* = .{};
    _ = lib.syscall(SYS_SEND_PAGE, scratch_phys, 0, token);
}

fn handleClusterSummary(payload_va: u64) void {
    const reply: *align(1) const proto_dashd.TelemetrySummaryReply =
        @ptrFromInt(payload_va + @sizeOf(proto_dashd.DashdHeader));
    for (&node_rows) |*r| r.* = .{};
    const count = @min(@as(usize, reply.count), proto_dashd.MAX_TELEMETRY_SUMMARY_ENTRIES);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = reply.entries[i];
        var row: ?*NodeRow = null;
        for (&node_rows) |*r| {
            if (r.used and std.mem.eql(u8, &r.addr, &e.node_addr)) { row = r; break; }
        }
        if (row == null) {
            for (&node_rows) |*r| {
                if (!r.used) { r.used = true; r.addr = e.node_addr; row = r; break; }
            }
        }
        if (row) |r| {
            r.vms += 1;
            r.cycles +%= e.cpu_cycles;
            r.exits +%= e.exit_count;
        }
    }
}

fn appendStr(buf: []u8, pos: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - pos.*);
    @memcpy(buf[pos.*..][0..n], s[0..n]);
    pos.* += n;
}

fn appendDec(buf: []u8, pos: *usize, v: u64) void {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (x > 0) : (x /= 10) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        appendStr(buf, pos, tmp[n .. n + 1]);
    }
}

fn appendHexByte(buf: []u8, pos: *usize, b: u8) void {
    const hex = "0123456789abcdef";
    appendStr(buf, pos, &[_]u8{ hex[b >> 4], hex[b & 0xF] });
}

fn drawClusterNodes(text_phys: u64, text_va: u64, token: u64) void {
    const base_row: u32 = @intCast(ROWS - 12); // bottom of sidebar, clear of the VM list
    lib.drawText(text_phys, text_va, base_row, 2, COLOR_GOLDEN_YELLOW, "Cluster Nodes", token);
    var shown: u32 = 0;
    for (&node_rows) |*r| {
        if (!r.used) continue;
        var line: [64]u8 = undefined;
        var p: usize = 0;
        var is_local = true;
        for (r.addr) |b| if (b != 0) { is_local = false; break; };
        if (is_local) {
            appendStr(&line, &p, "local");
        } else {
            // Show the last 4 address bytes to keep the line short.
            for (r.addr[12..16]) |b| appendHexByte(&line, &p, b);
        }
        appendStr(&line, &p, " vms=");
        appendDec(&line, &p, r.vms);
        appendStr(&line, &p, " x=");
        appendDec(&line, &p, r.exits);
        lib.drawText(text_phys, text_va, base_row + 1 + shown, 2, COLOR_HIGHLIGHT, line[0..p], token);
        shown += 1;
    }
    if (shown == 0) lib.drawText(text_phys, text_va, base_row + 1, 2, COLOR_DIM, "No telemetry yet", token);
}

fn vmStateLabel(state: u8) []const u8 {
    return switch (state) {
        1 => "Created",
        2 => "Running",
        3 => "Stopped",
        else => "Unknown",
    };
}

fn handleInput(ascii: u8, scancode: u8, token: u64) void {
    if (ascii == 0 and scancode == 0) return;

    if (ascii == '\t') {
        focused_pane = (focused_pane + 1) % 3;
        return;
    }

    if (focused_pane != 2) return;

    if (ascii != 0) {
        _ = lib.syscall(SYS_VARDE_INJECT, @as(u64, ascii), 0, token);
        return;
    }

    if (scancode == 0x48 or scancode == 0x50) {
        _ = lib.syscall(SYS_VARDE_INJECT, 27, 0, token);
        _ = lib.syscall(SYS_VARDE_INJECT, '[', 0, token);
        _ = lib.syscall(SYS_VARDE_INJECT, if (scancode == 0x48) 'A' else 'B', 0, token);
    }
}

fn handleMessage(page_va: u64, token: u64) void {
    const hdr: *const lib.PageHeader = lib.ptrFrom(*const lib.PageHeader, page_va);
    const payload_va = page_va + @as(u64, hdr.header_len);

    if (hdr.src.endpoint == @intFromEnum(lib.ReservedEndpoint.inputd) and
        hdr.payload_len >= @sizeOf(InputEventPayload))
    {
        const evt: *align(1) const InputEventPayload = @ptrFromInt(payload_va);
        handleInput(evt.ascii, evt.scancode, token);
        return;
    }

    if (hdr.src.endpoint == @intFromEnum(lib.ReservedEndpoint.dashd) and
        hdr.payload_len == @sizeOf(proto_dashd.DashdHeader) + @sizeOf(proto_dashd.TelemetrySummaryReply))
    {
        const dh: *align(1) const proto_dashd.DashdHeader = @ptrFromInt(payload_va);
        if (dh.magic == proto_dashd.MAGIC and dh.op == .telemetry_summary_reply) handleClusterSummary(payload_va);
        return;
    }

    if (hdr.src.endpoint == @intFromEnum(lib.ReservedEndpoint.kernel_control) and
        hdr.payload_len == @sizeOf(lib.VmSnapshotListPayload))
    {
        const snap: *align(1) const lib.VmSnapshotListPayload = @ptrFromInt(payload_va);
        microvm_count = @min(snap.count, microvm_list.len);

        var i: usize = 0;
        while (i < microvm_count) : (i += 1) {
            microvm_list[i].name = snap.entries[i].name;
            microvm_list[i].id = snap.entries[i].instance_id;
            microvm_list[i].status = vmStateLabel(snap.entries[i].state);
        }
    }
}

fn drawTui(dma_phys: u64, token: u64) void {
    const text_phys = dma_phys + DMA_TEXT_SLOT * 4096;
    const text_va = DMA_BASE_VA + DMA_TEXT_SLOT * 4096;

    // Header bar
    lib.fillRect(0, 0, SCREEN_WIDTH, 20, COLOR_TERRACOTTA, token);
    lib.drawText(text_phys, text_va, 0, 1, COLOR_WHITE, "Catenary OS  |  Cluster Orchestration", token);

    const sidebar_w = 240;
    drawPanel(text_phys, text_va, 0, 20, sidebar_w, SCREEN_HEIGHT - 20, "VM Manager", focused_pane == 0, token);
    drawPanel(text_phys, text_va, sidebar_w, 20, SCREEN_WIDTH - sidebar_w, 200, "New MicroVM", focused_pane == 1, token);
    drawPanel(text_phys, text_va, sidebar_w, 220, SCREEN_WIDTH - sidebar_w, SCREEN_HEIGHT - 220, "Varde Shell", focused_pane == 2, token);

    // VM List
    var i: usize = 0;
    while (i < microvm_count) : (i += 1) {
        const y = 50 + @as(u32, @intCast(i)) * 16;
        const color = if (i % 2 == 0) COLOR_WHITE else COLOR_DIM;
        lib.drawText(text_phys, text_va, y / 8, 2, color, microvm_list[i].name[0..lib.nameLen(microvm_list[i].name[0..])], token);
        lib.drawText(text_phys, text_va, y / 8, 20, COLOR_GREEN, microvm_list[i].status, token);
    }

    if (microvm_count == 0) {
        lib.drawText(text_phys, text_va, 7, 2, COLOR_DIM, "No MicroVMs discovered", token);
    }

    drawClusterNodes(text_phys, text_va, token);

    // Shell log
    const log_phys = dma_phys + DMA_LOG_SLOT * lib.PAGE_SIZE;
    const log_va = DMA_BASE_VA + DMA_LOG_SLOT * 4096;
    _ = lib.syscall(SYS_GET_VARDE_LOG, log_phys, 0, token);
    const log_ptr = lib.ptrFrom([*]const u8, log_va);
    var line: u32 = 0;
    var line_start: usize = 0;
    var j: usize = 0;
    while (j < 4000 and line < 25) : (j += 1) {
        if (log_ptr[j] == '\n' or log_ptr[j] == 0) {
            if (j > line_start) {
                lib.drawText(text_phys, text_va, 30 + line, 32, COLOR_WHITE, log_ptr[line_start..j], token);
            }
            line += 1;
            line_start = j + 1;
            if (log_ptr[j] == 0) break;
        }
    }
}

fn drawPanel(text_phys: u64, text_va: u64, x: u32, y: u32, w: u32, h: u32, title: []const u8, is_focused: bool, token: u64) void {
    lib.fillRect(x, y, w, h, COLOR_SEA_GRAY, token);
    const title_bg = if (is_focused) COLOR_HIGHLIGHT else COLOR_TERRACOTTA;
    lib.fillRect(x, y, w, 20, title_bg, token);
    lib.drawText(text_phys, text_va, y / 8 + 1, x / 8 + 1, COLOR_WHITE, title, token);
}
