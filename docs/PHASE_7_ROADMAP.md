# Phase 7: Network & Distributed Orchestration

This document outlines the roadmap for Phase 7 of Catenary OS. The focus is to transition from a single-node hypervisor to a multi-node cluster capable of dynamic workload placement and cross-node communication via DIPC.

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
