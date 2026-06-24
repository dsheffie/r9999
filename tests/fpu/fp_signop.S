/* abs / neg / mov (.s and .d).  Single via mtc1/mfc1; double via ldc1/sdc1 +
 * memory (read back as words for the co-sim GPR check).  Co-sim (--checker) and
 * -c0 self-check both: prints 'P'.
 *   3.0s=0x40400000  -3.0s=0xc0400000  5.0s=0x40a00000
 *   -3.0d=0xc008000000000000  3.0d=0x4008000000000000  5.0d=0x4014000000000000
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
    /* ---- abs.s(-3.0) = 3.0 ---- */
    lui   $8, 0xc040          /* -3.0f */
    mtc1  $8, $f0
    nop
    nop
    abs.s $f2, $f0
    nop
    nop
    nop
    nop
    mfc1  $9, $f2
    lui   $13, 0x4040         /* 3.0f */
    bne   $9, $13, fail
    nop

    /* ---- neg.s(3.0) = -3.0 ---- */
    lui   $8, 0x4040          /* 3.0f */
    mtc1  $8, $f4
    nop
    nop
    neg.s $f6, $f4
    nop
    nop
    nop
    nop
    mfc1  $10, $f6
    lui   $13, 0xc040         /* -3.0f */
    bne   $10, $13, fail
    nop

    /* ---- mov.s(5.0) = 5.0 ---- */
    lui   $8, 0x40a0          /* 5.0f */
    mtc1  $8, $f8
    nop
    nop
    mov.s $f10, $f8
    nop
    nop
    nop
    nop
    mfc1  $11, $f10
    lui   $13, 0x40a0
    bne   $11, $13, fail
    nop

    /* ---- doubles: abs.d/neg.d/mov.d via ldc1/sdc1 ---- */
    la    $14, dbl
    ldc1  $f12, 0($14)        /* -3.0d (offset 0) */
    ldc1  $f14, 8($14)        /*  5.0d (offset 8) */
    nop
    nop
    abs.d $f16, $f12          /* 3.0d */
    neg.d $f18, $f16          /* -3.0d */
    mov.d $f20, $f14          /* 5.0d */
    nop
    nop
    nop
    nop
    sdc1  $f16, 16($14)       /* 3.0d  -> offset 16 */
    sdc1  $f18, 24($14)       /* -3.0d -> offset 24 */
    sdc1  $f20, 32($14)       /* 5.0d  -> offset 32 */
    nop
    nop

    lw    $8, 16($14)         /* hi(3.0d) = 0x40080000 */
    lui   $13, 0x4008
    bne   $8, $13, fail
    nop
    lw    $8, 24($14)         /* hi(-3.0d) = 0xc0080000 */
    lui   $13, 0xc008
    bne   $8, $13, fail
    nop
    lw    $8, 32($14)         /* hi(5.0d) = 0x40140000 */
    lui   $13, 0x4014
    bne   $8, $13, fail
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
dbl:
    .dword 0xc008000000000000  /* [0]  -3.0 */
    .dword 0x4014000000000000  /* [8]   5.0 */
    .dword 0                    /* [16] abs.d result */
    .dword 0                    /* [24] neg.d result */
    .dword 0                    /* [32] mov.d result */
