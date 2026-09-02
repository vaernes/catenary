# Phase 7: Network & Distributed Orchestration

This document outlines the roadmap for Phase 7 of Catenary OS. The focus is to transition from a single-node hypervisor to a multi-node cluster capable of dynamic workload placement and cross-node communication via DIPC.

## Current Status (2026-08-07)

Phase 7 is partially implemented. The control-plane and orchestration work is substantially farther along than the networking bring-up, and the current blocker is still `netd` on the legacy Virtio-Net path used by the two-node QEMU cluster smoke.

### What Is Implemented
- `kernel_control` ABI was expanded for richer node status, node identity, and MicroVM create/reply paths.
- `netd`, `clusterd`, `configd`, and `dashd` protocol definitions were extended for Phase 7 traffic.
- `clusterd` was reworked for resource advertisement, remote-launch request/ack flow, local `netd` queries, and startup race avoidance.
- The cluster harness was updated to force the legacy `virtio-net-pci` path with `disable-modern=on`.

### What Is Still Blocking Phase 7
- `netd` still does not complete legacy Virtio-Net bring-up in `test_qemu_cluster.sh`.
- The latest stable symptom is that `netd` reaches `stage features` and at least the first two DMA allocations on one node, but still does not reach `stage dma`, `stage rx_queue`, `stage tx_queue`, `registered`, `peer announcement broadcast queued`, or `entering DIPC handler loop`.
- Because `netd` never registers cleanly, cluster discovery and the remote MicroVM launch milestones are still blocked.

### Important Findings From This Debug Slice
- QEMU on this setup rejects `rx_queue_size=64` and `tx_queue_size=64` for `virtio-net-pci`; the driver must handle the 256-entry queue geometry.
- Preserving callee-saved general-purpose registers in `src/arch/x86_64/user_mode.zig`'s `int 0x80` syscall ISR moved `netd` farther through repeated DMA setup and should be kept.
- The current live debug focus is no longer `clusterd`; it is still the repeated DMA/syscall return path inside or immediately after `netd`'s Virtio-Net queue setup.

### Status By Roadmap Area
- `2.1 Networking Foundation`: in progress; blocked in `src/user/netd.zig` and the x86_64 user-mode trap/syscall path.
- `2.2 Global DIPC Routing`: partially implemented in protocol/control-plane form, but not validated across nodes because `netd` is not yet alive on both nodes.
- `2.3 Cluster Orchestration`: mostly implemented at the protocol and daemon-logic level; end-to-end validation is blocked on `netd`.
- `2.4 Distributed Dashboard`: protocol definitions were extended, but the daemon-side aggregation and cross-node telemetry flow are not finished.

### Validation State
- `zig build` passes.
- `TIMEOUT_SECS=25 ./test_qemu_cluster.sh` still fails because the expected remote-launch milestones do not appear.

### Continue Here
- Primary files: `src/user/netd.zig`, `src/arch/x86_64/user_mode.zig`, `test_qemu_cluster.sh`, and secondarily `src/user/clusterd.zig` once `netd` reaches registration.
- Immediate next step: continue instrumenting the `netd` DMA/queue bring-up path after the second successful DMA allocation and verify whether the next lost edge is another syscall-return corruption or a later queue-setup bug.

Useful resume commands:
- `zig build`
- `TIMEOUT_SECS=25 ./test_qemu_cluster.sh`
- `strings -a qemu_serial_B.log | rg -n "netd:|netd_dma:|netd_trace:|dma_alloc:|driver_ok|peer announcement|rx-poller|entering DIPC"`

## 1. Objectives
- **Multi-Node Networking**: Transition `netd` from loopback/dummy mode to utilizing physical NICs (Virtio-Net).
- **Cluster Bootstrap**: Implement secure node introduction and identity exchange.
- **Dynamic DIPC Routing**: Expand the kernel and `netd` to handle global IPv6-based DIPC routing.
- **Workload Orchestration**: Enhance `clusterd` to schedule MicroVMs across different physical nodes.
- **Distributed Telemetry**: Propagate system metrics across the cluster for global observability.

## 2. Technical Roadmap

### 2.1 Networking Foundation (`netd` & `virtio_net`)
- [ ] **Physical NIC Support**: Finalize Ring-3 DMA and IRQ handling for Virtio-Net in `netd`.
- [ ] **IPv6 Neighbor Discovery (NDP)**: Implement core NDP logic for local-link address resolution.
- [ ] **DIPC Encapsulation**: Formalize the wire protocol for decapsulating DIPC pages from Ethernet/IPv6 frames.

### 2.2 Global DIPC Routing
- [ ] **Node-Aware Router**: Update `src/ipc/router.zig` to efficiently handle off-node packet handoff to `netd`.
- [ ] **DIPC Auth Identity**: Extend `src/ipc/identity.zig` to support cross-node cryptographic verification using the `KernelManifest` capability seed.

### 2.3 Cluster Orchestration (`clusterd` & `configd`)
- [ ] **Node Discovery**: Implement a gossip or announcement protocol for node presence detection.
- [ ] **Resource Advertisement**: Nodes should broadcast their available memory and CPU resources via DIPC.
- [ ] **Remote Launch Command**: Extend `kernel_control` messages to support remote MicroVM creation requests triggered by `clusterd`.

### 2.4 Distributed Dashboard (`dashd`)
- [ ] **Cluster View**: Update `dashd` to aggregate and display telemetry from all nodes in the local L2 segment.
- [ ] **Cross-Node Metrics**: Ship `TelemetryUpdate` packets over the wire to a centralized or distributed dashboard instance.

## 3. Compliance & Constraints
- **Exokernel Philosophy**: All orchestration logic MUST stay in Ring 3. The kernel remains a simple packet router.
- **Security**: Cross-node identity MUST be verified via the `AuthTag` in the DIPC header.
- **No Legacy**: Strictly IPv6 for all inter-node communication.

## 4. Success Criteria
1. `clusterd` on Node A can successfully launch a MicroVM on Node B.
2. DIPC messages can be sent between services on different nodes with < 1ms latency overhead.
3. `test_qemu_cluster.sh` passes with a simulated 2-node topology.
