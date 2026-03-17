const dipc = @import("../ipc/dipc.zig");
const identity = @import("../ipc/identity.zig");
const microvm_transport = @import("../vmm/microvm_transport.zig");

pub const DescriptorMagic: u32 = 0x53565442; // 'SVTB'
pub const DescriptorVersion: u16 = 1;

pub const DescriptorError = error{
    BadMagic,
    BadVersion,
    BadLength,
    BadKind,
};

pub const ProcessClass = enum(u16) {
    kernel_thread = 1,
    user_service = 2,
    microvm_workload = 3,
};

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

pub const RuntimeMode = enum(u16) {
    oneshot = 1,
    persistent = 2,
};

pub const PersistentTrapVector: u8 = 0x80;
pub const PersistentHeartbeatOp: u16 = 1;
pub const PersistentStopOp: u16 = 2;
pub const PersistentStopReasonClean: u32 = 0;
pub const PersistentStopReasonFault: u32 = 1;

// Stable bootstrap contract for future Ring-3 services.
// It carries the kernel/user-space ABI surface a service needs before any
// runtime control plane exists.
pub const Descriptor = extern struct {
    magic: u32,
    version: u16,
    descriptor_len: u16,
    class: u16, // Use u16 for ABI stability
    service_kind: u16,
    runtime_mode: u16,
    _reserved0: u16 = 0,
    service_id: u32,
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
    microvm_ingress_magic: u32,
    microvm_ingress_version: u16,
    microvm_ingress_len: u16,
    capability_token: u64, // Per-service randomized token for kernel-trap auth
};

pub fn validate(desc: Descriptor) DescriptorError!void {
    if (desc.magic != DescriptorMagic) return error.BadMagic;
    if (desc.version != DescriptorVersion) return error.BadVersion;
    if (desc.descriptor_len != @sizeOf(Descriptor)) return error.BadLength;
    // ... enum checks skipped for now as we use u16 in the struct ...
}

pub fn forNetd(local_node: dipc.Ipv6Addr, service_id: u32, runtime_mode: RuntimeMode, capability_token: u64) Descriptor {
    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(ServiceKind.netd),
        .runtime_mode = @intFromEnum(runtime_mode),
        .service_id = service_id,
        .persistent_trap_vector = if (runtime_mode == .persistent) PersistentTrapVector else 0,
        .persistent_heartbeat_op = if (runtime_mode == .persistent) PersistentHeartbeatOp else 0,
        .persistent_stop_op = if (runtime_mode == .persistent) PersistentStopOp else 0,
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
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = capability_token,
    };
}

pub fn forVmm(local_node: dipc.Ipv6Addr, service_id: u32, capability_token: u64) Descriptor {
    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(ServiceKind.vmm),
        .runtime_mode = @intFromEnum(RuntimeMode.persistent),
        .service_id = service_id,
        .persistent_trap_vector = PersistentTrapVector,
        .persistent_heartbeat_op = PersistentHeartbeatOp,
        .persistent_stop_op = PersistentStopOp,
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
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = capability_token,
    };
}

pub fn forStoraged(local_node: dipc.Ipv6Addr, service_id: u32, capability_token: u64) Descriptor {
    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(ServiceKind.storaged),
        .runtime_mode = @intFromEnum(RuntimeMode.oneshot),
        .service_id = service_id,
        .persistent_trap_vector = 0,
        .persistent_heartbeat_op = 0,
        .persistent_stop_op = 0,
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
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = capability_token,
    };
}

pub fn forDashd(local_node: dipc.Ipv6Addr, service_id: u32, capability_token: u64) Descriptor {
    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(ServiceKind.dashd),
        .runtime_mode = @intFromEnum(RuntimeMode.persistent),
        .service_id = service_id,
        .persistent_trap_vector = PersistentTrapVector,
        .persistent_heartbeat_op = PersistentHeartbeatOp,
        .persistent_stop_op = PersistentStopOp,
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
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = capability_token,
    };
}

pub fn forContainerd(local_node: dipc.Ipv6Addr, service_id: u32, capability_token: u64) Descriptor {
    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(ServiceKind.containerd),
        .runtime_mode = @intFromEnum(RuntimeMode.oneshot),
        .service_id = service_id,
        .persistent_trap_vector = 0,
        .persistent_heartbeat_op = 0,
        .persistent_stop_op = 0,
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
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = capability_token,
    };
}

pub fn forClusterd(local_node: dipc.Ipv6Addr, service_id: u32, capability_token: u64) Descriptor {
    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(ServiceKind.clusterd),
        .runtime_mode = @intFromEnum(RuntimeMode.oneshot),
        .service_id = service_id,
        .persistent_trap_vector = 0,
        .persistent_heartbeat_op = 0,
        .persistent_stop_op = 0,
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
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = capability_token,
    };
}

pub fn forInputd(local_node: dipc.Ipv6Addr, service_id: u32, capability_token: u64) Descriptor {
    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(ServiceKind.inputd),
        .runtime_mode = @intFromEnum(RuntimeMode.persistent),
        .service_id = service_id,
        .persistent_trap_vector = PersistentTrapVector,
        .persistent_heartbeat_op = PersistentHeartbeatOp,
        .persistent_stop_op = PersistentStopOp,
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
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = capability_token,
    };
}

pub fn forWindowd(local_node: dipc.Ipv6Addr, service_id: u32, capability_token: u64) Descriptor {
    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(ServiceKind.windowd),
        .runtime_mode = @intFromEnum(RuntimeMode.persistent),
        .service_id = service_id,
        .persistent_trap_vector = PersistentTrapVector,
        .persistent_heartbeat_op = PersistentHeartbeatOp,
        .persistent_stop_op = PersistentStopOp,
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
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = capability_token,
    };
}

pub fn forConfigd(local_node: dipc.Ipv6Addr, service_id: u32, capability_token: u64) Descriptor {
    return .{
        .magic = DescriptorMagic,
        .version = DescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .class = @intFromEnum(ProcessClass.user_service),
        .service_kind = @intFromEnum(ServiceKind.configd),
        .runtime_mode = @intFromEnum(RuntimeMode.persistent),
        .service_id = service_id,
        .persistent_trap_vector = PersistentTrapVector,
        .persistent_heartbeat_op = PersistentHeartbeatOp,
        .persistent_stop_op = PersistentStopOp,
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
        .microvm_ingress_magic = microvm_transport.IngressDescriptorMagic,
        .microvm_ingress_version = microvm_transport.IngressDescriptorVersion,
        .microvm_ingress_len = @as(u16, @intCast(@sizeOf(microvm_transport.IngressDescriptor))),
        .capability_token = capability_token,
    };
}
