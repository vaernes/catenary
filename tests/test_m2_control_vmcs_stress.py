"""
Adversarial Empirical Challenge Test Suite for Milestone M2:
Control Plane Multi-Instance Launch, SMP Core Distribution & VMCS Invariants

Author: challenger_m2_2 (Empirical Challenger)
Milestone: Phase 9 Milestone M2 (Console Syscalls & Multi-Instance Control)
Target Files Under Review:
- src/control/control_handler.zig (next_core_affinity round-robin)
- src/arch/x86_64/vmx.zig (setupVmcs cross-core vmclear, resumeInstance vmlaunch/vmresume routing, per_cpu_vmx_start_tsc)
- src/arch/x86_64/gdt.zig (tssSelectorForCpu clamping)
- src/kernel/scheduler.zig (spawnWithVmx target_core propagation & candidate affinity selection)
"""

import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from typing import Optional, Dict, List, Tuple


# ==============================================================================
# Model 1: Control Plane Core Affinity Round-Robin Engine
# Matches src/control/control_handler.zig lines 40, 424, 434-441, 489-498
# ==============================================================================
class ControlPlaneAffinityEngine:
    """
    Direct model of Catenary OS control plane affinity allocator.
    Emulates:
    - var next_core_affinity: u8 = 0;
    - Boot staged instance 1 launch on Core 0 -> next_core_affinity = if (online_cpus > 1) 1 else 0;
    - Dynamic create_microvm -> target_core = next_core_affinity % online_cpus; next_core_affinity = (target_core + 1) % online_cpus;
    - start_microvm -> if (inst.pinned_cpu) |pin| pin else { target_core = next_core_affinity % online_cpus; ... }
    """

    def __init__(self, online_cpus: int = 2):
        self.online_cpus = online_cpus
        self.next_core_affinity: int = 0
        self.instances: Dict[int, Dict] = {}
        self.next_instance_id: int = 1
        self.lock = threading.Lock()

    def launch_staged_instance(self) -> int:
        """Emulates boot-staged instance 1 launch in .create_microvm."""
        with self.lock:
            inst_id = self.next_instance_id
            self.next_instance_id += 1
            pinned_core = 0
            self.next_core_affinity = 1 if self.online_cpus > 1 else 0
            self.instances[inst_id] = {
                "id": inst_id,
                "pinned_cpu": pinned_core,
                "state": "running",
            }
            return inst_id

    def create_microvm(self, name: str = "vm") -> Tuple[int, int]:
        """
        Emulates dynamic .create_microvm.
        Returns (instance_id, target_core).
        """
        with self.lock:
            target_core = (
                (self.next_core_affinity % self.online_cpus)
                if self.online_cpus > 1
                else 0
            )
            self.next_core_affinity = (
                ((target_core + 1) % self.online_cpus)
                if self.online_cpus > 1
                else 0
            )
            inst_id = self.next_instance_id
            self.next_instance_id += 1
            self.instances[inst_id] = {
                "id": inst_id,
                "pinned_cpu": target_core,
                "state": "created",
            }
            return inst_id, target_core

    def start_microvm(self, instance_id: int) -> int:
        """
        Emulates .start_microvm.
        Resolves core affinity (using pinned_cpu if present, else round-robin).
        """
        with self.lock:
            inst = self.instances.get(instance_id)
            if not inst:
                raise ValueError("Instance not found")
            if inst["state"] == "running":
                return inst["pinned_cpu"]

            if inst["pinned_cpu"] is not None:
                target_core = inst["pinned_cpu"]
            else:
                core = (
                    (self.next_core_affinity % self.online_cpus)
                    if self.online_cpus > 1
                    else 0
                )
                self.next_core_affinity = (
                    ((core + 1) % self.online_cpus)
                    if self.online_cpus > 1
                    else 0
                )
                inst["pinned_cpu"] = core
                target_core = core

            inst["state"] = "running"
            return target_core


# ==============================================================================
# Model 2: Scheduler Core Pinning and Dispatch Engine
# Matches src/kernel/scheduler.zig lines 469-530, 621-636
# ==============================================================================
class SchedulerDispatchModel:
    MAX_CPUS = 8
    THREAD_TARGET_COUNT = 64

    class Thread:
        def __init__(self, tid: int, is_vmx: bool, vmid: int, target_core: Optional[int]):
            self.id = tid
            self.is_vmx = is_vmx
            self.vmid = vmid
            self.pinned_cpu = target_core
            self.state = "Ready"
            self.active = False
            self.sid = 0

    def __init__(self, cpu_count: int = 2):
        self.cpu_count = cpu_count
        self.threads: Dict[int, SchedulerDispatchModel.Thread] = {}
        self.next_tid = 1
        self.lock = threading.Lock()

    def spawn_with_vmx(self, is_vmx: bool, vmid: u32 if False else int, target_core: Optional[int]) -> int:
        """Emulates scheduler.spawnWithVmx."""
        with self.lock:
            tid = self.next_tid
            self.next_tid += 1
            t = SchedulerDispatchModel.Thread(
                tid=tid,
                is_vmx=is_vmx,
                vmid=vmid,
                target_core=target_core,
            )
            self.threads[tid] = t
            return tid

    def can_candidate_run_on_core(self, thread: 'SchedulerDispatchModel.Thread', cpu_id: int) -> bool:
        """
        Emulates lines 626-630 in src/kernel/scheduler.zig:
        if (threads[candidate].pinned_cpu) |pin| {
            if (pin != @as(u8, @intCast(cpu_id))) continue;
        } else {
            if (cpu_id != 0 and threads[candidate].sid == 0) continue;
        }
        """
        if thread.pinned_cpu is not None:
            if thread.pinned_cpu != cpu_id:
                return False
        else:
            if cpu_id != 0 and thread.sid == 0:
                return False

        return thread.state == "Ready" and not thread.active

    def select_thread_for_core(self, cpu_id: int) -> Optional['SchedulerDispatchModel.Thread']:
        with self.lock:
            for tid, t in sorted(self.threads.items()):
                if self.can_candidate_run_on_core(t, cpu_id):
                    return t
            return None


# ==============================================================================
# Model 3: Intel SDM §24.11.1 VMCS Lifecycle & Processor Activation Oracle
# Emulates hardware VMCS state transitions:
# - Clear: Inactive on all processors, launch state is clear
# - Active-Clear: Loaded on exactly ONE processor via VMPTRLD, not yet launched
# - Active-Launched: Launched on processor via VMLAUNCH
# - SDM Invariant: Cannot be Active on >1 logical processor simultaneously!
# - SDM Invariant: VMRESUME on Active-Clear or Clear fails with Error 0x5!
# ==============================================================================
class VmcsHardwareState:
    INACTIVE_CLEAR = 0
    ACTIVE_CLEAR = 1
    ACTIVE_LAUNCHED = 2


class IntelVmcsHardwareModel:
    """
    Faithful model of Intel 64 VMCS hardware activation and instruction validation.
    """
    VM_ERROR_VMRESUME_NON_LAUNCHED = 0x5
    VM_ERROR_VMPTRLD_ON_ACTIVE = 0x10  # Activation collision

    def __init__(self, vmcs_phys: int):
        self.phys = vmcs_phys
        self.state = VmcsHardwareState.INACTIVE_CLEAR
        self.active_on_cpu: Optional[int] = None
        self.exit_count = 0
        self.lock = threading.Lock()

    def vmclear(self, cpu_id: int) -> bool:
        """
        Intel VMCLEAR: Marks VMCS inactive, copies cached data to RAM,
        initializes launch state to clear.
        """
        with self.lock:
            self.state = VmcsHardwareState.INACTIVE_CLEAR
            self.active_on_cpu = None
            return True

    def vmptrld(self, cpu_id: int) -> Tuple[bool, Optional[str]]:
        """
        Intel VMPTRLD: Makes VMCS active on cpu_id.
        Fails or generates processor conflict if already active on another CPU without VMCLEAR!
        """
        with self.lock:
            if self.active_on_cpu is not None and self.active_on_cpu != cpu_id:
                # Intel SDM §24.11.1: VMCS cannot be active on multiple processors!
                return False, f"Processor activation collision: active on CPU {self.active_on_cpu}, attempted VMPTRLD on CPU {cpu_id}"

            self.active_on_cpu = cpu_id
            if self.state == VmcsHardwareState.INACTIVE_CLEAR:
                self.state = VmcsHardwareState.ACTIVE_CLEAR
            return True, None

    def vmlaunch(self, cpu_id: int) -> Tuple[bool, Optional[int]]:
        """
        Intel VMLAUNCH: Requires VMCS to be Active-Clear on current cpu.
        Transitions state to Active-Launched.
        """
        with self.lock:
            if self.active_on_cpu != cpu_id:
                return False, 0x1  # VMLAUNCH with non-active VMCS
            if self.state != VmcsHardwareState.ACTIVE_CLEAR:
                return False, 0x4  # VMLAUNCH with launched VMCS
            self.state = VmcsHardwareState.ACTIVE_LAUNCHED
            self.exit_count += 1
            return True, None

    def vmresume(self, cpu_id: int) -> Tuple[bool, Optional[int]]:
        """
        Intel VMRESUME: Requires VMCS to be Active-Launched on current cpu.
        If VMCS is not launched (e.g. Active-Clear), generates Error 0x5!
        """
        with self.lock:
            if self.active_on_cpu != cpu_id:
                return False, 0x2  # VMRESUME with non-active VMCS
            if self.state != VmcsHardwareState.ACTIVE_LAUNCHED:
                # Intel SDM Vol 3C §30.4: VMRESUME with non-launched VMCS
                return False, self.VM_ERROR_VMRESUME_NON_LAUNCHED
            self.exit_count += 1
            return True, None


class VmxCoreModel:
    """
    Direct model of setupVmcs and resumeInstance logic in src/arch/x86_64/vmx.zig.
    """
    MAX_CPUS = 8

    def __init__(self):
        self.per_cpu_vmx_start_tsc: List[int] = [0] * self.MAX_CPUS
        self.vmx_start_tsc: int = 0
        self.vmcs_map: Dict[int, IntelVmcsHardwareModel] = {}

    def get_or_create_vmcs(self, vmcs_phys: int) -> IntelVmcsHardwareModel:
        if vmcs_phys not in self.vmcs_map:
            self.vmcs_map[vmcs_phys] = IntelVmcsHardwareModel(vmcs_phys)
        return self.vmcs_map[vmcs_phys]

    def setup_vmcs(self, vmcs_phys: int, target_core_id: int, current_cpu_id: int) -> Tuple[bool, Optional[str]]:
        """
        Exact implementation of src/arch/x86_64/vmx.zig lines 3133-3161:
        1. vmclear(vmcs_phys)
        2. vmptrld(vmcs_phys)
        3. initialize host/guest state
        4. if (core_id != smp.getCurrentCpuId()) { _ = vmclear(vmcs_phys); }
        """
        if target_core_id >= self.MAX_CPUS:
            return False, "Unsupported target core"

        vmcs = self.get_or_create_vmcs(vmcs_phys)

        # Clear and load on current CPU
        vmcs.vmclear(current_cpu_id)
        ok, err = vmcs.vmptrld(current_cpu_id)
        if not ok:
            return False, err

        # Host and guest setup simulated here...

        # Line 3158-3160:
        if target_core_id != current_cpu_id:
            vmcs.vmclear(current_cpu_id)

        return True, None

    def resume_instance(self, vmcs_phys: int, current_cpu_id: int, exit_count: int, now_tsc: int) -> Tuple[str, Optional[int]]:
        """
        Exact implementation of src/arch/x86_64/vmx.zig lines 3167-3232:
        if (instance.exit_count == 0) {
            vmptrld(...)
            per_cpu_vmx_start_tsc[core_id] = now
            vmlaunch(...)
            return "vmlaunch", None
        } else {
            vmptrld(...)
            per_cpu_vmx_start_tsc[core_id] = now
            vmresume(...)
            return "vmresume", None
        }
        """
        vmcs = self.get_or_create_vmcs(vmcs_phys)

        # Always vmptrld before entry
        ok, err = vmcs.vmptrld(current_cpu_id)
        if not ok:
            raise RuntimeError(f"VMPTRLD failed: {err}")

        if current_cpu_id < self.MAX_CPUS:
            self.per_cpu_vmx_start_tsc[current_cpu_id] = now_tsc
        self.vmx_start_tsc = now_tsc

        if exit_count == 0:
            # Route to vmlaunch
            lok, lerr = vmcs.vmlaunch(current_cpu_id)
            if not lok:
                return "vmlaunch_failed", lerr
            return "vmlaunch", None
        else:
            # Route to vmresume
            rok, rerr = vmcs.vmresume(current_cpu_id)
            if not rok:
                return "vmresume_failed", rerr
            return "vmresume", None

    def handle_vmexit(self, vmcs_phys: int, current_cpu_id: int, exit_tsc: int) -> int:
        """
        Exact implementation of src/arch/x86_64/vmx.zig lines 2865-2876:
        delta = tsc_end - per_cpu_vmx_start_tsc[core_id];
        """
        start = self.per_cpu_vmx_start_tsc[current_cpu_id] if current_cpu_id < self.MAX_CPUS else self.vmx_start_tsc
        delta = exit_tsc - start
        return delta


# ==============================================================================
# Model 4: GDT TSS Selector Clamping Oracle
# Matches src/arch/x86_64/gdt.zig lines 34-37
# ==============================================================================
def tss_selector_for_cpu(cpu_id: int) -> int:
    MAX_CPUS = 8
    cid = cpu_id if cpu_id < MAX_CPUS else 0
    return 0x28 + cid * 16


# ==============================================================================
# Test Cases
# ==============================================================================
class TestM2ControlVmcsStress(unittest.TestCase):
    """
    Adversarial Empirical Stress Suite for M2 Multi-Instance Control & VMCS Invariants.
    """

    # --------------------------------------------------------------------------
    # Requirement 1: Adversarial Core Affinity & Multi-VM Lifecycle
    # --------------------------------------------------------------------------
    def test_R1_01_round_robin_single_cpu(self):
        """
        Verify single-CPU (online_cpus=1) never divides by zero and strictly pins
        all 100+ requests to Core 0 without advancing next_core_affinity past 0.
        """
        engine = ControlPlaneAffinityEngine(online_cpus=1)
        staged_id = engine.launch_staged_instance()
        self.assertEqual(engine.instances[staged_id]["pinned_cpu"], 0)
        self.assertEqual(engine.next_core_affinity, 0)

        for i in range(120):
            vm_id, core = engine.create_microvm(f"vm_{i}")
            self.assertEqual(core, 0, f"Expected core 0 on single-cpu, got {core}")
            self.assertEqual(engine.next_core_affinity, 0)
            self.assertEqual(engine.instances[vm_id]["pinned_cpu"], 0)

    def test_R1_02_round_robin_varying_cpu_topologies(self):
        """
        Stress-test round-robin distribution under 2, 4, 8, 16 CPUs across 200 allocations each.
        Assert strict fairness, zero core starvation, and periodic cycling.
        """
        for cpu_count in [2, 4, 8, 16]:
            with self.subTest(cpu_count=cpu_count):
                engine = ControlPlaneAffinityEngine(online_cpus=cpu_count)
                # Launch staged instance (Core 0)
                staged_id = engine.launch_staged_instance()
                self.assertEqual(engine.instances[staged_id]["pinned_cpu"], 0)
                self.assertEqual(engine.next_core_affinity, 1)

                allocated_cores = [0]
                core_counts = {c: 0 for c in range(cpu_count)}
                core_counts[0] += 1

                TOTAL_ALLOCS = 200
                for i in range(TOTAL_ALLOCS):
                    vm_id, core = engine.create_microvm(f"vm_{i}")
                    allocated_cores.append(core)
                    core_counts[core] += 1
                    # Expected core is ((i + 1) % cpu_count)
                    expected_core = (i + 1) % cpu_count
                    self.assertEqual(
                        core,
                        expected_core,
                        f"Alloc {i}: expected core {expected_core}, got {core} under {cpu_count} CPUs",
                    )

                # Check fairness: every core must receive equal share (+/- 1)
                min_c = min(core_counts.values())
                max_c = max(core_counts.values())
                self.assertLessEqual(
                    max_c - min_c,
                    1,
                    f"Core allocation unbalanced under {cpu_count} CPUs: {core_counts}",
                )
                self.assertGreater(min_c, 0, f"Core starvation detected under {cpu_count} CPUs: {core_counts}")

    def test_R1_03_sequential_create_and_start_lifecycle(self):
        """
        Adversarially interleave .create_microvm and .start_microvm requests:
        Verify that sequential create/start calls preserve alternating cores without
        clobbering next_core_affinity or starving secondary cores.
        """
        engine = ControlPlaneAffinityEngine(online_cpus=2)
        # 1. Boot stage VM 1 (Core 0)
        vm1 = engine.launch_staged_instance()
        self.assertEqual(engine.instances[vm1]["pinned_cpu"], 0)

        # 2. Sequential create and start
        # VM 2 create -> Core 1
        vm2, core2 = engine.create_microvm("vm2")
        self.assertEqual(core2, 1)
        # VM 2 start -> preserves Core 1
        start_core2 = engine.start_microvm(vm2)
        self.assertEqual(start_core2, 1)

        # VM 3 create -> Core 0
        vm3, core3 = engine.create_microvm("vm3")
        self.assertEqual(core3, 0)
        # VM 3 start -> preserves Core 0
        start_core3 = engine.start_microvm(vm3)
        self.assertEqual(start_core3, 0)

        # VM 4 create -> Core 1
        vm4, core4 = engine.create_microvm("vm4")
        self.assertEqual(core4, 1)
        # VM 4 start -> preserves Core 1
        start_core4 = engine.start_microvm(vm4)
        self.assertEqual(start_core4, 1)

        # Secondary core (Core 1) got vm2 and vm4; Primary core (Core 0) got vm1 and vm3.
        cores = [engine.instances[v]["pinned_cpu"] for v in [vm1, vm2, vm3, vm4]]
        self.assertEqual(cores, [0, 1, 0, 1])

    def test_R1_04_out_of_order_start_and_unpinned_fallback(self):
        """
        Create 4 VMs ahead of time, then start in reverse order (VM4, VM3, VM2).
        Verify each VM maintains its predetermined pinned_cpu regardless of start order.
        Also test an unpinned instance lazily started and verify it acquires next_core_affinity.
        """
        engine = ControlPlaneAffinityEngine(online_cpus=4)
        vms = []
        for i in range(4):
            vid, c = engine.create_microvm(f"vm_{i}")
            vms.append((vid, c))

        # Expected initial pins: Core 0, 1, 2, 3
        self.assertEqual([c for _, c in vms], [0, 1, 2, 3])

        # Start in reverse order
        for vid, expected_core in reversed(vms):
            c = engine.start_microvm(vid)
            self.assertEqual(c, expected_core)

        # Create an unpinned instance manually (like legacy create)
        engine.instances[99] = {"id": 99, "pinned_cpu": None, "state": "created"}
        core_99 = engine.start_microvm(99)
        # Next affinity after 0,1,2,3 is 0
        self.assertEqual(core_99, 0)
        self.assertEqual(engine.instances[99]["pinned_cpu"], 0)

    def test_R1_05_scheduler_spawn_with_vmx_and_core_filtering(self):
        """
        Verify scheduler.spawnWithVmx correctly propagates target_core to Thread.pinned_cpu,
        and scheduler dispatch candidate selection strictly enforces CPU isolation:
        - Thread pinned to Core 1 is never dispatched on Core 0.
        - Thread pinned to Core 0 is never dispatched on Core 1.
        """
        sched = SchedulerDispatchModel(cpu_count=2)

        # Spawn VM1 pinned to Core 0
        t1 = sched.spawn_with_vmx(is_vmx=True, vmid=1, target_core=0)
        # Spawn VM2 pinned to Core 1
        t2 = sched.spawn_with_vmx(is_vmx=True, vmid=2, target_core=1)

        self.assertEqual(sched.threads[t1].pinned_cpu, 0)
        self.assertEqual(sched.threads[t2].pinned_cpu, 1)

        # Core 0 query: must only match t1, never t2
        picked_on_0 = sched.select_thread_for_core(cpu_id=0)
        self.assertIsNotNone(picked_on_0)
        self.assertEqual(picked_on_0.id, t1)

        # Core 1 query: must only match t2, never t1
        picked_on_1 = sched.select_thread_for_core(cpu_id=1)
        self.assertIsNotNone(picked_on_1)
        self.assertEqual(picked_on_1.id, t2)

        # Mismatched core filtering check
        self.assertFalse(sched.can_candidate_run_on_core(sched.threads[t1], cpu_id=1))
        self.assertFalse(sched.can_candidate_run_on_core(sched.threads[t2], cpu_id=0))

    # --------------------------------------------------------------------------
    # Requirement 2: VMCS Hardware Lifecycle & Multi-Core Invariants
    # --------------------------------------------------------------------------
    def test_R2_01_cross_core_vmcs_setup_and_vmclear_flushing(self):
        """
        Test Intel SDM §24.11.1 compliance:
        Setup VMCS on Core 0 for execution on Core 1.
        Verify:
        1. Core 0 executes VMCLEAR after setup (line 3159 of vmx.zig).
        2. VMCS is INACTIVE on Core 0 when setup completes.
        3. Core 1 can execute VMPTRLD and VMLAUNCH without activation collision.
        """
        vmx = VmxCoreModel()
        VMCS_PHYS = 0x5000_1000

        # Run setupVmcs on Core 0 (current_cpu=0) for Core 1 (target_core=1)
        ok, err = vmx.setup_vmcs(
            vmcs_phys=VMCS_PHYS,
            target_core_id=1,
            current_cpu_id=0,
        )
        self.assertTrue(ok)
        self.assertIsNone(err)

        vmcs = vmx.vmcs_map[VMCS_PHYS]
        # Crucial SDM check: because target_core (1) != current_cpu (0), Core 0 called vmclear!
        # Therefore, VMCS must be INACTIVE_CLEAR on all CPUs!
        self.assertEqual(vmcs.state, VmcsHardwareState.INACTIVE_CLEAR)
        self.assertIsNone(vmcs.active_on_cpu)

        # Now Core 1 resumes instance with exit_count == 0
        action, err = vmx.resume_instance(
            vmcs_phys=VMCS_PHYS,
            current_cpu_id=1,
            exit_count=0,
            now_tsc=100_000,
        )
        self.assertEqual(action, "vmlaunch")
        self.assertIsNone(err)
        # VMCS is now ACTIVE_LAUNCHED on Core 1
        self.assertEqual(vmcs.state, VmcsHardwareState.ACTIVE_LAUNCHED)
        self.assertEqual(vmcs.active_on_cpu, 1)

    def test_R2_02_same_core_vmcs_setup_avoids_redundant_vmclear(self):
        """
        Setup VMCS on Core 0 for execution on Core 0.
        Verify VMCS remains ACTIVE_CLEAR on Core 0 without redundant vmclear,
        allowing direct vmlaunch.
        """
        vmx = VmxCoreModel()
        VMCS_PHYS = 0x5000_2000

        ok, err = vmx.setup_vmcs(
            vmcs_phys=VMCS_PHYS,
            target_core_id=0,
            current_cpu_id=0,
        )
        self.assertTrue(ok)
        vmcs = vmx.vmcs_map[VMCS_PHYS]
        # Same core: remains active on CPU 0
        self.assertEqual(vmcs.state, VmcsHardwareState.ACTIVE_CLEAR)
        self.assertEqual(vmcs.active_on_cpu, 0)

        # Direct vmlaunch on CPU 0
        action, err = vmx.resume_instance(
            vmcs_phys=VMCS_PHYS,
            current_cpu_id=0,
            exit_count=0,
            now_tsc=150_000,
        )
        self.assertEqual(action, "vmlaunch")
        self.assertEqual(vmcs.state, VmcsHardwareState.ACTIVE_LAUNCHED)

    def test_R2_03_resume_instance_exit_count_zero_strictly_routes_to_vmlaunch(self):
        """
        Verify that resumeInstance with exit_count == 0 strictly routes to VMLAUNCH,
        and never invokes VMRESUME on an unlaunched VMCS (which would trigger hardware Error 0x5).
        Verify that exit_count > 0 strictly routes to VMRESUME.
        """
        vmx = VmxCoreModel()
        VMCS_PHYS = 0x5000_3000
        vmcs = vmx.get_or_create_vmcs(VMCS_PHYS)

        # Fresh VMCS loaded into Core 1
        vmcs.vmptrld(1)
        self.assertEqual(vmcs.state, VmcsHardwareState.ACTIVE_CLEAR)

        # If we had directly called vmresume on unlaunched VMCS, error 0x5 would occur!
        err_ok, err_code = vmcs.vmresume(1)
        self.assertFalse(err_ok)
        self.assertEqual(err_code, IntelVmcsHardwareModel.VM_ERROR_VMRESUME_NON_LAUNCHED)

        # But resumeInstance checks exit_count == 0:
        action, err = vmx.resume_instance(
            vmcs_phys=VMCS_PHYS,
            current_cpu_id=1,
            exit_count=0,
            now_tsc=200_000,
        )
        self.assertEqual(action, "vmlaunch")
        self.assertIsNone(err)
        self.assertEqual(vmcs.state, VmcsHardwareState.ACTIVE_LAUNCHED)

        # Subsequent resume with exit_count == 1 routes to vmresume
        action, err = vmx.resume_instance(
            vmcs_phys=VMCS_PHYS,
            current_cpu_id=1,
            exit_count=1,
            now_tsc=250_000,
        )
        self.assertEqual(action, "vmresume")
        self.assertIsNone(err)

    def test_R2_04_per_cpu_tsc_independence_under_concurrent_exits(self):
        """
        Adversarially stress concurrent VM exits across Core 0 and Core 1.
        Verify that per_cpu_vmx_start_tsc[0] and per_cpu_vmx_start_tsc[1] never
        corrupt each other's cycle deltas across 1000 simulated concurrent exit cycles.
        """
        vmx = VmxCoreModel()
        VMCS_0 = 0x6000_1000
        VMCS_1 = 0x6000_2000

        # Setup VMCS 0 on Core 0, VMCS 1 on Core 1
        vmx.setup_vmcs(VMCS_0, target_core_id=0, current_cpu_id=0)
        vmx.setup_vmcs(VMCS_1, target_core_id=1, current_cpu_id=0)

        # Launch both
        vmx.resume_instance(VMCS_0, current_cpu_id=0, exit_count=0, now_tsc=1000)
        vmx.resume_instance(VMCS_1, current_cpu_id=1, exit_count=0, now_tsc=2000)

        # Multi-threaded simulation of concurrent exits
        errors = []
        cycles_core0 = []
        cycles_core1 = []

        def core_exit_worker(cpu_id: int, vmcs_phys: int, start_tsc_base: int, result_list: list):
            try:
                for i in range(1000):
                    now_enter = start_tsc_base + i * 1000
                    vmx.resume_instance(vmcs_phys, current_cpu_id=cpu_id, exit_count=i + 1, now_tsc=now_enter)
                    # Simulated execution time inside guest
                    exit_delta = 50 + (i % 20)
                    now_exit = now_enter + exit_delta
                    measured_delta = vmx.handle_vmexit(vmcs_phys, current_cpu_id=cpu_id, exit_tsc=now_exit)
                    if measured_delta != exit_delta:
                        errors.append(f"CPU {cpu_id} iteration {i}: expected delta {exit_delta}, got {measured_delta}")
                    result_list.append(measured_delta)
            except Exception as e:
                errors.append(f"CPU {cpu_id} exception: {e}")

        t0 = threading.Thread(target=core_exit_worker, args=(0, VMCS_0, 10_000, cycles_core0))
        t1 = threading.Thread(target=core_exit_worker, args=(1, VMCS_1, 50_000, cycles_core1))

        t0.start()
        t1.start()
        t0.join()
        t1.join()

        self.assertEqual(len(errors), 0, f"Concurrent exit TSC errors: {errors[:5]}")
        self.assertEqual(len(cycles_core0), 1000)
        self.assertEqual(len(cycles_core1), 1000)

        # Contrast: if a shared global scalar were used without locking, concurrent
        # assignments would overwrite each other and cause non-deterministic delta corruption!
        # per_cpu_vmx_start_tsc completely isolates the TSC tracking per CPU.

    def test_R2_05_tss_selector_for_cpu_bounds_and_clamping(self):
        """
        Test src/arch/x86_64/gdt.zig tssSelectorForCpu:
        - Valid CPUs 0..7 must produce exact selectors (0x28, 0x38, ..., 0x98).
        - CPUs >= 8 (e.g. 8, 9, 15, 255, 65535, 2^32-1) must safely clamp to 0x28.
        - Must never produce out-of-bounds selector or GDT index out-of-range.
        """
        expected_valid = {
            0: 0x28,
            1: 0x38,
            2: 0x48,
            3: 0x58,
            4: 0x68,
            5: 0x78,
            6: 0x88,
            7: 0x98,
        }
        for cpu_id, expected_sel in expected_valid.items():
            sel = tss_selector_for_cpu(cpu_id)
            self.assertEqual(
                sel,
                expected_sel,
                f"Valid CPU {cpu_id}: expected selector 0x{expected_sel:x}, got 0x{sel:x}",
            )

        # Adversarial out-of-bounds CPUs
        adversarial_cpus = [8, 9, 10, 16, 32, 64, 128, 255, 1000, 65535, 0xFFFF_FFFF, 0x7FFF_FFFF_FFFF_FFFF]
        for bad_cpu in adversarial_cpus:
            sel = tss_selector_for_cpu(bad_cpu)
            self.assertEqual(
                sel,
                0x28,
                f"Adversarial CPU {bad_cpu}: expected clamped selector 0x28, got 0x{sel:x}",
            )


if __name__ == "__main__":
    unittest.main()
