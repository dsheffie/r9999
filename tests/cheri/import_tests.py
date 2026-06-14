#!/usr/bin/env python3
"""import_tests.py -- copy a subset of CTSRD cheritest .s/.py into tests/cheri/
and build each into an n32 big-endian ELF32 the r9999 sim can run.

Two assembly styles are auto-detected:
  * inline-dump : test defines its own global `start` and ends with
                  `mtc0 _,$26` (dump) / `mtc0 _,$23` (halt).  Built with
                  -DENTRY_START -DINLINE_DUMP and crt0 `j start`.
  * BEGIN_TEST  : test defines `test` (via BEGIN_TEST) and returns; crt0 calls
                  test() then `finish` dumps+halts.  Built without those defines.

Usage:  python3 import_tests.py [category ...]   (default: alu branch mem cp0 tlb)
        python3 import_tests.py --skip-existing   (don't rebuild existing .o/.elf)
Skips CHERI/cap tests automatically (grep for c-cap ops).
"""
import os
import re
import shutil
import subprocess
import sys

THIS = os.path.dirname(os.path.abspath(__file__))
CHERISRC = "/tmp/cheritest/tests"
COMMON = os.path.join(THIS, "common")

CC = "mips-linux-gnu-gcc"
CFLAGS = ["-march=mips3", "-mabi=n32", "-EB", "-mno-abicalls", "-fno-pic",
          "-G", "0", "-nostdlib", "-Wall", "-I" + COMMON]
LD = "mips-linux-gnu-ld"
LDFLAGS = ["-m", "elf32btsmipn32", "-T", os.path.join(COMMON, "link_n32.ld"),
           "-nostdlib", "-G", "0", "-static"]

# Patterns that mark a test as CHERI/BERI/emulator-specific -> skip (r9999 does
# not model capabilities, the FPU, QEMU magic NOPs, or the BERI xkphys windows)
CHERI_RE = re.compile(
    r"\b(c[gs]et|cset|cfromptr|cincoffset|candperm|cjr|cjalr|ccall|cclear|"
    r"creadhwr|cwritehwr|clc|csc|cld|csd|cgetnull|cgetpcc|cbts|cbez|cbnz|"
    r"\$c\d|\$ddc|\$kcc|\$kdc|\$epcc|CFromInt|CGet|CSet|cap_from_label|"
    r"mtc2|mfc2|dmtc2|dmfc2|lwc1|swc1|ldc1|sdc1|mtc1|mfc1|cvt\.|add\.[sd]|"
    r"BUILDING_PURECAP)\b"
    r"|QEMU magic|magic nop|qemu_memset|xkphys", re.IGNORECASE)


def is_cheri(src):
    return bool(CHERI_RE.search(src))


def style(src):
    # inline if it defines its own `start` and uses mtc0 $26
    if re.search(r"mtc0\s+\$\w+,\s*\$26", src):
        return "inline"
    if re.search(r"\bBEGIN_TEST\b", src):
        return "begin_test"
    # default: treat like begin_test (define `test`) — but most non-cap tests are
    # one of the two; flag unknown.
    return "unknown"


def sh(cmd):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.returncode, r.stdout.decode("latin-1", "replace")


def build_crt0():
    # inline crt0 (j start) and begin_test crt0 (jal test; finish)
    rc, o = sh([CC] + CFLAGS + ["-DENTRY_START", "-x", "assembler-with-cpp",
                "-c", os.path.join(COMMON, "crt0.S"),
                "-o", os.path.join(COMMON, "crt0_inline.o")])
    if rc:
        print("crt0_inline FAILED\n" + o); sys.exit(1)
    rc, o = sh([CC] + CFLAGS + ["-x", "assembler-with-cpp",
                "-c", os.path.join(COMMON, "crt0.S"),
                "-o", os.path.join(COMMON, "crt0_test.o")])
    if rc:
        print("crt0_test FAILED\n" + o); sys.exit(1)
    rc, o = sh([CC] + CFLAGS + ["-x", "assembler-with-cpp",
                "-c", os.path.join(COMMON, "dump.s"),
                "-o", os.path.join(COMMON, "dump.o")])
    if rc:
        print("dump.o FAILED\n" + o); sys.exit(1)
    rc, o = sh([CC] + CFLAGS + ["-x", "assembler-with-cpp",
                "-c", os.path.join(COMMON, "lib.s"),
                "-o", os.path.join(COMMON, "lib.o")])
    if rc:
        print("lib.o FAILED\n" + o); sys.exit(1)


def build_test(cat, name, src):
    st = style(src)
    sdir = os.path.join(THIS, cat)
    os.makedirs(sdir, exist_ok=True)
    sfile = os.path.join(sdir, name + ".s")
    ofile = os.path.join(sdir, name + ".o")
    efile = os.path.join(sdir, name + ".elf")
    asflags = ["-Wa,-I" + COMMON, "-Wa,-I" + CHERISRC]
    if st == "inline":
        defs = ["-DENTRY_START", "-Wa,--defsym,INLINE_DUMP=1"]
        crt0 = os.path.join(COMMON, "crt0_inline.o")
    else:
        defs = []
        crt0 = os.path.join(COMMON, "crt0_test.o")
    rc, o = sh([CC] + CFLAGS + defs + asflags +
               ["-x", "assembler-with-cpp", "-c", sfile, "-o", ofile])
    if rc:
        return st, "ASM_FAIL", o
    rc, o = sh([LD] + LDFLAGS + [crt0, ofile, os.path.join(COMMON, "dump.o"),
                os.path.join(COMMON, "lib.o"), "-o", efile])
    if rc:
        return st, "LINK_FAIL", o
    return st, "OK", ""


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    cats = args if args else ["alu", "branch", "mem", "cp0", "tlb"]
    build_crt0()
    summary = {}
    for cat in cats:
        srcdir = os.path.join(CHERISRC, cat)
        if not os.path.isdir(srcdir):
            print("no such category:", cat); continue
        stats = {"imported": 0, "skip_cheri": 0, "asm_fail": 0, "link_fail": 0,
                 "unknown_style": 0}
        for f in sorted(os.listdir(srcdir)):
            if not f.endswith(".s"):
                continue
            name = f[:-2]
            pyf = os.path.join(srcdir, name + ".py")
            if not os.path.exists(pyf):
                continue
            with open(os.path.join(srcdir, f), "r", errors="replace") as fh:
                src = fh.read()
            if is_cheri(src):
                stats["skip_cheri"] += 1
                continue
            # skip tests whose .py needs the upstream BERITestBaseClasses infra
            with open(pyf, "r", errors="replace") as pfh:
                pysrc = pfh.read()
            if "beritest_baseclasses" in pysrc:
                stats.setdefault("skip_baseclass", 0)
                stats["skip_baseclass"] += 1
                continue
            # copy .s and .py into the dest category dir, then build
            os.makedirs(os.path.join(THIS, cat), exist_ok=True)
            shutil.copy(os.path.join(srcdir, f), os.path.join(THIS, cat, f))
            shutil.copy(pyf, os.path.join(THIS, cat, name + ".py"))
            st, status, log = build_test(cat, name, src)
            if status == "OK":
                stats["imported"] += 1
                if st == "unknown":
                    stats["unknown_style"] += 1
            elif status == "ASM_FAIL":
                stats["asm_fail"] += 1
                print("ASM_FAIL %s/%s (%s)\n%s" % (cat, name, st,
                      "\n".join(log.splitlines()[:8])))
            elif status == "LINK_FAIL":
                stats["link_fail"] += 1
                print("LINK_FAIL %s/%s (%s)\n%s" % (cat, name, st,
                      "\n".join(log.splitlines()[:8])))
        summary[cat] = stats
    print("\n=== import summary ===")
    for cat, s in summary.items():
        print("%-8s imported=%-3d skip_cheri=%-3d asm_fail=%-3d link_fail=%-3d unknown_style=%d"
              % (cat, s["imported"], s["skip_cheri"], s["asm_fail"],
                 s["link_fail"], s["unknown_style"]))


if __name__ == "__main__":
    main()
