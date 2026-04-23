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
        _ = lib.syscall(lib.SYS_YIELD, 0, 0, token);
        asm volatile ("pause");
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
