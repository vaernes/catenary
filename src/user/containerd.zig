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

const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
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
    reserved_containerd_endpoint: u64,
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
    for (s) |c| outb(0x3F8, c);
}

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        outb(0x3F8, hex[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
}

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    serialWrite("containerd: starting\n");
    // Wait, the BootstrapDescriptor doesn't have reserved_containerd_endpoint
    // We should use a hardcoded endpoint ID if we didn't add it to Identity.
    // Let's assume endpoint ID 6 for containerd.
    _ = syscall(SYS_REGISTER, 0, 6, token);
    serialWrite("containerd: registered at endpoint 6\n");

    // Allocate 2 DMA pages: 1 for data payload, 1 for DIPC scratch
    const data_phys = syscall(SYS_ALLOC_DMA, 1, 0, token);
    const dipc_phys = syscall(SYS_ALLOC_DMA, 1, 1, token);
    
    if (data_phys == 0 or dipc_phys == 0) {
        serialWrite("containerd: DMA alloc failed\n");
        while(true) asm volatile("pause");
    }

    serialWrite("containerd: simulating image pull...\n");
    
    // Fill data page with dummy ext4 superblock or tarball header
    const data_va: [*]u8 = ptrFrom([*]u8, DMA_BASE_VA + 0 * 4096);
    for (0..4096) |i| {
        data_va[i] = 0xAB; // Dummy layer byte
    }
    
    // Send a block write request to storaged via DIPC
    const scratch: [*]u8 = ptrFrom([*]u8, DMA_BASE_VA + 1 * 4096);
    
    // DIPC PageHeader
    scratch[0] = 0x43; scratch[1] = 0x50; scratch[2] = 0x49; scratch[3] = 0x44;
    scratch[4] = 1; scratch[5] = 0;
    scratch[6] = 64; scratch[7] = 0;
    scratch[8] = 48; scratch[9] = 0; scratch[10] = 0; scratch[11] = 0; // payload_len=48
    
    @memset(scratch[12..20], 0); // auth
    
    // src (node + endpoint 6)
    @memcpy(scratch[20..36], &bs.local_node);
    scratch[36] = 6; @memset(scratch[37..44], 0);
    
    // dst (node + storaged endpoint)
    @memcpy(scratch[44..60], &bs.local_node);
    const sid = bs.reserved_storaged_endpoint;
    scratch[60] = @truncate(sid); scratch[61] = @truncate(sid >> 8);
    scratch[62] = @truncate(sid >> 16); scratch[63] = @truncate(sid >> 24);
    scratch[64] = @truncate(sid >> 32); scratch[65] = @truncate(sid >> 40);
    scratch[66] = @truncate(sid >> 48); scratch[67] = @truncate(sid >> 56);

    // BlkRequest payload at offset 64
    // req_type = 1 (write)
    scratch[64] = 1; scratch[65] = 0; scratch[66] = 0; scratch[67] = 0;
    // _reserved
    scratch[68] = 0; scratch[69] = 0; scratch[70] = 0; scratch[71] = 0;
    // sector = 1024 (some offset)
    scratch[72] = 0; scratch[73] = 4; scratch[74] = 0; scratch[75] = 0;
    scratch[76] = 0; scratch[77] = 0; scratch[78] = 0; scratch[79] = 0;
    
    // vmid = 0 (we are not a VM)
    scratch[80] = 0; scratch[81] = 0; scratch[82] = 0; scratch[83] = 0;
    // chain_head = 0
    scratch[84] = 0; scratch[85] = 0;
    // data_len = 4096
    scratch[86] = 0; scratch[87] = 16;
    // data_hpa
    scratch[88] = @truncate(data_phys);
    scratch[89] = @truncate(data_phys >> 8);
    scratch[90] = @truncate(data_phys >> 16);
    scratch[91] = @truncate(data_phys >> 24);
    scratch[92] = @truncate(data_phys >> 32);
    scratch[93] = @truncate(data_phys >> 40);
    scratch[94] = @truncate(data_phys >> 48);
    scratch[95] = @truncate(data_phys >> 56);

    serialWrite("containerd: sending image block to storaged...\n");
    _ = syscall(SYS_SEND_PAGE, dipc_phys, 0, token);

    serialWrite("containerd: entering event loop\n");
    while (true) {
        const page_phys = syscall(SYS_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                // Read response
                const payload: [*]const u8 = ptrFrom([*]const u8, recv_va + 64);
                // virtio_blk_response opcode is 17
                if (payload[0] == 17) {
                    const status = payload[14];
                    if (status == 0) {
                        serialWrite("containerd: unpack block WRITE SUCCESS!\n");
                    } else {
                        serialWrite("containerd: unpack block WRITE FAILED!\n");
                    }
                }
            }
            _ = syscall(SYS_FREE_PAGE, page_phys, 0, token);
        }
        asm volatile ("pause");
    }
}
