# Phase 7: Network & Distributed Orchestration [COMPLETED]

> [!NOTE]
> **Status:** Completed & Verified (2026-10-11).
> All core deliverables for Phase 7 (distributed orchestration, physical virtio-net, user-space TCP/IPv6, SMP scheduling, remote MicroVM launching, and cluster telemetry) are implemented and green in CI/tests.
> Active development has transitioned to [Phase 8: User Interface & OS Interaction](PHASE_8_ROADMAP.md).

This document outlines the completed deliverables and tracking record for Phase 7 of Catenary OS. The focus was transitioning from a single-node hypervisor to a multi-node cluster capable of dynamic workload placement, cross-node communication via DIPC, and multi-core SMP scheduling.

## Final Status (2026-10-11)

Phase 7 core networking, cluster bootstrap, remote MicroVM launching, and Symmetric Multi-Processing (SMP) are **fully functional and verified in automated tests**.

### What Is Implemented & Validated

- **Physical Virtio-Net Bring-Up (`netd`)**:
  - Ring-3 DMA allocation and legacy `virtio-net-pci` driver with 256-descriptor RX/TX queues.
  - Dedicated `rx-poller` thread (`SYS_SPAWN_THREAD`) handling asynchronous packet reception.
  - Link-local IPv6 assignment, NDP unsolicited neighbor advertisements, and MAC filtering.
- **Embedded TCP/IPv6 Stack (`src/user/protocols/tcp.zig`)**:
  - Full 16-connection TCP socket state machine with RFC 793/9293 3-way handshakes, data transfer, sequence tracking, and connection teardown.
  - DIPC notification interface for user daemons (`tcp_listen`, `tcp_connect`, `tcp_send`, `tcp_recv`, `tcp_close`).
- **Cluster Discovery & Remote Workload Launching (`clusterd` & `configd`)**:
  - Node discovery and capability exchange over multicast Ethernet / DIPC.
  - Resource advertisement protocol and multi-node registry synchronization.
  - Automated remote MicroVM launch via DIPC control-plane commands (`clusterd` on Node A -> `kernel_control` on Node B).
- **Symmetric Multi-Processing (SMP) (`src/arch/x86_64/smp.zig` & `src/kernel/scheduler.zig`)**:
  - AP core initialization via INIT-SIPI-SIPI trampoline at physical address `0x8000`.
  - Atomic scheduling spinlock, per-CPU current thread tracking, and dedicated idle threads per core.
  - Concurrent dispatch of Ring-3 services (`windowd`, `dashd`, `storaged`, `containerd`, `clusterd`, etc.) on AP cores.
- **Interactive Varde Shell (`dashd`)**:
  - Terminal commands for service listing (`ps`), network status (`net-stat`), and MicroVM inspection (`vmlist`).

### Current Validation State

- `zig build`: **PASSES** cleanly.
- `TIMEOUT_SECS=120 ./test_qemu.sh` (single-node SMP smoke): **PASSES** (`[+] SMOKE PASS: observed guest and core milestones`).
- `TIMEOUT_SECS=120 ./test_qemu_cluster.sh` (2-node QEMU cluster): **PASSES** (`[+] PASS: Node A requested remote launch, Node B launched staged MicroVM via DIPC`).
- `SMOKE_PROFILE=vmx-linux-services ./test_qemu.sh`: Linux guest boots, runs cgroups, mounts rootfs, and emits heartbeats concurrently with host services.

---

## 1. Objectives

1. **Multi-Node Networking**: Physical NIC driver (`netd`) with native IPv6 and TCP stack.
2. **Cluster Bootstrap**: Secure node introduction, presence detection, and registry synchronization.
3. **Dynamic DIPC Routing**: Seamless cross-node message handoff via `netd` encapsulation.
4. **Workload Orchestration**: Remote MicroVM scheduling and launch across cluster nodes via `clusterd`.
5. **Multi-Core Scaling**: SMP scheduler dispatching workloads across all available CPU cores.
6. **Distributed Telemetry**: Propagating system metrics across the cluster for global observability in `dashd`.

---

## 2. Technical Roadmap & Progress

### 2.1 Networking Foundation (`netd` & `virtio_net`)
- [x] **Physical NIC Support**: Ring-3 DMA and 256-descriptor Virtio-Net driver in `netd`.
- [x] **IPv6 Neighbor Discovery (NDP)**: Link-local IPv6 assignment and unsolicited Neighbor Advertisement.
- [x] **User-Space TCP Stack**: Minimal RFC-compliant TCP/IPv6 implementation with DIPC socket ops.
- [x] **DIPC Wire Encapsulation**: Ethernet/IPv6 framing for cross-node DIPC messaging.

### 2.2 Global DIPC Routing & Trust
- [x] **Remote Node Addressing**: Node ID assignment and publishing via `kernel_control` (`set_node_addr`).
- [x] **Transparent Node-Aware Router**: Update `src/ipc/router.zig` to automatically route off-node packet destinations to `netd`'s outbound queue without explicit daemon addressing.
- [x] **Cryptographic DIPC Identity**: pages leaving a node are re-signed by the router with an HMAC-SHA256 cluster tag (key derived from `-Dcluster_secret`, which must match on all nodes; a dev default logs a warning). `SEND_PAGE` accepts remote-origin pages only from `netd` with a valid tag. Known gaps: no replay protection; the per-node `KernelManifest` seed is not yet bound into the tag; early pre-address-assignment packets are dropped (and retried).

### 2.3 Cluster Orchestration & Core Foundation
- [x] **Node Discovery**: Presence broadcasting and registry sync over DIPC multicast.
- [x] **Remote Launch Protocol**: `clusterd` request and `kernel_control` staged MicroVM launch across nodes.
- [x] **Multi-Core SMP Scheduling**: AP core bring-up and per-CPU run queues in `scheduler.zig`.
- [x] **Node CPU Capacity Reporting**: Wire `arch.smp.getCpuCount()` into `control_handler.zig`.
- [x] **SMP UART Output Serialization**: Protect `vmx.zig` and keepalive UART writes with `smp.serialAcquire()` to prevent character-level interleaving across cores.

### 2.4 Distributed Dashboard & Observability (`dashd`)
- [x] **Interactive Varde Shell**: Local commands (`help`, `ps`, `net-stat`, `vmlist`) in `dashd`.
- [x] **Cluster-Wide Telemetry**: `dashd` forwards local VM samples to `clusterd` (rate-limited), which multicasts them as `telemetry_report`; peers relay them to their `dashd`, which keys stats by (node, VM id) and exposes a `cluster` shell command.
- [x] **Remote Node TUI View**: `windowd` polls `dashd` for a telemetry summary and shows per-node VM counts and exits in the sidebar.

### 2.5 Storage Integration (`storaged` & `containerd`)
- [x] **NVMe Driver & Synthetic Storage**: Controller initialization and block IO queues.
- [x] **Container Image Mounting**: `containerd` allocates a 1 MiB NVMe partition per image (slot table at LBA 8192+), writes a header through `storaged` (real I/O under a dedicated requester id) and reads it back to verify. Full image unpack into the partition is still simulated.

---

## 3. Compliance & Constraints

- **Exokernel Philosophy**: All orchestration and networking logic remains strictly in Ring 3. The kernel only routes pages, provides scheduling, and exposes hardware virtualization primitives.
- **Strict IPv6**: Zero legacy IPv4 support in kernel or cluster control plane.
- **Zero-Trust**: Cross-node identity backed by hardware/boot measurements (`KernelManifest`).

---

## 4. Verification & Testing

| Test Command | Target | Status |
|--------------|--------|--------|
| `./test_qemu.sh` | Single-node boot, SMP (2 CPUs), Ring-3 daemons, MicroVM creation | **PASS** |
| `./test_qemu_cluster.sh` | 2-node cluster bootstrap, DIPC multicast, remote MicroVM launch | **PASS** |
| `SMOKE_PROFILE=vmx-linux ./test_qemu.sh` | Isolated Linux guest execution via VT-x | **PASS** |
| `SMOKE_PROFILE=vmx-linux-services ./test_qemu.sh` | Full stack: SMP + Linux guest + Ring-3 user services | **PASS** |
