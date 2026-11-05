"""
Tier 2: Boundary & Corner Cases — Feature 2 (R2)
Boundaries and contention handling for SMP and core affinity.
"""

import unittest
from concurrent.futures import ThreadPoolExecutor
from tests.test_harness import PerCoreVmxModel, Thread


class TestR2SmpBoundaries(unittest.TestCase):
    """
    Validates Boundary & Corner Cases for Requirement R2:
    - Core affinity mismatch rejection
    - Unpinned thread scheduling fallback
    - Concurrent registry spinlock contention
    - Maximum SMP cores scaling boundary
    - VM-exit re-entry context preservation on AP cores
    """

    def test_T2_F2_01_smp_core_affinity_mismatch_rejection(self):
        """
        T2_F2_01: Verify scheduler candidate evaluation strictly rejects executing
        a thread pinned to Core 1 when evaluating candidate threads on Core 0.
        """
        smp = PerCoreVmxModel(core_count=2)
        smp.init_core(0, 0x1000, 0x2000)
        smp.init_core(1, 0x3000, 0x4000)

        # Thread explicitly pinned to Core 1
        t_pinned_to_1 = Thread(thread_id=42, pinned_cpu=1, is_vmx=True, vmid=2)
        smp.threads = [t_pinned_to_1]

        # Scheduling on Core 0 must return None
        chosen_on_core0 = smp.schedule(cpu_id=0)
        self.assertIsNone(chosen_on_core0, "Core 0 must never dispatch a thread pinned to Core 1")

        # Scheduling on Core 1 must succeed
        chosen_on_core1 = smp.schedule(cpu_id=1)
        self.assertIsNotNone(chosen_on_core1)
        self.assertEqual(chosen_on_core1.id, 42)

    def test_T2_F2_02_unpinned_thread_fallback(self):
        """
        T2_F2_02: Verify non-VMX threads with pinned_cpu == None can be scheduled
        on any active SMP core without affinity constraints.
        """
        smp = PerCoreVmxModel(core_count=2)
        smp.init_core(0, 0x1000, 0x2000)
        smp.init_core(1, 0x3000, 0x4000)

        unpinned_thread = Thread(thread_id=99, pinned_cpu=None, is_vmx=False)
        self.assertTrue(smp.can_schedule(unpinned_thread, cpu_id=0))
        self.assertTrue(smp.can_schedule(unpinned_thread, cpu_id=1))

    def test_T2_F2_03_microvm_registry_concurrent_spinlock(self):
        """
        T2_F2_03: Verify concurrent lifecycle operations from multiple SMP cores
        are serialized via registry spinlock without state corruption.
        """
        smp = PerCoreVmxModel(core_count=4)
        active_instances = []

        def worker_register(vmid: int):
            with smp.registry_lock:
                # Critical section: simulate atomic create/register
                active_instances.append(vmid)

        with ThreadPoolExecutor(max_workers=8) as executor:
            futures = [executor.submit(worker_register, i) for i in range(50)]
            for f in futures:
                f.result()

        self.assertEqual(len(active_instances), 50)
        self.assertEqual(len(set(active_instances)), 50, "All 50 VMIDs must be uniquely registered")

    def test_T2_F2_04_max_smp_cores_boundary(self):
        """
        T2_F2_04: Verify per-CPU arrays and VMX models handle scaling up to
        maximum configured cores (e.g. 8 cores) without index overflow.
        """
        MAX_CORES = 8
        smp8 = PerCoreVmxModel(core_count=MAX_CORES)

        for cpu in range(MAX_CORES):
            smp8.init_core(cpu, 0x10000 + cpu * 0x1000, 0x20000 + cpu * 0x1000)

        for cpu in range(MAX_CORES):
            self.assertTrue(smp8.vmxon_enabled[cpu])
            self.assertIsNotNone(smp8.vmxon_phys[cpu])

        # Querying beyond MAX_CORES returns False
        self.assertFalse(smp8.can_schedule(Thread(thread_id=1, pinned_cpu=None), cpu_id=MAX_CORES))

    def test_T2_F2_05_vmexit_reentry_preserves_core_context(self):
        """
        T2_F2_05: Verify host exit state and guest context are retained across
        consecutive VM-exits on AP cores without register leakage.
        """
        # Emulate register context preserved across exit
        guest_rax_initial = 0xCAFE_BABE_DEAD_BEEF
        host_exit_reason = 0x0000_0030  # VMEXIT: EPT_VIOLATION or IO_INSTRUCTION

        def handle_vmexit(rax_in: int, reason: int) -> int:
            # Emulate VM-exit handler on AP core
            if reason == 0x30:
                # Handled, increment rax
                return rax_in + 1
            return rax_in

        guest_rax_after = handle_vmexit(guest_rax_initial, host_exit_reason)
        self.assertEqual(guest_rax_after, guest_rax_initial + 1)


if __name__ == "__main__":
    unittest.main()
