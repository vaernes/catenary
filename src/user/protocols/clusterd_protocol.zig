/// clusterd DIPC protocol
///
/// Endpoint: ReservedEndpoint.clusterd (7)
///
/// clusterd is the cluster orchestration daemon.  It discovers peer nodes via
/// registry_sync messages (sent by configd/router), then issues
/// create_microvm requests to the kernel_control endpoint on behalf of other
/// services.  It also accepts direct VM-launch requests from peer clusterd
/// instances on remote nodes.
///
/// Message format:
///   PageHeader     (lib.DIPC_HEADER_SIZE bytes)
///   ControlHeader  (8 bytes, op from lib.ControlOp)  — for kernel messages
///   payload        (op-specific)
///
/// Service-to-service messages use ClusterdHeader instead of ControlHeader.
pub const MAGIC: u32 = 0x434C5354; // 'CLST'
pub const VERSION: u16 = 1;

// ---------------------------------------------------------------------------
// Service-to-service ops (clusterd ↔ peer clusterd or configd)
// ---------------------------------------------------------------------------

pub const Op = enum(u16) {
    /// A remote clusterd requests that this node launch a MicroVM.
    /// Payload: LaunchVmRequest.
    launch_vm_request = 1,

    /// Acknowledgement from the target clusterd that it accepted a launch.
    /// Payload: LaunchVmAck.
    launch_vm_ack = 2,

    /// Request the VM list for display (from windowd, future use).
    /// Payload: none.  Reply op: vm_list_reply.
    vm_list_request = 3,

    /// Reply to vm_list_request.
    /// Payload: VmListReply.
    vm_list_reply = 4,

    /// Broadcast current node resource availability to peer clusterd instances.
    /// Payload: ResourceAdvertisement.
    resource_advertisement = 5,

    /// Request a point-in-time resource snapshot from a peer.
    /// Payload: ResourceSnapshotRequest. Reply op: resource_snapshot_reply.
    resource_snapshot_request = 6,

    /// Reply to resource_snapshot_request.
    /// Payload: ResourceSnapshotReply.
    resource_snapshot_reply = 7,
};

/// Header for clusterd service-to-service messages (not kernel_control messages).
pub const ClusterdHeader = extern struct {
    magic: u32 = MAGIC,
    version: u16 = VERSION,
    op: Op,
    payload_len: u32,
    _pad: u32 = 0,
};

// ---------------------------------------------------------------------------
// Per-op payloads
// ---------------------------------------------------------------------------

pub const LaunchVmStatus = enum(u32) {
    ok = 0,
    rejected = 1,
    no_capacity = 2,
    invalid_payload = 3,
    busy = 4,
    unauthorized = 5,
    internal_error = 6,
};

/// Op.launch_vm_request — ask a remote node to create and start a MicroVM.
pub const LaunchVmRequest = extern struct {
    request_id: u64,
    flags: u32 = 0,
    _pad0: u32 = 0,
    /// Requested memory in 4 KiB pages.
    mem_pages: u32,
    /// Requested vCPU count.
    vcpus: u32,
    /// Kernel image physical address on the requesting node (resolved remotely
    /// from the bootstrap descriptor; remote node uses its own images).
    kernel_phys: u64,
    kernel_size: u64,
    initramfs_phys: u64,
    initramfs_size: u64,
    /// Human-readable VM name (NUL-padded).
    name: [32]u8,
    /// Container tag / image name (NUL-padded).
    container: [32]u8,
};

/// Op.launch_vm_ack — response from the target clusterd.
pub const LaunchVmAck = extern struct {
    request_id: u64,
    /// Instance ID assigned by the remote kernel (0 on failure).
    instance_id: u32,
    /// Result status for the request.
    status: LaunchVmStatus,
};

pub const ResourceAdvertisement = extern struct {
    generation: u64,
    total_mem_pages: u32,
    free_mem_pages: u32,
    logical_cpu_total: u32,
    logical_cpu_available: u32,
    active_vms: u32,
    service_mask: u32,
    flags: u32,
    _pad0: u32 = 0,
};

pub const ResourceSnapshotRequest = extern struct {
    flags: u32 = 0,
    _pad: u32 = 0,
};

pub const ResourceSnapshotEntry = extern struct {
    node_addr: [16]u8,
    resources: ResourceAdvertisement,
};

pub const MAX_RESOURCE_SNAPSHOT_ENTRIES: usize = 16;

pub const ResourceSnapshotReply = extern struct {
    count: u32,
    _pad: u32 = 0,
    entries: [MAX_RESOURCE_SNAPSHOT_ENTRIES]ResourceSnapshotEntry = [_]ResourceSnapshotEntry{.{
        .node_addr = [_]u8{0} ** 16,
        .resources = .{
            .generation = 0,
            .total_mem_pages = 0,
            .free_mem_pages = 0,
            .logical_cpu_total = 0,
            .logical_cpu_available = 0,
            .active_vms = 0,
            .service_mask = 0,
            .flags = 0,
        },
    }} ** MAX_RESOURCE_SNAPSHOT_ENTRIES,
};

/// Op.vm_list_reply — compact VM snapshot list for dashboard queries.
pub const VmEntry = extern struct {
    instance_id: u32,
    state: u8,
    _pad: [3]u8 = [_]u8{0} ** 3,
    mem_pages: u32,
    vcpus: u32,
    name: [32]u8,
};

pub const MAX_VM_ENTRIES: usize = 32;

pub const VmListReply = extern struct {
    count: u32,
    _pad: u32 = 0,
    entries: [MAX_VM_ENTRIES]VmEntry,
};
