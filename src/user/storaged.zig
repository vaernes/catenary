/// storaged — NVMe PCI driver + DIPC block-I/O handler.
///
/// Syscall ABI: rax=op, rbx=arg0, rdx=arg1, r8=token.
const std = @import("std");
const lib = @import("lib.zig");


// ---------------------------------------------------------------------------
// Low-level serial + lib.syscall interface (same convention as netd.zig)
// ---------------------------------------------------------------------------

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        lib.outb(0x3F8, hex[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
}


const SYS_LOG = 1;
const SYS_REGISTER = 2;
const SYS_RECV = 3;
const SYS_FREE_PAGE = 4;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_MAP_IO = 7;
const SYS_MAP_RECV = 17;

const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;
const IO_WINDOW_VA: u64 = 0x0000_7E00_0000_0000;
const PAGE_SIZE: u64 = 4096;

// PCI config read/write via kernel lib.syscalls
fn pciRead(bus: u8, dev: u8, func: u8, off: u8, size: u8, token: u64) u64 {
    const addr = (@as(u64, bus) << 24) | (@as(u64, dev) << 16) | (@as(u64, func) << 8) | @as(u64, off);
    return lib.syscall(13, addr, @as(u64, size) << 32, token);
}
fn pciWrite(bus: u8, dev: u8, func: u8, off: u8, size: u8, val: u32, token: u64) void {
    const addr = (@as(u64, bus) << 24) | (@as(u64, dev) << 16) | (@as(u64, func) << 8) | @as(u64, off);
    _ = lib.syscall(14, addr, (@as(u64, size) << 32) | val, token);
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

// Lba size (LBA = logical block address, a 512-byte sector).
const SECTOR_SIZE: u32 = 512;

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
    adminSqDoorbell(g_adm_sq_tail);

    // Poll CQ until we see a completion with the correct phase bit.
    const cq: [*]volatile NvmeCqe = lib.ptrFrom([*]volatile NvmeCqe, ADM_CQ_VA);
    var timeout: u64 = 20_000_000;
    while (timeout > 0) : (timeout -= 1) {
        const entry = &cq[@as(usize, g_adm_cq_head % ADM_Q_DEPTH)];
        const phase: u1 = @truncate(entry.status & 1);
        if (phase == g_adm_cq_phase) {
            const status = (entry.status >> 1) & 0x7FFF;
            g_adm_cq_head +%= 1;
            if (g_adm_cq_head % ADM_Q_DEPTH == 0) g_adm_cq_phase ^= 1;
            adminCqDoorbell(g_adm_cq_head);
            return @truncate(status);
        }
        asm volatile ("pause");
    }
    return 0xFFFF; // timeout
}

fn submitIO(sqe: NvmeSqe) u16 {
    const sq: [*]NvmeSqe = lib.ptrFrom([*]NvmeSqe, IO_SQ_VA);
    sq[@as(usize, g_io_sq_tail % IO_Q_DEPTH)] = sqe;
    g_io_sq_tail +%= 1;
    ioSqDoorbell(g_io_sq_tail);

    const cq: [*]volatile NvmeCqe = lib.ptrFrom([*]volatile NvmeCqe, IO_CQ_VA);
    var timeout: u32 = 10_000_000;
    while (timeout > 0) : (timeout -= 1) {
        const entry = &cq[@as(usize, g_io_cq_head % IO_Q_DEPTH)];
        const phase: u1 = @truncate(entry.status & 1);
        if (phase == g_io_cq_phase) {
            const status = (entry.status >> 1) & 0x7FFF;
            g_io_cq_head +%= 1;
            if (g_io_cq_head % IO_Q_DEPTH == 0) g_io_cq_phase ^= 1;
            ioCqDoorbell(g_io_cq_head);
            return @truncate(status);
        }
        asm volatile ("pause");
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

pub export fn umain() noreturn {
    const bs_desc: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    if (bs_desc.magic != 0x53565442) while (true) asm volatile ("hlt");
    g_token = bs_desc.capability_token;

    lib.serialWrite("storaged: starting\n");
    _ = lib.syscall(SYS_REGISTER, 0, bs_desc.reserved_storaged_endpoint, g_token);
    lib.serialWrite("storaged: registered\n");

    // ----- PCI scan for NVMe (class=0x01, subclass=0x08, prog_if=0x02) -----
    var nvme_bus: u8 = 0;
    var nvme_dev: u8 = 0;
    var nvme_func: u8 = 0;
    var found = false;
    outer: {
        var bus: u8 = 0;
        while (bus < 8) : (bus += 1) {
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
        lib.serialWrite("storaged: no NVMe found; idle\n");
        while (true) asm volatile ("pause");
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
        while (nvmeR32(NVME_REG_CSTS) & NVME_CSTS_RDY != 0 and t > 0) t -= 1;
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
        while (nvmeR32(NVME_REG_CSTS) & NVME_CSTS_RDY == 0 and t > 0) t -= 1;
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
        lib.serialWrite("storaged: Identify Controller OK\n");
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

    // ----- Main event loop -----
    while (true) {
        // Receive a DIPC block IO request.
        const page_phys = lib.syscall(SYS_RECV, 0, 0, g_token);
        if (page_phys == 0) {
            asm volatile ("pause");
            continue;
        }

        const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, g_token);
        if (recv_va == 0) {
            _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, g_token);
            continue;
        }

        const request: *align(1) const BlkRequest = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
        const req_type = request.req_type;
        const sector = request.sector;
        const vmid = request.vmid;
        const chain_head = request.chain_head;
        const data_len = request.data_len;
        const data_hpa = request.data_hpa;

        var io_status: u8 = 1; // 1 = error by default
        const nlb: u32 = if (data_len >= 512) @as(u32, data_len) / 512 else 1;

        if (req_type == 0) { // VIRTIO_BLK_T_IN — read
            if (sector < g_ns_lba_count) {
                const sts = doRead(sector, nlb, data_hpa);
                if (sts == 0) io_status = 0;
            }
        } else if (req_type == 1) { // VIRTIO_BLK_T_OUT — write
            if (sector < g_ns_lba_count) {
                const sts = doWrite(sector, nlb, data_hpa);
                if (sts == 0) io_status = 0;
            }
        } else if (req_type == 4) { // VIRTIO_BLK_T_FLUSH — no-op for now
            io_status = 0;
        }

        const scratch: [*]u8 = lib.ptrFrom([*]u8, DIPC_SCRATCH_VA);
        const incoming_hdr: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
        const local_node = lib.Ipv6Addr{ .bytes = bs_desc.local_node };

        const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
        header.* = .{
            .magic = lib.WireMagic,
            .version = lib.WireVersion,
            .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
            .payload_len = @as(u32, @intCast(@sizeOf(lib.ControlHeader) + @sizeOf(lib.VirtioBlkResponsePayload))),
            .auth_tag = 0,
            .src = .{ .node = local_node, .endpoint = bs_desc.reserved_storaged_endpoint },
            .dst = incoming_hdr.src,
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

        _ = lib.syscall(SYS_SEND_PAGE, g_dipc_scratch_phys, 0, g_token);

        // Free the received DIPC page.
        _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, g_token);
    }
}
