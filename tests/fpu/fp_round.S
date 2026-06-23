/* FCSR.RM plumbing test (SELF-CHECK only, run with -c 0).
 *
 * The co-sim checker computes FP in host round-to-nearest and ignores FCSR.RM,
 * so this CANNOT be run under --checker for the non-RN cases -- it self-checks
 * against hand-computed expected values instead.
 *
 * 1.0 + 2^-24 is an exact-halfway single-precision add (guard=1, round=sticky=0,
 * lsb=0):
 *   RN (round-to-nearest-even): -> 1.0        = 0x3f800000  (ties to even)
 *   RP (toward +inf):           -> 1.0+ulp    = 0x3f800001
 *   RZ (toward zero):           -> 1.0        = 0x3f800000
 * Distinguishing RP from RN proves FCSR.RM reaches the rounder.
 *   1.0 = 0x3f800000   2^-24 = 0x33800000
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
    lui   $9, 0x3f80          /* 1.0 */
    mtc1  $9, $f0
    lui   $10, 0x3380         /* 2^-24 */
    mtc1  $10, $f2
    nop
    nop

    /* --- RN: ties-to-even -> 0x3f800000 --- */
    ori   $8, $0, 0
    ctc1  $8, $31             /* FCSR.RM = 0 (RN) */
    nop
    add.s $f4, $f0, $f2
    nop
    nop
    nop
    nop
    mfc1  $11, $f4
    lui   $13, 0x3f80
    bne   $11, $13, fail
    nop

    /* --- RP: toward +inf -> 0x3f800001 --- */
    ori   $8, $0, 2
    ctc1  $8, $31             /* FCSR.RM = 2 (RP) */
    nop
    add.s $f6, $f0, $f2
    nop
    nop
    nop
    nop
    mfc1  $12, $f6
    lui   $13, 0x3f80
    ori   $13, $13, 0x0001    /* 0x3f800001 */
    bne   $12, $13, fail
    nop

    /* --- RZ: toward zero -> 0x3f800000 --- */
    ori   $8, $0, 1
    ctc1  $8, $31             /* FCSR.RM = 1 (RZ) */
    nop
    add.s $f8, $f0, $f2
    nop
    nop
    nop
    nop
    mfc1  $14, $f8
    lui   $13, 0x3f80
    bne   $14, $13, fail
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
