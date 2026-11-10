const std = @import("std");
const lib = @import("lib.zig");
const tui = @import("tui/mod.zig");
const color = tui.color;
const Rect = tui.Rect;
const DamageTracker = tui.DamageTracker;
const Panel = tui.Panel;
const TextInput = tui.TextInput;
const NumberSpinner = tui.NumberSpinner;
const OptionSelect = tui.OptionSelect;
const ListView = tui.ListView;
const Button = tui.Button;
const ModalDialog = tui.ModalDialog;
const HistoryRing = tui.HistoryRing;

// Syscall ops (mirrors lib.zig constants)
const SYS_REGISTER = lib.SYS_REGISTER;
const SYS_TRY_RECV = lib.SYS_TRY_RECV;
const SYS_MAP_RECV = lib.SYS_MAP_RECV;
const SYS_FREE_PAGE = lib.SYS_FREE_PAGE;
const SYS_ALLOC_DMA = lib.SYS_ALLOC_DMA;
const SYS_SEND_PAGE = lib.SYS_SEND_PAGE;
const SYS_GET_VARDE_LOG = lib.SYS_GET_VARDE_LOG;
const SYS_VARDE_INJECT = lib.SYS_VARDE_INJECT;
const SYS_GET_VM_CONSOLE_LOG = lib.SYS_GET_VM_CONSOLE_LOG;
const SYS_VM_CONSOLE_INJECT = lib.SYS_VM_CONSOLE_INJECT;
const SYS_YIELD = lib.SYS_YIELD;

const USER_BOOTSTRAP_VADDR: usize = lib.USER_BOOTSTRAP_VADDR;
const DMA_BASE_VA: u64 = lib.DMA_BASE_VA;

// DMA page layout (each slot = 4096 bytes)
const DMA_TEXT_SLOT: u64 = 0;
const DMA_LOG_SLOT: u64 = 1;
const DMA_SCRATCH_SLOT: u64 = 2;
pub const DMA_CONSOLE_SLOT: u64 = 3;
const DMA_NUM_PAGES: u64 = 4;

var COLS: usize = 100;
var ROWS: usize = 75;
var SCREEN_WIDTH: u32 = 800;
var SCREEN_HEIGHT: u32 = 600;

// Surface Adapter: Bridges to lib.fillRect and lib.drawTextBg satisfying tui duck-typing
pub const Surface = struct {
    token: u64,
    dma_phys: u64,
    dma_va: u64,

    pub fn fillRect(self: Surface, x: u32, y: u32, w: u32, h: u32, col: u32) void {
        lib.fillRect(x, y, w, h, col, self.token);
    }

    pub fn drawText(self: Surface, row: u32, col: u32, fg: u32, bg: u32, text: []const u8) void {
        lib.drawTextBg(self.dma_phys, self.dma_va, row, col, fg, bg, text, self.token);
    }
};

// --- Focus & Layout State ---
pub const Pane = enum(u8) {
    vm_form = 0,
    vm_manager = 1,
    varde_shell = 2,
    guest_console = 3,
};

pub const FormField = enum(u8) {
    name = 0,
    vcpus = 1,
    memory = 2,
    kernel = 3,
    rootfs = 4,
    create_btn = 5,
    reset_btn = 6,
};

var focused_pane: Pane = .vm_form;
var focused_form_field: FormField = .name;

// Geometry Rectangles
var header_rect: Rect = Rect.init(0, 0, 800, 20);
var left_panel_rect: Rect = Rect.init(0, 20, 400, 288);
var shell_panel_rect: Rect = Rect.init(0, 308, 400, 272);
var shell_prompt_rect: Rect = Rect.init(16, 544, 368, 16);
var right_panel_rect: Rect = Rect.init(400, 20, 400, 304);
var console_panel_rect: Rect = Rect.init(400, 324, 400, 256);
var bottom_bar_rect: Rect = Rect.init(0, 580, 800, 20);
var status_banner_rect: Rect = Rect.init(24, 212, 352, 24);

// Damage Tracker
var damage_tracker: DamageTracker = DamageTracker.initWithBounds(Rect.init(0, 0, 800, 600));

// TUI Panels
var left_panel: Panel = undefined;
var shell_panel: Panel = undefined;
var right_panel: Panel = undefined;
var console_panel: Panel = undefined;
var help_modal: ModalDialog = undefined;

// Varde Shell Line Editor, History & Scrollback State
var shell_input: TextInput = undefined;
var shell_history: HistoryRing = HistoryRing.init();
var shell_scroll_offset: usize = 0;
var shell_auto_scroll: bool = true;

// Guest Serial Console State
var active_console_vm_id: u32 = 1;
var console_scroll_offset: usize = 0;
var console_auto_scroll: bool = true;
var last_seen_console_len: usize = 0;
var last_seen_console_vm_id: u32 = 0;
var last_injected_char: u8 = 0;

// Form Widgets
var form_name_input: TextInput = undefined;
var form_vcpu_spinner: NumberSpinner = undefined;
const MEM_OPTIONS = [_][]const u8{ "16 MB", "32 MB", "64 MB", "128 MB" };
const MEM_VALUES = [_]u32{ 16, 32, 64, 128 };
var form_mem_select: OptionSelect = undefined;
const KERNEL_OPTIONS = [_][]const u8{ "Embedded Linux 6.6", "Custom" };
var form_kernel_select: OptionSelect = undefined;
const ROOTFS_OPTIONS = [_][]const u8{ "In-Memory OCI Demo", "NVMe Staged" };
var form_rootfs_select: OptionSelect = undefined;
var form_create_btn: Button = undefined;
var form_reset_btn: Button = undefined;

// VM List View
var vm_list_view: ListView = undefined;

// Status feedback buffer
var form_status_buf: [64]u8 = @splat(0);
var form_status_len: usize = 0;
var form_status_color: u32 = color.COLOR_GREEN;

fn setFormStatus(msg: []const u8, c: u32) void {
    const n = @min(msg.len, form_status_buf.len);
    @memcpy(form_status_buf[0..n], msg[0..n]);
    form_status_len = n;
    form_status_color = c;
}

// MicroVM State
const VmItem = struct {
    name: [32]u8,
    status: []const u8,
    id: u32,
    state: u8,
    vcpus: u32,
    mem_pages: u64,
    cpu_cycles: u64,
    exit_count: u64,
};
var microvm_list: [16]VmItem = undefined;
var microvm_count: usize = 0;
var selected_vm_idx: usize = 0;
var needs_vm_refresh: bool = true;
var needs_redraw: bool = true;

// Varde Shell Log Tracking
var last_seen_shell_len: usize = 0;

const proto_dashd = @import("protocols/dashd_protocol.zig");
const proto_configd = @import("protocols/configd_protocol.zig");
const proto_netd = @import("protocols/netd_protocol.zig");

const NetworkBindCommand = struct {
    vmid: u32,
    ipv4: ?[4]u8 = null,
    ipv6: ?[16]u8 = null,
};

const NetworkBindParse = union(enum) {
    unrelated,
    invalid,
    binding: NetworkBindCommand,
};

const NetworkBindPhase = enum { querying, updating };
const PendingNetworkBind = struct {
    request_id: u64,
    command: NetworkBindCommand,
    phase: NetworkBindPhase = .querying,
    generation: u64 = 0,
    expected_revision: u64 = 0,
};

const NETWORK_REQUEST_TIMEOUT_TICKS: u32 = 1_000_000;
var network_request_id: u64 = 0;
var pending_network_bind: ?PendingNetworkBind = null;
var network_request_wait: u32 = 0;
var network_status_buf: [46]u8 = @splat(0);
var network_status_len: usize = 0;
var network_status_color: u32 = color.COLOR_WHITE;

fn parseNetworkBindCommand(command: []const u8) NetworkBindParse {
    var tokens = std.mem.tokenizeAny(u8, command, " \t");
    const name = tokens.next() orelse return .unrelated;
    if (!std.mem.eql(u8, name, "vnic-bind")) return .unrelated;
    const vmid_text = tokens.next() orelse return .invalid;
    const ipv4_text = tokens.next() orelse return .invalid;
    const ipv6_text = tokens.next() orelse return .invalid;
    if (tokens.next() != null) return .invalid;
    const vmid = std.fmt.parseInt(u32, vmid_text, 10) catch return .invalid;
    if (vmid == 0) return .invalid;
    var result = NetworkBindCommand{ .vmid = vmid };
    if (!std.mem.eql(u8, ipv4_text, "-")) {
        const address = std.Io.net.Ip4Address.parse(ipv4_text, 0) catch return .invalid;
        result.ipv4 = address.bytes;
    }
    if (!std.mem.eql(u8, ipv6_text, "-")) {
        const address = std.Io.net.Ip6Address.parse(ipv6_text, 0) catch return .invalid;
        result.ipv6 = address.bytes;
    }
    return .{ .binding = result };
}

fn setNetworkStatus(message: []const u8, status_color: u32) void {
    network_status_len = @min(message.len, network_status_buf.len);
    @memcpy(network_status_buf[0..network_status_len], message[0..network_status_len]);
    network_status_color = status_color;
    damage_tracker.addDamage(shell_panel_rect);
    needs_redraw = true;
}

fn sendConfigdMessage(dma_phys: u64, token: u64, op: proto_configd.Op, payload: []const u8) bool {
    const body_len = @sizeOf(proto_configd.ConfigdHeader) + payload.len;
    if (lib.DIPC_HEADER_SIZE + body_len > lib.PAGE_SIZE) return false;
    const scratch_phys = dma_phys + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const scratch_va = DMA_BASE_VA + DMA_SCRATCH_SLOT * lib.PAGE_SIZE;
    const scratch: [*]u8 = lib.ptrFrom([*]u8, scratch_va);
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @intCast(lib.DIPC_HEADER_SIZE),
        .payload_len = @intCast(body_len),
        .auth_tag = 0,
        .src = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @backingInt(lib.ReservedEndpoint.windowd) },
        .dst = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @backingInt(lib.ReservedEndpoint.configd) },
    };
    const config_header: *align(1) proto_configd.ConfigdHeader =
        @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    config_header.* = .{ .op = op, .payload_len = @intCast(payload.len) };
    if (payload.len > 0) {
        @memcpy(scratch[lib.DIPC_HEADER_SIZE + @sizeOf(proto_configd.ConfigdHeader) ..][0..payload.len], payload);
    }
    return lib.syscall(SYS_SEND_PAGE, scratch_phys, 0, token) == 0;
}

fn startNetworkBind(command: NetworkBindCommand, dma_phys: u64, token: u64) void {
    if (pending_network_bind != null) {
        setNetworkStatus("vNIC request already pending", color.COLOR_RED);
        return;
    }
    const request_id = std.math.add(u64, network_request_id, 1) catch {
        setNetworkStatus("vNIC request IDs exhausted", color.COLOR_RED);
        return;
    };
    network_request_id = request_id;
    const request = proto_configd.LocalPortStatusRequest{ .request_id = request_id, .vmid = command.vmid };
    if (!sendConfigdMessage(dma_phys, token, .local_port_status, std.mem.asBytes(&request))) {
        setNetworkStatus("Could not query vNIC", color.COLOR_RED);
        return;
    }
    pending_network_bind = .{ .request_id = request_id, .command = command };
    network_request_wait = 0;
    setNetworkStatus("Querying vNIC...", color.COLOR_HIGHLIGHT);
}

fn isLocalConfigdReply(page: *const lib.PageHeader) bool {
    const loopback = lib.Ipv6Addr.loopback();
    return page.magic == lib.WireMagic and page.version == lib.WireVersion and
        page.header_len == lib.DIPC_HEADER_SIZE and
        page.src.endpoint == @backingInt(lib.ReservedEndpoint.configd) and
        page.dst.endpoint == @backingInt(lib.ReservedEndpoint.windowd) and
        std.mem.eql(u8, &page.src.node.bytes, &loopback.bytes) and
        std.mem.eql(u8, &page.dst.node.bytes, &loopback.bytes);
}

fn finishNetworkBind(message: []const u8, status_color: u32) void {
    pending_network_bind = null;
    network_request_wait = 0;
    setNetworkStatus(message, status_color);
}

fn handleNetworkBindReply(page: *const lib.PageHeader, payload_va: u64, dma_phys: u64, token: u64) void {
    var pending = pending_network_bind orelse return;
    if (!isLocalConfigdReply(page) or page.payload_len < @sizeOf(proto_configd.ConfigdHeader)) return;
    const header: *align(1) const proto_configd.ConfigdHeader = @ptrFromInt(payload_va);
    if (header.magic != proto_configd.MAGIC or header.version != proto_configd.VERSION or header._pad != 0 or
        header.payload_len != page.payload_len - @sizeOf(proto_configd.ConfigdHeader)) return;
    const op = @as(*align(1) const u16, @ptrCast(&header.op)).*;
    const body_va = payload_va + @sizeOf(proto_configd.ConfigdHeader);
    if (op == @backingInt(proto_configd.Op.local_port_status_reply) and pending.phase == .querying) {
        if (header.payload_len != @sizeOf(proto_configd.LocalPortStatusReply)) return;
        const reply: *align(1) const proto_configd.LocalPortStatusReply = @ptrFromInt(body_va);
        if (reply.request_id != pending.request_id or reply.vmid != pending.command.vmid or reply._reserved != 0) return;
        const status = @as(*align(1) const u16, @ptrCast(&reply.status)).*;
        if (status > @backingInt(proto_netd.SwitchConfigStatus.no_capacity)) return;
        if (status != @backingInt(proto_netd.SwitchConfigStatus.ok)) {
            finishNetworkBind("vNIC unavailable or busy", color.COLOR_RED);
            return;
        }
        if (reply.generation == 0 or reply.policy_revision == 0) return;
        var request = proto_configd.LocalBindingsRequest{
            .vmid = pending.command.vmid,
            .generation = reply.generation,
            .expected_revision = reply.policy_revision,
            .request_id = pending.request_id,
            .ipv4_count = if (pending.command.ipv4 == null) 0 else 1,
            .ipv6_count = if (pending.command.ipv6 == null) 0 else 1,
        };
        if (pending.command.ipv4) |address| request.ipv4_addresses[0] = address;
        if (pending.command.ipv6) |address| request.ipv6_addresses[0] = address;
        if (!sendConfigdMessage(dma_phys, token, .local_bindings_replace, std.mem.asBytes(&request))) {
            finishNetworkBind("Could not send vNIC update", color.COLOR_RED);
            return;
        }
        pending.phase = .updating;
        pending.generation = reply.generation;
        pending.expected_revision = reply.policy_revision;
        pending_network_bind = pending;
        network_request_wait = 0;
        setNetworkStatus("Updating vNIC...", color.COLOR_HIGHLIGHT);
    } else if (op == @backingInt(proto_configd.Op.local_bindings_reply) and pending.phase == .updating) {
        if (header.payload_len != @sizeOf(proto_configd.LocalBindingsReply)) return;
        const reply: *align(1) const proto_configd.LocalBindingsReply = @ptrFromInt(body_va);
        if (reply.request_id != pending.request_id or reply.vmid != pending.command.vmid or
            reply.generation != pending.generation or reply._reserved != 0) return;
        const status = @as(*align(1) const u16, @ptrCast(&reply.status)).*;
        if (status > @backingInt(proto_netd.SwitchConfigStatus.no_capacity)) return;
        if (status == @backingInt(proto_netd.SwitchConfigStatus.ok)) {
            const next_revision = std.math.add(u64, pending.expected_revision, 1) catch return;
            if (reply.policy_revision != next_revision) return;
            finishNetworkBind("vNIC updated; firewall rules cleared", color.COLOR_GREEN);
            lib.serialWrite("[UI] vNIC bindings updated (default-deny)\n");
        } else {
            if (reply.policy_revision != 0) return;
            finishNetworkBind("vNIC update rejected; check addresses/state", color.COLOR_RED);
            lib.serialWrite("[UI] vNIC binding rejected\n");
        }
    }
}

// Cluster Node View
const MAX_NODES: usize = 8;
const NodeRow = struct {
    used: bool = false,
    addr: [16]u8 = @splat(0),
    vms: u32 = 0,
    cycles: u64 = 0,
    exits: u64 = 0,
};
var node_rows: [MAX_NODES]NodeRow = @splat(.{});

const proto_inputd = @import("protocols/inputd_protocol.zig");
const InputEventPayload = proto_inputd.InputEvent;

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
        .src = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @backingInt(lib.ReservedEndpoint.windowd) },
        .dst = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @backingInt(lib.ReservedEndpoint.dashd) },
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

fn sendVmCreate(bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64, name: []const u8, vcpus: u32, mem_mb: u32, rootfs_tag: []const u8) void {
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
        .name = @splat(0),
        .container = @splat(0),
    };
    const len = @min(name.len, 31);
    @memcpy(p.name[0..len], name[0..len]);
    const rlen = @min(rootfs_tag.len, 31);
    @memcpy(p.container[0..rlen], rootfs_tag[0..rlen]);
    lib.sendControl(bs, scratch_phys, scratch_va, token, .create_microvm, std.mem.asBytes(&p));
}

// --- Serial Milestone Emission Helpers ---

fn emitMilestoneProvisioned(name: []const u8) void {
    var buf: [64]u8 = undefined;
    var p: usize = 0;
    appendStr(&buf, &p, "[UI] MicroVM provisioned: ");
    appendStr(&buf, &p, name);
    appendStr(&buf, &p, "\n");
    lib.serialWrite(buf[0..p]);
}

fn emitMilestoneStarted(id: u32) void {
    var buf: [48]u8 = undefined;
    var p: usize = 0;
    appendStr(&buf, &p, "[UI] MicroVM ");
    appendDec(&buf, &p, id);
    appendStr(&buf, &p, " started\n");
    lib.serialWrite(buf[0..p]);
}

fn emitMilestoneStopped(id: u32) void {
    var buf: [48]u8 = undefined;
    var p: usize = 0;
    appendStr(&buf, &p, "[UI] MicroVM ");
    appendDec(&buf, &p, id);
    appendStr(&buf, &p, " stopped\n");
    lib.serialWrite(buf[0..p]);
}

fn emitMilestoneDeleted(id: u32) void {
    var buf: [48]u8 = undefined;
    var p: usize = 0;
    appendStr(&buf, &p, "[UI] MicroVM ");
    appendDec(&buf, &p, id);
    appendStr(&buf, &p, " deleted\n");
    lib.serialWrite(buf[0..p]);
}

fn emitMilestoneConsoleSwitched(id: u32) void {
    var buf: [64]u8 = undefined;
    var p: usize = 0;
    appendStr(&buf, &p, "[UI] Switched console to MicroVM #");
    appendDec(&buf, &p, id);
    appendStr(&buf, &p, "\n");
    lib.serialWrite(buf[0..p]);
}

fn cycleConsoleVm(delta: i32) void {
    if (microvm_count >= 2) {
        var cur_idx: usize = 0;
        for (microvm_list[0..microvm_count], 0..) |vm, idx| {
            if (vm.id == active_console_vm_id) {
                cur_idx = idx;
                break;
            }
        }
        const count_i: i32 = @intCast(microvm_count);
        const next_i = @mod(@as(i32, @intCast(cur_idx)) + delta, count_i);
        active_console_vm_id = microvm_list[@as(usize, @intCast(next_i))].id;
    } else {
        active_console_vm_id = if (active_console_vm_id == 1) 2 else 1;
    }
    console_scroll_offset = 0;
    console_auto_scroll = true;
}

// --- Widget Focus Synchronization ---

fn syncWidgetFocus() void {
    const is_form = (focused_pane == .vm_form);
    const is_mgr = (focused_pane == .vm_manager);
    const is_shell = (focused_pane == .varde_shell);
    const is_console = (focused_pane == .guest_console);
    left_panel.setFocused(is_form);
    right_panel.setFocused(is_mgr);
    shell_panel.setFocused(is_shell);
    console_panel.setFocused(is_console);
    form_name_input.setFocused(is_form and focused_form_field == .name);
    form_vcpu_spinner.setFocused(is_form and focused_form_field == .vcpus);
    form_mem_select.setFocused(is_form and focused_form_field == .memory);
    form_kernel_select.setFocused(is_form and focused_form_field == .kernel);
    form_rootfs_select.setFocused(is_form and focused_form_field == .rootfs);
    form_create_btn.setFocused(is_form and focused_form_field == .create_btn);
    form_reset_btn.setFocused(is_form and focused_form_field == .reset_btn);
    vm_list_view.setFocused(is_mgr);
    shell_input.setFocused(is_shell);
}

// --- Widget Initialization ---

fn initWidgets() void {
    const pane_w = SCREEN_WIDTH / 2;
    const work_h = SCREEN_HEIGHT - 40;
    const form_h: u32 = 288;
    const shell_h: u32 = work_h - form_h;
    const mgr_h: u32 = 304;
    const console_h: u32 = work_h - mgr_h;

    header_rect = Rect.init(0, 0, SCREEN_WIDTH, 20);
    left_panel_rect = Rect.init(0, 20, pane_w, form_h);
    shell_panel_rect = Rect.init(0, 20 + form_h, pane_w, shell_h);
    shell_prompt_rect = Rect.init(16, 544, pane_w - 32, 16);
    right_panel_rect = Rect.init(pane_w, 20, pane_w, mgr_h);
    console_panel_rect = Rect.init(pane_w, 20 + mgr_h, pane_w, console_h);
    bottom_bar_rect = Rect.init(0, SCREEN_HEIGHT - 20, SCREEN_WIDTH, 20);
    status_banner_rect = Rect.init(24, 212, 352, 24);

    damage_tracker = DamageTracker.initWithBounds(Rect.init(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT));

    left_panel = Panel.init(left_panel_rect, "MicroVM Provisioning Form [F2]");
    shell_panel = Panel.init(shell_panel_rect, "Varde Shell [F4] [PgUp/PgDn]");
    right_panel = Panel.init(right_panel_rect, "VM Manager & Inspector [F3]");
    console_panel = Panel.init(console_panel_rect, "Guest Serial Console (ttyS0) [F6]");

    // Form fields
    form_name_input = TextInput.init(Rect.init(128, 48, 248, 16), 31);
    form_name_input.setText("alpine-node-01");

    form_vcpu_spinner = NumberSpinner.init(Rect.init(128, 72, 160, 16), 1, 1, 1, 1, " vCPU");

    form_mem_select = OptionSelect.init(Rect.init(128, 96, 160, 16), &MEM_OPTIONS, 1);

    form_kernel_select = OptionSelect.init(Rect.init(128, 120, 248, 16), &KERNEL_OPTIONS, 0);

    form_rootfs_select = OptionSelect.init(Rect.init(128, 144, 248, 16), &ROOTFS_OPTIONS, 0);

    form_create_btn = Button.init(Rect.init(24, 176, 192, 24), "CREATE & LAUNCH");
    form_reset_btn = Button.init(Rect.init(232, 176, 136, 24), "RESET");

    // Varde Shell Line Editor
    shell_input = TextInput.init(Rect.init(96, 544, 288, 16), 96);
    shell_history = HistoryRing.init();
    shell_scroll_offset = 0;
    shell_auto_scroll = true;

    // Guest Console State
    active_console_vm_id = 1;
    console_scroll_offset = 0;
    console_auto_scroll = true;

    // VM Manager ListView
    vm_list_view = ListView.init(Rect.init(412, 56, 376, 80), 4);
    vm_list_view.setItemCount(0);

    // Centered Help Modal
    help_modal = ModalDialog.initCentered(560, 420, SCREEN_WIDTH, SCREEN_HEIGHT, "Catenary OS - Operator Guide & Shortcuts");

    syncWidgetFocus();
}

// --- Main Event Loop ---

pub export fn umain() noreturn {
    lib.serialWrite("windowd: starting\n");
    const bs: *const lib.BootstrapDescriptor =
        lib.ptrFrom(*const lib.BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    _ = lib.syscall(SYS_REGISTER, 0, @backingInt(lib.ReservedEndpoint.windowd), token);
    lib.serialWrite("windowd: registered at endpoint 9\n");

    // Allocate DMA pages
    const dma_phys = lib.syscall(SYS_ALLOC_DMA, DMA_NUM_PAGES, 0, token);
    if (dma_phys == 0) while (true) asm volatile ("pause");

    if (lib.getFramebufferInfo(token)) |info| {
        if (info.width > 0) {
            SCREEN_WIDTH = info.width;
            SCREEN_HEIGHT = info.height;
            COLS = SCREEN_WIDTH / 8;
            ROWS = SCREEN_HEIGHT / 8;
        }
    }

    initWidgets();
    setFormStatus("Ready. Press [Tab] to navigate fields.", color.COLOR_HIGHLIGHT);

    // Initial paint with full screen damage
    damage_tracker.markAllDirty();
    drawTui(dma_phys, token);
    needs_redraw = false;

    var last_poll: u64 = 0;

    while (true) {
        if (needs_vm_refresh or last_poll > 600_000) {
            requestVmList(bs, dma_phys, token);
            requestClusterSummary(dma_phys, token);
            needs_vm_refresh = false;
            last_poll = 0;
        }

        while (true) {
            const page_phys = lib.syscall(SYS_TRY_RECV, 0, 0, token);
            if (page_phys == 0) break;
            const page_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (page_va != 0) {
                handleMessage(page_va, bs, dma_phys, token);
                _ = lib.syscall(SYS_FREE_PAGE, lib.DIPC_RECV_VA, 0, token);
            } else {
                _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
            }
        }

        const log_phys = dma_phys + DMA_LOG_SLOT * lib.PAGE_SIZE;
        const current_shell_len = lib.syscall(SYS_GET_VARDE_LOG, log_phys, 0, token);
        if (current_shell_len != last_seen_shell_len) {
            last_seen_shell_len = @intCast(current_shell_len);
            if (shell_auto_scroll) {
                shell_scroll_offset = 0;
            }
            damage_tracker.addDamage(shell_panel_rect);
            needs_redraw = true;
        }

        const console_phys = dma_phys + DMA_CONSOLE_SLOT * lib.PAGE_SIZE;
        const current_console_len = lib.getVmConsoleLog(console_phys, active_console_vm_id, token);
        if (current_console_len != last_seen_console_len or active_console_vm_id != last_seen_console_vm_id) {
            last_seen_console_len = current_console_len;
            last_seen_console_vm_id = active_console_vm_id;
            if (console_auto_scroll) {
                console_scroll_offset = 0;
            }
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
        }

        if (needs_redraw) {
            drawTui(dma_phys, token);
            needs_redraw = false;
        }

        if (pending_network_bind != null) {
            network_request_wait +|= 1;
            if (network_request_wait >= NETWORK_REQUEST_TIMEOUT_TICKS) {
                finishNetworkBind("vNIC request timed out; result unknown", color.COLOR_RED);
            }
        }

        last_poll += 1;
        _ = lib.syscall(SYS_YIELD, 0, 0, token);
        asm volatile ("pause");
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

// --- Input Event Dispatcher ---

fn handleInputEvent(evt: InputEventPayload, bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64) void {
    // 1. Modal Overlay Input Trapping
    if (help_modal.isOpen()) {
        const is_dismiss = (evt.key_code == .escape or
            evt.key_code == .enter or evt.ascii == '\n' or evt.ascii == '\r' or
            evt.key_code == .f1 or evt.ascii == '?' or evt.ascii == ' ' or
            evt.ascii == 'q' or evt.ascii == 'Q');
        if (is_dismiss) {
            help_modal.close();
            damage_tracker.addDamage(help_modal.rect);
            damage_tracker.addDamage(left_panel_rect);
            damage_tracker.addDamage(shell_panel_rect);
            damage_tracker.addDamage(right_panel_rect);
            damage_tracker.addDamage(console_panel_rect);
            damage_tracker.addDamage(bottom_bar_rect);
            needs_redraw = true;
        }
        // Exclusively trap all keyboard events while modal is visible
        return;
    }

    // 2. Help Modal Trigger ([F1] or '?' when not typing in text input)
    const in_text_input = (focused_pane == .vm_form and focused_form_field == .name) or
        (focused_pane == .varde_shell) or
        (focused_pane == .guest_console);
    if (evt.key_code == .f1 or (evt.ascii == '?' and !in_text_input)) {
        help_modal.open();
        damage_tracker.addDamage(help_modal.rect);
        needs_redraw = true;
        return;
    }

    // 3. Direct Function Key Pane Navigation & Console Switching
    if (evt.key_code == .f2) {
        if (focused_pane != .vm_form) {
            focused_pane = .vm_form;
            syncWidgetFocus();
            damage_tracker.addDamage(left_panel_rect);
            damage_tracker.addDamage(shell_panel_rect);
            damage_tracker.addDamage(right_panel_rect);
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
        }
        return;
    }
    if (evt.key_code == .f3) {
        if (focused_pane != .vm_manager) {
            focused_pane = .vm_manager;
            syncWidgetFocus();
            damage_tracker.addDamage(left_panel_rect);
            damage_tracker.addDamage(shell_panel_rect);
            damage_tracker.addDamage(right_panel_rect);
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
        }
        return;
    }
    if (evt.key_code == .f4) {
        if (focused_pane != .varde_shell) {
            focused_pane = .varde_shell;
            syncWidgetFocus();
            damage_tracker.addDamage(left_panel_rect);
            damage_tracker.addDamage(shell_panel_rect);
            damage_tracker.addDamage(right_panel_rect);
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
        }
        return;
    }
    if (evt.key_code == .f5) {
        needs_vm_refresh = true;
        setFormStatus("Refreshing VM & cluster telemetry...", color.COLOR_HIGHLIGHT);
        damage_tracker.addDamage(status_banner_rect);
        damage_tracker.addDamage(shell_panel_rect);
        damage_tracker.addDamage(right_panel_rect);
        damage_tracker.addDamage(console_panel_rect);
        damage_tracker.addDamage(header_rect);
        needs_redraw = true;
        return;
    }
    if (evt.key_code == .f6) {
        focused_pane = .guest_console;
        syncWidgetFocus();
        damage_tracker.addDamage(left_panel_rect);
        damage_tracker.addDamage(shell_panel_rect);
        damage_tracker.addDamage(right_panel_rect);
        damage_tracker.addDamage(console_panel_rect);
        needs_redraw = true;
        return;
    }
    if (evt.key_code == .f7) {
        cycleConsoleVm(-1);
        focused_pane = .guest_console;
        syncWidgetFocus();
        emitMilestoneConsoleSwitched(active_console_vm_id);
        damage_tracker.addDamage(left_panel_rect);
        damage_tracker.addDamage(shell_panel_rect);
        damage_tracker.addDamage(right_panel_rect);
        damage_tracker.addDamage(console_panel_rect);
        needs_redraw = true;
        return;
    }
    if (evt.key_code == .f8) {
        cycleConsoleVm(1);
        focused_pane = .guest_console;
        syncWidgetFocus();
        emitMilestoneConsoleSwitched(active_console_vm_id);
        damage_tracker.addDamage(left_panel_rect);
        damage_tracker.addDamage(shell_panel_rect);
        damage_tracker.addDamage(right_panel_rect);
        damage_tracker.addDamage(console_panel_rect);
        needs_redraw = true;
        return;
    }

    // 4. Tab / Shift+Tab Navigation
    const is_tab = (evt.key_code == .tab or evt.ascii == '\t');
    const is_shift = ((evt.modifiers & proto_inputd.MOD_SHIFT) != 0);

    if (is_tab) {
        if (focused_pane == .vm_form) {
            if (is_shift) {
                if (@backingInt(focused_form_field) > 0) {
                    focused_form_field = @fromBackingInt(@intCast(@backingInt(focused_form_field) - 1));
                } else {
                    focused_pane = .guest_console;
                }
            } else {
                if (@backingInt(focused_form_field) < 6) {
                    focused_form_field = @fromBackingInt(@intCast(@backingInt(focused_form_field) + 1));
                } else {
                    focused_pane = .vm_manager;
                }
            }
        } else if (focused_pane == .vm_manager) {
            if (is_shift) {
                focused_pane = .vm_form;
                focused_form_field = .reset_btn;
            } else {
                focused_pane = .varde_shell;
            }
        } else if (focused_pane == .varde_shell) {
            if (is_shift) {
                focused_pane = .vm_manager;
            } else {
                focused_pane = .guest_console;
            }
        } else {
            if (is_shift) {
                focused_pane = .varde_shell;
            } else {
                focused_pane = .vm_form;
                focused_form_field = .name;
            }
        }
        syncWidgetFocus();
        damage_tracker.addDamage(left_panel_rect);
        damage_tracker.addDamage(shell_panel_rect);
        damage_tracker.addDamage(right_panel_rect);
        damage_tracker.addDamage(console_panel_rect);
        needs_redraw = true;
        return;
    }

    // 5. Left Pane: MicroVM Provisioning Form
    if (focused_pane == .vm_form) {
        // Vertical field navigation via Up / Down arrow keys
        if (evt.key_code == .down) {
            focused_form_field = if (@backingInt(focused_form_field) < 6)
                @fromBackingInt(@intCast(@backingInt(focused_form_field) + 1))
            else
                .name;
            syncWidgetFocus();
            damage_tracker.addDamage(left_panel_rect);
            needs_redraw = true;
            return;
        }
        if (evt.key_code == .up) {
            focused_form_field = if (@backingInt(focused_form_field) > 0)
                @fromBackingInt(@intCast(@backingInt(focused_form_field) - 1))
            else
                .reset_btn;
            syncWidgetFocus();
            damage_tracker.addDamage(left_panel_rect);
            needs_redraw = true;
            return;
        }

        // Horizontal toggle between action buttons
        if (focused_form_field == .create_btn and evt.key_code == .right) {
            focused_form_field = .reset_btn;
            syncWidgetFocus();
            damage_tracker.addDamage(form_create_btn.rect);
            damage_tracker.addDamage(form_reset_btn.rect);
            needs_redraw = true;
            return;
        }
        if (focused_form_field == .reset_btn and evt.key_code == .left) {
            focused_form_field = .create_btn;
            syncWidgetFocus();
            damage_tracker.addDamage(form_create_btn.rect);
            damage_tracker.addDamage(form_reset_btn.rect);
            needs_redraw = true;
            return;
        }

        // Field 0: Name (TextInput)
        if (focused_form_field == .name) {
            if (evt.key_code == .enter or evt.ascii == '\n') {
                focused_form_field = .vcpus;
                syncWidgetFocus();
                damage_tracker.addDamage(form_name_input.rect);
                damage_tracker.addDamage(form_vcpu_spinner.rect);
                needs_redraw = true;
                return;
            }
            if (form_name_input.handleKey(evt)) {
                damage_tracker.addDamage(form_name_input.rect);
                needs_redraw = true;
                return;
            }
            return;
        }

        // Field 1: vCPUs (NumberSpinner)
        if (focused_form_field == .vcpus) {
            if (evt.key_code == .enter or evt.ascii == '\n') {
                focused_form_field = .memory;
                syncWidgetFocus();
                damage_tracker.addDamage(form_vcpu_spinner.rect);
                damage_tracker.addDamage(form_mem_select.rect);
                needs_redraw = true;
                return;
            }
            if (form_vcpu_spinner.handleKey(evt)) {
                damage_tracker.addDamage(form_vcpu_spinner.rect);
                needs_redraw = true;
                return;
            }
            return;
        }

        // Field 2: Memory (OptionSelect)
        if (focused_form_field == .memory) {
            if (evt.key_code == .enter or evt.ascii == '\n') {
                focused_form_field = .kernel;
                syncWidgetFocus();
                damage_tracker.addDamage(form_mem_select.rect);
                damage_tracker.addDamage(form_kernel_select.rect);
                needs_redraw = true;
                return;
            }
            if (form_mem_select.handleKey(evt)) {
                damage_tracker.addDamage(form_mem_select.rect);
                needs_redraw = true;
                return;
            }
            return;
        }

        // Field 3: Kernel (OptionSelect)
        if (focused_form_field == .kernel) {
            if (evt.key_code == .enter or evt.ascii == '\n') {
                focused_form_field = .rootfs;
                syncWidgetFocus();
                damage_tracker.addDamage(form_kernel_select.rect);
                damage_tracker.addDamage(form_rootfs_select.rect);
                needs_redraw = true;
                return;
            }
            if (form_kernel_select.handleKey(evt)) {
                damage_tracker.addDamage(form_kernel_select.rect);
                needs_redraw = true;
                return;
            }
            return;
        }

        // Field 4: Rootfs (OptionSelect)
        if (focused_form_field == .rootfs) {
            if (evt.key_code == .enter or evt.ascii == '\n') {
                focused_form_field = .create_btn;
                syncWidgetFocus();
                damage_tracker.addDamage(form_rootfs_select.rect);
                damage_tracker.addDamage(form_create_btn.rect);
                needs_redraw = true;
                return;
            }
            if (form_rootfs_select.handleKey(evt)) {
                damage_tracker.addDamage(form_rootfs_select.rect);
                needs_redraw = true;
                return;
            }
            return;
        }

        // Field 5: Action Button: < CREATE & LAUNCH >
        if (focused_form_field == .create_btn) {
            const is_action = form_create_btn.handleKey(evt) or
                evt.key_code == .enter or evt.ascii == '\n' or evt.ascii == ' ';
            if (is_action) {
                const name_text = form_name_input.getText();
                // Validation 1: Non-empty name
                if (name_text.len == 0) {
                    setFormStatus("[ERR] Name cannot be empty", color.COLOR_RED);
                    damage_tracker.addDamage(status_banner_rect);
                    needs_redraw = true;
                    return;
                }
                // Validation 2: Unique name
                for (microvm_list[0..microvm_count]) |vm| {
                    const vlen = lib.nameLen(&vm.name);
                    if (std.mem.eql(u8, vm.name[0..vlen], name_text)) {
                        setFormStatus("[ERR] Name already exists", color.COLOR_RED);
                        damage_tracker.addDamage(status_banner_rect);
                        needs_redraw = true;
                        return;
                    }
                }
                // This VMM currently implements one vCPU per VM.
                const vcpu_val = form_vcpu_spinner.getValue();
                if (vcpu_val != 1) {
                    setFormStatus("[ERR] Only one vCPU is supported", color.COLOR_RED);
                    damage_tracker.addDamage(status_banner_rect);
                    needs_redraw = true;
                    return;
                }

                // Inline Feedback: Status Green
                setFormStatus("[OK] Valid configuration", color.COLOR_GREEN);

                // Serial Milestone
                emitMilestoneProvisioned(name_text);

                // Dispatch create_microvm DIPC
                const mem_mb = MEM_VALUES[form_mem_select.getSelectedIndex()];
                const rootfs_choice = form_rootfs_select.getSelected();
                sendVmCreate(bs, dma_phys, token, name_text, vcpu_val, mem_mb, rootfs_choice);

                needs_vm_refresh = true;
                damage_tracker.addDamage(status_banner_rect);
                damage_tracker.addDamage(form_create_btn.rect);
                needs_redraw = true;
                return;
            }
            return;
        }

        // Field 6: Action Button: < RESET >
        if (focused_form_field == .reset_btn) {
            const is_action = form_reset_btn.handleKey(evt) or
                evt.key_code == .enter or evt.ascii == '\n' or evt.ascii == ' ';
            if (is_action) {
                form_name_input.setText("alpine-node-01");
                form_vcpu_spinner.setValue(1);
                form_mem_select.setSelectedIndex(1); // 32 MB
                form_kernel_select.setSelectedIndex(0);
                form_rootfs_select.setSelectedIndex(0);
                focused_form_field = .name;
                syncWidgetFocus();
                form_status_len = 0;
                damage_tracker.addDamage(left_panel_rect);
                needs_redraw = true;
                return;
            }
            return;
        }
        return;
    }

    // 6. Right Pane: VM Manager Sidebar & Inspector Card
    if (focused_pane == .vm_manager) {
        if (evt.key_code == .up) {
            if (vm_list_view.moveUp()) {
                selected_vm_idx = vm_list_view.getSelectedIndex();
                damage_tracker.addDamage(right_panel_rect);
                needs_redraw = true;
            }
            return;
        }
        if (evt.key_code == .down) {
            if (vm_list_view.moveDown()) {
                selected_vm_idx = vm_list_view.getSelectedIndex();
                damage_tracker.addDamage(right_panel_rect);
                needs_redraw = true;
            }
            return;
        }
        if (evt.key_code == .page_up) {
            if (vm_list_view.pageUp()) {
                selected_vm_idx = vm_list_view.getSelectedIndex();
                damage_tracker.addDamage(right_panel_rect);
                needs_redraw = true;
            }
            return;
        }
        if (evt.key_code == .page_down) {
            if (vm_list_view.pageDown()) {
                selected_vm_idx = vm_list_view.getSelectedIndex();
                damage_tracker.addDamage(right_panel_rect);
                needs_redraw = true;
            }
            return;
        }
        if (evt.key_code == .home) {
            if (vm_list_view.moveHome()) {
                selected_vm_idx = vm_list_view.getSelectedIndex();
                damage_tracker.addDamage(right_panel_rect);
                needs_redraw = true;
            }
            return;
        }
        if (evt.key_code == .end) {
            if (vm_list_view.moveEnd()) {
                selected_vm_idx = vm_list_view.getSelectedIndex();
                damage_tracker.addDamage(right_panel_rect);
                needs_redraw = true;
            }
            return;
        }

        // Hotkey: [C] -> Jump to Selected MicroVM Console
        if (evt.ascii == 'c' or evt.ascii == 'C') {
            if (microvm_count > 0 and selected_vm_idx < microvm_count) {
                const vm = microvm_list[selected_vm_idx];
                active_console_vm_id = vm.id;
            }
            console_scroll_offset = 0;
            console_auto_scroll = true;
            focused_pane = .guest_console;
            syncWidgetFocus();
            emitMilestoneConsoleSwitched(active_console_vm_id);
            damage_tracker.addDamage(right_panel_rect);
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
            return;
        }

        // Hotkey: [S] / Enter -> Start MicroVM (or jump to console if Enter on Running VM)
        if (evt.ascii == 's' or evt.ascii == 'S' or evt.key_code == .enter) {
            if (microvm_count > 0 and selected_vm_idx < microvm_count) {
                const vm = microvm_list[selected_vm_idx];
                if (evt.key_code == .enter and vm.state == 2) {
                    active_console_vm_id = vm.id;
                    console_scroll_offset = 0;
                    console_auto_scroll = true;
                    focused_pane = .guest_console;
                    syncWidgetFocus();
                    emitMilestoneConsoleSwitched(active_console_vm_id);
                    damage_tracker.addDamage(right_panel_rect);
                    damage_tracker.addDamage(console_panel_rect);
                    needs_redraw = true;
                    return;
                }
                sendVmStart(bs, dma_phys, token, vm.id);
                emitMilestoneStarted(vm.id);
                var status_msg: [48]u8 = undefined;
                var sp: usize = 0;
                appendStr(&status_msg, &sp, "Starting MicroVM #");
                appendDec(&status_msg, &sp, vm.id);
                appendStr(&status_msg, &sp, "...");
                setFormStatus(status_msg[0..sp], color.COLOR_GOLDEN_YELLOW);
                needs_vm_refresh = true;
                damage_tracker.addDamage(right_panel_rect);
                damage_tracker.addDamage(status_banner_rect);
                needs_redraw = true;
            }
            return;
        }

        // Hotkey: [K] -> Stop / Kill MicroVM
        if (evt.ascii == 'k' or evt.ascii == 'K') {
            if (microvm_count > 0 and selected_vm_idx < microvm_count) {
                const vm = microvm_list[selected_vm_idx];
                sendVmStop(bs, dma_phys, token, vm.id);
                emitMilestoneStopped(vm.id);
                var status_msg: [48]u8 = undefined;
                var sp: usize = 0;
                appendStr(&status_msg, &sp, "Stopping MicroVM #");
                appendDec(&status_msg, &sp, vm.id);
                appendStr(&status_msg, &sp, "...");
                setFormStatus(status_msg[0..sp], color.COLOR_GOLDEN_YELLOW);
                needs_vm_refresh = true;
                damage_tracker.addDamage(right_panel_rect);
                damage_tracker.addDamage(status_banner_rect);
                needs_redraw = true;
            }
            return;
        }

        // Hotkey: [D] -> Delete MicroVM
        if (evt.ascii == 'd' or evt.ascii == 'D') {
            if (microvm_count > 0 and selected_vm_idx < microvm_count) {
                const vm = microvm_list[selected_vm_idx];
                sendVmDelete(bs, dma_phys, token, vm.id);
                emitMilestoneDeleted(vm.id);
                var status_msg: [48]u8 = undefined;
                var sp: usize = 0;
                appendStr(&status_msg, &sp, "Deleted MicroVM #");
                appendDec(&status_msg, &sp, vm.id);
                appendStr(&status_msg, &sp, ".");
                setFormStatus(status_msg[0..sp], color.COLOR_RED);
                needs_vm_refresh = true;
                damage_tracker.addDamage(right_panel_rect);
                damage_tracker.addDamage(status_banner_rect);
                needs_redraw = true;
            }
            return;
        }
        return;
    }

    // 7. Bottom-Left Pane: Varde Shell Line Editor, History & Scrollback
    if (focused_pane == .varde_shell) {
        if (evt.key_code == .page_up) {
            shell_scroll_offset += 6;
            shell_auto_scroll = false;
            damage_tracker.addDamage(shell_panel_rect);
            needs_redraw = true;
            return;
        }
        if (evt.key_code == .page_down) {
            if (shell_scroll_offset > 6) {
                shell_scroll_offset -= 6;
            } else {
                shell_scroll_offset = 0;
                shell_auto_scroll = true;
            }
            damage_tracker.addDamage(shell_panel_rect);
            needs_redraw = true;
            return;
        }
        if (evt.key_code == .up) {
            if (shell_history.recallUp(shell_input.getText(), shell_input.cursor_pos)) |res| {
                shell_input.setText(res.text);
                shell_input.cursor_pos = @min(res.cursor, shell_input.len);
                damage_tracker.addDamage(shell_prompt_rect);
                needs_redraw = true;
            }
            return;
        }
        if (evt.key_code == .down) {
            if (shell_history.recallDown()) |res| {
                shell_input.setText(res.text);
                shell_input.cursor_pos = @min(res.cursor, shell_input.len);
                damage_tracker.addDamage(shell_prompt_rect);
                needs_redraw = true;
            }
            return;
        }
        if (evt.key_code == .enter or evt.ascii == '\n' or evt.ascii == '\r') {
            const cmd = shell_input.getText();
            shell_history.push(cmd);
            switch (parseNetworkBindCommand(cmd)) {
                .unrelated => {
                    for (cmd) |ch| {
                        _ = lib.syscall(SYS_VARDE_INJECT, @as(u64, ch), 0, token);
                    }
                    _ = lib.syscall(SYS_VARDE_INJECT, '\n', 0, token);
                },
                .invalid => setNetworkStatus("Invalid vNIC binding command", color.COLOR_RED),
                .binding => |binding| startNetworkBind(binding, dma_phys, token),
            }
            shell_input.clear();
            shell_scroll_offset = 0;
            shell_auto_scroll = true;
            needs_vm_refresh = true;
            damage_tracker.addDamage(shell_panel_rect);
            needs_redraw = true;
            return;
        }
        if (shell_input.handleKey(evt)) {
            damage_tracker.addDamage(shell_prompt_rect);
            needs_redraw = true;
            return;
        }
        return;
    }

    // 8. Bottom-Right Pane: Live Guest Serial Console (ttyS0)
    if (focused_pane == .guest_console) {
        if (evt.key_code == .page_up) {
            console_scroll_offset += 6;
            console_auto_scroll = false;
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
            return;
        }
        if (evt.key_code == .page_down) {
            if (console_scroll_offset > 6) {
                console_scroll_offset -= 6;
            } else {
                console_scroll_offset = 0;
                console_auto_scroll = true;
            }
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
            return;
        }
        if (evt.key_code == .enter or evt.ascii == '\n' or evt.ascii == '\r') {
            _ = lib.injectVmConsole(active_console_vm_id, '\n', token);
            last_injected_char = '\n';
            console_scroll_offset = 0;
            console_auto_scroll = true;
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
            return;
        }
        if (evt.key_code == .backspace or evt.ascii == 8 or evt.ascii == 0x7F) {
            _ = lib.injectVmConsole(active_console_vm_id, 0x08, token);
            last_injected_char = 0x08;
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
            return;
        }
        if (evt.ascii > 0) {
            _ = lib.injectVmConsole(active_console_vm_id, evt.ascii, token);
            last_injected_char = evt.ascii;
            console_scroll_offset = 0;
            console_auto_scroll = true;
            damage_tracker.addDamage(console_panel_rect);
            needs_redraw = true;
            return;
        }
    }
}

// --- Inbound DIPC Message Dispatcher ---

fn handleMessage(page_va: u64, bs: *const lib.BootstrapDescriptor, dma_phys: u64, token: u64) void {
    const hdr: *const lib.PageHeader = lib.ptrFrom(*const lib.PageHeader, page_va);
    const payload_va = page_va + @as(u64, hdr.header_len);

    if (hdr.src.endpoint == @backingInt(lib.ReservedEndpoint.inputd) and
        hdr.payload_len >= @sizeOf(InputEventPayload))
    {
        const evt: *align(1) const InputEventPayload = @ptrFromInt(payload_va);
        lib.serialWrite("windowd: input event received\n");
        handleInputEvent(evt.*, bs, dma_phys, token);
        return;
    }

    if (hdr.src.endpoint == @backingInt(lib.ReservedEndpoint.dashd) and
        hdr.payload_len == @sizeOf(proto_dashd.DashdHeader) + @sizeOf(proto_dashd.TelemetrySummaryReply))
    {
        const dh: *align(1) const proto_dashd.DashdHeader = @ptrFromInt(payload_va);
        if (dh.magic == proto_dashd.MAGIC and dh.op == .telemetry_summary_reply) {
            handleClusterSummary(payload_va);
            damage_tracker.addDamage(header_rect);
            damage_tracker.addDamage(right_panel_rect);
            needs_redraw = true;
        }
        return;
    }

    if (hdr.src.endpoint == @backingInt(lib.ReservedEndpoint.configd) and
        hdr.payload_len >= @sizeOf(proto_configd.ConfigdHeader))
    {
        handleNetworkBindReply(hdr, payload_va, dma_phys, token);
        return;
    }

    if (hdr.src.endpoint == @backingInt(lib.ReservedEndpoint.kernel_control) and
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
            microvm_list[i].vcpus = snap.entries[i].vcpus;
            microvm_list[i].mem_pages = snap.entries[i].mem_pages;
            microvm_list[i].cpu_cycles = snap.entries[i].cpu_cycles;
            microvm_list[i].exit_count = snap.entries[i].exit_count;
        }
        if (selected_vm_idx >= microvm_count and microvm_count > 0) {
            selected_vm_idx = microvm_count - 1;
        }
        vm_list_view.setItemCount(microvm_count);
        vm_list_view.setSelectedIndex(selected_vm_idx);
        damage_tracker.addDamage(right_panel_rect);
        needs_redraw = true;
        return;
    }

    if (hdr.src.endpoint == @backingInt(lib.ReservedEndpoint.kernel_control) and
        hdr.payload_len == @sizeOf(lib.CreateMicrovmResult))
    {
        const res: *align(1) const lib.CreateMicrovmResult = @ptrFromInt(payload_va);
        if (res.status == .ok and res.instance_id != 0) {
            var msg: [48]u8 = undefined;
            var p: usize = 0;
            appendStr(&msg, &p, "Created & started MicroVM #");
            appendDec(&msg, &p, res.instance_id);
            setFormStatus(msg[0..p], color.COLOR_GREEN);
        } else {
            setFormStatus("MicroVM creation failed (registry full).", color.COLOR_RED);
        }
        needs_vm_refresh = true;
        damage_tracker.addDamage(status_banner_rect);
        needs_redraw = true;
        return;
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
            if (r.used and std.mem.eql(u8, &r.addr, &e.node_addr)) {
                row = r;
                break;
            }
        }
        if (row == null) {
            for (&node_rows) |*r| {
                if (!r.used) {
                    r.used = true;
                    r.addr = e.node_addr;
                    row = r;
                    break;
                }
            }
        }
        if (row) |r| {
            r.vms += 1;
            r.cycles +%= e.cpu_cycles;
            r.exits +%= e.exit_count;
        }
    }
}

// --- Zero-Allocation String Formatting Helpers ---

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

// --- Flicker-Free Rendering Routine ---

fn drawTui(dma_phys: u64, token: u64) void {
    if (!damage_tracker.hasDamage()) return;

    const text_phys = dma_phys + DMA_TEXT_SLOT * lib.PAGE_SIZE;
    const text_va = DMA_BASE_VA + DMA_TEXT_SLOT * lib.PAGE_SIZE;
    const surface = Surface{
        .token = token,
        .dma_phys = text_phys,
        .dma_va = text_va,
    };

    if (damage_tracker.is_all_dirty) {
        surface.fillRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, color.COLOR_SEA_GRAY);
        drawHeader(surface);
        drawLeftPane(surface);
        drawShellPane(surface, dma_phys, token);
        drawRightPane(surface);
        drawGuestConsolePane(surface, dma_phys, token);
        drawBottomBar(surface);
        if (help_modal.isOpen()) {
            drawHelpModal(surface);
        }
        damage_tracker.clear();
        return;
    }

    // Surgical damage region repaints
    if (damage_tracker.isDirty(header_rect)) {
        drawHeader(surface);
    }
    if (damage_tracker.isDirty(left_panel_rect)) {
        drawLeftPane(surface);
    }
    if (damage_tracker.isDirty(shell_panel_rect)) {
        // Check if only the prompt row is dirty vs the full shell panel
        const log_area = Rect.init(shell_panel_rect.x, shell_panel_rect.y, shell_panel_rect.w, shell_panel_rect.h - 32);
        if (damage_tracker.isDirty(log_area)) {
            drawShellPane(surface, dma_phys, token);
        } else if (damage_tracker.isDirty(shell_prompt_rect)) {
            drawShellPrompt(surface);
        } else {
            drawShellPane(surface, dma_phys, token);
        }
    }
    if (damage_tracker.isDirty(right_panel_rect)) {
        drawRightPane(surface);
    }
    if (damage_tracker.isDirty(console_panel_rect)) {
        drawGuestConsolePane(surface, dma_phys, token);
    }
    if (damage_tracker.isDirty(bottom_bar_rect)) {
        drawBottomBar(surface);
    }
    if (help_modal.isOpen() and damage_tracker.isDirty(help_modal.rect)) {
        drawHelpModal(surface);
    }

    damage_tracker.clear();
}

fn drawHeader(surface: Surface) void {
    surface.fillRect(0, 0, SCREEN_WIDTH, 20, color.COLOR_TERRACOTTA);
    surface.drawText(0, 1, color.COLOR_WHITE, color.COLOR_TERRACOTTA, "[C] CATENARY OS");

    // Gauges
    var total_vms: u32 = 0;
    for (&node_rows) |*r| if (r.used) {
        total_vms += r.vms;
    };
    if (total_vms < @as(u32, @intCast(microvm_count))) total_vms = @as(u32, @intCast(microvm_count));

    // CPU gauge
    const cpu_bars = @min(@as(usize, total_vms) * 2 + 3, 10);
    var cpu_gauge: [32]u8 = undefined;
    var gp: usize = 0;
    appendStr(&cpu_gauge, &gp, "CPU: [");
    var b_idx: usize = 0;
    while (b_idx < 10) : (b_idx += 1) {
        appendStr(&cpu_gauge, &gp, if (b_idx < cpu_bars) "|" else ".");
    }
    appendStr(&cpu_gauge, &gp, "] ");
    appendDec(&cpu_gauge, &gp, @as(u64, cpu_bars) * 10);
    appendStr(&cpu_gauge, &gp, "%");
    surface.drawText(0, 22, color.COLOR_GOLDEN_YELLOW, color.COLOR_TERRACOTTA, cpu_gauge[0..gp]);

    // RAM gauge
    const mem_bars = @min(@as(usize, total_vms) * 2 + 2, 10);
    var mem_gauge: [32]u8 = undefined;
    var mp: usize = 0;
    appendStr(&mem_gauge, &mp, "RAM: [");
    b_idx = 0;
    while (b_idx < 10) : (b_idx += 1) {
        appendStr(&mem_gauge, &mp, if (b_idx < mem_bars) "|" else ".");
    }
    appendStr(&mem_gauge, &mp, "] ");
    appendDec(&mem_gauge, &mp, @as(u64, mem_bars) * 10);
    appendStr(&mem_gauge, &mp, "%");
    surface.drawText(0, 48, color.COLOR_HIGHLIGHT, color.COLOR_TERRACOTTA, mem_gauge[0..mp]);

    // SMP & Network info
    surface.drawText(0, 72, color.COLOR_WHITE, color.COLOR_TERRACOTTA, "SMP: 2 Cores | IPv6 Ready");
}

fn drawLeftPane(surface: Surface) void {
    left_panel.render(surface);

    const is_form = (focused_pane == .vm_form);

    // Field 0: Name
    surface.drawText(6, 3, if (is_form and focused_form_field == .name) color.COLOR_GOLDEN_YELLOW else color.COLOR_WHITE, color.COLOR_PANEL_BG, "VM Name   :");
    form_name_input.render(surface);

    // Field 1: vCPUs
    surface.drawText(9, 3, if (is_form and focused_form_field == .vcpus) color.COLOR_GOLDEN_YELLOW else color.COLOR_WHITE, color.COLOR_PANEL_BG, "vCPUs     :");
    form_vcpu_spinner.render(surface);

    // Field 2: Memory
    surface.drawText(12, 3, if (is_form and focused_form_field == .memory) color.COLOR_GOLDEN_YELLOW else color.COLOR_WHITE, color.COLOR_PANEL_BG, "Memory    :");
    form_mem_select.render(surface);

    // Field 3: Kernel
    surface.drawText(15, 3, if (is_form and focused_form_field == .kernel) color.COLOR_GOLDEN_YELLOW else color.COLOR_WHITE, color.COLOR_PANEL_BG, "Kernel    :");
    form_kernel_select.render(surface);

    // Field 4: Rootfs
    surface.drawText(18, 3, if (is_form and focused_form_field == .rootfs) color.COLOR_GOLDEN_YELLOW else color.COLOR_WHITE, color.COLOR_PANEL_BG, "Rootfs    :");
    form_rootfs_select.render(surface);

    // Action buttons
    form_create_btn.render(surface);
    form_reset_btn.render(surface);

    // Status Banner
    surface.fillRect(status_banner_rect.x, status_banner_rect.y, status_banner_rect.w, status_banner_rect.h, color.COLOR_PANEL_BG);
    if (form_status_len > 0) {
        surface.drawText(27, 3, form_status_color, color.COLOR_PANEL_BG, form_status_buf[0..form_status_len]);
    }

    // Compact Form Hints
    surface.drawText(31, 3, color.COLOR_GOLDEN_YELLOW, color.COLOR_PANEL_BG, "Hints: [Tab]/[Up]/[Down] Field | [Left]/[Right] Step");
    surface.drawText(33, 3, color.COLOR_WHITE, color.COLOR_PANEL_BG, "[F2] Form  [F3] VMs  [F4] Shell  [F1] Help");
}

fn drawShellPrompt(surface: Surface) void {
    surface.fillRect(shell_prompt_rect.x, shell_prompt_rect.y, shell_prompt_rect.w, shell_prompt_rect.h, color.COLOR_INPUT_BG);
    const prompt_row: u32 = shell_prompt_rect.y / 8;
    const is_shell = (focused_pane == .varde_shell);
    const prompt_fg = if (is_shell) color.COLOR_GOLDEN_YELLOW else color.COLOR_DIM;
    surface.drawText(prompt_row, 2, prompt_fg, color.COLOR_INPUT_BG, "catenary> ");

    const text = shell_input.getText();
    const max_vis: usize = 34;
    const start = shellInputViewStart(shell_input.cursor_pos, max_vis);
    const vis_len = @min(text.len - start, max_vis);
    if (vis_len > 0) {
        surface.drawText(prompt_row, 12, color.COLOR_WHITE, color.COLOR_INPUT_BG, text[start .. start + vis_len]);
    }
    if (is_shell) {
        const cur_col: u32 = 12 + @as(u32, @intCast(shell_input.cursor_pos - start));
        if (shell_input.cursor_pos < start + vis_len) {
            const ch_slice = text[shell_input.cursor_pos .. shell_input.cursor_pos + 1];
            surface.drawText(prompt_row, cur_col, color.COLOR_INPUT_BG, color.COLOR_HIGHLIGHT, ch_slice);
        } else {
            surface.drawText(prompt_row, cur_col, color.COLOR_HIGHLIGHT, color.COLOR_INPUT_BG, "_");
        }
    }
}

fn shellInputViewStart(cursor: usize, max_visible: usize) usize {
    return if (cursor > max_visible) cursor - max_visible else 0;
}

fn drawShellPane(surface: Surface, dma_phys: u64, token: u64) void {
    shell_panel.render(surface);

    const log_phys = dma_phys + DMA_LOG_SLOT * lib.PAGE_SIZE;
    const log_va = DMA_BASE_VA + DMA_LOG_SLOT * lib.PAGE_SIZE;
    const log_len = @min(@as(usize, @intCast(lib.syscall(SYS_GET_VARDE_LOG, log_phys, 0, token))), 4095);
    last_seen_shell_len = log_len;
    const log_ptr = lib.ptrFrom([*]const u8, log_va);

    const base_row: u32 = 42;
    const max_rows: u32 = if (network_status_len > 0) 23 else 24;
    const max_cols: usize = 46;

    // Parse lines from kernel varde_shell log
    var line_offsets: [128]usize = undefined;
    var line_lens: [128]usize = undefined;
    var total_lines: usize = 0;

    var cur_start: usize = 0;
    var idx: usize = 0;
    while (idx <= log_len) : (idx += 1) {
        const is_end = (idx == log_len);
        const c = if (is_end) @as(u8, 0) else log_ptr[idx];
        if (is_end or c == 0 or c == '\n') {
            if (!is_end or idx > cur_start) {
                if (total_lines < line_offsets.len) {
                    line_offsets[total_lines] = cur_start;
                    line_lens[total_lines] = idx - cur_start;
                    total_lines += 1;
                } else {
                    var s: usize = 0;
                    while (s + 1 < line_offsets.len) : (s += 1) {
                        line_offsets[s] = line_offsets[s + 1];
                        line_lens[s] = line_lens[s + 1];
                    }
                    line_offsets[line_offsets.len - 1] = cur_start;
                    line_lens[line_offsets.len - 1] = idx - cur_start;
                }
            }
            cur_start = idx + 1;
            if (is_end or c == 0) break;
        }
    }

    if (total_lines <= max_rows) {
        shell_scroll_offset = 0;
    } else {
        const max_scroll = total_lines - max_rows;
        if (shell_scroll_offset > max_scroll) {
            shell_scroll_offset = max_scroll;
        }
    }

    if (shell_scroll_offset > 0) {
        var scroll_badge: [32]u8 = undefined;
        var sp: usize = 0;
        appendStr(&scroll_badge, &sp, "[SCROLLED -");
        appendDec(&scroll_badge, &sp, shell_scroll_offset);
        appendStr(&scroll_badge, &sp, "L]");
        const badge_bg = if (focused_pane == .varde_shell) color.COLOR_HIGHLIGHT else color.COLOR_TERRACOTTA;
        const badge_fg = if (focused_pane == .varde_shell) color.COLOR_INPUT_BG else color.COLOR_GOLDEN_YELLOW;
        surface.drawText(39, 34, badge_fg, badge_bg, scroll_badge[0..sp]);
    }

    const lines_to_show = @min(total_lines, max_rows);
    const start_show = if (total_lines > lines_to_show) (total_lines - lines_to_show - shell_scroll_offset) else 0;

    var r: u32 = 0;
    while (r < lines_to_show) : (r += 1) {
        const l_idx = start_show + r;
        if (l_idx >= total_lines) break;
        const off = line_offsets[l_idx];
        const len = @min(line_lens[l_idx], max_cols);
        if (len > 0) {
            const line_slice = log_ptr[off .. off + len];
            const is_prompt = std.mem.startsWith(u8, line_slice, "catenary> ");
            const fg = if (is_prompt) color.COLOR_GOLDEN_YELLOW else color.COLOR_WHITE;
            surface.drawText(base_row + r, 2, fg, color.COLOR_PANEL_BG, line_slice);
        }
    }

    if (network_status_len > 0) {
        surface.drawText(base_row + 23, 2, network_status_color, color.COLOR_PANEL_BG, network_status_buf[0..network_status_len]);
    }
    drawShellPrompt(surface);
}

fn drawRightPane(surface: Surface) void {
    right_panel.render(surface);

    // ListView Header
    surface.drawText(5, 52, color.COLOR_GOLDEN_YELLOW, color.COLOR_PANEL_BG, "Sel  Name          State       ID    vCPU");

    // MicroVM list rows
    if (microvm_count == 0) {
        surface.drawText(7, 54, color.COLOR_DIM, color.COLOR_PANEL_BG, "(No MicroVMs discovered)");
    } else {
        const top = vm_list_view.top_idx;
        const visible_end = @min(microvm_count, top + vm_list_view.visible_rows);
        var i = top;
        while (i < visible_end) : (i += 1) {
            const row: u32 = 7 + @as(u32, @intCast(i - top)) * 2;
            const is_selected = (i == selected_vm_idx);

            var line: [32]u8 = undefined;
            var p: usize = 0;
            appendStr(&line, &p, if (is_selected) "> " else "  ");
            const vname_len = lib.nameLen(&microvm_list[i].name);
            const disp_len = @min(vname_len, 12);
            appendStr(&line, &p, microvm_list[i].name[0..disp_len]);
            while (p < 16) : (p += 1) line[p] = ' ';

            const fg_color = if (is_selected and focused_pane == .vm_manager)
                color.COLOR_GOLDEN_YELLOW
            else if (is_selected)
                color.COLOR_HIGHLIGHT
            else
                color.COLOR_WHITE;
            surface.drawText(row, 52, fg_color, color.COLOR_PANEL_BG, line[0..p]);

            // State badges
            const state_badge = switch (microvm_list[i].state) {
                2 => "[RUNNING]",
                3 => "[STOPPED]",
                1 => "[CREATED]",
                else => "[UNKNOWN]",
            };
            const state_color = switch (microvm_list[i].state) {
                2 => color.COLOR_GREEN,
                3 => color.COLOR_RED,
                1 => color.COLOR_GOLDEN_YELLOW,
                else => color.COLOR_DIM,
            };
            surface.drawText(row, 69, state_color, color.COLOR_PANEL_BG, state_badge);

            // ID
            var id_buf: [12]u8 = undefined;
            var ip: usize = 0;
            appendStr(&id_buf, &ip, "#");
            appendDec(&id_buf, &ip, microvm_list[i].id);
            surface.drawText(row, 81, color.COLOR_HIGHLIGHT, color.COLOR_PANEL_BG, id_buf[0..ip]);

            // vCPUs
            var vcpu_buf: [12]u8 = undefined;
            var vp: usize = 0;
            appendDec(&vcpu_buf, &vp, microvm_list[i].vcpus);
            appendStr(&vcpu_buf, &vp, " vCPU");
            surface.drawText(row, 88, color.COLOR_WHITE, color.COLOR_PANEL_BG, vcpu_buf[0..vp]);
        }
    }

    // Lifecycle Controls Hint Bar
    surface.drawText(16, 52, color.COLOR_GOLDEN_YELLOW, color.COLOR_PANEL_BG, "[S]tart [K]ill [D]el [C]onsole [F5]Refresh");

    // Compact Telemetry & Cluster Inspector Card
    surface.fillRect(412, 144, 376, 168, color.COLOR_INPUT_BG);
    surface.drawText(19, 53, color.COLOR_GOLDEN_YELLOW, color.COLOR_INPUT_BG, "--- Selected MicroVM & Cluster Telemetry ---");

    if (microvm_count == 0) {
        surface.drawText(21, 55, color.COLOR_DIM, color.COLOR_INPUT_BG, "No MicroVM selected.");
    } else if (selected_vm_idx < microvm_count) {
        const sel = microvm_list[selected_vm_idx];

        // ID & Name & State
        var id_line: [48]u8 = undefined;
        var p: usize = 0;
        appendStr(&id_line, &p, "VM #");
        appendDec(&id_line, &p, sel.id);
        appendStr(&id_line, &p, " (");
        const nlen = @min(lib.nameLen(&sel.name), 12);
        appendStr(&id_line, &p, sel.name[0..nlen]);
        appendStr(&id_line, &p, ")  Core: ");
        appendDec(&id_line, &p, (sel.id -| 1) % 2);
        surface.drawText(21, 53, color.COLOR_HIGHLIGHT, color.COLOR_INPUT_BG, id_line[0..p]);

        const state_badge = switch (sel.state) {
            2 => "[RUNNING]",
            3 => "[STOPPED]",
            1 => "[CREATED]",
            else => "[UNKNOWN]",
        };
        const state_color = switch (sel.state) {
            2 => color.COLOR_GREEN,
            3 => color.COLOR_RED,
            1 => color.COLOR_GOLDEN_YELLOW,
            else => color.COLOR_DIM,
        };
        surface.drawText(21, 86, state_color, color.COLOR_INPUT_BG, state_badge);

        // vCPUs & RAM
        var res_line: [48]u8 = undefined;
        p = 0;
        appendStr(&res_line, &p, "vCPUs: ");
        appendDec(&res_line, &p, sel.vcpus);
        appendStr(&res_line, &p, "  |  RAM: ");
        appendDec(&res_line, &p, sel.mem_pages / 256);
        appendStr(&res_line, &p, " MB (");
        appendDec(&res_line, &p, sel.mem_pages);
        appendStr(&res_line, &p, " pgs)");
        surface.drawText(23, 53, color.COLOR_WHITE, color.COLOR_INPUT_BG, res_line[0..p]);

        // Host Cycles & VM-Exits
        var cyc_line: [48]u8 = undefined;
        p = 0;
        appendStr(&cyc_line, &p, "Cycles: ");
        appendDec(&cyc_line, &p, sel.cpu_cycles);
        appendStr(&cyc_line, &p, " | Exits: ");
        appendDec(&cyc_line, &p, sel.exit_count);
        surface.drawText(25, 53, color.COLOR_GOLDEN_YELLOW, color.COLOR_INPUT_BG, cyc_line[0..p]);
    }

    // Cluster Status inside Inspector
    surface.drawText(28, 53, color.COLOR_GOLDEN_YELLOW, color.COLOR_INPUT_BG, "Cluster Nodes:");
    var shown: u32 = 0;
    for (&node_rows) |*r| {
        if (!r.used or shown >= 3) continue;
        var line: [64]u8 = undefined;
        var p: usize = 0;
        var is_local = true;
        for (r.addr) |b| if (b != 0) {
            is_local = false;
            break;
        };

        if (is_local) {
            appendStr(&line, &p, "* local-node (Active) | VMs: ");
        } else {
            appendStr(&line, &p, "* node-peer (");
            for (r.addr[12..16]) |b| appendHexByte(&line, &p, b);
            appendStr(&line, &p, ")  | VMs: ");
        }
        appendDec(&line, &p, r.vms);
        appendStr(&line, &p, " | Exits: ");
        appendDec(&line, &p, r.exits);

        surface.drawText(30 + shown * 2, 53, color.COLOR_GREEN, color.COLOR_INPUT_BG, "*");
        surface.drawText(30 + shown * 2, 55, color.COLOR_HIGHLIGHT, color.COLOR_INPUT_BG, line[2..p]);
        shown += 1;
    }
    if (shown == 0) {
        surface.drawText(30, 53, color.COLOR_DIM, color.COLOR_INPUT_BG, "Awaiting node telemetry from dashd...");
    }
    surface.drawText(36, 53, color.COLOR_DIM, color.COLOR_INPUT_BG, "Virtio-Net NDP Active | SMP Multi-VM Ready");
}

fn drawGuestConsolePane(surface: Surface, dma_phys: u64, token: u64) void {
    console_panel.render(surface);

    // Header Selector Bar inside Console Pane
    var sel_line: [48]u8 = undefined;
    var sp: usize = 0;
    appendStr(&sel_line, &sp, "Target: [MicroVM #");
    appendDec(&sel_line, &sp, active_console_vm_id);
    appendStr(&sel_line, &sp, "]  |  [F7] Prev  [F8] Next");
    surface.drawText(43, 52, color.COLOR_GOLDEN_YELLOW, color.COLOR_PANEL_BG, sel_line[0..sp]);

    const console_phys = dma_phys + DMA_CONSOLE_SLOT * lib.PAGE_SIZE;
    const console_va = DMA_BASE_VA + DMA_CONSOLE_SLOT * lib.PAGE_SIZE;
    const log_len = @min(lib.getVmConsoleLog(console_phys, active_console_vm_id, token), 4095);
    last_seen_console_len = log_len;
    last_seen_console_vm_id = active_console_vm_id;
    const log_ptr = lib.ptrFrom([*]const u8, console_va);

    const base_row: u32 = 45;
    const max_rows: u32 = 22;
    const max_cols: usize = 46;

    // Parse lines from virtual 16550 UART circular buffer
    var line_offsets: [128]usize = undefined;
    var line_lens: [128]usize = undefined;
    var total_lines: usize = 0;

    var cur_start: usize = 0;
    var idx: usize = 0;
    while (idx <= log_len) : (idx += 1) {
        const is_end = (idx == log_len);
        const c = if (is_end) @as(u8, 0) else log_ptr[idx];
        const cur_len = idx - cur_start;
        if (is_end or c == 0 or c == '\n' or cur_len >= max_cols) {
            if (!is_end or idx > cur_start) {
                var clean_len = cur_len;
                if (clean_len > 0 and log_ptr[cur_start + clean_len - 1] == '\r') {
                    clean_len -= 1;
                }
                if (total_lines < line_offsets.len) {
                    line_offsets[total_lines] = cur_start;
                    line_lens[total_lines] = clean_len;
                    total_lines += 1;
                } else {
                    var s: usize = 0;
                    while (s + 1 < line_offsets.len) : (s += 1) {
                        line_offsets[s] = line_offsets[s + 1];
                        line_lens[s] = line_lens[s + 1];
                    }
                    line_offsets[line_offsets.len - 1] = cur_start;
                    line_lens[line_offsets.len - 1] = clean_len;
                }
            }
            cur_start = if (c == '\n' or is_end or c == 0) idx + 1 else idx;
            if (is_end or c == 0) break;
        }
    }

    if (total_lines <= max_rows) {
        console_scroll_offset = 0;
    } else {
        const max_scroll = total_lines - max_rows;
        if (console_scroll_offset > max_scroll) {
            console_scroll_offset = max_scroll;
        }
    }

    if (console_scroll_offset > 0) {
        var scroll_badge: [32]u8 = undefined;
        var bp: usize = 0;
        appendStr(&scroll_badge, &bp, "[SCROLLED -");
        appendDec(&scroll_badge, &bp, console_scroll_offset);
        appendStr(&scroll_badge, &bp, "L]");
        const badge_bg = if (focused_pane == .guest_console) color.COLOR_HIGHLIGHT else color.COLOR_TERRACOTTA;
        const badge_fg = if (focused_pane == .guest_console) color.COLOR_INPUT_BG else color.COLOR_GOLDEN_YELLOW;
        surface.drawText(41, 84, badge_fg, badge_bg, scroll_badge[0..bp]);
    }

    if (total_lines == 0) {
        surface.drawText(base_row + 2, 54, color.COLOR_DIM, color.COLOR_PANEL_BG, "(Awaiting ttyS0 output from MicroVM...)");
    } else {
        const lines_to_show = @min(total_lines, max_rows);
        const start_show = if (total_lines > lines_to_show) (total_lines - lines_to_show - console_scroll_offset) else 0;

        var r: u32 = 0;
        while (r < lines_to_show) : (r += 1) {
            const l_idx = start_show + r;
            if (l_idx >= total_lines) break;
            const off = line_offsets[l_idx];
            const len = @min(line_lens[l_idx], max_cols);
            if (len > 0) {
                const line_slice = log_ptr[off .. off + len];
                const is_init = std.mem.indexOf(u8, line_slice, "SUCCESS") != null or
                    std.mem.indexOf(u8, line_slice, "guest_rootfs") != null;
                const fg = if (is_init) color.COLOR_GREEN else color.COLOR_WHITE;
                surface.drawText(base_row + r, 52, fg, color.COLOR_PANEL_BG, line_slice);
            }
        }
    }

    // Bottom Interactive Input Status Bar inside Console Pane
    surface.fillRect(416, 552, 368, 16, color.COLOR_INPUT_BG);
    const is_console = (focused_pane == .guest_console);
    const bar_fg = if (is_console) color.COLOR_GOLDEN_YELLOW else color.COLOR_DIM;
    var prompt_buf: [48]u8 = undefined;
    var pp: usize = 0;
    appendStr(&prompt_buf, &pp, "ttyS0#");
    appendDec(&prompt_buf, &pp, active_console_vm_id);
    appendStr(&prompt_buf, &pp, "> ");
    if (is_console) {
        appendStr(&prompt_buf, &pp, "[LIVE INPUT ACTIVE] _");
    } else {
        appendStr(&prompt_buf, &pp, "Press [F6] to type into guest");
    }
    surface.drawText(69, 52, bar_fg, color.COLOR_INPUT_BG, prompt_buf[0..pp]);
}

fn drawBottomBar(surface: Surface) void {
    surface.fillRect(bottom_bar_rect.x, bottom_bar_rect.y, bottom_bar_rect.w, bottom_bar_rect.h, color.COLOR_SEA_GRAY);
    surface.drawText(73, 1, color.COLOR_WHITE, color.COLOR_SEA_GRAY, " [F1]Help [F2]Form [F3]VMs [F4]Shell [F6]Console [F7/F8]Switch VM [S]tart [K]ill");
}

fn drawHelpModal(surface: Surface) void {
    help_modal.render(surface);

    const base_row: u32 = 14;
    const col: u32 = 18;

    surface.drawText(base_row + 0, col, color.COLOR_GOLDEN_YELLOW, color.COLOR_MODAL_BG, "KEYBOARD NAVIGATION & SHORTCUTS:");
    surface.drawText(base_row + 2, col, color.COLOR_WHITE, color.COLOR_MODAL_BG, "  [Tab] / [S-Tab]   Navigate Form fields & cycle TUI panes");
    surface.drawText(base_row + 4, col, color.COLOR_WHITE, color.COLOR_MODAL_BG, "  [F2] / [F3]       Direct jump to Form / VM Manager pane");
    surface.drawText(base_row + 6, col, color.COLOR_WHITE, color.COLOR_MODAL_BG, "  [F4] / [F6]       Direct jump to Varde Shell / Guest Console");
    surface.drawText(base_row + 8, col, color.COLOR_WHITE, color.COLOR_MODAL_BG, "  [F7] / [F8]       Switch Guest Serial Console between MicroVMs");

    surface.drawText(base_row + 11, col, color.COLOR_GOLDEN_YELLOW, color.COLOR_MODAL_BG, "MICROVM PROVISIONING & ACTIONS:");
    surface.drawText(base_row + 13, col, color.COLOR_WHITE, color.COLOR_MODAL_BG, "  < CREATE & LAUNCH >  Validate configuration & launch MicroVM");
    surface.drawText(base_row + 15, col, color.COLOR_WHITE, color.COLOR_MODAL_BG, "  [S]tart / [C]onsole  Start MicroVM or attach to guest ttyS0");
    surface.drawText(base_row + 17, col, color.COLOR_WHITE, color.COLOR_MODAL_BG, "  [K]ill / [D]elete    Stop or delete selected MicroVM");
    surface.drawText(base_row + 19, col, color.COLOR_WHITE, color.COLOR_MODAL_BG, "  [PgUp] / [PgDn]      Scroll Varde Shell or Guest Console log");

    surface.drawText(base_row + 24, col, color.COLOR_GOLDEN_YELLOW, color.COLOR_MODAL_BG, "SYSTEM SHORTCUTS:");
    surface.drawText(base_row + 26, col, color.COLOR_WHITE, color.COLOR_MODAL_BG, "  [F5] Refresh telemetry  |  [F12] Quit  |  [F1] / '?' Help");

    surface.drawText(base_row + 30, col + 12, color.COLOR_HIGHLIGHT, color.COLOR_MODAL_BG, "Press [Esc] or [Enter] to Close Help");
}

test "vNIC binding command accepts explicit dual-stack addresses" {
    const parsed = parseNetworkBindCommand("vnic-bind 7 10.77.0.7 fd00::7");
    try std.testing.expect(parsed == .binding);
    const binding = parsed.binding;
    try std.testing.expectEqual(@as(u32, 7), binding.vmid);
    try std.testing.expectEqual([4]u8{ 10, 77, 0, 7 }, binding.ipv4.?);
    try std.testing.expectEqual([16]u8{ 0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7 }, binding.ipv6.?);
    const cleared = parseNetworkBindCommand("vnic-bind 7 - -");
    try std.testing.expect(cleared == .binding);
    try std.testing.expect(cleared.binding.ipv4 == null and cleared.binding.ipv6 == null);
    try std.testing.expect(parseNetworkBindCommand("ps") == .unrelated);
    try std.testing.expect(parseNetworkBindCommand("vnic-bind 0 - -") == .invalid);
    try std.testing.expect(parseNetworkBindCommand("vnic-bind 7 999.1.1.1 -") == .invalid);
    try std.testing.expect(parseNetworkBindCommand("vnic-bind 7 - not-ipv6") == .invalid);
    try std.testing.expect(parseNetworkBindCommand("vnic-bind 7 -") == .invalid);
    try std.testing.expect(parseNetworkBindCommand("vnic-bind 7 - - extra") == .invalid);
}

test "shell input keeps the cursor visible for long commands" {
    try std.testing.expectEqual(@as(usize, 0), shellInputViewStart(34, 34));
    try std.testing.expectEqual(@as(usize, 1), shellInputViewStart(35, 34));
    try std.testing.expectEqual(@as(usize, 62), shellInputViewStart(96, 34));
}

test "vNIC configuration replies require the local configd endpoint" {
    var page = lib.PageHeader{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @intCast(lib.DIPC_HEADER_SIZE),
        .payload_len = @sizeOf(proto_configd.ConfigdHeader),
        .auth_tag = 0,
        .src = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @backingInt(lib.ReservedEndpoint.configd) },
        .dst = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @backingInt(lib.ReservedEndpoint.windowd) },
    };
    try std.testing.expect(isLocalConfigdReply(&page));
    page.src.endpoint = @backingInt(lib.ReservedEndpoint.netd);
    try std.testing.expect(!isLocalConfigdReply(&page));
    page.src.endpoint = @backingInt(lib.ReservedEndpoint.configd);
    page.src.node.bytes[0] = 0xFE;
    try std.testing.expect(!isLocalConfigdReply(&page));
    page.src.node = lib.Ipv6Addr.loopback();
    page.dst.node.bytes[0] = 0xFE;
    try std.testing.expect(!isLocalConfigdReply(&page));
}
