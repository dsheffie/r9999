/*
 * test_eret.S  --  validate the EXL-based exception/ERET round trip.
 *
 * A normal exception must set Status.EXL (not ERL) on entry, and ERET must
 * clear EXL and return to EPC.  This test:
 *   1. enters BEV=0 kernel mode with EXL=0,
 *   2. executes SYSCALL (general exception -> 0x80000180),
 *   3. the handler checks EXL==1, advances EPC past the syscall, and ERETs,
 *   4. after return, main checks EXL==0 and that execution continued.
 *
 * Expected console output:  H1 R0  (handler saw EXL=1; after ERET EXL=0)
 *
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

/* ================================================================
 * General exception handler at 0x80000180 (BEV=0)
 * ================================================================ */
    .section .except_vec, "ax"
    .org    0x180
    .globl  _vec_gen
_vec_gen:
    /* print 'H' then '1' if EXL set, '0' if not */
    SIMCON_PUTLIT('H')
    mfc0    $k0, $12            /* Status */
    andi    $k1, $k0, 0x2       /* EXL bit */
    beq     $k1, $zero, 1f
    nop
    SIMCON_PUTLIT('1')
    b       2f
    nop
1:  SIMCON_PUTLIT('0')
2:
    /* advance EPC past the SYSCALL so ERET returns to the next insn */
    mfc0    $k0, $14
    addiu   $k0, $k0, 4
    mtc0    $k0, $14
    eret
    nop

/* ================================================================
 * Reset entry
 * ================================================================ */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00           /* BEV=0, kernel mode, EXL=0, ERL=0 */
    mtc0    $t0, $12
    nop
    nop
    nop

    syscall                     /* general exception -> 0x80000180 */

    /* returned here via ERET: print 'R' then EXL bit (expect 0) */
    SIMCON_PUTLIT(' ')
    SIMCON_PUTLIT('R')
    mfc0    $t0, $12
    andi    $t1, $t0, 0x2
    beq     $t1, $zero, 3f
    nop
    SIMCON_PUTLIT('1')
    b       4f
    nop
3:  SIMCON_PUTLIT('0')
4:  SIMCON_PUTLIT('\n')
    HALT
    .size   _start, . - _start
