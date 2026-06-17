/* test_l2_evict.S -- L2->DRAM eviction writeback across the AXI (bus-stress).
 *
 * Fills 32 KB (2048 lines = 2x L2 capacity) of dirty data through the cached
 * kseg0 alias.  Line i and line i+1024 map to the SAME L2 set, so writing the
 * second 16 KB EVICTS the first 16 KB out of L2 -> DRAM, generating ~1024 real
 * L2->DRAM writebacks across the mem bus (AXI).  Then verifies the FIRST 16 KB
 * via the UNCACHED kseg1 alias (which bypasses L1D+L2 and reads DRAM directly):
 * if every evicted writeback drained correctly, each word0 reads back its index.
 *
 * This is the closest directed analogue of the wirepda bus traffic; on silicon
 * a writeback/AXI drain bug shows up here as a wrong value or a wedge.
 *
 * -c0 self-check.  Verilator: ../../ooo_core -c0 -f test_l2_evict.elf
 *                  FPGA:      mips-axi -f test_l2_evict.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    lui   $s0, 0x8002             /* cached fill base  kseg0 0x80020000 */
    lui   $s3, 0xa002             /* uncached verify base kseg1 0xa0020000 (same PA) */
    li    $s1, 2048             /* 2x L2 -> forces L2->DRAM eviction of the first half */
    li    $s2, 1024             /* verify the first half (guaranteed evicted to DRAM) */

    /* fill 32 KB cached: word0 of each line = its index */
    move  $t2, $s0
    li    $t3, 0
1:  sw    $t3, 0($t2)
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $s1, 1b
    nop

    /* flush the 256 L1D sets too (covers anything still dirty in L1D) */
    move  $t2, $s0
    li    $t3, 0
    li    $t5, 256
2:  cache 0x01, 0($t2)
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $t5, 2b
    nop

    /* verify first 16 KB via UNCACHED reads -> proves L2->DRAM writeback drained */
    move  $t2, $s3
    li    $t3, 0
3:  lw    $t4, 0($t2)
    bne   $t4, $t3, fail
    nop
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $s2, 3b
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
