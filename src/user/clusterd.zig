const std = @import("std");

fn ptrFrom(comptime T: type, addr: u64) T {
    return @ptrFromInt(asm volatile ("" : [ret] "={rax}" (-> u64) : [val] "{rax}" (addr)));
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
        while(true) asm volatile("pause");
    }

    serialWrite("clusterd: requesting local MicroVM launch...\n");
    
    const scratch: [*]u8 = ptrFrom([*]u8, DMA_BASE_VA);
    
    // DIPC PageHeader
    scratch[0] = 0x43; scratch[1] = 0x50; scratch[2] = 0x49; scratch[3] = 0x44;
    scratch[4] = 1; scratch[5] = 0;
    scratch[6] = 64; scratch[7] = 0;
    scratch[8] = 16; scratch[9] = 0; scratch[10] = 0; scratch[11] = 0; // payload_len=16
    @memset(scratch[12..20], 0); // auth
    
    // src (node + endpoint 7)
    @memcpy(scratch[20..36], &bs.local_node);
    scratch[36] = 7; @memset(scratch[37..44], 0);
    
    // dst (node + kernel control endpoint)
    @memcpy(scratch[44..60], &bs.local_node); // local node for now
    const kc_id = bs.reserved_kernel_control_endpoint;
    scratch[60] = @truncate(kc_id); scratch[61] = @truncate(kc_id >> 8);
    scratch[62] = @truncate(kc_id >> 16); scratch[63] = @truncate(kc_id >> 24);
    scratch[64] = @truncate(kc_id >> 32); scratch[65] = @truncate(kc_id >> 40);
    scratch[66] = @truncate(kc_id >> 48); scratch[67] = @truncate(kc_id >> 56);

    // ControlHeader (op=6 create_microvm, payload_len=8)
    scratch[64] = 6; scratch[65] = 0; // op
    scratch[66] = 0; scratch[67] = 0; // _reserved
    scratch[68] = 8; scratch[69] = 0; scratch[70] = 0; scratch[71] = 0; // len

    // CreateMicrovmPayload
    scratch[72] = 0; scratch[73] = 64; scratch[74] = 0; scratch[75] = 0; // mem_pages = 16384 (64MiB)
    scratch[76] = 0; scratch[77] = 0; scratch[78] = 0; scratch[79] = 0; // _reserved

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
