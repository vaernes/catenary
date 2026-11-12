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

    /// Leader replicated log entry append request.
    /// Payload: AppendEntriesPayload.
    append_entries = 19,

    /// Follower replicated log entry append reply.
    /// Payload: AppendEntriesReplyPayload.
    append_entries_reply = 20,

    /// Versioned RBAC management API request.
    /// Payload: MgmtRequest.
    mgmt_request = 21,

    /// Versioned RBAC management API response.
    /// Payload: MgmtResponse.
    mgmt_response = 22,
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

// ---------------------------------------------------------------------------
// Phase 17A: Replicated State Machine Log & Idempotent Cluster Mutations
// ---------------------------------------------------------------------------

pub const MutationOp = enum(u16) {
    vm_create = 1,
    vm_stop = 2,
    vm_migrate = 3,
    config_set = 4,
    fence_node = 5,
    role_grant = 6,
};

pub const IdempotencyKey = extern struct {
    caller_id: u32 = 0,
    _pad0: u32 = 0,
    client_seq: u64 = 0,
    body_hash: u64 = 0,
};

pub const LogEntry = extern struct {
    index: u32 = 0,
    op: MutationOp = .vm_create,
    _pad0: u16 = 0,
    term: u64 = 0,
    fencing_epoch: u64 = 0,
    idempotency: IdempotencyKey = .{},
    target_node_id: u32 = 0,
    vm_id: u32 = 0,
    payload: [32]u8 = @splat(0),
};

pub const AppendEntriesPayload = extern struct {
    term: u64,
    leader_node_id: u32,
    prev_log_index: u32,
    prev_log_term: u64,
    leader_commit: u32,
    entry_count: u32,
    entry: LogEntry,
    signature: [32]u8,
};

pub const AppendEntriesReplyPayload = extern struct {
    term: u64,
    follower_node_id: u32,
    success: bool,
    _pad: [3]u8 = @splat(0),
    match_index: u32,
    signature: [32]u8,
};

pub const ReconcileStatus = enum(u8) {
    accepted = 0,
    committed = 1,
    reconciling = 2,
    applied = 3,
    blocked = 4,
    failed = 5,
};

pub const MAX_LOG_ENTRIES: usize = 32;
pub const MAX_IDEMPOTENCY_CACHE: usize = 32;

pub const IdempotencyRecord = struct {
    used: bool = false,
    key: IdempotencyKey = .{},
    log_index: u32 = 0,
    status: ReconcileStatus = .accepted,
};

pub const ReplicatedStateMachine = struct {
    entries: [MAX_LOG_ENTRIES]LogEntry = @splat(.{}),
    log_len: u32 = 0,
    commit_index: u32 = 0,
    last_applied: u32 = 0,
    desired_revision: u64 = 0,
    observed_revision: u64 = 0,
    reconcile_status: ReconcileStatus = .applied,
    idempotency_cache: [MAX_IDEMPOTENCY_CACHE]IdempotencyRecord = @splat(.{}),
    cache_cursor: usize = 0,
    peer_match_index: [16]u32 = @splat(0),

    pub const ProposeError = error{
        LogFull,
        IdempotencyConflict,
    };

    pub const ProposeResult = struct {
        index: u32,
        reused: bool,
        status: ReconcileStatus,
    };

    pub fn lastLogIndex(self: *const ReplicatedStateMachine) u32 {
        return self.log_len;
    }

    pub fn lastLogTerm(self: *const ReplicatedStateMachine) u64 {
        if (self.log_len == 0) return 0;
        return self.entries[self.log_len - 1].term;
    }

    pub fn lookupIdempotency(self: *const ReplicatedStateMachine, key: IdempotencyKey) ?*const IdempotencyRecord {
        if (key.caller_id == 0 and key.client_seq == 0) return null;
        for (&self.idempotency_cache) |*rec| {
            if (rec.used and rec.key.caller_id == key.caller_id and rec.key.client_seq == key.client_seq) {
                return rec;
            }
        }
        return null;
    }

    fn recordIdempotency(self: *ReplicatedStateMachine, key: IdempotencyKey, log_index: u32, status: ReconcileStatus) void {
        if (key.caller_id == 0 and key.client_seq == 0) return;
        for (&self.idempotency_cache) |*rec| {
            if (rec.used and rec.key.caller_id == key.caller_id and rec.key.client_seq == key.client_seq) {
                rec.log_index = log_index;
                rec.status = status;
                return;
            }
        }
        self.idempotency_cache[self.cache_cursor] = .{
            .used = true,
            .key = key,
            .log_index = log_index,
            .status = status,
        };
        self.cache_cursor = (self.cache_cursor + 1) % MAX_IDEMPOTENCY_CACHE;
    }

    pub fn proposeMutation(
        self: *ReplicatedStateMachine,
        term: u64,
        fencing_epoch: u64,
        op: MutationOp,
        idempotency: IdempotencyKey,
        target_node_id: u32,
        vm_id: u32,
        payload: [32]u8,
    ) ProposeError!ProposeResult {
        if (self.lookupIdempotency(idempotency)) |existing| {
            if (existing.key.body_hash != idempotency.body_hash) {
                return error.IdempotencyConflict;
            }
            return .{
                .index = existing.log_index,
                .reused = true,
                .status = existing.status,
            };
        }
        if (self.log_len >= MAX_LOG_ENTRIES) return error.LogFull;

        const next_idx = self.log_len + 1;
        self.entries[self.log_len] = .{
            .index = next_idx,
            .op = op,
            .term = term,
            .fencing_epoch = fencing_epoch,
            .idempotency = idempotency,
            .target_node_id = target_node_id,
            .vm_id = vm_id,
            .payload = payload,
        };
        self.log_len = next_idx;
        self.reconcile_status = .accepted;
        self.recordIdempotency(idempotency, next_idx, .accepted);
        return .{
            .index = next_idx,
            .reused = false,
            .status = .accepted,
        };
    }

    pub fn handleAppendEntries(
        self: *ReplicatedStateMachine,
        consensus: *ConsensusState,
        req: *align(1) const AppendEntriesPayload,
    ) bool {
        if (req.term < consensus.current_term) return false;
        if (req.term > consensus.current_term or consensus.role == .candidate) {
            consensus.current_term = req.term;
            consensus.role = .follower;
            consensus.voted_for = null;
            consensus.votes_granted = 0;
        }
        consensus.leader_node_id = req.leader_node_id;
        consensus.timer_ticks = 0;

        if (req.prev_log_index > self.log_len) return false;
        if (req.prev_log_index > 0 and self.entries[req.prev_log_index - 1].term != req.prev_log_term) {
            return false;
        }

        if (req.entry_count > 0) {
            const idx = req.entry.index;
            if (idx == 0 or idx > MAX_LOG_ENTRIES) return false;
            self.entries[idx - 1] = req.entry;
            if (idx > self.log_len) {
                self.log_len = idx;
            }
            self.recordIdempotency(req.entry.idempotency, idx, .accepted);
        }

        if (req.leader_commit > self.commit_index) {
            const target = @min(req.leader_commit, self.log_len);
            self.commitUpTo(target);
        }
        return true;
    }

    pub fn handleAppendEntriesReply(
        self: *ReplicatedStateMachine,
        consensus: *ConsensusState,
        reply: *align(1) const AppendEntriesReplyPayload,
    ) bool {
        if (reply.term > consensus.current_term) {
            consensus.current_term = reply.term;
            consensus.role = .follower;
            consensus.voted_for = null;
            consensus.votes_granted = 0;
            return false;
        }
        if (consensus.role != .leader or reply.term != consensus.current_term or !reply.success) {
            return false;
        }

        const slot = reply.follower_node_id % 16;
        if (reply.match_index > self.peer_match_index[slot]) {
            self.peer_match_index[slot] = reply.match_index;
        }

        // Advance commit_index if quorum of nodes (leader + peers) have replicated up to n
        var n = self.log_len;
        while (n > self.commit_index) : (n -= 1) {
            if (self.entries[n - 1].term != consensus.current_term) continue;
            var acked: u32 = 1; // leader itself
            for (self.peer_match_index) |m| {
                if (m >= n) acked += 1;
            }
            if (acked >= consensus.quorum()) {
                self.commitUpTo(n);
                return true;
            }
        }
        return false;
    }

    pub fn commitUpTo(self: *ReplicatedStateMachine, target: u32) void {
        const clamped = @min(target, self.log_len);
        if (clamped <= self.commit_index) return;
        self.commit_index = clamped;
        while (self.last_applied < self.commit_index) {
            self.last_applied += 1;
            self.desired_revision += 1;
            const e = self.entries[self.last_applied - 1];
            self.recordIdempotency(e.idempotency, e.index, .committed);
        }
        self.reconcile_status = if (self.observed_revision >= self.desired_revision) .applied else .reconciling;
    }

    pub fn reconcileObserved(self: *ReplicatedStateMachine, observed_rev: u64) void {
        if (observed_rev > self.observed_revision) {
            self.observed_revision = observed_rev;
        }
        if (self.observed_revision >= self.desired_revision) {
            self.reconcile_status = .applied;
        } else {
            self.reconcile_status = .reconciling;
        }
    }
};

// ---------------------------------------------------------------------------
// Phase 17B: Node Failover, Lease Expiry & Storage Fencing
// ---------------------------------------------------------------------------

pub const FenceRecord = struct {
    used: bool = false,
    node_id: u32 = 0,
    fencing_epoch: u64 = 0,
    verified: bool = false,
};

pub const FenceTable = struct {
    records: [16]FenceRecord = @splat(.{}),
    active_fencing_epoch: u64 = 0,

    pub fn fenceNode(self: *FenceTable, node_id: u32, epoch: u64, verified: bool) void {
        if (epoch > self.active_fencing_epoch) {
            self.active_fencing_epoch = epoch;
        }
        for (&self.records) |*r| {
            if (r.used and r.node_id == node_id) {
                if (epoch >= r.fencing_epoch) {
                    r.fencing_epoch = epoch;
                    r.verified = verified;
                }
                return;
            }
        }
        for (&self.records) |*r| {
            if (!r.used) {
                r.* = .{
                    .used = true,
                    .node_id = node_id,
                    .fencing_epoch = epoch,
                    .verified = verified,
                };
                return;
            }
        }
    }

    pub fn isNodeFenced(self: *const FenceTable, node_id: u32) bool {
        for (&self.records) |*r| {
            if (r.used and r.node_id == node_id) return true;
        }
        return false;
    }

    pub fn isWriteAllowed(self: *const FenceTable, node_id: u32, req_epoch: u64, self_fenced: bool) bool {
        if (self_fenced) return false;
        if (req_epoch < self.active_fencing_epoch) return false;
        if (self.isNodeFenced(node_id)) return false;
        return true;
    }

    pub fn canFailoverWorkload(self: *const FenceTable, failed_node_id: u32, has_quorum: bool) bool {
        if (!has_quorum) return false;
        for (&self.records) |*r| {
            if (r.used and r.node_id == failed_node_id and r.verified) return true;
        }
        return false;
    }
};

pub const LeaseState = struct {
    lease_duration_ticks: u32 = 180,
    ticks_since_heartbeat: u32 = 0,
    ticks_without_quorum_ack: u32 = 0,
    self_fenced: bool = false,

    pub fn onHeartbeatReceived(self: *LeaseState) void {
        self.ticks_since_heartbeat = 0;
    }

    pub fn onQuorumAck(self: *LeaseState) void {
        self.ticks_without_quorum_ack = 0;
    }

    /// Returns true when follower lease expires and failover election should trigger.
    pub fn tickFollower(self: *LeaseState) bool {
        self.ticks_since_heartbeat +|= 1;
        return self.ticks_since_heartbeat >= self.lease_duration_ticks;
    }

    /// Returns true if leader lost quorum contact past lease_duration_ticks and self-fenced.
    pub fn tickLeader(self: *LeaseState, consensus: *ConsensusState) bool {
        self.ticks_without_quorum_ack +|= 1;
        if (self.ticks_without_quorum_ack >= self.lease_duration_ticks) {
            self.self_fenced = true;
            consensus.role = .quarantined;
            return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Phase 17C: Unified Versioned Management API, RBAC & Audit Trail
// ---------------------------------------------------------------------------

pub const MGMT_API_MAJOR: u16 = 1;
pub const MGMT_API_MINOR: u16 = 0;

pub const MgmtRole = enum(u8) {
    viewer = 1,
    operator = 2,
    cluster_admin = 3,
};

pub const MgmtAction = enum(u16) {
    get_cluster_status = 1,
    list_vms = 2,
    create_vm = 3,
    stop_vm = 4,
    fence_node = 5,
    rotate_key = 6,
    set_policy = 7,
};

pub const MgmtStatus = enum(u8) {
    ok = 0,
    unauthorized = 1,
    forbidden = 2,
    unsupported_version = 3,
    no_quorum = 4,
    idempotency_conflict = 5,
    fenced = 6,
    reconciling = 7,
};

pub const AuthToken = extern struct {
    actor_id: u32,
    role: MgmtRole,
    _pad: [3]u8 = @splat(0),
    epoch: u64,
    expiry_seq: u64,
    signature: [32]u8,
};

pub const MgmtRequest = extern struct {
    api_major: u16 = MGMT_API_MAJOR,
    api_minor: u16 = MGMT_API_MINOR,
    action: MgmtAction,
    _pad0: u16 = 0,
    token: AuthToken,
    idempotency: IdempotencyKey = .{},
    target_node_id: u32 = 0,
    vm_id: u32 = 0,
    payload: [32]u8 = @splat(0),
};

pub const MgmtResponse = extern struct {
    status: MgmtStatus,
    _pad0: [3]u8 = @splat(0),
    target_node_id: u32,
    revision: u64,
    commit_index: u32,
    _pad1: u32 = 0,
    audit_seq: u64,
};

pub const MAX_AUDIT_ENTRIES: usize = 32;

pub const AuditEntry = struct {
    used: bool = false,
    seq: u64 = 0,
    actor_id: u32 = 0,
    role: MgmtRole = .viewer,
    action: MgmtAction = .get_cluster_status,
    target_node_id: u32 = 0,
    status: MgmtStatus = .ok,
    revision: u64 = 0,
};

pub const AuditLog = struct {
    entries: [MAX_AUDIT_ENTRIES]AuditEntry = @splat(.{}),
    next_seq: u64 = 1,
    cursor: usize = 0,

    pub fn record(
        self: *AuditLog,
        actor_id: u32,
        role: MgmtRole,
        action: MgmtAction,
        target_node_id: u32,
        status: MgmtStatus,
        revision: u64,
    ) u64 {
        const seq = self.next_seq;
        self.next_seq += 1;
        self.entries[self.cursor] = .{
            .used = true,
            .seq = seq,
            .actor_id = actor_id,
            .role = role,
            .action = action,
            .target_node_id = target_node_id,
            .status = status,
            .revision = revision,
        };
        self.cursor = (self.cursor + 1) % MAX_AUDIT_ENTRIES;
        return seq;
    }
};

pub fn computeTokenSignature(secret: []const u8, actor_id: u32, role: MgmtRole, epoch: u64, expiry_seq: u64) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("CATENARY-MGMT-TOKEN-V1");
    hasher.update(secret);
    hasher.update(std.mem.asBytes(&actor_id));
    const role_byte = [_]u8{@intFromEnum(role)};
    hasher.update(&role_byte);
    hasher.update(std.mem.asBytes(&epoch));
    hasher.update(std.mem.asBytes(&expiry_seq));
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn isRolePermitted(role: MgmtRole, action: MgmtAction) bool {
    return switch (action) {
        .get_cluster_status, .list_vms => true,
        .create_vm, .stop_vm => role == .operator or role == .cluster_admin,
        .fence_node, .rotate_key, .set_policy => role == .cluster_admin,
    };
}

pub fn authorizeMgmtRequest(
    req: *align(1) const MgmtRequest,
    secret: []const u8,
    current_epoch: u64,
    current_seq: u64,
) MgmtStatus {
    if (req.api_major != MGMT_API_MAJOR or req.api_minor > MGMT_API_MINOR) {
        return .unsupported_version;
    }
    if (req.token.epoch < current_epoch or req.token.expiry_seq < current_seq) {
        return .unauthorized;
    }
    const expected_sig = computeTokenSignature(
        secret,
        req.token.actor_id,
        req.token.role,
        req.token.epoch,
        req.token.expiry_seq,
    );
    if (!std.mem.eql(u8, &req.token.signature, &expected_sig)) {
        return .unauthorized;
    }
    if (!isRolePermitted(req.token.role, req.action)) {
        return .forbidden;
    }
    return .ok;
}

pub const ManagementPlane = struct {
    consensus: ConsensusState = .{},
    rsm: ReplicatedStateMachine = .{},
    lease: LeaseState = .{},
    fences: FenceTable = .{},
    audit: AuditLog = .{},

    pub fn handleMgmtRequest(
        self: *ManagementPlane,
        req: *align(1) const MgmtRequest,
        secret: []const u8,
        current_seq: u64,
    ) MgmtResponse {
        const auth_status = authorizeMgmtRequest(req, secret, self.consensus.fencing_epoch, current_seq);
        if (auth_status != .ok) {
            const aseq = self.audit.record(
                req.token.actor_id,
                req.token.role,
                req.action,
                req.target_node_id,
                auth_status,
                self.rsm.desired_revision,
            );
            return .{
                .status = auth_status,
                .target_node_id = req.target_node_id,
                .revision = self.rsm.desired_revision,
                .commit_index = self.rsm.commit_index,
                .audit_seq = aseq,
            };
        }

        // Read-only queries succeed even without leader write authority
        if (req.action == .get_cluster_status or req.action == .list_vms) {
            const aseq = self.audit.record(
                req.token.actor_id,
                req.token.role,
                req.action,
                req.target_node_id,
                .ok,
                self.rsm.desired_revision,
            );
            return .{
                .status = .ok,
                .target_node_id = req.target_node_id,
                .revision = self.rsm.desired_revision,
                .commit_index = self.rsm.commit_index,
                .audit_seq = aseq,
            };
        }

        if (self.lease.self_fenced or self.consensus.role == .quarantined) {
            const aseq = self.audit.record(req.token.actor_id, req.token.role, req.action, req.target_node_id, .fenced, self.rsm.desired_revision);
            return .{
                .status = .fenced,
                .target_node_id = req.target_node_id,
                .revision = self.rsm.desired_revision,
                .commit_index = self.rsm.commit_index,
                .audit_seq = aseq,
            };
        }

        if (self.consensus.role != .leader) {
            const aseq = self.audit.record(req.token.actor_id, req.token.role, req.action, req.target_node_id, .no_quorum, self.rsm.desired_revision);
            return .{
                .status = .no_quorum,
                .target_node_id = req.target_node_id,
                .revision = self.rsm.desired_revision,
                .commit_index = self.rsm.commit_index,
                .audit_seq = aseq,
            };
        }

        const mut_op: MutationOp = switch (req.action) {
            .create_vm => .vm_create,
            .stop_vm => .vm_stop,
            .fence_node => .fence_node,
            .set_policy, .rotate_key => .config_set,
            else => .config_set,
        };

        const prop = self.rsm.proposeMutation(
            self.consensus.current_term,
            self.consensus.fencing_epoch,
            mut_op,
            req.idempotency,
            req.target_node_id,
            req.vm_id,
            req.payload,
        ) catch |err| {
            const st: MgmtStatus = switch (err) {
                error.IdempotencyConflict => .idempotency_conflict,
                error.LogFull => .no_quorum,
            };
            const aseq = self.audit.record(req.token.actor_id, req.token.role, req.action, req.target_node_id, st, self.rsm.desired_revision);
            return .{
                .status = st,
                .target_node_id = req.target_node_id,
                .revision = self.rsm.desired_revision,
                .commit_index = self.rsm.commit_index,
                .audit_seq = aseq,
            };
        };

        if (req.action == .fence_node) {
            self.fences.fenceNode(req.target_node_id, self.consensus.fencing_epoch + 1, true);
        }

        const out_status: MgmtStatus = if (prop.status == .applied) .ok else .reconciling;
        const aseq = self.audit.record(req.token.actor_id, req.token.role, req.action, req.target_node_id, out_status, self.rsm.desired_revision);
        return .{
            .status = out_status,
            .target_node_id = req.target_node_id,
            .revision = self.rsm.desired_revision,
            .commit_index = self.rsm.commit_index,
            .audit_seq = aseq,
        };
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

test "clusterd_protocol: replicated state machine, idempotency, and reconciliation" {
    const std_test = @import("std").testing;
    var consensus = ConsensusState{ .cluster_size = 3, .role = .leader, .current_term = 1, .fencing_epoch = 1, .leader_node_id = 1 };
    var rsm = ReplicatedStateMachine{};

    const key1 = IdempotencyKey{ .caller_id = 10, .client_seq = 1, .body_hash = 0xCAFEBABE };
    const res1 = try rsm.proposeMutation(1, 1, .vm_create, key1, 2, 100, @splat(0));
    try std_test.expectEqual(@as(u32, 1), res1.index);
    try std_test.expect(!res1.reused);

    // Idempotent retry with same body hash returns existing entry
    const retry = try rsm.proposeMutation(1, 1, .vm_create, key1, 2, 100, @splat(0));
    try std_test.expectEqual(@as(u32, 1), retry.index);
    try std_test.expect(retry.reused);

    // Conflicting body hash with same key fails
    const conflict_key = IdempotencyKey{ .caller_id = 10, .client_seq = 1, .body_hash = 0xDEADBEEF };
    try std_test.expectError(error.IdempotencyConflict, rsm.proposeMutation(1, 1, .vm_create, conflict_key, 2, 101, @splat(0)));

    // Quorum replication commits entry and advances desired revision
    const reply = AppendEntriesReplyPayload{
        .term = 1,
        .follower_node_id = 2,
        .success = true,
        .match_index = 1,
        .signature = @splat(0),
    };
    try std_test.expect(rsm.handleAppendEntriesReply(&consensus, &reply));
    try std_test.expectEqual(@as(u32, 1), rsm.commit_index);
    try std_test.expectEqual(@as(u64, 1), rsm.desired_revision);
    try std_test.expectEqual(ReconcileStatus.reconciling, rsm.reconcile_status);

    // Observed state catches up -> applied
    rsm.reconcileObserved(1);
    try std_test.expectEqual(ReconcileStatus.applied, rsm.reconcile_status);
}

test "clusterd_protocol: lease expiry, self-fencing, and failover gating" {
    const std_test = @import("std").testing;
    var consensus = ConsensusState{ .cluster_size = 3, .role = .leader, .current_term = 2, .fencing_epoch = 3, .leader_node_id = 1 };
    var lease = LeaseState{ .lease_duration_ticks = 3 };
    var fences = FenceTable{};

    try std_test.expect(fences.isWriteAllowed(1, 3, lease.self_fenced));

    // Tick without quorum ack -> self-fence at tick 3
    try std_test.expect(!lease.tickLeader(&consensus));
    try std_test.expect(!lease.tickLeader(&consensus));
    try std_test.expect(lease.tickLeader(&consensus));
    try std_test.expect(lease.self_fenced);
    try std_test.expectEqual(ConsensusRole.quarantined, consensus.role);
    try std_test.expect(!fences.isWriteAllowed(1, 3, lease.self_fenced));

    // Failover requires both quorum AND verified fencing of failed node
    try std_test.expect(!fences.canFailoverWorkload(1, true));
    fences.fenceNode(1, 4, true);
    try std_test.expect(fences.canFailoverWorkload(1, true));
    try std_test.expect(!fences.canFailoverWorkload(1, false));
    try std_test.expect(!fences.isWriteAllowed(2, 3, false)); // stale epoch 3 < active 4
}

test "clusterd_protocol: management API version, RBAC, and audit trail" {
    const std_test = @import("std").testing;
    const secret = "mgmt-cluster-secret";
    var plane = ManagementPlane{};
    plane.consensus.role = .leader;
    plane.consensus.current_term = 1;
    plane.consensus.fencing_epoch = 1;

    const viewer_sig = computeTokenSignature(secret, 42, .viewer, 1, 100);
    const viewer_token = AuthToken{ .actor_id = 42, .role = .viewer, .epoch = 1, .expiry_seq = 100, .signature = viewer_sig };

    // Viewer can read status
    const status_req = MgmtRequest{ .action = .get_cluster_status, .token = viewer_token };
    const status_resp = plane.handleMgmtRequest(&status_req, secret, 10);
    try std_test.expectEqual(MgmtStatus.ok, status_resp.status);

    // Viewer cannot create VM -> forbidden
    const forbidden_req = MgmtRequest{ .action = .create_vm, .token = viewer_token, .vm_id = 5 };
    const forbidden_resp = plane.handleMgmtRequest(&forbidden_req, secret, 10);
    try std_test.expectEqual(MgmtStatus.forbidden, forbidden_resp.status);

    // Operator can create VM -> reconciling
    const op_sig = computeTokenSignature(secret, 43, .operator, 1, 100);
    const op_token = AuthToken{ .actor_id = 43, .role = .operator, .epoch = 1, .expiry_seq = 100, .signature = op_sig };
    const create_req = MgmtRequest{
        .action = .create_vm,
        .token = op_token,
        .idempotency = .{ .caller_id = 43, .client_seq = 1, .body_hash = 999 },
        .target_node_id = 2,
        .vm_id = 5,
    };
    const create_resp = plane.handleMgmtRequest(&create_req, secret, 10);
    try std_test.expectEqual(MgmtStatus.reconciling, create_resp.status);
    try std_test.expectEqual(@as(u32, 1), plane.rsm.log_len);

    // Operator cannot fence node -> forbidden; Cluster Admin can fence node
    const op_fence = MgmtRequest{ .action = .fence_node, .token = op_token, .target_node_id = 2 };
    try std_test.expectEqual(MgmtStatus.forbidden, plane.handleMgmtRequest(&op_fence, secret, 10).status);

    const admin_sig = computeTokenSignature(secret, 1, .cluster_admin, 1, 100);
    const admin_token = AuthToken{ .actor_id = 1, .role = .cluster_admin, .epoch = 1, .expiry_seq = 100, .signature = admin_sig };
    const admin_fence = MgmtRequest{
        .action = .fence_node,
        .token = admin_token,
        .idempotency = .{ .caller_id = 1, .client_seq = 1, .body_hash = 777 },
        .target_node_id = 2,
    };
    const admin_resp = plane.handleMgmtRequest(&admin_fence, secret, 10);
    try std_test.expectEqual(MgmtStatus.reconciling, admin_resp.status);
    try std_test.expect(plane.fences.isNodeFenced(2));

    // Unsupported version rejected
    const bad_ver = MgmtRequest{ .api_major = 99, .action = .get_cluster_status, .token = viewer_token };
    try std_test.expectEqual(MgmtStatus.unsupported_version, plane.handleMgmtRequest(&bad_ver, secret, 10).status);
}

