/* test_uc_wb_alias.S -- uncached store that aliases a DIRTY L2 line.
 *
 * Reproduces the IRIX wirepda wedge in isolation: an uncached store whose line
 * is resident-and-dirty in the L2 makes the L2 do UNCACHE_WB_DRAIN (write the
 * dirty line back) then the uncached store -- two back-to-back AXI transactions.
 * The old L2 slammed mem_req high with no gap, so the AXI master's WAIT state
 * never fell to IDLE -> deadlock. The fix (UNCACHE_WB_TURNAROUND) inserts a
 * one-cycle mem_req gap.  FPGA-only: Verilator's flat mem model has no AXI WAIT.
 *
 *   1. cached store 0xCAFE to kseg0 PA 0x20000      (dirty in L1D)
 *   2. CACHE D-Index-WB-Inval                       (push dirty line to L2, inval L1D)
 *   3. uncached store 0xBEEF to kseg1 same PA       (alias dirty L2 line -> UNCACHE_WB_DRAIN)
 *   4. uncached read back -> expect 0xBEEF
 * Old L2: step 3 deadlocks (timeout, no output).  Fixed L2: 'PASS'.
 *
 * FPGA: mips-axi -f test_uc_wb_alias.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    lui   $t0, 0x8002            /* cached alias  kseg0 0x80020000 (PA 0x20000) */
    lui   $t2, 0xa002            /* uncached alias kseg1 0xa0020000 (same PA)   */

    li    $t1, 0x0000cafe
    sw    $t1, 0($t0)            /* 1. cached store -> dirty L1D line */

    cache 0x01, 0($t0)           /* 2. D-Index-WB-Inval -> writeback to L2 (dirty), inval L1D */

    li    $t3, 0x0000beef
    sw    $t3, 0($t2)            /* 3. uncached store, aliases dirty L2 line -> UNCACHE_WB_DRAIN */

    lw    $t4, 0($t2)            /* 4. uncached read back of the same PA */
    li    $t5, 0x0000beef
    bne   $t4, $t5, fail
    nop

    SIMCON_PUTLIT(0x50)         /* P */
    SIMCON_PUTLIT(0x41)         /* A */
    SIMCON_PUTLIT(0x53)         /* S */
    SIMCON_PUTLIT(0x53)         /* S */
    SIMCON_PUTLIT(0x0a)
    break
fail:
    SIMCON_PUTLIT(0x46)         /* F */
    SIMCON_PUTLIT(0x41)
    SIMCON_PUTLIT(0x49)
    SIMCON_PUTLIT(0x4c)
    SIMCON_PUTLIT(0x0a)
    break
    .size main, .-main
