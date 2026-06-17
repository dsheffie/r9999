/* test_flush_full.S -- FULL-L1D-cache flush.
 *
 * The existing cache tests touch ONE line; this fills ALL 256 L1D sets dirty
 * (4 KB, one 16 B line per set), D-Index-Writeback-Invalidates the whole cache,
 * then verifies via a cached read-back (which must miss L1D and refill the
 * written-back value from L2).  Exercises 256 writebacks, not one.
 *
 * -c0 self-check ('PASS'/'FAIL').  Verilator: ../../ooo_core -c0 -f test_flush_full.elf
 *                                  FPGA:      mips-axi -f test_flush_full.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    lui   $s0, 0x8002             /* buffer @ kseg0 0x80020000 (PA 0x20000) */
    li    $s1, 256               /* L1D sets (LG_L1D_NUM_SETS=8 -> 256), 16 B line */

    /* fill: word0 of each 16 B line = its index -> dirties all 256 sets */
    move  $t2, $s0
    li    $t3, 0
1:  sw    $t3, 0($t2)
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $s1, 1b
    nop

    /* flush: D-Index-Writeback-Invalidate every set */
    move  $t2, $s0
    li    $t3, 0
2:  cache 0x01, 0($t2)
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $s1, 2b
    nop

    /* verify cached: each word0 must still read its index (refilled from L2) */
    move  $t2, $s0
    li    $t3, 0
3:  lw    $t4, 0($t2)
    bne   $t4, $t3, fail
    nop
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $s1, 3b
    nop

    SIMCON_PUTLIT(0x50)          /* P */
    SIMCON_PUTLIT(0x41)          /* A */
    SIMCON_PUTLIT(0x53)          /* S */
    SIMCON_PUTLIT(0x53)          /* S */
    SIMCON_PUTLIT(0x0a)
    break
fail:
    SIMCON_PUTLIT(0x46)          /* F */
    SIMCON_PUTLIT(0x41)          /* A */
    SIMCON_PUTLIT(0x49)          /* I */
    SIMCON_PUTLIT(0x4c)          /* L */
    SIMCON_PUTLIT(0x0a)
    break
    .size main, .-main
