# Catenary OS Architecture

Catenary OS is an experimental freestanding Zig microkernel and Type-1 hypervisor. The [constitution](../CONSTITUTION.md) is authoritative; this document separates the existing bring-up paths from the planned standalone and clustered platform. Phase status and dependencies are in [PROJECT.md](../PROJECT.md).

## 1. Existing foundation and evidence limits

- **Kernel and services:** The repository contains physical-frame allocation, paging, scheduling, IPC, Limine boot, Ring-3 service launch, and x86_64 VMX/EPT paths. [Hardening](../src/arch/x86_64/hardening.zig) attempts CPU-supported protections; actual enabled state and safety require runtime evidence. Their presence is not a production-isolation claim.
- **Guests:** [Linux boot](../src/vmm/linux_boot.zig) parses a Linux `bzImage` and builds boot parameters; [VMX](../src/arch/x86_64/vmx.zig) and the [instance registry](../src/vmm/microvm_registry.zig) contain guest execution and per-instance state. This is not a generic UEFI platform or proof of complete per-vCPU isolation. The historical Linux smoke profiles are described in [SETUP.md](SETUP.md).
- **Networking and control:** [virtio-net](../src/vmm/virtio_net.zig), the [MicroVM bridge](../src/vmm/microvm_bridge.zig), [DIPC router](../src/ipc/router.zig), and `netd` are building blocks; discovery, remote launch and telemetry are described in the historical [Phase 7 record](PHASE_7_ROADMAP.md). They are not a secure guest vSwitch, firewall, or encrypted VM overlay.
- **Storage:** [storaged](../src/user/storaged.zig) has an NVMe path but also synthetic acknowledgements, and its guest flush is a no-op. No successful smoke marker or immediate readback proves crash-safe persistence or replicated storage.
- **UI:** `windowd`, `dashd`, and related services provide a native TUI and telemetry foundation, not yet a complete authenticated common cluster-management API.
- **Testing:** The 50 historical Phase 9 cases in [TEST_READY.md](../TEST_READY.md) include models and simulated traces, not live-system proof. No specific current build, QEMU, guest, or hardware result is implied by these descriptions.

## 2. Exokernel and service boundaries

Ring 0 owns physical isolation and frame allocation, scheduling, local IPC, Intel VMX/EPT and the minimal interrupt, capability, DMA-mapping, and VM-exit mechanisms needed to enforce isolation. Ring 3 owns device drivers and complex backends, virtual networking and firewall policy, virtual storage and recovery, cluster coordination, and the UI.

Existing guest device and bridge paths still include Ring-0-adjacent handling. The target is to move complex interpretation and policy behind bounded, capability-scoped Ring-3 interfaces without weakening hardware isolation. Every shared page, descriptor, buffer, and DMA grant needs explicit ownership, bounds, lifetime, revocation, and failure cleanup; see [DIPC ownership](DIPC_OWNERSHIP.md). IOMMU confinement or an explicit trusted-device model is required for physical DMA: a bounce buffer alone does not sandbox a malicious bus master.

The current [reserved endpoints](../src/ipc/identity.zig) include `netd` 1, kernel control 2, router 3, `storaged` 4, `dashd` 5, `containerd` 6, `clusterd` 7, `inputd` 8, `windowd` 9, and `configd` 10. An endpoint number or service name alone is not authorization.

## 3. VM execution — target

Both Linux MicroVMs and full VMs are primarily direct Type-1 guests. Each VM needs an isolated guest-physical address space, host-assigned identity, capabilities, virtual devices and lifecycle; each vCPU needs independent execution, interrupt and scheduling state. Full VMs add a virtual PC, approved guest UEFI firmware, durable disk and firmware state, networking, graphical input/output, and, for the Windows profile, Secure Boot and vTPM. Ubuntu Server 26.04 LTS and Windows 11 Pro 26H2 are proposed initial acceptance targets, not supported configurations today.

A support MicroVM is optional. Running Linux/KVM inside it requires Catenary to expose correctly virtualized nested VMX, as well as a guest user-space VMM. The existing external host-KVM/QEMU setup tests a different nesting arrangement. Boot, recovery, storage quorum, and direct VMs cannot depend on the support VM. See the [virtualization plan](VIRTUALIZATION_PLAN.md).

## 4. Networks and trust — target

The host and cluster control plane are IPv6-first; guest networks support IPv4 and IPv6 inside isolated virtual segments. Ring-3 virtual switches should apply default-deny ingress and egress policy to host-assigned VM/vNIC identities, not guest-supplied MAC/IP addresses. Cross-node segments require mutually authenticated, encrypted, replay-protected transport, explicit policy versioning, and failure-safe revocation. Guest Ethernet and DIPC control traffic are separate planes. See the [virtual network plan](VIRTUAL_NETWORK_PLAN.md).

[DIPC](../src/ipc/dipc.zig) uses page-backed messages with local authentication and a cluster-wide shared HMAC for cross-node traffic. The historical [Phase 7 record](PHASE_7_ROADMAP.md) identifies a replay gap; that shared key does not provide per-node identity or confidentiality. Secure enrollment and transport are planned in [cluster orchestration](CLUSTER_ORCHESTRATION.md), not already guaranteed.

## 5. Storage and cluster management — target

Local virtual disks should work on a standalone node. The proposed distributed [Span-Weave storage](STORAGE_PLAN.md) uses three data-capable nodes, a 2-of-3 metadata quorum, and two full copies on different nodes with real durable flush before a write is acknowledged. Checksums, writer fencing, safe recovery, bounded repair, backups, and no-quorum failure behavior are mandatory; current storage does not yet meet the contract.

One authenticated, versioned Ring-3 management API should serve a common native UI on any healthy cluster node. It manages VMs, consoles, nodes, virtual networks and policies, volumes, health and audit. It must distinguish desired from observed and stale state, and refuse unsafe changes without quorum or verified fencing. A browser UI is a later client of the same API. Local bootstrap and rescue remain independent of distributed volumes and support VMs. See [cluster orchestration](CLUSTER_ORCHESTRATION.md).

## 6. Implementation and validation policy

New Catenary platform implementations are independently authored from published specifications and established algorithms, not copied or adapted from known platform implementations. Existing project/toolchain components, approved guest operating systems, explicitly approved licensed firmware and drivers, and optional Linux/KVM in a support VM are the defined exceptions. Use established, reviewed cryptography rather than inventing primitives. See the [project rules](../.agents/workflows/project-rules.md) for approval and provenance requirements.

Separate model checks, live QEMU integration, and physical-host/guest acceptance; record exact configurations, failures, and limits rather than treating plans or synthetic traces as evidence. Future acceptance gates are in [TEST_INFRA.md](../TEST_INFRA.md).
