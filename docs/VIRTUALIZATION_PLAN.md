# Catenary virtualization plan

> **Status: proposed design, not an implementation or a compatibility claim.**
> Direct Type-1 virtualization is the primary route for both profiles below.
> All milestones and acceptance tests in this document are future work.

## 1. Scope and implementation policy

Catenary should host a lightweight Linux MicroVM and a generic x86_64 full VM
directly on its own Intel VMX/EPT hypervisor. The first full-VM acceptance targets
are **Ubuntu Server 26.04 LTS x86_64** and **Windows 11 Pro 26H2 x86_64**. These
are targets, not supported guests today. A Linux support MicroVM offering nested
KVM is optional and must not be needed to boot or operate either direct profile.

The platform and its VMM, device models, services, and orchestration are to be
independently authored for Catenary, not copied or adapted from another platform
implementation. Published specifications and established algorithms are valid
references; cryptographic primitives must come from an appropriately approved
standard library rather than being invented. Guest operating systems, explicitly
approved licensed guest firmware and drivers, and Linux/KVM in the optional
support VM are exceptions. The support VM's userspace VMM must itself be
independently authored or explicitly approved and licensed; it is not transplanted
into Catenary. Record provenance, versions, licenses, and security updates for all
approved external components. Guest installers, licenses, firmware, and drivers
are supplied or explicitly approved by the operator.

The initial host architecture is x86_64 Intel VT-x with EPT. AMD virtualization,
additional host architectures, live migration, GPU passthrough, and broad guest
compatibility are separate future projects, not prerequisites for these targets.

## 2. Current baseline and evidence limits

The following describes the checked-in and currently modified source, not a new
test result:

* The [Linux boot loader](../src/vmm/linux_boot.zig) parses an x86 Linux
  `bzImage` and constructs Linux boot parameters and a memory map. The
  [VMX core](../src/arch/x86_64/vmx.zig) stages a kernel and initramfs, configures
  VMX/EPT and guest state, and has Linux-entry and demo paths. The
  [guest asset notes](../assets/guest/README.md) describe the intended direct
  Linux bring-up. This is a Linux-specific experimental baseline, not generic
  firmware boot.
* The [instance registry](../src/vmm/microvm_registry.zig) contains per-instance
  EPT-root, VMCS, quota and some device fields, and the VMX code has per-host-CPU
  resources. However, the VMX core also has shared or fallback state, including
  PCI and LAPIC state. An instance-level `vcpus` field and a VMCS per instance do
  **not** establish isolated per-vCPU execution, multi-vCPU correctness, or
  multi-tenant safety. The create path now rejects requests other than one vCPU;
  that bounds the current profile but is not evidence that the remaining
  per-VM/per-vCPU isolation requirements are complete.
* Existing [virtio-net](../src/vmm/virtio_net.zig),
  [virtio-blk](../src/vmm/virtio_blk.zig), and
  [MicroVM bridge](../src/vmm/microvm_bridge.zig) code are bring-up paths, with
  substantial guest device handling still adjacent to Ring 0. They are not
  evidence of the bounded userspace backends described below. The
  [storage service](../src/user/storaged.zig) now rejects requests without
  NVMe, serializes the shared block request layout, and issues NVMe Flush when
  a volatile write cache is present. Virtio FUA is handled with a write-then-
  flush fallback rather than the NVMe Write FUA bit. Scoped buffer grants,
  power-loss/recovery evidence, and a durability guarantee remain absent.
* The initial Phase 10 lifecycle change makes stop asynchronous: a running VM
  enters `stopping`, and the VM-exit path declines to resume it once a state
  check observes that request. Deletion stays blocked until guest execution has
  returned to the host. Launch failures and unexpected VMX exits are recorded as
  `failed`. Stop has no bounded response time if the guest does not exit. This
  is not a complete vCPU teardown or proof that VM resources are safely
  reclaimed; those remain acceptance work. Registry deletion now also refuses
  to clear an instance while it still owns VMCS, EPT, or guest-pool allocations.
  This prevents losing the only allocation references and reusing a registry
  slot before a reclaimer exists; deletion of launched VMs therefore remains
  unavailable rather than pretending teardown succeeded. The virtio-net
  backend also rejects TX queue processing and RX injection unless the registry
  still reports the VM as running; a kernel regression test covers both paths
  after a stop request.
* The [QEMU smoke script](../test_qemu.sh) defines Linux guest serial milestones
  and can run Catenary inside QEMU accelerated by the **external host's** KVM.
  Its presence is not a recorded successful run. Some
  [scenario tests](../tests/tier4_scenarios/test_real_world_scenarios.py) use
  models and constructed traces; those are not live VM evidence.
* General-purpose UEFI boot, Windows installation, vTPM 2.0, a durable
  virtual-disk contract, and Catenary-provided nested VMX/KVM are unimplemented
  as complete end-to-end features in this VMM. No firmware, Windows, nested-KVM,
  or physical-host acceptance test was run as part of this documentation change.

In the existing QEMU/KVM smoke arrangement, the external Linux/KVM host is L0,
Catenary is L1, and its test Linux guest is L2. That arrangement is useful for
testing Catenary's existing VMX path; it does **not** prove the different design
in section 8, where Catenary itself is L0 and supplies nested VMX to an L1 Linux
support VM.

## 3. Boundaries and profiles

The [constitution](../CONSTITUTION.md) and
[project rules](../.agents/workflows/project-rules.md) define the exokernel
boundary. Host Ring 0/Ring 3 here are Catenary privilege levels; they are
distinct from guest OS privilege levels and VMX root/non-root modes.

| Component | Proposed responsibility |
| --- | --- |
| Catenary Ring 0 | Physical frame ownership and isolation; scheduler and accounting; per-host-CPU VMX operation; per-VM EPT and per-vCPU VMCS/state; capability validation; bounded local IPC; hardware interrupt and VM-exit entry, safe classification, and interrupt injection. Expose only narrow, validated operations for IOMMU mappings, pinned pages, and hardware access. |
| Catenary Ring 3 | VM lifecycle and policy; firmware/image selection; virtual PCI, storage, network, console, keyboard/mouse, and other complex device backends; physical drivers; variable and vTPM services; quotas, backup, and orchestration. Each service receives only the capabilities needed for the assigned objects. |
| Guest | An untrusted OS and its drivers execute in VMX non-root mode with only the assigned virtual machine and devices. Guest requests, descriptors, addresses, timing, and firmware contents are untrusted input. |

Ring 0 must handle the hardware-adjacent part of each VM exit: save the correct
vCPU context, check the reason and ownership, preserve architectural exception and
interrupt semantics, and safely block, resume, or report a fault. Minimal CPU,
MSR, paging, and interrupt handling may remain there when necessary for isolation.
Complex device interpretation, queue processing, protocols, and policy move to
bounded Ring-3 backends. This is a transition from the current in-kernel device
paths, not a claim that the transition is complete. An exit that cannot be
handled safely must fail the affected VM or inject the architecturally
appropriate fault; it must not skip the guest instruction or advance state on an
unresolved operation.

| Profile | Boot and devices | Intended use |
| --- | --- | --- |
| Linux MicroVM | Direct Linux `bzImage`/initramfs boot, serial console, narrowly selected virtio devices and optional persistent volume. UEFI is not required for this profile. | Small, controlled Linux workloads and, only when requested, the L1 support VM. |
| Full VM | Guest UEFI firmware, persistent variable store, installation media and disk, virtual PC platform, networking, serial plus graphical console/input, and vTPM where required. | Normal installation and boot of the two pinned guest targets. |

Both profiles use the same isolation, admission, lifecycle and resource contracts.
Neither requires a Linux host or support VM. A full Ubuntu installer is not the
same evidence as a direct-boot MicroVM with a custom Linux kernel.

## 4. VM objects, admission, and lifecycle

### State and invariants

* A **VM** has an unforgeable host-assigned identity and generation, owner and
  capabilities, a versioned machine profile, an isolated guest-physical address
  space/EPT root, RAM and MMIO map, device/IRQ routing, clocks, volumes, console,
  network ports, and, for full VMs, firmware variables and optional vTPM state.
  No VM may address another VM's pages, devices, queues, variables, or keys.
* Each **vCPU** has its own VMCS, registers including extended/FPU state,
  control/MSR state, interruptibility and pending events, local APIC/timers, and
  scheduling/accounting state. vCPUs of one VM share that VM's EPT under
  synchronization; different VMs do not share EPT roots or private frames.
  VMXON regions and host exit stacks are per physical CPU. No global current-VM,
  PCI, interrupt, or device fallback may substitute for the correct object.
* The machine profile exposes only CPU features, MSRs, interrupt modes, and
  memory-map ranges actually implemented and validated. Start secondary vCPUs
  with correct architectural startup and interrupt semantics. Nested VMX is
  hidden/disabled by default until the separate nested gate passes. Reuse,
  revocation, and changes of EPT mappings require appropriate Intel invalidation
  and cross-CPU acknowledgement before frames or VM identifiers are reused.
  Zero private frames on allocation/reassignment, and clear sensitive state on
  teardown.

### Admission and limits

Before publishing a VM or enabling any device, atomically validate its principal,
profile, requested CPU features and firmware, and reserve or account for vCPUs,
guest RAM, VMCS/EPT/page-table and backend memory, pinned/bounce pages, interrupt
routes, device queues, console buffers, and storage capacity. Bound CPU time and
exit rate, memory, I/O operations and bandwidth, network ports, queue depth,
snapshots, and console traffic; retain host capacity for critical services. The
minimum Windows guest RAM and disk are guest-visible allocations, not the whole
host requirement. Thin provisioning must have an explicit capacity policy and
must report exhaustion, not silently promise unavailable space. Reject missing
hardware, quotas, trusted firmware, durable storage, or capabilities before
launch; roll back partial reservations. CPU and storage usage are charged to the
owning VM, including work delegated to its backends.

### Lifecycle and failure cleanup

The intended state machine is `defined -> admitted -> starting -> running`,
with `running <-> paused`, `running/paused -> stopping -> stopped`, and an
explicit `failed` state. A stopped VM may be started again; delete is a separate
authorized operation. Requests carry an idempotency ID and VM generation, and
report observed state and errors rather than assuming a request succeeded.
Graceful shutdown waits for the guest and its I/O; forced stop is reported as a
crash, not a clean shutdown. Reboot resets vCPU and device state while retaining
the authorized disk, EFI variables, and vTPM identity.

On stop, failed launch, backend crash, or delete:

1. Fence new submissions and ingress, stop all vCPUs, and invalidate the VM
   generation so stale completions cannot reach a restarted VM.
2. Drain or cancel bounded I/O; report failures and indeterminate writes rather
   than acknowledging them. Quiesce devices, disable bus mastering where
   applicable, revoke DMA mappings, and wait for device and IOMMU invalidation.
3. Revoke capabilities and memory grants, unmap EPT and invalidate translations
   on all relevant CPUs, clear secrets and pages, then release accounting. If a
   device or invalidation cannot be proven quiescent, quarantine its pages and
   reservations rather than reuse them.
4. Preserve persistent volumes and security state unless separately authorized
   deletion is requested. Audit deletion, key destruction, failures, and
   quarantine; do not leak guest data or keys in logs.

## 5. Device, storage, network, and console contracts

### Capability-scoped I/O and DMA

An exit or device notification carries a kernel-authenticated VM/vCPU identity,
device and queue capability, operation, and generation; an untrusted guest or
backend-supplied VM ID is not authority. Grant a backend only the device, volume,
port, interrupt, and guest-memory ranges/directions needed for its work, with
bounded length and lifetime. Copy or pin validated descriptors under a defined
ownership protocol, check arithmetic, permissions and every page, bound chains
and outstanding requests, and defend against guest mutation and stale completion
races. A request cannot turn a guest physical address into unrestricted host
physical access. Queues have explicit backpressure and release ownership on all
success, error, timeout, reset and process-death paths. The existing
[DIPC ownership design](DIPC_OWNERSHIP.md) is a starting point, not proof that
these new grants exist.

Virtual devices normally copy through controlled buffers; guests do not directly
program host devices. For physical DMA, enforce device-specific IOMMU mappings
to pinned, authorized pages with invalidation and teardown, or use bounded
host-owned bounce buffers for a **trusted and constrained** physical device and
driver. Bounce buffers alone cannot stop a malicious bus-mastering device or a
driver able to program arbitrary DMA addresses. Without enforceable confinement,
do not attach an untrusted DMA-capable device or offer passthrough; treat any
necessary unconfined device/driver as part of the trusted host and restrict its
access. EPT by itself does not constrain physical DMA.

### Virtual disks and persistence

Expose per-VM virtual block volumes as opaque sectors; Catenary need not interpret
guest NTFS or ext4. The operator assigns immutable volume identities, capacity,
access mode, backing store, and a single-writer/fencing policy. Installation
media is read-only. A write completion follows the advertised cache policy; it
is not automatically a power-loss durability guarantee. A successful guest flush
is an ordered barrier: all prior relevant writes reach the promised durable
backing medium before success is returned. FUA must make its associated write
durable; it is not assumed to be a barrier for unrelated writes unless the
advertised device contract says so. Use real flush/FUA through every volatile
layer and serialize barriers across queues as needed.
Propagate I/O errors, full capacity, missing media, and uncertain timeouts; do not
report a no-op flush or synthetic acknowledgement as persistence. Reject a
durability-requiring profile if the backing store cannot provide this contract.

The existing [storage plan](STORAGE_PLAN.md) is a complementary overview; its
future implementation must define the volume, flush, recovery, and backup
contracts above. Standalone local volumes are sufficient for initial direct
acceptance; clustered storage and quorum are not prerequisites for a local VM.

### Networking

Give each direct VM a host-created vNIC/port bound to its principal, with bounded
queues and explicit segment and ingress/egress policy. Guests may use IPv4 and
IPv6 inside their virtual segments; host/cluster control remains IPv6-first and
the network stack and policy remain in Ring 3. Start with deny-by-default and
explicitly authorize needed address configuration, DNS, and connectivity; do not
trust guest-supplied MAC/IP as identity. Separate guest Ethernet from DIPC control
traffic. Missing or stale policy and backend failure fail closed. A disconnected
uplink drops or reports affected traffic without a policy bypass; authorized
local traffic may continue while its policy remains valid. Local switching,
external routing, and authenticated cross-node transport need their own tests;
current bridge code and shared cluster credentials do not prove these properties.
The proposed [virtual network plan](VIRTUAL_NETWORK_PLAN.md) and
[cluster orchestration design](CLUSTER_ORCHESTRATION.md) specify complementary
future work; neither is evidence of implemented enforcement.

### Serial and graphical access

Serial is the initial MicroVM diagnostic console, with per-VM input/output,
bounded buffers, access control, and audit. Full VMs additionally need a
guest-visible graphical adapter with a firmware Graphics Output Protocol (GOP)
and a guest-compatible basic display path, plus virtual keyboard **and** mouse.
The Ring-3 console presents only an authorized VM's framebuffer and input,
bounds dimensions and update queues, and isolates sessions. For Windows, test an
interactive visible console or an explicitly configured, authenticated,
policy-permitted RDP path; installation and recovery still need a working
boot-time interaction path.
No physical GPU passthrough is required.

Basic framebuffer boot and interaction are not evidence of a WDDM 2.0 driver,
DirectX 12, hardware acceleration, or Microsoft/vendor support. Microsoft's
published Windows 11 hardware requirements include DirectX 12 with WDDM 2.0 and
a 720p display. A qualifying paravirtual graphics device and signed driver require
a separate implementation and acceptance gate before claiming those graphics
requirements are met. Do not promise graphics features or vendor certification
merely because an installer or desktop appears.

## 6. Proposed generic UEFI full-VM platform

1. Select an explicitly approved, licensed x86_64 UEFI firmware image, verify its
   provenance/hash, and map its code read-only into the VM with a distinct
   writable, persistent EFI variable store per guest. Catenary supplies a virtual
   hardware/memory map and resets the guest to the firmware's required entry
   state. This guest firmware is separate from the host's Limine boot path.
2. Attach a user-provided installer as read-only virtual media and a writable
  persistent virtual disk, or attach an operator-provided bootable disk image
  or volume without an installer. Firmware enumerates the devices and normally
  loads the signed EFI bootloader from the selected installer or disk. During a
  new installation the installer partitions/formats the target disk and
  installs the guest OS; do not overwrite an existing disk without authorization.
  Later reboots use the guest's EFI boot entries and disk. Catenary does **not**
  parse or load a Windows kernel.
3. Provide a versioned virtual PC contract: coherent RAM/reserved/MMIO and
   firmware maps; ACPI tables matching actual CPU topology, interrupts, PCI and
   power behavior; virtual LAPIC/IOAPIC and applicable PIC/MSI/MSI-X delivery;
   monotonic clock/RTC and required timers; PCI/PCIe configuration and resource
   windows; and correct reset, shutdown and secondary-vCPU startup. Implement
   only advertised features, including any system-management or runtime-service
   behavior required by the selected firmware, and validate table checksums and
   interrupt/timer behavior against the real guests.
4. Initial device selection to prove is an independently authored standards-based
   PCI AHCI/SATA controller with disk and ATAPI installer media, plus a NIC with
   validated inbox guest drivers or virtio-net PCI with explicitly approved signed
   drivers. An independently authored virtio-blk PCI device is an alternative
   when both the selected firmware and installer can access it and the correct
   guest drivers are available. Confirm the actual firmware's storage, display,
   keyboard and mouse support; choose another standards-based device if this
   combination fails. No candidate is assumed compatible until tested.

### Secure Boot and guest variables

For the Windows acceptance profile, UEFI must be Secure-Boot-capable **and
enabled**, with an operator-approved trust policy. The approved firmware and
variable service enforce authenticated updates to the platform key (PK), key
exchange keys (KEK), allowed database (`db`), and revocation database (`dbx`).
Provision keys that authorize the chosen signed boot chain and drivers, maintain
revocations, and permit key enrollment/rotation only through an authorized,
audited procedure. Do not silently enter setup mode, disable verification, accept
an empty trust database, or bypass installer checks. Firmware code integrity and
the variable-store policy are both part of the trust boundary.

Persist each guest's EFI boot entries and authenticated variables atomically
with crash recovery and access scoped to that VM. Protect against corruption,
cross-VM access, and unauthorized rollback; identify and test the freshness
anchor and recovery procedure rather than claiming rollback resistance from
encryption alone. Firmware, key or revocation updates must be tested for boot and
recovery before rollout.

### Virtual TPM 2.0

Provide a per-VM TPM 2.0 device and command/state implementation conforming to
the selected [TCG specification](https://trustedcomputinggroup.org/resource/tpm-library-specification/).
Use an independently authored implementation, except for an explicitly approved
licensed firmware/driver component within the stated exception. Verify the
capabilities and algorithms the selected Windows build actually needs, not just
the reported version.

Each instance has unique, durable hierarchy/key/NV state and isolated access;
encrypt and authenticate that state at rest with a per-VM key protected by an
approved host key service and trust root. Restrict key release and backups to the
authorized VM and operator, use a cryptographically secure entropy source, and
clear transient secrets. Preserve TPM identity and sealed-key usability across
normal guest and host reboots. Use an independently anchored generation or
equivalent verified anti-rollback mechanism; if the necessary anchor, trusted
key service, or state is unavailable, the secure profile fails closed rather
than silently creating a new TPM or permitting rollback. Authorized restore of
older state needs an explicit recovery procedure and may require guest recovery
keys. A software vTPM is protected by the host trust boundary: it is not a
physical TPM, independent hardware attestation, or protection from a compromised
host kernel.

## 7. Snapshots and backup consistency

Initial snapshots are offline snapshots or disk-state captures without RAM, not
live memory snapshots or migration. Prefer a clean guest shutdown. A
crash-consistent disk capture may instead pause all vCPUs and fence guest and
external writers; it presents a crash-like point in time, not a guarantee of
filesystem recovery or application consistency. Filesystem consistency requires
a successful guest filesystem quiesce and flush. Application consistency also
requires every participating application's writers to checkpoint or quiesce,
for example through Linux application hooks plus filesystem freeze, or successful
Windows VSS writers. Provide a bounded freeze with guest-side timeout/automatic
thaw and request thaw on both success and failure. If thaw cannot be verified,
report failure and recover or fence the guest; do not claim the requested
consistency level after a failed quiesce or timeout.

At one coordinated consistency point, drain in-flight I/O, issue the real
ordered flush, freeze the relevant device state, and capture **all** VM volumes,
EFI variables and vTPM state where present, firmware/profile identifiers, and
encryption/key metadata as a single generation. Publish a manifest only after
every component is durably captured; if atomic group capture or the necessary
fencing is absent, fail rather than publish a mixed snapshot. Interrupted capture
leaves the last committed generation usable. Restore verifies integrity,
permissions, firmware compatibility, key availability and anti-rollback policy
before allowing a single writer. Restoring a disk-state capture of a running VM
starts it as a cold boot; the original can continue after a successful thaw.
Capturing RAM, vCPU state, pending I/O and timers for live restore is later work.

Backups are independent, encrypted, integrity-checked copies with scoped key
recovery, retention and deletion policies; a local snapshot or replica alone is
not a backup. Regularly test restoration into an isolated environment, including
EFI and TPM-dependent guest recovery. Do not start the original and a restored
copy with the same VM/TPM identity concurrently; cloning requires a new identity
and an explicit guest/key migration procedure. Host bootstrap and recovery must
not require the optional support VM or the volume being recovered.

## 8. Optional Linux support VM and nested KVM

This is a distinct, later path:

* **L0:** Catenary on physical Intel hardware, enforcing the host's isolation,
  resource accounting and capability policy.
* **L1:** a resource-bounded Linux support MicroVM. KVM is a subsystem of its
  Linux kernel; it exposes `/dev/kvm` to a permitted L1 userspace VMM.
* **L2:** a Linux or Windows VM created by that L1 VMM. KVM supplies CPU
  virtualization interfaces, not an entire PC: the independently authored or
  explicitly approved L1 userspace VMM still needs memory setup, virtual devices,
  storage, console, network, and approved firmware/driver backing.

The support VM is opt-in, least-privilege, bounded in CPU, RAM, disk, I/O and
network access, and controlled through scoped capabilities. It receives no
unrestricted host device, volume, management or cluster credentials. Neither
bootstrap, recovery, storage quorum, nor direct VM operation depends on it. If
it fails, fence its I/O and ports, report its L2 workload unavailable, clean up
as in section 4, and keep direct guests and critical host services independent;
do not silently weaken isolation or divert direct VMs through it.

Nested support requires substantial new L0 work, not just exposing a CPUID bit:

1. Detect physical VMX/EPT controls and the complete supported nested feature
   set. Expose consistent virtual CPUID, VMX capability MSRs, feature-control and
   CR state only to an authorized L1. Otherwise report nesting unavailable and
   hide it; do not fall back silently to software emulation and call it KVM.
2. Virtualize the VMX instruction and MSR interface safely, including VMXON,
    VMXOFF, VMCS pointer/read/write/clear operations, VMLAUNCH, VMRESUME and
    exposed invalidation instructions. Emulate entry/exit controls, status/flags,
    errors and L1-visible exits according to the advertised capability set.
    Validate L1's requested state and controls before L2 entry; L1 must never
    control L0's host VMCS, MSRs, page tables, or interrupt routing.
3. Compose L2 guest-physical to L1-physical translation with L0's mapping from
   L1 physical to host physical. Effective permissions are no broader than both
   mappings; L1 cannot map host or other-VM memory. Correctly handle invalidation
   of composed translations, EPT/VPID and TLB caches, page pinning, permission
   changes and concurrent vCPUs before reuse.
4. Route interrupts, exceptions, timers and safe exits among L2, L1 and L0
    without losing events or exposing host state. Charge all L1 and L2 CPU time,
    memory, exits and I/O to the L1 principal, including expensive emulation,
    without double-counting the same CPU execution. Do not snapshot or migrate
    nested state live until complete serialization and restoration are validated.

The initial security model is **one L2 and its support L1 as one L0 principal**.
If an untrusted L1 runs multiple L2s, L0 treats all of them and L1 as that same
principal: it cannot infer trustworthy per-L2 identity from guest-supplied
MAC/IP addresses or L1's assertions, nor claim host-enforced per-L2 firewall or
resource isolation. Per-L2 policy requires a separately designed and proven
host-controlled identity/port binding that the L1 cannot forge or inject into,
with the corresponding memory, device and accounting isolation. Until that is
demonstrated, use separate L1 support VMs for separate host principals.

## 9. Proposed milestones and release gates

All entries are **planned**; identifiers are local to this document and do not
change historical phase status. Tests and evidence below must be implemented and
recorded before promoting a gate.

| Milestone | Work and dependencies | Exit gate |
| --- | --- | --- |
| V0 — Baseline | Capture repeatable current direct-Linux smoke evidence and inventory hardware/firmware features without assuming model tests are integration tests. | Documented smoke result and host feature inventory; no new compatibility claim. |
| V1 — Isolated VM core | Implement per-VM/per-vCPU state, admission, invalidation, teardown, scoped grants and move complex device handling to bounded Ring 3; retain the direct MicroVM path. | H1, I1 and D1. |
| V2 — Durable local I/O | Implement real ordered block flush/FUA, isolated volumes, serial and bounded network backends; depends on V1. | D1 and D2. |
| V3 — Generic UEFI and Ubuntu | Add the full virtual PC, approved guest firmware, install media and persistent variables; depends on V1 and V2. | F1 and U1. |
| V4 — Windows security and interaction | Add approved Secure Boot key policy, persistent isolated vTPM 2.0, compatible basic display and keyboard/mouse, and signed guest drivers; depends on V1–V3. | F1, F2 and W1. WDDM/DirectX/vendor support remains a separate gate. |
| V5 — Snapshots and backup | Add coordinated offline and disk-state capture, protected security state and restore; depends on V2 and V3, and V4 for TPM-bearing guests. | S1 for the applicable guest security profile. |
| V6 — Optional nested KVM | Add the section 8 L0 mechanisms and bounded support VM; depends on validated V1/V2 isolation. L2 full-VM targets also depend on V3/V4-equivalent L1 device/firmware support. | N1; never a dependency of V1–V5 or host recovery. |

### Hardware and adversarial acceptance

* **H1 — Host eligibility.** On a documented physical x86_64 Intel host, record
  CPU model/stepping, microcode, RAM, storage, firmware settings and Catenary
  revision. Check VMX permission, required VMX controls, EPT and required
  invalidations, and any IOMMU isolation claimed by the configuration. Exercise
  missing/disabled features and invalid controls: admission must reject them
  without a host fault. Provision enough real host RAM and disk for the guest
  minimums **plus** host, device and metadata overhead. QEMU smoke results are
  useful regressions but do not replace physical-host evidence.
* **I1 — CPU/memory/lifecycle.** Run two mutually untrusted VMs with the same
  guest-physical addresses and different canaries; attempt cross-VM memory,
  device, interrupt, console and capability access. Exercise at least two
  concurrently active vCPUs in one VM, startup/IPIs, timer delivery, preemption,
  pause/resume, reset, invalidation and concurrent teardown/restart. Verify
  register/MSR/extended-state preservation, no cross-VM leakage, bounded CPU
  use, and that stopping or faulting one VM does not stop another.
* **D1 — I/O and DMA.** Send malformed, overflowing, cyclic, cross-page,
  wrong-direction and cross-VM descriptors, exhaust queues/quotas, kill a backend
  during I/O, and race reset with late completions. Invalid operations fail or
  affect only the responsible VM; no host/other-VM access or leaked resources.
  Test IOMMU mapping, revocation and invalidation on claimed hardware; test
  bounce-buffer limits under the explicitly trusted-device assumptions.
* **D2 — Durability.** Verify ordered guest writes, flush/FUA, error and full
  disk propagation against a real durable backend. Inject failures and sudden
  power loss before and after write and flush acknowledgements; after recovery,
  every successfully flushed write and its ordering must meet the advertised
  contract. Confirm synthetic/no-op paths cannot pass this gate. Once EFI and
  vTPM are available at later milestones, also test their persistent state across
  host power cycles; V2 does not depend on those later components.
* **F1 — Firmware platform.** With approved firmware/media, check the
  advertised memory map, ACPI, vCPU topology, PCI, storage, interrupts and timers
  against guest observations. Verify independent EFI variables and boot entries
  survive guest and host reboot. This gate does not require the later vTPM work.
* **F2 — Secure Boot and vTPM.** With Secure Boot enabled, reject a deliberately
  untrusted or revoked bootloader. Verify TPM 2.0 feature support, independent
  encrypted state, sealed-key persistence, authorized key/state recovery, and
  rejection of cross-VM access, tampering and unauthorized rollback. Failure to
  obtain trusted keys/state prevents secure-profile launch. This tests security
  state recovery independently of V5's coordinated snapshot facility.

### Version-pinned guest acceptance

Record exact ISO/build and hash, guest edition, CPU profile, firmware and key
policy, virtual device/driver versions and signatures, host revision, settings,
test results and known limitations for every run. Use approved, appropriately
licensed media; do not bypass the guest's requirements.

* **U1 — Ubuntu Server 26.04 LTS x86_64.** On the direct full-VM profile,
  perform at least two independent clean installs from the pinned installer to
  separate persistent disks through normal UEFI boot. For each, reach login,
  verify the expected guest version and device enumeration, perform at least two
  guest reboots and a host restart, and demonstrate allowed networking. Write and
  guest-flush identifiable data, then verify its hash after the reboots and host
  restart. Check denial on an unauthorized network path. A separate direct
  `bzImage` MicroVM test may validate that profile, but does not substitute for
  this installer/disk test.
* **W1 — Windows 11 Pro 26H2 x86_64.** Provide at least **2 vCPUs**, **4 GB
  guest-visible RAM** and a **64 GB virtual disk**; use at least 4 GiB and 64
  GiB respectively when provisioning binary-sized resources. Check the actual
  host processor against Microsoft's applicable Windows 11 processor
  requirements, and expose required guest CPU features, including NX/DEP and the
  pinned installer's instruction set, only when supported.
  Use Secure-Boot-capable UEFI with Secure Boot **enabled**, a ready TPM **2.0**
  with the protected persistent state above, approved user-provided installer
  media and appropriately signed drivers. Verify guest-reported CPU, memory,
  storage, Secure Boot status and TPM version/readiness; do not bypass checks.
  Perform at least two independent clean installations, each with at least two
  guest reboots and a host restart. Demonstrate visible graphical interaction
  with keyboard/mouse or a previously configured and tested authorized RDP path,
  working network and denial of an unauthorized path, and guest-flushed data
  whose hash survives restart. Verify the same TPM identity and access to a
  guest-created sealed object after reboot. Record the graphics/driver result
  separately from installation success and from any vendor-support claim.
* **S1 — Capture and restore.** Restore a clean offline snapshot and an
  explicitly crash-consistent capture; verify all disks and EFI entries belong
  to the same committed generation. For TPM-bearing guests, also verify vTPM
  state and keys in that generation and exercise the TPM-dependent guest recovery
  procedure after V4. Inject failure at every capture and manifest-commit boundary,
  test filesystem and application quiesce outcomes and consistency labels,
  quiesce failure/thaw, authorized and rejected rollback, unavailable keys, and
  isolated backup restore. No incomplete snapshot may be reported successful.
* **N1 — Optional nested path.** On eligible physical hardware, enable nesting
  only for a scoped L1. Verify L1 Linux actually opens `/dev/kvm`, creates and
  runs an L2 through KVM, and correlate L1/L0 evidence of accelerated nested
  execution; a userspace software emulator or the external host-KVM smoke test
  does not pass. Exercise L2 Linux and, once its separate firmware/device
  prerequisites exist, Windows; test virtual VMX errors, EPT permission and
  invalidation races, interrupts, quotas, and hostile L1/L2 input. Disable a
  required feature and confirm a clear unavailable result. Crash or exhaust L1,
  verify its traffic is fenced and its whole principal accounted for, and verify
  direct guests, bootstrap, recovery and quorum do not depend on it. Test spoofed
  L2 identities as the same L1 principal unless the separate host binding is
  proven.

## 10. Compatibility matrix and open decisions

Maintain a matrix per exact guest version, Catenary revision, physical host,
firmware, device/driver set and boot mode. Distinguish `planned`,
`tested experimentally`, and `supported`, and attach dated reproducible evidence
for install, reboot, networking, persistence, security, console and any graphics
claims. A result for one profile, host, or version does not extend to others.

| Guest/profile | Current status | Acceptance | Not implied |
| --- | --- | --- | --- |
| Existing custom Linux `bzImage` MicroVM | Experimental implementation and smoke paths exist; no fresh result asserted here. | V0/V1 plus profile-specific evidence. | Ubuntu installation or full-VM support. |
| Ubuntu Server 26.04 LTS x86_64, direct full VM | Planned; not yet accepted. | V3 / U1. | Other Ubuntu releases or Linux distributions. |
| Windows 11 Pro 26H2 x86_64, direct full VM | Planned; not yet accepted. | V4 / W1. | WDDM/DirectX, GPU passthrough, vendor certification, or other Windows versions. |
| Linux or Windows L2 via support VM | Planned; nesting not established. | V6 / N1 and relevant L2 guest gates. | Host-enforced per-L2 isolation within a shared untrusted L1. |

Before implementation, select and validate the approved firmware and licensing,
actual boot/storage/NIC/display/input devices and signed drivers, the vTPM trust
root and rollback/backup procedure, and hardware suitable for durable-flush and
DMA testing. The initial storage and networking documents do not yet establish
all required contracts. Side-channel mitigations, malicious-host confidentiality,
live migration, additional guests, 3D acceleration and vendor certification need
separate threat models and evidence; none follows automatically from this plan.

## 11. References and complementary designs

Existing repository context: [architecture](architecture.md),
[storage](STORAGE_PLAN.md), [virtual networking](VIRTUAL_NETWORK_PLAN.md),
[cluster orchestration](CLUSTER_ORCHESTRATION.md), [DIPC ownership](DIPC_OWNERSHIP.md), and
[test infrastructure](../TEST_INFRA.md). Their historical or proposed statements
are not evidence that the future gates above have passed. Detailed virtual
networking, durable storage, backup and cluster-control work are complementary
planned designs; they must preserve the boundaries and failure contracts here.

Official references, for specifications and requirements rather than copied
implementations:

* [Intel 64 and IA-32 Software Developer's Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html), especially the instruction reference, system programming/VMX and EPT, and MSR volumes; the same index links Intel VT-d documentation.
* [UEFI Forum specifications](https://uefi.org/specifications), including UEFI boot, Secure Boot/variables, and ACPI platform tables.
* [Microsoft Windows 11 hardware and VM requirements](https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements) and [Windows 11 release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information).
* [Canonical Ubuntu release cycle](https://ubuntu.com/about/release-cycle), for the 26.04 LTS release and lifecycle.
* [Linux nested KVM documentation](https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html) and [KVM userspace API](https://docs.kernel.org/virt/kvm/api.html), for L0/L1/L2 roles, capability checks and `/dev/kvm`.
* [TCG TPM 2.0 Library specification](https://trustedcomputinggroup.org/resource/tpm-library-specification/) and [OASIS virtio 1.2 specification](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html), for the selected virtual security and device interfaces.