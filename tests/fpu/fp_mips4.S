/* MIPS IV ops under interp_mips --cpu r5000 vs the default R4400 (MIPS III).
 * Reads PRId: on an R5000 (imp 0x23) every op must execute with no exception and
 * the right result; otherwise movn/movz and the COP1X ops must raise RI (10) and
 * recip.d / movn.d must raise the FP Unimplemented exception (15).
 * madd/msub/nmadd/nmsub use a = 1+2^-30, c = -(1+2^-29): a*a = 1+2^-29+2^-60, so an
 * UNFUSED madd.d (product rounded first, as on the R5000) gives exactly 0 and a
 * fused one gives 2^-60.
 * Self-contained (own vectors, no crt0); prints 'P'/'F'.
 *   interp_mips --virt -f tests/fpu/fp_mips4.elf [--cpu r5000]
 */
#include "sim.h"

    .set    mips4
    .set    noreorder
    .set    noat

    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

    /* s0 = 1 on the R5000.  On it, expect no exception; else expect code \c. */
    .macro  EXPECT c
    lw      $2, 0($19)
    bne     $16, $0, 8f
    nop
    li      $3, \c
    bne     $2, $3, fail
    nop
    b       9f
    nop
8:  bne     $2, $0, fail
    nop
9:  sw      $0, 0($19)
    .endm

    .section .except_vec, "ax"
    .org    0x180
_exc_handler:
    mfc0    $k0, $13            /* Cause */
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f
    la      $k1, exc_code
    sw      $k0, 0($k1)
    mfc0    $k0, $14            /* EPC */
    addiu   $k0, $k0, 4
    mtc0    $k0, $14
    eret
    nop

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x24000000     /* Status: CU1=1, FR=1, BEV=0, kernel */
    mtc0    $t0, $12
    nop
    nop
    nop
    la      $19, exc_code
    sw      $0, 0($19)
    mfc0    $t0, $15            /* PRId */
    srl     $t0, $t0, 8
    andi    $t0, $t0, 0xff
    xori    $t0, $t0, 0x23
    sltiu   $16, $t0, 1         /* s0 = (imp == 0x23) */

    /* movn / movz */
    li      $8, 5
    li      $9, 7
    li      $10, 1
    movn    $8, $9, $10         /* t0 = 7 */
    EXPECT  10
    li      $11, 3
    movz    $11, $9, $0         /* t3 = 7 */
    EXPECT  10
    beq     $16, $0, 1f
    nop
    li      $3, 7
    bne     $8, $3, fail
    nop
    bne     $11, $3, fail
    nop
1:
    /* madd family: f0 = a, f2 = c */
    la      $20, dbl
    ldc1    $f0, 0($20)
    ldc1    $f2, 8($20)
    madd.d  $f4, $f2, $f0, $f0  /* a*a + c = 0 (unfused) */
    EXPECT  10
    msub.d  $f6, $f2, $f0, $f0  /* a*a - c = 2+2^-28 */
    EXPECT  10
    nmadd.d $f8, $f2, $f0, $f0  /* -(a*a + c) = -0.0 */
    EXPECT  10
    nmsub.d $f10, $f2, $f0, $f0 /* -(a*a - c) = -(2+2^-28) */
    EXPECT  10

    /* indexed FP loads/stores: sdxc1 f6 -> buf+8, ldxc1 back */
    la      $21, buf
    li      $22, 8
    sdxc1   $f6, $22($21)
    EXPECT  10
    ldxc1   $f12, $22($21)
    EXPECT  10
    li      $23, 0x3f800000     /* 1.0f */
    mtc1    $23, $f14
    li      $22, 16
    swxc1   $f14, $22($21)
    EXPECT  10
    lwxc1   $f16, $22($21)
    EXPECT  10
    prefx   0, $22($21)
    EXPECT  10

    /* recip.d 4.0 = 0.25; movn.d */
    ldc1    $f18, 16($20)
    recip.d $f20, $f18
    EXPECT  15
    movn.d  $f22, $f18, $10     /* f22 = 4.0 */
    EXPECT  15

    beq     $16, $0, pass       /* R4400: the traps were the test */
    nop
    sdc1    $f4, 0($21)
    sdc1    $f8, 24($21)
    sdc1    $f10, 32($21)
    sdc1    $f12, 40($21)
    sdc1    $f20, 48($21)
    sdc1    $f22, 56($21)
    mfc1    $24, $f16
    bne     $24, $23, fail
    nop
    la      $4, expect
    li      $5, 0
2:  addu    $6, $21, $5
    lw      $6, 0($6)
    addu    $7, $4, $5
    lw      $7, 0($7)
    bne     $6, $7, fail
    nop
    addiu   $5, $5, 4
    li      $6, 64
    bne     $5, $6, 2b
    nop
    lw      $6, 16($21)         /* swxc1 wrote 1.0f */
    bne     $6, $23, fail
    nop
pass:
    li      $25, 0x50           /* 'P' */
    mtc0    $25, $7
    HALT
fail:
    li      $25, 0x46           /* 'F' */
    mtc0    $25, $7
    HALT

    .data
    .align  3
exc_code:   .word 0, 0
dbl:        .word 0x3ff00000, 0x00400000    /* a = 1+2^-30 */
            .word 0xbff00000, 0x00800000    /* c = -(1+2^-29) */
            .word 0x40100000, 0x00000000    /* 4.0 */
buf:        .space 64
expect:     .word 0x00000000, 0x00000000    /* 0:  madd.d  = +0.0 */
            .word 0x40000000, 0x00800000    /* 8:  sdxc1 of msub.d = 2+2^-28 */
            .word 0x3f800000, 0x00000000    /* 16: swxc1 1.0f (low word untouched) */
            .word 0x80000000, 0x00000000    /* 24: nmadd.d = -0.0 */
            .word 0xc0000000, 0x00800000    /* 32: nmsub.d */
            .word 0x40000000, 0x00800000    /* 40: ldxc1 */
            .word 0x3fd00000, 0x00000000    /* 48: recip.d 4.0 = 0.25 */
            .word 0x40100000, 0x00000000    /* 56: movn.d = 4.0 */
