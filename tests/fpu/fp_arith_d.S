/* Double-precision ADD.D / SUB.D through the unified fpu_add (fmt=1 path).
 * Exact values (1.0 + 2.0 = 3.0, 2.0 - 1.0 = 1.0) so no rounding is involved.
 * Operands loaded with ldc1 and results stored with sdc1, then read back as
 * words for the co-sim GPR check.  Big-endian: the high-order word of a double
 * is at the lower address.
 *   1.0 = 0x3ff0000000000000   2.0 = 0x4000000000000000   3.0 = 0x4008000000000000
 */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    la    $14, dbl
    ldc1  $f0, 0($14)         /* 1.0 */
    ldc1  $f2, 8($14)         /* 2.0 */
    nop
    nop

    add.d $f4, $f0, $f2       /* 3.0 */
    sub.d $f6, $f2, $f0       /* 1.0 */
    nop
    nop
    nop
    nop

    sdc1  $f4, 16($14)        /* store 3.0 */
    sdc1  $f6, 24($14)        /* store 1.0 */
    nop
    nop

    lw    $8,  16($14)        /* hi(3.0) = 0x40080000 */
    lw    $9,  20($14)        /* lo(3.0) = 0x00000000 */
    lw    $10, 24($14)        /* hi(1.0) = 0x3ff00000 */
    lw    $11, 28($14)        /* lo(1.0) = 0x00000000 */
    nop

    lui   $13, 0x4008
    bne   $8, $13, fail
    nop
    bne   $9, $0, fail
    nop
    lui   $13, 0x3ff0
    bne   $10, $13, fail
    nop
    bne   $11, $0, fail
    nop

    /* C.LE.D: 1.0 <= 2.0 -> cc0=1 -> BC1T taken */
    c.le.d $f0, $f2
    nop
    nop
    nop
    nop
    bc1t  pass
    nop
    b     fail
    nop

pass:
    ori   $25, $0, 0x50       /* 'P' */
    mtc0  $25, $7
    break
fail:
    ori   $25, $0, 0x46       /* 'F' */
    mtc0  $25, $7
    break
    .size main,.-main

    .data
    .align 3
dbl:
    .word 0x3ff00000, 0x00000000    /* 1.0 (big-endian: hi word first) */
    .word 0x40000000, 0x00000000    /* 2.0 */
    .space 32                       /* result scratch (3.0, 1.0) */
