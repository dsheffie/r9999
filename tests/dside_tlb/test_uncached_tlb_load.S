/*
 * test_uncached_tlb_load.S  --  a load through a TLB page marked UNCACHED
 * (C=2) must not issue speculatively.
 *
 * l1d's admission gate (w_uncachable_req) only sees the SEGMENT's
 * cacheability, and kuseg is "cached" there, so before the fix a kuseg load
 * whose TLB entry says C=2 could fast-hit or issue INJECT_UNCACHE_LOAD while
 * still younger than the ROB head -- a speculative device read.  The l1d
 * VERILATOR checker prints "[UCSPEC]" for exactly that.
 *
 *   kuseg VA 0x00100000 -> TLB (C=2, uncached) -> PA 0x100000
 *   kseg1    0xA0100000 -> PA 0x100000 (writes the expected value)
 *
 * Each iteration: an unfinished divide (mflo pending) keeps the uncached load
 * off the ROB head; then a branch that is really taken puts a second
 * uncached load on the (predicted) wrong path.
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
    jal     sim_puts
    nop

    /* TLB entry 0: VPN2 0x80 (VA 0x00100000/0x00101000), ASID 7, C=2 */
    li      $t0, 0x00100007
    mtc0    $t0, $10
    li      $t0, 0x00004016        /* PFN=0x100, C=2, D=1, V=1 */
    mtc0    $t0, $2
    li      $t0, 0x00004056        /* PFN=0x101, C=2, D=1, V=1 */
    mtc0    $t0, $3
    mtc0    $zero, $5
    mtc0    $zero, $0
    tlbwi

    li      $t0, 0x5a5a1234
    li      $t1, 0xa0100000
    sw      $t0, 0($t1)            /* expected value, via kseg1 */

    li      $t2, 0x00100000        /* kuseg VA, TLB-uncached */
    li      $s0, 64                /* iterations */
loop:
    li      $t4, 100000
    li      $t5, 7
    divu    $zero, $t4, $t5
    mflo    $t6                    /* long-latency, older than the load */
    lw      $t3, 0($t2)            /* uncached: must wait for the ROB head */
    bne     $t3, $t0, fail
    bnez    $t6, taken             /* really taken; a cold predictor says not */
    nop
    lw      $t7, 0($t2)            /* wrong path: must never touch the device */
taken:
    addiu   $s0, $s0, -1
    bnez    $s0, loop
    nop

    la      $a0, msg_pass
    jal     sim_puts
    nop
    SIM_PASS()

fail:
    la      $a0, msg_fail
    jal     sim_puts
    nop
    SIM_FAIL(msg_fail)

    .size   main, . - main

/* ---- sim_puts ---- */
    .type   sim_puts, @function
sim_puts:
1:  lb      $t9, 0($a0)
    beqz    $t9, 2f
    SIMCON_PUTCHAR($t9)
    addiu   $a0, $a0, 1
    b       1b
2:  jr      $ra
    .size   sim_puts, . - sim_puts

    .section .rodata
msg_start: .asciiz "uncached TLB load test\n"
msg_pass:  .asciiz "uncached TLB load test passed\n"
msg_fail:  .asciiz "uncached TLB load test FAIL: wrong data\n"
