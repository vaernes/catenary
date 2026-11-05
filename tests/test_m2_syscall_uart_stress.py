#!/usr/bin/env python3
"""
Empirical Adversarial Challenge & Stress Test Suite for Phase 9 Milestone M2
(Console Syscalls ABI & Virtual 16550 UART Emulation)

Author: challenger_m2_1 (Empirical Challenger)
"""

import threading
import time
import unittest
from typing import Optional, List, Dict, Tuple


# ============================================================================
# Exact Models Derived Directly from Catenary OS Source Code
# ============================================================================

TARGET_INSTANCES = 8
SYS_GET_VM_CONSOLE_LOG = 28
SYS_VM_CONSOLE_INJECT = 29

class ServiceKind:
    NONE = 0
    NETD = 1
    STORAGED = 2
    DASHD = 3
    INPUTD = 4
    WINDOWD = 5
    CONTAINERD = 6
    CLUSTERD = 7
    CONFIGD = 8


def is_syscall_allowed(kind: int, op: int) -> bool:
    """Matches src/services/service_bootstrap.zig:96-158"""
    if op > 31:
        return False
    base_mask = (
        (1 << 1) |  # SYS_REGISTER
        (1 << 2) |  # SYS_RECV
        (1 << 20) | # SYS_TRY_RECV
        (1 << 4) |  # SYS_FREE_PAGE
        (1 << 5) |  # SYS_ALLOC_DMA
        (1 << 6) |  # SYS_SEND_PAGE
        (1 << 8) |  # SYS_SERIAL_WRITE
        (1 << 11) | # SYS_MAP_RECV
        (1 << 12) | # SYS_YIELD
        (1 << 27)   # SYS_SPAWN_THREAD
    )
    if kind == ServiceKind.WINDOWD:
        mask = base_mask | (1 << 16) | (1 << 17) | (1 << 19) | (1 << 20) | (1 << 21) | (1 << 26) | (1 << 18) | (1 << SYS_GET_VM_CONSOLE_LOG) | (1 << SYS_VM_CONSOLE_INJECT)
    elif kind == ServiceKind.NETD or kind == ServiceKind.STORAGED:
        mask = base_mask | (1 << 7) | (1 << 22) | (1 << 23) | (1 << 24) | (1 << 25)
    elif kind == ServiceKind.DASHD:
        mask = base_mask | (1 << 16) | (1 << 17) | (1 << 20)
    elif kind == ServiceKind.INPUTD:
        mask = base_mask | (1 << 10)
    elif kind == ServiceKind.CONTAINERD:
        mask = base_mask | (1 << 20)
    else:
        mask = base_mask

    return (mask & (1 << op)) != 0


class Virtual16550Uart:
    """Direct model of src/vmm/microvm_registry.zig:66-141 VmUartState"""

    def __init__(self, vmid: int = 1):
        self.vmid = vmid
        self.dll = 0x01
        self.dlm = 0x00
        self.ier = 0x00
        self.fcr = 0x00
        self.lcr = 0x03
        self.mcr = 0x00
        self.scr = 0x00
        self.irq4_pending = False

        self.rx_buf = bytearray(256)
        self.rx_head = 0
        self.rx_tail = 0
        self.rx_count = 0  # Fixed: integer capable of tracking up to 256

        self.tx_buf = bytearray(4096)
        self.tx_len = 0
        self.lock = threading.Lock()

    def reset(self):
        with self.lock:
            self.dll = 0x01
            self.dlm = 0x00
            self.ier = 0x00
            self.fcr = 0x00
            self.lcr = 0x03
            self.mcr = 0x00
            self.scr = 0x00
            self.irq4_pending = False
            self.rx_head = 0
            self.rx_tail = 0
            self.rx_count = 0
            self.tx_len = 0

    def write_tx_byte(self, ch: int) -> None:
        """Models VmUartState.writeTxByte"""
        with self.lock:
            if self.tx_len < len(self.tx_buf):
                self.tx_buf[self.tx_len] = ch & 0xFF
                self.tx_len += 1
            else:
                # Scrollback circular slide
                self.tx_buf[0:-1] = self.tx_buf[1:]
                self.tx_buf[-1] = ch & 0xFF

    def read_tx_log(self, max_bytes: int) -> bytes:
        """Models VmUartState.readTxLog"""
        with self.lock:
            to_copy = min(self.tx_len, max_bytes)
            return bytes(self.tx_buf[0:to_copy])

    def inject_rx_byte(self, ch: int) -> bool:
        """Models VmUartState.injectRxByte"""
        with self.lock:
            if self.rx_count >= 256:
                return False
            self.rx_buf[self.rx_tail] = ch & 0xFF
            self.rx_tail = (self.rx_tail + 1) & 0xFF
            self.rx_count += 1
            self.irq4_pending = True
            return True

    def read_rx_byte(self) -> Optional[int]:
        """Models VmUartState.readRxByte"""
        with self.lock:
            if self.rx_count == 0:
                return None
            ch = self.rx_buf[self.rx_head]
            self.rx_head = (self.rx_head + 1) & 0xFF
            self.rx_count -= 1
            if self.rx_count == 0:
                self.irq4_pending = False
            return ch

    def is_rx_empty(self) -> bool:
        with self.lock:
            return self.rx_count == 0

    @property
    def lsr(self) -> int:
        """COM1 LSR register (Port 0x3FD)"""
        with self.lock:
            val = 0x60  # THRE and TEMT always set
            if self.rx_count > 0:
                val |= 0x01  # Data Ready (DR)
            return val


class KernelSyscallDispatcher:
    """Models userModeSyscallBridge dispatch for ops 28 & 29"""

    def __init__(self):
        self.uarts: Dict[int, Virtual16550Uart] = {}
        self.lock = threading.Lock()

    def create_vm(self, vmid: int):
        with self.lock:
            self.uarts[vmid] = Virtual16550Uart(vmid)

    def dispatch_get_vm_console_log(
        self,
        caller_kind: int,
        valid_token: bool,
        page_phys: int,
        arg_vmid: int,
        dest_dma_buffer: bytearray,
    ) -> int:
        """src/arch/x86_64/user_mode.zig:883-896"""
        if not valid_token:
            return 0
        if caller_kind != ServiceKind.WINDOWD:
            return 0
        if page_phys == 0:
            return 0

        # raw_vmid = @as(u32, @truncate(arg1));
        raw_vmid = arg_vmid & 0xFFFFFFFF
        # vmid = if (raw_vmid == 0) 1 else raw_vmid;
        vmid = 1 if raw_vmid == 0 else raw_vmid
        if vmid > TARGET_INSTANCES:
            return 0

        # Safety: destination DMA buffer must have at least 4096 bytes allocated
        if len(dest_dma_buffer) < 4096:
            return 0

        uart = self.uarts.get(vmid)
        if uart is None:
            dest_dma_buffer[0] = 0
            return 0

        # dest[0..4095]
        log = uart.read_tx_log(4095)
        copied = len(log)
        dest_dma_buffer[0:copied] = log
        dest_dma_buffer[copied] = 0  # null termination guarantee
        return copied

    def dispatch_vm_console_inject(
        self,
        caller_kind: int,
        valid_token: bool,
        arg_vmid: int,
        arg_char: int,
    ) -> int:
        """src/arch/x86_64/user_mode.zig:897-914"""
        if not valid_token:
            return 0xFFFFFFFF
        if caller_kind != ServiceKind.WINDOWD:
            return 0xFFFFFFFF

        raw_vmid = arg_vmid & 0xFFFFFFFF
        vmid = 1 if raw_vmid == 0 else raw_vmid
        if vmid > TARGET_INSTANCES:
            return 0xFFFFFFFF

        uart = self.uarts.get(vmid)
        if uart is None:
            return 0xFFFFFFFF

        ch = arg_char & 0xFF
        if not uart.inject_rx_byte(ch):
            return 0xFFFFFFFF
        return 0


class LinePrefixMultiplexer:
    """Models writeCom1CharWithPrefix in src/arch/x86_64/vmx.zig:771-802"""

    def __init__(self):
        self.vm_line_start = [True] * (TARGET_INSTANCES + 1)
        self.lock = threading.Lock()
        self.output = []

    def write_char(self, vmid: int, ch: str):
        with self.lock:
            idx = vmid if vmid < len(self.vm_line_start) else 0
            if self.vm_line_start[idx]:
                tag = f"[vm{vmid}] "
                self.output.append(tag)
                self.vm_line_start[idx] = False

            self.output.append(ch)
            if ch == '\n':
                self.vm_line_start[idx] = True

    def write_string(self, vmid: int, s: str):
        for c in s:
            self.write_char(vmid, c)

    def get_output_string(self) -> str:
        with self.lock:
            return "".join(self.output)


# ============================================================================
# Unit & Stress Test Suites
# ============================================================================

class TestAdversarialSyscallBoundaries(unittest.TestCase):
    """
    Requirement 1: Adversarial Syscall Boundary Tests
    - Out-of-bounds VMIDs: negative, 0, TARGET_INSTANCES+1, 0xFFFFFFFF
    - DMA buffer safety: sizes 0, 1, 4095, 4096, 8192, 4095 clamp & null-termination
    - Unauthorized caller access: syscall fails if caller is not windowd
    """

    def setUp(self):
        self.dispatcher = KernelSyscallDispatcher()
        self.dispatcher.create_vm(1)
        self.uart1 = self.dispatcher.uarts[1]

    def test_unauthorized_callers_rejected(self):
        """Ensure all non-windowd services cannot call console syscalls"""
        unauthorized = [
            ServiceKind.NONE,
            ServiceKind.NETD,
            ServiceKind.STORAGED,
            ServiceKind.DASHD,
            ServiceKind.INPUTD,
            ServiceKind.CONTAINERD,
            ServiceKind.CLUSTERD,
            ServiceKind.CONFIGD,
        ]
        buf = bytearray(4096)
        for kind in unauthorized:
            self.assertFalse(is_syscall_allowed(kind, SYS_GET_VM_CONSOLE_LOG))
            self.assertFalse(is_syscall_allowed(kind, SYS_VM_CONSOLE_INJECT))

            ret_get = self.dispatcher.dispatch_get_vm_console_log(kind, True, 0x1000, 1, buf)
            self.assertEqual(ret_get, 0)

            ret_inj = self.dispatcher.dispatch_vm_console_inject(kind, True, 1, ord('A'))
            self.assertEqual(ret_inj, 0xFFFFFFFF)

        # windowd must be allowed
        self.assertTrue(is_syscall_allowed(ServiceKind.WINDOWD, SYS_GET_VM_CONSOLE_LOG))
        self.assertTrue(is_syscall_allowed(ServiceKind.WINDOWD, SYS_VM_CONSOLE_INJECT))

    def test_out_of_bounds_vmids(self):
        """Out-of-bounds VMIDs: negative, 0, TARGET_INSTANCES+1, 0xFFFFFFFF"""
        buf = bytearray(4096)

        # 1. Negative VMID (-1 -> 0xFFFFFFFFFFFFFFFF)
        ret = self.dispatcher.dispatch_get_vm_console_log(ServiceKind.WINDOWD, True, 0x1000, -1, buf)
        self.assertEqual(ret, 0)
        ret_inj = self.dispatcher.dispatch_vm_console_inject(ServiceKind.WINDOWD, True, -1, ord('A'))
        self.assertEqual(ret_inj, 0xFFFFFFFF)

        # 2. VMID 0 defaults to 1 (succeeds if VM1 exists)
        self.uart1.write_tx_byte(ord('X'))
        ret_zero = self.dispatcher.dispatch_get_vm_console_log(ServiceKind.WINDOWD, True, 0x1000, 0, buf)
        self.assertEqual(ret_zero, 1)
        self.assertEqual(buf[0], ord('X'))
        self.assertEqual(buf[1], 0)

        ret_inj_zero = self.dispatcher.dispatch_vm_console_inject(ServiceKind.WINDOWD, True, 0, ord('Z'))
        self.assertEqual(ret_inj_zero, 0)
        self.assertEqual(self.uart1.read_rx_byte(), ord('Z'))

        # 3. TARGET_INSTANCES + 1 (9)
        ret_oob = self.dispatcher.dispatch_get_vm_console_log(ServiceKind.WINDOWD, True, 0x1000, TARGET_INSTANCES + 1, buf)
        self.assertEqual(ret_oob, 0)
        ret_inj_oob = self.dispatcher.dispatch_vm_console_inject(ServiceKind.WINDOWD, True, TARGET_INSTANCES + 1, ord('A'))
        self.assertEqual(ret_inj_oob, 0xFFFFFFFF)

        # 4. 0xFFFFFFFF
        ret_max = self.dispatcher.dispatch_get_vm_console_log(ServiceKind.WINDOWD, True, 0x1000, 0xFFFFFFFF, buf)
        self.assertEqual(ret_max, 0)
        ret_inj_max = self.dispatcher.dispatch_vm_console_inject(ServiceKind.WINDOWD, True, 0xFFFFFFFF, ord('A'))
        self.assertEqual(ret_inj_max, 0xFFFFFFFF)

    def test_dma_buffer_boundary_and_null_termination(self):
        """Test DMA buffer sizes (0, 1, 4095, 4096, 8192) and 4095 copying clamp"""
        # Populate TX buffer with 5000 non-zero bytes
        for i in range(5000):
            self.uart1.write_tx_byte((i % 250) + 1)

        # Buffer size < 4096 rejected to prevent kernel DMA fault
        for small_size in [0, 1, 4095]:
            small_buf = bytearray(small_size)
            copied = self.dispatcher.dispatch_get_vm_console_log(ServiceKind.WINDOWD, True, 0x1000, 1, small_buf)
            self.assertEqual(copied, 0)

        # Buffer size 4096: copies exactly 4095 bytes, guaranteed null termination at dest[4095]
        buf_4k = bytearray(b'\xFF' * 4096)
        copied = self.dispatcher.dispatch_get_vm_console_log(ServiceKind.WINDOWD, True, 0x1000, 1, buf_4k)
        self.assertEqual(copied, 4095)
        self.assertEqual(buf_4k[4095], 0, "Index 4095 MUST be 0 (null-terminated)")
        self.assertTrue(all(b != 0 for b in buf_4k[:4095]))

        # Buffer size 8192: copies exactly 4095 bytes, null termination at dest[4095], remainder untouched
        buf_8k = bytearray(b'\xAA' * 8192)
        copied = self.dispatcher.dispatch_get_vm_console_log(ServiceKind.WINDOWD, True, 0x1000, 1, buf_8k)
        self.assertEqual(copied, 4095)
        self.assertEqual(buf_8k[4095], 0)
        self.assertEqual(buf_8k[4096:], b'\xAA' * (8192 - 4096))


class TestAdversarialUartRxStress(unittest.TestCase):
    """
    Requirement 2: Adversarial UART & Console Stream Stress
    - Keystroke injection fuzzing: burst 1,500+ characters into 256-byte RX FIFO
    - Circular buffer wraparound across 255->0 boundary
    - LSR Data Ready (DR) bit 0 transition and IRQ4 assertion / deassertion
    """

    def test_burst_keystroke_fuzzing_1500_chars(self):
        """Burst-inject 1,500 characters into RX FIFO. Verify capacity and overflow drop without corruption."""
        uart = Virtual16550Uart(1)

        # Fill to exact 256-byte capacity
        for i in range(256):
            ok = uart.inject_rx_byte(i & 0xFF)
            self.assertTrue(ok, f"Byte {i} must be accepted into FIFO")
            self.assertTrue(uart.irq4_pending)
            self.assertEqual(uart.lsr & 0x01, 0x01)

        self.assertEqual(uart.rx_count, 256)

        # Burst 1,244 additional bytes: all must be dropped safely
        for i in range(256, 1500):
            ok = uart.inject_rx_byte(i & 0xFF)
            self.assertFalse(ok, f"Byte {i} must be dropped on full FIFO")
            self.assertEqual(uart.rx_count, 256)

        # Verify FIFO integrity: drain 256 bytes and assert no corruption
        for i in range(256):
            ch = uart.read_rx_byte()
            self.assertIsNotNone(ch)
            self.assertEqual(ch, i & 0xFF)

        # FIFO is empty now
        self.assertTrue(uart.is_rx_empty())
        self.assertFalse(uart.irq4_pending)
        self.assertEqual(uart.lsr & 0x01, 0x00)
        self.assertIsNone(uart.read_rx_byte())

    def test_circular_wraparound_stress_10000_operations(self):
        """Stress circular wraparound over 10,000 inject/read operations across 255->0 boundary"""
        uart = Virtual16550Uart(1)
        inject_seq = 0
        read_seq = 0

        for _ in range(100):
            # Inject 100 bytes
            for _ in range(100):
                ok = uart.inject_rx_byte(inject_seq & 0xFF)
                self.assertTrue(ok)
                inject_seq += 1

            # Read 100 bytes
            for _ in range(100):
                ch = uart.read_rx_byte()
                self.assertIsNotNone(ch)
                self.assertEqual(ch, read_seq & 0xFF)
                read_seq += 1

        self.assertEqual(inject_seq, read_seq)
        self.assertEqual(inject_seq, 10000)
        self.assertTrue(uart.is_rx_empty())

    def test_lsr_dr_and_irq4_transitions(self):
        """Verify LSR bit 0 (Data Ready) and IRQ4 assert on byte entry and clear when FIFO drains"""
        uart = Virtual16550Uart(1)

        self.assertEqual(uart.lsr & 0x01, 0x00)
        self.assertFalse(uart.irq4_pending)

        # Byte 1 in -> DR=1, IRQ4=True
        uart.inject_rx_byte(ord('A'))
        self.assertEqual(uart.lsr & 0x01, 0x01)
        self.assertTrue(uart.irq4_pending)

        # Byte 2 in -> DR=1, IRQ4=True
        uart.inject_rx_byte(ord('B'))
        self.assertEqual(uart.lsr & 0x01, 0x01)
        self.assertTrue(uart.irq4_pending)

        # Read Byte 1 -> DR=1, IRQ4=True (FIFO still has 1 byte)
        uart.read_rx_byte()
        self.assertEqual(uart.lsr & 0x01, 0x01)
        self.assertTrue(uart.irq4_pending)

        # Read Byte 2 -> DR=0, IRQ4=False (FIFO completely empty)
        uart.read_rx_byte()
        self.assertEqual(uart.lsr & 0x01, 0x00)
        self.assertFalse(uart.irq4_pending)


class TestLinePrefixMultiplexing(unittest.TestCase):
    """
    Requirement 2: Line Prefix Multiplexing Stress
    - Interleaving newlines, carriage returns, empty lines, and long lines
    - [vm<id>] prefix atomic on first character of line
    - Prefix never interleaved mid-line
    """

    def test_newline_and_cr_prefixing(self):
        mux = LinePrefixMultiplexer()

        # Multi-line string
        mux.write_string(1, "hello\nworld\n")
        self.assertEqual(mux.get_output_string(), "[vm1] hello\n[vm1] world\n")

        # CRLF sequences
        mux2 = LinePrefixMultiplexer()
        mux2.write_string(2, "line1\r\nline2\r\n")
        self.assertEqual(mux2.get_output_string(), "[vm2] line1\r\n[vm2] line2\r\n")

        # Consecutive empty lines (\n\n\n)
        mux3 = LinePrefixMultiplexer()
        mux3.write_string(3, "\n\n\n")
        self.assertEqual(mux3.get_output_string(), "[vm3] \n[vm3] \n[vm3] \n")

    def test_long_line_no_midsequence_interleaving(self):
        mux = LinePrefixMultiplexer()
        long_line = "ABCDEFGHIJ" * 100  # 1000 characters without newline
        mux.write_string(1, long_line + "\n")

        out = mux.get_output_string()
        self.assertTrue(out.startswith("[vm1] "))
        self.assertTrue(out.endswith("\n"))
        # Verify tag does not appear mid-line
        self.assertEqual(out.count("[vm1] "), 1)
        self.assertEqual(out.count("[vm"), 1)


if __name__ == '__main__':
    unittest.main()
