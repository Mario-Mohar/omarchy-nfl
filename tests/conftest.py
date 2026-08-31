"""Make bin/nflcommon.py importable.

bin/ holds executables without a .py suffix, so it is not a package and cannot
be imported normally. The module under test is the one file in there that is a
plain library.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "bin"))
