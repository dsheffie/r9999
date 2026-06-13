/*
 * test_smc_index.S  --  self-modifying-code coherence via the Index-form CACHE ops
 *
 *   D-Index-Writeback-Invalidate (0x01)  +  I-Index-Invalidate (0x00)
 *
 * Same code-patching sequence as test_smc_hit.S, but using the Index forms,
 * which are IRIX's dominant ops (28.5% I-Index-Inval + 28.5% D-Index-WB-Inval
 * at boot -- cache init and bulk flushes).  Index ops select the line by the
 * EA's {set-index} bits with no tag compare; for this direct-mapped cache the
 * line holding patch_target sits at index = (PA >> 4) & (num_sets-1), and since
 * kseg0 PA == VA & 0x1fffffff, the patch_target VA itself indexes the right set.
 *
 *   correct CACHE -> 2nd call returns 2 -> PASS
 *   CACHE == NOP  -> stale L1I hit, returns 1 -> FAIL (TDD red)
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

    /* ---- index-WB the D line to L2, then index-invalidate the I line ---- */
    cache   0x01, 0($s0)            /* D-Index-Writeback-Invalidate */
    cache   0x00, 0($s0)            /* I-Index-Invalidate            */
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
    SIM_FAIL("smc-index stale fetch")

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
    .globl  patch_target
patch_target:
    .word   0x03e00008             /* jr   $ra            */
    .word   0x34020001             /* ori  $v0,$zero,1    (OLD; patched to ..2) */

    .section .rodata
msg_start:  .asciz "SMC code-coherence (Index-form CACHE) test\n"
msg_pass:   .asciz "PASS\n"
msg_fail:   .asciz "FAIL\n"
