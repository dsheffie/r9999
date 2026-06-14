# cheritest subset integrated into the r9999 regression suite

CTSRD `cheritest` base-MIPS / TLB / exception tests, run unmodified (the `.s`
and `.py` are imported verbatim) against the r9999 R4000-class OOO core via a
small shim. CHERI capability, FPU, multicore, DMA, fuzz, and QEMU-magic tests
are skipped.

## How it works
- `common/macros.s` — r9999 replacement for cheritest's `macros.s`. Provides
  `BEGIN_TEST`/`END_TEST`, the counting trap handler, `init_tlb`, and overrides
  the `mtc0` mnemonic (inline-dump builds only) so cheritest's `mtc0 _,$26`
  (dump GPRs) / `mtc0 _,$23` (halt) retarget to our dump/`break`.
- `common/dump.s` — `__dump_print` prints every GPR as `R<dd>=<16 hex>\n` to the
  r9999 console (`mtc0 $rt,$7` putchar FIFO). `__putc` is a literal-encoded
  `mtc0 $4,$7` so the macro override does not recurse.
- `common/crt0.S` — startup. Sets 64-bit kernel mode (CU0|KX|SX|UX, BEV=0, no
  EXL/ERL), stack, sentinel GPR fill (matching cheritest init.s), then either
  `j start` (inline tests, `-DENTRY_START`) or `jalr test; finish` (BEGIN_TEST
  tests). BEV=0 vectors at 0x80000000 dispatch to the active trap handler.
- `common/lib.s` — stand-ins for the cheritest lib helpers the tests call
  (`bev_clear`, `bev0_handler_install`, `bzero`, `__trap_count`, ...).
  Exceptions dispatch through `jump_to_real_trap_handler` -> `__active_handler`.
- `beritest_tools.py` — `BaseBERITestCase`: runs `ooo_core` on the test's `.elf`,
  parses the `R<dd>=` dump into `self.MIPS.<regname>` (n64/o32 names), and
  implements `assertRegisterEqual` / `assertRegisterMaskEqual` / etc. Also
  provides `attr`/`HexInt`/`xfail_on`/`is_feature_supported` shims.

## ABI / ELF decisions (for review)
- cheritest `.s` use `.set mips64` and n64 register names (`$a4-$a7`, `$t4-$t9`)
  that the o32 assembler rejects. Built with **`-mabi=n32 -march=mips3 -EB`**,
  which accepts those names and still emits **ELF32 big-endian** that r9999's
  `load_elf` accepts (it only checks ELFCLASS32 + big-endian + e_machine=MIPS;
  it does NOT check the ABI flag).
- Linked with `ld -m elf32btsmipn32` and `OUTPUT_FORMAT("elf32-ntradbigmips")`
  (`common/link_n32.ld`); the o32 `elf32-tradbigmips` format rejects n32 objects.
- Tests run in **64-bit kernel mode** (crt0 sets KX) so `dadd`/`daddi`/`dsll`/
  `dmtc0`/etc. don't RI.
- `break` does NOT magic-halt r9999 (it takes a Breakpoint exception); tests run
  to `--maxcycle` after dumping. The dump completes first, so output is clean.

## Build & run
    make import          # build the alu/branch/mem/cp0/tlb subset
    make test            # run all
    make test-alu        # one category

## Known non-imported
- `_needs_baseclasses/` — tests importing `beritest_baseclasses`
  (`UnalignedLoadStoreTestCase` generators); they need the upstream BERI base-
  class machinery not ported here.
- See `import_tests.py` CHERI_RE for the skip patterns (cap ops, FPU, mtc2,
  QEMU magic NOPs, xkphys).

## Real core bugs surfaced
See `BUGS_FOUND.md` — two confirmed RTL bugs in the integer overflow path
(un-forwarded operands; SUB compares result to the wrong operand) and the
missing `BGEZALL`/`BLTZAL`/`BLTZALL` decodes.
