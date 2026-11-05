"""
Empirical Challenge Test Suite for Milestone 1: SMP Concurrency, Core Affinity & Registry Synchronization
Author: Milestone 1 Challenger 2 (Empirical Challenger)
"""

import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from typing import Optional, Dict, List, Tuple


class SchedulerAffinityModel:
    """
    Direct model of Catenary OS scheduler candidate selection logic
    from src/kernel/scheduler.zig lines 615-636.
    """

    MAX_CPUS = 8
    THREAD_TARGET_COUNT = 64

    class ThreadState:
        EMPTY = 0
        READY = 1
        RUNNING = 2
        WAITING = 3

    class Thread:
        def __init__(
            self,
            tid: int,
            pinned_cpu: Optional[int] = None,
            sid: int = 0,
            is_vmx: bool = False,
            vmid: int = 0,
            state: int = 1,
        ):
            self.id = tid
            self.pinned_cpu = pinned_cpu
            self.sid = sid
            self.is_vmx = is_vmx
            self.vmid = vmid
            self.state = state
            self.active = False

    def __init__(self, num_cpus: int = 8):
        self.num_cpus = num_cpus
        self.threads: Dict[int, SchedulerAffinityModel.Thread] = {}
        self.current_thread_per_cpu: Dict[int, int] = {i: (self.THREAD_TARGET_COUNT - i if i > 0 else 0) for i in range(num_cpus)}
        self.lock = threading.Lock()

    def add_thread(self, thread: 'SchedulerAffinityModel.Thread') -> None:
        self.threads[thread.id] = thread

    def set_thread_affinity(self, tid: int, cpu_id: Optional[int]) -> bool:
        with self.lock:
            if tid in self.threads and self.threads[tid].state != self.ThreadState.EMPTY:
                self.threads[tid].pinned_cpu = cpu_id
                return True
            return False

    def can_candidate_run_on_core(self, thread: 'SchedulerAffinityModel.Thread', cpu_id: int) -> bool:
        """
        Implements lines 626-630 of src/kernel/scheduler.zig:
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

        return thread.state == self.ThreadState.READY and not thread.active

    def schedule_select(self, cpu_id: int) -> Optional['SchedulerAffinityModel.Thread']:
        with self.lock:
            for tid, t in sorted(self.threads.items()):
                if tid == 0:
                    continue  # Skip idle/BSP boot thread
                if self.can_candidate_run_on_core(t, cpu_id):
                    return t
            return None


class VmUartState:
    """Exact emulation of VmUartState from microvm_registry.zig."""
    def __init__(self):
        self.rx_buf = bytearray(256)
        self.rx_head = 0
        self.rx_tail = 0
        self.rx_count = 0
        self.irq4_pending = False
        self.tx_buf = bytearray(4096)
        self.tx_len = 0

    def write_tx_byte(self, ch: int):
        if self.tx_len < len(self.tx_buf):
            self.tx_buf[self.tx_len] = ch & 0xFF
            self.tx_len += 1
        else:
            # Scrollback slide
            self.tx_buf[0:-1] = self.tx_buf[1:]
            self.tx_buf[-1] = ch & 0xFF

    def write_tx_slice(self, data: bytes):
        for b in data:
            self.write_tx_byte(b)

    def read_tx_log(self, max_bytes: int) -> bytes:
        to_copy = min(self.tx_len, max_bytes)
        return bytes(self.tx_buf[0:to_copy])

    def inject_rx_byte(self, ch: int) -> bool:
        if self.rx_count >= 256:
            return False
        self.rx_buf[self.rx_tail] = ch & 0xFF
        self.rx_tail = (self.rx_tail + 1) % 256
        self.rx_count += 1
        self.irq4_pending = True
        return True

    def read_rx_byte(self) -> Optional[int]:
        if self.rx_count == 0:
            return None
        ch = self.rx_buf[self.rx_head]
        self.rx_head = (self.rx_head + 1) % 256
        self.rx_count -= 1
        if self.rx_count == 0:
            self.irq4_pending = False
        return ch


class VirtualDeviceState:
    """Exact emulation of VirtualDeviceState from microvm_registry.zig."""
    def __init__(self):
        self.master_imr = 0xFF
        self.slave_imr = 0xFF
        self.pit_channel0_reload = 0
        self.lapic_guest_apic_base = 0xFEE00900
        self.lapic_regs = [0] * 1024
        self.pci_config_address = 0
        self.uart = VmUartState()


class MicrovmRegistryModel:
    """
    Thread-safe model of microvm_registry.zig with spinlock and capacity constraints.
    """
    TARGET_INSTANCES = 8

    class Instance:
        def __init__(self, instance_id: int, pinned_cpu: Optional[int] = None):
            self.in_use = True
            self.instance_id = instance_id
            self.state = "created"
            self.pinned_cpu = pinned_cpu
            self.devices = VirtualDeviceState()

    def __init__(self):
        self.instances: List[Optional['MicrovmRegistryModel.Instance']] = [None] * self.TARGET_INSTANCES
        self.next_instance_id = 1
        self.lock = threading.Lock()
        self.lock_contention_counter = 0

    def create_with_affinity(self, pinned_cpu: Optional[int]) -> Optional[int]:
        with self.lock:
            self.lock_contention_counter += 1
            for i in range(len(self.instances)):
                if self.instances[i] is None or not self.instances[i].in_use:
                    vmid = self.next_instance_id
                    self.next_instance_id += 1
                    self.instances[i] = self.Instance(vmid, pinned_cpu)
                    return vmid
            return None

    def set_pinned_cpu(self, instance_id: int, pinned_cpu: Optional[int]) -> bool:
        with self.lock:
            self.lock_contention_counter += 1
            for inst in self.instances:
                if inst and inst.in_use and inst.instance_id == instance_id:
                    inst.pinned_cpu = pinned_cpu
                    return True
            return False

    def lookup(self, instance_id: int) -> Optional['MicrovmRegistryModel.Instance']:
        with self.lock:
            self.lock_contention_counter += 1
            for inst in self.instances:
                if inst and inst.in_use and inst.instance_id == instance_id:
                    return inst
            return None

    def start(self, instance_id: int) -> bool:
        with self.lock:
            self.lock_contention_counter += 1
            for inst in self.instances:
                if inst and inst.in_use and inst.instance_id == instance_id:
                    if inst.state in ("created", "stopped"):
                        inst.state = "running"
                        return True
            return False

    def stop(self, instance_id: int) -> bool:
        with self.lock:
            self.lock_contention_counter += 1
            for inst in self.instances:
                if inst and inst.in_use and inst.instance_id == instance_id:
                    if inst.state == "running":
                        inst.state = "stopped"
                        return True
            return False

    def delete(self, instance_id: int) -> bool:
        with self.lock:
            self.lock_contention_counter += 1
            for i in range(len(self.instances)):
                inst = self.instances[i]
                if inst and inst.in_use and inst.instance_id == instance_id:
                    if inst.state == "running":
                        return False
                    self.instances[i] = None
                    return True
            return False

    def get_console_log(self, instance_id: int, max_bytes: int = 4096) -> bytes:
        with self.lock:
            self.lock_contention_counter += 1
            for inst in self.instances:
                if inst and inst.in_use and inst.instance_id == instance_id:
                    return inst.devices.uart.read_tx_log(max_bytes)
            return b""

    def inject_console_input(self, instance_id: int, ch: int) -> bool:
        with self.lock:
            self.lock_contention_counter += 1
            for inst in self.instances:
                if inst and inst.in_use and inst.instance_id == instance_id:
                    return inst.devices.uart.inject_rx_byte(ch)
            return False


class TestEmpiricalM1SmpAffinity(unittest.TestCase):
    """
    Empirical tests explicitly challenging:
    1. Edge cases in thread affinity (core 0 on AP 1, core 1 on BSP, unpinned threads, invalid core IDs).
    2. Registry spinlock behavior and virtual device encapsulation under concurrent access.
    """

    def setUp(self):
        self.sched = SchedulerAffinityModel(num_cpus=8)
        self.reg = MicrovmRegistryModel()

    # =========================================================================
    # Edge Cases in Thread Affinity
    # =========================================================================

    def test_affinity_pinned_core0_on_ap1_strictly_rejected(self):
        """
        Challenge 1A: Thread pinned to core 0 evaluated on AP 1.
        Must be strictly rejected and never scheduled on AP 1.
        """
        t = SchedulerAffinityModel.Thread(tid=1, pinned_cpu=0, is_vmx=True, vmid=1)
        self.sched.add_thread(t)

        self.assertFalse(self.sched.can_candidate_run_on_core(t, cpu_id=1))
        self.assertIsNone(self.sched.schedule_select(cpu_id=1))

        # Must succeed on Core 0
        self.assertTrue(self.sched.can_candidate_run_on_core(t, cpu_id=0))
        self.assertEqual(self.sched.schedule_select(cpu_id=0), t)

    def test_affinity_pinned_core1_on_bsp_strictly_rejected(self):
        """
        Challenge 1B: Thread pinned to core 1 evaluated on BSP (Core 0).
        Must be strictly rejected and never scheduled on BSP.
        """
        t = SchedulerAffinityModel.Thread(tid=2, pinned_cpu=1, is_vmx=True, vmid=2)
        self.sched.add_thread(t)

        self.assertFalse(self.sched.can_candidate_run_on_core(t, cpu_id=0))
        self.assertIsNone(self.sched.schedule_select(cpu_id=0))

        # Must succeed on AP 1
        self.assertTrue(self.sched.can_candidate_run_on_core(t, cpu_id=1))
        self.assertEqual(self.sched.schedule_select(cpu_id=1), t)

    def test_affinity_unpinned_kernel_task_bsp_only(self):
        """
        Challenge 1C: Unpinned thread with sid == 0 (kernel maintenance task).
        Scheduler rule: AP cores (cpu_id != 0) do not run unpinned sid == 0.
        Must only run on BSP (cpu_id == 0).
        """
        t_kernel = SchedulerAffinityModel.Thread(tid=3, pinned_cpu=None, sid=0, is_vmx=False)
        self.sched.add_thread(t_kernel)

        self.assertTrue(self.sched.can_candidate_run_on_core(t_kernel, cpu_id=0))
        self.assertEqual(self.sched.schedule_select(cpu_id=0), t_kernel)

        # On any AP core (1..7), it must be skipped
        for ap_id in range(1, 8):
            self.assertFalse(self.sched.can_candidate_run_on_core(t_kernel, cpu_id=ap_id))
            self.assertIsNone(self.sched.schedule_select(cpu_id=ap_id))

    def test_affinity_unpinned_service_task_multi_core(self):
        """
        Challenge 1D: Unpinned thread with sid > 0 (Ring-3 service).
        Can be scheduled on both BSP (core 0) and AP cores (1..7).
        """
        t_service = SchedulerAffinityModel.Thread(tid=4, pinned_cpu=None, sid=10, is_vmx=False)
        self.sched.add_thread(t_service)

        for cpu_id in range(8):
            self.assertTrue(self.sched.can_candidate_run_on_core(t_service, cpu_id=cpu_id))
            self.assertEqual(self.sched.schedule_select(cpu_id=cpu_id), t_service)

    def test_affinity_invalid_core_ids_rejection(self):
        """
        Challenge 1E: Invalid core IDs (e.g. pinned_cpu = 8, 9, 255).
        Must be rejected on all valid system cores (0..7), preventing out-of-bounds dispatch.
        """
        for invalid_cpu in [8, 9, 16, 255]:
            t_invalid = SchedulerAffinityModel.Thread(tid=100 + invalid_cpu, pinned_cpu=invalid_cpu, is_vmx=True)
            self.sched.add_thread(t_invalid)

            for cpu_id in range(8):
                self.assertFalse(
                    self.sched.can_candidate_run_on_core(t_invalid, cpu_id=cpu_id),
                    f"Core {cpu_id} must not run thread pinned to invalid core {invalid_cpu}"
                )
            self.assertIsNone(self.sched.schedule_select(cpu_id=0))

    def test_dynamic_core_affinity_migration(self):
        """
        Challenge 1F: Dynamic migration via setThreadAffinity.
        Re-pinning from Core 0 to Core 1 immediately shifts eligibility.
        """
        t = SchedulerAffinityModel.Thread(tid=5, pinned_cpu=0, is_vmx=True, vmid=5)
        self.sched.add_thread(t)

        self.assertEqual(self.sched.schedule_select(0), t)
        self.assertIsNone(self.sched.schedule_select(1))

        # Re-pin to Core 1
        self.assertTrue(self.sched.set_thread_affinity(5, 1))
        self.assertIsNone(self.sched.schedule_select(0))
        self.assertEqual(self.sched.schedule_select(1), t)

        # Unpin thread
        self.assertTrue(self.sched.set_thread_affinity(5, None))
        self.assertEqual(self.sched.schedule_select(0), t)

    # =========================================================================
    # Registry Spinlock & Virtual Device Encapsulation Under Concurrency
    # =========================================================================

    def test_concurrent_registry_allocation_and_capacity_limit(self):
        """
        Challenge 2A: High-concurrency allocation race.
        Multiple threads attempt to allocate instances up to TARGET_INSTANCES (8).
        Verifies:
        - Exactly 8 instances allocated with unique IDs.
        - 9th+ attempts safely return None without data corruption.
        """
        allocated_ids = []
        lock = threading.Lock()

        def worker_create(worker_idx: int):
            vmid = self.reg.create_with_affinity(pinned_cpu=worker_idx % 8)
            if vmid is not None:
                with lock:
                    allocated_ids.append(vmid)

        with ThreadPoolExecutor(max_workers=16) as pool:
            futures = [pool.submit(worker_create, i) for i in range(32)]
            for f in futures:
                f.result()

        self.assertEqual(len(allocated_ids), 8, "Must strictly cap allocation at TARGET_INSTANCES=8")
        self.assertEqual(len(set(allocated_ids)), 8, "All allocated instance IDs must be unique")

    def test_virtual_device_encapsulation_under_concurrent_access(self):
        """
        Challenge 2B: Strict encapsulation of VirtualDeviceState under concurrent multi-core access.
        - Core 0 runs VM 1: writes to UART TX, sets PIC IMR 0xFE, sets LAPIC APIC base 0x11110000.
        - Core 1 runs VM 2: writes to UART TX, sets PIC IMR 0xFD, sets LAPIC APIC base 0x22220000.
        - UI thread reads console logs and injects RX keystrokes concurrently.
        Verifies:
        - 0% data leakage between VM 1 and VM 2 device states.
        - UART TX logs strictly separated.
        - UART RX FIFO strictly separated.
        """
        vm1_id = self.reg.create_with_affinity(pinned_cpu=0)
        vm2_id = self.reg.create_with_affinity(pinned_cpu=1)
        self.assertIsNotNone(vm1_id)
        self.assertIsNotNone(vm2_id)

        inst1 = self.reg.lookup(vm1_id)
        inst2 = self.reg.lookup(vm2_id)

        stop_signal = threading.Event()
        errors = []

        def core0_worker():
            for i in range(200):
                if stop_signal.is_set():
                    break
                inst1.devices.uart.write_tx_slice(f"[VM1-LINE-{i}]\n".encode())
                inst1.devices.master_imr = 0xFE
                inst1.devices.lapic_guest_apic_base = 0x11110000
                time.sleep(0.0001)

        def core1_worker():
            for i in range(200):
                if stop_signal.is_set():
                    break
                inst2.devices.uart.write_tx_slice(f"[VM2-LINE-{i}]\n".encode())
                inst2.devices.master_imr = 0xFD
                inst2.devices.lapic_guest_apic_base = 0x22220000
                time.sleep(0.0001)

        def ui_thread():
            for i in range(100):
                if stop_signal.is_set():
                    break
                # Concurrent read log
                log1 = self.reg.get_console_log(vm1_id)
                log2 = self.reg.get_console_log(vm2_id)

                if b"VM2" in log1:
                    errors.append("Crosstalk: VM2 data found in VM1 console log!")
                if b"VM1" in log2:
                    errors.append("Crosstalk: VM1 data found in VM2 console log!")

                # Concurrent RX injection
                self.reg.inject_console_input(vm1_id, ord('A'))
                self.reg.inject_console_input(vm2_id, ord('B'))
                time.sleep(0.0002)

        threads = [
            threading.Thread(target=core0_worker),
            threading.Thread(target=core1_worker),
            threading.Thread(target=ui_thread),
        ]

        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(len(errors), 0, f"Encapsulation violations detected: {errors}")

        # Final state verification
        self.assertEqual(inst1.devices.master_imr, 0xFE)
        self.assertEqual(inst2.devices.master_imr, 0xFD)
        self.assertEqual(inst1.devices.lapic_guest_apic_base, 0x11110000)
        self.assertEqual(inst2.devices.lapic_guest_apic_base, 0x22220000)

        # Verify RX separation
        vm1_rx = inst1.devices.uart.read_rx_byte()
        vm2_rx = inst2.devices.uart.read_rx_byte()
        self.assertEqual(vm1_rx, ord('A'))
        self.assertEqual(vm2_rx, ord('B'))

    def test_heavy_contention_spinlock_stress(self):
        """
        Challenge 2C: High contention on registry spinlock with rapid parallel operations.
        50 threads make 2,500 total mixed calls.
        Verifies mutual exclusion and absence of deadlocks.
        """
        vm_id = self.reg.create_with_affinity(pinned_cpu=0)
        self.assertIsNotNone(vm_id)

        operations_performed = [0]
        counter_lock = threading.Lock()

        def spam_worker(worker_id: int):
            for i in range(50):
                op = (worker_id + i) % 4
                if op == 0:
                    self.reg.lookup(vm_id)
                elif op == 1:
                    self.reg.set_pinned_cpu(vm_id, (worker_id + i) % 8)
                elif op == 2:
                    self.reg.inject_console_input(vm_id, ord('X'))
                elif op == 3:
                    self.reg.get_console_log(vm_id, 64)

                with counter_lock:
                    operations_performed[0] += 1

        workers = [threading.Thread(target=spam_worker, args=(w,)) for w in range(50)]
        for w in workers:
            w.start()
        for w in workers:
            w.join()

        self.assertEqual(operations_performed[0], 2500)
        self.assertGreaterEqual(self.reg.lock_contention_counter, 2500)


if __name__ == "__main__":
    unittest.main()
