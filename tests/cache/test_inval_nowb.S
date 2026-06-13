/*
 * test_inval_nowb.S  --  D-Hit-Invalidate (0x11) discards dirty data WITHOUT writeback
 *
 * DMA-in semantics: a device wrote main memory behind the CPU's back, so
 * software invalidates the (now-stale) cached copy and must NOT write the dirty
 * cache line back over the fresh memory data. 0x11 must invalidate WITHOUT
 * writeback at every level that could hold a stale copy (L1D and L2 -- the
 * caches are non-inclusive).
 *
 * Model (no real device): seed OLD (0xAAAA) into MEMORY via the .data image,
 * dirty the cached copy to NEW (0xBBBB), then 0x11, then read back:
 *   1. store NEW    -> dirty in L1D (write-allocate brings OLD up through L2)
 *   2. CACHE 0x11   -> drop the dirty L1D line (no WB) + drop the L2 copy
 *   3. load         -> miss L1D, miss L2 -> memory -> OLD (0xAAAA)
 *
 *   correct 0x11        -> reads OLD  -> PASS
 *   CACHE == NOP        -> reads dirty NEW from L1D -> FAIL (red)
 *   0x11 promoted to WB -> NEW written down, reads NEW -> FAIL
 *
 * RTL SELF-CHECK ONLY (-c 0): the coherent interpreter cannot model
 * dirty-discard (it would read NEW), so do NOT run this under --checker.
 */

#include "sim.h"

    .set    mips3
    .set    reorder
    .set    noat

/* Magic-halt: -c 0 (no-checker) runs stop on a write to kseg1 0xBFD00000. */
    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

    .text
    .globl  main
    .type   main, @function
main:
    addiu   $sp, $sp, -8
    sw      $ra, 4($sp)

    la      $a0, msg_start
    jal     puts_sim
    nop

    la      $s0, scratch            /* memory at scratch already holds OLD=0xAAAA */

    /* ---- 1. dirty the cached copy to NEW ---- */
    li      $t1, 0xBBBB
    sw      $t1, 0($s0)             /* NEW dirty in L1D; OLD still in memory */

    /* ---- 2. D-Hit-Invalidate: discard the dirty line (no WB) + drop L2 ---- */
    cache   0x11, 0($s0)
    nop
    nop
    nop

    /* ---- 3. read back: must be OLD (NEW was discarded) ---- */
    lw      $v0, 0($s0)
    li      $t2, 0xAAAA
    bne     $v0, $t2, fail
    nop

    la      $a0, msg_pass
    jal     puts_sim
    nop
    HALT

fail:
    la      $a0, msg_fail
    jal     puts_sim
    nop
    HALT

    .size   main, . - main

    .globl  puts_sim
    .type   puts_sim, @function
puts_sim:
1:  lb      $t9, 0($a0)
    beqz    $t9, 2f
    SIMCON_PUTCHAR($t9)
    addiu   $a0, $a0, 1
    b       1b
2:  jr      $ra
    .size   puts_sim, . - puts_sim

    .section .data
    .align  4
scratch:
    .word   0x0000aaaa             /* OLD, lives in memory via the ELF image */

    .section .rodata
msg_start:  .asciz "CACHE D-Hit-Invalidate (no-writeback / DMA-in) test\n"
msg_pass:   .asciz "PASS\n"
msg_fail:   .asciz "FAIL\n"
