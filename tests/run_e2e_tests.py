#!/usr/bin/env python3
"""
Unified E2E Test Suite Runner for Catenary OS Phase 9.
Supports:
- Running all tiers (default)
- Running specific tiers (--tier 1, --tier 2, etc.)
- Verbose output (-v, --verbose)
- Formatted summary report with pass/fail counts
"""

import argparse
import os
import sys
import time
import unittest

# Ensure project root is in sys.path
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from tests.tier1_feature_coverage.test_r1_ept_vmcs import TestR1EptVmcs
from tests.tier1_feature_coverage.test_r2_smp_concurrency import TestR2SmpConcurrency
from tests.tier1_feature_coverage.test_r3_console_windowd import TestR3ConsoleWindowd
from tests.tier1_feature_coverage.test_r4_smoke_profile import TestR4SmokeProfile

from tests.tier2_boundaries.test_r1_ept_boundaries import TestR1EptBoundaries
from tests.tier2_boundaries.test_r2_smp_boundaries import TestR2SmpBoundaries
from tests.tier2_boundaries.test_r3_console_boundaries import TestR3ConsoleBoundaries
from tests.tier2_boundaries.test_r4_smoke_boundaries import TestR4SmokeBoundaries

from tests.tier3_combinations.test_pairwise_combinations import TestPairwiseCombinations

from tests.tier4_scenarios.test_real_world_scenarios import TestRealWorldScenarios

TIER_MAP = {
    1: [
        TestR1EptVmcs,
        TestR2SmpConcurrency,
        TestR3ConsoleWindowd,
        TestR4SmokeProfile,
    ],
    2: [
        TestR1EptBoundaries,
        TestR2SmpBoundaries,
        TestR3ConsoleBoundaries,
        TestR4SmokeBoundaries,
    ],
    3: [
        TestPairwiseCombinations,
    ],
    4: [
        TestRealWorldScenarios,
    ],
}


def build_suite(tier: int = None) -> unittest.TestSuite:
    suite = unittest.TestSuite()
    loader = unittest.TestLoader()

    tiers_to_load = [tier] if tier in TIER_MAP else [1, 2, 3, 4]

    for t in tiers_to_load:
        for test_class in TIER_MAP[t]:
            suite.addTests(loader.loadTestsFromTestCase(test_class))

    return suite


def main():
    parser = argparse.ArgumentParser(description="Run Catenary OS Phase 9 E2E Test Suite")
    parser.add_argument(
        "--tier",
        type=int,
        choices=[1, 2, 3, 4],
        help="Run only the specified test tier (1: Features, 2: Boundaries, 3: Pairs, 4: Scenarios)",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose test output",
    )
    args = parser.parse_args()

    print("=" * 72)
    print("  CATENARY OS — PHASE 9 E2E TEST SUITE RUNNER")
    print("  Scope: Multi-VCPU, SMP MicroVMs & Live Serial Console")
    print("=" * 72)
    if args.tier:
        print(f"[*] Executing Tier {args.tier} tests only")
    else:
        print("[*] Executing Full Suite (Tiers 1, 2, 3, 4)")
    print("-" * 72)

    suite = build_suite(args.tier)
    total_tests = suite.countTestCases()
    print(f"[*] Loaded {total_tests} test cases.")

    start_time = time.time()
    verbosity = 2 if args.verbose else 1
    runner = unittest.TextTestRunner(verbosity=verbosity)
    result = runner.run(suite)
    elapsed = time.time() - start_time

    print("-" * 72)
    print("  E2E TEST EXECUTION SUMMARY")
    print("-" * 72)
    print(f"  Total Tests:    {result.testsRun}")
    print(f"  Passed:         {result.testsRun - len(result.failures) - len(result.errors)}")
    print(f"  Failures:       {len(result.failures)}")
    print(f"  Errors:         {len(result.errors)}")
    print(f"  Elapsed Time:   {elapsed:.3f}s")
    print("=" * 72)

    if result.wasSuccessful():
        print("  RESULT: >>> ALL TESTS PASSED (100%) <<<")
        print("=" * 72)
        sys.exit(0)
    else:
        print("  RESULT: >>> TEST FAILURES DETECTED <<<")
        print("=" * 72)
        sys.exit(1)


if __name__ == "__main__":
    main()
