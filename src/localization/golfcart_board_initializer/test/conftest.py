"""Make the package importable without installing it.

The simulator lives inside the package rather than beside the tests, so the same
scene definitions drive both the offline test matrix and the live scene
publisher.
"""

import os
import sys

PACKAGE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

if PACKAGE_ROOT not in sys.path:
    sys.path.insert(0, PACKAGE_ROOT)
