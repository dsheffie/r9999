/*
 * test_nested_epc.S -- a NESTED exception (EXL already 1) must NOT overwrite EPC.
 *
 * R4000: EPC (and Cause.BD) update only when Status.EXL==0.  IRIX's self-mapped
 * page-table refill relies on this: a TLB miss taken inside the refill handler
 * (EXL=1) must leave EPC = the original access so its ERET retries it.
 *
 * Sequence:
 *   1. BEV=0 kernel, EXL=0.  `syscall` at PC_A -> EPC=PC_A, EXL=1, enter handler.
 *   2. Handler (1st entry): save EPC (PC_A), then `syscall` again (PC_H) while
 *      EXL=1 -> NESTED exception, re-enter handler.
 *   3. Handler (2nd/nested entry): EPC must still be PC_A (preserved).  Compare to
 *      the saved value: 'P' if equal (fix works), 'F' if it became PC_H (bug).
 *      Redirect EPC to `done` and ERET out.
 *
 * Expected console: P
 * Self-contained: own vectors (no crt0), halts via the magic-halt register.
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

/* ---- general exception handler at 0x80000180 (BEV=0) ---- */
    .section .except_vec, "ax"
    .org    0x180
    .globl  _vec_gen
_vec_gen:
    la      $k0, ncount
    lw      $k1, 0($k0)
    addiu   $k1, $k1, 1
    sw      $k1, 0($k0)
    li      $k0, 2
    beq     $k1, $k0, _nested      /* 2nd entry == the nested one */
    nop

    /* ---- 1st entry: save EPC (=PC_A), then cause a nested exception ---- */
    mfc0    $k0, $14               /* EPC = PC_A */
    la      $k1, saved_epc
    sw      $k0, 0($k1)
    syscall                        /* nested exception at PC_H, EXL still 1 */
    nop

_nested:
    /* ---- 2nd (nested) entry: EPC must still be PC_A ---- */
    mfc0    $k0, $14               /* current EPC */
    la      $k1, saved_epc
    lw      $k1, 0($k1)            /* saved PC_A */
    beq     $k0, $k1, _pass        /* preserved? */
    nop
    SIMCON_PUTLIT('F')             /* EPC clobbered by the nested exception */
    b       _recover
    nop
_pass:
    SIMCON_PUTLIT('P')             /* EPC survived the nested exception */
_recover:
    la      $k0, done              /* redirect EPC out of the loop and ERET */
    mtc0    $k0, $14
    eret
    nop

/* ---- reset entry ---- */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00              /* BEV=0, kernel, EXL=0, ERL=0 */
    mtc0    $t0, $12
    nop
    nop
    nop
    syscall                        /* PC_A: general exception -> handler */
    nop
done:
    SIMCON_PUTLIT('\n')
    HALT
    .size   _start, . - _start

    .data
    .align  2
ncount:    .word 0
saved_epc: .word 0
