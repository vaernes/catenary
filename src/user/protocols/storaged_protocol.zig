/// storaged DIPC protocol
///
/// Endpoint: ReservedEndpoint.storaged (4)
///
/// storaged is the block-device owner.  It accepts read/write/flush requests
/// from any authorized service (containerd, clusterd, the kernel VMM bridge)
/// and replies with a completion status.
///
/// Message format:
///   PageHeader   (lib.DIPC_HEADER_SIZE bytes)
///   BlkRequest   (request) or BlkResponse (reply)
pub const MAGIC: u32 = 0x53544F52; // 'STOR'
pub const VERSION: u16 = 1;

// ---------------------------------------------------------------------------
// Request (sent TO storaged)
// ---------------------------------------------------------------------------

pub const ReqType = enum(u32) {
    /// Read sectors from the block device.
    read = 0,
    /// Write sectors to the block device.
    write = 1,
    /// Flush the write cache / ensure durability.
    flush = 4,
};

/// Block I/O request.  The physical address of the data buffer (for reads:
/// destination; for writes: source) is given in data_hpa.  The kernel maps
/// this address into the DMA window before the request is issued.
pub const BlkRequest = extern struct {
    /// Request type (see ReqType).
    req_type: u32,
    _reserved: u32 = 0,
    /// Starting logical block address (512-byte sectors).
    sector: u64,
    /// MicroVM instance ID (0 = host / Ring-3 requester).
    vmid: u32,
    /// Virtqueue chain head index (used for VMM completions; set 0 for host).
    chain_head: u16,
    /// Number of bytes to transfer (must be a multiple of 512).
    data_len: u16,
    /// Host physical address of the data buffer.
    data_hpa: u64,
};

// ---------------------------------------------------------------------------
// Response (sent FROM storaged back to the requester's endpoint)
// ---------------------------------------------------------------------------

pub const StatusCode = enum(u8) {
    ok = 0,
    io_error = 1,
    unsupported = 2,
};

/// Block I/O completion.  storaged sends this to the endpoint stored in the
/// request's PageHeader.src after the NVMe command completes.
pub const BlkResponse = extern struct {
    /// Mirror of BlkRequest.vmid so the recipient can demultiplex.
    vmid: u32,
    /// Mirror of BlkRequest.chain_head for VMM virtqueue completion.
    chain_head: u16,
    /// Completion status.
    status: StatusCode,
    _pad: u8 = 0,
    /// Number of bytes actually transferred (may be less than requested on error).
    transferred: u32,
    _pad2: u32 = 0,
};
