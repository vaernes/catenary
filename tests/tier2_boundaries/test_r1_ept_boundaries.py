"""
Tier 2: Boundary & Corner Cases — Feature 1 (R1)
Boundaries and error handling for EPT and VMCS.
"""

import unittest
from tests.test_harness import EptRadixModel


class TestR1EptBoundaries(unittest.TestCase):
    """
    Validates Boundary & Corner Cases for Requirement R1:
    - GPA zero boundary
    - High-memory boundary (512 MiB limit)
    - Unmapped GPA fault handling (triggering EPT violation)
    - VMCS 4096-byte page alignment verification
    - Table modification isolation between instances
    """

    def setUp(self):
        self.ept = EptRadixModel()

    def test_T2_F1_01_ept_gpa_zero_page_boundary(self):
        """
        T2_F1_01: Verify translation of GPA 0x0000_0000 (page 0 boundary).
        Must map to valid HPA without NULL pointer misinterpretation.
        """
        root = self.ept.allocate_root()
        gpa_zero = 0x0000_0000
        target_hpa = 0x1000_0000

        self.ept.map_page(root, gpa_zero, target_hpa)
        resolved = self.ept.translate(root, gpa_zero)

        self.assertIsNotNone(resolved)
        self.assertEqual(resolved, target_hpa)

    def test_T2_F1_02_ept_high_memory_boundary(self):
        """
        T2_F1_02: Verify translation of GPA at maximum 512 MiB boundary:
        GPA = 512 MiB - 1 = 0x1FFF_FFFF.
        Offset = 0xFFF, Page base = 0x1FFF_F000.
        """
        root = self.ept.allocate_root()
        gpa_max = 0x1FFF_FFFF
        hpa_frame = 0x3000_0000

        self.ept.map_page(root, gpa_max & ~0xFFF, hpa_frame)
        resolved = self.ept.translate(root, gpa_max)

        self.assertEqual(resolved, hpa_frame | 0xFFF)

    def test_T2_F1_03_ept_unmapped_gpa_fault(self):
        """
        T2_F1_03: Verify translation of an unmapped GPA (e.g. 1 GiB: 0x4000_0000)
        returns None (which induces an EPT Violation VM-exit in hardware).
        """
        root = self.ept.allocate_root()
        # Map only low 64 MiB
        self.ept.map_huge_page(root, 0x0010_0000, 0x1000_0000)

        unmapped_gpa = 0x4000_0000
        resolved = self.ept.translate(root, unmapped_gpa)
        self.assertIsNone(resolved, "Unmapped GPA must return None to trigger EPT violation")

    def test_T2_F1_04_vmcs_page_alignment_enforcement(self):
        """
        T2_F1_04: Verify VMCS page address validator rejects non-4KB aligned physical addresses.
        Intel SDM: VMPTRLD requires 4KB-aligned physical address (bits 11:0 must be 0).
        """
        def validate_vmcs_address(phys_addr: int) -> bool:
            return (phys_addr & 0xFFF) == 0

        self.assertTrue(validate_vmcs_address(0x1000_0000))
        self.assertTrue(validate_vmcs_address(0x1000_1000))
        self.assertFalse(validate_vmcs_address(0x1000_0001))
        self.assertFalse(validate_vmcs_address(0x1000_0080))
        self.assertFalse(validate_vmcs_address(0x1000_0FFF))

    def test_T2_F1_05_ept_multi_instance_page_table_isolation(self):
        """
        T2_F1_05: Verify modifying page mappings in Instance 1's EPT radix tree
        does not alter the translation in Instance 2.
        """
        root1 = self.ept.allocate_root()
        root2 = self.ept.allocate_root()

        gpa = 0x0020_0000  # 2 MiB GPA
        self.ept.map_huge_page(root1, gpa, 0x2000_0000)
        self.ept.map_huge_page(root2, gpa, 0x3000_0000)

        # Update root1 mapping to a new HPA
        self.ept.map_huge_page(root1, gpa, 0x8000_0000)

        self.assertEqual(self.ept.translate(root1, gpa), 0x8000_0000)
        # Root2 must remain untouched
        self.assertEqual(self.ept.translate(root2, gpa), 0x3000_0000)


if __name__ == "__main__":
    unittest.main()
