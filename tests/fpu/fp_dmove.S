/* TDD test: dmtc1/dmfc1 -- 64-bit GPR<->FPR move (FR=1, full register).
 * Builds a 64-bit value with a non-zero HIGH word, round-trips it through an
 * FP register, and checks the full 64 bits survive (a 32-bit move would drop
 * the high word).  Runs in kernel mode so the 64-bit ops are valid.
 * Co-sim clean + prints 'P'.
 */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    /* $8 = 0x12345678_6abcdef0 (high word non-zero; low-word bit31 clear) */
    lui   $8, 0x1234
    ori   $8, $8, 0x5678
    dsll32 $8, $8, 0             /* $8 = 0x1234567800000000 */
    lui   $9, 0x6abc
    ori   $9, $9, 0xdef0         /* $9 = 0x000000006abcdef0 */
    or    $8, $8, $9             /* $8 = 0x123456786abcdef0 */

    dmtc1 $8, $f0                /* f0 <- $8  (full 64b) */
    nop
    nop
    dmfc1 $11, $f0               /* $11 <- f0 (full 64b) */
    nop
    bne   $8, $11, fail          /* full 64b must survive */
    nop

    /* contrast: mfc1 (32b) of the same reg must give the sign-extended low word */
    mfc1  $12, $f0               /* $12 = sign_extend32(0x6abcdef0) */
    nop
    lui   $13, 0x6abc
    ori   $13, $13, 0xdef0       /* $13 = 0x000000006abcdef0 (bit31 clear -> no sext) */
    bne   $12, $13, fail
    nop

    ori   $25, $0, 0x50          /* 'P' */
    mtc0  $25, $7
    break
fail:
    ori   $25, $0, 0x46          /* 'F' */
    mtc0  $25, $7
    break
    .size main,.-main
