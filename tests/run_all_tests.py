#!/usr/bin/env python3
import os
import sys
import unittest

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

def run_tests():
    print("======================================================================")
    print("           PipeSync System Test & Verification Suite                  ")
    print("======================================================================")
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    tests_dir = os.path.join(BASE_DIR, "tests")
    suite.addTests(loader.discover(tests_dir, pattern="test_*.py"))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    print("======================================================================")
    if result.wasSuccessful():
        print("ALL TESTS PASSED! PipeSync architecture and 2PC verified successfully.")
        return 0
    else:
        print(f"TESTS FAILED: {len(result.failures)} failures, {len(result.errors)} errors.")
        return 1

if __name__ == "__main__":
    sys.exit(run_tests())
