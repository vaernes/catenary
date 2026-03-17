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

fn syscall(op: u64, arg0: u64, arg1: u64, token: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [op] "{rax}" (op),
          [arg0] "{rbx}" (arg0),
          [arg1] "{rdx}" (arg1),
          [token] "{r8}" (token),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn ptrFrom(comptime T: type, addr: u64) T {
    return @ptrFromInt(asm volatile (""
        : [ret] "={rax}" (-> u64),
        : [val] "{rax}" (addr),
    ));
}
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

const BootstrapDescriptor = extern struct {
    magic: u32,
    version: u16,
    descriptor_len: u16,
    class: u16,
    service_kind: u16,
    runtime_mode: u16,
    _r0: u16,
    service_id: u32,
    flags: u32,
    persistent_trap_vector: u8,
    _r1: u8,
    persistent_heartbeat_op: u16,
    persistent_stop_op: u16,
    _r2: u16,
    local_node: [16]u8,
    dipc_wire_magic: u32,
    dipc_wire_version: u16,
    dipc_header_len: u16,
    dipc_max_payload: u32,
    reserved_netd_endpoint: u64,
    reserved_kernel_control_endpoint: u64,
    reserved_router_endpoint: u64,
    reserved_storaged_endpoint: u64,
    reserved_dashd_endpoint: u64,
    microvm_ingress_magic: u32,
    microvm_ingress_version: u16,
    microvm_ingress_len: u16,
    capability_token: u64,
};

// ---------------------------------------------------------------------------
// Shared DIPC / control protocol constants
// ---------------------------------------------------------------------------

const DIPC_MAGIC: u32 = 0x44495043; // 'DIPC'
const DIPC_VERSION: u16 = 1;
const DIPC_HDR_LEN: u16 = 64;

const CTRL_OP_CREATE_MICROVM: u16 = 6;
const CTRL_OP_REGISTRY_SYNC: u16 = 18;

// Endpoint IDs (must match identity.zig ReservedEndpoint)
const EP_KERNEL_CONTROL: u64 = 2;
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

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

fn serialWrite(s: []const u8) void {
    for (s) |c| outb(0x3F8, c);
}

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
        _ = syscall(SYS_FB_DRAW, text_phys, (@as(u64, 0) << 32) | 0, token);
    }

    // --- Row 1: local node ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "Node: ");
        writeHexNode(buf, &pos, local_node);
        buf[pos] = 0;
        _ = syscall(SYS_FB_DRAW, text_phys, (@as(u64, 1) << 32) | 0, token);
    }

    // --- Row 2: separator ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "------------------------------------------");
        buf[pos] = 0;
        _ = syscall(SYS_FB_DRAW, text_phys, (@as(u64, 2) << 32) | 0, token);
    }

    // --- Row 3: cluster header ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "Cluster Nodes:");
        buf[pos] = 0;
        _ = syscall(SYS_FB_DRAW, text_phys, (@as(u64, 3) << 32) | 0, token);
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
        _ = syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }

    // --- MicroVM section ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "MicroVMs:");
        buf[pos] = 0;
        _ = syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
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
        _ = syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }

    // --- Footer ---
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "------------------------------------------");
        buf[pos] = 0;
        _ = syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
        row += 1;
    }
    {
        var pos: usize = 0;
        writeLine(buf, &pos, "Keys: [L] Launch VM   [R] Refresh   [Q] Quit");
        buf[pos] = 0;
        _ = syscall(SYS_FB_DRAW, text_phys, (@as(u64, row) << 32) | 0, token);
    }
}

// ---------------------------------------------------------------------------
// Send a create_microvm control request to the kernel via DIPC.
// The DIPC message goes to kernel_control (endpoint 2).
// ---------------------------------------------------------------------------

fn launchMicroVm(bs: *const BootstrapDescriptor, token: u64, dipc_phys_slot1: u64) void {
    const dipc_buf: [*]u8 = ptrFrom([*]u8, DMA_DIPC_SLOT);
    // Format DIPC header at DMA slot 1
    // magic
    dipc_buf[0] = 0x43;
    dipc_buf[1] = 0x50;
    dipc_buf[2] = 0x49;
    dipc_buf[3] = 0x44;
    // version
    dipc_buf[4] = 1;
    dipc_buf[5] = 0;
    // header_len
    dipc_buf[6] = 64;
    dipc_buf[7] = 0;
    // payload_len = ControlHeader(8) + CreateMicrovmPayload(8) = 16
    dipc_buf[8] = 16;
    dipc_buf[9] = 0;
    dipc_buf[10] = 0;
    dipc_buf[11] = 0;
    // auth_tag (will be re-signed by kernel in SYS_SEND_PAGE)
    @memset(dipc_buf[12..20], 0);
    // src: local_node + configd endpoint (10)
    @memcpy(dipc_buf[20..36], &bs.local_node);
    dipc_buf[36] = @truncate(EP_CONFIGD);
    @memset(dipc_buf[37..44], 0);
    // dst: local_node + kernel_control endpoint (2)
    @memcpy(dipc_buf[44..60], &bs.local_node);
    dipc_buf[60] = @truncate(EP_KERNEL_CONTROL);
    @memset(dipc_buf[61..68], 0);

    // ControlHeader at offset 64
    // op = create_microvm (6), _reserved=0, payload_len=8
    dipc_buf[64] = @truncate(CTRL_OP_CREATE_MICROVM);
    dipc_buf[65] = 0;
    dipc_buf[66] = 0;
    dipc_buf[67] = 0;
    dipc_buf[68] = 8;
    dipc_buf[69] = 0;
    dipc_buf[70] = 0;
    dipc_buf[71] = 0;

    // CreateMicrovmPayload at offset 72
    // mem_pages = 256 (1 GiB / 4 KiB = 256 pages for a 1 MiB VM)
    const mem_pages: u32 = 256;
    dipc_buf[72] = @truncate(mem_pages & 0xFF);
    dipc_buf[73] = @truncate((mem_pages >> 8) & 0xFF);
    dipc_buf[74] = @truncate((mem_pages >> 16) & 0xFF);
    dipc_buf[75] = @truncate((mem_pages >> 24) & 0xFF);
    dipc_buf[76] = 0;
    dipc_buf[77] = 0;
    dipc_buf[78] = 0;
    dipc_buf[79] = 0;

    // The kernel's SYS_SEND_PAGE copies from the DMA phys page, re-signs, and routes.
    _ = syscall(SYS_SEND_PAGE, dipc_phys_slot1, 0, token);

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

    serialWrite("configd: create_microvm request sent\n");
}

// ---------------------------------------------------------------------------
// Handle an incoming DIPC registry_sync message (updates cluster_nodes table)
// ---------------------------------------------------------------------------

const RegistrySyncPayload = extern struct {
    service_id: u32,
    service_kind: u16,
    state: u8,
    _pad: u8,
};

fn handleRegistrySync(page_va: u64) void {
    const DIPC_HDR: usize = 64;
    const CTRL_HDR: usize = 8;
    const src_node_off: usize = 20; // src.node within DIPC header

    const page: [*]const u8 = ptrFrom([*]const u8, page_va);

    // Extract source node address from DIPC header
    var src_node: [16]u8 = undefined;
    @memcpy(&src_node, page[src_node_off .. src_node_off + 16]);

    const payload: *const RegistrySyncPayload = @ptrCast(@alignCast(&page[DIPC_HDR + CTRL_HDR]));

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
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    serialWrite("configd: starting OS Configuration App\n");

    // Register at endpoint 10
    _ = syscall(SYS_REGISTER, 0, EP_CONFIGD, token);
    serialWrite("configd: registered at endpoint 10\n");

    // Allocate two DMA pages: text scratch (slot 0) + DIPC outbox (slot 1)
    const text_phys = syscall(SYS_ALLOC_DMA, 2, 0, token);
    if (text_phys == 0) {
        serialWrite("configd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }
    // Slot 1 physical = slot 0 + PAGE_SIZE
    const dipc_phys: u64 = text_phys + PAGE_SIZE;

    // Draw initial UI
    drawUi(text_phys, token, bs.local_node);
    serialWrite("configd: initial UI rendered\n");

    var refresh_counter: u32 = 0;

    // Main event loop
    while (true) {
        // --- Poll keyboard via inputd's SYS_GET_KEY ---
        const key = syscall(SYS_GET_KEY, 0, 0, token);
        if (key != 0xFFFFFFFF) {
            const scancode: u8 = @truncate(key);
            if ((scancode & 0x80) == 0) { // make code only
                const ascii: u8 = switch (scancode) {
                    0x26 => 'l', // L — launch VM
                    0x13 => 'r', // R — refresh
                    0x10 => 'q', // Q — quit
                    else => 0,
                };
                if (ascii == 'l') {
                    launchMicroVm(bs, token, dipc_phys);
                    drawUi(text_phys, token, bs.local_node);
                } else if (ascii == 'r') {
                    drawUi(text_phys, token, bs.local_node);
                } else if (ascii == 'q') {
                    serialWrite("configd: shutdown requested\n");
                }
            }
        }

        // --- Poll DIPC inbox for registry_sync messages ---
        const page_phys = syscall(SYS_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                // Peek at ControlHeader op field (offset 64 = DIPC header size)
                const page: [*]const u8 = ptrFrom([*]const u8, recv_va);
                const op: u16 = @as(u16, page[64]) | (@as(u16, page[65]) << 8);
                if (op == CTRL_OP_REGISTRY_SYNC) {
                    handleRegistrySync(recv_va);
                    drawUi(text_phys, token, bs.local_node);
                }
                _ = syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
            } else {
                _ = syscall(SYS_FREE_PAGE, page_phys, 0, token);
            }
        }

        // --- Periodic refresh (every ~500k polling cycles) ---
        refresh_counter += 1;
        if (refresh_counter >= 500_000) {
            refresh_counter = 0;
            drawUi(text_phys, token, bs.local_node);
        }

        asm volatile ("pause");
    }
}
