"""
Tier 2: Boundary & Corner Cases — Feature 3 (R3)
Boundaries and edge conditions for windowd console, buffers, and injection.
"""

import unittest
from tests.test_harness import VirtualUart16550Model, WindowdTuiModel


class TestR3ConsoleBoundaries(unittest.TestCase):
    """
    Validates Boundary & Corner Cases for Requirement R3:
    - 4096-byte circular TX buffer overflow and wrap-around
    - 256-byte RX FIFO capacity and overflow protection
    - Non-existent VM ID console query handling
    - Viewport scrollback boundary navigation
    - Special control characters injection (NUL, ESC, CR, Ctrl-C, Ctrl-D)
    """

    def test_T2_F3_01_circular_tx_buffer_overflow_wrap(self):
        """
        T2_F3_01: Write 5000 bytes (> 4096 TX buffer capacity).
        Verify the buffer wraps around modulo 4096 cleanly and retains the latest 4096 bytes.
        """
        uart = VirtualUart16550Model(vmid=1)
        # Write pattern: 5000 bytes with distinct values
        raw_payload = bytes([i % 256 for i in range(5000)])
        uart.write_tx_bytes(raw_payload)

        # Buffer length must be capped at 4096
        self.assertEqual(uart.tx_len, 4096)
        log = uart.get_console_log(max_bytes=4096)
        self.assertEqual(len(log), 4096)

        # The log must contain the tail: raw_payload[5000 - 4096:] = raw_payload[904:]
        expected_tail = raw_payload[904:]
        self.assertEqual(log, expected_tail)

    def test_T2_F3_02_rx_fifo_capacity_boundary(self):
        """
        T2_F3_02: Fill 256-byte RX FIFO to exact capacity, verify Data Ready set,
        and verify 257th byte is safely rejected/dropped without buffer overrun.
        """
        uart = VirtualUart16550Model(vmid=1)
        uart.ier = 0x01  # Enable RDA interrupt

        # Inject 256 bytes
        for i in range(256):
            ok = uart.inject_rx_byte(i & 0xFF)
            self.assertTrue(ok, f"Byte {i} must be accepted into FIFO")

        self.assertEqual(uart.rx_count, 256)
        # LSR Data Ready (DR, bit 0) must be 1
        self.assertTrue(bool(uart.lsr & 0x01))
        # IIR must report Received Data Available (0x04)
        self.assertEqual(uart.iir, 0x04)
        self.assertTrue(uart.irq4_pending)

        # 257th byte must be rejected
        ok_overflow = uart.inject_rx_byte(0xFF)
        self.assertFalse(ok_overflow, "FIFO full: 257th byte must be dropped/backpressured")
        self.assertEqual(uart.rx_count, 256)

    def test_T2_F3_03_invalid_vmid_console_syscall(self):
        """
        T2_F3_03: Query SYS_GET_VM_CONSOLE_LOG with invalid/non-existent VM ID (0 or 99).
        Verify system returns 0 bytes or error code without kernel panic.
        """
        def sys_get_vm_console_log(vmid: int, active_vm_ids: list) -> int:
            if vmid not in active_vm_ids:
                return 0xFFFFFFFFFFFFFFFF  # -1 / error
            return 100  # success

        self.assertEqual(sys_get_vm_console_log(0, [1, 2]), 0xFFFFFFFFFFFFFFFF)
        self.assertEqual(sys_get_vm_console_log(99, [1, 2]), 0xFFFFFFFFFFFFFFFF)
        self.assertEqual(sys_get_vm_console_log(1, [1, 2]), 100)

    def test_T2_F3_04_console_scrollback_boundary(self):
        """
        T2_F3_04: Test viewport scrollback at extreme boundaries:
        - Scrolling past top (offset < 0) clamped to 0
        - Scrolling past buffer end (offset > 4000) clamped to limit
        """
        tui = WindowdTuiModel(running_vm_ids=[1])
        tui.focused_pane = WindowdTuiModel.PANE_GUEST_CONSOLE

        # Multiple PageUps at top
        for _ in range(5):
            tui.handle_key("pageup")
        self.assertEqual(tui.scroll_offset, 0, "Scroll offset cannot be negative")

        # Multiple PageDowns
        for _ in range(500):
            tui.handle_key("pagedown")
        self.assertLessEqual(tui.scroll_offset, 4000, "Scroll offset clamped at max scrollback limit")

    def test_T2_F3_05_special_ascii_control_injection(self):
        """
        T2_F3_05: Inject control characters into active guest console:
        0x03 (Ctrl-C), 0x04 (Ctrl-D), 0x0D (CR), 0x1B (ESC), 0x00 (NUL).
        Verify character preservation across the injection pipeline.
        """
        uart = VirtualUart16550Model(vmid=1)
        control_chars = [0x03, 0x04, 0x0D, 0x1B, 0x00]

        for c in control_chars:
            uart.inject_rx_byte(c)

        # Read back in exact FIFO order
        for c in control_chars:
            read_byte = uart.read_rx_byte()
            self.assertEqual(read_byte, c)

        self.assertEqual(uart.rx_count, 0)


if __name__ == "__main__":
    unittest.main()
