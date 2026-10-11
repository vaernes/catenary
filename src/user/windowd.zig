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
const COLOR_PANEL_BG: u32 = 0x002B2D42;
const COLOR_INPUT_BG: u32 = 0x001A1C2E;

// --- UI State ---
var focused_pane: u8 = 1; // 0=VM Manager, 1=New VM Form, 2=Varde Shell (default to Form)
var focused_form_field: u8 = 0; // 0=name, 1=vcpus, 2=mem, 3=create button

// Form State
var form_name: [32]u8 = "alpine-01".* ++ [_]u8{0} ** 23;
var form_name_len: usize = 9;
var form_vcpus: u32 = 1;
const MEM_OPTIONS = [_]u32{ 16, 32, 64, 128 };
var form_mem_idx: usize = 1; // Default 32 MB
var form_status_buf: [64]u8 = [_]u8{0} ** 64;
var form_status_len: usize = 0;
var form_status_color: u32 = COLOR_GREEN;

fn setFormStatus(msg: []const u8, color: u32) void {
    const n = @min(msg.len, form_status_buf.len);
    @memcpy(form_status_buf[0..n], msg[0..n]);
    form_status_len = n;
    form_status_color = color;
}

// MicroVM Management State
var microvm_list: [16]struct { name: [32]u8, status: []const u8, id: u32, state: u8 } = undefined;
var microvm_count: usize = 0;
var selected_vm_idx: usize = 0;
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
const KeyCode = proto_inputd.KeyCode;

// --- DIPC Control Requests ---

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

fn sendVmStart(bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64, instance_id: u32) void {
    const scratch_phys = dma_phys + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const scratch_va = DMA_BASE_VA + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const p = lib.StartMicrovmPayload{ .instance_id = instance_id };
    lib.sendControl(bs, scratch_phys, scratch_va, token, .start_microvm, std.mem.asBytes(&p));
}

fn sendVmStop(bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64, instance_id: u32) void {
    const scratch_phys = dma_phys + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const scratch_va = DMA_BASE_VA + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const p = lib.StopMicrovmPayload{ .instance_id = instance_id };
    lib.sendControl(bs, scratch_phys, scratch_va, token, .stop_microvm, std.mem.asBytes(&p));
}

fn sendVmDelete(bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64, instance_id: u32) void {
    const scratch_phys = dma_phys + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const scratch_va = DMA_BASE_VA + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const p = lib.DeleteMicrovmPayload{ .instance_id = instance_id };
    lib.sendControl(bs, scratch_phys, scratch_va, token, .delete_microvm, std.mem.asBytes(&p));
}

fn sendVmCreate(bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64, name: []const u8, vcpus: u32, mem_mb: u32) void {
    const scratch_phys = dma_phys + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const scratch_va = DMA_BASE_VA + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const mem_pages = mem_mb * 256; // 1 MB = 256 * 4 KB pages
    var p = lib.CreateMicrovmPayload{
        .mem_pages = mem_pages,
        .vcpus = vcpus,
        .kernel_phys = bs.linux_bzimage_phys,
        .kernel_size = bs.linux_bzimage_size,
        .initramfs_phys = bs.initramfs_phys,
        .initramfs_size = bs.initramfs_size,
        .name = [_]u8{0} ** 32,
        .container = [_]u8{0} ** 32,
    };
    const len = @min(name.len, 31);
    @memcpy(p.name[0..len], name[0..len]);
    lib.sendControl(bs, scratch_phys, scratch_va, token, .create_microvm, std.mem.asBytes(&p));
}

// --- Main Event Loop ---

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

    setFormStatus("Ready. Press [Tab] to switch focus.", COLOR_HIGHLIGHT);

    // Initial paint
    lib.fillRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, COLOR_SEA_GRAY, token);
    drawTui(dma_phys, token);

    var last_poll: u64 = 0;
    var last_shell_len: usize = 0;

    while (true) {
        if (needs_vm_refresh or last_poll > 600_000) {
            requestVmList(bs, dma_phys, token);
            requestClusterSummary(dma_phys, token);
            needs_vm_refresh = false;
            last_poll = 0;
        }

        const page_phys = lib.syscall(SYS_TRY_RECV, 0, 0, token);
        if (page_phys != 0) {
            const page_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (page_va != 0) {
                handleMessage(page_va, bs, dma_phys, token);
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

fn vmStateLabel(state: u8) []const u8 {
    return switch (state) {
        1 => "Created",
        2 => "Running",
        3 => "Stopped",
        else => "Unknown",
    };
}

fn handleInputEvent(evt: InputEventPayload, bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64) void {
    // Global Navigation Keys
    if (evt.key_code == .tab or evt.ascii == '\t') {
        focused_pane = (focused_pane + 1) % 3;
        needs_redraw = true;
        return;
    }
    if (evt.key_code == .f1) {
        focused_pane = 0;
        needs_redraw = true;
        return;
    }
    if (evt.key_code == .f2) {
        focused_pane = 1;
        needs_redraw = true;
        return;
    }
    if (evt.key_code == .f3) {
        focused_pane = 2;
        needs_redraw = true;
        return;
    }

    // --- Pane 0: VM Manager ---
    if (focused_pane == 0) {
        if (evt.key_code == .up) {
            if (selected_vm_idx > 0) {
                selected_vm_idx -= 1;
                needs_redraw = true;
            }
            return;
        }
        if (evt.key_code == .down) {
            if (selected_vm_idx + 1 < microvm_count) {
                selected_vm_idx += 1;
                needs_redraw = true;
            }
            return;
        }
        if (evt.ascii == 's' or evt.ascii == 'S') {
            if (selected_vm_idx < microvm_count) {
                const vm = microvm_list[selected_vm_idx];
                sendVmStart(bs, dma_phys, token, vm.id);
                setFormStatus("Starting MicroVM...", COLOR_GOLDEN_YELLOW);
                needs_vm_refresh = true;
                needs_redraw = true;
            }
            return;
        }
        if (evt.ascii == 'k' or evt.ascii == 'K') {
            if (selected_vm_idx < microvm_count) {
                const vm = microvm_list[selected_vm_idx];
                sendVmStop(bs, dma_phys, token, vm.id);
                setFormStatus("Stopping MicroVM...", COLOR_GOLDEN_YELLOW);
                needs_vm_refresh = true;
                needs_redraw = true;
            }
            return;
        }
        if (evt.ascii == 'd' or evt.ascii == 'D') {
            if (selected_vm_idx < microvm_count) {
                const vm = microvm_list[selected_vm_idx];
                sendVmDelete(bs, dma_phys, token, vm.id);
                setFormStatus("Deleted MicroVM.", COLOR_RED);
                needs_vm_refresh = true;
                needs_redraw = true;
            }
            return;
        }
        return;
    }

    // --- Pane 1: New MicroVM Form ---
    if (focused_pane == 1) {
        if (evt.key_code == .up) {
            if (focused_form_field > 0) {
                focused_form_field -= 1;
                needs_redraw = true;
            }
            return;
        }
        if (evt.key_code == .down) {
            if (focused_form_field < 3) {
                focused_form_field += 1;
                needs_redraw = true;
            }
            return;
        }

        // Field 0: Name (Text input)
        if (focused_form_field == 0) {
            if (evt.key_code == .backspace or evt.ascii == 0x08) {
                if (form_name_len > 0) {
                    form_name_len -= 1;
                    form_name[form_name_len] = 0;
                    needs_redraw = true;
                }
                return;
            }
            if (evt.key_code == .enter or evt.ascii == '\n') {
                focused_form_field = 1;
                needs_redraw = true;
                return;
            }
            if (evt.ascii >= 32 and evt.ascii <= 126 and form_name_len < 20) {
                form_name[form_name_len] = evt.ascii;
                form_name_len += 1;
                form_name[form_name_len] = 0;
                needs_redraw = true;
                return;
            }
            return;
        }

        // Field 1: vCPUs (1..4)
        if (focused_form_field == 1) {
            if (evt.key_code == .left) {
                if (form_vcpus > 1) {
                    form_vcpus -= 1;
                    needs_redraw = true;
                }
                return;
            }
            if (evt.key_code == .right) {
                if (form_vcpus < 4) {
                    form_vcpus += 1;
                    needs_redraw = true;
                }
                return;
            }
            if (evt.ascii >= '1' and evt.ascii <= '4') {
                form_vcpus = evt.ascii - '0';
                needs_redraw = true;
                return;
            }
            if (evt.key_code == .enter or evt.ascii == '\n') {
                focused_form_field = 2;
                needs_redraw = true;
                return;
            }
            return;
        }

        // Field 2: Memory (16, 32, 64, 128 MB)
        if (focused_form_field == 2) {
            if (evt.key_code == .left) {
                if (form_mem_idx > 0) {
                    form_mem_idx -= 1;
                    needs_redraw = true;
                }
                return;
            }
            if (evt.key_code == .right) {
                if (form_mem_idx + 1 < MEM_OPTIONS.len) {
                    form_mem_idx += 1;
                    needs_redraw = true;
                }
                return;
            }
            if (evt.key_code == .enter or evt.ascii == '\n') {
                focused_form_field = 3;
                needs_redraw = true;
                return;
            }
            return;
        }

        // Field 3: Action Button (Create & Launch)
        if (focused_form_field == 3 or evt.key_code == .enter or evt.ascii == '\n') {
            const name_slice = if (form_name_len > 0) form_name[0..form_name_len] else "guest-vm";
            sendVmCreate(bs, dma_phys, token, name_slice, form_vcpus, MEM_OPTIONS[form_mem_idx]);
            setFormStatus("MicroVM provision request dispatched!", COLOR_GREEN);
            needs_vm_refresh = true;
            needs_redraw = true;
            return;
        }
        return;
    }

    // --- Pane 2: Varde Shell ---
    if (focused_pane == 2) {
        if (evt.key_code == .enter or evt.ascii == '\n') {
            _ = lib.syscall(SYS_VARDE_INJECT, '\r', 0, token);
            _ = lib.syscall(SYS_VARDE_INJECT, '\n', 0, token);
            return;
        }
        if (evt.key_code == .backspace or evt.ascii == 0x08) {
            _ = lib.syscall(SYS_VARDE_INJECT, 0x08, 0, token);
            return;
        }
        if (evt.key_code == .up) {
            _ = lib.syscall(SYS_VARDE_INJECT, 27, 0, token);
            _ = lib.syscall(SYS_VARDE_INJECT, '[', 0, token);
            _ = lib.syscall(SYS_VARDE_INJECT, 'A', 0, token);
            return;
        }
        if (evt.key_code == .down) {
            _ = lib.syscall(SYS_VARDE_INJECT, 27, 0, token);
            _ = lib.syscall(SYS_VARDE_INJECT, '[', 0, token);
            _ = lib.syscall(SYS_VARDE_INJECT, 'B', 0, token);
            return;
        }
        if (evt.ascii != 0) {
            _ = lib.syscall(SYS_VARDE_INJECT, @as(u64, evt.ascii), 0, token);
            return;
        }
    }
}

fn handleMessage(page_va: u64, bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64) void {
    const hdr: *const lib.PageHeader = lib.ptrFrom(*const lib.PageHeader, page_va);
    const payload_va = page_va + @as(u64, hdr.header_len);

    if (hdr.src.endpoint == @intFromEnum(lib.ReservedEndpoint.inputd) and
        hdr.payload_len >= @sizeOf(InputEventPayload))
    {
        const evt: *align(1) const InputEventPayload = @ptrFromInt(payload_va);
        handleInputEvent(evt.*, bs, dma_phys, token);
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
            microvm_list[i].state = snap.entries[i].state;
            microvm_list[i].status = vmStateLabel(snap.entries[i].state);
        }
        if (selected_vm_idx >= microvm_count and microvm_count > 0) {
            selected_vm_idx = microvm_count - 1;
        }
    }
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

// --- Formatting Helpers ---

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

// --- Drawing Routine ---

fn drawTui(dma_phys: u64, token: u64) void {
    const text_phys = dma_phys + DMA_TEXT_SLOT * 4096;
    const text_va = DMA_BASE_VA + DMA_TEXT_SLOT * 4096;

    // Header bar (y=0..20)
    lib.fillRect(0, 0, SCREEN_WIDTH, 20, COLOR_TERRACOTTA, token);
    lib.drawText(text_phys, text_va, 0, 1, COLOR_WHITE, " [C] CATENARY OS  |  Phase 8: Operator Console & MicroVM Fabric", token);

    const sidebar_w: u32 = 250;
    const form_h: u32 = 180;
    const main_w: u32 = SCREEN_WIDTH - sidebar_w;
    const status_h: u32 = 22;
    const work_h: u32 = SCREEN_HEIGHT - 20 - status_h;

    // 1. Sidebar - VM Manager Panel
    drawPanel(text_phys, text_va, 0, 20, sidebar_w, 320, "VM Manager (F1)", focused_pane == 0, token);
    drawVmList(text_phys, text_va, token);

    // 2. Sidebar - Cluster Topology Panel
    drawPanel(text_phys, text_va, 0, 340, sidebar_w, work_h - 320, "Cluster Topology", false, token);
    drawClusterNodes(text_phys, text_va, token);

    // 3. Top-Right: New MicroVM Form Panel
    drawPanel(text_phys, text_va, sidebar_w, 20, main_w, form_h, "New MicroVM (F2)", focused_pane == 1, token);
    drawNewVmForm(text_phys, text_va, sidebar_w, 20, token);

    // 4. Bottom-Right: Varde Shell Panel
    const shell_y = 20 + form_h;
    const shell_h = work_h - form_h;
    drawPanel(text_phys, text_va, sidebar_w, shell_y, main_w, shell_h, "Varde Shell (F3)", focused_pane == 2, token);
    drawShellLog(dma_phys, text_phys, text_va, sidebar_w, shell_y, shell_h, token);

    // 5. Global Shortcut / Status Bar (Bottom 20px)
    drawBottomBar(text_phys, text_va, token);
}

fn drawPanel(text_phys: u64, text_va: u64, x: u32, y: u32, w: u32, h: u32, title: []const u8, is_focused: bool, token: u64) void {
    lib.fillRect(x, y, w, h, COLOR_PANEL_BG, token);
    const title_bg = if (is_focused) COLOR_HIGHLIGHT else COLOR_TERRACOTTA;
    lib.fillRect(x, y, w, 20, title_bg, token);
    const title_fg = if (is_focused) COLOR_INPUT_BG else COLOR_WHITE;
    lib.drawTextBg(text_phys, text_va, y / 8 + 1, x / 8 + 1, title_fg, title_bg, title, token);
}

fn drawVmList(text_phys: u64, text_va: u64, token: u64) void {
    lib.drawText(text_phys, text_va, 5, 2, COLOR_GOLDEN_YELLOW, "Name          State   ID", token);

    var i: usize = 0;
    while (i < microvm_count and i < 10) : (i += 1) {
        const row: u32 = 7 + @as(u32, @intCast(i)) * 2;
        const is_selected = (i == selected_vm_idx and focused_pane == 0);

        var line: [32]u8 = undefined;
        var p: usize = 0;
        appendStr(&line, &p, if (is_selected) "> " else "  ");
        const name_len = lib.nameLen(microvm_list[i].name[0..]);
        const disp_len = @min(name_len, 10);
        appendStr(&line, &p, microvm_list[i].name[0..disp_len]);
        while (p < 14) : (p += 1) line[p] = ' ';

        const fg_color = if (is_selected) COLOR_GOLDEN_YELLOW else COLOR_WHITE;
        lib.drawText(text_phys, text_va, row, 1, fg_color, line[0..p], token);

        const state_color = if (microvm_list[i].state == 2) COLOR_GREEN else COLOR_DIM;
        lib.drawText(text_phys, text_va, row, 16, state_color, microvm_list[i].status, token);

        var id_buf: [8]u8 = undefined;
        var id_p: usize = 0;
        appendDec(&id_buf, &id_p, microvm_list[i].id);
        lib.drawText(text_phys, text_va, row, 25, COLOR_HIGHLIGHT, id_buf[0..id_p], token);
    }

    if (microvm_count == 0) {
        lib.drawText(text_phys, text_va, 8, 2, COLOR_DIM, "(No MicroVMs discovered)", token);
    }

    // Controls hint
    lib.drawText(text_phys, text_va, 28, 2, COLOR_GOLDEN_YELLOW, "VM Controls:", token);
    lib.drawText(text_phys, text_va, 30, 2, COLOR_WHITE, "[S]tart  [K]ill  [D]elete", token);
}

fn drawClusterNodes(text_phys: u64, text_va: u64, token: u64) void {
    const base_row: u32 = 45;
    lib.drawText(text_phys, text_va, base_row, 2, COLOR_GOLDEN_YELLOW, "Node ID        VMs  Exits", token);

    var shown: u32 = 0;
    for (&node_rows) |*r| {
        if (!r.used) continue;
        var line: [64]u8 = undefined;
        var p: usize = 0;
        var is_local = true;
        for (r.addr) |b| if (b != 0) { is_local = false; break; };
        if (is_local) {
            appendStr(&line, &p, "local-node    ");
        } else {
            for (r.addr[12..16]) |b| appendHexByte(&line, &p, b);
            appendStr(&line, &p, "      ");
        }
        appendDec(&line, &p, r.vms);
        while (p < 20) : (p += 1) line[p] = ' ';
        appendDec(&line, &p, r.exits);
        lib.drawText(text_phys, text_va, base_row + 2 + shown * 2, 2, COLOR_HIGHLIGHT, line[0..p], token);
        shown += 1;
    }
    if (shown == 0) {
        lib.drawText(text_phys, text_va, base_row + 2, 2, COLOR_DIM, "Awaiting node telemetry...", token);
    }
}

fn drawNewVmForm(text_phys: u64, text_va: u64, start_x: u32, start_y: u32, token: u64) void {
    _ = start_x;
    const base_row: u32 = start_y / 8 + 4;
    const col_lbl: u32 = 34;
    const col_input: u32 = 50;

    // Field 0: Name
    const is_f0 = (focused_pane == 1 and focused_form_field == 0);
    lib.drawText(text_phys, text_va, base_row, col_lbl, if (is_f0) COLOR_GOLDEN_YELLOW else COLOR_WHITE, "VM Name   :", token);

    var name_field: [32]u8 = undefined;
    var np: usize = 0;
    appendStr(&name_field, &np, "[ ");
    appendStr(&name_field, &np, form_name[0..form_name_len]);
    if (is_f0) appendStr(&name_field, &np, "_");
    appendStr(&name_field, &np, " ]");
    lib.drawText(text_phys, text_va, base_row, col_input, if (is_f0) COLOR_HIGHLIGHT else COLOR_WHITE, name_field[0..np], token);

    // Field 1: vCPUs
    const is_f1 = (focused_pane == 1 and focused_form_field == 1);
    lib.drawText(text_phys, text_va, base_row + 3, col_lbl, if (is_f1) COLOR_GOLDEN_YELLOW else COLOR_WHITE, "vCPUs     :", token);

    var vcpu_field: [32]u8 = undefined;
    var vp: usize = 0;
    appendStr(&vcpu_field, &vp, "[< ");
    appendDec(&vcpu_field, &vp, form_vcpus);
    appendStr(&vcpu_field, &vp, " core >]");
    lib.drawText(text_phys, text_va, base_row + 3, col_input, if (is_f1) COLOR_HIGHLIGHT else COLOR_WHITE, vcpu_field[0..vp], token);

    // Field 2: Memory
    const is_f2 = (focused_pane == 1 and focused_form_field == 2);
    lib.drawText(text_phys, text_va, base_row + 6, col_lbl, if (is_f2) COLOR_GOLDEN_YELLOW else COLOR_WHITE, "Memory    :", token);

    var mem_field: [32]u8 = undefined;
    var mp: usize = 0;
    appendStr(&mem_field, &mp, "[< ");
    appendDec(&mem_field, &mp, MEM_OPTIONS[form_mem_idx]);
    appendStr(&mem_field, &mp, " MB >]");
    lib.drawText(text_phys, text_va, base_row + 6, col_input, if (is_f2) COLOR_HIGHLIGHT else COLOR_WHITE, mem_field[0..mp], token);

    // Field 3: Action Button
    const is_f3 = (focused_pane == 1 and focused_form_field == 3);
    const btn_text = "< CREATE & LAUNCH MICROVM >";
    const btn_color = if (is_f3) COLOR_GOLDEN_YELLOW else COLOR_TERRACOTTA;
    lib.drawText(text_phys, text_va, base_row + 10, col_lbl + 4, btn_color, btn_text, token);

    // Status Banner
    if (form_status_len > 0) {
        lib.drawText(text_phys, text_va, base_row + 13, col_lbl, form_status_color, form_status_buf[0..form_status_len], token);
    }
}

fn drawShellLog(dma_phys: u64, text_phys: u64, text_va: u64, start_x: u32, start_y: u32, h: u32, token: u64) void {
    _ = start_x;
    const log_phys = dma_phys + DMA_LOG_SLOT * lib.PAGE_SIZE;
    const log_va = DMA_BASE_VA + DMA_LOG_SLOT * 4096;
    _ = lib.syscall(SYS_GET_VARDE_LOG, log_phys, 0, token);
    const log_ptr = lib.ptrFrom([*]const u8, log_va);

    const base_row: u32 = start_y / 8 + 3;
    const max_rows: u32 = (h / 8) - 5;

    // Scan the last N lines from the log
    var line_offsets: [64]usize = undefined;
    var line_lens: [64]usize = undefined;
    var total_lines: usize = 0;

    var cur_start: usize = 0;
    var idx: usize = 0;
    while (idx < 4000) : (idx += 1) {
        const c = log_ptr[idx];
        if (c == 0 or c == '\n') {
            if (total_lines < line_offsets.len) {
                line_offsets[total_lines] = cur_start;
                line_lens[total_lines] = idx - cur_start;
                total_lines += 1;
            } else {
                // Shift back by one to keep recent lines
                var s: usize = 0;
                while (s + 1 < line_offsets.len) : (s += 1) {
                    line_offsets[s] = line_offsets[s + 1];
                    line_lens[s] = line_lens[s + 1];
                }
                line_offsets[line_offsets.len - 1] = cur_start;
                line_lens[line_offsets.len - 1] = idx - cur_start;
            }
            cur_start = idx + 1;
            if (c == 0) break;
        }
    }

    const lines_to_show = @min(total_lines, max_rows);
    const start_show = if (total_lines > lines_to_show) (total_lines - lines_to_show) else 0;

    var r: u32 = 0;
    while (r < lines_to_show) : (r += 1) {
        const l_idx = start_show + r;
        const off = line_offsets[l_idx];
        const len = @min(line_lens[l_idx], 65);
        if (len > 0) {
            lib.drawText(text_phys, text_va, base_row + r, 34, COLOR_WHITE, log_ptr[off .. off + len], token);
        }
    }

    // Bottom interactive indicator when shell is focused
    const prompt_row = base_row + lines_to_show + 1;
    if (focused_pane == 2) {
        lib.drawText(text_phys, text_va, prompt_row, 34, COLOR_GOLDEN_YELLOW, "varde (active) > _", token);
    }
}

fn drawBottomBar(text_phys: u64, text_va: u64, token: u64) void {
    const y: u32 = SCREEN_HEIGHT - 20;
    lib.fillRect(0, y, SCREEN_WIDTH, 20, COLOR_SEA_GRAY, token);
    const bar_text = " [Tab] Switch Pane | [F1] VM List | [F2] New VM | [F3] Shell | [S]tart | [K]ill | [D]elete | [Enter] Select";
    lib.drawText(text_phys, text_va, y / 8 + 1, 1, COLOR_WHITE, bar_text, token);
}
