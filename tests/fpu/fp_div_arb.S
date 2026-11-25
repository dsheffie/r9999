/*
 * fp_div_arb.S -- int and FP divides sharing the unified divider (uni_divider d0) under
 * exec.sv's registered turn (r_div_turn).  Two shapes, 2000 times:
 *   1. an int divide whose dividend is a FP divide's result (div.s -> mfc1 -> divu): the
 *      int divide is not ready until the FP divide finishes, so it must not hold the turn
 *      (a presence-based request would deadlock here);
 *   2. back-to-back independent int and FP divides, so both sides want d0 at once.
 * Co-sim (-c 1) checks every GPR result; a deadlock shows as a timeout.  crt0 sets CU1.
 */
#include "sim.h"

    .set    mips3
    .set    reorder

    .text
    .globl  main
    .type   main, @function
main:
    li      $t0, 2000
    li      $t4, 0x42c80000         /* 100.0f */
    mtc1    $t4, $f0
    li      $t5, 0x40400000         /* 3.0f */
    mtc1    $t5, $f2
    li      $t7, 7
loop:
    /* 1. FP divide -> mfc1 -> int divide on its result */
    div.s   $f4, $f0, $f2
    mfc1    $t6, $f4
    divu    $zero, $t6, $t7
    mflo    $s0
    mfhi    $s1
    /* 2. independent int and FP divides, adjacent */
    divu    $zero, $t0, $t7
    div.s   $f6, $f2, $f0
    divu    $zero, $t4, $t0
    div.s   $f8, $f0, $f6
    mflo    $s2
    mfc1    $s3, $f6
    mfc1    $s4, $f8
    addu    $s5, $s0, $s2
    addiu   $t0, $t0, -1
    bnez    $t0, loop
    jr      $ra
    .size   main, . - main
