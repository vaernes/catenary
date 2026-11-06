# DIPC Page Ownership and Lifetime

This document defines ownership transfer for DIPC page-backed messages.
The current page and routing interfaces are in [DIPC](../src/ipc/dipc.zig)
and [the router](../src/ipc/router.zig). The guest data-plane contracts at the
end of this document are **proposed, not implemented**.

## Invariants

- A DIPC message is one physical page allocated by Ring 0 PMM.
- At any time, exactly one subsystem owns disposal rights for a page.
- The current owner is responsible for calling `dipc.freePageMessage(page_phys)` when routing/processing ends.

## Ownership States

1. Sender-owned
- Created by `dipc.allocPageMessage(...)`.
- Owner: caller that requested allocation.
- May be released immediately on local failure.

2. Router-owned
- Entered when `router.routePage(...)` accepts the page.
- Owner: router path until it successfully hands off to a destination queue.
- On routing error, ownership remains with caller (no implicit free).

3. Local thread queue-owned
- Entered when route result is `DeliveredLocal`.
- Owner: destination thread mailbox consumer.
- Consumer frees page after decode/processing.

4. Net daemon queue-owned
- Entered when route result is `HandedToNetd`.
- Owner: net daemon thread/service that dequeues page.
- Net daemon frees page after local delivery or remote-forward completion.

5. MicroVM bridge queue-owned
- Entered when route result is `QueuedForMicrovm`.
- Owner: [MicroVM bridge](../src/vmm/microvm_bridge.zig) queue consumer.
- Owner transfers to MicroVM transport/dispatch path; final consumer frees page.

## Control Plane Messages

- `control_handler.handleKernelControlPage(...)` reads and validates the page.
- Callers currently free control pages after handler return.
- Handler does not claim long-term ownership.

## Security/Validation Requirements

Before any ownership handoff, the receiver must verify:

- DIPC wire magic/version/header length.
- Payload bounds (`payload_len <= MAX_PAYLOAD`).
- Message authentication tag (`dipc.verifyPageAuth(...)`).

Any failed validation keeps ownership with current holder, which must free or quarantine the page.

## Netd Ownership and Extensibility (Phase 10)

- **Boundary**: The intended architecture places external packet interfaces, off-node routing policy, address assignment, and higher-level networking in Ring 3. The current [netd](../src/user/netd.zig), [virtual-switch policy core](../src/user/protocols/virtual_switch.zig), and [router](../src/ipc/router.zig) are partial implementations, not a complete virtual network or policy system. Guest TX no longer falls back to raw NIC transmission; with no configured vNIC binding or policy, it is dropped. Kernel ingress is accepted only from netd for a running MicroVM, but the current DIPC-page path is not yet a scoped guest-memory grant.
- **Capability tokens**: The [service bootstrap](../src/services/service_bootstrap.zig) supplies a startup token and syscall restrictions. Their existence alone does not prove complete isolation or the capability-limited packet grants proposed below.
- **Remote authentication**: The current cluster-wide DIPC HMAC is distinct from the node-local page tag and has a known replay gap; it is not encryption or per-node identity. See [cluster orchestration](CLUSTER_ORCHESTRATION.md#current-implementation-and-limits).

## Guest data-plane buffers and grants — proposed, not implemented

The [virtual network plan](VIRTUAL_NETWORK_PLAN.md) needs packet buffers and scoped grants that do not yet exist as a complete contract. This proposal does **not** change the one-owner disposal invariant above, imply that a DIPC control page is a guest Ethernet frame, or grant a service arbitrary access to guest memory.

### Authority and lifetime

1. A trusted broker/allocator records each buffer's generation, bounds, outstanding grants, and the single subsystem holding disposal rights. A successful handoff transfers that disposal responsibility; a rejected or failed handoff leaves it with the sender. A descriptor, guest-supplied address, MAC, IP address, or bare physical address is not authority.
2. A grant is bound to the authenticated service, host-assigned VM/vNIC port and attachment generation, buffer generation, permitted byte range, access mode, and lifetime. It grants only the minimum read or write needed for that operation. Validate descriptor chains, lengths, arithmetic, guest mappings, and direction before access; reject stale, forged, out-of-range, or revoked grants.
3. For transmit, inspect a stable snapshot: copy into an owned buffer or use an immutable, safely pinned grant whose contents cannot change between validation, policy decision, and send. For receive, write only to the intended guest's validated writable range and complete it once. Pinning, mappings, and revocation must prevent guests and services from accessing unrelated or recycled pages. Untrusted or guest-assigned DMA devices require verified IOMMU or equivalent hardware confinement; bounce buffers alone cannot contain arbitrary device DMA. A trusted host-owned device may use controlled bounce buffers for its intended transfers.
4. The broker may fan out by creating independent copies, each with its own disposal owner, or by retaining **one** disposal owner for an immutable buffer with bounded, explicit read-only references. Each reference is capability-limited, accounted, and released exactly once; only the owner reclaims the buffer after the last reference and all DMA/mappings are quiescent. Reference holders do not acquire independent disposal rights.

### Completion, overload, and teardown

- Bound bytes, packets, references, and outstanding work per port, segment, service, and remote peer, with reserved control-plane capacity. A full queue or exhausted quota rejects or drops work predictably and increments counters. Rejection before handoff leaves ownership with the sender and releases tentative grants; a drop after acceptance releases the receiver's grants/references and disposes of its owned buffer safely. Neither case transfers ownership implicitly or bypasses policy.
- Every accepted operation has one terminal outcome: completed, dropped, cancelled, or revoked. Completion and cancellation races must not double-free or deliver twice. Drain or discard queued packets after a policy change, hot-unplug, or generation change before allowing any old decision to send.
- On revocation, VM stop, service crash/restart, or peer loss, block new access, invalidate handles and mappings, stop or fence DMA, cancel/drain in-flight work, and reclaim only after references and device access are proven quiescent. Quarantine memory if safe reclamation cannot be established. A restarted service receives fresh capabilities and generations, not inherited stale handles.
- Planned tests cover descriptor mutation during inspection, malformed and cross-guest grants, fan-out and queue saturation, completion/drop/revocation races, service and VM restart, and DMA teardown. Assert bounded resource use, correct destination, and no leaks, stale access, duplicate completion, or double-free. These are future acceptance requirements, not claims about the existing bridge.
