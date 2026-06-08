/*
 * test_cache.S  --  CACHE instruction is decoded as a NOP (does not trap).
 *
 * Executes a few CACHE ops; if CACHE were still an illegal instruction it
 * would fault to the (absent) handler and the PASS line would never print.
 * Self-contained; halts via the magic-halt register.
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

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00           /* BEV=0, kernel, EXL=0, ERL=0 */
    mtc0    $t0, $12
    nop
    nop
    nop

    lui     $t0, 0x8001         /* a valid kseg0 base address */
    cache   0x0, 0($t0)         /* Index_Invalidate (I) */
    cache   0x1, 0($t0)         /* Index_WB_Invalidate (D) */
    cache   0x14, 0($t0)        /* Hit ops, etc. -- all NOP for now */
    nop

    SIMCON_PUTLIT('C')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('C')
    SIMCON_PUTLIT('H')
    SIMCON_PUTLIT('E')
    SIMCON_PUTLIT('-')
    SIMCON_PUTLIT('O')
    SIMCON_PUTLIT('K')
    SIMCON_PUTLIT('\n')
    HALT
    .size   _start, . - _start
