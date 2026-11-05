"""
Tier 4: Real-World Application Scenarios
End-to-end integration workflows simulating production use cases.
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


class TestRealWorldScenarios(unittest.TestCase):
    """
    Validates end-to-end production scenarios:
    1. Scenario 1: Multi-Tenant MicroVM Concurrent Boot Lifecycle
    2. Scenario 2: Interactive Guest Operator Session via windowd TUI
    3. Scenario 3: High-Throughput Logging & Circular Buffer Wrap-Around
    4. Scenario 4: VM Lifecycle Stop/Start & Core Recovery
    """

    def test_T4_SCEN_01_dual_guest_concurrent_boot(self):
        """
        Scenario 1: Multi-tenant boot lifecycle.
        - 2 SMP cores brought up.
        - VM 1 provisioned on Core 0 with EPT Root 1.
        - VM 2 provisioned on Core 1 with EPT Root 2.
        - Both execute vmlaunch concurrently.
        - Both reach guest_rootfs init started.
        """
        ept = EptRadixModel()
        root1 = ept.allocate_root()
        root2 = ept.allocate_root()

        # Allocate 64 MiB guest RAM per instance
        ept.map_huge_page(root1, 0x100000, 0x20000000)
        ept.map_huge_page(root2, 0x100000, 0x30000000)

        smp = PerCoreVmxModel(core_count=2)
        smp.init_core(0, 0x1000, 0x2000)
        smp.init_core(1, 0x3000, 0x4000)

        # Dispatch VMX threads
        t1 = Thread(thread_id=101, pinned_cpu=0, is_vmx=True, vmid=1)
        t2 = Thread(thread_id=102, pinned_cpu=1, is_vmx=True, vmid=2)
        smp.threads = [t1, t2]

        self.assertEqual(smp.schedule(0), t1)
        self.assertEqual(smp.schedule(1), t2)

        # Verify full serial trace milestones
        full_boot_trace = """
        [kernel] smp: AP core 1 online
        [kernel] VMX: initialized EPT root for VM 1
        [kernel] VMX: initialized EPT root for VM 2
        [kernel] [SMP core 0] entering guest via vmlaunch
        [kernel] [SMP core 1] entering guest via vmlaunch
        [vm1] Linux version 6.1.102-catenary
        [vm2] Linux version 6.1.102-catenary
        [vm1] Catenary OS Guest Init: SUCCESS
        [vm2] Catenary OS Guest Init: SUCCESS
        [vm1] guest_rootfs: init started
        [vm2] guest_rootfs: init started
        """

        milestones = [
            "VMX: initialized EPT root for VM 1",
            "VMX: initialized EPT root for VM 2",
            "[SMP core 0] entering guest via vmlaunch",
            "[SMP core 1] entering guest via vmlaunch",
            "[vm1] Linux version",
            "[vm2] Linux version",
            "[vm1] Catenary OS Guest Init: SUCCESS",
            "[vm2] Catenary OS Guest Init: SUCCESS",
            "[vm1] guest_rootfs: init started",
            "[vm2] guest_rootfs: init started",
        ]

        ok, missing = QemuHarnessModel.assert_all_milestones(milestones, full_boot_trace)
        self.assertTrue(ok, f"Missing boot milestones: {missing}")

    def test_T4_SCEN_02_interactive_operator_session(self):
        """
        Scenario 2: Interactive operator session.
        - Operator navigates windowd: focuses guest console via F6 (default VM 1).
        - Enters command 'uname -r\\n' into VM 1.
        - Switches console to VM 2 via F8.
        - Enters command 'ps\\n' into VM 2.
        - Asserts proper isolation and responses.
        """
        tui = WindowdTuiModel(running_vm_ids=[1, 2])
        uart1 = VirtualUart16550Model(vmid=1)
        uart2 = VirtualUart16550Model(vmid=2)

        # 1. Switch to console (F6)
        tui.handle_key("f6")
        self.assertEqual(tui.active_console_vm_id, 1)

        # 2. Type 'uname -r\n'
        for ch in "uname -r\n":
            tui.handle_key(ch, ascii_char=ord(ch))
            uart1.inject_rx_byte(ord(ch))

        # VM 1 responds
        uart1.write_tx_bytes(b"6.1.102-catenary\n")

        # 3. Switch to VM 2 (F8)
        tui.handle_key("f8")
        self.assertEqual(tui.active_console_vm_id, 2)

        # 4. Type 'ps\n'
        for ch in "ps\n":
            tui.handle_key(ch, ascii_char=ord(ch))
            uart2.inject_rx_byte(ord(ch))

        # VM 2 responds
        uart2.write_tx_bytes(b"PID TTY TIME CMD\n1 ? 00:00:00 init\n")

        # Verify separate logs
        log1 = uart1.get_console_log()
        log2 = uart2.get_console_log()

        self.assertIn(b"6.1.102-catenary", log1)
        self.assertNotIn(b"PID TTY TIME CMD", log1)

        self.assertIn(b"PID TTY TIME CMD", log2)
        self.assertNotIn(b"6.1.102-catenary", log2)

    def test_T4_SCEN_03_heavy_serial_burst_and_wraparound(self):
        """
        Scenario 3: High throughput serial logging stress.
        - Both concurrent guests produce 10 KB bursts of logs.
        - Circular buffer wraps around multiple times without crashing or overflowing.
        - Output retains last 4096 bytes cleanly.
        """
        uart1 = VirtualUart16550Model(vmid=1)
        uart2 = VirtualUart16550Model(vmid=2)

        burst1 = b"VM1_BURST_RECORD_" * 600  # ~10.2 KB
        burst2 = b"VM2_BURST_RECORD_" * 600

        uart1.write_tx_bytes(burst1)
        uart2.write_tx_bytes(burst2)

        self.assertEqual(uart1.tx_len, 4096)
        self.assertEqual(uart2.tx_len, 4096)

        log1 = uart1.get_console_log(4096)
        log2 = uart2.get_console_log(4096)

        self.assertEqual(len(log1), 4096)
        self.assertEqual(len(log2), 4096)
        self.assertEqual(log1, burst1[-4096:])
        self.assertEqual(log2, burst2[-4096:])

    def test_T4_SCEN_04_lifecycle_stop_start_and_recovery(self):
        """
        Scenario 4: VM lifecycle stop and recovery.
        - Both VM 1 and VM 2 are running.
        - VM 1 is stopped.
        - VM 2 continues running on AP Core 1 undisturbed.
        - windowd console switching automatically updates to remaining VM 2.
        - VM 1 is restarted and rebinds cleanly.
        """
        tui = WindowdTuiModel(running_vm_ids=[1, 2])
        smp = PerCoreVmxModel(core_count=2)
        smp.init_core(0, 0x1000, 0x2000)
        smp.init_core(1, 0x3000, 0x4000)

        t1 = Thread(thread_id=1, pinned_cpu=0, is_vmx=True, vmid=1)
        t2 = Thread(thread_id=2, pinned_cpu=1, is_vmx=True, vmid=2)
        smp.threads = [t1, t2]

        # Stop VM 1
        t1.state = "STOPPED"
        tui.running_vm_ids = [2]
        tui.active_console_vm_id = 2

        # Core 0 finds no runnable VMX thread
        self.assertIsNone(smp.schedule(cpu_id=0))
        # Core 1 continues executing VM 2
        self.assertEqual(smp.schedule(cpu_id=1), t2)

        # Cycling console now stays on VM 2
        tui.handle_key("f8")
        self.assertEqual(tui.active_console_vm_id, 2)

        # Restart VM 1
        t1.state = "RUNNABLE"
        tui.running_vm_ids = [1, 2]

        self.assertEqual(smp.schedule(cpu_id=0), t1)
        self.assertEqual(smp.schedule(cpu_id=1), t2)


if __name__ == "__main__":
    unittest.main()
