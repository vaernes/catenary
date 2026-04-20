const dipc = @import("../ipc/dipc.zig");

// Core IPC control-plane protocol.
// This is a message payload format carried inside `dipc` page-backed messages.
// Target: `identity.ReservedEndpoint.kernel_control`.

pub const ControlOp = enum(u16) {
    register_netd = 1,
    set_node_addr = 2,
    register_netd_service = 3,
    // Routing ops used by the persistent netd bring-up path.
    poll_netd_inbox = 4,
    assign_node_addr = 5,
    // VMM OCI lifecycle ops: issued by the Ring-3 VMM service, handled by
    // the kernel control endpoint which maps them onto microvm_registry state.
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
    list_microvms = 19,
    get_node_status = 20,
    get_node_addr = 21,
};

pub const ControlHeader = extern struct {
    op: ControlOp,
    _reserved: u16 = 0,
    payload_len: u32,
};

pub const PhysAllocPayload = extern struct {
    num_pages: u32,
    alignment_order: u8, // e.g. 0 for 4KB, 9 for 2MB (aligned)
};

pub const PhysAllocResult = extern struct {
    phys_addr: u64, // 0 if failed
    num_pages: u32,
};

pub const PhysFreePayload = extern struct {
    phys_addr: u64,
    num_pages: u32,
};

pub const PciReadConfigPayload = extern struct {
    bus: u8,
    device: u8,
    function: u8,
    offset: u8,
    size: u8, // 1, 2, or 4
};

pub const PciWriteConfigPayload = extern struct {
    bus: u8,
    device: u8,
    function: u8,
    offset: u8,
    size: u8, // 1, 2, or 4
    value: u32,
};

pub const RegisterNetdPayload = extern struct {
    // Temporary stand-in until Ring 3 exists.
    // When user-space tasks are introduced, this becomes a capability/handle.
    thread_id: u32,
};

pub const SetNodeAddrPayload = extern struct {
    addr: dipc.Ipv6Addr,
};

pub const RegisterNetdServicePayload = extern struct {
    capability_token: u64,
};

// Returned from poll_netd_inbox: encodes whether the dequeued message was
// destined for the local node (route_local=1) or would be forwarded off-node.
pub const PollNetdResult = extern struct {
    route_local: u32, // 1 = local, 0 = remote
    src_endpoint: u64, // source endpoint ID from the DIPC header
};

// VMM OCI lifecycle payloads.

/// Request the kernel to allocate a MicroVM instance slot.
/// Returns instance_id in the trap status field (0 = failed).
pub const CreateMicrovmPayload = extern struct {
    /// Guest RAM in 4 KiB pages (e.g. 16384 = 64 MiB).
    mem_pages: u32,
    vcpus: u32,
    kernel_phys: u64,
    kernel_size: u64,
    initramfs_phys: u64,
    initramfs_size: u64,
    name: [32]u8,
};

/// Request the kernel to transition instance_id to running and initiate VMX launch.
pub const StartMicrovmPayload = extern struct {
    instance_id: u32,
    _reserved: u32 = 0,
};

/// Request the kernel to stop a running MicroVM instance.
pub const StopMicrovmPayload = extern struct {
    instance_id: u32,
    _reserved: u32 = 0,
};

/// Request the kernel to release a stopped MicroVM instance slot.
pub const DeleteMicrovmPayload = extern struct {
    instance_id: u32,
    _reserved: u32 = 0,
};

pub const MicrovmInfo = extern struct {
    instance_id: u32,
    state: u32, // 0=empty, 1=created, 2=running, 3=stopped
    mem_pages: u32,
    vcpus: u32,
    name: [32]u8,
};

pub const ListMicrovmsResult = extern struct {
    count: u32,
    _pad: u32 = 0,
    vms: [64]MicrovmInfo,
};

pub const NodeStatusResult = extern struct {
    total_mem_pages: u32,
    free_mem_pages: u32,
    active_vms: u32,
    _pad: u32 = 0,
};

pub const NodeAddrResult = extern struct {
    addr: dipc.Ipv6Addr,
};

pub const RegisterStoragedServicePayload = extern struct {
    capability_token: u64,
};

pub const RegisterTelemetryPayload = extern struct {
    capability_token: u64,
};

pub const TelemetryUpdatePayload = extern struct {
    instance_id: u32,
    _reserved: u32 = 0,
    cpu_cycles: u64,
    exit_count: u64,
};

pub const VirtioBlkResponsePayload = extern struct {
    vmid: u32,
    head_idx: u16,
    status: u8,
    _pad: u8 = 0,
};

pub const RegistrySyncPayload = extern struct {
    service_id: u32,
    service_kind: u16,
    state: u8,
    _pad: u8 = 0,
};
