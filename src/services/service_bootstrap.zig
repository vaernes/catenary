const std = @import("std");
const dipc = @import("../ipc/dipc.zig");

pub const DescriptorMagic: u32 = 0x53565442; // 'SVTB'
pub const DescriptorVersion: u16 = 1;

pub const ServiceKind = enum(u16) {
    netd = 1,
    vmm = 2,
    storaged = 3,
    dashd = 4,
    containerd = 5,
    clusterd = 6,
    inputd = 7,
    windowd = 8,
    configd = 9,
};

pub const UserId = enum(u32) {
    core = 0,
    vm_deployer = 100,
    guest_user = 1000,
};

pub const ProcessClass = enum(u16) {
    kernel = 0,
    user_service = 1,
    user_app = 2,
};

pub const DescriptorError = error{
    BadMagic,
    BadVersion,
    BadLength,
    Unauthorized,
};

pub const RuntimeMode = enum(u16) {
    oneshot = 1,
    persistent = 2,
};

pub const PersistentTrapVector: u8 = 0x80;
pub const PersistentHeartbeatOp: u16 = 1;
pub const PersistentStopOp: u16 = 2;

pub const Descriptor = extern struct {
    magic: u32,
    version: u16,
    descriptor_len: u16,
    class: u16,
    service_kind: u16,
    runtime_mode: u16,
    _reserved0: u16 = 0,
    service_id: u32,
    user_id: u32,
    flags: u32 = 0,
    persistent_trap_vector: u8,
    _reserved1: u8 = 0,
    persistent_heartbeat_op: u16,
    persistent_stop_op: u16,
    _reserved2: u16 = 0,
    local_node: dipc.Ipv6Addr,
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
    reserved_clusterd_endpoint: u64,
    reserved_inputd_endpoint: u64,
    reserved_windowd_endpoint: u64,
    reserved_configd_endpoint: u64,
    microvm_ingress_magic: u32,
    microvm_ingress_version: u16,
    microvm_ingress_len: u16,
    capability_token: u64,
    config_size: u64 = 0,
    linux_bzimage_phys: u64 = 0,
    linux_bzimage_size: u64 = 0,
    initramfs_phys: u64 = 0,
    initramfs_size: u64 = 0,
};

pub fn validate(desc: Descriptor) DescriptorError!void {
    if (desc.magic != DescriptorMagic) return error.BadMagic;
    if (desc.version != DescriptorVersion) return error.BadVersion;
    if (desc.descriptor_len != @sizeOf(Descriptor)) return error.BadLength;
}

/// Check whether a given syscall op is allowed for the specified service kind.
pub fn isSyscallAllowed(kind: ServiceKind, op: u64) bool {
    if (op > 31) return false;
    const mask = allowedSyscallMask(kind);
    return (mask & (@as(u32, 1) << @as(u5, @intCast(op)))) != 0;
}

fn allowedSyscallMask(kind: ServiceKind) u32 {
    // Shared IPC and diagnostics ops used across user services.
    const base_mask: u32 =
        (1 << 2) | // SYS_REGISTER
        (1 << 3) | // SYS_RECV
        (1 << 4) | // SYS_FREE_PAGE
        (1 << 5) | // SYS_ALLOC_DMA
        (1 << 6) | // SYS_SEND_PAGE
        (1 << 9) | // SYS_SERIAL_WRITE
        (1 << 17) | // SYS_MAP_RECV
        (1 << 24); // SYS_YIELD

    return switch (kind) {
        .netd => base_mask | (1 << 7) | (1 << 13) | (1 << 14) | (1 << 22) | (1 << 23), // MMIO, PCI, PORT_IO
        .storaged => base_mask | (1 << 7) | (1 << 13) | (1 << 14) | (1 << 22) | (1 << 23),
        .dashd => base_mask | (1 << 16) | (1 << 18) | (1 << 20),
        .inputd => base_mask | (1 << 8),
        .windowd => base_mask | (1 << 16) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 21) | (1 << 25) | (1 << 26), // FB drawing, inbox poll, Varde shell
        .containerd => base_mask | (1 << 20),
        else => base_mask,
    };
}

fn baseDescriptor(kind: ServiceKind, service_id: u32, user_id: UserId, mode: RuntimeMode, token: u64, local_node: dipc.Ipv6Addr) Descriptor {
    const identity = @import("../ipc/identity.zig");
    const microvm_transport = @import("../vmm/microvm_transport.zig");

    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(kind),
        .runtime_mode = @intFromEnum(mode),
        .service_id = service_id,
        .user_id = @intFromEnum(user_id),
        .persistent_trap_vector = if (mode == .persistent) PersistentTrapVector else 0,
        .persistent_heartbeat_op = if (mode == .persistent) PersistentHeartbeatOp else 0,
        .persistent_stop_op = if (mode == .persistent) PersistentStopOp else 0,
        .local_node = local_node,
        .dipc_wire_magic = dipc.WireMagic,
        .dipc_wire_version = dipc.WireVersion,
        .dipc_header_len = @as(u16, @intCast(dipc.HEADER_SIZE)),
        .dipc_max_payload = @as(u32, @intCast(dipc.MAX_PAYLOAD)),
        .reserved_netd_endpoint = @intFromEnum(identity.ReservedEndpoint.netd),
        .reserved_kernel_control_endpoint = @intFromEnum(identity.ReservedEndpoint.kernel_control),
        .reserved_router_endpoint = @intFromEnum(identity.ReservedEndpoint.router),
        .reserved_storaged_endpoint = @intFromEnum(identity.ReservedEndpoint.storaged),
        .reserved_dashd_endpoint = @intFromEnum(identity.ReservedEndpoint.dashd),
        .reserved_containerd_endpoint = @intFromEnum(identity.ReservedEndpoint.containerd),
        .reserved_clusterd_endpoint = @intFromEnum(identity.ReservedEndpoint.clusterd),
        .reserved_inputd_endpoint = @intFromEnum(identity.ReservedEndpoint.inputd),
        .reserved_windowd_endpoint = @intFromEnum(identity.ReservedEndpoint.windowd),
        .reserved_configd_endpoint = @intFromEnum(identity.ReservedEndpoint.configd),
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = token,
    };
}

pub fn forNetd(local_node: dipc.Ipv6Addr, service_id: u32, user_id: UserId, mode: RuntimeMode, token: u64) Descriptor {
    return baseDescriptor(.netd, service_id, user_id, mode, token, local_node);
}

pub fn forVmm(local_node: dipc.Ipv6Addr, service_id: u32, user_id: UserId, token: u64) Descriptor {
    return baseDescriptor(.vmm, service_id, user_id, .oneshot, token, local_node);
}

pub fn forStoraged(local_node: dipc.Ipv6Addr, service_id: u32, user_id: UserId, token: u64) Descriptor {
    return baseDescriptor(.storaged, service_id, user_id, .oneshot, token, local_node);
}

pub fn forDashd(local_node: dipc.Ipv6Addr, service_id: u32, user_id: UserId, token: u64) Descriptor {
    return baseDescriptor(.dashd, service_id, user_id, .oneshot, token, local_node);
}

pub fn forContainerd(local_node: dipc.Ipv6Addr, service_id: u32, user_id: UserId, token: u64) Descriptor {
    return baseDescriptor(.containerd, service_id, user_id, .oneshot, token, local_node);
}

pub fn forClusterd(local_node: dipc.Ipv6Addr, service_id: u32, user_id: UserId, token: u64) Descriptor {
    return baseDescriptor(.clusterd, service_id, user_id, .oneshot, token, local_node);
}

pub fn forInputd(local_node: dipc.Ipv6Addr, service_id: u32, user_id: UserId, token: u64) Descriptor {
    return baseDescriptor(.inputd, service_id, user_id, .persistent, token, local_node);
}

pub fn forWindowd(local_node: dipc.Ipv6Addr, service_id: u32, user_id: UserId, token: u64) Descriptor {
    return baseDescriptor(.windowd, service_id, user_id, .persistent, token, local_node);
}

pub fn forConfigd(local_node: dipc.Ipv6Addr, service_id: u32, user_id: UserId, token: u64) Descriptor {
    return baseDescriptor(.configd, service_id, user_id, .persistent, token, local_node);
}
