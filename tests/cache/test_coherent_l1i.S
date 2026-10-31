/*
 * test_coherent_l1i.S  --  ENABLE_COHERENT_L1I: a store over an instruction the L1I
 * already holds is seen by the next fetch, with no CACHE op in between.
 *
 * `patchme` runs once (so its line is in the L1I), a store rewrites its first word,
 * and it runs again.  With the knob the L2 drops the line from the L1I before the
 * L1D takes it, and probes the dirty copy out of the L1D for the refetch, so the
 * second call returns NEW.  Without the knob the stale word is architecturally legal
 * (MIPS needs a CACHE op), so this test is only meaningful on a knob build:
 *   -c 0  self-check: the second call must return NEW
 *   -c 1  co-sim: the checker must report no [stale-ifetch]
 * A second case patches through kseg1 (the uncached-store path).
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

#define OLD_INSN 0x24020001     /* addiu v0, zero, 1 */
#define NEW_INSN 0x24020002     /* addiu v0, zero, 2 */
#define NEW2_INSN 0x24020003    /* addiu v0, zero, 3 */

/* let the patching store retire and drain before the refetch (in-flight
 * instructions are not covered by the knob) */
    .macro  SETTLE
    li      $t3, 256
1:  addiu   $t3, $t3, -1
    bnez    $t3, 1b
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

    /* case 1: a cached store (the L1D fills the line the L1I holds) */
    li      $s1, 1
    la      $s0, patchme
    jal     patchme
    nop
    li      $t2, 1
    bne     $v0, $t2, fail
    nop
    li      $t1, NEW_INSN
    sw      $t1, 0($s0)
    SETTLE
    jal     patchme
    nop
    li      $t2, 2
    bne     $v0, $t2, fail
    nop

    /* case 2: an uncached store through kseg1 to the same line */
    li      $s1, 2
    li      $t1, NEW2_INSN
    li      $t4, 0x20000000
    or      $t4, $s0, $t4           /* kseg0 -> kseg1 alias */
    cache   0x15, 0($s0)            /* D Hit WB-Inv: memory is what kseg1 writes over */
    sw      $t1, 0($t4)
    SETTLE
    jal     patchme
    nop
    li      $t2, 3
    bne     $v0, $t2, fail
    nop

    la      $a0, msg_pass
    jal     puts_sim
    nop
    HALT

fail:
    addiu   $t9, $s1, 0x30          /* the case id, as a digit */
    SIMCON_PUTCHAR($t9)
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
    nop
    SIMCON_PUTCHAR($t9)
    b       1b
    addiu   $a0, $a0, 1
2:  jr      $ra
    nop
    .size   puts_sim, . - puts_sim

/* alone in its 128-byte block so nothing else shares the line */
    .align  7
patchme:
    .word   OLD_INSN
    jr      $ra
    nop
    .align  7

    .data
msg_start: .asciz "coherent_l1i: start\n"
msg_pass:  .asciz "coherent_l1i: PASS\n"
msg_fail:  .asciz " coherent_l1i: FAIL\n"
