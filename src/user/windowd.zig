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
const SYS_ALLOC_DMA = 5;
const SYS_FB_DRAW = 16;

const BootstrapDescriptor = lib.BootstrapDescriptor;

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;

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

    serialWrite("windowd: starting\n");
    _ = syscall(SYS_REGISTER, 0, 9, token);
    serialWrite("windowd: registered at endpoint 9\n");

    const dma_phys = syscall(SYS_ALLOC_DMA, 1, 0, token);
    if (dma_phys == 0) {
        serialWrite("windowd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    const dma_ptr: [*]u8 = ptrFrom([*]u8, DMA_BASE_VA);
    const msg = "windowd: UI Compositor initialized.";
    @memcpy(dma_ptr[0..msg.len], msg);
    dma_ptr[msg.len] = 0;

    // Draw string to row 5, col 0
    const row = 5;
    const col = 0;
    const arg1 = (@as(u64, row) << 32) | col;
    _ = syscall(SYS_FB_DRAW, dma_phys, arg1, token);

    const DrawRequest = extern struct {
        row: u32,
        col: u32,
        text: [256]u8,
    };

    while (true) {
        const page_phys = syscall(3, 0, 0, token); // SYS_RECV
        if (page_phys == 0) {
            asm volatile ("pause");
            continue;
        }

        const recv_va = syscall(17, page_phys, 0, token); // SYS_MAP_RECV
        if (recv_va == 0) {
            _ = syscall(4, page_phys, 0, token); // SYS_FREE_PAGE
            continue;
        }

        // Multiplex logic: we expect a payload with draw commands.
        const req: *align(1) const DrawRequest = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);

        @memcpy(dma_ptr[0..256], &req.text);

        const draw_arg1 = (@as(u64, req.row) << 32) | req.col;
        _ = syscall(SYS_FB_DRAW, dma_phys, draw_arg1, token);

        _ = syscall(4, 0x0000_7F00_0000_0000, 0, token); // SYS_FREE_PAGE on DIPC_RECV_VA
    }
}
