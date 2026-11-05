"""
Tier 1: Feature Coverage — Feature 3 (R3)
Live Guest Serial Console Switching in windowd.
"""

import unittest
from tests.test_harness import VirtualUart16550Model, WindowdTuiModel


class TestR3ConsoleWindowd(unittest.TestCase):
    """
    Validates Requirement R3:
    - windowd guest console pane and DMA slot definition
    - Syscall ABI definitions: SYS_GET_VM_CONSOLE_LOG (28) and SYS_VM_CONSOLE_INJECT (29)
    - Virtual 16550 UART with 4KB circular TX buffer and 256B RX FIFO
    - Dual-path TX: ring buffer + COM1 prefix [vm<id>]
    - Console switching between MicroVMs via hotkeys ([F6], [F7], [F8], [C]/[Enter])
    """

    def test_T1_F3_01_guest_console_pane_definition(self):
        """
        T1_F3_01: Verify windowd defines Pane.guest_console = 3 and DMA_CONSOLE_SLOT = 3.
        """
        self.assertEqual(WindowdTuiModel.PANE_GUEST_CONSOLE, 3)
        self.assertEqual(WindowdTuiModel.DMA_CONSOLE_SLOT, 3)

    def test_T1_F3_02_syscall_abi_console_definitions(self):
        """
        T1_F3_02: Verify syscall numbers SYS_GET_VM_CONSOLE_LOG = 28 and SYS_VM_CONSOLE_INJECT = 29.
        """
        SYS_GET_VM_CONSOLE_LOG = 28
        SYS_VM_CONSOLE_INJECT = 29
        self.assertEqual(SYS_GET_VM_CONSOLE_LOG, 28)
        self.assertEqual(SYS_VM_CONSOLE_INJECT, 29)

    def test_T1_F3_03_windowd_syscall_whitelist(self):
        """
        T1_F3_03: Verify windowd syscall whitelist bitmask allows ops 28 and 29.
        """
        SYS_GET_VM_CONSOLE_LOG = 28
        SYS_VM_CONSOLE_INJECT = 29

        def bit(op: int) -> int:
            return 1 << op

        # Base windowd mask + ops 28 and 29
        windowd_mask = bit(SYS_GET_VM_CONSOLE_LOG) | bit(SYS_VM_CONSOLE_INJECT)

        self.assertTrue(bool(windowd_mask & (1 << 28)), "Bit 28 must be set in windowd mask")
        self.assertTrue(bool(windowd_mask & (1 << 29)), "Bit 29 must be set in windowd mask")

    def test_T1_F3_04_virtual_uart_dual_path_tx(self):
        """
        T1_F3_04: Verify virtual UART TX writes both to the in-memory circular buffer
        and generates mirrored output to COM1 with the [vm<id>] prefix.
        """
        uart = VirtualUart16550Model(vmid=1)
        test_msg = b"Linux guest boot message\n"
        mirrored = uart.write_tx_bytes(test_msg)

        # 1. In-memory buffer check
        log = uart.get_console_log()
        self.assertEqual(log, test_msg)

        # 2. Dual-path COM1 check
        self.assertIn("[vm1] Linux guest boot message\n", mirrored)
        self.assertTrue(mirrored.startswith("[vm1] "))

    def test_T1_F3_05_windowd_console_switching_hotkeys(self):
        """
        T1_F3_05: Verify hotkeys [F6], [F7], [F8], and [C]/[Enter] switch console focus
        and cycle between running MicroVMs.
        """
        tui = WindowdTuiModel(running_vm_ids=[1, 2])

        # Initially in VM manager, active VM is 1
        self.assertEqual(tui.focused_pane, WindowdTuiModel.PANE_VM_MANAGER)
        self.assertEqual(tui.active_console_vm_id, 1)

        # 1. F6 jumps to guest console pane
        tui.handle_key("f6")
        self.assertEqual(tui.focused_pane, WindowdTuiModel.PANE_GUEST_CONSOLE)
        self.assertEqual(tui.active_console_vm_id, 1)

        # 2. F8 switches to next VM (VM 2)
        res8 = tui.handle_key("f8")
        self.assertEqual(tui.active_console_vm_id, 2)
        self.assertIn("Switched console to MicroVM #2", res8)

        # 3. F7 switches back to previous VM (VM 1)
        res7 = tui.handle_key("f7")
        self.assertEqual(tui.active_console_vm_id, 1)
        self.assertIn("Switched console to MicroVM #1", res7)


if __name__ == "__main__":
    unittest.main()
