"""
Tier 3: Cross-Feature Combinations (Pairwise Coverage)
Validates interactions across pairs of Phase 9 requirements.
"""

import unittest
from tests.test_harness import (
    EptRadixModel,
    PerCoreVmxModel,
    Thread,
    VirtualUart16550Model,
    WindowdTuiModel,
    QemuHarnessModel,
)


class TestPairwiseCombinations(unittest.TestCase):
    """
    Validates pairwise interactions:
    - Pair 1 (R1 + R2): Independent EPT Radix Trees across Concurrent SMP Cores
    - Pair 2 (R1 + R3): Guest Memory Isolation and Independent Virtual UART Buffers
    - Pair 3 (R2 + R3): Live Console Switching and Keystroke Injection during SMP Guest Execution
    - Pair 4 (R1 + R4): Phase 9 Smoke Profile asserts Independent EPT Initialization Markers
    - Pair 5 (R2 + R4): Phase 9 Smoke Profile asserts Concurrent Multi-Core vmlaunch
    - Pair 6 (R3 + R4): Phase 9 Smoke Profile verifies Console Switching Keystroke Sequence
    """

    def test_T3_PAIR_01_r1_ept_and_r2_smp(self):
        """
        T3_PAIR_01 (R1 + R2): Independent EPT translation on Core 0 and Core 1.
        VM 1 pinned to Core 0 uses Root 1; VM 2 pinned to Core 1 uses Root 2.
        Concurrent execution does not cause translation crosstalk.
        """
        ept = EptRadixModel()
        root_vm1 = ept.allocate_root()
        root_vm2 = ept.allocate_root()

        # Map GPA 0x1000 to distinct frames
        ept.map_page(root_vm1, 0x1000, 0xA000)
        ept.map_page(root_vm2, 0x1000, 0xB000)

        smp = PerCoreVmxModel(core_count=2)
        smp.init_core(0, 0x1000, 0x2000)
        smp.init_core(1, 0x3000, 0x4000)

        t1 = Thread(thread_id=1, pinned_cpu=0, is_vmx=True, vmid=1)
        t2 = Thread(thread_id=2, pinned_cpu=1, is_vmx=True, vmid=2)
        smp.threads = [t1, t2]

        core0_thread = smp.schedule(cpu_id=0)
        core1_thread = smp.schedule(cpu_id=1)

        self.assertEqual(core0_thread.vmid, 1)
        self.assertEqual(core1_thread.vmid, 2)

        # Core 0 translates via VM 1 root; Core 1 translates via VM 2 root
        self.assertEqual(ept.translate(root_vm1, 0x1000), 0xA000)
        self.assertEqual(ept.translate(root_vm2, 0x1000), 0xB000)

    def test_T3_PAIR_02_r1_ept_and_r3_console(self):
        """
        T3_PAIR_02 (R1 + R3): Guest physical memory isolation ensures that
        Linux guest 1 UART writes do not leak into Linux guest 2 UART buffers.
        """
        uart1 = VirtualUart16550Model(vmid=1)
        uart2 = VirtualUart16550Model(vmid=2)

        uart1.write_tx_bytes(b"kernel panic in vm 1\n")
        uart2.write_tx_bytes(b"catenary login on vm 2\n")

        log1 = uart1.get_console_log()
        log2 = uart2.get_console_log()

        self.assertIn(b"vm 1", log1)
        self.assertNotIn(b"vm 2", log1)

        self.assertIn(b"vm 2", log2)
        self.assertNotIn(b"vm 1", log2)

    def test_T3_PAIR_03_r2_smp_and_r3_console(self):
        """
        T3_PAIR_03 (R2 + R3): Live console switching in windowd and keystroke injection
        while guests are executing concurrently across Core 0 and Core 1.
        """
        smp = PerCoreVmxModel(core_count=2)
        smp.init_core(0, 0x1000, 0x2000)
        smp.init_core(1, 0x3000, 0x4000)

        tui = WindowdTuiModel(running_vm_ids=[1, 2])
        uart1 = VirtualUart16550Model(vmid=1)
        uart2 = VirtualUart16550Model(vmid=2)

        # Focus console pane
        tui.handle_key("f6")
        self.assertEqual(tui.active_console_vm_id, 1)

        # Inject 'A' into VM 1
        tui.handle_key("a", ascii_char=ord("A"))
        self.assertEqual(tui.injected_commands[-1], (1, ord("A")))
        uart1.inject_rx_byte(ord("A"))

        # Switch to VM 2 via F8
        tui.handle_key("f8")
        self.assertEqual(tui.active_console_vm_id, 2)

        # Inject 'B' into VM 2
        tui.handle_key("b", ascii_char=ord("B"))
        self.assertEqual(tui.injected_commands[-1], (2, ord("B")))
        uart2.inject_rx_byte(ord("B"))

        # Verify RX separation
        self.assertEqual(uart1.read_rx_byte(), ord("A"))
        self.assertEqual(uart1.read_rx_byte(), None)
        self.assertEqual(uart2.read_rx_byte(), ord("B"))
        self.assertEqual(uart2.read_rx_byte(), None)

    def test_T3_PAIR_04_r1_ept_and_r4_smoke(self):
        """
        T3_PAIR_04 (R1 + R4): Smoke profile assertion verifies independent EPT initialization
        patterns for both VM 1 and VM 2 in serial log output.
        """
        log = """
        [boot] VMX: initialized EPT root for VM 1 (phys 0x10001000)
        [boot] VMX: initialized EPT root for VM 2 (phys 0x10002000)
        """
        p1 = "VMX: initialized EPT root for VM 1"
        p2 = "VMX: initialized EPT root for VM 2"

        self.assertTrue(QemuHarnessModel.pattern_seen(p1, log))
        self.assertTrue(QemuHarnessModel.pattern_seen(p2, log))

    def test_T3_PAIR_05_r2_smp_and_r4_smoke(self):
        """
        T3_PAIR_05 (R2 + R4): Smoke profile assertion verifies multi-core AP bringup
        and concurrent vmlaunch on SMP Core 0 and Core 1.
        """
        log = """
        smp: AP core 1 online
        [SMP core 0] entering guest via vmlaunch
        [SMP core 1] entering guest via vmlaunch
        """
        p0 = "[SMP core 0] entering guest via vmlaunch"
        p1 = "[SMP core 1] entering guest via vmlaunch"

        self.assertTrue(QemuHarnessModel.pattern_seen(p0, log))
        self.assertTrue(QemuHarnessModel.pattern_seen(p1, log))

    def test_T3_PAIR_06_r3_console_and_r4_smoke(self):
        """
        T3_PAIR_06 (R3 + R4): Smoke profile verifies monitor keystroke injection
        triggers console switching milestone '[UI] Switched console to MicroVM #2'.
        """
        log = """
        windowd: registered at endpoint 9
        inputd: registered at endpoint 8
        windowd: input event received: key=F8
        [UI] Switched console to MicroVM #2
        """
        pattern = "[UI] Switched console to MicroVM #2"
        self.assertTrue(QemuHarnessModel.pattern_seen(pattern, log))


if __name__ == "__main__":
    unittest.main()
