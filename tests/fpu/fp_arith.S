/* FP ALU plumbing test: ADD.S / SUB.S / MUL.S + C.LT.S/BC1T, all with values
 * whose results are EXACT in single precision (no rounding) so this exercises
 * the FP issue queue / fpu / FCR / 2nd complete port plumbing independent of
 * IEEE rounding correctness.  Co-sim (--checker true) compares the GPRs that the
 * mfc1 results land in; self-check prints 'P' iff every result is as expected.
 *   1.0=0x3f800000  2.0=0x40000000  3.0=0x40400000
 * Even FP registers only (o32/assembler convention; identical under FR=0/FR=1).
 */
    .set mips3
    .set noreorder
    .set noat

    /* magic-halt: -c 0 (no-checker) runs stop on a write to kseg1 0xBFD00000 */
    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

    .text
    .globl main
    .type main,@function
main:
    lui   $8, 0x3f80          /* 1.0 */
    mtc1  $8, $f0
    lui   $9, 0x4000          /* 2.0 */
    mtc1  $9, $f2
    nop
    nop

    add.s $f4, $f0, $f2       /* 3.0 */
    sub.s $f6, $f2, $f0       /* 1.0 */
    mul.s $f8, $f0, $f2       /* 2.0 */
    nop
    nop
    nop
    nop

    mfc1  $10, $f4            /* expect 0x40400000 */
    mfc1  $11, $f6            /* expect 0x3f800000 */
    mfc1  $12, $f8            /* expect 0x40000000 */
    nop
    nop

    lui   $13, 0x4040
    bne   $10, $13, fail
    nop
    lui   $13, 0x3f80
    bne   $11, $13, fail
    nop
    lui   $13, 0x4000
    bne   $12, $13, fail
    nop

    /* compare + branch: 1.0 < 2.0 -> cc0=1 -> BC1T taken */
    c.lt.s $f0, $f2
    nop
    nop
    nop
    nop
    bc1t  cc_ok
    nop
    b     fail               /* not taken => FCR/compare wrong */
    nop
cc_ok:
    /* 2.0 < 1.0 is false -> BC1F taken */
    c.lt.s $f2, $f0
    nop
    nop
    nop
    nop
    bc1f  pass
    nop
    b     fail
    nop

pass:
    ori   $25, $0, 0x50       /* 'P' */
    mtc0  $25, $7
    HALT
fail:
    ori   $25, $0, 0x46       /* 'F' */
    mtc0  $25, $7
    HALT
    .size main,.-main
