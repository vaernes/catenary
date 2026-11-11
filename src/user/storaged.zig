/// storaged — NVMe PCI driver + DIPC block-I/O handler.
///
/// Syscall ABI: rax=op, rbx=arg0, rdx=arg1, r8=token.
const std = @import("std");
const lib = @import("lib.zig");
const partition_metadata = @import("protocols/partition_metadata.zig");
const storage_protocol = @import("protocols/storaged_protocol.zig");

// ---------------------------------------------------------------------------
// Low-level serial + lib.syscall interface (same convention as netd.zig)
// ---------------------------------------------------------------------------

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        const c = hex[nibble];
        _ = lib.syscall(lib.SYS_SERIAL_WRITE, @intFromPtr(&c), 1, 0);
        if (shift == 0) break;
        shift -= 4;
    }
}

const SYS_LOG = lib.SYS_ACTIVATE;
const SYS_REGISTER = lib.SYS_REGISTER;
const SYS_RECV = lib.SYS_RECV;
const SYS_FREE_PAGE = lib.SYS_FREE_PAGE;
const SYS_ALLOC_DMA = lib.SYS_ALLOC_DMA;
const SYS_SEND_PAGE = lib.SYS_SEND_PAGE;
const SYS_MAP_IO = lib.SYS_MAP_MMIO;
const SYS_MAP_RECV = lib.SYS_MAP_RECV;

const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;
const IO_WINDOW_VA: u64 = 0x0000_7E00_0000_0000;
const PAGE_SIZE: u64 = 4096;

fn spinPauseWithYield(counter: u32) void {
    asm volatile ("pause");
    // Yield every 256 pauses so storaged does not starve other services on single vCPU.
    if ((counter & 0xFF) == 0) {
        _ = lib.syscall(lib.SYS_YIELD, 0, 0, g_token);
    }
}

// PCI config read/write via kernel lib.syscalls
fn pciRead(bus: u8, dev: u8, func: u8, off: u8, size: u8, token: u64) u64 {
    const addr = (@as(u64, bus) << 24) | (@as(u64, dev) << 16) | (@as(u64, func) << 8) | @as(u64, off);
    return lib.syscall(lib.SYS_PCI_READ_CONFIG, addr, @as(u64, size) << 32, token);
}
fn pciWrite(bus: u8, dev: u8, func: u8, off: u8, size: u8, val: u32, token: u64) void {
    const addr = (@as(u64, bus) << 24) | (@as(u64, dev) << 16) | (@as(u64, func) << 8) | @as(u64, off);
    _ = lib.syscall(lib.SYS_PCI_WRITE_CONFIG, addr, (@as(u64, size) << 32) | val, token);
}

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

const BootstrapDescriptor = lib.BootstrapDescriptor;

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;

// ---------------------------------------------------------------------------
// NVMe MMIO register offsets and constants
// ---------------------------------------------------------------------------

const NVME_REG_CAP: u64 = 0x00; // 64-bit: Controller Capabilities
const NVME_REG_VS: u64 = 0x08; // 32-bit: Version
const NVME_REG_CC: u64 = 0x14; // 32-bit: Controller Configuration
const NVME_REG_CSTS: u64 = 0x1C; // 32-bit: Controller Status
const NVME_REG_AQA: u64 = 0x24; // 32-bit: Admin Queue Attributes
const NVME_REG_ASQ: u64 = 0x28; // 64-bit: Admin SQ Base PA
const NVME_REG_ACQ: u64 = 0x30; // 64-bit: Admin CQ Base PA

const NVME_CC_EN: u32 = 1 << 0;
const NVME_CC_CSS_NVM: u32 = 0 << 4;
const NVME_CC_MPS_4K: u32 = 0 << 7;
const NVME_CC_IOSQES_64: u32 = 6 << 16; // SQE = 2^6 = 64 bytes
const NVME_CC_IOCQES_16: u32 = 4 << 20; // CQE = 2^4 = 16 bytes

const NVME_CSTS_RDY: u32 = 1 << 0;
const NVME_CSTS_CFS: u32 = 1 << 1;

// Admin queue depth (entries, must be < 4096; we use 16).
const ADM_Q_DEPTH: u32 = 16;

// IO queue (queue ID 1).
const IO_Q_DEPTH: u32 = 16;

// NVMe submission queue entry (64 bytes).
const NvmeSqe = extern struct {
    cdw0: u32, // opcode[7:0], fused[9:8], psdt[15:14], cid[31:16]
    nsid: u32,
    cdw2: u32,
    cdw3: u32,
    mptr_lo: u32,
    mptr_hi: u32,
    prp1_lo: u32,
    prp1_hi: u32,
    prp2_lo: u32,
    prp2_hi: u32,
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,
};
comptime {
    @setEvalBranchQuota(1000);
    std.debug.assert(@sizeOf(NvmeSqe) == 64);
}

// NVMe completion queue entry (16 bytes).
const NvmeCqe = extern struct {
    dw0: u32,
    dw1: u32,
    sq_head: u16,
    sq_id: u16,
    cid: u16,
    status: u16, // phase_bit[0], status[15:1]
};
comptime {
    std.debug.assert(@sizeOf(NvmeCqe) == 16);
}

// DIPC block request mirror of virtio_blk.RequestHeader (from kernel microvm_bridge).
const BlkRequest = lib.BlkRequest;
const BLK_WRITE_FUA = @backingInt(lib.BlkReqType.write_fua);
const BLK_ATTACH_VM_DISK = @backingInt(lib.BlkReqType.attach_vm_disk);
const BLK_DETACH_VM_DISK = @backingInt(lib.BlkReqType.detach_vm_disk);
const HOST_METADATA_VMID = storage_protocol.HOST_METADATA_VMID;
const CONTAINERD_ENDPOINT = @backingInt(lib.ReservedEndpoint.containerd);
const CONFIGD_ENDPOINT = @backingInt(lib.ReservedEndpoint.configd);
const KERNEL_CONTROL_ENDPOINT = @backingInt(lib.ReservedEndpoint.kernel_control);

// Lba size (LBA = logical block address, a 512-byte sector).
const SECTOR_SIZE: u32 = 512;

const VmDiskExtent = struct {
    attached: bool = false,
    start_lba: u64 = 0,
    sectors: u64 = 0,
};

var g_vm_disks: [partition_metadata.MAX_VM_DISKS]VmDiskExtent = @splat(.{});

fn isLoopbackOrLinkLocal(node: *const [16]u8) bool {
    const loopback = lib.Ipv6Addr.loopback();
    if (std.mem.eql(u8, node, &loopback.bytes)) return true;
    return node[0] == 0xFE and node[1] == 0x80;
}

fn isAuthorizedBlockClient(
    src_endpoint: u64,
    vmid: u32,
    src_node: *const [16]u8,
) bool {
    const loopback = lib.Ipv6Addr.loopback();
    return src_endpoint == CONTAINERD_ENDPOINT and
        vmid == HOST_METADATA_VMID and
        std.mem.eql(u8, src_node, &loopback.bytes);
}

fn isAuthorizedVmDiskAdmin(
    src_endpoint: u64,
    src_node: *const [16]u8,
) bool {
    return src_endpoint == CONFIGD_ENDPOINT and isLoopbackOrLinkLocal(src_node);
}

fn isAuthorizedVmIoClient(
    table: *const [partition_metadata.MAX_VM_DISKS]VmDiskExtent,
    src_endpoint: u64,
    vmid: u32,
    src_node: *const [16]u8,
) bool {
    const loopback = lib.Ipv6Addr.loopback();
    if (src_endpoint != KERNEL_CONTROL_ENDPOINT or !std.mem.eql(u8, src_node, &loopback.bytes)) return false;
    if (vmid == 0 or vmid > partition_metadata.MAX_VM_DISKS) return false;
    return table[vmid - 1].attached;
}

fn attachVmDisk(
    table: *[partition_metadata.MAX_VM_DISKS]VmDiskExtent,
    vmid: u32,
    start_lba: u64,
    sectors: u64,
) bool {
    const expected_start = partition_metadata.vmDiskStartLba(vmid) orelse return false;
    if (start_lba != expected_start or sectors != partition_metadata.VM_DISK_SECTORS) return false;
    table[vmid - 1] = .{
        .attached = true,
        .start_lba = start_lba,
        .sectors = sectors,
    };
    return true;
}

fn detachVmDisk(
    table: *[partition_metadata.MAX_VM_DISKS]VmDiskExtent,
    vmid: u32,
) bool {
    if (vmid == 0 or vmid > partition_metadata.MAX_VM_DISKS) return false;
    table[vmid - 1] = .{};
    return true;
}

fn translateAttachedVmSector(
    table: *const [partition_metadata.MAX_VM_DISKS]VmDiskExtent,
    vmid: u32,
    guest_sector: u64,
    nlb: u32,
) ?u64 {
    if (vmid == 0 or vmid > partition_metadata.MAX_VM_DISKS or nlb == 0) return null;
    const extent = table[vmid - 1];
    if (!extent.attached) return null;
    const end_sector = std.math.add(u64, guest_sector, nlb) catch return null;
    if (end_sector > extent.sectors) return null;
    return std.math.add(u64, extent.start_lba, guest_sector) catch null;
}

fn isHostMetadataRange(sector: u64, nlb: u32) bool {
    if (nlb == 0) return false;
    const end = std.math.add(u64, sector, nlb) catch return false;
    if (sector >= 1024 and end <= 1032) return true;
    if (nlb != 1) return false;
    if (sector == partition_metadata.JOURNAL_LBA) return true;
    for (0..partition_metadata.MAX_PARTS) |slot| {
        if (sector == partition_metadata.startLba(@intCast(slot))) return true;
    }
    return false;
}

test "unassigned VM block requests cannot access the host NVMe namespace" {
    const local_node = lib.Ipv6Addr.loopback().bytes;
    var remote_node: [16]u8 = @splat(0);
    remote_node[0] = 0xFE;
    remote_node[1] = 0x80;
    remote_node[15] = 1;
    var table: [partition_metadata.MAX_VM_DISKS]VmDiskExtent = @splat(.{});
    try std.testing.expect(isAuthorizedBlockClient(
        CONTAINERD_ENDPOINT,
        HOST_METADATA_VMID,
        &local_node,
    ));
    try std.testing.expect(!isAuthorizedBlockClient(
        @backingInt(lib.ReservedEndpoint.kernel_control),
        1,
        &local_node,
    ));
    try std.testing.expect(!isAuthorizedVmIoClient(
        &table,
        KERNEL_CONTROL_ENDPOINT,
        1,
        &local_node,
    ));
    try std.testing.expect(!isAuthorizedBlockClient(
        CONTAINERD_ENDPOINT,
        1,
        &local_node,
    ));
    try std.testing.expect(!isAuthorizedBlockClient(
        @backingInt(lib.ReservedEndpoint.dashd),
        HOST_METADATA_VMID,
        &local_node,
    ));
    try std.testing.expect(!isAuthorizedBlockClient(
        CONTAINERD_ENDPOINT,
        HOST_METADATA_VMID,
        &remote_node,
    ));
}

test "attached per-VM disk extents translate and isolate guest sector I/O" {
    const local_node = lib.Ipv6Addr.loopback().bytes;
    var table: [partition_metadata.MAX_VM_DISKS]VmDiskExtent = @splat(.{});
    const vm1_start = partition_metadata.vmDiskStartLba(1).?;
    const vm2_start = partition_metadata.vmDiskStartLba(2).?;

    try std.testing.expect(isAuthorizedVmDiskAdmin(CONFIGD_ENDPOINT, &local_node));
    try std.testing.expect(!isAuthorizedVmDiskAdmin(CONTAINERD_ENDPOINT, &local_node));
    try std.testing.expect(!attachVmDisk(&table, 1, vm1_start + 1, partition_metadata.VM_DISK_SECTORS));
    try std.testing.expect(attachVmDisk(&table, 1, vm1_start, partition_metadata.VM_DISK_SECTORS));
    try std.testing.expect(attachVmDisk(&table, 2, vm2_start, partition_metadata.VM_DISK_SECTORS));

    try std.testing.expect(isAuthorizedVmIoClient(&table, KERNEL_CONTROL_ENDPOINT, 1, &local_node));
    try std.testing.expect(!isAuthorizedVmIoClient(&table, CONTAINERD_ENDPOINT, 1, &local_node));
    try std.testing.expectEqual(@as(?u64, vm1_start + 7), translateAttachedVmSector(&table, 1, 7, 1));
    try std.testing.expectEqual(@as(?u64, vm2_start + 7), translateAttachedVmSector(&table, 2, 7, 1));
    try std.testing.expectEqual(@as(?u64, null), translateAttachedVmSector(&table, 1, partition_metadata.VM_DISK_SECTORS, 1));
    try std.testing.expectEqual(@as(?u64, null), translateAttachedVmSector(&table, 3, 0, 1));

    try std.testing.expect(detachVmDisk(&table, 1));
    try std.testing.expect(!isAuthorizedVmIoClient(&table, KERNEL_CONTROL_ENDPOINT, 1, &local_node));
    try std.testing.expectEqual(@as(?u64, null), translateAttachedVmSector(&table, 1, 0, 1));
}

test "host metadata client is confined to its smoke data and metadata sectors" {
    try std.testing.expect(isHostMetadataRange(1024, 8));
    try std.testing.expect(isHostMetadataRange(partition_metadata.JOURNAL_LBA, 1));
    try std.testing.expect(isHostMetadataRange(partition_metadata.startLba(0), 1));
    try std.testing.expect(!isHostMetadataRange(1024, 9));
    try std.testing.expect(!isHostMetadataRange(partition_metadata.startLba(0) + 1, 1));
    try std.testing.expect(!isHostMetadataRange(std.math.maxInt(u64), 1));
    try std.testing.expect(!isHostMetadataRange(partition_metadata.JOURNAL_LBA, 2));
}
// DMA layout (storaged DMA window slots):
// Slot 0:    Admin SQ  (1 page = 16 entries × 64 bytes = 1024 bytes)
// Slot 1:    Admin CQ  (1 page = 16 entries × 16 bytes = 256 bytes)
// Slot 2:    IO SQ     (1 page = 16 × 64 = 1024 bytes)
// Slot 3:    IO CQ     (1 page = 16 × 16 = 256 bytes)
// Slot 4:    Identify  and IO data buffer (shared; Identify used first, then IO data)
// Slot 5-6:  DIPC response scratch

const ADM_SQ_VA: u64 = DMA_BASE_VA + 0 * PAGE_SIZE;
const ADM_CQ_VA: u64 = DMA_BASE_VA + 1 * PAGE_SIZE;
const IO_SQ_VA: u64 = DMA_BASE_VA + 2 * PAGE_SIZE;
const IO_CQ_VA: u64 = DMA_BASE_VA + 3 * PAGE_SIZE;
const DATA_BUF_VA: u64 = DMA_BASE_VA + 4 * PAGE_SIZE;
const DIPC_SCRATCH_VA: u64 = DMA_BASE_VA + 5 * PAGE_SIZE;

var g_token: u64 = 0;
var g_adm_sq_phys: u64 = 0;
var g_adm_cq_phys: u64 = 0;
var g_io_sq_phys: u64 = 0;
var g_io_cq_phys: u64 = 0;
var g_data_buf_phys: u64 = 0;
var g_dipc_scratch_phys: u64 = 0;

var g_adm_sq_tail: u16 = 0;
var g_adm_cq_head: u16 = 0;
var g_adm_cq_phase: u1 = 1; // expected phase bit in completion entries
var g_io_sq_tail: u16 = 0;
var g_io_cq_head: u16 = 0;
var g_io_cq_phase: u1 = 1;
var g_cmd_id: u16 = 0;

var g_ns_lba_count: u64 = 0;
var g_ns_lba_size: u32 = SECTOR_SIZE;
var g_controller_identified: bool = false;
var g_volatile_write_cache: bool = false;

// ---------------------------------------------------------------------------
// NVMe MMIO helpers (IO window at IO_WINDOW_VA)
// ---------------------------------------------------------------------------

fn nvmeR32(off: u64) u32 {
    return lib.ptrFrom(*volatile u32, IO_WINDOW_VA + off).*;
}
fn nvmeW32(off: u64, val: u32) void {
    lib.ptrFrom(*volatile u32, IO_WINDOW_VA + off).* = val;
}
fn nvmeR64(off: u64) u64 {
    return lib.ptrFrom(*volatile u64, IO_WINDOW_VA + off).*;
}
fn nvmeW64(off: u64, val: u64) void {
    lib.ptrFrom(*volatile u64, IO_WINDOW_VA + off).* = val;
}

// Doorbell register addresses (DSTRD=0 assumed for QEMU):
// Admin SQ tail doorbell: 0x1000
// Admin CQ head doorbell: 0x1004
// IO SQ 1 tail doorbell:  0x1008
// IO CQ 1 head doorbell:  0x100C
fn adminSqDoorbell(tail: u32) void {
    nvmeW32(0x1000, tail);
}
fn adminCqDoorbell(head: u32) void {
    nvmeW32(0x1004, head);
}
fn ioSqDoorbell(tail: u32) void {
    nvmeW32(0x1008, tail);
}
fn ioCqDoorbell(head: u32) void {
    nvmeW32(0x100C, head);
}

// ---------------------------------------------------------------------------
// Submit an admin command and poll for its completion.
// Returns status field of CQE (0 = success).
// ---------------------------------------------------------------------------

fn submitAdmin(sqe: NvmeSqe) u16 {
    // Write SQE to admin queue at tail position.
    const sq: [*]NvmeSqe = lib.ptrFrom([*]NvmeSqe, ADM_SQ_VA);
    sq[@as(usize, g_adm_sq_tail % ADM_Q_DEPTH)] = sqe;
    g_adm_sq_tail +%= 1;
    adminSqDoorbell(@as(u32, g_adm_sq_tail % ADM_Q_DEPTH));

    // Poll CQ until we see a completion with the correct phase bit.
    const cq: [*]volatile NvmeCqe = lib.ptrFrom([*]volatile NvmeCqe, ADM_CQ_VA);
    var timeout: u64 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        const entry = &cq[@as(usize, g_adm_cq_head % ADM_Q_DEPTH)];
        const phase: u1 = @truncate(entry.status & 1);
        if (phase == g_adm_cq_phase) {
            const status = (entry.status >> 1) & 0x7FFF;
            g_adm_cq_head +%= 1;
            if (g_adm_cq_head % ADM_Q_DEPTH == 0) g_adm_cq_phase ^= 1;
            adminCqDoorbell(@as(u32, g_adm_cq_head % ADM_Q_DEPTH));
            return @truncate(status);
        }
        spinPauseWithYield(@as(u32, @truncate(timeout)));
    }
    return 0xFFFF; // timeout
}

fn submitIO(sqe: NvmeSqe) u16 {
    const sq: [*]NvmeSqe = lib.ptrFrom([*]NvmeSqe, IO_SQ_VA);
    sq[@as(usize, g_io_sq_tail % IO_Q_DEPTH)] = sqe;
    g_io_sq_tail +%= 1;
    ioSqDoorbell(@as(u32, g_io_sq_tail % IO_Q_DEPTH));

    const cq: [*]volatile NvmeCqe = lib.ptrFrom([*]volatile NvmeCqe, IO_CQ_VA);
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        const entry = &cq[@as(usize, g_io_cq_head % IO_Q_DEPTH)];
        const phase: u1 = @truncate(entry.status & 1);
        if (phase == g_io_cq_phase) {
            const status = (entry.status >> 1) & 0x7FFF;
            g_io_cq_head +%= 1;
            if (g_io_cq_head % IO_Q_DEPTH == 0) g_io_cq_phase ^= 1;
            ioCqDoorbell(@as(u32, g_io_cq_head % IO_Q_DEPTH));
            return @truncate(status);
        }
        spinPauseWithYield(timeout);
    }
    return 0xFFFF;
}

fn nextCmdId() u16 {
    g_cmd_id +%= 1;
    if (g_cmd_id == 0) g_cmd_id = 1;
    return g_cmd_id;
}

fn makeCdw0(opcode: u8, cid: u16) u32 {
    return @as(u32, opcode) | (@as(u32, cid) << 16);
}

// ---------------------------------------------------------------------------
// Admin commands (opcode constants)
// ---------------------------------------------------------------------------

const ADM_IDENTIFY: u8 = 0x06;
const ADM_CREATE_IOSQ: u8 = 0x01;
const ADM_CREATE_IOCQ: u8 = 0x05;

fn cmdIdentifyController() u16 {
    const cid = nextCmdId();
    return submitAdmin(NvmeSqe{
        .cdw0 = makeCdw0(ADM_IDENTIFY, cid),
        .nsid = 0,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr_lo = 0,
        .mptr_hi = 0,
        .prp1_lo = @truncate(g_data_buf_phys),
        .prp1_hi = @truncate(g_data_buf_phys >> 32),
        .prp2_lo = 0,
        .prp2_hi = 0,
        .cdw10 = 1, // CNS=1: identify controller
        .cdw11 = 0,
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    });
}

fn cmdIdentifyNamespace() u16 {
    const cid = nextCmdId();
    return submitAdmin(NvmeSqe{
        .cdw0 = makeCdw0(ADM_IDENTIFY, cid),
        .nsid = 1,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr_lo = 0,
        .mptr_hi = 0,
        .prp1_lo = @truncate(g_data_buf_phys),
        .prp1_hi = @truncate(g_data_buf_phys >> 32),
        .prp2_lo = 0,
        .prp2_hi = 0,
        .cdw10 = 0, // CNS=0: identify namespace
        .cdw11 = 0,
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    });
}

fn cmdCreateIOCQ() u16 {
    const cid = nextCmdId();
    // CDW10: QID=1, QSIZE=IO_Q_DEPTH-1
    const cdw10: u32 = 1 | ((@as(u32, IO_Q_DEPTH) - 1) << 16);
    // CDW11: PC=1 (physically contiguous), INT_EN=0
    return submitAdmin(NvmeSqe{
        .cdw0 = makeCdw0(ADM_CREATE_IOCQ, cid),
        .nsid = 0,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr_lo = 0,
        .mptr_hi = 0,
        .prp1_lo = @truncate(g_io_cq_phys),
        .prp1_hi = @truncate(g_io_cq_phys >> 32),
        .prp2_lo = 0,
        .prp2_hi = 0,
        .cdw10 = cdw10,
        .cdw11 = 1, // PC=1
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    });
}

fn cmdCreateIOSQ() u16 {
    const cid = nextCmdId();
    const cdw10: u32 = 1 | ((@as(u32, IO_Q_DEPTH) - 1) << 16);
    // CDW11: PC=1, CQID=1 (linked to IO CQ 1)
    const cdw11: u32 = 1 | (@as(u32, 1) << 16);
    return submitAdmin(NvmeSqe{
        .cdw0 = makeCdw0(ADM_CREATE_IOSQ, cid),
        .nsid = 0,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr_lo = 0,
        .mptr_hi = 0,
        .prp1_lo = @truncate(g_io_sq_phys),
        .prp1_hi = @truncate(g_io_sq_phys >> 32),
        .prp2_lo = 0,
        .prp2_hi = 0,
        .cdw10 = cdw10,
        .cdw11 = cdw11,
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    });
}

// ---------------------------------------------------------------------------
// IO read/write commands
// ---------------------------------------------------------------------------

const NVM_READ: u8 = 0x02;
const NVM_WRITE: u8 = 0x01;
const NVM_FLUSH: u8 = 0x00;

fn doFlush() u16 {
    if (!g_controller_identified) return 0xFFFF;
    if (!g_volatile_write_cache) return 0;
    const cid = nextCmdId();
    return submitIO(NvmeSqe{
        .cdw0 = makeCdw0(NVM_FLUSH, cid),
        .nsid = 1,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr_lo = 0,
        .mptr_hi = 0,
        .prp1_lo = 0,
        .prp1_hi = 0,
        .prp2_lo = 0,
        .prp2_hi = 0,
        .cdw10 = 0,
        .cdw11 = 0,
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    });
}

fn doRead(slba: u64, nlb: u32, prp1: u64) u16 {
    const cid = nextCmdId();
    return submitIO(NvmeSqe{
        .cdw0 = makeCdw0(NVM_READ, cid),
        .nsid = 1,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr_lo = 0,
        .mptr_hi = 0,
        .prp1_lo = @truncate(prp1),
        .prp1_hi = @truncate(prp1 >> 32),
        .prp2_lo = 0,
        .prp2_hi = 0,
        .cdw10 = @truncate(slba),
        .cdw11 = @truncate(slba >> 32),
        .cdw12 = nlb - 1, // NLB is zero-based
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    });
}

fn doWrite(slba: u64, nlb: u32, prp1: u64) u16 {
    const cid = nextCmdId();
    return submitIO(NvmeSqe{
        .cdw0 = makeCdw0(NVM_WRITE, cid),
        .nsid = 1,
        .cdw2 = 0,
        .cdw3 = 0,
        .mptr_lo = 0,
        .mptr_hi = 0,
        .prp1_lo = @truncate(prp1),
        .prp1_hi = @truncate(prp1 >> 32),
        .prp2_lo = 0,
        .prp2_hi = 0,
        .cdw10 = @truncate(slba),
        .cdw11 = @truncate(slba >> 32),
        .cdw12 = nlb - 1,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    });
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn queryCurrentNode(bs: *const lib.BootstrapDescriptor, token: u64, scratch_phys: u64, scratch_va: u64, endpoint: u64) ?lib.Ipv6Addr {
    return lib.queryCurrentNode(bs, token, scratch_phys, scratch_va, endpoint);
}

/// Background I/O watchdog thread (spawned by umain after NVMe init).
/// Runs as "storaged/1" in the scheduler.  Emits a periodic heartbeat so
/// operators can confirm the storage service is alive during long I/O drains.
fn ioWatchdogLoop() noreturn {
    lib.serialWrite("storaged: io-watchdog starting\n");
    var tick: u32 = 0;
    while (true) {
        tick += 1;
        if (tick >= 50_000) {
            tick = 0;
            lib.serialWrite("storaged: io-watchdog alive\n");
        }
        _ = lib.syscall(lib.SYS_YIELD, 0, 0, g_token);
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            asm volatile ("pause");
        }
    }
}

pub export fn umain() noreturn {
    const bs_desc: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    if (bs_desc.magic != 0x53565442) while (true) asm volatile ("hlt");
    g_token = bs_desc.capability_token;

    lib.serialWrite("storaged: starting\n");

    // Register storaged endpoint immediately so DIPC senders can reach us
    // regardless of whether NVMe hardware is present.
    _ = lib.syscall(SYS_REGISTER, 0, bs_desc.reserved_storaged_endpoint, g_token);
    lib.serialWrite("storaged: registered\n");

    // ----- PCI scan for NVMe (class=0x01, subclass=0x08, prog_if=0x02) -----
    var nvme_bus: u8 = 0;
    var nvme_dev: u8 = 0;
    var nvme_func: u8 = 0;
    var found = false;
    outer: {
        var bus: u8 = 0;
        while (bus < 1) : (bus += 1) {
            var dev: u8 = 0;
            while (dev < 32) : (dev += 1) {
                if (pciRead(bus, dev, 0, 0, 4, g_token) & 0xFFFF == 0xFFFF) continue;
                var func: u8 = 0;
                while (func < 8) : (func += 1) {
                    const vid_did = @as(u32, @truncate(pciRead(bus, dev, func, 0, 4, g_token)));
                    if (vid_did == 0xFFFFFFFF) continue;
                    // Class code register at offset 0x08 (4 bytes): rev | prog_if | subclass | class
                    const class_raw = @as(u32, @truncate(pciRead(bus, dev, func, 0x08, 4, g_token)));
                    const class_byte = @as(u8, @truncate(class_raw >> 24));
                    const sub_byte = @as(u8, @truncate(class_raw >> 16));
                    const prog_byte = @as(u8, @truncate(class_raw >> 8));
                    if (class_byte == 0x01 and sub_byte == 0x08 and prog_byte == 0x02) {
                        nvme_bus = bus;
                        nvme_dev = dev;
                        nvme_func = func;
                        found = true;
                        break :outer;
                    }
                }
            }
        }
    }

    if (!found) {
        lib.serialWrite("storaged: no NVMe found; block requests will fail\n");
        // Allocate a DIPC scratch page for sending responses.
        const scratch_phys = lib.syscall(SYS_ALLOC_DMA, 1, 5, g_token);
        if (scratch_phys == 0) {
            lib.serialWrite("storaged: scratch alloc failed; idle\n");
            while (true) asm volatile ("pause");
        }
        g_dipc_scratch_phys = scratch_phys;
        lib.serialWrite("storaged: entering unavailable-device event loop\n");
        while (true) {
            const page_phys = lib.syscall(SYS_RECV, 0, 0, g_token);
            if (page_phys == 0) {
                _ = lib.syscall(lib.SYS_YIELD, 0, 0, g_token);
                asm volatile ("pause");
                continue;
            }
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, g_token);
            if (recv_va == 0) {
                _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, g_token);
                continue;
            }
            const incoming_hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
            var req_type2: u32 = std.math.maxInt(u32);
            var vmid2: u32 = 0;
            var chain_head2: u16 = 0;
            if (incoming_hdr.payload_len == @sizeOf(BlkRequest)) {
                const request: *align(1) const BlkRequest = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
                req_type2 = request.req_type;
                vmid2 = request.vmid;
                chain_head2 = request.chain_head;
            }
            if (req_type2 == BLK_ATTACH_VM_DISK or req_type2 == BLK_DETACH_VM_DISK) {
                _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, g_token);
                continue;
            }
            const reply_dst = incoming_hdr.src;
            const local_node2 = lib.Ipv6Addr.loopback();
            const scratch2: [*]u8 = lib.ptrFrom([*]u8, DIPC_SCRATCH_VA);
            const hdr2: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch2));
            hdr2.* = .{
                .magic = lib.WireMagic,
                .version = lib.WireVersion,
                .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
                .payload_len = @as(u32, @intCast(@sizeOf(lib.ControlHeader) + @sizeOf(lib.VirtioBlkResponsePayload))),
                .auth_tag = 0,
                .src = .{ .node = local_node2, .endpoint = bs_desc.reserved_storaged_endpoint },
                .dst = reply_dst,
            };
            const ctrl2: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch2) + lib.DIPC_HEADER_SIZE);
            ctrl2.* = .{
                .op = .virtio_blk_response,
                .payload_len = @as(u32, @intCast(@sizeOf(lib.VirtioBlkResponsePayload))),
            };
            const resp2: *align(1) lib.VirtioBlkResponsePayload = @ptrFromInt(@intFromPtr(scratch2) + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
            resp2.* = .{ .vmid = vmid2, .head_idx = chain_head2, .status = 1 };
            _ = lib.syscall(SYS_SEND_PAGE, g_dipc_scratch_phys, 0, g_token);
            _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, g_token);
        }
    }
    lib.serialWrite("storaged: NVMe at dev=");
    printHex(nvme_dev);
    lib.serialWrite("\n");

    // ----- Enable PCI bus-mastering for DMA -----
    const cmd = @as(u16, @truncate(pciRead(nvme_bus, nvme_dev, nvme_func, 0x04, 2, g_token)));
    pciWrite(nvme_bus, nvme_dev, nvme_func, 0x04, 2, cmd | 0x0006, g_token); // bus-master + mem-space

    // ----- Read 64-bit BAR0 -----
    const bar0_lo = @as(u32, @truncate(pciRead(nvme_bus, nvme_dev, nvme_func, 0x10, 4, g_token)));
    const bar0_hi = @as(u32, @truncate(pciRead(nvme_bus, nvme_dev, nvme_func, 0x14, 4, g_token)));
    const bar0_type = (bar0_lo >> 1) & 0x3;
    const bar0_phys: u64 = if (bar0_type == 2)
        // 64-bit BAR
        (@as(u64, bar0_hi) << 32) | (@as(u64, bar0_lo) & ~@as(u64, 0xF))
    else
        @as(u64, bar0_lo) & ~@as(u64, 0xF);
    lib.serialWrite("storaged: NVMe BAR0=");
    printHex(bar0_phys);
    lib.serialWrite("\n");

    // Map BAR0 (2 pages = 8 KB covers registers + doorbells for 2 queues).
    if (lib.syscall(SYS_MAP_IO, bar0_phys, 2, g_token) == 0) {
        lib.serialWrite("storaged: MAP_IO failed\n");
        while (true) asm volatile ("pause");
    }

    // ----- Allocate DMA for queue memory -----
    g_adm_sq_phys = lib.syscall(SYS_ALLOC_DMA, 1, 0, g_token);
    g_adm_cq_phys = lib.syscall(SYS_ALLOC_DMA, 1, 1, g_token);
    g_io_sq_phys = lib.syscall(SYS_ALLOC_DMA, 1, 2, g_token);
    g_io_cq_phys = lib.syscall(SYS_ALLOC_DMA, 1, 3, g_token);
    g_data_buf_phys = lib.syscall(SYS_ALLOC_DMA, 1, 4, g_token);
    g_dipc_scratch_phys = lib.syscall(SYS_ALLOC_DMA, 1, 5, g_token);
    if (g_adm_sq_phys == 0 or g_adm_cq_phys == 0 or g_io_sq_phys == 0 or
        g_io_cq_phys == 0 or g_data_buf_phys == 0 or g_dipc_scratch_phys == 0)
    {
        lib.serialWrite("storaged: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    // ----- Disable + reset controller -----
    nvmeW32(NVME_REG_CC, nvmeR32(NVME_REG_CC) & ~NVME_CC_EN);
    {
        var t: u32 = 100_000;
        while (nvmeR32(NVME_REG_CSTS) & NVME_CSTS_RDY != 0 and t > 0) : (t -= 1) spinPauseWithYield(t);
    }

    // ----- Configure admin queues -----
    nvmeW64(NVME_REG_ASQ, g_adm_sq_phys);
    nvmeW64(NVME_REG_ACQ, g_adm_cq_phys);
    // AQA: (ACQS-1)<<16 | (ASQS-1) where ACQS = ASQS = ADM_Q_DEPTH
    nvmeW32(NVME_REG_AQA, ((@as(u32, ADM_Q_DEPTH) - 1) << 16) | (@as(u32, ADM_Q_DEPTH) - 1));

    // ----- Enable controller -----
    const cc: u32 = NVME_CC_EN | NVME_CC_CSS_NVM | NVME_CC_MPS_4K | NVME_CC_IOSQES_64 | NVME_CC_IOCQES_16;
    nvmeW32(NVME_REG_CC, cc);
    {
        var t: u32 = 2_000_000;
        while (nvmeR32(NVME_REG_CSTS) & NVME_CSTS_RDY == 0 and t > 0) : (t -= 1) spinPauseWithYield(t);
    }
    if (nvmeR32(NVME_REG_CSTS) & NVME_CSTS_RDY == 0) {
        lib.serialWrite("storaged: controller did not become ready\n");
        while (true) asm volatile ("pause");
    }
    lib.serialWrite("storaged: controller ready\n");

    // ----- Identify Controller -----
    const sts_ctrl = cmdIdentifyController();
    if (sts_ctrl != 0) {
        lib.serialWrite("storaged: Identify Controller failed\n");
    } else {
        const identify: [*]const u8 = lib.ptrFrom([*]const u8, DATA_BUF_VA);
        g_controller_identified = true;
        g_volatile_write_cache = identify[525] & 1 != 0;
        lib.serialWrite("storaged: Identify Controller OK\n");
        lib.serialWrite(if (g_volatile_write_cache)
            "storaged: NVMe volatile write cache present\n"
        else
            "storaged: NVMe reports no volatile write cache\n");
    }

    // ----- Identify Namespace 1 -----
    const sts_ns = cmdIdentifyNamespace();
    if (sts_ns == 0) {
        // NSZE is at offset 0 of identify namespace data (8 bytes, LE)
        const buf: [*]const u8 = lib.ptrFrom([*]const u8, DATA_BUF_VA);
        g_ns_lba_count = @as(u64, buf[0]) | (@as(u64, buf[1]) << 8) | (@as(u64, buf[2]) << 16) |
            (@as(u64, buf[3]) << 24) | (@as(u64, buf[4]) << 32) | (@as(u64, buf[5]) << 40) |
            (@as(u64, buf[6]) << 48) | (@as(u64, buf[7]) << 56);
        lib.serialWrite("storaged: NS LBA count=");
        printHex(g_ns_lba_count);
        lib.serialWrite("\n");
    }

    // ----- Create IO Completion Queue 1 -----
    if (cmdCreateIOCQ() != 0) {
        lib.serialWrite("storaged: create IOCQ failed\n");
        while (true) asm volatile ("pause");
    }

    // ----- Create IO Submission Queue 1 -----
    if (cmdCreateIOSQ() != 0) {
        lib.serialWrite("storaged: create IOSQ failed\n");
        while (true) asm volatile ("pause");
    }
    lib.serialWrite("storaged: IO queues ready\n");

    // Spawn background I/O watchdog thread using DMA slot 7 as its stack.
    const wd_stack_phys = lib.syscall(SYS_ALLOC_DMA, 1, 7, g_token);
    if (wd_stack_phys != 0) {
        const wd_stack_top: u64 = DMA_BASE_VA + 8 * PAGE_SIZE;
        const tid = lib.spawnThread(&ioWatchdogLoop, wd_stack_top, g_token);
        if (tid != 0xFFFFFFFF) {
            lib.serialWrite("storaged: io-watchdog thread spawned tid=");
            printHex(tid);
            lib.serialWrite("\n");
        } else {
            lib.serialWrite("storaged: io-watchdog spawn failed\n");
        }
    } else {
        lib.serialWrite("storaged: io-watchdog stack alloc failed\n");
    }

    lib.serialWrite("storaged: entering event loop\n");

    // ----- Main event loop -----
    while (true) {
        // Receive a DIPC block IO request.
        const page_phys = lib.syscall(SYS_RECV, 0, 0, g_token);
        if (page_phys == 0) {
            _ = lib.syscall(lib.SYS_YIELD, 0, 0, g_token);
            asm volatile ("pause");
            continue;
        }

        const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, g_token);
        if (recv_va == 0) {
            _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, g_token);
            continue;
        }

        lib.serialWrite("storaged: received block IO request\n");

        const incoming_hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
        var req_type: u32 = std.math.maxInt(u32);
        var sector: u64 = 0;
        var vmid: u32 = 0;
        var chain_head: u16 = 0;
        var data_len: u16 = 0;
        var data_hpa: u64 = 0;
        const request_envelope_valid = incoming_hdr.magic == lib.WireMagic and
            incoming_hdr.version == lib.WireVersion and
            incoming_hdr.header_len == lib.DIPC_HEADER_SIZE and
            incoming_hdr.dst.endpoint == bs_desc.reserved_storaged_endpoint and
            incoming_hdr.payload_len == @sizeOf(BlkRequest);
        if (request_envelope_valid) {
            const request: *align(1) const BlkRequest = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
            req_type = request.req_type;
            sector = request.sector;
            vmid = request.vmid;
            chain_head = request.chain_head;
            data_len = request.data_len;
            data_hpa = request.data_hpa;
        }
        const loopback = lib.Ipv6Addr.loopback();
        const dst_node_valid = isLoopbackOrLinkLocal(&incoming_hdr.dst.node.bytes);
        if (request_envelope_valid and dst_node_valid and
            (req_type == BLK_ATTACH_VM_DISK or req_type == BLK_DETACH_VM_DISK))
        {
            if (isAuthorizedVmDiskAdmin(incoming_hdr.src.endpoint, &incoming_hdr.src.node.bytes)) {
                if (req_type == BLK_ATTACH_VM_DISK) {
                    if (attachVmDisk(&g_vm_disks, vmid, sector, @as(u64, data_len))) {
                        lib.serialWrite("storaged: per-VM disk attached\n");
                    } else {
                        lib.serialWrite("storaged: per-VM disk attach rejected\n");
                    }
                } else {
                    if (detachVmDisk(&g_vm_disks, vmid)) {
                        lib.serialWrite("storaged: per-VM disk detached\n");
                    }
                }
            } else {
                lib.serialWrite("storaged: unauthorized VM disk control request\n");
            }
            _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, g_token);
            continue;
        }

        const is_host_metadata = request_envelope_valid and
            std.mem.eql(u8, &incoming_hdr.dst.node.bytes, &loopback.bytes) and
            isAuthorizedBlockClient(
                incoming_hdr.src.endpoint,
                vmid,
                &incoming_hdr.src.node.bytes,
            );
        const is_vm_io = request_envelope_valid and
            std.mem.eql(u8, &incoming_hdr.dst.node.bytes, &loopback.bytes) and
            isAuthorizedVmIoClient(
                &g_vm_disks,
                incoming_hdr.src.endpoint,
                vmid,
                &incoming_hdr.src.node.bytes,
            );

        var io_status: u8 = 1;
        if (is_host_metadata or is_vm_io) {
            if (req_type == 4) {
                if (data_len == 0 and data_hpa == 0 and doFlush() == 0) io_status = 0;
            } else if ((req_type == 0 or req_type == 1 or req_type == BLK_WRITE_FUA) and data_len > 0 and
                @as(u64, data_len) % SECTOR_SIZE == 0 and @as(u64, data_len) <= PAGE_SIZE and data_hpa != 0 and
                @as(u64, data_len) <= PAGE_SIZE - (data_hpa & (PAGE_SIZE - 1)))
            {
                const nlb = @as(u32, data_len) / SECTOR_SIZE;
                const target_lba: ?u64 = if (is_host_metadata)
                    (if (isHostMetadataRange(sector, nlb)) sector else null)
                else
                    translateAttachedVmSector(&g_vm_disks, vmid, sector, nlb);
                if (target_lba) |resolved_lba| {
                    if (resolved_lba < g_ns_lba_count and nlb <= g_ns_lba_count - resolved_lba) {
                        if (req_type == 0) {
                            const read_status = doRead(resolved_lba, nlb, data_hpa);
                            if (read_status == 0) {
                                io_status = 0;
                            } else {
                                lib.serialWrite("storaged: NVMe read completion status=");
                                printHex(read_status);
                                lib.serialWrite("\n");
                            }
                        } else if (doWrite(resolved_lba, nlb, data_hpa) == 0) {
                            if (req_type != BLK_WRITE_FUA or doFlush() == 0) {
                                io_status = 0;
                                if (req_type == BLK_WRITE_FUA) lib.serialWrite("storaged: FUA write+flush completed\n");
                            }
                        }
                    }
                }
            }
        }
        if (io_status != 0) {
            lib.serialWrite("storaged: block request failed type=");
            printHex(req_type);
            lib.serialWrite(" sector=");
            printHex(sector);
            lib.serialWrite(" bytes=");
            printHex(data_len);
            lib.serialWrite(" buffer=");
            printHex(data_hpa);
            lib.serialWrite("\n");
        }

        const scratch: [*]u8 = lib.ptrFrom([*]u8, DIPC_SCRATCH_VA);
        const reply_dst = incoming_hdr.src;
        const local_node = lib.Ipv6Addr.loopback();

        const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
        header.* = .{
            .magic = lib.WireMagic,
            .version = lib.WireVersion,
            .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
            .payload_len = @as(u32, @intCast(@sizeOf(lib.ControlHeader) + @sizeOf(lib.VirtioBlkResponsePayload))),
            .auth_tag = 0,
            .src = .{ .node = local_node, .endpoint = bs_desc.reserved_storaged_endpoint },
            .dst = reply_dst,
        };

        const control: *align(1) lib.ControlHeader = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
        control.* = .{
            .op = .virtio_blk_response,
            .payload_len = @as(u32, @intCast(@sizeOf(lib.VirtioBlkResponsePayload))),
        };

        const response: *align(1) lib.VirtioBlkResponsePayload = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
        response.* = .{
            .vmid = vmid,
            .head_idx = chain_head,
            .status = io_status,
        };

        // If it was a read, we need to send the data back too.
        // For simplicity in Phase 6, we assume the VMM bridge mapped the guest physical page
        // into storaged's DMA window if it wanted us to read INTO it, but actually doRead
        // uses data_hpa which is a Host Physical Address.
        // storaged (Ring 3) cannot access arbitrary HPA unless mapped.
        // However, the current kernel implementation of SYS_SEND_PAGE/SYS_RECV
        // for DIPC handles the page contents.
        // Virtio-Blk uses the data_hpa directly in doRead/doWrite which are NVMe IO commands.
        // The NVMe controller DMA's directly to/from that HPA.

        _ = lib.syscall(SYS_SEND_PAGE, g_dipc_scratch_phys, 0, g_token);

        // Free the received DIPC page.
        _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, g_token);
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
