/*
 * test_cache_blk.S  --  the R10000 secondary-cache ops (0x17, 0x13, 0x03) as one
 * mem op each to the L2 (MEM_BLK_*): they must complete and retire exactly once,
 * in straight-line code and in the delay slots of taken and not-taken branches,
 * with the architectural state the interpreter computes (run under --checker).
 * Cache effects are not checked here (test_cache_act does that).
 *
 * Build for an ENABLE_R10000 ooo_core; on an R4400 build the same encodings are
 * one-line D ops and the test passes too.
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
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

    la      $s0, buf
    li      $s1, 0                  /* taken-branch count */
    li      $s2, 0                  /* fall-through count */
    li      $s3, 64                 /* iterations */

loop:
    /* straight line, one of each */
    cache   0x17, 0($s0)
    cache   0x13, 128($s0)
    cache   0x03, 256($s0)
    cache   0x03, 257($s0)          /* the way-1 form the IP28 kernel issues */

    /* delay slot of a taken branch */
    beq     $zero, $zero, 1f
    cache   0x17, 384($s0)
    addiu   $s1, $s1, 100           /* skipped */
1:  addiu   $s1, $s1, 1

    /* delay slot of a not-taken branch */
    bne     $zero, $zero, 2f
    cache   0x13, 512($s0)
    addiu   $s2, $s2, 1
2:
    /* delay slot of a taken branch, index op */
    bgez    $zero, 3f
    cache   0x03, 640($s0)
    addiu   $s1, $s1, 100           /* skipped */
3:
    addiu   $s3, $s3, -1
    bne     $s3, $zero, loop
    nop

    li      $t0, 64
    bne     $s1, $t0, fail
    nop
    bne     $s2, $t0, fail
    nop

    la      $a0, msg_pass
    jal     puts_sim
    nop
    lw      $ra, 4($sp)
    addiu   $sp, $sp, 8
    SIM_PASS()
    nop

fail:
    la      $a0, msg_fail
    jal     puts_sim
    nop
    SIM_FAIL(x)
    nop
    .size   main, . - main

    .globl  puts_sim
    .type   puts_sim, @function
puts_sim:
1:  lb      $t9, 0($a0)
    beqz    $t9, 2f
    nop
    SIMCON_PUTCHAR($t9)
    b       1b
    addiu   $a0, $a0, 1
2:  jr      $ra
    nop
    .size   puts_sim, . - puts_sim

    .data
    .align  7
buf:
    .space  1024

    .section .rodata
msg_start: .asciz "test_cache_blk: R10000 block CACHE ops\n"
msg_pass:  .asciz "PASS\n"
msg_fail:  .asciz "FAIL\n"
