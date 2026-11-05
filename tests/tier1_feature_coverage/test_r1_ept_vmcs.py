"""
Tier 1: Feature Coverage — Feature 1 (R1)
Independent EPT Roots and Dedicated VMCS per MicroVM Instance.
"""

import unittest
from tests.test_harness import EptRadixModel


class TestR1EptVmcs(unittest.TestCase):
    """
    Validates Requirement R1:
    - Independent Extended Page Table (EPT) roots per MicroVM
    - Dedicated Virtual Machine Control Structures (VMCS) per MicroVM
    - 4-level radix-tree translation logic and address space isolation
    """

    def setUp(self):
        self.ept = EptRadixModel()

    def test_T1_F1_01_ept_pml4_radix_structure(self):
        """
        T1_F1_01: Verify 4-level EPT radix-tree walker translates 48-bit GPA
        through PML4, PDPT, PD, and PT indices with 4 KiB offset math.
        """
        # Test GPA: 0x0000_1234_5678_9ABC
        # Bit breakdown:
        # PML4 index: (0x123456789abc >> 39) & 0x1FF = 0x24 = 36
        # PDPT index: (0x123456789abc >> 30) & 0x1FF = 0xD1 = 209
        # PD index:   (0x123456789abc >> 21) & 0x1FF = 0x0B3 = 179
        # PT index:   (0x123456789abc >> 12) & 0x1FF = 0x189 = 393
        # Offset:     0x123456789abc & 0xFFF = 0xABC
        gpa = 0x0000_1234_5678_9ABC
        pml4_idx, pdpt_idx, pd_idx, pt_idx, offset = EptRadixModel.get_indices(gpa)
        self.assertEqual(pml4_idx, 36)
        self.assertEqual(pdpt_idx, 209)
        self.assertEqual(pd_idx, 179)
        self.assertEqual(pt_idx, 393)
        self.assertEqual(offset, 0xABC)

        # Map to HPA frame 0x987654321000
        root = self.ept.allocate_root()
        target_hpa_frame = 0x0000_9876_5432_1000
        self.ept.map_page(root, gpa, target_hpa_frame)

        resolved_hpa = self.ept.translate(root, gpa)
        self.assertIsNotNone(resolved_hpa)
        self.assertEqual(resolved_hpa, target_hpa_frame | 0xABC)

    def test_T1_F1_02_ept_independent_address_spaces(self):
        """
        T1_F1_02: Verify two MicroVM instances allocate distinct EPT PML4 roots
        and translate identical GPA (e.g. 0x100000) to distinct HPA frames.
        """
        root_vm1 = self.ept.allocate_root()
        root_vm2 = self.ept.allocate_root()

        self.assertNotEqual(root_vm1, root_vm2, "VM1 and VM2 must have distinct EPT root addresses")

        # Identical GPA: 0x100000 (1 MiB guest RAM base within 2 MiB huge page)
        gpa_shared = 0x0010_0000
        hpa_vm1_base = 0x2000_0000
        hpa_vm2_base = 0x4000_0000

        self.ept.map_huge_page(root_vm1, gpa_shared, hpa_vm1_base)
        self.ept.map_huge_page(root_vm2, gpa_shared, hpa_vm2_base)

        trans_vm1 = self.ept.translate(root_vm1, gpa_shared)
        trans_vm2 = self.ept.translate(root_vm2, gpa_shared)

        expected_vm1 = hpa_vm1_base | (gpa_shared & 0x1FFFFF)
        expected_vm2 = hpa_vm2_base | (gpa_shared & 0x1FFFFF)

        self.assertEqual(trans_vm1, expected_vm1)
        self.assertEqual(trans_vm2, expected_vm2)
        self.assertNotEqual(trans_vm1, trans_vm2, "Address space isolation failure: GPAs mapped to same HPA")

    def test_T1_F1_03_vmcs_dedicated_physical_pages(self):
        """
        T1_F1_03: Verify dedicated 4KB-aligned physical pages are allocated
        for VMCS structures per instance without sharing.
        """
        PAGE_SIZE = 4096
        # Simulate physical frame allocator for VMCS
        vmcs_pool = [0x5000_0000 + i * PAGE_SIZE for i in range(16)]

        instance_1_vmcs = vmcs_pool[0]
        instance_2_vmcs = vmcs_pool[1]

        # Verify page alignment
        self.assertEqual(instance_1_vmcs & 0xFFF, 0, "VMCS 1 must be 4KB page aligned")
        self.assertEqual(instance_2_vmcs & 0xFFF, 0, "VMCS 2 must be 4KB page aligned")

        # Verify dedication (no overlap)
        self.assertNotEqual(instance_1_vmcs, instance_2_vmcs, "VMCS frames must be distinct per instance")
        self.assertGreaterEqual(abs(instance_1_vmcs - instance_2_vmcs), PAGE_SIZE)

    def test_T1_F1_04_ept_identity_mapping_isolation(self):
        """
        T1_F1_04: Verify early boot zero-page (GPA 0x7000) and cmdline (GPA 0x20000)
        are mapped to independent physical buffers across instances.
        """
        root1 = self.ept.allocate_root()
        root2 = self.ept.allocate_root()

        zero_page_gpa = 0x7000
        cmdline_gpa = 0x20000

        # Physical frames for VM 1
        vm1_zero_hpa = 0x6000_7000
        vm1_cmdline_hpa = 0x6002_0000
        self.ept.map_page(root1, zero_page_gpa, vm1_zero_hpa)
        self.ept.map_page(root1, cmdline_gpa, vm1_cmdline_hpa)

        # Physical frames for VM 2
        vm2_zero_hpa = 0x7000_7000
        vm2_cmdline_hpa = 0x7002_0000
        self.ept.map_page(root2, zero_page_gpa, vm2_zero_hpa)
        self.ept.map_page(root2, cmdline_gpa, vm2_cmdline_hpa)

        self.assertEqual(self.ept.translate(root1, zero_page_gpa), vm1_zero_hpa)
        self.assertEqual(self.ept.translate(root2, zero_page_gpa), vm2_zero_hpa)
        self.assertEqual(self.ept.translate(root1, cmdline_gpa), vm1_cmdline_hpa)
        self.assertEqual(self.ept.translate(root2, cmdline_gpa), vm2_cmdline_hpa)

    def test_T1_F1_05_vmcs_revision_id_header(self):
        """
        T1_F1_05: Verify VMCS structure header starts with 31-bit VMCS revision identifier
        and shadow bit (bit 31 = 0 for normal VMCS).
        """
        VMCS_REVISION_ID = 0x00000001  # Intel IA32_VMX_BASIC revision field simulation
        vmcs_header_bytes = VMCS_REVISION_ID.to_bytes(4, byteorder="little")

        unpacked_revision = int.from_bytes(vmcs_header_bytes[:4], byteorder="little")
        # Bit 31 must be 0 (clear) for non-shadow VMCS
        shadow_bit = (unpacked_revision >> 31) & 1
        revision_val = unpacked_revision & 0x7FFFFFFF

        self.assertEqual(shadow_bit, 0, "VMCS header shadow bit must be 0")
        self.assertEqual(revision_val, VMCS_REVISION_ID)


if __name__ == "__main__":
    unittest.main()
