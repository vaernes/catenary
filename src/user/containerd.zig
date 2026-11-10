const std = @import("std");
const lib = @import("lib.zig");
const partition_metadata = @import("protocols/partition_metadata.zig");
const storage_protocol = @import("protocols/storaged_protocol.zig");

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
const PART_VMID: u32 = storage_protocol.HOST_METADATA_VMID;
const MAX_PARTS = partition_metadata.MAX_PARTS;
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

const PartState = enum {
    journal_reading,
    journal_replaying,
    journal_clearing,
    journal_writing,
    journal_flushing,
    journal_clear_flushing,
    scanning,
    priming,
    priming_flushing,
    idle,
    writing,
    flushing,
    verifying,
    done,
};
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

fn isStorageReplyEnvelope(
    page: *align(1) const lib.PageHeader,
    control: *align(1) const lib.ControlHeader,
) bool {
    const loopback = lib.Ipv6Addr.loopback();
    return page.magic == lib.WireMagic and page.version == lib.WireVersion and
        page.header_len == lib.DIPC_HEADER_SIZE and
        page.payload_len == lib.CONTROL_HEADER_SIZE + @sizeOf(lib.VirtioBlkResponsePayload) and
        page.src.endpoint == @backingInt(lib.ReservedEndpoint.storaged) and
        page.dst.endpoint == @backingInt(lib.ReservedEndpoint.containerd) and
        std.mem.eql(u8, &page.src.node.bytes, &loopback.bytes) and
        std.mem.eql(u8, &page.dst.node.bytes, &loopback.bytes) and
        @as(*align(1) const u16, @ptrCast(&control.op)).* == @backingInt(lib.ControlOp.virtio_blk_response) and
        control._reserved == 0 and control.payload_len == @sizeOf(lib.VirtioBlkResponsePayload);
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
        lib.serialWrite("containerd: smoke block WRITE SUCCESS!\n");
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

    const local_node = lib.Ipv6Addr.loopback();
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
    const journal_phys = lib.syscall(SYS_ALLOC_DMA, 1, 3, token);
    if (journal_phys == 0) {
        lib.serialWrite("containerd: journal DMA allocation failed\n");
        while (true) {
            _ = lib.syscall(lib.SYS_YIELD, 0, 0, token);
        }
    }

    var part_state: PartState = .journal_reading;
    var part_slot: u32 = 0;
    var scan_slot: u32 = 0;
    var journal_recovery_pending_scan = false;
    if (!sendTrackedBlkRequest(
        dipc_phys,
        token,
        local_node,
        container_endpoint,
        bs.reserved_storaged_endpoint,
        0,
        partition_metadata.JOURNAL_LBA,
        verify_phys,
        512,
        &request_sequence,
        &pending_request_id,
    )) {
        lib.serialWrite("containerd: initial journal read send failed, will retry\n");
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
                        .journal_reading => .{ .req_type = 0, .sector = partition_metadata.JOURNAL_LBA, .data_phys = verify_phys, .data_len = 512 },
                        .journal_replaying => .{ .req_type = BLK_WRITE_FUA, .sector = partitionStart(part_slot), .data_phys = data_phys, .data_len = 512 },
                        .journal_clearing => .{ .req_type = BLK_WRITE_FUA, .sector = partition_metadata.JOURNAL_LBA, .data_phys = journal_phys, .data_len = 512 },
                        .journal_writing => .{ .req_type = BLK_WRITE_FUA, .sector = partition_metadata.JOURNAL_LBA, .data_phys = journal_phys, .data_len = 512 },
                        .journal_flushing => .{ .req_type = 4, .sector = partition_metadata.JOURNAL_LBA, .data_phys = 0, .data_len = 0 },
                        .journal_clear_flushing => .{ .req_type = 4, .sector = partition_metadata.JOURNAL_LBA, .data_phys = 0, .data_len = 0 },
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

        // Once the smoke write is acknowledged, commit a partition-header
        // transaction through the reserved write-ahead journal sector.
        if (write_completed and part_state == .idle) {
            if (allocPartition()) |slot| {
                part_slot = slot;
                const journal_va: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA + 3 * 4096);
                @memcpy(journal_va[0..512], &partition_metadata.makeJournalSector(slot, 1));
                const hdr_va: *align(1) PartitionHeader = lib.ptrFrom(*align(1) PartitionHeader, DMA_BASE_VA);
                @memset(lib.ptrFrom([*]u8, DMA_BASE_VA)[0..512], 0);
                hdr_va.* = partition_metadata.makeHeader(slot);
                part_state = .journal_writing;
                pending_request_id = 0;
                _ = sendTrackedBlkRequest(
                    dipc_phys,
                    token,
                    local_node,
                    container_endpoint,
                    bs.reserved_storaged_endpoint,
                    BLK_WRITE_FUA,
                    partition_metadata.JOURNAL_LBA,
                    journal_phys,
                    512,
                    &request_sequence,
                    &pending_request_id,
                );
                lib.serialWrite("containerd: partition journal intent write requested\n");
            } else {
                part_state = .done;
                lib.serialWrite("containerd: no free partitions\n");
            }
        }

        const page_phys = lib.syscall(SYS_TRY_RECV, 0, 0, token);
        if (page_phys != 0) {
            const recv_va = lib.syscall(SYS_MAP_RECV, page_phys, 0, token);
            if (recv_va != 0) {
                const page_header: *align(1) const lib.PageHeader = @ptrFromInt(recv_va);
                const control: *align(1) const lib.ControlHeader = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE);
                if (isStorageReplyEnvelope(page_header, control)) {
                    const response: *align(1) const lib.VirtioBlkResponsePayload = @ptrFromInt(recv_va + lib.DIPC_HEADER_SIZE + @sizeOf(lib.ControlHeader));
                    if (response.vmid == PART_VMID and response.head_idx == pending_request_id) {
                        part_wait_ticks = 0;
                        part_retries = 0;
                        pending_request_id = 0;
                        if (response.status != 0) {
                            if (part_state == .journal_reading) {
                                lib.serialWrite("containerd: partition journal read failed\n");
                            } else if (part_state == .scanning) {
                                lib.serialWrite("containerd: partition metadata read failed at slot ");
                                printHex(scan_slot);
                                lib.serialWrite("\n");
                            }
                            lib.serialWrite("containerd: block I/O FAILED\n");
                            part_state = .done;
                        } else switch (part_state) {
                            .journal_reading => {
                                const verify: [*]const u8 = lib.ptrFrom([*]const u8, DMA_BASE_VA + 2 * 4096);
                                if (partition_metadata.readJournalRecord(verify[0..512])) |record| {
                                    part_slot = record.slot;
                                    journal_recovery_pending_scan = true;
                                    const replay_data_va: [*]u8 = lib.ptrFrom([*]u8, DMA_BASE_VA);
                                    @memset(replay_data_va[0..512], 0);
                                    @memcpy(replay_data_va[0..@sizeOf(PartitionHeader)], std.mem.asBytes(&record.header));
                                    part_state = .journal_replaying;
                                    _ = sendTrackedBlkRequest(
                                        dipc_phys,
                                        token,
                                        local_node,
                                        container_endpoint,
                                        bs.reserved_storaged_endpoint,
                                        BLK_WRITE_FUA,
                                        partitionStart(part_slot),
                                        data_phys,
                                        512,
                                        &request_sequence,
                                        &pending_request_id,
                                    );
                                } else if (partition_metadata.isEmptySector(verify[0..512])) {
                                    part_state = .scanning;
                                    scan_slot = 0;
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
                                    lib.serialWrite("containerd: invalid partition journal; refusing metadata recovery\n");
                                    part_state = .done;
                                }
                            },
                            .journal_replaying => {
                                lib.serialWrite("containerd: journal recovery replayed slot ");
                                printHex(part_slot);
                                lib.serialWrite("\n");
                                @memset(lib.ptrFrom([*]u8, DMA_BASE_VA + 3 * 4096)[0..512], 0);
                                part_state = .journal_clearing;
                                _ = sendTrackedBlkRequest(
                                    dipc_phys,
                                    token,
                                    local_node,
                                    container_endpoint,
                                    bs.reserved_storaged_endpoint,
                                    BLK_WRITE_FUA,
                                    partition_metadata.JOURNAL_LBA,
                                    journal_phys,
                                    512,
                                    &request_sequence,
                                    &pending_request_id,
                                );
                            },
                            .journal_writing => {
                                part_state = .journal_flushing;
                                _ = sendTrackedBlkRequest(
                                    dipc_phys,
                                    token,
                                    local_node,
                                    container_endpoint,
                                    bs.reserved_storaged_endpoint,
                                    4,
                                    partition_metadata.JOURNAL_LBA,
                                    0,
                                    0,
                                    &request_sequence,
                                    &pending_request_id,
                                );
                            },
                            .journal_flushing => {
                                part_state = .writing;
                                _ = sendTrackedBlkRequest(
                                    dipc_phys,
                                    token,
                                    local_node,
                                    container_endpoint,
                                    bs.reserved_storaged_endpoint,
                                    BLK_WRITE_FUA,
                                    partitionStart(part_slot),
                                    data_phys,
                                    512,
                                    &request_sequence,
                                    &pending_request_id,
                                );
                            },
                            .journal_clearing => {
                                part_state = .journal_clear_flushing;
                                _ = sendTrackedBlkRequest(
                                    dipc_phys,
                                    token,
                                    local_node,
                                    container_endpoint,
                                    bs.reserved_storaged_endpoint,
                                    4,
                                    partition_metadata.JOURNAL_LBA,
                                    0,
                                    0,
                                    &request_sequence,
                                    &pending_request_id,
                                );
                            },
                            .journal_clear_flushing => {
                                if (journal_recovery_pending_scan) {
                                    journal_recovery_pending_scan = false;
                                    lib.serialWrite("containerd: journal recovery complete\n");
                                    part_state = .scanning;
                                    scan_slot = 0;
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
                                    lib.serialWrite("containerd: partition journal cleared\n");
                                    part_state = .done;
                                }
                            },
                            .scanning => {
                                const verify: [*]const u8 = lib.ptrFrom([*]const u8, DMA_BASE_VA + 2 * 4096);
                                if (partition_metadata.isValidHeader(verify[0..512], scan_slot)) {
                                    part_used[scan_slot] = true;
                                    lib.serialWrite("containerd: recovered partition metadata\n");
                                } else if (!partition_metadata.isEmptySector(verify[0..512])) {
                                    lib.serialWrite("containerd: invalid partition metadata; refusing slot reuse\n");
                                    lib.serialWrite("containerd: invalid metadata slot ");
                                    printHex(scan_slot);
                                    lib.serialWrite("\n");
                                    part_state = .done;
                                }
                                if (part_state != .done) {
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
                                const verify: [*]const u8 = lib.ptrFrom([*]const u8, DMA_BASE_VA + 2 * 4096);
                                if (partition_metadata.isValidHeader(verify[0..512], part_slot)) {
                                    lib.serialWrite("containerd: partition header verified after flush\n");
                                    @memset(lib.ptrFrom([*]u8, DMA_BASE_VA + 3 * 4096)[0..512], 0);
                                    part_state = .journal_clearing;
                                    _ = sendTrackedBlkRequest(
                                        dipc_phys,
                                        token,
                                        local_node,
                                        container_endpoint,
                                        bs.reserved_storaged_endpoint,
                                        BLK_WRITE_FUA,
                                        partition_metadata.JOURNAL_LBA,
                                        journal_phys,
                                        512,
                                        &request_sequence,
                                        &pending_request_id,
                                    );
                                } else {
                                    lib.serialWrite("containerd: partition verify MISMATCH\n");
                                    part_state = .done;
                                }
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

test "host storage replies require the local storaged endpoint" {
    var page = lib.PageHeader{
        .magic = lib.WireMagic,
        .version = lib.WireVersion,
        .header_len = @intCast(lib.DIPC_HEADER_SIZE),
        .payload_len = lib.CONTROL_HEADER_SIZE + @sizeOf(lib.VirtioBlkResponsePayload),
        .auth_tag = 0,
        .src = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @backingInt(lib.ReservedEndpoint.storaged) },
        .dst = .{ .node = lib.Ipv6Addr.loopback(), .endpoint = @backingInt(lib.ReservedEndpoint.containerd) },
    };
    var control = lib.ControlHeader{ .op = .virtio_blk_response, .payload_len = @sizeOf(lib.VirtioBlkResponsePayload) };
    try std.testing.expect(isStorageReplyEnvelope(&page, &control));
    page.src.node.bytes[0] = 0xFE;
    try std.testing.expect(!isStorageReplyEnvelope(&page, &control));
    page.src.node = lib.Ipv6Addr.loopback();
    page.src.endpoint = @backingInt(lib.ReservedEndpoint.netd);
    try std.testing.expect(!isStorageReplyEnvelope(&page, &control));
    page.src.endpoint = @backingInt(lib.ReservedEndpoint.storaged);
    page.payload_len -= 1;
    try std.testing.expect(!isStorageReplyEnvelope(&page, &control));
    page.payload_len += 1;
    const op: *align(1) u16 = @ptrCast(&control.op);
    op.* = 0xFFFF;
    try std.testing.expect(!isStorageReplyEnvelope(&page, &control));
}
