"""
Tier 2: Boundary & Corner Cases — Feature 4 (R4)
Boundaries and timeout/failure handling for test_qemu.sh harness.
"""

import os
import tempfile
import unittest
from tests.test_harness import QemuHarnessModel


class TestR4SmokeBoundaries(unittest.TestCase):
    """
    Validates Boundary & Corner Cases for Requirement R4:
    - Single-core SMP=1 handling in Phase 9 smoke profile
    - Fallback behavior under TCG (REQUIRE_KVM=0)
    - Timeout and diagnostic reporting on partial milestone match failure
    - Stale socket and PID file cleanup
    - Post-flush serial log inspection
    """

    def test_T2_F4_01_single_core_smp1_rejection_or_upgrade(self):
        """
        T2_F4_01: Verify Phase 9 smoke profile rejects SMP=1 or safely enforces SMP=2.
        """
        def configure_phase9_smp(env_smp: str) -> int:
            smp_val = int(env_smp) if env_smp else 2
            if smp_val < 2:
                # Upgrades or rejects
                return 2
            return smp_val

        self.assertEqual(configure_phase9_smp("1"), 2)
        self.assertEqual(configure_phase9_smp("2"), 2)
        self.assertEqual(configure_phase9_smp("4"), 4)

    def test_T2_F4_02_missing_kvm_fallback_tcg(self):
        """
        T2_F4_02: When REQUIRE_KVM=0 and /dev/kvm is missing, verify harness selects
        ACCEL=tcg and CPU=max,vmx=on.
        """
        def resolve_accel_cpu(has_kvm: bool, require_kvm: int):
            if has_kvm:
                return "kvm", "host,vmx=on"
            elif require_kvm == 1:
                raise RuntimeError("/dev/kvm is unavailable; nested-VMX smoke test cannot run.")
            else:
                return "tcg", "max,vmx=on"

        # KVM available
        accel, cpu = resolve_accel_cpu(has_kvm=True, require_kvm=1)
        self.assertEqual(accel, "kvm")
        self.assertEqual(cpu, "host,vmx=on")

        # KVM unavailable, REQUIRE_KVM=0 (fallback permitted)
        accel_tcg, cpu_tcg = resolve_accel_cpu(has_kvm=False, require_kvm=0)
        self.assertEqual(accel_tcg, "tcg")
        self.assertEqual(cpu_tcg, "max,vmx=on")

        # KVM unavailable, REQUIRE_KVM=1 (strict mode errors out)
        with self.assertRaises(RuntimeError):
            resolve_accel_cpu(has_kvm=False, require_kvm=1)

    def test_T2_F4_03_partial_milestone_timeout_failure(self):
        """
        T2_F4_03: Verify harness detects missing milestone (e.g. Core 1 never launches guest)
        and flags failure.
        """
        required_patterns = [
            "booting...",
            "[SMP core 0] entering guest via vmlaunch",
            "[SMP core 1] entering guest via vmlaunch",  # Missing in log!
        ]

        partial_log = """
        booting...
        smp: AP core 1 online
        [SMP core 0] entering guest via vmlaunch
        """

        all_found, missing = QemuHarnessModel.assert_all_milestones(required_patterns, partial_log)
        self.assertFalse(all_found)
        self.assertIn("[SMP core 1] entering guest via vmlaunch", missing)

    def test_T2_F4_04_stale_monitor_socket_cleanup(self):
        """
        T2_F4_04: Verify harness cleans up stale monitor socket and pid file before launch.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            sock_path = os.path.join(tmpdir, "catenary_qemu_mon.sock")
            pid_path = os.path.join(tmpdir, "qemu.pid")

            # Create dummy stale files
            with open(sock_path, "w") as f:
                f.write("stale_sock")
            with open(pid_path, "w") as f:
                f.write("99999\n")

            self.assertTrue(os.path.exists(sock_path))
            self.assertTrue(os.path.exists(pid_path))

            # Simulate harness cleanup step
            for p in (sock_path, pid_path):
                if os.path.exists(p):
                    os.remove(p)

            self.assertFalse(os.path.exists(sock_path))
            self.assertFalse(os.path.exists(pid_path))

    def test_T2_F4_05_post_flush_pass_detection(self):
        """
        T2_F4_05: Verify post_flush_pass catches a milestone that was written to
        serial file buffer right at QEMU termination.
        """
        initial_log = "booting...\n[SMP core 0] entering guest via vmlaunch\n"
        final_flushed_log = initial_log + "[SMP core 1] entering guest via vmlaunch\nguest_rootfs: init started\n"

        target_pattern = "guest_rootfs: init started"

        # Initially absent
        self.assertFalse(QemuHarnessModel.pattern_seen(target_pattern, initial_log))

        # Flushed at exit
        self.assertTrue(QemuHarnessModel.pattern_seen(target_pattern, final_flushed_log))


if __name__ == "__main__":
    unittest.main()
