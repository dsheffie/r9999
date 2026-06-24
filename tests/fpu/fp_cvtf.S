/* FP<->FP converts: CVT.D.S (widen, exact) and CVT.S.D (narrow, rounds).
 * Co-sim (--checker) compares the mfc1/lw GPR results; -c0 self-check prints 'P'.
 *   3.0s=0x40400000  3.0d=0x4008000000000000  2.5s=0x40200000
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

    .text
    .globl main
    .type main,@function
main:
    la    $14, scr

    /* CVT.D.S: 3.0s -> 3.0d */
    lui   $8, 0x4040          /* 3.0f */
    mtc1  $8, $f0
    nop
    nop
    cvt.d.s $f2, $f0
    nop
    nop
    nop
    nop
    sdc1  $f2, 0($14)
    nop
    nop
    lw    $9, 0($14)          /* hi(3.0d) = 0x40080000 */
    lui   $13, 0x4008
    bne   $9, $13, fail
    nop
    lw    $9, 4($14)          /* lo = 0 */
    bne   $9, $0, fail
    nop

    /* CVT.S.D: 3.0d -> 3.0s */
    ldc1  $f4, 8($14)         /* 3.0d const */
    nop
    nop
    cvt.s.d $f6, $f4
    nop
    nop
    nop
    nop
    mfc1  $10, $f6            /* 3.0f = 0x40400000 */
    lui   $13, 0x4040
    bne   $10, $13, fail
    nop

    /* roundtrip 2.5: s -> d -> s (exact both ways) */
    lui   $8, 0x4020          /* 2.5f */
    mtc1  $8, $f8
    nop
    nop
    cvt.d.s $f10, $f8
    nop
    nop
    nop
    nop
    cvt.s.d $f12, $f10
    nop
    nop
    nop
    nop
    mfc1  $11, $f12
    lui   $13, 0x4020
    bne   $11, $13, fail
    nop

    li    $25, 0x50           /* 'P' */
    mtc0  $25, $7
    HALT
fail:
    li    $25, 0x46           /* 'F' */
    mtc0  $25, $7
    HALT

    .data
    .align 3
scr:  .dword 0                    /* [0] sdc1 dest */
      .dword 0x4008000000000000   /* [8] 3.0d const */
