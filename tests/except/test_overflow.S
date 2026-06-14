/*
 * test_overflow.S -- ADD/ADDI/SUB signed-overflow detection (self-contained).
 *
 * Regression for two exec.sv bugs surfaced by the cheritest import:
 *   BUG1: overflow read the raw PRF (w_srcA/w_srcB) instead of the forwarded
 *         operands -> spurious Ov trap when an operand came from forwarding.
 *   BUG2: SUB overflow compared the result to B instead of A (the minuend).
 *
 * Checks: cases that CANNOT overflow take no trap and give the right result;
 * a case that MUST overflow does trap (cause 12).  Prints 'P' on success.
 * Halts via the magic-halt register.  Runs clean under the co-sim checker.
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

/* General exception handler at 0x80000180 (BEV=0): record cause, skip the
 * faulting instruction, return. */
    .section .except_vec, "ax"
    .org    0x180
_exc_handler:
    la      $k0, ov_flag
    li      $k1, 1
    sw      $k1, 0($k0)         /* ov_flag = 1 */
    mfc0    $k0, $13            /* Cause */
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f      /* ExcCode */
    la      $k1, ov_code
    sw      $k0, 0($k1)         /* ov_code = ExcCode */
    mfc0    $k0, $14            /* EPC */
    addiu   $k0, $k0, 4         /* skip the faulting insn */
    mtc0    $k0, $14
    eret
    nop

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00           /* Status: BEV=0, kernel, EXL=0, ERL=0, IE=0 */
    mtc0    $t0, $12
    nop
    nop
    nop
    la      $19, ov_flag        /* $19 = &ov_flag (handler uses k0/k1, not $19) */

    /* ---- BUG1: forwarded add, operands differ in sign -> cannot overflow ---- */
    sw      $0, 0($19)
    li      $12, 1
    li      $13, -2
    add     $14, $12, $13       /* forwarded; must NOT trap; = -1 */
    lw      $2, 0($19)
    bne     $2, $0, fail        /* flag set -> spurious trap */
    nop
    li      $3, -1
    bne     $14, $3, fail
    nop

    /* ---- BUG2: sub, operands spaced so forwarding is not in play ---- */
    sw      $0, 0($19)
    li      $12, -1
    ssnop
    ssnop
    ssnop
    li      $13, 1
    ssnop
    ssnop
    ssnop
    sub     $16, $12, $13       /* -1 - 1 = -2; must NOT trap */
    lw      $2, 0($19)
    bne     $2, $0, fail
    nop
    li      $3, -2
    bne     $16, $3, fail
    nop

    /* ---- BUG1 (immediate): addi forwarded, different signs ---- */
    sw      $0, 0($19)
    li      $12, 5
    addi    $17, $12, -10       /* 5 + (-10) = -5; must NOT trap */
    lw      $2, 0($19)
    bne     $2, $0, fail
    nop
    li      $3, -5
    bne     $17, $3, fail
    nop

    /* ---- confirm a REAL overflow still traps: INT_MAX + 1 ---- */
    sw      $0, 0($19)
    lui     $12, 0x7fff
    ori     $12, $12, 0xffff    /* 0x7fffffff = INT_MAX */
    li      $13, 1
    add     $18, $12, $13       /* MUST overflow */
    lw      $2, 0($19)
    beq     $2, $0, fail        /* flag NOT set -> overflow missed */
    nop
    la      $4, ov_code         /* and it must be ExcCode 12 (Ov) */
    lw      $2, 0($4)
    li      $3, 12
    bne     $2, $3, fail
    nop

    /* ---- daddi (64-bit add-immediate): non-overflow takes no trap ---- */
    sw      $0, 0($19)
    li      $12, 5
    daddi   $14, $12, 3         /* 5 + 3 = 8; must NOT trap */
    lw      $2, 0($19)
    bne     $2, $0, fail
    nop
    li      $3, 8
    bne     $14, $3, fail
    nop

    /* ---- daddi 64-bit overflow MUST trap (cause 12): 0x7fff..ff + 1 ---- */
    sw      $0, 0($19)
    li      $12, -1             /* 0xffffffffffffffff */
    dsrl    $12, $12, 1         /* 0x7fffffffffffffff = INT64_MAX */
    daddi   $15, $12, 1         /* MUST overflow */
    lw      $2, 0($19)
    beq     $2, $0, fail        /* flag NOT set -> overflow missed */
    nop
    la      $4, ov_code
    lw      $2, 0($4)
    li      $3, 12
    bne     $2, $3, fail
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
ov_flag:    .word 0
ov_code:    .word 0
