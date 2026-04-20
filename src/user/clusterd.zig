const std = @import("std");
const lib = @import("lib.zig");

fn ptrFrom(comptime T: type, addr: u64) T {
    return @ptrFromInt(asm volatile (""
        : [ret] "={rax}" (-> u64),
        : [val] "{rax}" (addr),
    ));
}

fn syscall(op: u64, arg0: u64, arg1: u64, token: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [op] "{rax}" (op),
          [arg0] "{rbx}" (arg0),
          [arg1] "{rdx}" (arg1),
          [token] "{r8}" (token),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

const SYS_REGISTER = 2;
const SYS_RECV = 3;
const SYS_FREE_PAGE = 4;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_MAP_RECV = 17;

const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;

const BootstrapDescriptor = lib.BootstrapDescriptor;

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

fn serialWrite(s: []const u8) void {
    _ = syscall(9, @intFromPtr(s.ptr), s.len, 0);
}

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    serialWrite("clusterd: starting\n");
    // Register clusterd on endpoint 7 (assume we map it to 7 in identity.zig)
    _ = syscall(SYS_REGISTER, 0, 7, token);
    serialWrite("clusterd: registered at endpoint 7\n");

    const dipc_phys = syscall(SYS_ALLOC_DMA, 1, 0, token);
    if (dipc_phys == 0) {
        serialWrite("clusterd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    serialWrite("clusterd: requesting local MicroVM launch...\n");

    const scratch: [*]u8 = ptrFrom([*]u8, DMA_BASE_VA);

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

    _ = syscall(SYS_SEND_PAGE, dipc_phys, 0, token);

    serialWrite("clusterd: entering event loop\n");
    while (true) {
        const page_phys = syscall(SYS_RECV, 0, 0, token);
        if (page_phys != 0) {
            _ = syscall(SYS_FREE_PAGE, page_phys, 0, token);
        }
        asm volatile ("pause");
    }
}
