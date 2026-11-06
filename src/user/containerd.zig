const std = @import("std");
const lib = @import("lib.zig");
const partition_metadata = @import("protocols/partition_metadata.zig");

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

/// Host-local block requests use a nonzero ID so responses can be correlated.
const PART_VMID: u32 = 0xC0DE_0001;
const PART_SECTORS = partition_metadata.PART_SECTORS;
const MAX_PARTS = partition_metadata.MAX_PARTS;
const PART_MAGIC = partition_metadata.PART_MAGIC;
const BLK_WRITE_FUA: u32 = @backingInt(lib.BlkReqType.write_fua);

const PartitionHeader = partition_metadata.Header;

var part_used: [MAX_PARTS]bool = @splat(false);

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
    return partition_metadata.startLba(slot);
}

const PartState = enum { scanning, priming, priming_flushing, idle, writing, flushing, verifying, done };
const BlkRetry = struct {
    req_type: u32,
    sector: u64,
    data_phys: u64,
    data_len: u16,
};

fn sendBlkRequest(
    dipc_phys: u64,
    token: u64,
    local_node: lib.Ipv6Addr,
    endpoint: u64,
    storaged_ep: u64,
    req_type: u32,
    sector: u64,
    data_phys: u64,
    data_len: u16,
    request_id: u16,
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
        .chain_head = request_id,
        .data_len = data_len,
        .data_hpa = data_phys,
    };
    return lib.syscall(SYS_SEND_PAGE, dipc_phys, 0, token) == 0;
}

fn sendTrackedBlkRequest(
    dipc_phys: u64,
    token: u64,
    local_node: lib.Ipv6Addr,
    endpoint: u64,
    storaged_ep: u64,
    req_type: u32,
    sector: u64,
    data_phys: u64,
    data_len: u16,
    request_sequence: *u16,
    pending_request_id: *u16,
) bool {
    request_sequence.* +%= 1;
    if (request_sequence.* == 0) request_sequence.* = 1;
    if (!sendBlkRequest(
        dipc_phys,
        token,
        local_node,
        endpoint,
        storaged_ep,
        req_type,
        sector,
        data_phys,
        data_len,
        request_sequence.*,
    )) return false;
    pending_request_id.* = request_sequence.*;
    return true;
}

fn markWriteCompleted(write_completed: *bool) void {
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

    const local_node = lib.queryCurrentNode(bs, token, dipc_phys, DMA_BASE_VA + 1 * 4096, container_endpoint) orelse lib.Ipv6Addr{ .bytes = bs.local_node };
    lib.serialWrite("containerd: sending image block to storaged...\n");
    var write_completed = false;
    var request_sequence: u16 = 0;
    var pending_request_id: u16 = 0;
    const verify_phys = lib.syscall(SYS_ALLOC_DMA, 1, 2, token);
    if (verify_phys == 0) {
        lib.serialWrite("containerd: partition scan DMA allocation failed\n");
        while (true) {
            _ = lib.syscall(lib.SYS_YIELD, 0, 0, token);
        }
    }

    var part_state: PartState = .scanning;
    var part_slot: u32 = 0;
    var scan_slot: u32 = 0;
    if (!sendTrackedBlkRequest(
        dipc_phys,
        token,
        local_node,
        container_endpoint,
        bs.reserved_storaged_endpoint,
        0,
        partitionStart(scan_slot),
        verify_phys,
        512,
        &request_sequence,
        &pending_request_id,
    )) {
        lib.serialWrite("containerd: initial partition scan send failed, will retry\n");
    }
    lib.serialWrite("containerd: entering event loop\n");

    var part_wait_ticks: u32 = 0;
    var part_retries: u32 = 0;
    const PART_RETRY_TICKS: u32 = 2000;
    const PART_MAX_RETRIES: u32 = 100;
    while (true) {
        if (part_state != .idle and part_state != .done) {
            part_wait_ticks += 1;
            if (part_wait_ticks >= PART_RETRY_TICKS) {
                part_wait_ticks = 0;
                part_retries += 1;
                if (part_retries > PART_MAX_RETRIES) {
                    lib.serialWrite("containerd: storage I/O timed out\n");
                    part_state = .done;
                } else {
                    const retry: BlkRetry = switch (part_state) {
                        .scanning => .{ .req_type = 0, .sector = partitionStart(scan_slot), .data_phys = verify_phys, .data_len = 512 },
                        .priming => .{ .req_type = BLK_WRITE_FUA, .sector = 1024, .data_phys = data_phys, .data_len = 4096 },
                        .priming_flushing => .{ .req_type = 4, .sector = 1024, .data_phys = 0, .data_len = 0 },
                        .flushing => .{ .req_type = 4, .sector = partitionStart(part_slot), .data_phys = 0, .data_len = 0 },
                        .writing => .{ .req_type = BLK_WRITE_FUA, .sector = partitionStart(part_slot), .data_phys = data_phys, .data_len = 512 },
                        .verifying => .{ .req_type = 0, .sector = partitionStart(part_slot), .data_phys = verify_phys, .data_len = 512 },
                        .idle, .done => unreachable,
                    };
                    _ = sendTrackedBlkRequest(
                        dipc_phys,
                        token,
                        local_node,
                        container_endpoint,
                        bs.reserved_storaged_endpoint,
                        retry.req_type,
                        retry.sector,
                        retry.data_phys,
                        retry.data_len,
                        &request_sequence,
                        &pending_request_id,
                    );
                }
            }
        }

        // Once the smoke write is acknowledged, claim a persistent partition
        // for the image and write its header to NVMe.
        if (write_completed and part_state == .idle) {
            if (allocPartition()) |slot| {
                part_slot = slot;
                const hdr_va: *align(1) PartitionHeader = lib.ptrFrom(*align(1) PartitionHeader, DMA_BASE_VA);
                @memset(lib.ptrFrom([*]u8, DMA_BASE_VA)[0..512], 0);
                hdr_va.* = .{
                    .magic = PART_MAGIC,
                    .slot = slot,
                    .start_lba = partitionStart(slot),
                    .sectors = PART_SECTORS,
                    .name = @splat(0),
                };
                @memcpy(hdr_va.name[0..6], "rootfs");
                part_slot = slot;
                part_state = .writing;
                pending_request_id = 0;
                _ = sendTrackedBlkRequest(
                    dipc_phys,
                    token,
                    local_node,
                    container_endpoint,
                    bs.reserved_storaged_endpoint,
                    BLK_WRITE_FUA,
                    partitionStart(slot),
                    data_phys,
                    512,
                    &request_sequence,
                    &pending_request_id,
                );
                lib.serialWrite("containerd: partition header write requested\n");
            } else {
                part_state = .done;
                lib.serialWrite("containerd: no free partitions\n");
            }
        }

        const page_phys = lib.syscall(SYS_TRY_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                const control: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
                if (control.op == .virtio_blk_response and control.payload_len >= @sizeOf(lib.VirtioBlkResponsePayload)) {
                    const response: *align(1) const lib.VirtioBlkResponsePayload = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
                    if (response.vmid == PART_VMID and response.head_idx == pending_request_id) {
                        part_wait_ticks = 0;
                        part_retries = 0;
                        pending_request_id = 0;
                        if (response.status != 0) {
                            if (part_state == .scanning) {
                                lib.serialWrite("containerd: partition metadata read failed at slot ");
                                printHex(scan_slot);
                                lib.serialWrite("\n");
                            }
                            lib.serialWrite("containerd: block I/O FAILED\n");
                            part_state = .done;
                        } else switch (part_state) {
                            .scanning => {
                                const verify: [*]const u8 = lib.ptrFrom([*]const u8, DMA_BASE_VA + 2 * 4096);
                                if (partition_metadata.isValidHeader(verify[0..512], scan_slot)) {
                                    part_used[scan_slot] = true;
                                    lib.serialWrite("containerd: recovered partition metadata\n");
                                }
                                scan_slot += 1;
                                if (scan_slot < MAX_PARTS) {
                                    _ = sendTrackedBlkRequest(
                                        dipc_phys,
                                        token,
                                        local_node,
                                        container_endpoint,
                                        bs.reserved_storaged_endpoint,
                                        0,
                                        partitionStart(scan_slot),
                                        verify_phys,
                                        512,
                                        &request_sequence,
                                        &pending_request_id,
                                    );
                                } else {
                                    lib.serialWrite("containerd: partition metadata scan complete\n");
                                    part_state = .priming;
                                    _ = sendTrackedBlkRequest(
                                        dipc_phys,
                                        token,
                                        local_node,
                                        container_endpoint,
                                        bs.reserved_storaged_endpoint,
                                        1,
                                        1024,
                                        data_phys,
                                        4096,
                                        &request_sequence,
                                        &pending_request_id,
                                    );
                                }
                            },
                            .priming => {
                                part_state = .priming_flushing;
                                _ = sendTrackedBlkRequest(
                                    dipc_phys,
                                    token,
                                    local_node,
                                    container_endpoint,
                                    bs.reserved_storaged_endpoint,
                                    4,
                                    1024,
                                    0,
                                    0,
                                    &request_sequence,
                                    &pending_request_id,
                                );
                            },
                            .priming_flushing => {
                                markWriteCompleted(&write_completed);
                                part_state = .idle;
                            },
                            .writing => {
                                part_state = .flushing;
                                _ = sendTrackedBlkRequest(
                                    dipc_phys,
                                    token,
                                    local_node,
                                    container_endpoint,
                                    bs.reserved_storaged_endpoint,
                                    4,
                                    partitionStart(part_slot),
                                    0,
                                    0,
                                    &request_sequence,
                                    &pending_request_id,
                                );
                            },
                            .flushing => {
                                part_state = .verifying;
                                _ = sendTrackedBlkRequest(
                                    dipc_phys,
                                    token,
                                    local_node,
                                    container_endpoint,
                                    bs.reserved_storaged_endpoint,
                                    0,
                                    partitionStart(part_slot),
                                    verify_phys,
                                    512,
                                    &request_sequence,
                                    &pending_request_id,
                                );
                            },
                            .verifying => {
                                const got: *align(1) const PartitionHeader = lib.ptrFrom(*align(1) const PartitionHeader, DMA_BASE_VA + 2 * 4096);
                                if (got.magic == PART_MAGIC and got.slot == part_slot) {
                                    lib.serialWrite("containerd: partition mounted on NVMe, header verified after flush\n");
                                } else {
                                    lib.serialWrite("containerd: partition verify MISMATCH\n");
                                }
                                part_state = .done;
                            },
                            .idle, .done => {},
                        }
                    }
                }
                _ = lib.syscall(SYS_FREE_PAGE, DIPC_RECV_VA, 0, token);
            } else {
                _ = lib.syscall(SYS_FREE_PAGE, page_phys, 0, token);
            }
        }
        if (part_state == .done) {
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
