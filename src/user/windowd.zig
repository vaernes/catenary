const lib = @import("lib.zig");

// Syscall ops (mirrors lib.zig constants)
const SYS_REGISTER        = lib.SYS_REGISTER;
const SYS_TRY_RECV        = lib.SYS_TRY_RECV;
const SYS_MAP_RECV        = lib.SYS_MAP_RECV;
const SYS_FREE_PAGE       = lib.SYS_FREE_PAGE;
const SYS_ALLOC_DMA       = lib.SYS_ALLOC_DMA;
const SYS_SEND_PAGE       = lib.SYS_SEND_PAGE;
const SYS_FB_DRAW_COLORED = lib.SYS_FB_DRAW_COLORED;
const SYS_FB_FILL_RECT    = lib.SYS_FB_FILL_RECT;
const SYS_GET_VARDE_LOG   = lib.SYS_GET_VARDE_LOG;
const SYS_VARDE_INJECT    = lib.SYS_VARDE_INJECT;
const SYS_FB_GET_INFO     = lib.SYS_FB_GET_INFO;

const USER_BOOTSTRAP_VADDR: usize = lib.USER_BOOTSTRAP_VADDR;
const DMA_BASE_VA: u64            = lib.DMA_BASE_VA;

// DMA page layout (each slot = 4096 bytes)
// Slot 0  (phys+0x0000): text draw buffer
// Slot 1  (phys+0x1000): varde shell log copy
// Slot 2  (phys+0x2000): scratch for outgoing DIPC pages
// Slots 3-15 reserved
const DMA_TEXT_SLOT:    u64 = 0;
const DMA_LOG_SLOT:     u64 = 1;
const DMA_SCRATCH_SLOT: u64 = 2;
const DMA_NUM_PAGES:    u64 = 4; // allocate 4 pages (0-3)

var COLS: usize = 100;
var ROWS: usize = 75;
var SCREEN_WIDTH: u32 = 800;
var SCREEN_HEIGHT: u32 = 600;

// Branding palette
const COLOR_SEA_GRAY:      u32 = 0x004A4E69;
const COLOR_TERRACOTTA:    u32 = 0x00E2725B;
const COLOR_GOLDEN_YELLOW: u32 = 0x00FFC300;
const COLOR_WHITE:         u32 = 0x00FFFFFF;
const COLOR_GREEN:         u32 = 0x0000CC44;
const COLOR_RED:           u32 = 0x00FF4444;
const COLOR_HIGHLIGHT:     u32 = 0x005BC0EB;
const COLOR_DIM:           u32 = 0x00888888;

// --- UI State ---
var focused_pane:       u8    = 0; // 0=VM Manager, 1=New VM Form, 2=Shell
var focused_form_field: u8    = 0; // 0=name, 1=vcpus, 2=mem  (valid when pane==1)
var form_name:          [32]u8 = [_]u8{0} ** 32;
var form_name_len:      usize  = 0;
var form_container:     [32]u8 = [_]u8{0} ** 32;
var form_container_len: usize  = 0;
var form_vcpus:         [4]u8  = "1\x00\x00\x00".*;
var form_vcpus_len:     usize  = 1;
var form_mem:           [10]u8 = "16384\x00\x00\x00\x00\x00".*;
var form_mem_len:       usize  = 5;
var selected_vm_idx:    usize  = 0;
var vm_list:            lib.VmSnapshotListPayload = .{ .count = 0 };
var vm_list_ready:      bool   = false;
var needs_vm_refresh:   bool   = true;

// Node status (from get_node_status)
var node_total_pages: u32 = 0;
var node_free_pages:  u32 = 0;
var node_active_vms:  u32 = 0;
var node_status_ready: bool = false;
var needs_status_refresh: bool = true;

// Form validation feedback
// Confirmation state
var show_confirm_delete: bool = false;
var form_error: []const u8 = "";
var needs_redraw: bool = true;

fn parseDecimal(bytes: []const u8) u32 {
    var val: u32 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') break;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn nameLen(name: *const [32]u8) usize {
    var l: usize = 0;
    while (l < 32 and name[l] != 0) : (l += 1) {}
    return l;
}

// --- Drawing Helpers ---
fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u32, token: u64) void {
    const arg0 = (@as(u64, x) << 48) | (@as(u64, y) << 32) | (@as(u64, w) << 16) | @as(u64, h);
    _ = lib.syscall(SYS_FB_FILL_RECT, arg0, color, token);
}

fn drawText(buf: [*]u8, dma_phys: u64, row: u32, col: u32, fg: u32, text: []const u8, token: u64) void {
    const len = @min(text.len, 255);
    if (len == 0) return;
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    const arg1 = (@as(u64, row) << 48) | (@as(u64, col) << 32) | fg;
    _ = lib.syscall(SYS_FB_DRAW_COLORED, dma_phys + DMA_TEXT_SLOT * 4096, arg1, token);
}

fn drawPanel(buf: [*]u8, dma_phys: u64, x: u32, y: u32, w: u32, h: u32, title: []const u8, is_focused: bool, token: u64) void {
    fillRect(x, y, w, h, COLOR_SEA_GRAY, token);
    const title_bg = if (is_focused) COLOR_HIGHLIGHT else COLOR_TERRACOTTA;
    fillRect(x, y, w, 20, title_bg, token);
    drawText(buf, dma_phys, y / 8 + 1, x / 8 + 1, COLOR_WHITE, title, token);
}

fn drawTui(dma_phys: u64, token: u64) void {
    lib.serialWrite("windowd: drawTui called\n");
    const buf: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + DMA_TEXT_SLOT * 4096);

    // ── Header bar ──────────────────────────────────────────────────────────
    fillRect(0, 0, SCREEN_WIDTH, 20, COLOR_TERRACOTTA, token);
    drawText(buf, dma_phys, 0, 1, COLOR_WHITE, "Catenary OS  |  Cluster Orchestration", token);
    drawText(buf, dma_phys, 0, @as(u32, @intCast(COLS)) - 12, COLOR_GOLDEN_YELLOW, "[TAB] Focus", token);

    // ── Node status bar (bottom of header) ──────────────────────────────────
    fillRect(0, 20, SCREEN_WIDTH, 12, 0x00232540, token);
    if (node_status_ready) {
        drawText(buf, dma_phys, 2, 1, COLOR_DIM, "Node:", token);
        drawText(buf, dma_phys, 2, 7, COLOR_WHITE, &fmtU32(node_free_pages), token);
        drawText(buf, dma_phys, 2, 16, COLOR_DIM, "/ ", token);
        drawText(buf, dma_phys, 2, 18, COLOR_WHITE, &fmtU32(node_total_pages), token);
        drawText(buf, dma_phys, 2, 27, COLOR_DIM, "pages free", token);
        drawText(buf, dma_phys, 2, 40, COLOR_DIM, "Active VMs:", token);
        drawText(buf, dma_phys, 2, 52, COLOR_GOLDEN_YELLOW, &fmtU32(node_active_vms), token);
    }

    // Dynamic layout calculations
    const mgr_y: u32 = 32;
    const mgr_h: u32 = (SCREEN_HEIGHT - mgr_y) * 4 / 10;
    const form_h: u32 = 80;
    const shell_y: u32 = mgr_y + mgr_h + form_h + 8;
    const shell_h: u32 = SCREEN_HEIGHT - shell_y;

    // ── Pane 0: VM Manager ──────────────────────────────────────────────────
    drawPanel(buf, dma_phys, 0, mgr_y, SCREEN_WIDTH, mgr_h, "MicroVM Manager", focused_pane == 0, token);
    drawText(buf, dma_phys, (mgr_y / 8) + 2, 2, COLOR_GOLDEN_YELLOW, "ID  Name          Container     Mem(pg)  vCPUs  State", token);
    drawText(buf, dma_phys, (mgr_y / 8) + 3, 2, COLOR_DIM,            "--- ------------- ------------- -------- ------ -------", token);

    const mgr_row_start = (mgr_y / 8) + 4;
    const max_visible_vms = (mgr_h - 48) / 8;

    if (vm_list_ready and vm_list.count > 0) {
        var i: u32 = 0;
        while (i < vm_list.count and i < max_visible_vms) : (i += 1) {
            const vm  = &vm_list.entries[i];
            const sel = (i == selected_vm_idx and focused_pane == 0);
            const row_fg = if (sel) COLOR_GOLDEN_YELLOW else COLOR_WHITE;

            var id_buf: [4]u8 = [_]u8{' '} ** 4;
            id_buf[0] = @as(u8, @intCast(vm.instance_id % 10)) + '0';

            const nl  = nameLen(&vm.name);
            const cl  = nameLen(&vm.container);
            const state_str = switch (vm.state) {
                1 => "Created",
                2 => "Running",
                3 => "Stopped",
                else => "Unknown",
            };
            const state_fg = if (vm.state == 2) COLOR_GREEN else if (vm.state == 3) COLOR_RED else COLOR_DIM;

            if (sel) fillRect(0, mgr_y + 32 + i * 8, SCREEN_WIDTH, 8, 0x00222244, token);

            drawText(buf, dma_phys, mgr_row_start + i, 2,  row_fg,   id_buf[0..1],          token);
            drawText(buf, dma_phys, mgr_row_start + i, 6,  row_fg,   vm.name[0..@min(nl, 13)],        token);
            drawText(buf, dma_phys, mgr_row_start + i, 20, row_fg,   vm.container[0..@min(cl, 13)],   token);
            drawText(buf, dma_phys, mgr_row_start + i, 34, row_fg,   &fmtU32(vm.mem_pages), token);
            drawText(buf, dma_phys, mgr_row_start + i, 43, row_fg,   &fmtU32(vm.vcpus),     token);
            drawText(buf, dma_phys, mgr_row_start + i, 50, state_fg, state_str,             token);
        }
    } else if (vm_list_ready) {
        drawText(buf, dma_phys, mgr_row_start, 4, COLOR_DIM, "(no MicroVMs)", token);
    } else {
        drawText(buf, dma_phys, mgr_row_start, 4, COLOR_DIM, "Loading...", token);
    }

    if (focused_pane == 0 and vm_list_ready and vm_list.count > 0) {
        const help_y = (mgr_y + mgr_h) / 8 - 1;
        drawText(buf, dma_phys, help_y, 2, COLOR_GOLDEN_YELLOW, "[S] Start   [K] Stop   [D] Delete   [UP/DOWN] Select", token);
    }

    // ── Pane 1: New VM Form ──────────────────────────────────────────────────
    const form_y = mgr_y + mgr_h + 4;
    drawPanel(buf, dma_phys, 0, form_y, SCREEN_WIDTH, form_h, "New MicroVM", focused_pane == 1, token);
    const form_row = (form_y / 8) + 2;

    const pane1 = focused_pane == 1;
    const name_fg  = if (pane1 and focused_form_field == 0) COLOR_HIGHLIGHT else COLOR_WHITE;
    const cont_fg  = if (pane1 and focused_form_field == 1) COLOR_HIGHLIGHT else COLOR_WHITE;
    const vcpu_fg  = if (pane1 and focused_form_field == 2) COLOR_HIGHLIGHT else COLOR_WHITE;
    const mem_fg   = if (pane1 and focused_form_field == 3) COLOR_HIGHLIGHT else COLOR_WHITE;

    drawText(buf, dma_phys, form_row, 2,  name_fg, "Name: [", token);
    drawText(buf, dma_phys, form_row, 9, COLOR_WHITE, form_name[0..form_name_len], token);
    drawText(buf, dma_phys, form_row, 9 + @as(u32, @intCast(form_name_len)), name_fg, "_]", token);

    drawText(buf, dma_phys, form_row, 42, cont_fg, "Cont: [", token);
    drawText(buf, dma_phys, form_row, 49, COLOR_WHITE, form_container[0..form_container_len], token);
    drawText(buf, dma_phys, form_row, 49 + @as(u32, @intCast(form_container_len)), cont_fg, "_]", token);

    drawText(buf, dma_phys, form_row + 2, 2,  vcpu_fg, "vCPUs: [", token);
    drawText(buf, dma_phys, form_row + 2, 10, COLOR_WHITE, form_vcpus[0..form_vcpus_len], token);
    drawText(buf, dma_phys, form_row + 2, 10 + @as(u32, @intCast(form_vcpus_len)), vcpu_fg, "_]", token);

    drawText(buf, dma_phys, form_row + 2, 42, mem_fg, "Mem: [", token);
    drawText(buf, dma_phys, form_row + 2, 48, COLOR_WHITE, form_mem[0..form_mem_len], token);
    drawText(buf, dma_phys, form_row + 2, 48 + @as(u32, @intCast(form_mem_len)), mem_fg, "_]", token);

    if (form_error.len > 0) {
        drawText(buf, dma_phys, form_row + 4, 2, COLOR_RED, form_error, token);
    }

    // ── Pane 2: Varde Shell ──────────────────────────────────────────────────
    drawPanel(buf, dma_phys, 0, shell_y, SCREEN_WIDTH, shell_h,
        if (focused_pane == 2) "Varde Shell  [INTERACTIVE]" else "Varde Shell  [TAB to focus]",
        focused_pane == 2, token);

    const log_phys = dma_phys + DMA_LOG_SLOT * 4096;
    const history_len = lib.syscall(SYS_GET_VARDE_LOG, log_phys, 0, token);
    const hist: [*]const u8 = lib.ptrFrom([*]const u8, DMA_BASE_VA + DMA_LOG_SLOT * 4096);

    if (history_len > 0) {
        const hlen: usize = @intCast(history_len);
        const max_rows = (shell_h - 24) / 8;
        var row: u32 = (shell_y / 8) + 2;
        var pos: usize = 0;
        if (hlen > 4000) pos = hlen - 4000; // rough tailing
        while (pos < hlen and row < (SCREEN_HEIGHT / 8) - 1) {
            var end = pos;
            while (end < hlen and hist[end] != '\n') : (end += 1) {}
            const line_len = @min(end - pos, COLS - 4);
            if (line_len > 0)
                drawText(buf, dma_phys, row, 2, COLOR_WHITE, hist[pos .. pos + line_len], token);
            row += 1;
            pos = end + 1;
            if (row > (shell_y / 8) + max_rows) break;
        }
    }

    // ── Dialogs ────────────────────────────────────────────────────────────
    if (show_confirm_delete) {
        const dw: u32 = 400;
        const dh: u32 = 80;
        const dx: u32 = (SCREEN_WIDTH - dw) / 2;
        const dy: u32 = (SCREEN_HEIGHT - dh) / 2;
        fillRect(dx, dy, dw, dh, 0x00111111, token);
        fillRect(dx, dy, dw, 20, COLOR_RED, token);
        drawText(buf, dma_phys, (dy / 8) + 1, (dx / 8) + 2, COLOR_WHITE, "Confirm Delete", token);
        drawText(buf, dma_phys, (dy / 8) + 4, (dx / 8) + 4, COLOR_WHITE, "Delete this MicroVM? [Y]es / [N]o", token);
    }
}

/// Format a u32 into a fixed 8-char right-aligned decimal string.
fn fmtU32(n: u32) [8]u8 {
    var buf: [8]u8 = [_]u8{' '} ** 8;
    if (n == 0) {
        buf[7] = '0';
        return buf;
    }
    var v = n;
    var i: usize = 8;
    while (v > 0 and i > 0) {
        i -= 1;
        buf[i] = @as(u8, @intCast(v % 10)) + '0';
        v /= 10;
    }
    return buf;
}

// --- DIPC helpers ---

/// Build and send a control plane message from DMA scratch page (slot 2).
fn sendControl(
    bs: *const lib.BootstrapDescriptor,
    dma_phys: u64,
    token: u64,
    op: lib.ControlOp,
    extra_payload: []const u8,
) void {
    const scratch_phys = dma_phys + DMA_SCRATCH_SLOT * 4096;
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + DMA_SCRATCH_SLOT * 4096);
    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };

    const total_payload: u32 = @as(u32, @intCast(lib.CONTROL_HEADER_SIZE + extra_payload.len));
    const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    head.* = .{
        .magic      = lib.WireMagic,
        .version    = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = total_payload,
        .auth_tag   = 0,
        .src = .{ .node = local_node, .endpoint = @intFromEnum(lib.ReservedEndpoint.windowd) },
        .dst = .{ .node = local_node, .endpoint = @intFromEnum(lib.ReservedEndpoint.kernel_control) },
    };
    const ctrl: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    ctrl.* = .{ .op = op, .payload_len = @as(u32, @intCast(extra_payload.len)) };

    if (extra_payload.len > 0) {
        const dst: [*]u8 = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
        @memcpy(dst[0..extra_payload.len], extra_payload);
    }
    _ = lib.syscall(SYS_SEND_PAGE, scratch_phys, 0, token);
}

fn requestVmList(bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64) void {
    sendControl(bs, dma_phys, token, .list_microvms, &[_]u8{});
}

// ── Main ────────────────────────────────────────────────────────────────────

pub export fn umain() noreturn {
    lib.serialWrite("windowd: starting umain\n");
    const bs: *const lib.BootstrapDescriptor =
        lib.ptrFrom(*const lib.BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    _ = lib.syscall(SYS_REGISTER, 0, @intFromEnum(lib.ReservedEndpoint.windowd), token);
    lib.serialWrite("windowd: registered at endpoint 9\n");

    // Allocate DMA pages (slots 0-3)
    const dma_phys = lib.syscall(SYS_ALLOC_DMA, DMA_NUM_PAGES, 0, token);
    if (dma_phys == 0) while (true) asm volatile ("pause");

    if (lib.getFramebufferInfo()) |info| {
        if (info.width > 0 and info.height > 0) {
            SCREEN_WIDTH = info.width;
            SCREEN_HEIGHT = info.height;
            COLS = SCREEN_WIDTH / 8;
            ROWS = SCREEN_HEIGHT / 8;
        }
    }
    lib.serialWrite("windowd: screen dimensions updated\n");

    // Initial paint
    fillRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, COLOR_SEA_GRAY, token);
    drawTui(dma_phys, token);

    var last_poll: u64 = 0;

    while (true) {
        // Periodic VM list + node status refresh
        if (needs_vm_refresh or last_poll > 800_000) {
            requestVmList(bs, dma_phys, token);
            needs_vm_refresh = false;
            last_poll = 0;
        }
        if (needs_status_refresh or last_poll == 400_000) {
            sendControl(bs, dma_phys, token, .get_node_status, &[_]u8{});
            needs_status_refresh = false;
        }

        const page_phys = lib.syscall(SYS_TRY_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                handleMessage(bs, dma_phys, token, recv_va);
                _ = lib.syscall(SYS_FREE_PAGE, lib.DIPC_RECV_VA, 0, token);
                needs_redraw = true;
            }
        }

        if (needs_redraw) {
            drawTui(dma_phys, token);
            needs_redraw = false;
        }

        last_poll += 1;
        asm volatile ("pause");
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
}

fn handleMessage(
    bs: *const lib.BootstrapDescriptor,
    dma_phys: u64,
    token: u64,
    recv_va: u64,
) void {
    const hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);

    // ── Keyboard event from inputd (endpoint 8) ──────────────────────────────
    if (hdr.src.endpoint == @intFromEnum(lib.ReservedEndpoint.inputd)) {
        const InputEvent = extern struct { event_type: u8, ascii: u8, scancode: u8 };
        const evt: *align(1) const InputEvent = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
        handleInput(bs, dma_phys, token, evt.ascii, evt.scancode);
        return;
    }

    // ── Response from kernel control (endpoint 2) ─────────────────────────────
    // The kernel sends result structs directly as the DIPC payload
    // (no ControlHeader wrapper in responses).
    if (hdr.src.endpoint == @intFromEnum(lib.ReservedEndpoint.kernel_control)) {
        const payload_len = @as(usize, hdr.payload_len);
        if (payload_len == @sizeOf(lib.VmSnapshotListPayload)) {
            const snap: *align(1) const lib.VmSnapshotListPayload =
                @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
            vm_list = snap.*;
            if (vm_list.count == 0) {
                selected_vm_idx = 0;
            } else if (selected_vm_idx >= vm_list.count) {
                selected_vm_idx = vm_list.count - 1;
            }
            vm_list_ready = true;
        } else if (payload_len == @sizeOf(lib.NodeStatusResult)) {
            const ns: *align(1) const lib.NodeStatusResult =
                @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
            node_total_pages = ns.total_mem_pages;
            node_free_pages  = ns.free_mem_pages;
            node_active_vms  = ns.active_vms;
            node_status_ready = true;
        }
        return;
    }
}

fn handleInput(
    bs: *const lib.BootstrapDescriptor,
    dma_phys: u64,
    token: u64,
    ascii: u8,
    scancode: u8,
) void {
    // Nothing pressed
    if (ascii == 0 and scancode == 0) return;

    const low = if (ascii >= 'A' and ascii <= 'Z') ascii + 32 else ascii;

    // TAB — cycle panes (or form fields within the form pane)
    if (ascii == '\t') {
        if (focused_pane == 1) {
            // Cycle within form fields; wrapping past field 3 exits to shell
            if (focused_form_field < 3) {
                focused_form_field += 1;
            } else {
                focused_form_field = 0;
                focused_pane = 2;
            }
        } else {
            focused_pane = (focused_pane + 1) % 3;
            if (focused_pane == 1) focused_form_field = 0;
        }
        return;
    }

    // ── Shell pane: forward keystrokes to varde_shell ────────────────────────
    if (focused_pane == 2) {
        if (ascii != 0) {
            _ = lib.syscall(SYS_VARDE_INJECT, @as(u64, ascii), 0, token);
        } else if (scancode == 0x48) { // UP
            _ = lib.syscall(SYS_VARDE_INJECT, 27, 0, token);
            _ = lib.syscall(SYS_VARDE_INJECT, '[', 0, token);
            _ = lib.syscall(SYS_VARDE_INJECT, 'A', 0, token);
        } else if (scancode == 0x50) { // DOWN
            _ = lib.syscall(SYS_VARDE_INJECT, 27, 0, token);
            _ = lib.syscall(SYS_VARDE_INJECT, '[', 0, token);
            _ = lib.syscall(SYS_VARDE_INJECT, 'B', 0, token);
        }
        return;
    }

    // ── Dialog handling (Confirm Delete) ────────────────────────────────────
    if (show_confirm_delete) {
        if (low == 'y') {
            if (vm_list_ready and vm_list.count > 0) {
                const vm = &vm_list.entries[@min(selected_vm_idx, vm_list.count - 1)];
                var p = lib.DeleteMicrovmPayload{ .instance_id = vm.instance_id };
                sendControl(bs, dma_phys, token, .delete_microvm, std.mem.asBytes(&p));
                needs_vm_refresh = true;
                if (selected_vm_idx > 0) selected_vm_idx -= 1;
            }
            show_confirm_delete = false;
        } else if (low == 'n' or ascii == 27) {
            show_confirm_delete = false;
        }
        return;
    }

    // ── Arrow keys (scancode only) ───────────────────────────────────────────
    if (ascii == 0) {
        if (focused_pane == 0) {
            if (scancode == 0x48 and selected_vm_idx > 0) selected_vm_idx -= 1; // Up
            if (scancode == 0x50 and vm_list_ready and selected_vm_idx + 1 < vm_list.count)
                selected_vm_idx += 1; // Down
        }
        return;
    }

    // ── VM Manager pane (0) ───────────────────────────────────────────────────
    if (focused_pane == 0) {
        if (vm_list_ready and vm_list.count > 0) {
            const vm = &vm_list.entries[@min(selected_vm_idx, vm_list.count - 1)];
            if (low == 's') { // Start
                var p = lib.StartMicrovmPayload{ .instance_id = vm.instance_id };
                sendControl(bs, dma_phys, token, .start_microvm, std.mem.asBytes(&p));
                needs_vm_refresh = true;
            } else if (low == 'k') { // Stop (Kill)
                var p = lib.StopMicrovmPayload{ .instance_id = vm.instance_id };
                sendControl(bs, dma_phys, token, .stop_microvm, std.mem.asBytes(&p));
                needs_vm_refresh = true;
            } else if (low == 'd') { // Delete
                show_confirm_delete = true;
            }
        }
        return;
    }

    // ── New VM Form pane (1) ──────────────────────────────────────────────────
    if (focused_pane == 1) {
        if (ascii == 0x08 or ascii == 127) { // Backspace
            switch (focused_form_field) {
                0 => if (form_name_len > 0) { form_name_len -= 1; },
                1 => if (form_container_len > 0) { form_container_len -= 1; },
                2 => if (form_vcpus_len > 0) { form_vcpus_len -= 1; },
                3 => if (form_mem_len > 0) { form_mem_len -= 1; },
                else => {},
            }
            return;
        }

        if (ascii == '\r' or ascii == '\n') {
            const vcpus = parseDecimal(form_vcpus[0..form_vcpus_len]);
            const mem   = parseDecimal(form_mem[0..form_mem_len]);
            // Validate and show inline error
            if (form_name_len == 0) {
                form_error = "Error: Name is required";
            } else if (form_container_len == 0) {
                form_error = "Error: Container image is required";
            } else if (vcpus == 0) {
                form_error = "Error: vCPUs must be >= 1";
            } else if (mem == 0) {
                form_error = "Error: Memory (pages) must be >= 1";
            } else if (mem < 64) {
                form_error = "Error: Memory must be >= 64 pages (256 KiB)";
            } else {
                form_error = "";
                var p = lib.CreateMicrovmPayload{
                    .mem_pages      = mem,
                    .vcpus          = vcpus,
                    .kernel_phys    = bs.linux_bzimage_phys,
                    .kernel_size    = bs.linux_bzimage_size,
                    .initramfs_phys = bs.initramfs_phys,
                    .initramfs_size = bs.initramfs_size,
                    .name           = [_]u8{0} ** 32,
                    .container      = [_]u8{0} ** 32,
                };
                @memcpy(p.name[0..form_name_len], form_name[0..form_name_len]);
                @memcpy(p.container[0..form_container_len], form_container[0..form_container_len]);
                sendControl(bs, dma_phys, token, .create_microvm, std.mem.asBytes(&p));
                form_name_len = 0;
                form_container_len = 0;
                needs_vm_refresh = true;
                needs_status_refresh = true;
            }
            return;
        }

        // Escape — clear the active field
        if (ascii == 0x1B) {
            switch (focused_form_field) {
                0 => { form_name_len = 0; @memset(&form_name, 0); },
                1 => { form_container_len = 0; @memset(&form_container, 0); },
                2 => { form_vcpus_len = 1; form_vcpus[0] = '1'; },
                3 => { form_mem_len = 5; @memcpy(form_mem[0..5], "16384"); },
                else => {},
            }
            form_error = "";
            return;
        }

        // Printable character input per field
        if (ascii >= 32 and ascii <= 126) {
            switch (focused_form_field) {
                0 => if (form_name_len < 31) {
                    form_name[form_name_len] = ascii;
                    form_name_len += 1;
                },
                1 => if (form_container_len < 31) {
                    form_container[form_container_len] = ascii;
                    form_container_len += 1;
                },
                2 => if (ascii >= '0' and ascii <= '9' and form_vcpus_len < 3) {
                    form_vcpus[form_vcpus_len] = ascii;
                    form_vcpus_len += 1;
                },
                3 => if (ascii >= '0' and ascii <= '9' and form_mem_len < 9) {
                    form_mem[form_mem_len] = ascii;
                    form_mem_len += 1;
                },
                else => {},
            }
        }
    }
}

// Bring std in for mem.asBytes
const std = @import("std");
