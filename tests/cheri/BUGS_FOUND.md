# Real r9999 core bugs surfaced by the cheritest integration

These are category-(a) findings: genuine RTL bugs in the r9999 integer ALU
overflow path, reproduced in isolation. NOT fixed here (would require a Verilator
rebuild); reported for human review.

File: exec.sv  (lines as of branch `main` / worktree r9999-cheri)

## BUG 1 — ADD/SUB overflow detection reads UN-forwarded operands

    1209  csa ... .a(t_srcA[31:0]), .b(... t_srcB[31:0] ...)   // ALU uses t_srcA/t_srcB (forwarded)
    1216  wire [31:0] w_add32 = w_add_srcA + w_add_srcB;        // result from t_srcA/t_srcB
    1217  wire w_add32_overflow = (w_add32[31] != w_srcB[31]) & (w_srcA[31] == w_srcB[31]);
    1218  wire w_sub32_overflow = (w_add32[31] != w_srcB[31]) & (w_srcA[31] != w_srcB[31]);

The result `w_add32` is computed from the *forwarded* operands `t_srcA`/`t_srcB`,
but the overflow predicate compares it against `w_srcA`/`w_srcB`, which are the
RAW physical-register-file read ports (exec.sv:2212-2213, `.rd0(w_srcA)`,
`.rd1(w_srcB)`) — i.e. the value BEFORE same-cycle forwarding. When an operand is
produced by an immediately-preceding instruction (forwarded, not yet written to
the PRF), `w_srcA`/`w_srcB` hold the STALE value and the overflow comparison is
garbage -> spurious Arithmetic Overflow exception (cause 12).

Same defect in the 64-bit path:
    1235  w_add64_overflow = (w_add64[63] != w_srcB[63]) & (w_srcA[63] == w_srcB[63]);
    1236  w_sub64_overflow = (w_add64[63] != w_srcB[63]) & (w_srcA[63] != w_srcB[63]);

Reproducer (KX=1 kernel mode):
    li $12, 1
    li $13, -2
    add $14, $12, $13      # 1 + -2 = -1, different signs -> can NEVER overflow
                           # OBSERVED: takes overflow exception (EXL=1)
Spacing the operands away from the add with several ssnops (so they come from the
PRF, not forwarding) makes the spurious trap disappear -> confirms the forwarding
origin.

Likely fix: the overflow predicates must use the forwarded operands `t_srcA`/
`t_srcB` (same source the adder uses), not `w_srcA`/`w_srcB`.

## BUG 2 — SUB overflow formula compares result to the wrong operand

    1218  w_sub32_overflow = (w_add32[31] != w_srcB[31]) & (w_srcA[31] != w_srcB[31]);
    1236  w_sub64_overflow = (w_add64[63] != w_srcB[63]) & (w_srcA[63] != w_srcB[63]);

For A - B, signed subtraction overflows iff the operands differ in sign AND the
result's sign differs from the MINUEND A:
    overflow = (A[msb] != B[msb]) & (result[msb] != A[msb])
The code's first term is `(result[msb] != B[msb])` — it compares the result to B
instead of A. Wrong even with correctly-forwarded operands.

Reproducer (operands spaced so forwarding is not the cause):
    li $12, -1
    ... (ssnops) ...
    li $13, 1
    ... (ssnops) ...
    sub $14, $12, $13     # -1 - 1 = -2, valid 32-bit -> must NOT overflow
                          # OBSERVED with the formula above: false overflow
Worked example for `-1 - 1`:
    A=0xff..(msb 1), B=1(msb 0), result=-2(msb 1)
    correct: (A!=B)=1 & (result!=A)=(1!=1)=0  -> 0  (no overflow) ✓
    buggy:   (result!=B)=(1!=0)=1 & (A!=B)=1  -> 1  (false overflow) ✗

Likely fix: first term should be `(w_add32[31] != w_srcA[31])` (and the 64-bit
analog `(w_add64[63] != w_srcA[63])`), using the forwarded `t_srcA` per BUG 1.

## BUG 3 — REGIMM branch-and-link variants not decoded (BGEZALL/BLTZAL/BLTZALL)

decode_mips.sv REGIMM (opcode 0) decodes rt = BLTZ(0), BGEZ(1), BLTZL(2),
BGEZL(3), BGEZAL(17) but `default: II` for everything else. So:
  - BLTZAL  (rt=16) -> II
  - BLTZALL (rt=18) -> II
  - BGEZALL (rt=19) -> II
These are valid MIPS-III. BGEZAL is implemented; its siblings are not. Tests
`branch/test_raw_bgezall_*`, `test_raw_bltzal_*`, `test_raw_bltzall_*` hit this
(the unimplemented opcode RIs -> exception -> test diverges, no dump).
Classification: (a)/(c) depending on whether r9999 intends to support the
branch-likely-and-link family; BGEZAL support suggests the others are an
oversight.

## BUG 4 — incomplete MIPS trap-instruction decode (TGE/TGEU/TLT/TLTU + all trap-immediates)

decode_mips.sv decodes only TEQ (SPECIAL fn 0x34) and TNE (0x36) of the
register-form traps, and NONE of the REGIMM trap-immediate forms:
  - register form MISSING: TGE(0x30), TGEU(0x31), TLT(0x32), TLTU(0x33)
  - REGIMM rt MISSING:    TGEI(8), TGEIU(9), TLTI(10), TLTIU(11), TEQI(12), TNEI(14)
    (REGIMM only handles rt 0,1,2,3,17 -> everything else II)
These are MIPS-II / MIPS-III instructions. The undecoded ones RI (cause 10) ->
the test diverges and never dumps.

PROOF the trap path itself is correct (so these are decode gaps, not handler
bugs): every TEQ/TNE test (decoded forms) PASSES end-to-end through our trap
handler + EPC + ERET + register dump:
  test_teq_eq/gt/lt, test_tne_eq/gt/lt  -> PASS
  test_teqi_*, test_tnei_*, test_tge*, test_tlt*, test_tgei*, test_tlti* -> ERROR (II)
Classification: (a) if r9999 intends full MIPS-III trap support; TEQ/TNE present
strongly implies the rest are an oversight.

## NOTE — SPECIAL2 ops are MIPS32, not MIPS-III (category (c), not a bug)

r9999 has no SPECIAL2 (opcode 0x1c) decode, so `mul`, `madd`, `maddu`, `msub`,
`msubu` (and `dext`/`dins` MIPS64r2) are unimplemented and RI. These are
MIPS32/MIPS64r2 instructions, NOT part of MIPS-III (R4000); cheritest targets a
BERI/MIPS32-class core. Affected tests (test_mul*, test_madd*, test_msub*,
test_maddu*, test_msubu*, test_x_dext_ri) should be treated as (c) / skipped, not
core bugs. The importer skip filter could be extended with `\bmul\b|\bmadd|`
`\bmsub|\bmaddu|\bmsubu|\bdext|\bdins` if you want them auto-excluded.

## Tests that surface these (all category-(a) failures)
alu: test_raw_add, test_raw_addi, test_raw_addiu, test_raw_dadd, test_raw_daddi,
     test_raw_sub, test_raw_dsub, test_raw_sub_ex, test_raw_arithmetic_combo
(any "raw" trapping-arithmetic test whose body packs add/sub with forwarded
operands, or whose sub result-vs-minuend sign distinguishes the formula).

Reproducer source kept at: tests/cheri/bug_overflow_repro.s
