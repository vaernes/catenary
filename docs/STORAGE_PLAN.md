# Storage plan: standalone disks and experimental Span-Weave

**Status: proposal, not an implemented durability guarantee.** The goal is to
provide persistent virtual block disks for standalone VMs and distributed
virtual block volumes for Linux and Windows guests. Catenary presents blocks;
the guest owns its partitioning and file system. The host need not understand
NTFS, ext4, or any other guest file system. No distributed write durability,
consensus, or recovery described below should be inferred from today's code.

Related documents are the [virtualization plan](VIRTUALIZATION_PLAN.md),
[cluster orchestration](CLUSTER_ORCHESTRATION.md),
[virtual-network plan](VIRTUAL_NETWORK_PLAN.md),
[architecture overview](architecture.md), and
[DIPC page-ownership rules](DIPC_OWNERSHIP.md). These describe intended
integrations, not proof that the authenticated transport or durable volume
implementation required here already exists.

## 1. Current implementation and limits

- [storaged](../src/user/storaged.zig) already scans for NVMe, initializes
	controller and I/O queues, and has NVMe read/write command paths. It is not
	accurate to describe NVMe support as entirely future work.
- When no NVMe device is found, requests now complete with I/O error instead of
	returning synthetic success. Host-local smoke writes use the same NVMe path
	as other block requests; `vmid == 0` no longer bypasses persistence.
- Flush requests issue an NVMe Flush when Identify Controller reports a
	volatile write cache. If that field reports no volatile cache, the flush may
	complete without a command; if controller identification failed, flush fails.
	Virtio FUA writes use a write-then-flush fallback and complete only after both
	commands succeed. This does not issue the NVMe Write FUA bit, provide power-cut
	evidence, or prove that physical media honors its advertised persistence
	contract.
- The [virtio-blk device](../src/vmm/virtio_blk.zig) and
	[guest bridge](../src/vmm/microvm_bridge.zig) implement queue notification,
	descriptor handling, DIPC routing, and completion/interrupt plumbing. The
	bridge now serializes the shared 32-byte
	[block request](../src/user/protocols/storaged_protocol.zig) directly,
	including VM/chain identity and buffer metadata. Descriptor lengths and
	sector alignment are bounded to the current single-page NVMe PRP path. The
	present direct host-physical-address path is not evidence that the scoped
	DMA and ownership design below exists.
- `containerd` scans all 16 configured partition-header sectors on startup and
	avoids reusing slots whose headers validate. The default QEMU smoke has
	recovered existing metadata and completed a new write after the full scan;
	that exercise also covers NVMe queue doorbell wrap at the configured queue
	depth. This is a smoke-test allocation aid, not a checksummed journal or
	crash-consistent metadata recovery protocol; a read error stops the scan and
	prevents subsequent writes.
- The default QEMU smoke path now observes an actual NVMe write, an FUA
	write+flush fallback, and readback of a test partition header. This is QEMU
	integration evidence only; it does not establish physical power-loss
	durability, native NVMe FUA behavior, crash recovery, or persistent guest
	filesystem behavior.

## 2. Boundaries and service model

All storage policy, hardware drivers, virtual block backend logic, replication,
consensus, metadata, recovery, authorization, and key management run in
isolated **Ring 3** services. `storaged` may be split into independently
authorized services as needed. Ring 0 provides hardware isolation and
capability primitives: address-space and VM isolation, scheduling, IPC,
capability enforcement, MMIO/DMA mapping, VM exits, and interrupt delivery.
It does not decide placement, membership, file-system semantics, or access
policy. The existing bridge's parsing and routing are a starting point, not a
claim that the proposed division is already implemented.

The planned path is guest block frontend -> bounded VM/IPC boundary -> Ring-3
virtual-block and volume service -> local device driver or distributed data
nodes -> completion through the boundary. Validate descriptor chains, sector
alignment, bounds, lengths, overflow, operations, ownership, and permissions;
copy write data into an owned bounded buffer, or use an immutable pinned grant
that prevents guest modification throughout hashing and writing. Use scoped
capability mappings and lifetimes. Kernel-managed IOMMU mappings must confine
DMA where hardware isolation is required; bounce buffers alone do not sandbox
a malicious DMA-capable device. Without adequate isolation, reject the
configuration or explicitly restrict it to a trusted device threat model.

An authorized administrator grants capabilities scoped to a principal, VM,
volume, operation, and, for mutations, writer epoch. The Ring-3 authority
checks them on attach, I/O, snapshot, repair, and administration; Ring 0
enforces the underlying isolation and capability primitives. Never expose a
volume's raw backing device, arbitrary host addresses, or a bypass around its
mapping, checksums, epoch, and access checks to guests or untrusted services.
Physical administration and compromised authorized components are outside the
crash-fault guarantee.

### Standalone volumes

A standalone host needs neither a cluster nor a support VM. A local volume uses
the same validated block interface, immutable copy-on-write versions, atomic
mapping updates, request-result handling, and real flush/FUA semantics, with a
durable **local** metadata journal instead of a quorum. Write and verify the
complete new object, flush/FUA it, then atomically commit and flush the local
mapping and request result before acknowledging. Recover the journal after a
crash; barriers, ambiguous outcomes, and safe reclamation still apply. It has
only the local device's failure domain: loss of that device or host can lose
the volume. Synthetic storage is suitable only for explicitly non-durable
testing, never a persistent disk advertised to a guest.

## 3. Span-Weave: model and invariants

Span-Weave is a **proposed Catenary-specific composition**, not an existing
implementation or a new consensus algorithm. Its initial steady-state
protection group has exactly three actual data-capable nodes in three distinct
failure domains. Each is a metadata voter and can store full extent data;
there is no metadata-only witness. Domains must account for shared power,
controllers, underlying media, and similar correlated dependencies, not merely
different hostnames. A temporary learner is permitted during reconfiguration.

The model is crash/restart and network-partition faults with honest members,
authenticated communication, independently failing domains, and devices that
truthfully honor confirmed flush/FUA operations. A durable metadata quorum is
two of the three voters. Each acknowledged write has, at its durability point,
two independently flushed **full copies of every new extent generation** on
distinct eligible nodes and a committed metadata record. A later single node
failure may leave only one available copy; protection is not restored until
repair commits a second one. No guarantee is made for two simultaneous node
losses, a second loss before restoration, correlated failures, malicious
members, compromised keys, or media that lies about flush. Checksums and
replicas do not turn this into a Byzantine fault-tolerant system.

### Identity, mappings, and roles

- Give each group, node, volume, and logical extent a stable, non-reused ID.
	An immutable extent object is identified by its originating volume/extent ID
	and generation. Reserve generations from a quorum-persisted, monotonically
	increasing **group-wide** counter before staging; never reuse an ID or
	generation after a crash, abort, deletion, or log compaction. This also gives
	generations a deterministic age order across the group. Stop allocating if
	the counter is exhausted rather than wrapping it. A partial write constructs
	a new complete extent from verified old data plus the change; never overwrite
	a committed object in place.
- The quorum-owned state maps each logical range to the exact immutable object,
	length, checksum, two full-copy locations, configuration and placement
	epoch, and writer epoch. It also owns volume writer assignments, request
	outcomes, snapshot/clone references, and a durable audit hash. An untouched,
	explicitly unmapped range may read as zero; an acknowledged write to it still
	requires the two full copies. For encryption, both nodes store the same
	sealed bytes. The standard SHA-256 checksum covers the exact stored bytes and
	relevant format data, so replicas can be compared without interpreting a guest
	file system.
- For each extent and placement epoch, assign **primary**, **replica**, and
	**sentinel** to the three nodes. Sort the configuration's roster by stable
	node ID and interpret the standard SHA-256 digest of the versioned canonical
	extent ID as an unsigned big-endian integer `h`. For placement epoch `e`,
	let `p = (h + e) mod 3`: roster position `p` is primary, `(p + 1) mod 3`
	is replica, and `(p + 2) mod 3` is sentinel. Record the actual roles and
	configuration in the committed mapping. Every reassignment advances the
	quorum-owned per-extent placement epoch; it may skip epochs to select eligible
	survivors, but never reuses or wraps one. Primary and replica are full-data
	roles, not extra votes. Rotation does not imply balanced load or optimality.
- The quorum-persisted SHA-256 audit hash covers a versioned, canonical descriptor
	containing the group and object identity, length, data checksum, locations,
	configuration, placement epoch, and writer epoch. A healthy sentinel
	**independently reads the stored data**, recomputes its checksum and the
	descriptor digest, and compares them with the committed values. It durably
	records a separate receipt listing which copies it verified; a partial check
	is not a two-copy verification. The sentinel may use transient read buffers
	but is not a third full data replica. Its receipt never counts as a data copy.
	Audit is best-effort and may be pending or absent: a failed sentinel must not
	block writes that still meet the two-copy and quorum requirements. The audit
	hash itself is always durable in the metadata quorum, including then.

Call a version **protected** only when its committed placement has two
independently verified, available, durable full copies in distinct eligible
domains. A digest, old uncommitted blob, unreachable copy, or stale node's
claim does not count. Availability is evaluated conservatively from the
authoritative group's view; a heartbeat is not proof of data correctness or a
fencing mechanism. Previously committed physical blobs may temporarily remain
as quarantined, uncounted leftovers during repair or reconfiguration.

## 4. Consensus, authority, and fencing

Use a proven published majority-consensus protocol, for example independently
implement [Raft as published by Ongaro and Ousterhout](https://www.usenix.org/conference/atc14/technical-sessions/presentation/ongaro),
including its election, log, commitment, snapshot, and joint-consensus rules
and applicable published corrections. Do not invent a consensus protocol or
copy an external implementation. A log entry is committed only according to
the chosen protocol's rules, not merely because one node wrote it; in Raft,
the current-term commitment rule matters. Persist and flush the required term,
vote, log, configuration, state-machine snapshot, and high-water marks on
dedicated local journals, including term and vote before protocol responses
that require them. Frame and checksum records to detect torn or corrupt writes;
a node with uncertain consensus state must not vote until safely recovered.
Recover only entries proven committed by the protocol; never apply an isolated
node's uncommitted tail as authoritative. Compaction must preserve the committed
state, membership, fence/ID high-water marks, and retained request results,
and must leave a safe catch-up path.

Each volume has **one authorized writer**. Before admitting its mutations, a
metadata quorum durably commits a monotonically increasing fencing epoch and
the writer's identity. Never reuse or wrap an epoch; stop granting ownership if
the epoch space is exhausted. Every mapping commit atomically checks the current
writer, epoch, expected old versions, configuration, and request ID in the
consensus state machine. A grant for a new writer fences earlier epochs in log
order; an old write ordered before the grant may already have committed, but
one ordered after it cannot commit or receive a new success. Timeouts,
heartbeats, and temporal leases may prompt elections or retries; they do not
prove fencing, exclusivity, or safe reuse.

Data nodes persist their highest observed epoch before accepting a newer one and
reject lower epochs once they have observed the fence. An isolated node may
not yet know a newer epoch and might accept an old writer's **immutable,
unreferenced preparation**. That is not publication: all publication, repair
placement, deletion, and success depend on a current quorum-checked commit.
No raw access or in-place overwrite may bypass this rule. Rejoining nodes must
catch up and reconcile epochs and tombstones before serving authoritative I/O.
Reads of the current volume require a linearizable quorum read/barrier or an
equivalent authority established by the published protocol; a former leader's
local state alone is insufficient.

All node and client traffic must use standardized mutually authenticated,
encrypted transport, bind messages to the cluster/group, node identity,
operation, request ID, and epoch, and reject unauthorized members and replay.
For example, use standard TLS with mutual authentication and no replayable
0-RTT mutations, plus application-level idempotency. IPv6 addresses and the
current experimental DIPC authentication are not sufficient identity or proof
of this transport. Use established, vetted cryptographic primitives; do not
invent encryption, authentication, or hash algorithms. This protects the
transport under its assumptions, not against a malicious voting member.

## 5. End-to-end I/O contract

The following is the proposed order for **each** distributed write; no success
is inferred from merely submitting a command or receiving a synthetic reply.

1. Authenticate and authorize the caller; validate the full I/O, limits,
	 guest buffers, and volume state. Assign a unique request ID scoped to a
	 durable client/device incarnation and monotonic sequence, and preserve the
	 original operation and payload digest. A reusable virtqueue descriptor
	 index is not such an ID. The backend journals pending IDs before submission
	 so it can retry them after its own restart.
2. Establish that the volume's single writer and fencing epoch are committed
	 by a metadata quorum. Reserve unique generations and a bounded transaction
	 intent with the expected base mappings and their pins in the quorum log; this
	 reservation does **not** publish a mapping. Serialize volume mutations in
	 admitted order, including across queues.
3. Read and verify any old bytes needed for partial extents, then construct the
	 complete immutable new versions. Compute the checksum of each complete
	 stored object. Choose two independent, data-capable eligible nodes in
	 different failure domains, with space reserved for all touched extents.
4. Send identical full objects and their identities to both nodes. Each node
	 independently checks the received bytes and identity, writes them, confirms
	 a real device **flush or FUA** covering the writes, then reads back and
	 verifies the complete stored object before returning a durable receipt.
	 Receipts bind the request, exact object, checksum, location, group
	 configuration, placement epoch, and writer epoch. A volatile write-cache
	 completion without the required persistence confirmation is not a receipt.
5. Only after both receipts for **every** touched extent, atomically commit the
	 entire logical mapping change and durable request result in the metadata
	 log. The entry contains the exact generations, hashes, two locations,
	 placement/configuration and writer epochs, and quorum-owned audit hashes.
	 Check its preconditions in the replicated state machine and wait for the
	 protocol's committed majority and application of the successful result;
	 the local metadata journals themselves must have been durably flushed.
6. This successful atomic metadata commit is the write's **linearization
	 point**. Only afterward may the backend acknowledge success to the guest.
	 If a copy loss is known before success is returned, withhold that success
	 until the committed version again has two verified survivor copies; never
	 roll back an already committed write. A node can still fail immediately
	 after its last confirmation: such a racing failure can leave a committed
	 write degraded, and cannot be ruled out by a heartbeat.

One guest write crossing extent boundaries is **one transaction**: all its
mapping changes and result commit together, or none become visible. Advertise
and validate a maximum request size/extent count that fits a bounded atomic
metadata transaction; reject an oversized request before mutation rather than
silently splitting it into partially visible writes. A read atomically selects
and quorum-pins a single committed mapping view before fetching data, verifies
the referenced bytes against its checksum, and returns an error rather than
substitute an older generation or fabricated zeros. Retain the immutable version
pins for the duration of the read and any retained retry result.

### Ordering, barriers, and caches

A per-volume sequencer preserves the accepted order of mutations and guest
barriers across queues. A flush waits until all earlier writes have resolved;
every earlier committed write, including one whose response was lost, must have
completed the two-copy data and metadata durability contract. An unresolved
earlier write prevents a successful flush. Later writes cannot cross the barrier.
Quorum-commit the flush request's durable result after the barrier and before
returning success. FUA writes meet the same data-and-metadata durability rule
before completion; do not advertise flush, FUA, or cache behavior that the
entire path cannot honor. All normal successful writes already satisfy the
two-copy durable contract; flush is still an ordering barrier, not today's
no-op.

The Ring-3 driver must correctly issue and wait for supported device flush/FUA
commands, account for volatile controller and intermediate caches, and treat
errors, resets, and uncertain completion as failures or indeterminate outcomes.
Disable unsafe write caching or refuse persistent volumes if the device stack
cannot establish the required durability. Data and metadata need their own
confirmed persistence; a flush of one is not a flush of the other.

### Retries and ambiguous outcomes

Persist each admitted write, flush, and other side-effecting request's terminal
success or definite abort and its identity/digest in quorum state; a successful
write result is atomic with its mapping. Before returning a retriable read,
quorum-commit its exact mapping/result reference and pins: a retry returns the
same bytes or an error if no verified copy remains, never a newer mapping.
Concurrent duplicates are serialized/deduplicated by ID; a pending retry resumes
the original durable intent and reserved generations. The same ID and parameters
resolve to the recorded outcome without re-execution, while reuse with a
different operation or payload is rejected. Data nodes also reject reuse of an
immutable object identity for different bytes.
An authorized result query may report an already committed old-epoch outcome
without re-executing the write; guest success still waits for the protection
gate above, and new mutations need the current fence.

A write can commit and its ACK can then be lost on the way to the guest.
**No ACK means indeterminate**, not necessarily failed or uncommitted. A
timeout, reset, or lost quorum must not be reported as a definite abort unless
a quorum has durably ordered an abort that prevents a later commit of that ID.
A retry or linearizable status query resolves a committed result, an ordered
abort, or a still-pending/unknown outcome; absence from one node's log is not
proof. Keep deduplication records and pins until a durable client completion
watermark or explicitly invalidated session makes retries impossible; retain a
durable rejection floor/tombstone so an expired old ID cannot execute as new.
Do not expire correctness state based only on elapsed time. After a guest reset, the
device protocol may not supply the same request ID; report uncertainty through
the available device error/reset semantics and rely on guest recovery, rather
than claiming exactly-once behavior for a newly issued guest request.

## 6. Worked A/B/C failures

Suppose nodes A, B, and C occupy distinct domains. For extent X at one
placement epoch, A is primary, B is replica, and C is sentinel. A and B have
flushed full copies; the exact mapping and audit hash are committed on a
metadata majority. C's independently verified receipt may exist, but it is
not a data copy. The surviving nodes in each single-loss case can communicate
and have healthy journals and sufficient eligible capacity.

| Event | Required behavior |
| --- | --- |
| A fails | B and C retain the 2-of-3 metadata quorum. X may have only B's verified copy and is **degraded**. Read/verify B, copy X to eligible C, flush and read back/verify C, then quorum-commit B/C placement before marking X protected. New writes require full flushed copies on both B and C; A can be the unavailable sentinel for their placement. |
| B fails | A and C retain quorum. X may exist only on A; repair A -> C and commit placement before declaring protection. New writes need both A and C. |
| C fails | A and B retain quorum and both copies of X. Sentinel verification may be unavailable, but new writes can commit with full durable copies on A and B and metadata on their quorum. |
| Two nodes or a metadata majority are lost | The live volume is unavailable for new writes and cannot claim current reads without quorum. Even if one data copy remains, do not force a new quorum or infer the latest mapping from it. Two simultaneous losses have no durability guarantee. |

The same rules apply to a partition: only a component with quorum and two
eligible data nodes can acknowledge **new** writes; a minority cannot. A
previously committed extent with one surviving verified copy is readable but
not protected while repair is pending. If no verified copy of a committed
extent exists, or its authoritative mapping/outcome is ambiguous, freeze
volume writes and report affected reads as unavailable/I/O errors; never
silently roll back or use the sentinel digest as data. An independently exported,
verified backup may be examined as explicitly stale read-only data, but is not
the current live volume and does not restore quorum.

## 7. Recovery, repair, and reclamation

On restart, recover local device state and journal, join authenticated peers,
replay only protocol-committed metadata, reconcile epochs and request outcomes,
and verify committed object identities and hashes before serving them. Treat
unknown or corrupt copies as unavailable; quarantine a bad copy, try another
committed verified copy, and raise an alert. Scrubbing and sentinel audits are
background checks, not substitutes for quorum metadata or a second data copy.
If the last copy is missing or corrupt, stop and require explicit recovery from
a verified backup. A rejoining node must not resurrect stale mappings, accept
old writer authority, or count its old blobs without reconciliation.

### Proposed tension-directed repair

For each surviving node `n`, define its **tension** as the sum of the stored
bytes of committed, still-referenced extent generations having exactly one
verified available full copy, and that copy is on `n`. Count a shared
snapshot/clone object once, not once per reference. This includes retained
versions, not merely the current live mapping. Recompute from the authoritative
committed state and current verification evidence after each repair or change
of availability.

Among extents with exactly one verified copy and an eligible distinct-domain
destination with sufficient reserved capacity, the normal repair selection is
deterministic:

1. Highest tension of the surviving source node.
2. Largest extent in bytes.
3. Oldest generation, using the group-wide generation order.
4. Stable volume/extent ID, then stable source and destination node IDs to
	 break any remaining ties.

To prevent a continuously high-tension source from indefinitely displacing
older eligible work, every **eighth successfully committed repair** is a
fairness turn: choose the oldest generation among all eligible extents,
ignoring tension and size, then use the stable ID/source/destination tie
breaks. Store the non-wrapping successful-repair sequence in quorum metadata;
serialize selection/commit through one logical repair coordinator, and
conditionally commit the expected sequence so concurrent or restarted
coordinators cannot skip or duplicate a fairness turn. A failed, cancelled, or
invalidated repair does not advance it. The interval of eight is a proposed
policy parameter, not a measured optimum.

A node with no currently repairable extent does not prevent progress on
another node. For example, on a normal turn, if A alone holds referenced
extents of 8 and 2 units and B alone holds one of 8 units, tensions are 10 and
8: repair A's 8-unit extent first, then recompute, making B's 8-unit extent the
next candidate if the same destinations remain eligible. The units are
illustrative, not a capacity or performance estimate. The fairness rule
provides eventual progress only while the older extent remains eligible,
earlier eligible work is finite, and successful repairs continue; it makes no
wall-clock guarantee when a destination, capacity, quorum, or I/O progress is
missing. Alert on stalled repair rather than relaxing durability.

Quorum-pin and verify the source, copy the exact immutable bytes to the chosen
destination, flush them, then independently read back and verify the complete
copy. Conditionally quorum-commit the new placement, placement epoch, and
recomputed audit hash for that same generation. Keep the old committed copy
until the update succeeds. Only then count the destination and mark the version
protected; discard/reconcile a raced repair if the expected object, references,
fence, or configuration changed. If no destination or space is available,
retain the degraded state and reject writes that cannot obtain two valid copies.
Sentinel availability is not a repair quorum requirement; a changed placement
needs a fresh best-effort audit.

This role-specific, risk-directed selection is a **proposed compositional
project policy**, not a proof of global novelty, patentability, or optimality.
Require prior-art review, correctness modeling, and empirical fault tests
before drawing stronger conclusions.

### Safe garbage collection

Prepared blobs are not visible merely because they exist. A timeout or absence
of a local commit is not permission to delete them: first resolve the
transaction through quorum and durably order a conditional abort/tombstone that
precludes a later commit, or discover that it already committed. Reclaim an
old committed generation only after quorum-owned reference accounting proves
that no live mapping, snapshot, clone, reader pin, in-flight transaction,
retained retry result, or required recovery/reconfiguration state can use it.
Commit the deletion/tombstone before physical reuse; quarantine offline nodes
until they replay it. Never reuse object IDs or generations, and never free a
source just because its replacement was written but not quorum-committed.
Without quorum or proof of safety, defer collection even under space pressure.

## 8. Membership, bootstrap, and resource safety

### Joint-safe membership changes

Reconfigure one node at a time. Authenticate a prospective data-capable node,
verify its distinct failure domain and reserved capacity, and add it as a
non-voting learner. Catch it up with verified, durably persisted metadata
snapshot/log state, configuration, writer epochs, generation high-water marks,
and required data. Quiesce new volume mutations and resolve in-flight work
while moving the retained extent versions; preserve existing copies and make
enough verified, flushed copies available in the proposed new group before
removing a member. Temporary staging copies are not sentinel replicas or
committed placements.

Use the chosen protocol's joint-consensus transition: a joint configuration
requires the prescribed majorities of **both** old and new voter sets before
the final configuration is committed. Update placements safely while preserving
referenced copies, and finalize only when every retained extent has two
verified durable copies on eligible nodes in the new three-node group. Old
nodes and copies may be retired only after the committed transition and safe
reference reclamation. If either required quorum, data, or capacity is missing,
remain quiesced/degraded and reject unsafe changes. Never recover a lost
majority by resetting terms, reusing identities, or forcing a stale member to
be authoritative; disaster restore requires an explicit new group identity and
fencing of the old group.

### Independent startup and recovery graph

The dependency graph must not loop through the volume being recovered:

An administrator provisions the same authenticated genesis record, naming the
group and its three initial node identities, keys, and failure domains, on
independent local bootstrap media. Reject conflicting genesis records; the
first election still requires two of those three voters. Standalone mode is a
separate local configuration, not a way to bootstrap a partitioned group.

1. Local boot image, kernel, essential Ring-3 binaries, bootstrap credentials,
	 and rescue administration, independent of distributed volumes and guests.
2. Local device driver and **dedicated, reserved local metadata journal**;
	 local network driver and authenticated node transport.
3. Quorum election, committed-log/snapshot replay, fencing and request
	 reconciliation, followed by extent verification and repair.
4. Distributed volume exposure, guest startup, and only then any optional
	 support VM or other nonessential workload.

Local key/identity bootstrap must likewise be available independently of the
distributed volume. A support VM is optional and is never required to start
the driver, network, quorum, repair, rescue interface, or recover its own disk.
Dedicated journals may share a physical device with data only through reserved
local regions; they must never be files on the distributed volume and a shared
device must not be counted as independent failure domains.

Reserve journal space, CPU, memory, DMA buffers, network capacity, and repair
space for elections, fencing, aborts, metadata recovery, and a bounded amount
of repair. Account for snapshots, pinned results, orphan preparations, and
per-node capacity when admitting writes. Apply backpressure and stop admitting
writes before reserves are exhausted. If a journal cannot persist required
consensus state or a second copy cannot be placed, fail closed/read-only or
unavailable; never acknowledge by dropping safety state, overwriting retained
versions, or assuming compaction/GC is safe. Report metadata exhaustion as a
separate critical condition.

## 9. Snapshots, backup, keys, and operations

- **Snapshots and clones:** Order a snapshot after a volume barrier and
	quorum-commit an immutable mapping root with references/pins to its exact
	generations. It is crash-consistent, not automatically application-
	consistent; coordinated guest quiescing is required for the latter. Clones
	use copy-on-write, their own single-writer authority and epochs, and the same
	durability and accounting rules. A snapshot of degraded data is not magically
	protected.
- **Backup and restore:** Replication is not backup. Export a verified
	point-in-time mapping and data, format/version metadata, integrity information,
	and protected key-recovery material to an independently administered and
	failure-isolated backup, with retention and restore tests. Restore into an
	isolated new volume/group, verify every object and key, establish the proper
	durable mappings and copy count, then expose it. Do not silently restore an
	old epoch into a live group.
- **Encryption and keys:** Plan optional at-rest authenticated encryption for
	data and sensitive metadata using established, vetted algorithms and
	implementations. Seal once per immutable object before replication, protect
	authentication metadata, and guarantee any required nonce uniqueness across
	crashes, retries, clones, snapshots, rollback, and restore. Ring-3 key
	services manage scoped access, rotation, revocation, and independent recovery;
	old key versions remain available while referenced snapshots/backups require
	them. Keys are not stored in plaintext in the metadata log. If keys are
	unavailable, keep encrypted volumes unavailable rather than bypassing checks.
- **Observability:** Expose authorized, auditable health for quorum and log
	state, current writer/fence, per-extent copy and checksum status, placement
	epochs, sentinel audit/receipt status, unavailable or corrupt data, pending
	request outcomes, repair candidates and tensions, capacity/reserves, GC,
	keys, and last verified backup/restore. Alert separately on degraded data,
	missing quorum, metadata exhaustion, failed flush, and stalled repair.
	Do not expose keys or capability secrets in telemetry.

## 10. Verification and acceptance matrix

All items below are **future acceptance work**, not claims that current
smoke tests demonstrate these properties. Model checking and unit tests
complement, but do not replace, real device/VM and crash-fault tests. Record
fault seeds, durable log/data evidence, request IDs, commit order, and guest
outcomes so each run can be reproduced and checked against the invariants.

| Area | Required evidence / expected result |
| --- | --- |
| Model and log safety | Model atomic multi-extent commits, durable fences, deduplication, crashes, snapshots, GC, and old/new quorum transitions; check that no mutation ordered after its writer's fence or uncommitted blob becomes visible. |
| Guest bridge and ABI | Round-trip the shared request layout, VM identity, buffer, length, status, and completion through the real bridge; reject malformed descriptors and scoped-memory violations. Synthetic success must never satisfy the persistence test. |
| Real guest disks | Linux and Windows guests perform block I/O, reboot, and verify data on local and distributed disks; guest file systems are handled inside the guest, not parsed by the host. |
| Power loss and caches | Randomized power cuts/device resets before and after each data write, flush/FUA, metadata append/commit, and response; emulate volatile controller caches and also test devices that honestly honor persistence. Every reported success survives the assumed single fault unless superseded by a later committed write; a lost response may nevertheless correspond to a committed write. |
| Atomicity and barriers | Cut multi-extent writes at every boundary; readers observe all-old or all-new mappings, never a mixture from one transaction. Reorder queues around flush/FUA and verify earlier unresolved writes prevent barrier success. |
| Partitions and loss | Exercise A/B/C cases, every single-node loss, 2+1 and 1+1+1 partitions, and loss of majority. A failed sentinel does not block a valid two-node write; a minority cannot write. |
| Fencing | Pause an old writer, commit a newer epoch, delay/replay its messages, restart nodes, and show stale commits and raw bypass fail even if an isolated data node accepted an orphan preparation. |
| Retry and GC | Lose a response after commit, repeat the same ID across restart, race duplicates and aborts, reuse an ID with different data, and exhaust retry retention. Apply the mutation at most once, return the same durable outcome on authorized retries, reject conflicting/expired IDs, and never reclaim a possibly committed blob. |
| Corruption and audit | Corrupt each full copy and metadata/journal records independently; verify checksums, quarantine, sentinel's independent read/receipt, and no use of a digest as a replica. With no valid source, return errors instead of stale data. |
| Repair ordering and capacity | Check tension calculation, highest-source/largest/oldest/stable-ID tie breaks, persisted every-eighth oldest-first fairness turn, restart/concurrency and recomputation, concurrent version changes, destination domain, flush-before-placement, and refusal when space or eligible nodes are insufficient. |
| Reconfiguration | Crash during learner catch-up and each joint/final configuration step; test old/new quorum loss, retained snapshots, epochs, and insufficient replicas. Never finalize an unsafe membership change. |
| Resource exhaustion | Fill data, journal, reservations, and retained-result capacity; ensure backpressure, useful alarms, no unsafe GC or success, and preserved election/recovery state. |
| Security and keys | Exercise cross-volume capability denial, stale authority, guest buffer/DMA isolation, transport identity/replay, key unavailability/rotation, and restore without exposing secrets. |
| Bootstrap and backup | Recover quorum and repair while distributed volumes and the optional support VM are down; independently restore a verified backup and check snapshot/clone pins and application-consistency limitations. |
