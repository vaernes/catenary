const std = @import("std");
const lib = @import("lib.zig");



const SYS_REGISTER = 2;
const SYS_RECV = 3;
const SYS_FREE_PAGE = 4;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_MAP_RECV = 17;

const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;

const BootstrapDescriptor = lib.BootstrapDescriptor;

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;



fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        lib.outb(0x3F8, hex[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
}

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    lib.serialWrite("containerd: starting\n");
    // Wait, the BootstrapDescriptor doesn't have reserved_containerd_endpoint
    // We should use a hardcoded endpoint ID if we didn't add it to Identity.
    // Let's assume endpoint ID 6 for containerd.
    _ = lib.syscall(SYS_REGISTER, 0, 6, token);
    lib.serialWrite("containerd: registered at endpoint 6\n");

    // Allocate 2 DMA pages: 1 for data payload, 1 for DIPC scratch
    const data_phys = lib.syscall(SYS_ALLOC_DMA, 1, 0, token);
    const dipc_phys = lib.syscall(SYS_ALLOC_DMA, 1, 1, token);

    if (data_phys == 0 or dipc_phys == 0) {
        lib.serialWrite("containerd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    lib.serialWrite("containerd: simulating image pull...\n");

    // Fill data page with dummy ext4 superblock or tarball header
    const data_va: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 0 * 4096);
    for (0..4096) |i| {
        data_va[i] = 0xAB; // Dummy layer byte
    }

    // Send a block write request to storaged via DIPC
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 1 * 4096);

    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(@sizeOf(lib.BlkRequest))),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = 6 },
        .dst = .{ .node = local_node, .endpoint = bs.reserved_storaged_endpoint },
    };

    const request: *align(1) lib.BlkRequest = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    request.* = .{
        .req_type = 1,
        ._reserved = 0,
        .sector = 1024,
        .vmid = 0,
        .chain_head = 0,
        .data_len = 4096,
        .data_hpa = data_phys,
    };

    lib.serialWrite("containerd: sending image block to storaged...\n");
    _ = lib.syscall(SYS_SEND_PAGE, dipc_phys, 0, token);

    lib.serialWrite("containerd: entering event loop\n");
    while (true) {
        const page_phys = lib.syscall(SYS_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                const control: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
                if (control.op == .virtio_blk_response and control.payload_len >= @sizeOf(lib.VirtioBlkResponsePayload)) {
                    const response: *align(1) const lib.VirtioBlkResponsePayload = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
                    if (response.status == 0) {
                        lib.serialWrite("containerd: unpack block WRITE SUCCESS!\n");
                    } else {
                        lib.serialWrite("containerd: unpack block WRITE FAILED!\n");
                    }
                }
            }
            _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
        }
        asm volatile ("pause");
    }
}
