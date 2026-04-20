const std = @import("std");
const lib = @import("lib.zig");



const SYS_REGISTER = 2;
const SYS_RECV = 3;
const SYS_FREE_PAGE = 4;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_MAP_RECV = 17;

const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;

const BootstrapDescriptor = lib.BootstrapDescriptor;

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;



pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    lib.serialWrite("clusterd: starting\n");
    // Register clusterd on endpoint 7 (assume we map it to 7 in identity.zig)
    _ = lib.syscall(SYS_REGISTER, 0, 7, token);
    lib.serialWrite("clusterd: registered at endpoint 7\n");

    const dipc_phys = lib.syscall(SYS_ALLOC_DMA, 1, 0, token);
    if (dipc_phys == 0) {
        lib.serialWrite("clusterd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    lib.serialWrite("clusterd: requesting local MicroVM launch...\n");

    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA);

    const local_node = lib.Ipv6Addr{ .bytes = bs.local_node };
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(@sizeOf(lib.PageHeader))),
        .payload_len = @as(u32, @intCast(@sizeOf(lib.ControlHeader) + @sizeOf(lib.CreateMicrovmPayload))),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = 7 },
        .dst = .{ .node = local_node, .endpoint = bs.reserved_kernel_control_endpoint },
    };

    const control: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + @sizeOf(lib.PageHeader));
    control.* = .{
        .op = .create_microvm,
        .payload_len = @as(u32, @intCast(@sizeOf(lib.CreateMicrovmPayload))),
    };

    const payload: *align(1) lib.CreateMicrovmPayload = @ptrFromInt(@intFromPtr(scratch) + @sizeOf(lib.PageHeader) + @sizeOf(lib.ControlHeader));
    payload.* = .{
        .mem_pages = 16384,
        .vcpus = 1,
        .kernel_phys = bs.linux_bzimage_phys,
        .kernel_size = bs.linux_bzimage_size,
        .initramfs_phys = bs.initramfs_phys,
        .initramfs_size = bs.initramfs_size,
    };

    _ = lib.syscall(SYS_SEND_PAGE, dipc_phys, 0, token);

    lib.serialWrite("clusterd: entering event loop\n");
    while (true) {
        const page_phys = lib.syscall(SYS_RECV, 0, 0, token);
        if (page_phys != 0) {
            _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
        }
        asm volatile ("pause");
    }
}
