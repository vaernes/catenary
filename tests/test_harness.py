"""
Shared Test Harness and Reference Oracles for Catenary OS Phase 9 E2E Testing.
Author: E2E Test Suite Architect (Dual Track)

Provides mathematical reference models, state machine oracles, and verification
utilities derived from:
- Intel 64 and IA-32 Architectures Software Developer's Manual (SDM Vol 3C)
- 16550A UART Specification
- Catenary OS Interface Contracts (PROJECT.md)
"""

import re
import threading
from typing import Optional, Dict, List, Tuple


class EptRadixModel:
    """
    Mathematical reference oracle for 4-level Extended Page Table (EPT) translation.
    Matches translateEptGpaToHpa(root_phys, gpa).
    """

    PAGE_SIZE = 4096
    HUGE_PAGE_SIZE = 2 * 1024 * 1024  # 2 MiB
    PML4_MASK = 0x1FF
    PDPT_MASK = 0x1FF
    PD_MASK = 0x1FF
    PT_MASK = 0x1FF

    def __init__(self):
        # Maps root_phys -> {gpa_page_base: (hpa_frame, flags, is_huge)}
        self.roots: Dict[int, Dict[int, Tuple[int, int, bool]]] = {}
        self.next_root_phys = 0x1000000

    def allocate_root(self) -> int:
        root_phys = self.next_root_phys
        self.next_root_phys += self.PAGE_SIZE
        self.roots[root_phys] = {}
        return root_phys

    def map_page(self, root_phys: int, gpa: int, hpa: int, flags: int = 0x7) -> None:
        """Map 4 KiB page at gpa to hpa."""
        if root_phys not in self.roots:
            raise ValueError(f"Unknown EPT root 0x{root_phys:x}")
        page_base = gpa & ~0xFFF
        hpa_base = hpa & ~0xFFF
        self.roots[root_phys][page_base] = (hpa_base, flags, False)

    def map_huge_page(self, root_phys: int, gpa: int, hpa: int, flags: int = 0x87) -> None:
        """Map 2 MiB huge page at gpa to hpa."""
        if root_phys not in self.roots:
            raise ValueError(f"Unknown EPT root 0x{root_phys:x}")
        huge_base = gpa & ~0x1FFFFF
        hpa_base = hpa & ~0x1FFFFF
        self.roots[root_phys][huge_base] = (hpa_base, flags, True)

    def translate(self, root_phys: int, gpa: int) -> Optional[int]:
        """
        Translates GPA to HPA using EPT radix tree walking rules.
        Returns HPA or None if unmapped.
        """
        if root_phys not in self.roots:
            return None

        table = self.roots[root_phys]

        # Check 4 KiB page mapping
        page_base = gpa & ~0xFFF
        if page_base in table:
            hpa_base, flags, is_huge = table[page_base]
            if not is_huge:
                offset = gpa & 0xFFF
                return hpa_base | offset

        # Check 2 MiB huge page mapping
        huge_base = gpa & ~0x1FFFFF
        if huge_base in table:
            hpa_base, flags, is_huge = table[huge_base]
            if is_huge:
                offset = gpa & 0x1FFFFF
                return hpa_base | offset

        return None

    @staticmethod
    def get_indices(gpa: int) -> Tuple[int, int, int, int, int]:
        """Return (pml4_idx, pdpt_idx, pd_idx, pt_idx, page_offset)."""
        pml4_idx = (gpa >> 39) & 0x1FF
        pdpt_idx = (gpa >> 30) & 0x1FF
        pd_idx = (gpa >> 21) & 0x1FF
        pt_idx = (gpa >> 12) & 0x1FF
        offset = gpa & 0xFFF
        return pml4_idx, pdpt_idx, pd_idx, pt_idx, offset


class Thread:
    def __init__(self, thread_id: int, pinned_cpu: Optional[int] = None, is_vmx: bool = False, vmid: int = 0):
        self.id = thread_id
        self.pinned_cpu = pinned_cpu
        self.is_vmx = is_vmx
        self.vmid = vmid
        self.state = "RUNNABLE"
        self.cpu_cycles = 0
        self.exit_count = 0


class PerCoreVmxModel:
    """
    Reference oracle for SMP per-core VMX initialization, host stack, and scheduler core affinity.
    """

    def __init__(self, core_count: int = 2):
        self.core_count = core_count
        self.vmxon_enabled: Dict[int, bool] = {i: False for i in range(core_count)}
        self.vmxon_phys: Dict[int, Optional[int]] = {i: None for i in range(core_count)}
        self.host_stack_phys: Dict[int, Optional[int]] = {i: None for i in range(core_count)}
        self.tss_base: Dict[int, int] = {i: 0xFFFF_8000_0000_0000 + i * 0x1000 for i in range(core_count)}
        self.threads: List[Thread] = []
        self.registry_lock = threading.Lock()

    def init_core(self, cpu_id: int, vmxon_page: int, stack_page: int) -> None:
        if cpu_id >= self.core_count:
            raise ValueError(f"Core {cpu_id} exceeds core count {self.core_count}")
        self.vmxon_enabled[cpu_id] = True
        self.vmxon_phys[cpu_id] = vmxon_page
        self.host_stack_phys[cpu_id] = stack_page

    def can_schedule(self, thread: Thread, cpu_id: int) -> bool:
        """
        In Catenary OS scheduler:
        A thread is eligible for cpu_id if thread.pinned_cpu is None or thread.pinned_cpu == cpu_id.
        Furthermore, VMX threads require VMX to be initialized on that core.
        """
        if cpu_id >= self.core_count:
            return False
        if thread.pinned_cpu is not None and thread.pinned_cpu != cpu_id:
            return False
        if thread.is_vmx and not self.vmxon_enabled.get(cpu_id, False):
            return False
        return True

    def schedule(self, cpu_id: int) -> Optional[Thread]:
        """Select next runnable thread for cpu_id."""
        for t in self.threads:
            if t.state == "RUNNABLE" and self.can_schedule(t, cpu_id):
                return t
        return None


class VirtualUart16550Model:
    """
    Reference oracle for virtual 16550 UART state machine and dual-path output.
    Matches VmUartState from src/vmm/microvm_registry.zig:
    - 4096-byte circular TX buffer
    - 256-byte RX FIFO
    - Dual-path TX (memory buffer + COM1 prefix [vm<id>])
    """

    TX_BUF_SIZE = 4096
    RX_FIFO_SIZE = 256

    def __init__(self, vmid: int):
        self.vmid = vmid
        self.dll = 0x01
        self.dlm = 0x00
        self.ier = 0x00  # Bit 0 = RDA interrupt enable
        self.fcr = 0x00
        self.lcr = 0x03  # 8 bits, 1 stop bit, no parity
        self.mcr = 0x00
        self.scr = 0x00
        self.irq4_pending = False

        self.tx_buf = bytearray(self.TX_BUF_SIZE)
        self.tx_len = 0
        self.tx_head = 0

        self.rx_buf = bytearray(self.RX_FIFO_SIZE)
        self.rx_head = 0
        self.rx_tail = 0
        self.rx_count = 0

        self.com1_mirror: List[str] = []

    @property
    def lsr(self) -> int:
        """
        Line Status Register:
        Bit 0: Data Ready (DR)
        Bit 5: Transmitter Holding Register Empty (THRE)
        Bit 6: Transmitter Empty (TEMT)
        """
        val = 0x60  # THRE | TEMT
        if self.rx_count > 0:
            val |= 0x01  # DR
        return val

    @property
    def iir(self) -> int:
        """
        Interrupt Identification Register:
        Bit 0: 0 if interrupt pending, 1 if no interrupt pending
        Bits 3:1:
          010 = THRE (0x02)
          100 = Received Data Available (0x04)
        """
        if self.rx_count > 0 and (self.ier & 0x01):
            return 0x04  # RDA pending
        if self.irq4_pending:
            return 0x02  # THRE pending
        return 0x01  # No interrupt pending

    def write_tx_byte(self, char_byte: int) -> str:
        """
        Emulates guest write to THR (port 0x3F8).
        1. Appends to 4096 circular buffer.
        2. Generates dual-path COM1 output with [vm<id>] prefix.
        """
        # Circular buffer write
        self.tx_buf[self.tx_head] = char_byte & 0xFF
        self.tx_head = (self.tx_head + 1) % self.TX_BUF_SIZE
        if self.tx_len < self.TX_BUF_SIZE:
            self.tx_len += 1

        # Mirrored write
        char_str = chr(char_byte & 0xFF)
        mirrored = f"[vm{self.vmid}] {char_str}"
        self.com1_mirror.append(mirrored)
        return mirrored

    def write_tx_bytes(self, data: bytes) -> str:
        chars = []
        for b in data:
            chars.append(chr(b))
            self.tx_buf[self.tx_head] = b
            self.tx_head = (self.tx_head + 1) % self.TX_BUF_SIZE
            if self.tx_len < self.TX_BUF_SIZE:
                self.tx_len += 1
        full_str = "".join(chars)
        mirrored = f"[vm{self.vmid}] {full_str}"
        self.com1_mirror.append(mirrored)
        return mirrored

    def inject_rx_byte(self, char_byte: int) -> bool:
        """
        Emulates SYS_VM_CONSOLE_INJECT = 29.
        Pushes char into RX FIFO if space available. Sets IRQ4 if IER bit 0 is set.
        Returns True on success, False if FIFO is full.
        """
        if self.rx_count >= self.RX_FIFO_SIZE:
            return False  # Overflow drop / backpressure

        self.rx_buf[self.rx_head] = char_byte & 0xFF
        self.rx_head = (self.rx_head + 1) % self.RX_FIFO_SIZE
        self.rx_count += 1

        if self.ier & 0x01:
            self.irq4_pending = True
        return True

    def read_rx_byte(self) -> Optional[int]:
        """Emulates guest read from RBR (port 0x3F8)."""
        if self.rx_count == 0:
            return None
        val = self.rx_buf[self.rx_tail]
        self.rx_tail = (self.rx_tail + 1) % self.RX_FIFO_SIZE
        self.rx_count -= 1
        if self.rx_count == 0:
            self.irq4_pending = False
        return val

    def get_console_log(self, max_bytes: int = 4096) -> bytes:
        """
        Emulates SYS_GET_VM_CONSOLE_LOG = 28.
        Returns the linearized contents of the circular buffer up to max_bytes.
        """
        if self.tx_len == 0:
            return b""
        n = min(self.tx_len, max_bytes)
        out = bytearray(n)
        start_idx = (self.tx_head - self.tx_len + self.TX_BUF_SIZE) % self.TX_BUF_SIZE
        for i in range(n):
            out[i] = self.tx_buf[(start_idx + i) % self.TX_BUF_SIZE]
        return bytes(out)


class WindowdTuiModel:
    """
    Reference oracle for Ring-3 windowd TUI pane layout, console switching, and keyboard forwarding.
    """

    PANE_VM_FORM = 0
    PANE_VM_MANAGER = 1
    PANE_VARDE_SHELL = 2
    PANE_GUEST_CONSOLE = 3

    DMA_CONSOLE_SLOT = 3

    def __init__(self, running_vm_ids: Optional[List[int]] = None):
        self.focused_pane = self.PANE_VM_MANAGER
        self.running_vm_ids: List[int] = running_vm_ids or [1, 2]
        self.active_console_vm_id: int = self.running_vm_ids[0] if self.running_vm_ids else 1
        self.scroll_offset: int = 0
        self.injected_commands: List[Tuple[int, int]] = []  # List of (vmid, ascii_code)

    def handle_key(self, key_code: str, ascii_char: int = 0) -> str:
        """
        Handles hotkeys and character forwarding according to windowd contracts:
        - F6: Jump directly to guest console pane
        - F7: Switch to previous running MicroVM console
        - F8: Switch to next running MicroVM console
        - C / Enter in VM manager: Jump to selected VM console
        - PageUp / PageDown: Scrollback
        - Regular character while in guest_console: SYS_VM_CONSOLE_INJECT
        """
        key = key_code.lower()

        if key == "f6":
            self.focused_pane = self.PANE_GUEST_CONSOLE
            return f"focused guest_console (VM {self.active_console_vm_id})"

        elif key == "f7":
            if self.running_vm_ids:
                curr_idx = self.running_vm_ids.index(self.active_console_vm_id) if self.active_console_vm_id in self.running_vm_ids else 0
                new_idx = (curr_idx - 1) % len(self.running_vm_ids)
                self.active_console_vm_id = self.running_vm_ids[new_idx]
                self.focused_pane = self.PANE_GUEST_CONSOLE
            return f"[UI] Switched console to MicroVM #{self.active_console_vm_id}"

        elif key == "f8":
            if self.running_vm_ids:
                curr_idx = self.running_vm_ids.index(self.active_console_vm_id) if self.active_console_vm_id in self.running_vm_ids else 0
                new_idx = (curr_idx + 1) % len(self.running_vm_ids)
                self.active_console_vm_id = self.running_vm_ids[new_idx]
                self.focused_pane = self.PANE_GUEST_CONSOLE
            return f"[UI] Switched console to MicroVM #{self.active_console_vm_id}"

        elif (key in ("c", "ret", "enter")) and self.focused_pane == self.PANE_VM_MANAGER:
            self.focused_pane = self.PANE_GUEST_CONSOLE
            return f"[UI] Switched console to MicroVM #{self.active_console_vm_id}"

        elif key == "pageup":
            self.scroll_offset = max(0, self.scroll_offset - 10)
            return f"scroll_offset={self.scroll_offset}"

        elif key == "pagedown":
            self.scroll_offset = min(4000, self.scroll_offset + 10)
            return f"scroll_offset={self.scroll_offset}"

        elif self.focused_pane == self.PANE_GUEST_CONSOLE and ascii_char > 0:
            self.injected_commands.append((self.active_console_vm_id, ascii_char))
            return f"injected char 0x{ascii_char:02x} into VM {self.active_console_vm_id}"

        return "ignored"


class QemuHarnessModel:
    """
    Reference pattern matching and milestone assertion oracle matching test_qemu.sh.
    """

    @staticmethod
    def pattern_seen(pattern: str, text: str) -> bool:
        """
        Exact Python equivalent of Perl matcher from test_qemu.sh:
        my @chars = split //, $pattern;
        my $regex = join(q{\\.*}, map { quotemeta($_) } @chars);
        exit($text =~ /$regex/s ? 0 : 1);
        """
        escaped_chars = [re.escape(c) for c in pattern]
        regex = r"\.*".join(escaped_chars)
        return bool(re.search(regex, text, re.DOTALL))

    @staticmethod
    def assert_all_milestones(patterns: List[str], text: str) -> Tuple[bool, List[str]]:
        missing = []
        for p in patterns:
            if not p:
                continue
            if not QemuHarnessModel.pattern_seen(p, text):
                missing.append(p)
        return len(missing) == 0, missing
