/* test_flush_l2_full.S -- FULL-L2 fill + flush.
 *
 * Fills 16 KB (1024 lines = all L2 sets, LG_L2_NUM_SETS=10), which forces the
 * fill to evict L1D lines into L2 (L1D holds only 256), so the whole L2 ends up
 * dirty.  Then D-Index-Writeback-Invalidates the 256 L1D sets and verifies all
 * 1024 lines via cached read-back -- proving a FULL L2's worth of data stays
 * consistent through the hierarchy (L1D->L2 evictions + the flush).
 *
 * -c0 self-check.  Verilator: ../../ooo_core -c0 -f test_flush_l2_full.elf
 *                  FPGA:      mips-axi -f test_flush_l2_full.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    lui   $s0, 0x8002             /* buffer @ kseg0 0x80020000 */
    li    $s1, 1024              /* L2 sets -> 16 KB of 16 B lines */
    li    $s2, 256              /* L1D sets (flush count) */

    /* fill 16 KB: word0 of each line = its index */
    move  $t2, $s0
    li    $t3, 0
1:  sw    $t3, 0($t2)
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $s1, 1b
    nop

    /* flush the 256 L1D sets (D-Index-WB-Inval) -> push current L1D into L2 */
    move  $t2, $s0
    li    $t3, 0
2:  cache 0x01, 0($t2)
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $s2, 2b
    nop

    /* verify all 1024 lines cached: each word0 == index (from L2) */
    move  $t2, $s0
    li    $t3, 0
3:  lw    $t4, 0($t2)
    bne   $t4, $t3, fail
    nop
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $s1, 3b
    nop

    SIMCON_PUTLIT(0x50)
    SIMCON_PUTLIT(0x41)
    SIMCON_PUTLIT(0x53)
    SIMCON_PUTLIT(0x53)
    SIMCON_PUTLIT(0x0a)
    break
fail:
    SIMCON_PUTLIT(0x46)
    SIMCON_PUTLIT(0x41)
    SIMCON_PUTLIT(0x49)
    SIMCON_PUTLIT(0x4c)
    SIMCON_PUTLIT(0x0a)
    break
    .size main, .-main
