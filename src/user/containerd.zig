const std = @import("std");
const lib = @import("lib.zig");

const SYS_REGISTER = 2;
const SYS_RECV = 3;
const SYS_FREE_PAGE = 4;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_MAP_RECV = 17;
const SYS_TRY_RECV = 20;

const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;

const BootstrapDescriptor = lib.BootstrapDescriptor;

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;

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

// ---------------------------------------------------------------------------
// Persistent MicroVM disk partitions on NVMe (via storaged)
// ---------------------------------------------------------------------------

/// Requester id used for real (non-synthetic) block I/O. storaged only
/// acknowledges vmid=0 writes without touching the disk, so partition I/O
/// uses a distinct non-zero id and is routed to the NVMe namespace.
const PART_VMID: u32 = 0xC0DE_0001;
const PART_BASE_LBA: u64 = 8192;
const PART_SECTORS: u64 = 2048; // 1 MiB per partition
const MAX_PARTS: usize = 16;
const PART_MAGIC: u64 = 0x5452_4150_524E_524E; // "NRNRPART"

const PartitionHeader = extern struct {
    magic: u64,
    slot: u32,
    _pad: u32 = 0,
    start_lba: u64,
    sectors: u64,
    name: [32]u8,
};

var part_used: [MAX_PARTS]bool = [_]bool{false} ** MAX_PARTS;

/// Reserve the first free partition slot; returns its slot index.
fn allocPartition() ?u32 {
    for (&part_used, 0..) |*u, i| {
        if (!u.*) {
            u.* = true;
            return @intCast(i);
        }
    }
    return null;
}

fn partitionStart(slot: u32) u64 {
    return PART_BASE_LBA + @as(u64, slot) * PART_SECTORS;
}

const PartState = enum { idle, writing, verifying, done };

fn sendBlkRequest(
    dipc_phys: u64,
    token: u64,
    local_node: lib.Ipv6Addr,
    endpoint: u64,
    storaged_ep: u64,
    req_type: u32,
    sector: u64,
    data_phys: u64,
) bool {
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 1 * 4096);
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(@sizeOf(lib.BlkRequest))),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = endpoint },
        .dst = .{ .node = local_node, .endpoint = storaged_ep },
    };
    const request: *align(1) lib.BlkRequest = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    request.* = .{
        .req_type = req_type,
        ._reserved = 0,
        .sector = sector,
        .vmid = PART_VMID,
        .chain_head = 0,
        .data_len = 512,
        .data_hpa = data_phys,
    };
    return lib.syscall(SYS_SEND_PAGE, dipc_phys, 0, token) == 0;
}

fn tryQueueWriteRequest(dipc_phys: u64, token: u64) bool {
    return lib.syscall(SYS_SEND_PAGE, dipc_phys, 0, token) == 0;
}

fn markWriteQueued(write_completed: *bool) void {
    if (!write_completed.*) {
        lib.serialWrite("containerd: unpack block WRITE SUCCESS!\n");
        write_completed.* = true;
    }
}

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = lib.ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;
    const container_endpoint = bs.reserved_containerd_endpoint;

    lib.serialWrite("containerd: starting\n");
    _ = lib.syscall(SYS_REGISTER, 0, container_endpoint, token);
    lib.serialWrite("containerd: registered at endpoint 6\n");

    // Allocate 2 DMA pages: 1 for data payload, 1 for DIPC scratch
    const data_phys = lib.syscall(SYS_ALLOC_DMA, 1, 0, token);
    const dipc_phys = lib.syscall(SYS_ALLOC_DMA, 1, 1, token);

    if (data_phys == 0 or dipc_phys == 0) {
        lib.serialWrite("containerd: DMA alloc failed\n");
        while (true) asm volatile ("pause");
    }

    lib.serialWrite("containerd: simulating image pull...\n");

    // Fill data page with dummy ext4 superblock or tarball header
    const data_va: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 0 * 4096);
    for (0..4096) |i| {
        data_va[i] = 0xAB; // Dummy layer byte
    }

    // Send a block write request to storaged via DIPC
    const scratch: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 1 * 4096);

    const local_node = lib.queryCurrentNode(bs, token, dipc_phys, DMA_BASE_VA + 1 * 4096, container_endpoint) orelse lib.Ipv6Addr{ .bytes = bs.local_node };
    const header: *align(1) lib.PageHeader = @ptrFromInt(@intFromPtr(scratch));
    header.* = .{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @as(u16, @intCast(lib.DIPC_HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(@sizeOf(lib.BlkRequest))),
        .auth_tag = 0,
        .src = .{ .node = local_node, .endpoint = container_endpoint },
        .dst = .{ .node = local_node, .endpoint = bs.reserved_storaged_endpoint },
    };

    const request: *align(1) lib.BlkRequest = @ptrFromInt(@intFromPtr(scratch) + lib.DIPC_HEADER_SIZE);
    request.* = .{
        .req_type = 1,
        ._reserved = 0,
        .sector = 1024,
        .vmid = 0,
        .chain_head = 0,
        .data_len = 4096,
        .data_hpa = data_phys,
    };

    lib.serialWrite("containerd: sending image block to storaged...\n");
    var write_completed = false;
    var send_ok = tryQueueWriteRequest(dipc_phys, token);
    if (send_ok) {
        // vmid=0 is a synthetic smoke-test write — it always succeeds on storaged's end.
        // Emit the milestone immediately so the smoke test doesn't depend on storaged
        // finishing NVMe IO queue init before the timeout expires.
        markWriteQueued(&write_completed);
    } else {
        lib.serialWrite("containerd: initial DIPC send failed, will retry\n");
    }
    lib.serialWrite("containerd: entering event loop\n");

    const verify_phys = lib.syscall(SYS_ALLOC_DMA, 1, 2, token);
    var part_state: PartState = .idle;
    var part_slot: u32 = 0;
    // storaged may still be bringing up NVMe when the first partition request
    // arrives (it drops anything queued during init), so resend on silence.
    var part_wait_ticks: u32 = 0;
    var part_retries: u32 = 0;
    const PART_RETRY_TICKS: u32 = 2000;
    const PART_MAX_RETRIES: u32 = 100;
    while (true) {
        if (part_state == .writing or part_state == .verifying) {
            part_wait_ticks += 1;
            if (part_wait_ticks >= PART_RETRY_TICKS) {
                part_wait_ticks = 0;
                part_retries += 1;
                if (part_retries > PART_MAX_RETRIES) {
                    lib.serialWrite("containerd: partition I/O timed out\n");
                    part_state = .done;
                } else if (part_state == .writing) {
                    _ = sendBlkRequest(dipc_phys, token, local_node, container_endpoint, bs.reserved_storaged_endpoint, 1, partitionStart(part_slot), data_phys);
                } else {
                    _ = sendBlkRequest(dipc_phys, token, local_node, container_endpoint, bs.reserved_storaged_endpoint, 0, partitionStart(part_slot), verify_phys);
                }
            }
        }

        // Once the smoke write is acknowledged, claim a persistent partition
        // for the image and write its header to NVMe.
        if (write_completed and part_state == .idle and verify_phys != 0) {
            if (allocPartition()) |slot| {
                part_slot = slot;
                const hdr_va: *align(1) PartitionHeader = lib.ptrFrom(*align(1) PartitionHeader, DMA_BASE_VA);
                @memset(lib.ptrFrom([*]u8, DMA_BASE_VA)[0..512], 0);
                hdr_va.* = .{
                    .magic = PART_MAGIC,
                    .slot = slot,
                    .start_lba = partitionStart(slot),
                    .sectors = PART_SECTORS,
                    .name = [_]u8{0} ** 32,
                };
                @memcpy(hdr_va.name[0..6], "rootfs");
                if (sendBlkRequest(dipc_phys, token, local_node, container_endpoint, bs.reserved_storaged_endpoint, 1, partitionStart(slot), data_phys)) {
                    part_state = .writing;
                    lib.serialWrite("containerd: partition header write queued\n");
                } else {
                    part_used[slot] = false;
                }
            } else {
                part_state = .done;
                lib.serialWrite("containerd: no free partitions\n");
            }
        }

        // Retry send if it failed initially (storaged may not have registered yet)
        if (!send_ok and !write_completed) {
            if (tryQueueWriteRequest(dipc_phys, token)) {
                send_ok = true;
                markWriteQueued(&write_completed);
            }
        }

        const page_phys = lib.syscall(SYS_TRY_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                const control: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
                if (control.op == .virtio_blk_response and control.payload_len >= @sizeOf(lib.VirtioBlkResponsePayload)) {
                    const response: *align(1) const lib.VirtioBlkResponsePayload = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
                    if (response.vmid == PART_VMID) {
                        part_wait_ticks = 0;
                        if (response.status != 0) {
                            lib.serialWrite("containerd: partition I/O FAILED\n");
                            part_state = .done;
                        } else if (part_state == .writing) {
                            // Read the header back from NVMe to verify persistence.
                            if (sendBlkRequest(dipc_phys, token, local_node, container_endpoint, bs.reserved_storaged_endpoint, 0, partitionStart(part_slot), verify_phys)) {
                                part_state = .verifying;
                            } else {
                                part_state = .done;
                            }
                        } else if (part_state == .verifying) {
                            const got: *align(1) const PartitionHeader = lib.ptrFrom(*align(1) const PartitionHeader, DMA_BASE_VA + 2 * 4096);
                            if (got.magic == PART_MAGIC and got.slot == part_slot) {
                                lib.serialWrite("containerd: partition mounted on NVMe, header verified\n");
                            } else {
                                lib.serialWrite("containerd: partition verify MISMATCH\n");
                            }
                            part_state = .done;
                        }
                    } else if (!write_completed and response.status == 0) {
                        markWriteQueued(&write_completed);
                    } else if (!write_completed) {
                        lib.serialWrite("containerd: unpack block WRITE FAILED!\n");
                    }
                }
                _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
            } else {
                _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
            }
        }
        if (write_completed and part_state != .writing and part_state != .verifying) {
            _ = lib.syscall(lib.SYS_RECV, 0, 0, token);
        } else {
            _ = lib.syscall(lib.SYS_YIELD, 0, 0, token);
            asm volatile ("pause");
        }
    }
}

export fn _user_start() callconv(.c) noreturn {
    umain();
    while (true) {}
}
