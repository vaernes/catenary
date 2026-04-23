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

    const local_node = lib.queryCurrentNode(bs, token, dipc_phys, DMA_BASE_VA, 7) orelse lib.Ipv6Addr{ .bytes = bs.local_node };
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
        .name = [_]u8{0} ** 32,
        .container = [_]u8{0} ** 32,
    };
    @memcpy(payload.name[0..7], "default");

    _ = lib.syscall(SYS_SEND_PAGE, dipc_phys, 0, token);

    var remote_launched: bool = false;

    lib.serialWrite("clusterd: entering event loop\n");
    while (true) {
        const page_phys = lib.syscall(SYS_RECV, 0, 0, token);
        if (page_phys != 0) {
            lib.serialWrite("clusterd: SYS_RECV returned a page\n");
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                lib.serialWrite("clusterd: mapped page\n");
                const in_header: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
                const in_control: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);

                if (in_control.op == .registry_sync and !remote_launched) {
                    lib.serialWrite("clusterd: received registry_sync\n");
                    var is_local = true;
                    for (0..16) |i| {
                        if (in_header.src.node.bytes[i] != local_node.bytes[i]) {
                            is_local = false;
                        }
                    }

                    if (!is_local and in_header.src.node.bytes[15] != 1) {
                        remote_launched = true;
                        lib.serialWrite("clusterd: discovered remote node via registry_sync, requesting remote MicroVM launch\n");

                        const src_node = in_header.src.node;
                        const out_header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
                        out_header.* = .{
                            .magic = lib.WireMagic,
                            .version = lib.WireVersion,
                            .header_len = @as(u16, @intCast(@sizeOf(lib.PageHeader))),
                            .payload_len = @as(u32, @intCast(@sizeOf(lib.ControlHeader) + @sizeOf(lib.CreateMicrovmPayload))),
                            .auth_tag = 0,
                            .src = .{ .node = local_node, .endpoint = 7 },
                            .dst = .{ .node = src_node, .endpoint = bs.reserved_kernel_control_endpoint },
                        };

                        const control_out: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + @sizeOf(lib.PageHeader));
                        control_out.* = .{
                            .op = .create_microvm,
                            .payload_len = @as(u32, @intCast(@sizeOf(lib.CreateMicrovmPayload))),
                        };

                        const out_payload: *align(1) lib.CreateMicrovmPayload = @ptrFromInt(@intFromPtr(scratch) + @sizeOf(lib.PageHeader) + @sizeOf(lib.ControlHeader));
                        out_payload.* = .{
                            .mem_pages = 16384,
                            .vcpus = 1,
                            .kernel_phys = bs.linux_bzimage_phys,
                            .kernel_size = bs.linux_bzimage_size,
                            .initramfs_phys = bs.initramfs_phys,
                            .initramfs_size = bs.initramfs_size,
                            .name = [_]u8{0} ** 32,
                            .container = [_]u8{0} ** 32,
                        };
                        @memcpy(out_payload.name[0..13], "remote-micron"); // name length is < 32

                        _ = lib.syscall(SYS_SEND_PAGE, dipc_phys, 0, token);
                    }
                }

                // configd also frees DIPC_RECV_VA and here we do the same since MAP_RECV maps into VA
                _ = lib.syscall(SYS_FREE_PAGE, lib.DIPC_RECV_VA, 0, token);
            } else {
                _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
            }
        }

        _ = lib.syscall(lib.SYS_YIELD, 0, 0, token);
        asm volatile ("pause");
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
