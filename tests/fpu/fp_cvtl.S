/* .L (64-bit) converts: TRUNC/CEIL.L.s (f2i->int64) and CVT.D.L/CVT.S.L
 * (int64->fp).  Co-sim (--checker) compares the sdc1/mfc1 results; -c0 -> 'P'.
 *   2.5s=0x40200000  5.0d=0x4008..no  5(int64)  5.0d=0x4014000000000000  5.0s=0x40a00000
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

    /* TRUNC.L.S of 2.5 -> int64 2 */
    lui   $8, 0x4020          /* 2.5 */
    mtc1  $8, $f0
    nop
    nop
    trunc.l.s $f2, $f0
    nop
    nop
    nop
    sdc1  $f2, 0($14)
    nop
    nop
    lw    $9, 0($14)          /* hi = 0 */
    bne   $9, $0, fail
    nop
    lw    $9, 4($14)          /* lo = 2 */
    li    $3, 2
    bne   $9, $3, fail
    nop

    /* CEIL.L.S of 2.5 -> int64 3 */
    ceil.l.s $f2, $f0
    nop
    nop
    nop
    sdc1  $f2, 0($14)
    nop
    nop
    lw    $9, 4($14)
    li    $3, 3
    bne   $9, $3, fail
    nop

    /* CVT.D.L: int64 5 -> 5.0d */
    ldc1  $f4, 8($14)         /* int64 5 */
    nop
    nop
    cvt.d.l $f6, $f4
    nop
    nop
    nop
    sdc1  $f6, 0($14)
    nop
    nop
    lw    $9, 0($14)          /* hi(5.0d) = 0x40140000 */
    lui   $13, 0x4014
    bne   $9, $13, fail
    nop

    /* CVT.S.L: int64 5 -> 5.0s */
    cvt.s.l $f8, $f4
    nop
    nop
    nop
    mfc1  $10, $f8           /* 5.0s = 0x40a00000 */
    lui   $13, 0x40a0
    bne   $10, $13, fail
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
scr:  .dword 0                    /* [0] scratch */
      .dword 5                    /* [8] int64 5 */
