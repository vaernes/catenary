# DIPC Page Ownership and Lifetime

This document defines ownership transfer for DIPC page-backed messages.

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
- Entered when `ipc/router.routePage(...)` accepts the page.
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
- Owner: `vmm/microvm_bridge.zig` queue consumer.
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

- **Single-Node Operations**: The `netd` user service exclusively manages external packet interfaces, DIPC routing policy off-node, and IP address assignment. 
- **Orchestration Boundaries**: All orchestration, routing metrics, and higher-level network stacks (TCP/UDP) reside purely in user space. The kernel's `ipc/router.zig` provides simple exact-match fast paths mapped by `netd`.
- **Capability Tokens**: A user space `netd` service manages authority through its startup capability token, ensuring isolation even from other local Ring-3 binaries.
