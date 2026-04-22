const lib = @import("lib.zig");

/// configd — OS Configuration Application
///
/// Provides a text-mode UI rendered via windowd onto the kernel framebuffer.
/// Displays:
///   - Local node IPv6 address (from bootstrap)
///   - Cluster node registry (received via registry_sync DIPC from other nodes)
///   - MicroVM list with status (launched by clusterd)
///   - Network interface status (from netd heartbeats)
///
/// The user can issue commands by pressing keys routed via inputd.
/// Supported commands (single keypress):
///   'l' — Launch a new MicroVM via clusterd (sends create_microvm DIPC)
///   'r' — Refresh display
///   'q' — Shutdown request (idles)

// ---------------------------------------------------------------------------
// Syscall shim
// ---------------------------------------------------------------------------

const SYS_LOG = 1;
const SYS_REGISTER = 2;
const SYS_RECV = 3;
const SYS_FREE_PAGE = 4;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_GET_KEY = 8;
const SYS_FB_DRAW = 16;
const SYS_MAP_RECV = 17;

// ---------------------------------------------------------------------------
// Memory layout constants
// ---------------------------------------------------------------------------

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;
const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
const PAGE_SIZE: u64 = 4096;

// DMA slot layout (each slot is one 4 KiB page):
//   slot 0: framebuffer text scratch (send via SYS_FB_DRAW)
//   slot 1: outgoing DIPC messages (send via SYS_SEND_PAGE)
const DMA_TEXT_SLOT: u64 = DMA_BASE_VA;
const DMA_DIPC_SLOT: u64 = DMA_BASE_VA + PAGE_SIZE;

// ---------------------------------------------------------------------------
// Bootstrap descriptor (mirrors service_bootstrap.Descriptor)
// ---------------------------------------------------------------------------

const BootstrapDescriptor = lib.BootstrapDescriptor;

// ---------------------------------------------------------------------------
// Shared DIPC / control protocol constants
// ---------------------------------------------------------------------------

const EP_CLUSTERD: u64 = 7;
const EP_WINDOWD: u64 = 9;
const EP_CONFIGD: u64 = 10;

// ---------------------------------------------------------------------------
// Intra-service state
// ---------------------------------------------------------------------------

const MAX_CLUSTER_NODES = 8;
const MAX_VMS = 8;

const NodeEntry = struct {
    used: bool = false,
    addr: [16]u8 = [_]u8{0} ** 16,
    services: u16 = 0,
};

const VmEntry = struct {
    used: bool = false,
    instance_id: u32 = 0,
    mem_pages: u32 = 0,
};

var cluster_nodes: [MAX_CLUSTER_NODES]NodeEntry = [_]NodeEntry{.{}} ** MAX_CLUSTER_NODES;
var vms: [MAX_VMS]VmEntry = [_]VmEntry{.{}} ** MAX_VMS;
var next_vmid: u32 = 1;

// ---------------------------------------------------------------------------
// Serial helpers (for debug output before windowd is ready)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Text helpers (write into DMA text slot)
// ---------------------------------------------------------------------------

fn textBuf() [*]u8 {
    return @ptrFromInt(DMA_TEXT_SLOT);
}

fn writeLine(buf: [*]u8, pos: *usize, s: []const u8) void {
    for (s) |c| {
        buf[pos.*] = c;
        pos.* += 1;
    }
}

fn writeHex8(buf: [*]u8, pos: *usize, v: u8) void {
    const hex = "0123456789ABCDEF";
    buf[pos.*] = hex[v >> 4];
    pos.* += 1;
    buf[pos.*] = hex[v & 0xF];
    pos.* += 1;
}

fn writeHexNode(buf: [*]u8, pos: *usize, addr: [16]u8) void {
    // Print first 8 bytes as condensed hex groups, e.g. "fe80:0000:0000:0001"
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        if (i > 0) {
            buf[pos.*] = ':';
            pos.* += 1;
        }
        writeHex8(buf, pos, addr[i]);
        writeHex8(buf, pos, addr[i + 1]);
    }
}

// ---------------------------------------------------------------------------
// Draw a full UI frame to the framebuffer via windowd SYS_FB_DRAW
// ---------------------------------------------------------------------------

fn drawUi(text_phys: u64, token: u64, local_node: [16]u8) void {
    const buf = textBuf();

    // --- Row 0: banner ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "=== Catenary OS  Configuration Console ===");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, 0) << 32) | 0, token);
    }

    // --- Row 1: local node ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "Node: ");
        writeHexNode(buf, &pos, local_node);
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, 1) << 32) | 0, token);
    }

    // --- Row 2: separator ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "------------------------------------------");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, 2) << 32) | 0, token);
    }

    // --- Row 3: cluster header ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "Cluster Nodes:");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, 3) << 32) | 0, token);
    }

    // --- Rows 4..(4+MAX_CLUSTER_NODES): node list ---
    var row: u32 = 4;
    for (&cluster_nodes) |*n| {
        var pos: usize = 0;
        if (n.used) {
            writeLine(buf, &pos, "  [*] ");
            writeHexNode(buf, &pos, n.addr);
            writeLine(buf, &pos, "  svc=0x");
            writeHex8(buf, &pos, @truncate(n.services >> 8));
            writeHex8(buf, &pos, @truncate(n.services & 0xFF));
        } else {
            writeLine(buf, &pos, "  [ ] ---");
        }
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }

    // --- MicroVM section ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "MicroVMs:");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }

    for (&vms) |*v| {
        var pos: usize = 0;
        if (v.used) {
            writeLine(buf, &pos, "  VM#");
            writeHex8(buf, &pos, @truncate(v.instance_id));
            writeLine(buf, &pos, "  mem=");
            writeHex8(buf, &pos, @truncate(v.mem_pages >> 8));
            writeHex8(buf, &pos, @truncate(v.mem_pages & 0xFF));
            writeLine(buf, &pos, " pages");
        } else {
            writeLine(buf, &pos, "  ---");
        }
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }

    // --- Footer ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "------------------------------------------");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "Keys: [L] Launch VM   [R] Refresh   [Q] Quit");
        buf[pos] = 0;
        _ = lib.syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
    }
}

// ---------------------------------------------------------------------------
// Send a create_microvm control request to the kernel via DIPC.
// The DIPC message goes to kernel_control (endpoint 2).
// ---------------------------------------------------------------------------

fn launchMicroVm(bs: *const BootstrapDescriptor, token: u64, dipc_phys_slot1: u64) void {
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_DIPC_SLOT);
    const local_node = lib.queryCurrentNode(bs, token, dipc_phys_slot1, DMA_DIPC_SLOT, EP_CONFIGD) orelse lib.Ipv6Addr{ .bytes = bs.local_node };

    // mem_pages = 256 (1 GiB / 4 KiB = 256 pages for a 1 MiB VM)
    const mem_pages: u32 = 256;

    const ini_file =
        \\[microvm]
        \\vcpus=2
        \\mem_pages=256
    ;

    var vcpus: u32 = 1;
    {
        var i: usize = 0;
        while (i < ini_file.len) {
            // Check for vcpus=
            var is_match = true;
            const prefix = "vcpus=";
            if (i + prefix.len <= ini_file.len) {
                for (prefix, 0..) |c, j| {
                    if (ini_file[i + j] != c) {
                        is_match = false;
                        break;
                    }
                }
                if (is_match) {
                    var v: u32 = 0;
                    var j = i + prefix.len;
                    while (j < ini_file.len and ini_file[j] >= '0' and ini_file[j] <= '9') {
                        v = v * 10 + (ini_file[j] - '0');
                        j += 1;
                    }
                    if (v > 0) vcpus = v;
                    break;
                }
            }
            while (i < ini_file.len and ini_file[i] != '\n') i += 1;
            if (i < ini_file.len) i += 1; // skip newline
        }
    }

    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(@sizeOf(lib.ControlHeader) + @sizeOf(lib.CreateMicrovmPayload))),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = EP_CONFIGD },
        .dst = .{ .node = local_node, .endpoint = bs.reserved_kernel_control_endpoint },
    };

    const control: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    control.* = .{
        .op = .create_microvm,
        .payload_len = @as(u32, @intCast(@sizeOf(lib.CreateMicrovmPayload))),
    };

    const payload: *align(1) lib.CreateMicrovmPayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
    payload.* = .{
        .mem_pages = mem_pages,
        .vcpus = vcpus,
        .kernel_phys = bs.linux_bzimage_phys,
        .kernel_size = bs.linux_bzimage_size,
        .initramfs_phys = bs.initramfs_phys,
        .initramfs_size = bs.initramfs_size,
        .name = [_]u8{0} ** 32,
        .container = [_]u8{0} ** 32,
    };

    // The kernel's SYS_SEND_PAGE copies from the DMA phys page, re-signs, and routes.
    _ = lib.syscall(SYS_SEND_PAGE, dipc_phys_slot1, 0, token);

    // Record in local VM table
    for (&vms) |*v| {
        if (!v.used) {
            v.used = true;
            v.instance_id = next_vmid;
            v.mem_pages = mem_pages;
            next_vmid += 1;
            break;
        }
    }

    lib.serialWrite("configd: create_microvm request sent\n");
}

// ---------------------------------------------------------------------------
// Handle an incoming DIPC registry_sync message (updates cluster_nodes table)
// ---------------------------------------------------------------------------

const RegistrySyncPayload = lib.RegistrySyncPayload;

fn handleRegistrySync(page_va: u64) void {
    const header: *align(1) const lib.PageHeader = @ptrFromInt(page_va);
    const payload: *align(1) const RegistrySyncPayload = @ptrFromInt(page_va + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
    const src_node = header.src.node.bytes;

    // Find existing or new slot for this node
    var slot: ?*NodeEntry = null;
    for (&cluster_nodes) |*n| {
        if (n.used) {
            var match = true;
            for (0..16) |i| {
                if (n.addr[i] != src_node[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                slot = n;
                break;
            }
        }
    }
    if (slot == null) {
        for (&cluster_nodes) |*n| {
            if (!n.used) {
                n.used = true;
                @memcpy(&n.addr, &src_node);
                slot = n;
                break;
            }
        }
    }

    if (slot) |s| {
        // Accumulate service kind bitmask so we can display which services are present
        s.services |= @as(u16, 1) << @as(u4, @truncate(payload.service_kind & 0xF));
        lib.serialWrite("configd: registry sync applied\n");
    }
}

// ---------------------------------------------------------------------------
// Handle a list_microvms request from windowd — reply with a VmSnapshotListPayload.
// ---------------------------------------------------------------------------

fn handleListMicrovms(bs: *const BootstrapDescriptor, token: u64, text_phys: u64, req_va: u64) void {
    // Determine the requesting endpoint so we can route the reply back.
    const req_hdr: *align(1) const lib.PageHeader = @ptrFromInt(req_va);
    const reply_ep = req_hdr.src.endpoint;
    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };

    // Build the snapshot into the DMA text slot (VA = DMA_TEXT_SLOT, phys = text_phys).
    const reply_buf: [*]u8 = lib.ptrFrom([*]u8, DMA_TEXT_SLOT);

    // DIPC header
    const reply_hdr: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(reply_buf));
    reply_hdr.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(lib.CONTROL_HEADER_SIZE + @sizeOf(lib.VmSnapshotListPayload))),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = EP_CONFIGD },
        .dst = .{ .node = local_node, .endpoint = reply_ep },
    };

    // Control header
    const reply_ctrl: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(reply_buf) + lib.DIPC_HEADER_SIZE);
    reply_ctrl.* = .{
        .op = .list_microvms,
        .payload_len = @as(u32, @intCast(@sizeOf(lib.VmSnapshotListPayload))),
    };

    // Payload — convert our simple VmEntry table to VmSnapshotEntry format.
    const snap: *align(1) lib.VmSnapshotListPayload = @ptrFromInt(@intFromPtr(reply_buf) + lib.DIPC_HEADER_SIZE + lib.CONTROL_HEADER_SIZE);
    // Zero-initialise
    @memset(@as([*]u8, @ptrFromInt(@intFromPtr(snap)))[0..@sizeOf(lib.VmSnapshotListPayload)], 0);
    var count: u32 = 0;
    for (&vms, 0..) |*v, i| {
        if (!v.used) continue;
        if (count >= lib.MAX_VM_SNAPSHOT_ENTRIES) break;
        snap.entries[count] = .{
            .instance_id = v.instance_id,
            .state = 1, // created (we don't track running/stopped here yet)
            .mem_pages = v.mem_pages,
            .vcpus = 1,
            .cpu_cycles = 0,
            .exit_count = 0,
            .name = [_]u8{0} ** 32,
            .container = [_]u8{0} ** 32,
        };
        // Copy first 3 chars of index as a default name placeholder
        _ = i;
        count += 1;
    }
    snap.count = count;

    _ = lib.syscall(SYS_SEND_PAGE, text_phys, 0, token);
    lib.serialWrite("configd: list_microvms reply sent\n");
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------


pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    lib.serialWrite("configd: starting OS Configuration App\n");

    // Register at endpoint 10
    _ = lib.syscall(SYS_REGISTER, 0, EP_CONFIGD, token);
    lib.serialWrite("configd: registered at endpoint 10\n");

    // Allocate two DMA pages: text scratch (slot 0) + DIPC lib.outbox (slot 1)
    const text_phys = lib.syscall(SYS_ALLOC_DMA, 2, 0, token);
    if (text_phys == 0) {
        lib.serialWrite("configd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }
    // Slot 1 physical = slot 0 + PAGE_SIZE
    const dipc_phys: u64 = text_phys + PAGE_SIZE;
    _ = &dipc_phys;

    // Draw initial UI
    // (windowd owns the framebuffer — configd is now a headless data backend)
    lib.serialWrite("configd: started (headless mode, windowd owns UI)\n");

    // Main event loop — receive DIPC messages; UI is handled by windowd
    while (true) {
        // --- Poll DIPC inbox ---
        const page_phys = lib.syscall(SYS_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                const control: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
                switch (control.op) {
                    .registry_sync => {
                        handleRegistrySync(recv_va);
                    },
                    .list_microvms => {
                        handleListMicrovms(bs, token, text_phys, recv_va);
                    },
                    else => {},
                }
                _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
            } else {
                _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
            }
        }

        asm volatile ("pause");
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
