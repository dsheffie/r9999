"""pytest conftest for the imported cheritest subset.

Ensures the tests/cheri directory (this directory) is on sys.path so the
per-category test_*.py modules can `import beritest_tools` regardless of which
subdirectory pytest is invoked from.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
