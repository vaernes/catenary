# Catenary OS Phase 9 — Historical Reference-Model Test Report

- **Status**: HISTORICAL MODEL REPORT; SYSTEM ACCEPTANCE NOT ESTABLISHED
- **Original status label**: READY & VALIDATED (historical suite-only claim; superseded as a product sign-off)
- **Date**: 2026-11-04
- **Author**: E2E Test Suite Architect (Dual Track)
- **Parent Orchestrator**: `71ae3b63-1533-458a-a1be-4f77b3f79671`

---

## 1. Executive Summary

This report preserves the historical results and case descriptions for **Catenary OS Phase 9 (Multi-VCPU, SMP MicroVMs & Live Serial Console)**. The legacy-named E2E runner exercises Python reference models and simulated inputs, not an opaque-box or end-to-end execution of the OS. Its reported outcomes do not establish actual boot, guest behavior, hardware isolation, production readiness, or complete Phase 9 requirements coverage.

The original **Dual Track** report recorded:
- **Requirement context**: Historical R1–R4 descriptions cited `ORIGINAL_REQUEST.md` and [PROJECT.md](PROJECT.md); they are expected contracts, not verified implemented behavior. Model internals and self-declared constants are used, so the suite is not opaque-box system testing.
- **Four model tiers**: 20 feature cases, 20 boundary cases, 6 combinations, and 4 simulated scenarios.
- **Historical result dated 2026-11-04**: **50/50 (100%) reported passing** for those model cases. This is not a percentage of product requirements completed and was not re-run for this documentation update.

[tests/test_harness.py](tests/test_harness.py) defines the models; [the Tier 4 source](tests/tier4_scenarios/test_real_world_scenarios.py) uses a literal boot trace and prewritten guest responses rather than launching QEMU. The [detailed historical matrix](TEST_INFRA.md#4-historical-model-check-matrix) distinguishes modeled assertions from the stronger intended contracts.

As inspected on 2026-11-05, the tracked baseline of [test_qemu.sh](test_qemu.sh) lists `default`, `vmx-linux`, `vmx-linux-services`, and `ui-phase8` only; `phase9` is absent from that baseline. The current working tree adds a `phase9` profile and has live QEMU evidence for its exercised path, recorded separately in [Section 8](#8-current-worktree-verification). That evidence does not establish hardware acceptance, complete Phase 9 requirements coverage, or production readiness.

---

## 2. Test Execution Commands

The historical model runner requires Python 3.10+ (standard library only; zero external pip dependencies). These commands describe the model suite; the current standard-discovery result is recorded in Section 8.

```bash
# 1. Run the legacy-named model runner (four tiers)
./tests/run_e2e_tests.sh

# 2. Run with verbose test case listing
./tests/run_e2e_tests.sh -v

# 3. Run individual test tiers
./tests/run_e2e_tests.sh --tier 1    # Tier 1: Feature Coverage (20 tests)
./tests/run_e2e_tests.sh --tier 2    # Tier 2: Boundary & Corner Cases (20 tests)
./tests/run_e2e_tests.sh --tier 3    # Tier 3: Cross-Feature Combinations (6 tests)
./tests/run_e2e_tests.sh --tier 4    # Tier 4: Simulated Operational Scenarios (4 cases)

# 4. Standard Python unittest discovery
python3 -m unittest discover -s tests -p "test_*.py"
```

Standard discovery is broader than the four-tier runner and may find other Python tests with different prerequisites; do not assume it has the same 50-case scope.

---

## 3. Historical Reported Model Results Breakdown

The counts, percentages, and timings below are reproduced from the 2026-11-04 report, not a new execution or measurements of live integration coverage.

| Tier | Focus | Test Count | Passing | Pass Rate | Execution Time |
|------|-------|------------|---------|-----------|----------------|
| **Tier 1** | **Feature Coverage** (>=5 per feature) | 20 | 20 | 100% | 0.010s |
| **Tier 2** | **Boundary & Corner Cases** (>=5 per feature) | 20 | 20 | 100% | 0.064s |
| **Tier 3** | **Cross-Feature Combinations** (Pairwise coverage) | 6 | 6 | 100% | 0.006s |
| **Tier 4** | **Simulated Operational Scenarios** | 4 | 4 | 100% | 0.018s |
| **Total** | **Four-Tier Model Suite** | **50** | **50** | **100%** | **~0.050s** |

The original per-tier times sum to 0.098s rather than the reported total of ~0.050s; both are preserved, and the historical report does not explain the difference.

---

## 4. Historical Expected-Contract Traceability

The original IDs and descriptions are retained as model-check intent, not verified implementation results. The cases use Python models, local constants, mock handlers and literal traces; selecting or combining models does not establish real concurrency, isolation, hardware behavior or requirement coverage. See [the detailed model matrix](TEST_INFRA.md#4-historical-model-check-matrix) for the actual scope of each case.

### Feature 1: R1. Independent EPT Roots & VMCS per Instance
*Requirement*: Allocate independent EPT roots and dedicated VMCS per MicroVM instance in Ring 0 virtualization, enabling distinct address spaces and execution contexts.
- **Tier 1 (5 tests)**:
  - `T1_F1_01_ept_pml4_radix_structure`: Models PML4, PDPT, PD and PT index arithmetic and a dictionary translation; the expected real 4-level walker is not invoked.
  - `T1_F1_02_ept_independent_address_spaces`: Model roots translate identical GPA to distinct HPA frames.
  - `T1_F1_03_vmcs_dedicated_physical_pages`: Simulated distinct 4KB-aligned page addresses, not physical allocation.
  - `T1_F1_04_ept_identity_mapping_isolation`: Model mappings for zero-page (0x7000) and cmdline (0x20000).
  - `T1_F1_05_vmcs_revision_id_header`: Literal simulated 31-bit VMX revision header with shadow bit 0, not an MSR read.
- **Tier 2 (5 tests)**:
  - `T2_F1_01_ept_gpa_zero_page_boundary`: Model translation of page-0 boundary GPA 0x0000_0000.
  - `T2_F1_02_ept_high_memory_boundary`: Model translation at the example 512 MiB boundary (0x1FFF_FFFF), not a demonstrated guest limit.
  - `T2_F1_03_ept_unmapped_gpa_fault`: An unmapped model GPA returns `None`; no hardware EPT violation is triggered.
  - `T2_F1_04_vmcs_page_alignment_enforcement`: A local predicate checks 4096-byte alignment, not the allocator.
  - `T2_F1_05_ept_multi_instance_page_table_isolation`: Remapping one model root leaves the other model root unchanged.

### Feature 2: R2. Concurrent Multi-MicroVM Execution Across SMP Cores
*Requirement*: Enable multiple Linux guest MicroVMs to execute concurrently across SMP cores, managing per-core VMX state, VM-exit handling, and core affinity.
- **Tier 1 (5 tests)**:
  - `T1_F2_01_per_core_vmxon_state`: Models per-core VMXON addresses and flags, not actual allocation or activation.
  - `T1_F2_02_per_core_host_exit_stack`: Compares modeled stack addresses; preventing RSP corruption remains an expected contract.
  - `T1_F2_03_per_core_tss_base_in_vmcs`: Compares modeled TSS bases; the real VMCS_HOST_TR_BASE is not read.
  - `T1_F2_04_thread_core_affinity_binding`: Checks modeled Thread.pinned_cpu eligibility.
  - `T1_F2_05_concurrent_vm_exit_handling`: Sequentially selects pinned model threads; no concurrent VM-exits occur.
- **Tier 2 (5 tests)**:
  - `T2_F2_01_smp_core_affinity_mismatch_rejection`: Model rejects a core-affinity mismatch.
  - `T2_F2_02_unpinned_thread_fallback`: Model permits unpinned threads on either modeled core.
  - `T2_F2_03_microvm_registry_concurrent_spinlock`: Uses a Python lock for 50 simulated registrations, not the kernel spinlock.
  - `T2_F2_04_max_smp_cores_boundary`: Initializes an eight-core model, not the live system's maximum.
  - `T2_F2_05_vmexit_reentry_preserves_core_context`: A toy handler changes a simulated register; real VM-exit context preservation is not tested.

### Feature 3: R3. Live Guest Serial Console Switching in windowd
*Requirement*: Add live guest serial console switching in the Ring-3 windowd TUI, streaming Linux guest ttyS0 output and forwarding keyboard input into the selected active MicroVM.
- **Tier 1 (5 tests)**:
  - `T1_F3_01_guest_console_pane_definition`: Checks model pane value 3 and DMA slot 3, not the live windowd definition.
  - `T1_F3_02_syscall_abi_console_definitions`: Checks local constants 28 and 29 without reading the syscall ABI.
  - `T1_F3_03_windowd_syscall_whitelist`: Checks a locally constructed mask, not the service allow-list.
  - `T1_F3_04_virtual_uart_dual_path_tx`: Models a 4KB circular buffer and `[vm<id>]` mirror string, not host COM1.
  - `T1_F3_05_windowd_console_switching_hotkeys`: Models [F6], [F7] and [F8]; [C]/[Enter] is an intended contract not checked by this case.
- **Tier 2 (5 tests)**:
  - `T2_F3_01_circular_tx_buffer_overflow_wrap`: A 5000-byte model write retains the latest 4096 bytes.
  - `T2_F3_02_rx_fifo_capacity_boundary`: Models 256-byte RX capacity and rejection of byte 257.
  - `T2_F3_03_invalid_vmid_console_syscall`: A mock treats 0 and 99 as invalid; the documented [ABI](src/syscall_abi.zig) says 0 defaults to 1, so this is not evidence of syscall behavior.
  - `T2_F3_04_console_scrollback_boundary`: Model viewport clamping (top=0, bottom=4000).
  - `T2_F3_05_special_ascii_control_injection`: Inserts Ctrl-C, Ctrl-D, CR, ESC and NUL directly into the model FIFO, not through the syscall pipeline.

### Feature 4: R4. Automated Phase 9 Smoke Test Profile
*Expected requirement*: An automated `SMOKE_PROFILE=phase9` would launch concurrent MicroVMs across SMP cores, observe guest progression over serial, and exit cleanly. The baseline, uncommitted working-tree branch, and unverified status are distinguished in §1.
- **Tier 1 (5 tests)**:
  - `T1_F4_01_smoke_profile_phase9_argument_handling`: Checks `-Dvmm_active=true -Dvmm_launch_linux=true` in a simulated string.
  - `T1_F4_02_smp_requirement_validation`: Checks a local SMP >= 2 predicate, not a QEMU run.
  - `T1_F4_03_qemu_monitor_phase9_key_injection`: Constructs mock form, focus and shell key strings; no monitor is contacted.
  - `T1_F4_04_milestone_pattern_assertion`: Matches required markers in a literal simulated serial log.
  - `T1_F4_05_clean_termination_and_exit_code`: Maps a simulated boolean to exit status 0; no QEMU process is terminated.
- **Tier 2 (5 tests)**:
  - `T2_F4_01_single_core_smp1_rejection_or_upgrade`: A local model promotes SMP=1 to 2.
  - `T2_F4_02_missing_kvm_fallback_tcg`: Models software TCG fallback selection (`REQUIRE_KVM=0`); it is not accelerated KVM evidence.
  - `T2_F4_03_partial_milestone_timeout_failure`: Finds a missing marker in a partial literal log, without a real timeout or exit code.
  - `T2_F4_04_stale_monitor_socket_cleanup`: Removes dummy temporary files, not a real monitor socket or PID.
  - `T2_F4_05_post_flush_pass_detection`: Compares literal pre/post-flush strings, not a QEMU serial flush.

### Modeled Cross-Feature Combinations (Tier 3)
- `T3_PAIR_01_r1_ept_and_r2_smp`: Combines model translations with sequential core selection, not concurrent execution.
- `T3_PAIR_02_r1_ept_and_r3_console`: Compares separate model UART logs; real EPT isolation is not demonstrated.
- `T3_PAIR_03_r2_smp_and_r3_console`: Models console switching and keystrokes, without guest VM-exits.
- `T3_PAIR_04_r1_ept_and_r4_smoke`: Matches literal EPT-root markers for VM 1 & 2, not the smoke profile.
- `T3_PAIR_05_r2_smp_and_r4_smoke`: Matches literal Core 0 & Core 1 vmlaunch markers, not concurrent launch.
- `T3_PAIR_06_r3_console_and_r4_smoke`: Matches a literal console-switch marker, without monitor key injection.

### Simulated Operational Scenarios (Tier 4)
- `T4_SCEN_01_dual_guest_concurrent_boot`: Intended two-guest boot to guest_rootfs init; the case selects model threads and matches a fabricated trace, with no live boot.
- `T4_SCEN_02_interactive_operator_session`: Intended interactive commands and isolated outputs; the case uses UI/UART models with prewritten `uname -r` and `ps` responses.
- `T4_SCEN_03_heavy_serial_burst_and_wraparound`: Sequential simulated ~10 KB bursts check modeled 4096-byte tails, not live concurrency or deadlocks.
- `T4_SCEN_04_lifecycle_stop_start_and_recovery`: Intended stop/restart with VM 2 undisturbed; the case manually changes model state and does not operate real VMs.

---

## 5. Historical Artifact Inventory

This inventory records the original artifacts and intended case counts; it does not establish system coverage or a new execution result.

1. [TEST_INFRA.md](TEST_INFRA.md) — Historical reference-model infrastructure specification and future acceptance matrix
2. [TEST_READY.md](TEST_READY.md) — Historical report (this document)
3. [tests/__init__.py](tests/__init__.py) — Test package root
4. [tests/test_harness.py](tests/test_harness.py) — Shared reference models and test oracles
5. [tests/run_e2e_tests.py](tests/run_e2e_tests.py) — Legacy-named CLI runner with tier filtering
6. [tests/run_e2e_tests.sh](tests/run_e2e_tests.sh) — Shell runner
7. [tests/tier1_feature_coverage/](tests/tier1_feature_coverage/) — 20 cases modeling aspects of R1–R4
8. [tests/tier2_boundaries/](tests/tier2_boundaries/) — 20 modeled boundary and corner cases
9. [tests/tier3_combinations/](tests/tier3_combinations/) — 6 modeled pairwise combinations
10. [tests/tier4_scenarios/](tests/tier4_scenarios/) — 4 simulated operational scenarios

---

## 6. Sign-off

**No product, production-readiness, or Phase 9 completion sign-off is supported by this report.** The 2026-11-04 report of 50/50 is limited to the historical model assertions. Live integration, per-guest behavior, isolation, durability and hardware acceptance need separate evidence; the model count alone must not be used as an orchestrator release gate.

---

## 7. FUTURE Acceptance Gates — Not Yet Established

The following is a planning summary, not a claim that any acceptance test exists, has been run, or passes. Every row requires **Q** (live QEMU integration) and **H** (physical hardware) evidence; **M** (models) can supplement but cannot replace either. See the [full future matrix and evidence prerequisites](TEST_INFRA.md), [project plan](PROJECT.md), [storage plan](docs/STORAGE_PLAN.md), [cluster plan](docs/CLUSTER_ORCHESTRATION.md), and [DIPC ownership/security plan](docs/DIPC_OWNERSHIP.md).

| Future area | Proposed acceptance gate |
|-------------|--------------------------|
| Ubuntu Server 26.04 LTS | Install from verified media, detach it, cold reboot and compare flushed data hashes after clean restart and power interruption; exercise UEFI/firmware, vTPM and configured serial plus graphical console. |
| Windows 11 Pro 26H2 | Use an approved user-supplied image and license; verify edition/build, UEFI Secure Boot and persistent vTPM 2.0, install/reboot/data durability including power interruption, supported configured serial/diagnostics and interactive graphical console. Missing media or license blocks acceptance; never expose keys or bypass licensing. |
| vSwitch/vNIC and policy | Demonstrate anti-spoofing and default-deny, with explicitly permitted IPv4/IPv6 traffic locally and cross-node; cover fragments, IPv6 extension headers and MTU/PMTU. Update and revoke policy during a partition, fail closed when freshness is unknown, and verify convergence with packet captures. |
| Metadata quorum and durable acknowledgments | Across three voters, require a durable 2-of-3 metadata majority and two independently durable extent copies on separate nodes/failure domains **before every successful acknowledgment**. Synthetic storage, a no-op flush and a smoke marker do not satisfy this gate. |
| Power cut, quorum loss and fencing | Fault before/after prepare, each copy flush, commit and response; compare recovered data with an independent ordered acknowledgment ledger. No-quorum nodes must not acknowledge mutations; retries must be idempotent. Stale writers cannot publish, overwrite committed data, or receive new success; an isolated data node may only accept harmless immutable orphan preparation before observing the newer fence. |
| Membership, repair and backup | Exercise learner catch-up/promotion and safe reconfiguration under failure; detect copy loss/checksum errors, scrub, quarantine and repair from a healthy copy, prioritizing higher-risk/high-tension under-replicated extents. Restore protected backups, including guest data and needed firmware/vTPM state, to an independent environment. |
| Overlay and operator controls | Demonstrate authenticated replay-safe messaging across restart/key rotation, authorized/denied operator RBAC, attributable audit records, and an accurate degraded/unknown cluster view during failures. |
| Support VM failure | Crash/stop and restart the support VM under load; verify tenant isolation, safe failure/degraded reporting, no unsafe acknowledgments, and recovery without duplicate effects. |
| L0/L1/L2 isolation and KVM | Test direct guests separately from the optional support path. On physical hardware, prove L0 Catenary -> L1 Linux/KVM support VM -> L2 guest actually uses the L1 `/dev/kvm` interface, with attributable accelerated-execution evidence and cross-layer isolation. When using outer QEMU, identify the additional L0 host, making the nested guest L3; a host QMP KVM flag alone cannot prove support-VM KVM. TCG fallback is diagnostic only and cannot satisfy the KVM gate. |

For durability, use three independently powered physical voting nodes with real storage whose flush/barrier and power-loss behavior are established, plus a learner/replacement host for reconfiguration, and retain request/acknowledgment evidence outside their failure domains. This remains a future acceptance gate; the current worktree's QEMU checks and their limits are recorded in Section 8.

## 8. Current Worktree Verification

These results were collected on 2026-11-05 from an isolated copy of the current working tree so QEMU artifacts would not overwrite existing workspace outputs.

| Check | Result | Evidence and limits |
|---|---|---|
| `python3 -m unittest discover -s tests -p 'test_*.py'` | PASS — 77 tests | Python tests; not system acceptance |
| `bash -n test_qemu.sh` and `git diff --check` on modified tracked source files | PASS | Syntax and whitespace checks |
| `SMOKE_PROFILE=phase9 TIMEOUT_SECS=180 ./test_qemu.sh` | PASS — KVM-backed QEMU | Distinct EPT roots; VM 1/core 0 and VM 2/core 1; both guest-init/rootfs milestones; VM 2 shell-ready marker; UI console switch to VM 2; injected `help` received and answered with `help env os-release exit` |
| `SMOKE_PROFILE=ui-phase8 TIMEOUT_SECS=120 ./test_qemu.sh` | PASS — QEMU | Existing Phase 8 UI profile |
| `SMOKE_PROFILE=vmx-linux-services TIMEOUT_SECS=120 ./test_qemu.sh` | FAIL — timeout | Required service and guest markers were not observed; root cause unresolved |

The Phase 9 run also rebuilt the OS with the project Zig version. The shell response demonstrates guest input and output on this QEMU path, not physical hardware behavior. The failed `vmx-linux-services` profile remains open; no physical-host, storage durability, cluster quorum, or adversarial isolation acceptance is claimed.
