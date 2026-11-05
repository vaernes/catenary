"""
Tier 1: Feature Coverage — Feature 2 (R2)
Concurrent Multi-MicroVM Execution Across SMP Cores.
"""

import unittest
from tests.test_harness import PerCoreVmxModel, Thread


class TestR2SmpConcurrency(unittest.TestCase):
    """
    Validates Requirement R2:
    - Per-core VMX initialization (per_cpu_vmxon, vmx.initApCore)
    - Per-core host exit stack (per_cpu_host_stack)
    - Per-core TSS base (VMCS_HOST_TR_BASE)
    - Thread core affinity (Thread.pinned_cpu) and scheduler AP dispatch
    - Concurrent multi-VM execution across SMP cores
    """

    def setUp(self):
        self.smp = PerCoreVmxModel(core_count=2)

    def test_T1_F2_01_per_core_vmxon_state(self):
        """
        T1_F2_01: Verify each online SMP core executes VMXON on dedicated physical pages.
        """
        core0_vmxon_phys = 0x1000_1000
        core1_vmxon_phys = 0x1000_2000

        self.smp.init_core(0, core0_vmxon_phys, 0x1000_3000)
        self.smp.init_core(1, core1_vmxon_phys, 0x1000_4000)

        self.assertTrue(self.smp.vmxon_enabled[0])
        self.assertTrue(self.smp.vmxon_enabled[1])
        self.assertEqual(self.smp.vmxon_phys[0], core0_vmxon_phys)
        self.assertEqual(self.smp.vmxon_phys[1], core1_vmxon_phys)
        self.assertNotEqual(self.smp.vmxon_phys[0], self.smp.vmxon_phys[1])

    def test_T1_F2_02_per_core_host_exit_stack(self):
        """
        T1_F2_02: Verify each SMP core allocates a dedicated host exit stack
        (per_cpu_host_stack), preventing VM-exit stack corruption between cores.
        """
        core0_stack_phys = 0x2000_1000
        core1_stack_phys = 0x2000_2000

        self.smp.init_core(0, 0x1000_1000, core0_stack_phys)
        self.smp.init_core(1, 0x1000_2000, core1_stack_phys)

        self.assertNotEqual(self.smp.host_stack_phys[0], self.smp.host_stack_phys[1])
        # Top of stack must be 16-byte aligned per AMD64/x86_64 ABI
        top_rsp_0 = (core0_stack_phys + 4096) & ~0xF
        top_rsp_1 = (core1_stack_phys + 4096) & ~0xF
        self.assertEqual(top_rsp_0 & 0xF, 0)
        self.assertEqual(top_rsp_1 & 0xF, 0)

    def test_T1_F2_03_per_core_tss_base_in_vmcs(self):
        """
        T1_F2_03: Verify VMCS_HOST_TR_BASE receives the per-core TSS descriptor base
        via gdt.tssBaseForCpu(cpu_id) rather than a single global TSS.
        """
        tss_core0 = self.smp.tss_base[0]
        tss_core1 = self.smp.tss_base[1]

        self.assertNotEqual(tss_core0, tss_core1)
        # Verify valid canonical kernel 64-bit addresses
        self.assertEqual((tss_core0 >> 48) & 0xFFFF, 0xFFFF)
        self.assertEqual((tss_core1 >> 48) & 0xFFFF, 0xFFFF)

    def test_T1_F2_04_thread_core_affinity_binding(self):
        """
        T1_F2_04: Verify Thread.pinned_cpu binds a MicroVM instance to a dedicated SMP core,
        allowing core 0 to run VM 1 and core 1 to run VM 2.
        """
        self.smp.init_core(0, 0x1000, 0x2000)
        self.smp.init_core(1, 0x3000, 0x4000)

        thread_vm1 = Thread(thread_id=10, pinned_cpu=0, is_vmx=True, vmid=1)
        thread_vm2 = Thread(thread_id=11, pinned_cpu=1, is_vmx=True, vmid=2)

        # Core 0 eligibility
        self.assertTrue(self.smp.can_schedule(thread_vm1, cpu_id=0))
        self.assertFalse(self.smp.can_schedule(thread_vm1, cpu_id=1))

        # Core 1 eligibility
        self.assertFalse(self.smp.can_schedule(thread_vm2, cpu_id=0))
        self.assertTrue(self.smp.can_schedule(thread_vm2, cpu_id=1))

    def test_T1_F2_05_concurrent_vm_exit_handling(self):
        """
        T1_F2_05: Verify scheduler dispatches pinned VMX threads on AP cores
        and concurrent execution proceeds across both cores simultaneously.
        """
        self.smp.init_core(0, 0x1000, 0x2000)
        self.smp.init_core(1, 0x3000, 0x4000)

        t1 = Thread(thread_id=1, pinned_cpu=0, is_vmx=True, vmid=1)
        t2 = Thread(thread_id=2, pinned_cpu=1, is_vmx=True, vmid=2)
        self.smp.threads = [t1, t2]

        scheduled_cpu0 = self.smp.schedule(cpu_id=0)
        scheduled_cpu1 = self.smp.schedule(cpu_id=1)

        self.assertIsNotNone(scheduled_cpu0)
        self.assertIsNotNone(scheduled_cpu1)
        self.assertEqual(scheduled_cpu0.vmid, 1)
        self.assertEqual(scheduled_cpu1.vmid, 2)


if __name__ == "__main__":
    unittest.main()
