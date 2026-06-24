/* Catch-all E-trap: a COP1 op not implemented in HW raises the Unimplemented-Op
 * FP exception (ExcCode 15, FCSR.Cause.E) so the OS soft-float emulator handles
 * it (instead of SIGILL).  Uses recip.s (MIPS IV, func 0x15) -- undecoded here.
 *   recip.s $f2,$f0 = 0x46000095
 * Self-contained (own vectors, no crt0); run under -c 0; prints 'P'.
 */
#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

    .section .except_vec, "ax"
    .org    0x180
_exc_handler:
    la      $k0, fpe_flag
    li      $k1, 1
    sw      $k1, 0($k0)
    mfc0    $k0, $13            /* Cause */
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f
    la      $k1, fpe_code
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
    la      $19, fpe_flag

    sw      $0, 0($19)
    .word   0x46000095          /* recip.s $f2,$f0 -- unimplemented COP1 */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    beq     $2, $0, fail        /* must trap */
    nop
    la      $4, fpe_code
    lw      $2, 0($4)
    li      $3, 15              /* FP exception */
    bne     $2, $3, fail
    nop
    cfc1    $20, $31            /* FCSR.Cause.E (bit 17) must be set */
    nop
    srl     $21, $20, 17
    andi    $21, $21, 1
    beq     $21, $0, fail
    nop

    li      $25, 0x50           /* 'P' */
    mtc0    $25, $7
    HALT
fail:
    li      $25, 0x46           /* 'F' */
    mtc0    $25, $7
    HALT

    .data
    .align  3
fpe_flag:   .word 0
fpe_code:   .word 0
