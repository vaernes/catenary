const std = @import("std");

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

    /// Per-VM telemetry sample. Sent by the local dashd to the local clusterd
    /// (node_addr zero), which stamps its node address and multicasts it; peer
    /// clusterd instances forward it to their local dashd.
    /// Payload: dashd_protocol.ClusterTelemetryUpdate.
    telemetry_report = 8,

    /// Peer enrollment request for mutual cluster authentication.
    /// Payload: EnrollmentPayload.
    enrollment_request = 9,

    /// Response to enrollment request.
    /// Payload: EnrollmentAck.
    enrollment_ack = 10,

    /// Administrative or quorum fence message to quarantine a node or epoch.
    /// Payload: FencePayload.
    fence_node_request = 11,

    /// Acknowledgement of fence command.
    /// Payload: FenceAck.
    fence_node_ack = 12,

    /// Monotonic authenticated heartbeat ping.
    /// Payload: HeartbeatPayload.
    heartbeat_ping = 13,

    /// Heartbeat response.
    /// Payload: HeartbeatPayload.
    heartbeat_pong = 14,

    /// Candidate requests vote in leader election.
    /// Payload: RequestVotePayload.
    consensus_request_vote = 15,

    /// Response to consensus_request_vote.
    /// Payload: RequestVoteReplyPayload.
    consensus_request_vote_reply = 16,

    /// Leader consensus heartbeat / commit sync.
    /// Payload: ConsensusHeartbeatPayload.
    consensus_heartbeat = 17,

    /// Follower consensus heartbeat acknowledgement.
    /// Payload: ConsensusHeartbeatReplyPayload.
    consensus_heartbeat_reply = 18,
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
    entries: [MAX_RESOURCE_SNAPSHOT_ENTRIES]ResourceSnapshotEntry = @splat(.{
        .node_addr = @splat(0),
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
    }),
};

/// Op.vm_list_reply — compact VM snapshot list for dashboard queries.
pub const VmEntry = extern struct {
    instance_id: u32,
    state: u8,
    _pad: [3]u8 = @splat(0),
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

// ---------------------------------------------------------------------------
// Phase 15: Node Enrollment, Authentication, and Fencing Epochs
// ---------------------------------------------------------------------------

pub const NodeRole = enum(u16) {
    unassigned = 0,
    primary = 1,
    follower = 2,
    learner = 3,
    fenced = 4,
};

pub const EnrollmentPayload = extern struct {
    node_id: u32,
    role: NodeRole = .learner,
    epoch: u64,
    seq: u64,
    genesis_hash: [32]u8,
    public_key: [32]u8,
    signature: [32]u8,
};

pub const EnrollmentAck = extern struct {
    node_id: u32,
    accepted: bool,
    _pad: [3]u8 = @splat(0),
    assigned_role: NodeRole,
    cluster_epoch: u64,
};

pub const FencePayload = extern struct {
    target_node_id: u32,
    _pad0: u32 = 0,
    fencing_epoch: u64,
    fencing_seq: u64,
    reason: [32]u8,
    signature: [32]u8,
};

pub const FenceAck = extern struct {
    target_node_id: u32,
    success: bool,
    _pad: [3]u8 = @splat(0),
    active_epoch: u64,
};

pub const HeartbeatPayload = extern struct {
    sender_node_id: u32,
    _pad0: u32 = 0,
    epoch: u64,
    seq: u64,
    timestamp: u64,
    signature: [32]u8,
};

pub const ReplayValidationError = error{
    StaleEpoch,
    ReplayDetected,
    InvalidSignature,
    NodeFenced,
};

pub fn computeAuthSignature(secret: []const u8, epoch: u64, seq: u64, node_id: u32) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("CATENARY-CLUSTER-AUTH-V1");
    hasher.update(secret);
    hasher.update(std.mem.asBytes(&epoch));
    hasher.update(std.mem.asBytes(&seq));
    hasher.update(std.mem.asBytes(&node_id));
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn validateMessageReplay(
    current_epoch: *u64,
    last_seq: *u64,
    incoming_epoch: u64,
    incoming_seq: u64,
) ReplayValidationError!void {
    if (incoming_epoch < current_epoch.*) {
        return error.StaleEpoch;
    }
    if (incoming_epoch == current_epoch.*) {
        if (incoming_seq <= last_seq.*) {
            return error.ReplayDetected;
        }
        last_seq.* = incoming_seq;
    } else {
        // Advanced epoch: reset sequence tracking to new baseline
        current_epoch.* = incoming_epoch;
        last_seq.* = incoming_seq;
    }
}

pub const ConsensusRole = enum(u16) {
    follower = 0,
    candidate = 1,
    leader = 2,
    quarantined = 3,
};

pub const RequestVotePayload = extern struct {
    term: u64,
    candidate_node_id: u32,
    _pad0: u32 = 0,
    last_log_term: u64,
    last_log_index: u64,
    signature: [32]u8,
};

pub const RequestVoteReplyPayload = extern struct {
    term: u64,
    voter_node_id: u32,
    vote_granted: bool,
    _pad: [3]u8 = @splat(0),
    signature: [32]u8,
};

pub const ConsensusHeartbeatPayload = extern struct {
    term: u64,
    leader_node_id: u32,
    commit_index: u32,
    fencing_epoch: u64,
    seq: u64,
    signature: [32]u8,
};

pub const ConsensusHeartbeatReplyPayload = extern struct {
    term: u64,
    follower_node_id: u32,
    success: bool,
    _pad: [3]u8 = @splat(0),
    match_index: u32,
    signature: [32]u8,
};

pub const ConsensusState = struct {
    role: ConsensusRole = .follower,
    current_term: u64 = 0,
    voted_for: ?u32 = null,
    leader_node_id: ?u32 = null,
    cluster_size: u32 = 3,
    votes_granted: u32 = 0,
    commit_index: u32 = 0,
    fencing_epoch: u64 = 0,
    timer_ticks: u32 = 0,

    pub fn quorum(self: *const ConsensusState) u32 {
        return (self.cluster_size / 2) + 1;
    }

    pub fn hasQuorum(self: *const ConsensusState) bool {
        return self.votes_granted >= self.quorum();
    }

    pub fn startElection(self: *ConsensusState, local_id: u32) void {
        self.role = .candidate;
        self.current_term += 1;
        self.voted_for = local_id;
        self.votes_granted = 1; // self vote
        self.leader_node_id = null;
        self.timer_ticks = 0;
    }

    pub fn handleVoteReply(self: *ConsensusState, reply: *align(1) const RequestVoteReplyPayload) bool {
        if (reply.term > self.current_term) {
            self.current_term = reply.term;
            self.role = .follower;
            self.voted_for = null;
            self.votes_granted = 0;
            return false;
        }
        if (self.role == .candidate and reply.term == self.current_term and reply.vote_granted) {
            self.votes_granted += 1;
            if (self.hasQuorum()) {
                self.role = .leader;
                self.leader_node_id = self.voted_for;
                self.fencing_epoch += 1; // advance fencing epoch on new leadership
                return true;
            }
        }
        return false;
    }

    pub fn handleVoteRequest(self: *ConsensusState, req: *align(1) const RequestVotePayload, _: u32) bool {
        if (req.term < self.current_term) return false;
        if (req.term > self.current_term) {
            self.current_term = req.term;
            self.role = .follower;
            self.voted_for = null;
            self.votes_granted = 0;
        }
        // If equal term and both are candidates, tie-break in favor of higher candidate_node_id
        if (self.role == .candidate and req.term == self.current_term and self.voted_for != null) {
            if (req.candidate_node_id > self.voted_for.?) {
                self.role = .follower;
                self.voted_for = req.candidate_node_id;
                self.votes_granted = 0;
                self.timer_ticks = 0;
                return true;
            }
        }
        if (self.voted_for == null or self.voted_for.? == req.candidate_node_id) {
            self.voted_for = req.candidate_node_id;
            self.timer_ticks = 0;
            return true;
        }
        return false;
    }

    pub fn handleHeartbeat(self: *ConsensusState, hb: *align(1) const ConsensusHeartbeatPayload) bool {
        if (hb.term < self.current_term) return false;
        if (hb.term > self.current_term or self.role == .candidate) {
            self.current_term = hb.term;
            self.role = .follower;
            self.voted_for = null;
            self.votes_granted = 0;
        }
        self.leader_node_id = hb.leader_node_id;
        if (hb.fencing_epoch > self.fencing_epoch) {
            self.fencing_epoch = hb.fencing_epoch;
        }
        self.timer_ticks = 0;
        return true;
    }
};

test "clusterd_protocol: signature verification, sequence replay, and epoch advancement" {
    const std_test = @import("std").testing;
    const secret = "catenary-cluster-master-secret";

    // 1. Signature validity
    const sig1 = computeAuthSignature(secret, 1, 100, 2);
    const sig2 = computeAuthSignature(secret, 1, 100, 2);
    try std_test.expectEqual(sig1, sig2);

    const sig_tampered = computeAuthSignature("wrong-secret", 1, 100, 2);
    try std_test.expect(!std.mem.eql(u8, &sig1, &sig_tampered));

    // 2. Monotonic replay check within same epoch
    var epoch: u64 = 1;
    var last_seq: u64 = 100;

    // Normal increment
    try validateMessageReplay(&epoch, &last_seq, 1, 101);
    try std_test.expectEqual(@as(u64, 101), last_seq);

    // Replay of same sequence rejected
    try std_test.expectError(error.ReplayDetected, validateMessageReplay(&epoch, &last_seq, 1, 101));

    // Earlier sequence rejected
    try std_test.expectError(error.ReplayDetected, validateMessageReplay(&epoch, &last_seq, 1, 99));

    // 3. Stale epoch rejected
    try std_test.expectError(error.StaleEpoch, validateMessageReplay(&epoch, &last_seq, 0, 500));

    // 4. Advanced epoch accepted and resets sequence tracking
    try validateMessageReplay(&epoch, &last_seq, 2, 1);
    try std_test.expectEqual(@as(u64, 2), epoch);
    try std_test.expectEqual(@as(u64, 1), last_seq);

    // Monotonic within new epoch
    try validateMessageReplay(&epoch, &last_seq, 2, 2);
    try std_test.expectEqual(@as(u64, 2), last_seq);
}

test "clusterd_protocol: consensus quorum, election, and term step-down" {
    const std_test = @import("std").testing;
    var state = ConsensusState{
        .cluster_size = 3,
    };
    try std_test.expectEqual(@as(u32, 2), state.quorum());
    try std_test.expectEqual(ConsensusRole.follower, state.role);

    // 1. Candidate start election
    state.startElection(1);
    try std_test.expectEqual(ConsensusRole.candidate, state.role);
    try std_test.expectEqual(@as(u64, 1), state.current_term);
    try std_test.expectEqual(@as(u32, 1), state.votes_granted);
    try std_test.expect(!state.hasQuorum());

    // 2. Stale vote reply rejected
    const stale_reply = RequestVoteReplyPayload{
        .term = 0,
        .voter_node_id = 2,
        .vote_granted = true,
        .signature = @splat(0),
    };
    try std_test.expect(!state.handleVoteReply(&stale_reply));
    try std_test.expectEqual(@as(u32, 1), state.votes_granted);

    // 3. Quorum-granting vote reply from Node 2 (2 of 3 votes)
    const valid_reply = RequestVoteReplyPayload{
        .term = 1,
        .voter_node_id = 2,
        .vote_granted = true,
        .signature = @splat(0),
    };
    try std_test.expect(state.handleVoteReply(&valid_reply));
    try std_test.expectEqual(ConsensusRole.leader, state.role);
    try std_test.expectEqual(@as(?u32, 1), state.leader_node_id);
    try std_test.expectEqual(@as(u64, 1), state.fencing_epoch);

    // 4. Discovering higher term in heartbeat causes step-down to follower
    const higher_hb = ConsensusHeartbeatPayload{
        .term = 2,
        .leader_node_id = 3,
        .commit_index = 0,
        .fencing_epoch = 2,
        .seq = 1,
        .signature = @splat(0),
    };
    try std_test.expect(state.handleHeartbeat(&higher_hb));
    try std_test.expectEqual(ConsensusRole.follower, state.role);
    try std_test.expectEqual(@as(u64, 2), state.current_term);
    try std_test.expectEqual(@as(?u32, 3), state.leader_node_id);
    try std_test.expectEqual(@as(u64, 2), state.fencing_epoch);

    // 5. Candidate tie-break on equal terms favors higher candidate ID
    state.startElection(1);
    try std_test.expectEqual(ConsensusRole.candidate, state.role);
    try std_test.expectEqual(@as(u64, 3), state.current_term);

    // Request from candidate with higher ID (2 > 1) wins vote and steps down candidate 1
    const peer_candidate_req = RequestVotePayload{
        .term = 3,
        .candidate_node_id = 2,
        .last_log_term = 0,
        .last_log_index = 0,
        .signature = @splat(0),
    };
    try std_test.expect(state.handleVoteRequest(&peer_candidate_req, 1));
    try std_test.expectEqual(ConsensusRole.follower, state.role);
    try std_test.expectEqual(@as(?u32, 2), state.voted_for);
}

