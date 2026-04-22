const std = @import("std");
const lib = @import("lib.zig");

// Syscalls
const SYS_REGISTER = 2;
const SYS_RECV = 3;
const SYS_FREE_PAGE = 4;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_FB_DRAW = 16;
const SYS_MAP_RECV = 17;
const SYS_FB_DRAW_COLORED = 18;
const SYS_FB_FILL_RECT = 19;
const SYS_TRY_RECV = 20;
const SYS_GET_VARDE_LOG = 21;

const BootstrapDescriptor = lib.BootstrapDescriptor;
const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;

const COLS: usize = 100; // 800px / 8px
const ROWS: usize = 75;  // 600px / 8px

// Branding Colors (Matches kernel fb.zig)
const COLOR_SEA_GRAY: u32 = 0x004A4E69;
const COLOR_TERRACOTTA: u32 = 0x00E2725B;
const COLOR_GOLDEN_YELLOW: u32 = 0x00FFC300;
const COLOR_WHITE: u32 = 0x00FFFFFF;
const COLOR_GREEN: u32 = 0x0000FF00;
const COLOR_RED: u32 = 0x00FF0000;
const COLOR_HIGHLIGHT: u32 = 0x005BC0EB;

// State
var focused_field: u8 = 0; // 0=name, 1=vcpus, 2=mem
var form_name: [32]u8 = [_]u8{0} ** 32;
var form_name_len: usize = 0;
var form_vcpus: [4]u8 = "1\x00\x00\x00".*;
var form_vcpus_len: usize = 1;
var form_mem: [10]u8 = "16384\x00\x00\x00\x00\x00".*;
var form_mem_len: usize = 5;

var selected_vm_idx: usize = 0;
var vm_list: lib.VmSnapshotListPayload = undefined;
var vm_list_ready: bool = false;

// Helper to parse decimal from bytes
fn parseDecimal(bytes: []const u8) u32 {
    var val: u32 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') break;
        val = val * 10 + (c - '0');
    }
    return val;
}

// Drawing Helpers
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
    _ = lib.syscall(SYS_FB_DRAW_COLORED, dma_phys, arg1, token);
}

fn drawPanel(buf: [*]u8, dma_phys: u64, x: u32, y: u32, w: u32, h: u32, title: []const u8, token: u64) void {
    fillRect(x, y, w, h, COLOR_SEA_GRAY, token);
    fillRect(x, y, w, 20, COLOR_TERRACOTTA, token);
    drawText(buf, dma_phys, y / 8 + 1, x / 8 + 1, COLOR_WHITE, title, token);
}

fn drawTui(dma_phys: u64, token: u64) void {
    const buf: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA);

    // 1. VM Manager Pane
    drawPanel(buf, dma_phys, 0, 20, 800, 200, "MicroVM Manager", token);
    drawText(buf, dma_phys, 6, 2, COLOR_GOLDEN_YELLOW, "ID | Name           | Mem (pages) | vCPUs | State", token);
    drawText(buf, dma_phys, 7, 2, COLOR_WHITE, "---|----------------|-------------|-------|---------", token);
    
    if (vm_list_ready) {
        var i: u32 = 0;
        while (i < vm_list.count) : (i += 1) {
            const vm = &vm_list.entries[i];
            var line: [100]u8 = [_]u8{' '} ** 100;
            const state_str = if (vm.state == 1) "Created" else if (vm.state == 2) "Running" else "Stopped";
            const state_color = if (vm.state == 2) COLOR_GREEN else COLOR_RED;
            const row_color = if (i == selected_vm_idx) COLOR_GOLDEN_YELLOW else COLOR_WHITE;
            
            line[0] = @as(u8, @intCast(vm.instance_id % 10)) + '0';
            line[1] = ' '; line[2] = '|'; line[3] = ' ';
            
            const name_len: usize = @min(vm.name.len, @as(usize, 14));
            @memcpy(line[4 .. 4 + name_len], vm.name[0..name_len]);
            line[19] = '|'; line[20] = ' ';
            
            line[21] = ' '; // placeholder
            line[33] = '|'; line[34] = ' ';
            
            line[35] = @as(u8, @intCast(vm.vcpus % 10)) + '0';
            line[41] = '|'; line[42] = ' ';
            
            drawText(buf, dma_phys, 8 + i, 2, row_color, line[0..43], token);
            drawText(buf, dma_phys, 8 + i, 45, state_color, state_str, token);
        }
    }

    // 2. New VM Form Pane
    drawPanel(buf, dma_phys, 0, 220, 800, 100, "New MicroVM", token);
    const name_fg = if (focused_field == 0) COLOR_HIGHLIGHT else COLOR_WHITE;
    const vcpu_fg = if (focused_field == 1) COLOR_HIGHLIGHT else COLOR_WHITE;
    const mem_fg = if (focused_field == 2) COLOR_HIGHLIGHT else COLOR_WHITE;

    drawText(buf, dma_phys, 30, 2, name_fg, "Name: [", token);
    drawText(buf, dma_phys, 30, 9, COLOR_WHITE, form_name[0..form_name_len], token);
    drawText(buf, dma_phys, 30, 9 + @as(u32, @intCast(form_name_len)), COLOR_WHITE, "_", token);
    drawText(buf, dma_phys, 30, 42, name_fg, "]", token);

    drawText(buf, dma_phys, 30, 45, vcpu_fg, "vCPUs: [", token);
    drawText(buf, dma_phys, 30, 53, COLOR_WHITE, form_vcpus[0..form_vcpus_len], token);
    drawText(buf, dma_phys, 30, 53 + @as(u32, @intCast(form_vcpus_len)), COLOR_WHITE, "_", token);
    drawText(buf, dma_phys, 30, 58, vcpu_fg, "]", token);

    drawText(buf, dma_phys, 32, 2, mem_fg, "Mem(pg): [", token);
    drawText(buf, dma_phys, 32, 12, COLOR_WHITE, form_mem[0..form_mem_len], token);
    drawText(buf, dma_phys, 32, 12 + @as(u32, @intCast(form_mem_len)), COLOR_WHITE, "_", token);
    drawText(buf, dma_phys, 32, 23, mem_fg, "]", token);

    drawText(buf, dma_phys, 36, 2, COLOR_WHITE, "[TAB] Focus field   [Enter] Create VM   [D] Delete   [S] Start/Stop", token);

    // 3. Shell Log Pane
    drawPanel(buf, dma_phys, 0, 320, 800, 280, "Varde Shell Log", token);
    const log_addr: u64 = dma_phys + 4096;
    const history_len = lib.syscall(SYS_GET_VARDE_LOG, log_addr, 0, token);
    const hist: [*]const u8 = @ptrFromInt(DMA_BASE_VA + 4096);

    if (history_len > 0) {
        var row: u32 = 42;
        var pos: usize = if (history_len > 3000) history_len - 3000 else 0;
        while (pos < history_len and hist[pos] != '\n') : (pos += 1) {}
        if (pos < history_len) pos += 1;
        while (pos < history_len and row < 74) {
            var end = pos;
            while (end < history_len and hist[end] != '\n') : (end += 1) {}
            const line_len = @min(end - pos, COLS - 4);
            if (line_len > 0) drawText(buf, dma_phys, row, 2, COLOR_WHITE, hist[pos .. pos + line_len], token);
            row += 1;
            pos = end + 1;
        }
    }
}

fn requestVmList(bs: *const BootstrapDescriptor, dma_phys: u64, token: u64) void {
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 8192);
    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };
    const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    head.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(lib.CONTROL_HEADER_SIZE)),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = 9 },
        .dst = .{ .node = local_node, .endpoint = 2 },
    };
    const ctrl: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    ctrl.* = .{ .op = .list_microvms, .payload_len = 0 };
    _ = lib.syscall(SYS_SEND_PAGE, dma_phys + 8192, 0, token);
}

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;
    _ = lib.syscall(SYS_REGISTER, 0, 9, token);
    lib.serialWrite("windowd: registered at endpoint 9\n");
    const dma_phys = lib.syscall(SYS_ALLOC_DMA, 4, 0, token);
    if (dma_phys == 0) while (true) asm volatile ("pause");
    fillRect(0, 0, 800, 600, COLOR_SEA_GRAY, token);
    drawTui(dma_phys, token);
    var last_poll: u64 = 0;
    while (true) {
        const page_phys = lib.syscall(SYS_TRY_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                const payload_hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
                if (payload_hdr.src.endpoint == 8) {
                    const evt: *align(1) const extern struct { event_type: u8, ascii: u8, scancode: u8 } = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
                    if (evt.ascii != 0) {
                        const low_ascii = if (evt.ascii >= 'A' and evt.ascii <= 'Z') evt.ascii + 32 else evt.ascii;
                        if (evt.ascii == '\t') {
                            focused_field = (focused_field + 1) % 3;
                        } else if (evt.ascii == 0x08) {
                            if (focused_field == 0 and form_name_len > 0) form_name_len -= 1;
                            if (focused_field == 1 and form_vcpus_len > 0) form_vcpus_len -= 1;
                            if (focused_field == 2 and form_mem_len > 0) form_mem_len -= 1;
                        } else if (evt.ascii == '\n') {
                            const vcpus = parseDecimal(form_vcpus[0..form_vcpus_len]);
                            const mem = parseDecimal(form_mem[0..form_mem_len]);
                            if (form_name_len > 0 and vcpus > 0 and mem > 0) {
                                const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 8192);
                                const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
                                head.* = .{ .magic = lib.WireMagic, .version = lib.WireVersion, .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)), .payload_len = @as(u32, @intCast(lib.CONTROL_HEADER_SIZE + @sizeOf(lib.CreateMicrovmPayload))), .auth_tag = 0, .src = .{ .node = lib.Ipv6Addr{ .bytes = bs.local_node }, .endpoint = 9 }, .dst = .{ .node = lib.Ipv6Addr{ .bytes = bs.local_node }, .endpoint = 2 } };
                                const ctrl: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
                                ctrl.* = .{ .op = .create_microvm, .payload_len = @as(u32, @intCast(@sizeOf(lib.CreateMicrovmPayload))) };
                                const p: *align(1) lib.CreateMicrovmPayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
                                p.* = .{ .mem_pages = mem, .vcpus = vcpus, .kernel_phys = bs.linux_bzimage_phys, .kernel_size = bs.linux_bzimage_size, .initramfs_phys = bs.initramfs_phys, .initramfs_size = bs.initramfs_size, .name = [_]u8{0} ** 32 };
                                @memcpy(p.name[0..form_name_len], form_name[0..form_name_len]);
                                _ = lib.syscall(SYS_SEND_PAGE, dma_phys + 8192, 0, token);
                                form_name_len = 0;
                            }
                        } else if (low_ascii == 'd') {
                            if (vm_list_ready and vm_list.count > 0 and selected_vm_idx < vm_list.count) {
                                const vm = &vm_list.entries[selected_vm_idx];
                                const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 8192);
                                const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
                                head.* = .{ .magic = lib.WireMagic, .version = lib.WireVersion, .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)), .payload_len = @as(u32, @intCast(lib.CONTROL_HEADER_SIZE + @sizeOf(lib.DeleteMicrovmPayload))), .auth_tag = 0, .src = .{ .node = lib.Ipv6Addr{ .bytes = bs.local_node }, .endpoint = 9 }, .dst = .{ .node = lib.Ipv6Addr{ .bytes = bs.local_node }, .endpoint = 2 } };
                                const ctrl: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
                                ctrl.* = .{ .op = .delete_microvm, .payload_len = @as(u32, @intCast(@sizeOf(lib.DeleteMicrovmPayload))) };
                                const p: *align(1) lib.DeleteMicrovmPayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
                                p.* = .{ .instance_id = vm.instance_id };
                                _ = lib.syscall(SYS_SEND_PAGE, dma_phys + 8192, 0, token);
                            }
                        } else if (low_ascii == 's') {
                            if (vm_list_ready and vm_list.count > 0 and selected_vm_idx < vm_list.count) {
                                const vm = &vm_list.entries[selected_vm_idx];
                                const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 8192);
                                const head: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
                                head.* = .{ .magic = lib.WireMagic, .version = lib.WireVersion, .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)), .payload_len = @as(u32, @intCast(lib.CONTROL_HEADER_SIZE + @sizeOf(lib.StartMicrovmPayload))), .auth_tag = 0, .src = .{ .node = lib.Ipv6Addr{ .bytes = bs.local_node }, .endpoint = 9 }, .dst = .{ .node = lib.Ipv6Addr{ .bytes = bs.local_node }, .endpoint = 2 } };
                                const ctrl: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
                                ctrl.* = .{ .op = if (vm.state == 2) .stop_microvm else .start_microvm, .payload_len = @as(u32, @intCast(@sizeOf(lib.StartMicrovmPayload))) };
                                const p: *align(1) lib.StartMicrovmPayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
                                p.* = .{ .instance_id = vm.instance_id };
                                _ = lib.syscall(SYS_SEND_PAGE, dma_phys + 8192, 0, token);
                            }
                        } else if (evt.scancode == 0x48) {
                            if (selected_vm_idx > 0) selected_vm_idx -= 1;
                        } else if (evt.scancode == 0x50) {
                            if (vm_list_ready and selected_vm_idx + 1 < vm_list.count) selected_vm_idx += 1;
                        } else {
                            if (focused_field == 0 and form_name_len < 31) {
                                form_name[form_name_len] = evt.ascii;
                                form_name_len += 1;
                            } else if (focused_field == 1 and form_vcpus_len < 3) {
                                if (evt.ascii >= '0' and evt.ascii <= '9') {
                                    form_vcpus[form_vcpus_len] = evt.ascii;
                                    form_vcpus_len += 1;
                                }
                            } else if (focused_field == 2 and form_mem_len < 9) {
                                if (evt.ascii >= '0' and evt.ascii <= '9') {
                                    form_mem[form_mem_len] = evt.ascii;
                                    form_mem_len += 1;
                                }
                            }
                        }
                    }
                } else if (payload_hdr.src.endpoint == 2) {
                    const ctrl: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
                    if (ctrl.op == .list_microvms) {
                        const snap: *align(1) const lib.VmSnapshotListPayload = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
                        vm_list = snap.*;
                        vm_list_ready = true;
                    }
                }
                _ = lib.syscall(4, lib.DIPC_RECV_VA, 0, token);
            }
            drawTui(dma_phys, token);
        }
        last_poll += 1;
        if (last_poll > 1000000) {
            requestVmList(bs, dma_phys, token);
            last_poll = 0;
            drawTui(dma_phys, token);
        }
        asm volatile ("pause");
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
}
