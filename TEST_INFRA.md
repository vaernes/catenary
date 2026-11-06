# Catenary OS Phase 9 — Historical Reference-Model Test Infrastructure

## 1. Overview & Dual Track Test Philosophy
This document preserves the historical test descriptions for **Phase 9: Multi-VCPU, SMP MicroVMs & Live Serial Console**. The suite was called E2E, but its Tier 1–4 Python cases exercise reference models and simulated inputs, not an opaque-box or end-to-end execution of Catenary OS. The dated 50/50 result in [TEST_READY.md](TEST_READY.md) is a historical report about those modeled contracts only; it is not evidence of real boots, guest behavior, hardware isolation, production readiness, or complete requirements coverage.

[tests/test_harness.py](tests/test_harness.py) supplies independent Python EPT, scheduler, UART, UI, and milestone-matcher models; its EPT model uses a mapping dictionary, not the kernel's page-table walker. In [the Tier 4 scenarios](tests/tier4_scenarios/test_real_world_scenarios.py), the boot trace and guest responses are literal simulated strings. The cases do not launch QEMU or exercise actual guests. Their assertions can also be weaker than the historical objectives below.

**Smoke-profile evidence (inspected 2026-11-05):** the tracked baseline of [test_qemu.sh](test_qemu.sh) lists `default`, `vmx-linux`, `vmx-linux-services`, and `ui-phase8`; it has no `phase9` case. The current working tree already contains an uncommitted `phase9` case and monitor-key helper, while [PROJECT.md](PROJECT.md) still marks M4 as planned. Source presence is not a successful live run. In that working-tree case, guest init/rootfs markers are not individually attributed to both VMs, and finding strings does not establish ordering or concurrent execution. No new run is reported here.

In accordance with the Dual Track development lifecycle:
- **Requirement context**: The historical descriptions cite `ORIGINAL_REQUEST.md` and [PROJECT.md](PROJECT.md); their R1–R4 labels are retained as intended contracts, not proof of implementation or completeness. The Python cases inspect their own models and constants, so they are not opaque-box tests of the system.
- **Progressive model checks**: Local fixtures express selected arithmetic, state-machine, and log-pattern expectations. They do not independently verify the implementation that inspired them.
- **Expected-output sources**: Intel SDM Vol 3C, the 16550 UART specification, and the project interface descriptions inform the intended expectations; the simplified models are not themselves authoritative hardware or ABI conformance evidence.
- **Adversarial targets**: The historical descriptions include memory boundaries, buffer wrapping, FIFO overflow, character escaping, invalid VMIDs, and affinity violations. Some are modeled; other entries below are objectives, not demonstrated system behavior.

---

## 2. Feature Inventory & Mapping

The historical Phase 9 plan names four primary functional pillars. The interfaces and milestones in this table are **expected contracts**, not verified implementation results:

| Feature ID | Pillar / Requirement | Scope & Interface Contracts | Target Milestones |
|------------|----------------------|-----------------------------|-------------------|
| **F1** | **R1. Independent EPT Roots & VMCS per Instance** | PML4 radix-tree translation `translateEptGpaToHpa(root, gpa)`, dedicated VMCS physical pages, independent GPA->HPA mappings, zero-page/cmdline isolation | M1 (`src/arch/x86_64/vmx.zig`, `microvm_registry.zig`) |
| **F2** | **R2. Concurrent Multi-MicroVM Execution Across SMP Cores** | Per-core VMX initialization (`per_cpu_vmxon`), per-core host exit stack, per-core `VMCS_HOST_TR_BASE` via `gdt.tssBaseForCpu(cpu)`, `Thread.pinned_cpu` core affinity, scheduler AP dispatch | M1 (`smp.zig`, `gdt.zig`, `scheduler.zig`, `microvm_bridge.zig`) |
| **F3** | **R3. Live Guest Serial Console Switching in windowd** | Syscalls `SYS_GET_VM_CONSOLE_LOG = 28` and `SYS_VM_CONSOLE_INJECT = 29`, virtual 16550 UART (4KB circular TX, 256B RX FIFO, LSR/IIR/IER IRQ4), `Pane.guest_console = 3`, `DMA_CONSOLE_SLOT = 3`, hotkeys `[F6]`, `[F7]`, `[F8]`, `[C]`/`[Enter]` | M2 & M3 (`syscall_abi.zig`, `lib.zig`, `service_bootstrap.zig`, `windowd.zig`) |
| **F4** | **R4. Automated Phase 9 Smoke Test Profile** | Intended `SMOKE_PROFILE=phase9`, SMP>=2 enforcement, `inject_ui_phase9_keys` via QEMU monitor socket, milestone pattern validation, clean exit 0; the working-tree code has not been validated by these model cases | M4, planned in [PROJECT.md](PROJECT.md) |

---

## 3. 4-Tier Test Design Methodology

The historical runner inventory comprises 50 Python cases in four tiers. The legacy runner and file names retain `e2e` terminology, but the listed cases are model/reference checks, including simulated scenarios:

```
tests/
├── __init__.py
├── test_harness.py                     # Shared models, reference oracles, and test fixtures
├── run_e2e_tests.py                    # Legacy-named CLI runner with tier filtering & colored report
├── run_e2e_tests.sh                    # Shell wrapper script
├── tier1_feature_coverage/             # Tier 1: Modeled feature behavior (20 cases: 5 per feature)
│   ├── __init__.py
│   ├── test_r1_ept_vmcs.py             # T1.F1: 5 tests
│   ├── test_r2_smp_concurrency.py      # T1.F2: 5 tests
│   ├── test_r3_console_windowd.py      # T1.F3: 5 tests
│   └── test_r4_smoke_profile.py        # T1.F4: 5 tests
├── tier2_boundaries/                   # Tier 2: Modeled boundaries and edge conditions (20 cases)
│   ├── __init__.py
│   ├── test_r1_ept_boundaries.py       # T2.F1: 5 tests
│   ├── test_r2_smp_boundaries.py       # T2.F2: 5 tests
│   ├── test_r3_console_boundaries.py   # T2.F3: 5 tests
│   └── test_r4_smoke_boundaries.py     # T2.F4: 5 tests
├── tier3_combinations/                 # Tier 3: Modeled pairwise interactions (6 cases)
│   ├── __init__.py
│   └── test_pairwise_combinations.py   # T3: R1+R2, R1+R3, R1+R4, R2+R3, R2+R4, R3+R4
└── tier4_scenarios/                    # Tier 4: Simulated operational scenarios (4 cases)
    ├── __init__.py
   └── test_real_world_scenarios.py    # T4: simulated boot, operator session, buffer wrap, recovery
```

---

## 4. Historical Model-Check Matrix

All descriptions below state an expected contract or a check against simulated values; they do not establish that the real system implements it. The original IDs and case labels are retained. The labels are historical shorthand, not necessarily the literal Python method names.

### Tier 1: Modeled Feature Coverage (>=5 per feature = 20 cases)

| Test ID | Feature | Historical Case Name | Expected Contract / Model Check |
|---------|---------|----------------|--------------------------------|
| `T1_F1_01` | F1 | `test_ept_pml4_radix_structure` | Expected 4-level 48-bit GPA translation through PML4 -> PDPT -> PD -> PT and offset arithmetic; the model checks index arithmetic and a dictionary mapping, not a real radix-tree walk. |
| `T1_F1_02` | F1 | `test_ept_independent_address_spaces` | Model distinct roots mapping identical GPA `0x100000` to different HPA frames; actual MicroVM isolation remains to be verified. |
| `T1_F1_03` | F1 | `test_vmcs_dedicated_physical_pages` | Compare simulated distinct, 4KB-aligned VMCS page addresses; no physical allocation is exercised. |
| `T1_F1_04` | F1 | `test_ept_identity_mapping_isolation` | Model separate zero-page (`0x7000`) and cmdline (`0x20000`) mappings for two instances. |
| `T1_F1_05` | F1 | `test_vmcs_revision_id_header` | Check a simulated 31-bit VMCS revision header and shadow bit; no `IA32_VMX_BASIC` MSR is read. |
| `T1_F2_01` | F2 | `test_per_core_vmxon_state` | Model per-core VMXON flags and distinct addresses; actual CR4.VMXE, VMXON, and AP bring-up are not exercised. |
| `T1_F2_02` | F2 | `test_per_core_host_exit_stack` | Model distinct, aligned host stacks; preventing cross-core RSP corruption is an expected hardware contract. |
| `T1_F2_03` | F2 | `test_per_core_tss_base_in_vmcs` | Compare modeled per-core TSS addresses; loading `VMCS_HOST_TR_BASE` from `gdt.tssBaseForCpu(cpu_id)` is not exercised. |
| `T1_F2_04` | F2 | `test_thread_core_affinity_binding` | Check modeled `Thread.pinned_cpu` eligibility on each core, not actual scheduler dispatch. |
| `T1_F2_05` | F2 | `test_concurrent_vm_exit_handling` | Sequentially select two pinned model threads; real concurrent execution and VM-exit handling are expected but not tested here. |
| `T1_F3_01` | F3 | `test_guest_console_pane_definition` | Compare modeled `Pane.guest_console = 3` and `DMA_CONSOLE_SLOT = 3`, not the live `windowd` definition. |
| `T1_F3_02` | F3 | `test_syscall_abi_console_definitions` | Compare locally declared values `SYS_GET_VM_CONSOLE_LOG = 28` and `SYS_VM_CONSOLE_INJECT = 29`; the test does not read the ABI. |
| `T1_F3_03` | F3 | `test_windowd_syscall_whitelist` | Check bits 28 and 29 in a locally constructed mask; the service bootstrap allow-list is not inspected. |
| `T1_F3_04` | F3 | `test_virtual_uart_dual_path_tx` | Model port `0x3F8` output in a 4KB ring and a `[vm<id>]` mirror string; no physical COM1 is exercised. |
| `T1_F3_05` | F3 | `test_windowd_console_switching_hotkeys` | Model `[F6]`, `[F7]`, and `[F8]` switching; `[C]`/`[Enter]` and the live viewport are historical expected contracts, not checked by this case. |
| `T1_F4_01` | F4 | `test_smoke_profile_phase9_argument_handling` | Check `-Dvmm_active=true -Dvmm_launch_linux=true` in a simulated argument string, not the script's profile handling. |
| `T1_F4_02` | F4 | `test_smp_requirement_validation` | Check a local `SMP >= 2` predicate; no QEMU invocation is made. |
| `T1_F4_03` | F4 | `test_qemu_monitor_phase9_key_injection` | Construct mock `sendkey` strings for form submission and console switching; no monitor socket is contacted. |
| `T1_F4_04` | F4 | `test_milestone_pattern_assertion` | Match EPT, AP vmlaunch, guest-init, and console-switch markers against a literal simulated log. |
| `T1_F4_05` | F4 | `test_clean_termination_and_exit_code` | Map a simulated milestone boolean to exit code 0; actual QEMU termination and cleanup are not checked. |

### Tier 2: Modeled Boundary & Corner Cases (>=5 per feature = 20 cases)

| Test ID | Feature | Historical Case Name | Expected Contract / Model Check |
|---------|---------|----------------|--------------------------------|
| `T2_F1_01` | F1 | `test_ept_gpa_zero_page_boundary` | Model translation of GPA `0x0000_0000` without treating it as NULL. |
| `T2_F1_02` | F1 | `test_ept_high_memory_boundary` | Model GPA `0x1FFF_FFFF`, the example 512 MiB boundary; this does not establish a real guest memory limit. |
| `T2_F1_03` | F1 | `test_ept_unmapped_gpa_fault` | Model an unmapped 1 GiB GPA returning `None`; an actual EPT-violation exit is not triggered. |
| `T2_F1_04` | F1 | `test_vmcs_page_alignment_enforcement` | Check a local 4096-byte alignment predicate; no VMCS allocation or hardware enforcement is exercised. |
| `T2_F1_05` | F1 | `test_ept_multi_instance_page_table_isolation` | Remap one model root and check that another model root is unchanged. |
| `T2_F2_01` | F2 | `test_smp_core_affinity_mismatch_rejection` | Model rejection of a thread pinned to a different core. |
| `T2_F2_02` | F2 | `test_unpinned_thread_fallback` | Model eligibility of unpinned non-VMX threads on either core. |
| `T2_F2_03` | F2 | `test_microvm_registry_concurrent_spinlock` | Serialize 50 simulated registrations with a Python lock; the actual registry spinlock and its race-freedom are not exercised. |
| `T2_F2_04` | F2 | `test_max_smp_cores_boundary` | Initialize an eight-core model and check an out-of-range lookup, not the live per-CPU arrays. |
| `T2_F2_05` | F2 | `test_vmexit_reentry_preserves_core_context` | A toy handler increments a simulated register; preserving real guest and host context across VM-exits remains an expected contract. |
| `T2_F3_01` | F3 | `test_circular_tx_buffer_overflow_wrap` | Write 5000 bytes to the model's 4096-byte UART ring and compare the retained tail. |
| `T2_F3_02` | F3 | `test_rx_fifo_capacity_boundary` | Model a 256-byte RX FIFO, Data Ready/interrupt status, and rejection of byte 257. |
| `T2_F3_03` | F3 | `test_invalid_vmid_console_syscall` | A local mock treats VMIDs 0 and 99 as invalid; it does not call the syscall. The documented [ABI](src/syscall_abi.zig) instead says VMID 0 defaults to 1, so that expectation requires reconciliation. |
| `T2_F3_04` | F3 | `test_console_scrollback_boundary` | Exercise top and bottom scrollback clamps in the UI model. |
| `T2_F3_05` | F3 | `test_special_ascii_control_injection` | Insert Ctrl-C `0x03`, Ctrl-D `0x04`, CR `0x0D`, ESC `0x1B`, and NUL `0x00` directly into the modeled FIFO; the syscall pipeline is not exercised. |
| `T2_F4_01` | F4 | `test_single_core_smp1_rejection_or_upgrade` | A local model promotes `SMP=1` to 2; no real profile is invoked. |
| `T2_F4_02` | F4 | `test_missing_kvm_fallback_tcg` | Model `REQUIRE_KVM=0` selecting `-accel tcg -cpu max,vmx=on`; the historical timeout-adjustment expectation is not exercised and no QEMU is started. |
| `T2_F4_03` | F4 | `test_partial_milestone_timeout_failure` | Match a partial literal log and identify the missing guest-2 marker; actual timeout and exit code 1 are not exercised. |
| `T2_F4_04` | F4 | `test_stale_monitor_socket_cleanup` | Remove dummy files in a temporary directory; real monitor socket and PID cleanup are not exercised. |
| `T2_F4_05` | F4 | `test_post_flush_pass_detection` | Compare simulated pre- and post-flush strings; no QEMU termination or serial flush occurs. |

### Tier 3: Modeled Cross-Feature Combinations (6 cases)

| Test ID | Interaction | Historical Case Name | Expected Contract / Model Check |
|---------|-------------|----------------|--------------------------------|
| `T3_PAIR_01` | R1 + R2 | `test_pair_r1_ept_and_r2_smp` | Combine model roots and sequential core selections; actual concurrent EPT isolation is an expected contract. |
| `T3_PAIR_02` | R1 + R3 | `test_pair_r1_ept_and_r3_console` | Compare separate UART model buffers; this does not establish that real EPT isolation guarantees independent logs. |
| `T3_PAIR_03` | R2 + R3 | `test_pair_r2_smp_and_r3_console` | Model UI switching and separate UART RX input; no live guests or concurrent VM-exits occur. |
| `T3_PAIR_04` | R1 + R4 | `test_pair_r1_ept_and_r4_smoke` | Match two EPT initialization markers in a literal log, not the real smoke profile. |
| `T3_PAIR_05` | R2 + R4 | `test_pair_r2_smp_and_r4_smoke` | Match core-0 and core-1 vmlaunch markers in a literal log; concurrent launch is not demonstrated. |
| `T3_PAIR_06` | R3 + R4 | `test_pair_r3_console_and_r4_smoke` | Match a simulated UI switch marker; no monitor keys are injected. |

### Tier 4: Simulated Operational Scenarios (4 cases)

| Test ID | Historical Scenario Name | Intended Scenario / Actual Simulation |
|---------|---------------|------------------------------------------|
| `T4_SCEN_01` | `test_scenario_dual_guest_concurrent_boot` | Intended: two cores, distinct EPT roots, concurrent MicroVM launch, and `Catenary OS Guest Init: SUCCESS` / `guest_rootfs: init started` for both. Actual simulation selects model threads and matches a literal boot trace; no OS or guest boots. |
| `T4_SCEN_02` | `test_scenario_interactive_operator_session` | Intended: switch with `[F6]`/`[F8]`, send `ps`, `uname`, and `cat /etc/os-release`, and obtain isolated responses. Actual simulation injects `uname -r` and `ps` into UART models and writes predetermined responses; `cat` is not exercised. |
| `T4_SCEN_03` | `test_scenario_heavy_serial_burst_and_wraparound` | Intended: >10 KB bursts from two concurrent guests, 4KB wrap, unmangled COM1 tags, and no core/spinlock deadlock. Actual simulation sequentially writes byte bursts to two UART models and compares their 4096-byte tails; it does not check COM1 or deadlocks. |
| `T4_SCEN_04` | `test_scenario_lifecycle_stop_start_and_recovery` | Intended: stop VM 1 while VM 2 continues on AP Core 1, switch console, and restart/rebind VM 1. Actual simulation manually changes model thread and console state, then selects model threads; no real lifecycle or recovery is exercised. |

---

## 5. Historical Expected-Output Derivation

The following are reference assumptions and intended interface values, not proof that each case checks the full specification or that the implementation conforms. In particular, the dictionary-backed EPT model is not a hardware page-table walk and does not establish hardware permission enforcement.

1. **Intel 64 SDM Vol 3C Chapter 28 (EPT)**:
   - 4-level translation equations:
     $$\text{PML4E Index} = (\text{GPA} \gg 39) \ \& \ 0\text{x}1\text{FF}$$
     $$\text{PDPTE Index} = (\text{GPA} \gg 30) \ \& \ 0\text{x}1\text{FF}$$
     $$\text{PDE Index} = (\text{GPA} \gg 21) \ \& \ 0\text{x}1\text{FF}$$
     $$\text{PTE Index} = (\text{GPA} \gg 12) \ \& \ 0\text{x}1\text{FF}$$
     $$\text{HPA} = (\text{PTE Base}) \mid (\text{GPA} \ \& \ 0\text{xFFF})$$
   - 2 MiB Large Page translation (when PDE Bit 7 PS=1):
     $$\text{HPA} = (\text{PDE Base} \ \& \ \sim 0\text{x}1\text{FFFFF}) \mid (\text{GPA} \ \& \ 0\text{x}1\text{FFFFF})$$
2. **National Semiconductor 16550A UART Specification**:
   - LSR Bit 0: Data Ready (DR) = 1 when RX FIFO count > 0; 0 when count == 0.
   - LSR Bit 5: Transmitter Holding Register Empty (THRE) = 1.
   - LSR Bit 6: Transmitter Empty (TEMT) = 1.
   - IER Bit 0: Received Data Available Interrupt Enable (ERBFI).
   - IIR: 0x04 when RDA interrupt is pending, 0x02 for THRE, 0x01 for no interrupt.
3. **Intended Catenary OS Interface Contracts ([PROJECT.md](PROJECT.md))**:
   - `SYS_GET_VM_CONSOLE_LOG = 28`, `SYS_VM_CONSOLE_INJECT = 29`.
   - `Pane.guest_console = 3`, `DMA_CONSOLE_SLOT = 3`.
   - Key bindings: `F6` (focus console), `F7` (previous VM), `F8` (next VM), `C`/`Enter` (VM manager console jump).
   - Dual-path TX prefix: `[vm<id>] `.
   - Milestone strings in `test_qemu.sh`.

---

## 6. Historical Adversarial Targets

These are expected resilient behaviors, not verified system results or a claim that every input below is exercised by the 50 historical cases. For example, the registry case uses 50 Python-locked registrations, not 100 operations against the kernel spinlock.

| Adversarial Vector | Input / Condition | Target Resilient Behavior |
|--------------------|-------------------|-----------------------------|
| **NUL Byte Injection** | Inject byte `0x00` via console injection | Stored in RX FIFO, delivered to guest UART without truncating buffer or causing string null-termination bugs. |
| **Syscall Keepalive Dot Flood** | Serial keepalive emits thousands of `.` | Pattern matcher ignores interleaved dots and reliably detects milestones. |
| **Buffer Overflow Flooding** | Send 65,536 bytes into 4096-byte TX buffer | Head and tail wrap around modulo 4096 without heap corruption, page fault, or negative indexing. |
| **Invalid Core Affinity** | Assign `pinned_cpu = 255` on a 2-core system | Thread is never scheduled on online cores (0 or 1), preventing out-of-bounds core execution. |
| **Concurrent Spinlock Contention** | 100 concurrent threads modifying registry | Spinlock serializes access, maintaining consistent state without race-induced memory corruption. |

---

## 7. Test Execution Guide

These legacy commands are preserved for the reference-model runner. They were not run for this documentation update, and a model-runner result must not be reported as live QEMU or hardware validation.

### Prerequisites
- Python 3.10+ (standard library only; no external pip dependencies needed).
- Linux environment.

### Running All Tests
```bash
# Via Python CLI runner
python3 tests/run_e2e_tests.py

# Via shell script wrapper
./tests/run_e2e_tests.sh
```

### Running Specific Tiers
```bash
# Tier 1: Feature Coverage only
python3 tests/run_e2e_tests.py --tier 1

# Tier 2: Boundary & Corner Cases only
python3 tests/run_e2e_tests.py --tier 2

# Tier 3: Cross-Feature Combinations only
python3 tests/run_e2e_tests.py --tier 3

# Tier 4: Simulated Operational Scenarios only
python3 tests/run_e2e_tests.py --tier 4
```

### Running Via Standard Unittest Discovery
This broader discovery command may find other Python tests as well as the four model tiers, with different prerequisites and scope; it is not equivalent to the historical 50-case runner.

```bash
python3 -m unittest discover -s tests -p "test_*.py"
```

---

## 8. FUTURE Acceptance Matrix — Planning Only

Every row below is a **future acceptance target**, not a claim that an implementation or test exists, has been run, or passes. The matrix makes no production-readiness or requirements-completeness sign-off. The related documents are plans or architecture context, not verification evidence: [project plan](PROJECT.md), [virtualization plan](docs/VIRTUALIZATION_PLAN.md), [virtual network plan](docs/VIRTUAL_NETWORK_PLAN.md), [storage plan](docs/STORAGE_PLAN.md), [cluster orchestration plan](docs/CLUSTER_ORCHESTRATION.md), [DIPC ownership/security](docs/DIPC_OWNERSHIP.md), and [architectural constitution](CONSTITUTION.md).

### Evidence classes and prerequisites

- **M — model/reference:** synthetic state, mock data, and simulated faults can check a proposed invariant, but cannot satisfy a live-system or hardware acceptance row.
- **Q — live QEMU integration:** operate actual Catenary and guests under QEMU, with recorded guest/host observations and independent packet or I/O evidence. For VM acceptance, require verified hardware KVM acceleration and nested virtualization; TCG fallback is diagnostic only. Availability of `/dev/kvm` or a serial milestone alone does not establish acceleration or guest behavior.
- **H — physical hardware:** repeat applicable criteria on physical hosts, NICs and storage; actual power interruption and independently durable failure domains are required for durability claims. Killing QEMU or using a disk image is useful fault injection but is not a physical power-cut test. All matrix rows require both Q and H unless explicitly stated; M is supplementary only.
- **Guest media and licensing:** use a verified Ubuntu Server 26.04 LTS image and an approved, user-supplied Windows 11 Pro 26H2 installation image and license with rights for the intended VM. Record edition/build and image digest without recording product keys. If approved media, licensing, or the target release is unavailable, the Windows criteria are blocked, not implicitly passed or bypassed.
- **Reliable storage:** provide three independently powered physical voting nodes with real, independently faulted durable devices, plus a fourth learner or replacement host for the reconfiguration trial. At acknowledgment, the two extent copies must reside on distinct nodes and independently durable storage/failure domains, not two paths to one cache, disk, controller, or power supply. QEMU may inject virtual node/storage failures, but cannot establish physical failure-domain independence. Establish the device/cache flush and barrier semantics and independently retain the write/acknowledgment ledger. The current [storage service](src/user/storaged.zig) fails without NVMe, issues NVMe Flush when a volatile cache is reported, and implements virtio FUA with a write-then-flush fallback. QEMU smoke results do not prove physical power-loss durability, native NVMe FUA, or replicated durability.
- **Evidence record:** retain the exact build/dirty-tree identity, machine/firmware and storage configuration, guest image and version, QEMU version and accelerator, fault timeline, request IDs, policy versions, logs, packet captures, and before/after hashes. Record unavailable prerequisites and missing evidence as blocked, not as success.

| Future ID | Area | Required evidence | Proposed observable acceptance criteria |
|-----------|------|-------------------|-----------------------------------------|
| `FUT-GUEST-U` | Ubuntu Server 26.04 LTS | Q + H | Install from verified media to persistent guest storage; record the exact release, finish installation, detach install media, cold reboot, and log in. Write and flush identifiable files, then compare hashes after clean restart and a guest/host power-interruption trial; exercise configured serial input/output and the graphical installer/console independently. |
| `FUT-GUEST-W` | Windows 11 Pro 26H2 | Q + H; approved user media and license | Install the exact approved edition/build using supported firmware, Secure Boot and vTPM 2.0; detach installation media, reboot, log in through the graphical console, and confirm license/activation only as permitted by the supplied license. Write and flush identifiable data, then compare hashes after clean restart and a guest/host power-interruption trial; exercise a supported, configured serial/diagnostic path as well as graphical input/output. Never bundle media, expose keys, or bypass licensing. |
| `FUT-FIRMWARE-TPM` | Guest firmware and vTPM | Q + H | For both full-VM guests, record UEFI/Secure Boot state and boot-variable persistence across restart and cold power cycle. For Windows and other TPM-enabled profiles, also verify vTPM 2.0 identity/state, distinct VM keys, no cross-VM access, and fail-closed handling of damaged/missing TPM state; restore protected firmware/TPM state with the backup in `FUT-BACKUP`. Test invalid boot images when Secure Boot is enabled; Ubuntu's base profile does not require a vTPM. |
| `FUT-NET-SWITCH` | vSwitch/vNIC isolation | Q + H | With two tenants on the same node and on different nodes, capture both ends: default-deny blocks unpermitted ingress and egress, while explicitly permitted IPv4 and IPv6 traffic is delivered locally and cross-node. Attempt spoofed source MAC/IP, ARP, IPv6 neighbor discovery and rogue router advertisements; none may impersonate another authorized vNIC or tenant. Keep guest IPv4 support at the appropriate user-space boundary. |
| `FUT-NET-EDGE` | Fragments, extension headers and MTU | Q + H | On both same-node and cross-node paths, send permitted and denied IPv4 fragments and IPv6 fragments/extension-header chains, including out-of-order and overlapping/malformed cases. Well-formed permitted traffic must work, while ambiguous or invalid traffic must not bypass policy. Probe effective overlay MTU and path-MTU handling in both directions, including appropriate ICMP errors rather than silent black holes. |
| `FUT-NET-REVOKE` | Policy updates during partition | Q + H | Establish permitted flows, partition a node, commit an update/revocation on the authorized majority, and probe existing and new flows on both sides. A node unable to establish policy freshness must fail closed according to a predeclared bounded lease/cutover; stale policy must not regain authority on reconnect. Record epoch, timing, packet captures, convergence and explicitly reauthorized traffic. |
| `FUT-OVERLAY` | Authenticated, replay-safe overlay | Q + H | Exercise node identity and key authorization; reject forged identities, altered frames, duplicates, replay after restart or key rotation/revocation, and cross-session/tenant replay. Accept legitimate reordering only within the defined replay window and at most once; capture the decisions without exposing secrets. |
| `FUT-STORAGE-ACK` | Three-node quorum and durable copies | Q + H; independent durable media for H | For three metadata voters, instrument each successful write acknowledgment: metadata must be durably committed by a majority (at least 2 of 3) and two independent extent copies must already be durably flushed on separate failure domains. No acknowledgment may rely on a synthetic success, volatile cache, or one physical copy. |
| `FUT-POWER-CUT` | Prepare/flush/commit/response crashes | Q + H; real power cuts for H | Cut power or inject a crash before and after each boundary: prepare, each copy's flush, majority commit, and client response. Compare recovery with an independent ordered request/ack ledger and content hashes: each acknowledged transaction remains reflected unless superseded by a later committed write; an unacknowledged one may be absent or committed, but must recover atomically under the declared write contract and be safe to retry. |
| `FUT-QUORUM-FENCE` | No-quorum safety, retries, stale writers | Q + H | Partition 2+1 and separately lose two voters. The minority/no-quorum side must not acknowledge mutations; the majority may acknowledge only while both durable-copy and quorum requirements hold. Retry lost responses with the same request ID without duplicate effects. After a newer fence, reject stale publication and successful new acknowledgements, preserve committed data, and reject lower epochs on data nodes that have observed the fence. An isolated node may temporarily accept only harmless immutable orphan preparation before learning it; reconcile that preparation without publishing it. |
| `FUT-RECONFIG` | Learner and membership changes | Q + H | Add a non-voting learner, catch it up, promote it only after the required state is durable, and replace a voter using a safe old/new quorum transition. Inject partition, crash and retry during catch-up and reconfiguration; no conflicting committed histories or unsafe acknowledgments may result. |
| `FUT-REPAIR` | Copy loss, checksum, scrub and tension | Q + H | Lose a copy, corrupt another in a separate trial, and run reads/scrub: detect checksum mismatch, quarantine corrupt data, report degradation, and rebuild from a verified healthy copy to an independent failure domain; if none is healthy, fail safely rather than invent data. Under constrained resources, demonstrate the documented tension priority and tie breaks; with a stable eligible repair queue, verify its fairness rule makes progress for the oldest eligible extent. Report blocked repair rather than claiming a time bound when capacity or progress is unavailable. Never relax the two-copy acknowledgment rule. |
| `FUT-BACKUP` | Backup and restore | Q + H | Create an independently stored, protected, consistent backup of guest data, metadata and necessary firmware/vTPM state; restore to a separate environment and boot both guest types, comparing application data hashes and identity/security state. Document and measure user-approved recovery-point and recovery-time objectives; replica copies alone are not backups. |
| `FUT-OPERATIONS` | Operator RBAC, audit, degraded view | Q + H | Exercise authorized and denied roles for VM, network and storage operations; verify audit records include actor, action, target, result and time without secrets, survive restart, and cannot be erased by an unauthorized operator. During node loss, lag and quorum loss, the cluster view must distinguish healthy, degraded and unknown/stale data, show lost quorum/replica health, and not display stale success as current. |
| `FUT-SUPPORT-VM` | Support VM failure | Q + H | Stop/crash a support VM while guest work and I/O are active. Other tenants remain isolated, dependent operations fail safely or show degraded state, and no unsafe write is acknowledged; restart/reconcile the support VM and verify recovery without silently duplicating requests. |
| `FUT-VIRT` | Direct and optional nested isolation and acceleration | Q + H | For the direct QEMU test, identify outer L0 Linux/KVM -> L1 Catenary -> L2 direct guest and record accelerator, QMP KVM state, attributable nested-entry/exit telemetry, guest behavior, and isolation. Separately test the optional support path on physical hardware as L0 Catenary -> L1 Linux/KVM support VM -> L2 nested guest: prove the L1 VMM opens `/dev/kvm` and executes the L2 with hardware acceleration, and probe memory/device/port isolation and quotas. If this path is tested inside outer QEMU, identify all four levels: outer L0 -> L1 Catenary -> L2 support VM -> L3 nested guest. A host QMP KVM flag or direct-guest run alone does not prove KVM inside the support VM. Missing hardware or nested support blocks that optional gate; TCG fallback is diagnostic only. |

Acceptance requires reviewed evidence for each applicable row, including the physical and licensed-media prerequisites; a historical model result or an incomplete QEMU smoke trace cannot substitute for a missing row.
