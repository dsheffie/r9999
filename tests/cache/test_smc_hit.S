/*
 * test_smc_hit.S  --  self-modifying-code coherence via the Hit-form CACHE ops
 *
 *   D-Hit-Writeback-Invalidate (0x15)  +  I-Hit-Invalidate (0x10)
 *
 * The classic runtime-code-patching sequence IRIX relies on (doelfrelocs,
 * R4000 workarounds, module load):  write new code via D-stores, push the
 * dirty D-cache line to the shared L2 (0x15), drop the stale I-cache line so
 * the next fetch refills the new code from L2 (0x10).
 *
 * patch_target lives in writable .data and is 16-byte (one cacheline) aligned.
 * It returns 1; we call it once (to warm L1I with the OLD code), patch its
 * delay-slot word to "ori $v0,$zero,2", run the CACHE sequence, and call again.
 *
 *   correct CACHE  -> 2nd call returns 2  -> PASS
 *   CACHE == NOP   -> 2nd call hits stale L1I, returns 1 -> FAIL  (TDD red)
 *
 * Co-sim safe: the interpreter has flat coherent memory, so it always sees the
 * new code (returns 2); a stale-fetching RTL diverges under --checker true.
 */

#include "sim.h"

    .set    mips3
    .set    reorder
    .set    noat

    .text
    .globl  main
    .type   main, @function
main:
    addiu   $sp, $sp, -8
    sw      $ra, 4($sp)

    la      $a0, msg_start
    jal     puts_sim
    nop

    la      $s0, patch_target

    /* ---- 1st call: warm L1I with the OLD code, expect v0 == 1 ---- */
    jalr    $s0
    nop
    li      $t0, 1
    bne     $v0, $t0, fail
    nop

    /* ---- patch the delay-slot word to "ori $v0,$zero,2" (0x34020002) ---- */
    li      $t1, 0x34020002
    sw      $t1, 4($s0)             /* new code, now dirty in L1D */

    /* ---- push the line to L2, then invalidate the stale L1I line ---- */
    cache   0x15, 0($s0)            /* D-Hit-Writeback-Invalidate */
    cache   0x10, 0($s0)            /* I-Hit-Invalidate            */
    nop
    nop
    nop

    /* ---- 2nd call: must fetch the NEW code, expect v0 == 2 ---- */
    jalr    $s0
    nop
    li      $t0, 2
    bne     $v0, $t0, fail
    nop

    la      $a0, msg_pass
    jal     puts_sim
    nop
    lw      $ra, 4($sp)
    addiu   $sp, $sp, 8
    SIM_PASS()

fail:
    la      $a0, msg_fail
    jal     puts_sim
    nop
    SIM_FAIL("smc-hit stale fetch")

    .size   main, . - main

/* ------------------------------------------------------------------ */
/* puts_sim($a0 = ptr) -- output a null-terminated string             */
/* ------------------------------------------------------------------ */
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

/* ------------------------------------------------------------------ */
/* Patchable function in writable .data, one-cacheline aligned.       */
/*   jr $ra ; ori $v0,$zero,1   (the ori is the patched delay slot)   */
/* ------------------------------------------------------------------ */
    .section .data
    .align  4
    .globl  patch_target
patch_target:
    .word   0x03e00008             /* jr   $ra            */
    .word   0x34020001             /* ori  $v0,$zero,1    (OLD; patched to ..2) */

    .section .rodata
msg_start:  .asciz "SMC code-coherence (Hit-form CACHE) test\n"
msg_pass:   .asciz "PASS\n"
msg_fail:   .asciz "FAIL\n"
