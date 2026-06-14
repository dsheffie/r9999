"""beritest_tools -- r9999 shim of the cheritest BaseBERITestCase.

Imported cheritest test_*.py files do `from beritest_tools import BaseBERITestCase`
and assert on self.MIPS.<regname>.  This module:

  * runs the assembled ELF on r9999's Verilator sim (ooo_core),
  * parses the "R<dd>=<16 hex>" register dump our macros shim prints, and
  * exposes the 32 GPRs under the n64/o32 register-name map as self.MIPS.

The ELF for a test class `test_foo` is expected at <category>/test_foo.elf relative
to this directory; the category is inferred from the test module's package dir.
"""

import os
import re
import subprocess
import unittest


# ---------------------------------------------------------------------------
# cheritest .py compatibility shims (decorators / helpers they import)
# ---------------------------------------------------------------------------
class HexInt(int):
    """cheritest uses HexInt for nicer failure formatting; plain int is fine."""
    def __repr__(self):
        return hex(self)


def attr(*a, **k):
    """No-op stand-in for nose's @attr tag decorator (used for test filtering in
    upstream; we run everything, so just return the decorated object)."""
    def deco(obj):
        return obj
    return deco


def xfail_on(*a, **k):
    """Upstream marks expected-fail on certain sim backends.  We don't model
    those backends, so treat as a no-op (the test still runs and reports)."""
    def deco(obj):
        return obj
    return deco


def is_feature_supported(*a, **k):
    """Upstream feature gate; r9999 has no feature DB, so report unsupported so
    feature-gated branches are skipped rather than spuriously asserted."""
    return False

# n64/n32 ABI register names -> GPR number (also accepts o32 names where they
# differ; cheritest .py uses the n64 names a4..a7,t4..t9).
REG_NAMES = {
    "zero": 0, "at": 1,
    "v0": 2, "v1": 3,
    "a0": 4, "a1": 5, "a2": 6, "a3": 7,
    "a4": 8, "a5": 9, "a6": 10, "a7": 11,   # n64: r8..r11 (== o32 t0..t3)
    "t0": 12, "t1": 13, "t2": 14, "t3": 15,  # n64: r12..r15 (== o32 t4..t7)
    "t4": 12, "t5": 13, "t6": 14, "t7": 15,  # o32 aliases for the same regs
    "s0": 16, "s1": 17, "s2": 18, "s3": 19,
    "s4": 20, "s5": 21, "s6": 22, "s7": 23,
    "t8": 24, "t9": 25,
    "k0": 26, "k1": 27,
    "gp": 28, "sp": 29, "fp": 30, "s8": 30, "ra": 31,
}

# Resolve ooo_core: tests/cheri/ -> tests/ -> repo root has ooo_core.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_ROOT = os.path.abspath(os.path.join(_THIS_DIR, "..", ".."))
OOO_CORE = os.environ.get("OOO_CORE", os.path.join(_REPO_ROOT, "ooo_core"))
MAXCYCLE = os.environ.get("CHERI_MAXCYCLE", "600000")

_R_LINE = re.compile(r"^R(\d{2})=([0-9a-fA-F]{16})\s*$")


class _Regs(object):
    """Holds 32 GPR values, addressable by ABI name (self.MIPS.a0, ...)."""
    def __init__(self, gpr):
        self._gpr = gpr  # list of 32 ints

    def __getattr__(self, name):
        if name in REG_NAMES:
            return self._gpr[REG_NAMES[name]]
        raise AttributeError(name)


def _run_elf(elf_path):
    """Run ooo_core on elf_path with the checker off; return parsed GPRs."""
    if not os.path.exists(elf_path):
        raise unittest.SkipTest("missing ELF (build failed?): %s" % elf_path)
    cmd = [OOO_CORE, "--file", elf_path, "-c", "0", "--maxcycle", MAXCYCLE]
    proc = subprocess.run(cmd, cwd=_REPO_ROOT, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=600)
    out = proc.stdout.decode("latin-1", "replace")
    gpr = [None] * 32
    for line in out.splitlines():
        m = _R_LINE.match(line)
        if m:
            gpr[int(m.group(1))] = int(m.group(2), 16)
    if any(v is None for v in gpr):
        missing = [i for i, v in enumerate(gpr) if v is None]
        raise AssertionError(
            "register dump incomplete (missing R%s).\n--- sim stdout tail ---\n%s"
            % (missing, "\n".join(out.splitlines()[-40:])))
    return _Regs(gpr)


class BaseBERITestCase(unittest.TestCase):
    # Tests that exercise traps and want the exception count / cause exposed can
    # override these; we leave them as plain GPR reads (the counting trap handler
    # leaves the count in $v0 and compressed cause in $k1).
    @classmethod
    def setUpClass(cls):
        # The .elf sits next to the test's .py (same basename, .elf extension).
        import sys
        modobj = sys.modules[cls.__module__]
        base = os.path.splitext(os.path.abspath(modobj.__file__))[0]
        cls.MIPS = _run_elf(base + ".elf")

    # ---- assertion helpers used by the imported .py files ----
    def assertRegisterEqual(self, first, second, msg=None):
        if first != second:
            raise self.failureException(
                (msg or "") + " (got 0x%016x, expected 0x%016x)" % (first, second))

    def assertRegisterNotEqual(self, first, second, msg=None):
        if first == second:
            raise self.failureException(
                (msg or "") + " (both 0x%016x)" % first)

    def assertRegisterMaskEqual(self, first, mask, second, msg=None):
        if (first & mask) != (second & mask):
            raise self.failureException(
                (msg or "") + " (got 0x%016x, expected 0x%016x under mask 0x%016x)"
                % (first, second, mask))

    def assertRegisterInRange(self, val, lo, hi, msg=None):
        if not (lo <= val <= hi):
            raise self.failureException(
                (msg or "") + " (0x%016x not in [0x%016x,0x%016x])" % (val, lo, hi))
