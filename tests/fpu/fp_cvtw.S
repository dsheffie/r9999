/* float->int32 with rounding: ROUND.W(RN,half-even) / CEIL.W(RP) / FLOOR.W(RM) /
 * CVT.W(FCSR.RM).  Co-sim (--checker) compares the mfc1 results; -c0 prints 'P'.
 *   2.5s=0x40200000 3.5s=0x40600000 2.25s=0x40100000 2.75s=0x40300000
 *   -2.25s=0xc0100000   2.5d=0x4004000000000000
 */
    .set mips3
    .set noreorder
    .set noat

    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

    .macro  CKW reg, val
    mfc1    $9, \reg
    nop
    li      $3, \val
    bne     $9, $3, fail
    nop
    .endm

    .text
    .globl main
    .type main,@function
main:
    /* ROUND.W (round to nearest, ties to even) */
    lui   $8, 0x4020          /* 2.5 */
    mtc1  $8, $f0
    nop
    nop
    round.w.s $f2, $f0        /* 2.5 -> 2 (even) */
    nop
    nop
    nop
    CKW   $f2, 2
    lui   $8, 0x4060          /* 3.5 */
    mtc1  $8, $f0
    nop
    nop
    round.w.s $f2, $f0        /* 3.5 -> 4 (even) */
    nop
    nop
    nop
    CKW   $f2, 4

    /* CEIL.W (toward +inf) */
    lui   $8, 0x4010          /* 2.25 */
    mtc1  $8, $f0
    nop
    nop
    ceil.w.s $f2, $f0         /* -> 3 */
    nop
    nop
    nop
    CKW   $f2, 3

    /* FLOOR.W (toward -inf) */
    lui   $8, 0x4030          /* 2.75 */
    mtc1  $8, $f0
    nop
    nop
    floor.w.s $f2, $f0        /* -> 2 */
    nop
    nop
    nop
    CKW   $f2, 2
    lui   $8, 0xc010          /* -2.25 */
    mtc1  $8, $f0
    nop
    nop
    floor.w.s $f2, $f0        /* -> -3 */
    nop
    nop
    nop
    CKW   $f2, -3

    /* CVT.W with FCSR.RM = RN (reset default) */
    lui   $8, 0x4020          /* 2.5 */
    mtc1  $8, $f0
    nop
    nop
    cvt.w.s $f2, $f0          /* RN -> 2 */
    nop
    nop
    nop
    CKW   $f2, 2

    /* double: ROUND.W.D of 2.5 -> 2 */
    la    $14, dbl
    ldc1  $f4, 0($14)
    nop
    nop
    round.w.d $f6, $f4        /* -> 2 */
    nop
    nop
    nop
    CKW   $f6, 2

    li    $25, 0x50           /* 'P' */
    mtc0  $25, $7
    HALT
fail:
    li    $25, 0x46           /* 'F' */
    mtc0  $25, $7
    HALT

    .data
    .align 3
dbl:  .dword 0x4004000000000000   /* 2.5 */
