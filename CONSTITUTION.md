# Catenary OS: Architectural Constitution

## 1. Mission and status

Catenary OS is a freestanding distributed microkernel and bare-metal Type-1 hypervisor, initially targeting x86_64 Intel VT-x/EPT. Its goal is to host isolated Linux MicroVMs, full Linux and Windows VMs, and Linux-based OCI workloads on a single node or across a cluster. Standalone operation must remain useful without a cluster.

The system is experimental. This constitution states architectural direction, not a guarantee that every capability is implemented or safe for production. The [architecture overview](docs/architecture.md) distinguishes the current baseline from the target; [PROJECT.md](PROJECT.md) records milestones and evidence. The [shared project rules](.agents/workflows/project-rules.md) apply these principles to contributions and AI agents.

## 2. Architectural pillars

### 2.1 Minimal exokernel (Ring 0)

Ring 0 owns physical frame allocation and isolation, CPU scheduling and context switching, hardware virtualization and guest-memory isolation, and local IPC. It also supplies the minimal interrupt, capability, IOMMU/DMA, and VM-exit mechanisms necessary to enforce those boundaries. It does not own network or storage policy, orchestration, UI, POSIX compatibility, or a Linux syscall ABI.

Existing guest device emulation and related bridge code include hardware-adjacent logic in or near Ring 0. This is a bring-up baseline, not the desired final placement of complex device backends or permission to add high-level policy to the kernel.

### 2.2 Isolated user-space services (Ring 3)

Device drivers and complex device backends, the network stack and virtual switches, firewall and address policy, virtual volumes and data protection, cluster coordination, and the operator interface belong in least-privileged Ring-3 services. Access to memory, devices, I/O, endpoints, and administrative operations is capability-scoped, bounded, and revocable. Physical DMA requires appropriate hardware confinement or a documented trusted-device model; bounce buffers alone cannot contain arbitrary device DMA.

### 2.3 IPC and trust

Local IPC and IPv6-first distributed communication enable user-space services to exchange messages across nodes. Location transparency must not hide authorization, remote failures, ownership, or backpressure. Authenticated node identity, confidentiality, replay protection, and authorization are required targets, not assumptions about the current shared-key DIPC path.

### 2.4 Guest networking and microsegmentation

Standalone and clustered nodes should provide host-managed virtual switches, virtual ports, and isolated logical segments. Each VM/vNIC has a host-assigned identity; guest-selected IP or MAC addresses do not confer authority. Per-port ingress and egress policy is default-deny and fails closed if authority or policy freshness cannot be established. Authorized segments can extend across nodes over an authenticated, encrypted, replay-protected fabric.

The host and cluster control plane are IPv6-first. Guest segments support both IPv4 and IPv6; IPv4 connectivity inside or outside a segment is not a reason to add an IPv4 stack to Ring 0. External routes, gateways, and translation are explicit Ring-3 policies.

### 2.5 VM profiles and support MicroVMs

The primary path is direct Type-1 execution: a lightweight Linux MicroVM profile and a generic full-VM profile booting approved firmware and guest media. The latter targets normal Linux distribution and Windows installations with appropriately supported virtual devices, durable disks, and guest security state. Support is claimed only for versions and configurations that pass documented acceptance tests. OCI compatibility is a goal of Linux guests, not a promise of universal compatibility.

An isolated Linux support MicroVM may run support services and, if Catenary later implements and validates nested virtualization, KVM and an authorized user-space VMM. It is optional and cannot be a dependency for host boot, direct VM execution, cluster quorum, storage recovery, or rescue administration. Per-L2 isolation cannot be inferred from identities asserted by an untrusted L1.

### 2.6 Storage and cluster operations

Provide local virtual block volumes for standalone use. The initial proposed distributed protection group has three data-capable nodes in distinct failure domains, a durable 2-of-3 metadata quorum, and two full durable copies on different nodes before acknowledging each write. Quorum alone is not data durability: require real persistence, ordered flushes, writer fencing, crash recovery, integrity checking, and safe membership changes. A minority or a group without two eligible copies must reject unsafe writes. Replicas are not backups.

The experimental [Span-Weave proposal](docs/STORAGE_PLAN.md) combines rotating data/audit roles with tension-directed repair. Its novelty, correctness, and fault tolerance are not established until independently reviewed and tested; it does not claim protection against two simultaneous node losses or malicious members.

The native operator UI should provide one cluster view from any healthy node through a shared authenticated, authorized, versioned management API. Cluster state, stale observations, failures, policy convergence, and quorum loss must be visible. A browser UI can later use the same API. Rescue and bootstrap must not depend on the cluster volume being recovered.

## 3. Independent implementation and interoperability

New Catenary platform components are independently authored; do not copy, adapt, port, wrap, or replace them with known hypervisor, network, storage, or orchestration implementations. Public specifications, hardware manuals, research, and established algorithms may inform an independent implementation. Do not invent cryptographic primitives or unsafe consensus algorithms merely to claim originality; use reviewed existing Zig standard-library cryptography when suitable.

The existing Catenary baseline, Zig and its standard library, Limine, and development/test tools remain. Guest operating systems, explicitly approved and licensed guest firmware and drivers, and optional Linux/KVM inside a support VM are exceptions, with recorded provenance and security updates. Any other new third-party runtime implementation requires explicit approval. Originality, worldwide novelty, and patentability are not assumed.

## 4. Technology and validation

- **Language and initial host:** freestanding Zig on x86_64, initially using Intel VT-x/EPT. Other host architectures and virtualization backends require their own plans and validation.
- **Boot and development:** Limine and QEMU are existing host boot/development tools. QEMU using an external host's KVM is a test arrangement, not proof that Catenary exposes nested KVM to its own guests.
- **Evidence:** Keep model and simulated-trace tests, live QEMU integration, and physical-host/guest acceptance distinct. A feature, durability claim, or security property is not established by a model, a single log marker, or the presence of code.
- **Planning:** Earlier phases are historical records; future dependencies, acceptance criteria, and status are maintained in [PROJECT.md](PROJECT.md) and [TEST_INFRA.md](TEST_INFRA.md).
