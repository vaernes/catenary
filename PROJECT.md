# Project: Catenary OS - Phase 9 (Multi-VCPU, SMP MicroVMs & Live Serial Console)

> **Scope and evidence:** Phase 9 below preserves its existing milestone statuses and intended interface contracts: M1 is recorded as done and M2–M5 as planned. Some related code is present in the working tree, but source presence or a model test is not a live-system acceptance result. The historical 50/50 test report covers Python models and simulated traces, not a 50/50 QEMU or hardware run; see [TEST_READY.md](TEST_READY.md). The pre-existing working tree includes a `phase9` smoke-profile branch, but M4 remains planned pending real, per-guest integration evidence.

## Architecture
Catenary OS is a high-performance distributed exokernel operating system written in Zig (targeting Zig 0.17.0).
Phase 9 targets concurrent multi-MicroVM execution across SMP cores, with live guest serial console streaming and switching in the Ring-3 `windowd` TUI. A vCPU count or one VMCS per VM does not by itself establish correct multi-vCPU execution; that requires separate per-vCPU state and integration evidence.

### Intended subsystem architecture and interface contracts:
1. **Ring 0 Virtualization Core (`src/arch/x86_64/vmx.zig`, `src/arch/x86_64/smp.zig`, `src/arch/x86_64/gdt.zig`)**:
   - Independent 4-level EPT radix tree per MicroVM (`translateEptGpaToHpa`), eliminating flat `guest_maps` collisions.
   - Dedicated VMCS per MicroVM instance.
   - Per-core VMX initialization (`per_cpu_vmxon`, `vmx.initApCore(ap_idx)`) in `smp.apEntry`.
   - Per-core host exit stack (`per_cpu_host_stack`) and per-core `VMCS_HOST_TR_BASE` via `gdt.tssBaseForCpu(cpu_id)`.
   - Per-instance emulated device state (`VirtualDeviceState` for PIC, PIT, LAPIC, UART 0x3F8, PCI).
2. **Kernel Scheduler & Registry (`src/kernel/scheduler.zig`, `src/vmm/microvm_registry.zig`, `src/vmm/microvm_bridge.zig`)**:
   - Thread and Instance core affinity (`pinned_cpu: ?u8`), binding each MicroVM's VMCS to a dedicated SMP core.
   - Scheduler dispatch updated to allow AP cores to execute pinned VMX threads (`scheduler.zig`).
   - Spinlock-synchronized `microvm_registry` and `microvm_bridge` for multi-core thread safety.
3. **Console Syscall ABI & Trap Handling (`src/syscall_abi.zig`, `src/user/lib.zig`, `src/services/service_bootstrap.zig`, `src/arch/x86_64/user_mode.zig`)**:
   - Virtual 16550 UART with 4096-byte circular TX buffer and 256-byte RX FIFO.
   - Emulation of Data Ready (DR) in LSR, Received Data Available (RDA) in IIR, and IRQ4 interrupt assertion.
   - Dual-path TX: circular buffer in memory for `windowd` + mirrored to host physical COM1 with `[vm<id>]` prefix.
   - Syscalls: `SYS_GET_VM_CONSOLE_LOG = 28` and `SYS_VM_CONSOLE_INJECT = 29`.
4. **Ring 3 Compositor & TUI (`src/user/windowd.zig`)**:
   - `Pane.guest_console = 3`, using DMA slot 3 (`DMA_CONSOLE_SLOT`).
   - Interactive live guest serial console displaying streaming Linux guest `ttyS0` output.
   - Console switching between running MicroVMs via hotkeys (`[F6]` direct focus, `[F7]`/`[F8]` cycle VMs, `[C]`/`[Enter]` in VM manager).
   - Raw keyboard character forwarding to active MicroVM via `SYS_VM_CONSOLE_INJECT`.
   - Scrollback navigation via `[PageUp]` / `[PageDown]`.
5. **Test Harness & Smoke Automation (`test_qemu.sh`)**:
   - `SMOKE_PROFILE=phase9` running QEMU with `-smp 2` (or more).
   - Python monitor socket stream injection (`inject_ui_phase9_keys`) to provision/start MicroVM 2, switch console, and interact with guest shell.
   - Regex-based verification of concurrent core progression milestones, EPT isolation, console switching, and clean exit code 0.

---

## Feature Inventory
Every feature identified during the Survey phase is mapped to a milestone below.

| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | EPT Radix Tree Walker | Replace global `guest_maps` array with per-instance EPT PML4 radix-tree translation | M1 | Survey 1 §1.5, §2.1 |
| 2 | Dedicated VMCS Allocation | Allocate private VMCS physical pages per MicroVM instance | M1 | Survey 1 §1.1 |
| 3 | Per-Core VMXON Initialization | Enable CR4.VMXE and execute VMXON per online core in `smp.apEntry` | M1 | Survey 1 §1.3, §2.2 |
| 4 | Per-Core Host Exit Stacks & TSS | Allocate `per_cpu_host_stack` and dynamic `tssBaseForCpu(cpu_id)` | M1 | Survey 1 §1.4, §2.2 |
| 5 | VMX Thread Core Affinity | Add `pinned_cpu` to `Thread` and allow AP cores to execute VMX threads in `scheduler.zig` | M1 | Survey 1 §1.2, §2.3 |
| 6 | Per-Instance Virtual Device State | Group emulated PIC, PIT, LAPIC, UART, PCI into `VirtualDeviceState` with spinlock protection | M1 | Survey 1 §1.6, §2.4 |
| 7 | Control Plane Multi-VM Launch | Update `control_handler.zig` to stage, allocate, and distribute instances across SMP cores | M2 | Survey 1 §1.7, §4.1 |
| 8 | Virtual 16550 UART TX/RX Buffers | Per-instance 4KB circular TX buffer, 256B RX FIFO, LSR/IER/IIR emulation, RDA IRQ4 injection | M2 | Survey 2 §1.3, §1.4, §4.1 |
| 9 | Console Syscall ABI Definitions | Define `SYS_GET_VM_CONSOLE_LOG = 28` and `SYS_VM_CONSOLE_INJECT = 29` in `syscall_abi.zig` & `lib.zig` | M2 | Survey 2 §1.2, §4.1 |
| 10 | Console Syscall Whitelist & Trap | Whitelist ops 28 & 29 for `windowd` in `service_bootstrap.zig` and implement handlers in `user_mode.zig` | M2 | Survey 2 §1.2, §4.1 |
| 11 | Dual Serial Output Multiplexing | Retain mirrored output to physical COM1 with `[vm<id>]` tag alongside in-memory ring buffer | M2 | Survey 2 §3.2, §4.1 |
| 12 | windowd Guest Console Pane | Implement `Pane.guest_console = 3`, `DMA_CONSOLE_SLOT = 3`, and `drawGuestConsolePane` | M3 | Survey 2 §1.5, §4.2 |
| 13 | windowd Live Console Switching | Track `active_console_vm_id`, implement `[F6]` jump, `[F7]`/`[F8]` cycle VMs, `[C]`/`[Enter]` in VM manager | M3 | Survey 2 §2, §4.2 |
| 14 | windowd Raw Keyboard Forwarding | Forward typed characters to active MicroVM via `SYS_VM_CONSOLE_INJECT`, support scrollback navigation | M3 | Survey 2 §2, §4.2 |
| 15 | Automated Phase 9 Smoke Profile | Add `SMOKE_PROFILE=phase9` in `test_qemu.sh` with SMP>=2 validation and default build flags | M4 | Survey 3 §4, §6 |
| 16 | QEMU Monitor Key Injection for Phase 9 | Implement `inject_ui_phase9_keys` exercising VM launch, console switching, and guest shell | M4 | Survey 3 §4, §6 |
| 17 | Concurrent MicroVM Milestone Assertions | Assert concurrent multi-core VMCS/EPT milestones, console switching, and clean exit 0 | M4 | Survey 3 §4, §7 |
| 18 | Historical Testing Suite (Tiers 1-4) | Reference models and simulated scenarios; not opaque-box system tests | E2E-Track | Survey 3 §4; [TEST_READY.md](TEST_READY.md) |
| 19 | Live Integration & Adversarial Hardening | Validate the actual implementation and conduct adversarial stress testing | M5 | Project Dual Track Spec |

---

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Ring 0 VMX, EPT & SMP Core Affinity | `src/arch/x86_64/vmx.zig`, `smp.zig`, `gdt.zig`, `src/kernel/scheduler.zig`, `src/vmm/microvm_registry.zig`, `microvm_bridge.zig` | none | DONE (EPT walker, per-core VMXON/stacks, TSS base, affinity, spinlocks) |
| M2 | Console Syscalls & Multi-Instance Control | `src/syscall_abi.zig`, `src/user/lib.zig`, `src/services/service_bootstrap.zig`, `src/arch/x86_64/user_mode.zig`, `src/control/control_handler.zig`, `src/arch/x86_64/vmx.zig` | M1 contracts | Both guests accept and answer console input in live QEMU; targeted production UART tests pass |
| M3 | windowd Live Guest Serial Console & Switching | `src/user/windowd.zig`, `src/user/protocols/windowd_protocol.zig` | M2 contracts | Live QEMU switches between both guests and verifies each shell response |
| M4 | Automated Phase 9 Smoke Profile & Integration | `test_qemu.sh` | M2, M3 | Phase 9, vmx-linux, vmx-linux-services, and ui-phase8 QEMU profiles pass |
| M5 | Live Integration & Adversarial Coverage Hardening | Entire codebase | M1, M2, M3, M4, TEST_READY.md | IN PROGRESS (software/QEMU regressions and targeted hardening tests pass; physical-host acceptance and broader adversarial gates remain) |
| E2E | Historical Model Testing Track | `tests/`, test harness, `TEST_INFRA.md`, `TEST_READY.md` | none (models and simulated traces) | DONE (historical report: 50/50 model cases; not live integration) |

### Current validation evidence (2026-11-05)

- The isolated live `phase9` QEMU profile passed with KVM at SMP=2 and SMP=4. It observed distinct EPT roots, VM 1 and VM 2 launched on cores 0 and 1, both guest shells becoming ready, console switching in both directions, and a `help` response from each guest. This verifies the exercised QEMU path only.
- The complete available QEMU regression matrix passed: `default` at SMP=2/4; `vmx-linux`, `vmx-linux-services`, and `ui-phase8` at SMP=2; and `phase9` at SMP=2/4. The Linux profiles disable per-syscall UART keepalive because its injected dots fragmented literal log markers.
- `zig build test-kernel --summary all` passed 72 production kernel tests with Zig 0.17.0. Standalone Zig EPT, UART/control adversarial-model, and VMCS stress suites passed 8, 10, and 8 tests; Python discovery passed 77 tests and the focused adversarial Python suites passed 33.
- Physical-host acceptance and broader adversarial isolation gates remain pending. QEMU and unit/model tests do not establish hardware acceptance or production readiness.
- The QEMU-validated software baseline is usable to begin Phase 10 development; this does not close Phase 9 M5 or establish hardware acceptance.
- See the [current worktree test record](TEST_READY.md#8-current-worktree-verification) for commands and evidence boundaries.

## Expanded scope and future milestones

**All Phase 10–14 capabilities and acceptance gates below are planned, not implemented or passed.** Preserve and validate the Phase 9 baseline before relying on it. Phase numbers in earlier documents are historical; this table supersedes their proposed future numbering without retroactively changing their completed work. Work can proceed in parallel where dependencies allow, but an acceptance gate cannot be skipped.

| Phase | Goal and dependencies | Required deliverables | Acceptance and failure gates |
| --- | --- | --- | --- |
| **10 — Local reliability and virtual networking** | Builds on the usable Phase 9 baseline. | Explicit VM/vCPU isolation and teardown contracts; local capability/identity hardening; real local disk write, flush/FUA and recovery semantics; standalone Ring-3 vSwitch, host-assigned vNICs, IPv4/IPv6 segments and default-deny policies. Establish locally bootstrapped credentials and durable local metadata journals for later cluster work. | On an offline node, demonstrate allowed and denied dual-stack flows, anti-spoofing and lifecycle isolation; prove actual flush/barrier and recovery under power interruption. Reject synthetic storage, missing isolation, unsafe DMA and unknown policy. |
| **11 — Direct full-VM platform** | Design may proceed alongside Phase 10; persistent guest acceptance requires Phase 10 isolation and local I/O. | Direct Type-1 generic UEFI boot, virtual PC/PCI/interrupts/timers, installation media, persistent disks and EFI variables, virtual NIC and graphical/serial consoles. Add approved Secure Boot, vTPM 2.0 and guest drivers for the selected Windows profile. | Install, reboot, access the console and network, and verify guest-flushed data using pinned Ubuntu Server 26.04 LTS and Windows 11 Pro 26H2 media. Record CPU, firmware, drivers, Secure Boot and TPM results; reject unmet prerequisites rather than bypassing them. A basic framebuffer is not a WDDM/DirectX or vendor-support claim. |
| **12 — Authenticated cluster fabric and common native UI** | Depends on Phase 10 local identity, journals and networking; can be developed alongside Phase 11. | Unique node enrollment/keys; authenticated, encrypted, replay-protected node transport; safe 3-node membership, majority metadata/consensus and fencing; cross-node guest segments with versioned per-port policy; one versioned management API powering the native UI on any healthy node. Storage-specific views depend on Phase 13. | Exercise 2+1 and 1+1+1 partitions, rejoin, spoof/replay, policy revocation and node loss. No minority writes or unsafe failover; no claim of globally enforced policy until all affected attachments apply or are verifiably fenced. Test operator authentication, roles, audit, idempotency, and stale/unreachable display. |
| **13 — Span-Weave distributed virtual storage** | Depends on Phase 10 real local persistence and Phase 12 authenticated transport, quorum and fencing. | Three data nodes, rotating primary/replica/sentinel roles, immutable extent generations, two full durable copies and quorum-committed mappings, checksums, fencing, tension-directed repair, safe membership, backup and restore, and integrated storage health. | Before every successful write acknowledgement require two independently durable copies on different nodes and a committed 2-of-3 metadata majority. Test power cuts at every data/metadata boundary, lost replies, stale writers, corruption, reconfiguration, repair and recovery. Reject writes without quorum or two eligible destinations. |
| **14 — Optional support MicroVM and nested KVM** | Research may begin earlier; release requires validated direct-VM isolation and the necessary Phase 10/11 device and firmware contracts. | Least-privilege Linux L1 support MicroVM, independently authored or explicitly approved guest VMM, and Catenary-provided nested VMX/EPT state, invalidation, interrupts and accounting. | On eligible hardware prove KVM actually runs an L2; test hostile L1/L2 input, containment, quotas, unavailable hardware and support-VM failure. Never silently treat software emulation as accelerated KVM; direct guests, bootstrap, recovery and quorum must remain independent. |

### Cross-cutting decisions and design references

- **Independent platform:** Author new Catenary hypervisor, network, storage and orchestration implementations independently from published specifications and established algorithms. Existing tools, approved guest operating systems, explicitly approved licensed firmware/drivers, and optional Linux/KVM in a support VM are exceptions. Use reviewed cryptography, not invented primitives. The binding policy is in the [constitution](CONSTITUTION.md) and [shared project rules](.agents/workflows/project-rules.md).
- **Virtualization:** The [VM plan](docs/VIRTUALIZATION_PLAN.md) defines direct MicroVM/full-VM profiles, guest compatibility, UEFI, device/DMA boundaries, security state, backup, and the optional L0/L1/L2 path. A shared untrusted L1 is one host-visible principal unless a separately proven per-L2 identity binding exists.
- **Networking:** The [virtual network plan](docs/VIRTUAL_NETWORK_PLAN.md) separates guest Ethernet from DIPC control, specifies standalone and authenticated multi-node switches, default-deny microsegmentation, IPv4/IPv6, anti-spoofing, and failure-safe policy distribution.
- **Storage:** The [storage plan](docs/STORAGE_PLAN.md) specifies Span-Weave's quorum and acknowledgement order, immutable extents, integrity, fencing and tension-directed repair. A failed node may leave earlier writes with only one available copy until repair; replicas are not backups. The proposal is not a claim of global novelty or validated fault tolerance.
- **Cluster UI and recovery:** The [cluster plan](docs/CLUSTER_ORCHESTRATION.md) defines the common native API/UI, operator authorization and audit, bootstrap, fencing, quorum loss and later browser access. Bootstrap and rescue do not depend on distributed volumes or the support VM.
- **Evidence:** [TEST_INFRA.md](TEST_INFRA.md) maps future guest, policy, quorum, power-loss, storage repair, operator and nesting requirements to model, live-QEMU, and physical-host acceptance. Each phase must record actual results and blocked prerequisites; historical 50/50 models and log markers cannot substitute for end-to-end evidence.

---

## Interface Contracts

### 1. Kernel Virtualization ↔ Scheduler & AP Cores (`M1`)
- **Per-core VMX**:
  - `vmx.initApCore(ap_idx: usize) void`: called from `smp.apEntry(ap_idx)` after GDT/IDT reload.
  - `gdt.tssBaseForCpu(cpu_id: usize) u64`: returns address of `per_cpu_tss[cpu_id]`.
- **Core Affinity**:
  - `Thread.pinned_cpu: ?u8 = null`.
  - `scheduler.spawnWithVmx(..., pinned_cpu: ?u8) !u32`.
  - `scheduler.schedule()` executes thread only if `t.pinned_cpu == null or t.pinned_cpu.? == cpu_id`.
- **EPT Translation**:
  - `translateEptGpaToHpa(root_phys: u64, gpa: u64) ?u64`: walks 4-level PML4 tree of the given instance.

### 2. MicroVM Virtual UART ↔ Syscall ABI (`M1` ↔ `M2`)
- **Instance UART Structure** (`src/vmm/microvm_registry.zig`):
  ```zig
  pub const VmUartState = struct {
      dll: u8 = 0x01,
      dlm: u8 = 0x00,
      ier: u8 = 0,
      fcr: u8 = 0,
      lcr: u8 = 0x03,
      mcr: u8 = 0,
      scr: u8 = 0,
      irq4_pending: bool = false,
      rx_buf: [256]u8 = undefined,
      rx_head: u8 = 0,
      rx_tail: u8 = 0,
      rx_count: u8 = 0,
      tx_buf: [4096]u8 = undefined,
      tx_len: usize = 0,
  };
  ```
- **Console Syscall ABI** (`src/syscall_abi.zig`):
  - `SYS_GET_VM_CONSOLE_LOG: u64 = 28;` (arg0 = dest_dma_phys, arg1 = vmid) -> returns bytes copied (u64).
  - `SYS_VM_CONSOLE_INJECT: u64 = 29;` (arg0 = vmid, arg1 = ascii_char) -> returns status (0 = success).
- **Service Bootstrap** (`src/services/service_bootstrap.zig`):
  - `allowedSyscallMask(.windowd)` includes `bit(SYS_GET_VM_CONSOLE_LOG) | bit(SYS_VM_CONSOLE_INJECT)`.

### 3. Syscall ABI ↔ windowd TUI (`M2` ↔ `M3`)
- **DMA Slot**:
  - `windowd` uses DMA slot 3: `DMA_CONSOLE_SLOT: u64 = 3` (within 4 allocated pages).
- **Pane Identification**:
  - `Pane.guest_console = 3`.
- **Switching Hotkeys**:
  - `[F6]`: Switch focus to Guest Serial Console pane.
  - `[F7]`: Switch console to previous running MicroVM.
  - `[F8]`: Switch console to next running MicroVM.
  - `[C]` or `[Enter]` in VM Manager (F3): Jump directly to selected VM's console.
- **Input Forwarding**:
  - Raw character input while `focused_pane == .guest_console` is dispatched via `lib.syscall(SYS_VM_CONSOLE_INJECT, active_console_vm_id, ch, token)`.

### 4. System Output ↔ Automated Test Harness (`M1..M3` ↔ `M4`)
- **Log Markers**:
  - `[SMP core 0] entering guest via vmlaunch`
  - `[SMP core 1] entering guest via vmlaunch`
  - `VMX: initialized EPT root for VM 1`
  - `VMX: initialized EPT root for VM 2`
  - `[UI] Switched console to MicroVM #<id>`
  - `Catenary OS Guest Init: SUCCESS`
  - `guest_rootfs: init started`

---

## Code Layout

```
src/
├── arch/x86_64/
│   ├── vmx.zig              # Ring-0 VMX, EPT radix walker, per-core stacks, virtual UART
│   ├── smp.zig              # AP core bringup, vmx.initApCore invocation
│   ├── gdt.zig              # Per-core TSS base discovery
│   └── user_mode.zig        # Syscall dispatch for ops 28 & 29
├── kernel/
│   └── scheduler.zig        # Thread pinned_cpu affinity & AP core VMX scheduling
├── vmm/
│   ├── microvm_registry.zig # Multi-VM instance registry, spinlock synchronization, UART state
│   ├── microvm_bridge.zig   # DIPC bridge & EPT address translation
│   └── linux_boot.zig       # Linux bzImage & E820 setup
├── control/
│   └── control_handler.zig  # Multi-instance dynamic launch & core distribution
├── syscall_abi.zig          # Syscall definitions (28 & 29)
├── services/
│   └── service_bootstrap.zig# Syscall whitelist bitmasks
└── user/
    ├── lib.zig              # Userspace syscall wrappers
    └── windowd.zig          # Ring-3 TUI compositor, console pane & live switching
test_qemu.sh                 # Automated smoke test harness (SMOKE_PROFILE=phase9)
tests/                       # E2E test suite (Tiers 1-4)
```
