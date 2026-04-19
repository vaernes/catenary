const std = @import("std");

pub fn ptrFrom(comptime T: type, addr: u64) T {
    return @ptrFromInt(asm volatile (""
        : [ret] "={rax}" (-> u64),
        : [val] "{rax}" (addr),
    ));
}

pub fn syscall(op: u64, arg0: u64, arg1: u64, token: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [op] "{rax}" (op),
          [arg0] "{rbx}" (arg0),
          [arg1] "{rdx}" (arg1),
          [token] "{r8}" (token),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub const SYS_REGISTER = 2;
pub const SYS_RECV = 3;
pub const SYS_FREE_PAGE = 4;
pub const SYS_ALLOC_DMA = 5;
pub const SYS_SEND_PAGE = 6;
pub const SYS_GET_KEY = 8;
pub const SYS_SERIAL_WRITE = 9;
pub const SYS_FB_DRAW = 16;
pub const SYS_MAP_RECV = 17;

pub const DIPC_HEADER_SIZE: usize = 64;
pub const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
pub const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;
pub const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;
pub const USER_CONFIG_VADDR: usize = USER_BOOTSTRAP_VADDR - (64 * PAGE_SIZE);
pub const PAGE_SIZE: u64 = 4096;

pub const BootstrapDescriptor = extern struct {
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
    config_size: u64,
    linux_bzimage_phys: u64,
    linux_bzimage_size: u64,
    initramfs_phys: u64,
    initramfs_size: u64,
};

pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

pub fn serialWrite(s: []const u8) void {
    _ = syscall(SYS_SERIAL_WRITE, @intFromPtr(s.ptr), s.len, 0);
}

pub fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        outb(0x3F8, hex[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
}

pub const Ipv6Addr = extern struct {
    bytes: [16]u8,
    pub fn loopback() Ipv6Addr {
        var out: Ipv6Addr = .{ .bytes = [_]u8{0} ** 16 };
        out.bytes[15] = 1;
        return out;
    }
};

pub const EndpointId = u64;

pub const Address = extern struct {
    node: Ipv6Addr,
    endpoint: EndpointId,
};

pub const WireVersion: u16 = 1;
pub const WireMagic: u32 = 0x44495043; // 'DIPC'

pub const PageHeader = extern struct {
    magic: u32,
    version: u16,
    header_len: u16,
    payload_len: u32,
    auth_tag: u64,
    src: Address,
    dst: Address,
};

pub const ControlOp = enum(u16) {
    register_netd = 1,
    set_node_addr = 2,
    register_netd_service = 3,
    poll_netd_inbox = 4,
    assign_node_addr = 5,
    create_microvm = 6,
    start_microvm = 7,
    stop_microvm = 8,
    delete_microvm = 9,
    revoke_node_addr = 10,
    register_storaged_service = 11,
    register_telemetry = 12,
    pci_read_config = 13,
    pci_write_config = 14,
    phys_alloc = 15,
    phys_free = 16,
    virtio_blk_response = 17,
    registry_sync = 18,
    query_dashboard = 19,
};

pub const ControlHeader = extern struct {
    op: ControlOp,
    _reserved: u16 = 0,
    payload_len: u32,
};

pub const CreateMicrovmPayload = extern struct {
    mem_pages: u32,
    vcpus: u32,
    kernel_phys: u64,
    kernel_size: u64,
    initramfs_phys: u64,
    initramfs_size: u64,
};

pub const BlkRequest = extern struct {
    req_type: u32,
    _reserved: u32,
    sector: u64,
    vmid: u32,
    chain_head: u16,
    data_len: u16,
    data_hpa: u64,
};

pub const VirtioBlkResponsePayload = extern struct {
    vmid: u32,
    head_idx: u16,
    status: u8,
    _pad: u8 = 0,
};
