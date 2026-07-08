/* test_uc_ds_deadlock.S -- uncached store in the delay slot of a MISPREDICTED branch.
 *
 * Isolates the ip22_eeprom_read FPGA deadlock (task #42).  ip22_eeprom_read ends:
 *       jr   ra                 <- return, RAS/BTB can mispredict (faulted=1)
 *       sw   v1,0(a0)           <- DELAY SLOT: uncached store to the eeprom device
 * The mispredicted branch's retire is gated (bug-#3 fix) on the delay slot
 * COMPLETING, but the delay-slot UNCACHED store's issue is gated on being at the
 * ROB head / drain_ds_complete -- which needs the branch to retire first.  Circular
 * -> deadlock.  Only a MISPREDICT (faulted) triggers it, so it is intermittent.
 *
 * Repro: an indirect `jr` with a COLD BTB (first + only execution) mispredicts,
 * with an uncached kseg1 store in its delay slot.
 *   pre-fix : the core wedges -> sim TIMES OUT, no output.
 *   post-fix: Fix A lets the (non-speculative) delay-slot store issue -> 'PASS'.
 *
 * FPGA: mips-axi -f test_uc_ds_deadlock.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    lui   $t2, 0xa002            /* uncached kseg1 0xa0020000 (PA 0x20000) */
    li    $t3, 0x0000beef

    la    $t0, after             /* fresh indirect target: BTB has no history  */
    jr    $t0                    /* -> mispredicts on this first/only run (faulted=1) */
    sw    $t3, 0($t2)            /* DELAY SLOT: uncached store to the device   */
    /* mispredicted fall-through path (should be squashed): */
    nop
    nop
after:
    lw    $t4, 0($t2)            /* uncached read back of the same PA */
    li    $t5, 0x0000beef
    bne   $t4, $t5, fail
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
