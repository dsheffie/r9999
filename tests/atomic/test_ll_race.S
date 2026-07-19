/*
 * test_ll_race.S -- 100 back-to-back LL/SC atomic increments to two separate
 * lines.  No intervening store to either linked line, so every SC MUST succeed
 * (rt=1).  Any spurious SC failure (e.g. the r_sc_should_write single-register
 * being re-latched across the two in-flight atomics) is caught: the code goes
 * straight to F on a failed SC, and the final counts must both be 100.
 */
#include "sim.h"
    .set    mips3
    .set    noreorder
    .set    noat
    .text
    .globl  main
    .type   main,@function
main:
    la      $16, lineA
    la      $17, lineB
    sw      $0, 0($16)
    sw      $0, 0($17)
    li      $19, 100
loop:
    ll      $8, 0($16)
    addiu   $8, $8, 1
    sc      $8, 0($16)
    beq     $8, $0, fail          /* SC must succeed */
    nop
    ll      $9, 0($17)
    addiu   $9, $9, 1
    sc      $9, 0($17)
    beq     $9, $0, fail
    nop
    addiu   $19, $19, -1
    bne     $19, $0, loop
    nop
    lw      $8, 0($16)
    li      $3, 100
    bne     $8, $3, fail
    nop
    lw      $9, 0($17)
    bne     $9, $3, fail
    nop
    li      $25, 0x50
    mtc0    $25, $7               /* P */
    break
fail:
    li      $25, 0x46
    mtc0    $25, $7               /* F */
    break
    .size   main,.-main
    .data
    .align  5
lineA:   .space 32
lineB:   .space 32
