/*
 * test_prid.S  --  PRId (CP0 reg 15) reads as the R4000-family value and is
 * read-only.  Verifies MFC0 and DMFC0 return 0x00000400 and that an attempted
 * MTC0 write leaves it unchanged.  Self-contained; halts via magic-halt.
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

    .macro  FAIL
    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('R')
    SIMCON_PUTLIT('I')
    SIMCON_PUTLIT('D')
    SIMCON_PUTLIT('-')
    SIMCON_PUTLIT('B')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('D')
    SIMCON_PUTLIT('\n')
    HALT
    .endm

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t2, PRID_VALUE     /* expected PRId */

    mfc0    $t0, $15            /* read PRId */
    bne     $t0, $t2, .Lbad
    nop

    /* attempt to write PRId (read-only -> must stay 0x400) */
    li      $t1, 0xdeadbeef
    mtc0    $t1, $15
    nop
    nop
    mfc0    $t0, $15
    bne     $t0, $t2, .Lbad
    nop

    /* dmfc0 must also return 0x400 */
    dmfc0   $t0, $15
    bne     $t0, $t2, .Lbad
    nop

    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('R')
    SIMCON_PUTLIT('I')
    SIMCON_PUTLIT('D')
    SIMCON_PUTLIT('-')
    SIMCON_PUTLIT('O')
    SIMCON_PUTLIT('K')
    SIMCON_PUTLIT('\n')
    HALT

.Lbad:
    FAIL
    .size   _start, . - _start
