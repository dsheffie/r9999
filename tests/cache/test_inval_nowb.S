/*
 * test_inval_nowb.S  --  D-Hit-Invalidate (0x11) discards dirty data WITHOUT writeback
 *
 * This is the DMA-in semantics: a device wrote main memory behind the CPU's
 * back, so software invalidates the (now-stale) cached copy and must NOT write
 * the dirty cache line back over the fresh memory data.  0x11 must therefore
 * invalidate without writeback, and must never be promoted to WB-Invalidate.
 *
 * Sequence:
 *   1. store OLD (0xAAAA) and push it to memory   (sw + D-Hit-WB-Inval 0x15)
 *   2. store NEW (0xBBBB)  -> dirty in L1D, NOT in memory
 *   3. CACHE 0x11          -> discard the dirty NEW line (no writeback)
 *   4. load back           -> must read OLD (0xAAAA) from memory
 *
 *   correct 0x11           -> reads OLD  -> PASS
 *   CACHE == NOP           -> reads dirty NEW from L1D -> FAIL (TDD red)
 *   0x11 promoted to WB    -> NEW written to mem, reads NEW -> FAIL
 *
 * RTL SELF-CHECK ONLY (run with -c 0): the interpreter has flat coherent
 * memory and cannot model "discard dirty data", so it would read NEW and
 * diverge from a correct RTL.  Do NOT run this under --checker.
 */

#include "sim.h"

    .set    mips3
    .set    reorder
    .set    noat

/* Magic-halt: -c 0 (no-checker) runs stop on a write to kseg1 0xBFD00000,
 * not on break (break would trap to the crt0 placeholder vector). */
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

    la      $s0, scratch

    /* ---- 1. establish OLD in memory ---- */
    li      $t0, 0xAAAA
    sw      $t0, 0($s0)
    cache   0x15, 0($s0)            /* D-Hit-WB-Inval: OLD -> L2/mem, line gone */
    nop

    /* ---- 2. write NEW: dirty in L1D only ---- */
    li      $t1, 0xBBBB
    sw      $t1, 0($s0)

    /* ---- 3. discard the dirty line WITHOUT writeback ---- */
    cache   0x11, 0($s0)            /* D-Hit-Invalidate (no writeback) */
    nop
    nop
    nop

    /* ---- 4. read back: must be OLD (NEW was discarded) ---- */
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
    .word   0

    .section .rodata
msg_start:  .asciz "CACHE D-Hit-Invalidate (no-writeback / DMA-in) test\n"
msg_pass:   .asciz "PASS\n"
msg_fail:   .asciz "FAIL\n"
