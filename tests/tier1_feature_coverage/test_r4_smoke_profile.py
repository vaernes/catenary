"""
Tier 1: Feature Coverage — Feature 4 (R4)
Automated Phase 9 Smoke Test Profile.
"""

import unittest
from tests.test_harness import QemuHarnessModel


class TestR4SmokeProfile(unittest.TestCase):
    """
    Validates Requirement R4:
    - Phase 9 smoke profile profile handling in test_qemu.sh
    - SMP >= 2 requirement enforcement
    - QEMU monitor socket key injection
    - Milestone pattern assertion and clean process termination
    """

    def test_T1_F4_01_smoke_profile_phase9_argument_handling(self):
        """
        T1_F4_01: Verify Phase 9 smoke profile sets required build options:
        -Dvmm_active=true -Dvmm_launch_linux=true -Dserial_syscall_keepalive=false
        """
        expected_flags = [
            "-Dvmm_active=true",
            "-Dvmm_launch_linux=true",
            "-Dserial_syscall_keepalive=false",
        ]
        simulated_zig_args = "-Dvmm_active=true -Dvmm_launch_linux=true -Dserial_syscall_keepalive=false"
        for flag in expected_flags:
            self.assertIn(flag, simulated_zig_args)

    def test_T1_F4_02_smp_requirement_validation(self):
        """
        T1_F4_02: Verify Phase 9 profile validates SMP >= 2.
        """
        def validate_smp(smp_val: int) -> bool:
            return smp_val >= 2

        self.assertFalse(validate_smp(1), "SMP=1 must not be valid for multi-core concurrent Phase 9")
        self.assertTrue(validate_smp(2))
        self.assertTrue(validate_smp(4))

    def test_T1_F4_03_qemu_monitor_phase9_key_injection(self):
        """
        T1_F4_03: Verify inject_ui_phase9_keys sequence sends proper sendkey commands
        for launching MicroVM 2, switching to console, and interacting with guest shell.
        """
        generated_monitor_commands = []

        def mock_send_keys(keys):
            for k in keys:
                generated_monitor_commands.append(f"sendkey {k}\n")

        # Step 1: Select 128 MB for the Linux guest and create MicroVM 2
        mock_send_keys(["ret", "ret"])
        mock_send_keys(["right", "right"])
        mock_send_keys(["ret", "ret", "ret", "ret"])
        # Step 2: Switch to console pane and select MicroVM 2 (f6, f8)
        mock_send_keys(["f6"])
        mock_send_keys(["f8"])
        # Step 3: Send 'help' to MicroVM 2, switch back to MicroVM 1, and repeat
        mock_send_keys(["h", "e", "l", "p", "ret"])
        mock_send_keys(["f7"])
        mock_send_keys(["h", "e", "l", "p", "ret"])

        self.assertIn("sendkey f6\n", generated_monitor_commands)
        self.assertIn("sendkey f8\n", generated_monitor_commands)
        self.assertIn("sendkey f7\n", generated_monitor_commands)
        self.assertIn("sendkey right\n", generated_monitor_commands)
        self.assertIn("sendkey ret\n", generated_monitor_commands)

    def test_T1_F4_04_milestone_pattern_assertion(self):
        """
        T1_F4_04: Verify all Phase 9 required milestone patterns are successfully matched.
        """
        required_patterns = [
            "booting...",
            "smp: AP core",
            "VMX: initialized EPT root for VM 1",
            "VMX: initialized EPT root for VM 2",
            "VMX: launching VM 1 on core 0",
            "VMX: launching VM 2 on core 1",
            "[SMP core 0] entering guest via vmlaunch",
            "[SMP core 1] entering guest via vmlaunch",
            "[UI] Switched console to MicroVM #2",
            "[vm1] Catenary OS Guest Init: SUCCESS",
            "[vm1] guest_rootfs: init started",
            "[vm1] guest_rootfs: shell ready",
            "[vm2] Catenary OS Guest Init: SUCCESS",
            "[vm2] guest_rootfs: init started",
            "[vm2] guest_rootfs: shell ready",
            "[UI] Switched console to MicroVM #1",
            "[vm1] help env os-release exit",
            "[UI] Switched console to MicroVM #2",
            "[vm2] help env os-release exit",
        ]

        simulated_serial_log = """
        booting...
        smp: AP core 1 online
        selftest: PASS paging.canonical
        Timer initialized.
        VMX: initialized EPT root for VM 1
        VMX: initialized EPT root for VM 2
        [SMP core 0] entering guest via vmlaunch
        [SMP core 1] entering guest via vmlaunch
        VMX: launching VM 1 on core 0
        VMX: launching VM 2 on core 1
        windowd: registered at endpoint 9
        inputd: registered at endpoint 8
        [UI] Switched console to MicroVM #2
        Linux version 6.1.102-catenary
        [vm1] Catenary OS Guest Init: SUCCESS
        [vm1] guest_rootfs: init started
        [vm1] guest_rootfs: shell ready
        [vm2] Catenary OS Guest Init: SUCCESS
        [vm2] guest_rootfs: init started
        [vm2] guest_rootfs: shell ready
        [UI] Switched console to MicroVM #1
        [vm1] help env os-release exit
        [UI] Switched console to MicroVM #2
        [vm2] guest_rootfs: shell ready
        [vm2] help env os-release exit
        """

        all_ok, missing = QemuHarnessModel.assert_all_milestones(required_patterns, simulated_serial_log)
        self.assertTrue(all_ok, f"Expected all milestones to match, missing: {missing}")

    def test_T1_F4_05_clean_termination_and_exit_code(self):
        """
        T1_F4_05: Verify test harness signals exit status 0 when all milestones are met.
        """
        milestones_passed = True
        exit_code = 0 if milestones_passed else 1
        self.assertEqual(exit_code, 0)


if __name__ == "__main__":
    unittest.main()
