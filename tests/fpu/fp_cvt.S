/* FP convert test: TRUNC.W.S (f2i), CVT.S.W / CVT.D.W (i2f), plus an add.s
 * interleaved with a convert to exercise the shared FP writeback port + the
 * r_fp_wb_bitvec arbitration.  Exact values so the checker (_truncw/_cvts/_cvtd)
 * agrees.  Co-sim (--checker) compares the mfc1/lw GPR results.
 *   3.5s=0x40600000  3.0s=0x40400000  2.0s=0x40000000  5.0d=0x4014000000000000
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
    /* TRUNC.W.S: (int)3.5 = 3 */
    lui   $8, 0x4060          /* 3.5f */
    mtc1  $8, $f0
    nop
    nop
    trunc.w.s $f2, $f0
    nop
    nop
    nop
    nop
    mfc1  $9, $f2
    ori   $13, $0, 3
    bne   $9, $13, fail
    nop

    /* CVT.S.W: (float)3 = 3.0f */
    ori   $8, $0, 3
    mtc1  $8, $f4
    nop
    nop
    cvt.s.w $f6, $f4
    nop
    nop
    nop
    nop
    mfc1  $10, $f6
    lui   $13, 0x4040
    bne   $10, $13, fail
    nop

    /* add.s immediately followed by a convert -> both target bank0/complete_2;
     * 1.0+1.0=2.0, then (int)2.0=2 */
    lui   $8, 0x3f80         /* 1.0f */
    mtc1  $8, $f8
    add.s $f10, $f8, $f8     /* 2.0f */
    nop
    nop
    nop
    nop
    trunc.w.s $f12, $f10     /* (int)2.0 = 2 */
    nop
    nop
    nop
    nop
    mfc1  $11, $f12
    ori   $13, $0, 2
    bne   $11, $13, fail
    nop

    /* CVT.D.W: (double)5 = 5.0 -> store + read hi/lo */
    la    $14, scratch
    ori   $8, $0, 5
    mtc1  $8, $f14
    nop
    nop
    cvt.d.w $f16, $f14
    nop
    nop
    nop
    nop
    sdc1  $f16, 0($14)
    nop
    nop
    lw    $15, 0($14)        /* hi = 0x40140000 (big-endian) */
    lw    $16, 4($14)        /* lo = 0x00000000 */
    nop
    lui   $13, 0x4014
    bne   $15, $13, fail
    nop
    bne   $16, $0, fail
    nop

pass:
    ori   $25, $0, 0x50      /* 'P' */
    mtc0  $25, $7
    HALT
fail:
    ori   $25, $0, 0x46      /* 'F' */
    mtc0  $25, $7
    HALT
    .size main,.-main

    .data
    .align 3
scratch:
    .space 16
