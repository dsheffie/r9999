/*
 * test_regimm_link.S -- REGIMM branch-and-link family: taken/not-taken, delay-slot
 *                       execute-vs-nullify, and unconditional linking.
 *
 * WHY THIS EXISTS (IRIX `be` root cause, 2026-08-06)
 * -------------------------------------------------
 * predecode.sv's REGIMM table switched on rt and handled only 0,1,2,3,17 -- so
 * rt 16 (BLTZAL), 18 (BLTZALL) and 19 (BGEZALL) fell to `default` and got pd=0,
 * which l1i treats as "NOT a control-flow instruction" (t_update_spec_hist =
 * (t_pd != 4'd0), and the cflow if-chain never matches 0).  t_is_cflow,
 * n_delay_slot and t_take_br all stayed 0, so the FRONT END ran straight through a
 * real branch -- mispredicting it every time and never marking its delay slot --
 * while decode_mips.sv decoded all four correctly.  MIPSpro emits
 * `bgezall $zero,TARGET` as an unconditional-call idiom, so IRIX hit this
 * constantly: the branch target's `addiu sp,sp,-112` prologue committed BEFORE the
 * delay slot retired, the restart re-ran it, and sp ended one 112-byte frame low ->
 * later frame reads hit the wrong stack slot -> wild deref.
 *
 * THE SPEC BEING TESTED (rs == $zero makes every case fully determined)
 * --------------------------------------------------------------------
 *   insn            condition   taken?  delay slot   links ra?
 *   bgezal  $zero   rs >= 0     YES     executes     yes
 *   bgezall $zero   rs >= 0     YES     executes     yes   (likely, taken => executes)
 *   bltzal  $zero   rs <  0     no      executes     yes   (not likely => always executes)
 *   bltzall $zero   rs <  0     no      NULLIFIED    yes   (likely, not taken => nullified)
 *
 * The *AL family links UNCONDITIONALLY -- ra = branch+8 even when not taken.  r9999
 * previously gated the link on branch-taken, which broke PIC dynamic linkers
 * (fixed in exec.sv/decode_mips.sv); this test pins that behaviour too.
 *
 * Each case uses a marker register the delay slot increments, so "did the delay slot
 * execute" is observable without relying on any control-flow side effect.
 *
 * Coverage note: randgen emits none of these and compilers rarely do, which is why a
 * front-end bug in three of the four survived ~600 randgen tests and a csmith sweep.
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

/* fail with a message */
    .macro  FAILM msg
    la      $a0, \msg
    jal     sim_puts
    nop
    HALT
    .endm

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    mtc0    $zero, $12
    nop
    nop
    nop
    li      $sp, 0x80070000

    la      $a0, msg_start
    jal     sim_puts
    nop

/* ================================================================
 * 1. bgezal $zero  -- TAKEN, delay slot EXECUTES, links
 * ================================================================ */
    li      $s0, 0                      /* marker */
    .globl  b1
b1: bgezal  $zero, t1
    addiu   $s0, $s0, 1                 /* delay slot */
    FAILM   msg_f1_fell                 /* taken => must not reach here */
t1: move    $s1, $ra
    li      $t0, 1
    bne     $s0, $t0, f1_ds             /* delay slot must have executed */
    nop
    la      $t0, b1
    addiu   $t0, $t0, 8
    bne     $s1, $t0, f1_ra             /* ra must be branch+8 */
    nop

/* ================================================================
 * 2. bgezall $zero -- TAKEN (likely), delay slot EXECUTES, links
 *    THE ONE THAT BROKE IRIX.
 * ================================================================ */
    li      $s0, 0
    .globl  b2
b2: bgezall $zero, t2
    addiu   $s0, $s0, 1                 /* delay slot: taken => executes */
    FAILM   msg_f2_fell
t2: move    $s1, $ra
    li      $t0, 1
    bne     $s0, $t0, f2_ds
    nop
    la      $t0, b2
    addiu   $t0, $t0, 8
    bne     $s1, $t0, f2_ra
    nop

/* ================================================================
 * 3. bltzal $zero -- NOT taken, delay slot STILL EXECUTES, links anyway
 * ================================================================ */
    li      $s0, 0
    li      $ra, 0
    .globl  b3
b3: bltzal  $zero, t3_bad
    addiu   $s0, $s0, 1                 /* not likely => executes regardless */
    move    $s1, $ra                    /* fall-through lands here */
    li      $t0, 1
    bne     $s0, $t0, f3_ds
    nop
    la      $t0, b3
    addiu   $t0, $t0, 8
    bne     $s1, $t0, f3_ra             /* links even though NOT taken */
    nop
    b       case4
    nop
t3_bad:
    FAILM   msg_f3_taken                /* rs<0 is false for $zero: must not branch */

/* ================================================================
 * 4. bltzall $zero -- NOT taken (likely) => delay slot NULLIFIED, links anyway
 * ================================================================ */
case4:
    li      $s0, 0
    li      $ra, 0
    .globl  b4
b4: bltzall $zero, t4_bad
    addiu   $s0, $s0, 1                 /* likely + not taken => must NOT execute */
    move    $s1, $ra
    bne     $s0, $zero, f4_ds           /* marker must still be 0 */
    nop
    la      $t0, b4
    addiu   $t0, $t0, 8
    bne     $s1, $t0, f4_ra
    nop
    b       done
    nop
t4_bad:
    FAILM   msg_f4_taken

done:
    la      $a0, msg_pass
    jal     sim_puts
    nop
    HALT

f1_ds:  FAILM msg_f1_ds
f1_ra:  FAILM msg_f1_ra
f2_ds:  FAILM msg_f2_ds
f2_ra:  FAILM msg_f2_ra
f3_ds:  FAILM msg_f3_ds
f3_ra:  FAILM msg_f3_ra
f4_ds:  FAILM msg_f4_ds
f4_ra:  FAILM msg_f4_ra

    .globl  sim_puts
    .type   sim_puts, @function
sim_puts:
    lbu     $t9, 0($a0)
    beq     $t9, $zero, 2f
    nop
1:  SIMCON_PUTCHAR($t9)
    addiu   $a0, $a0, 1
    lbu     $t9, 0($a0)
    bne     $t9, $zero, 1b
    nop
2:  jr      $ra
    nop

    .section .rodata
msg_start:    .asciiz "REGIMM branch-and-link test\n"
msg_pass:     .asciiz "PASS: bgezal/bgezall/bltzal/bltzall all correct\n"
msg_f1_fell:  .asciiz "FAIL: bgezal $zero not taken\n"
msg_f1_ds:    .asciiz "FAIL: bgezal delay slot did not execute\n"
msg_f1_ra:    .asciiz "FAIL: bgezal did not link branch+8\n"
msg_f2_fell:  .asciiz "FAIL: bgezall $zero not taken\n"
msg_f2_ds:    .asciiz "FAIL: bgezall delay slot did not execute (taken => must execute)\n"
msg_f2_ra:    .asciiz "FAIL: bgezall did not link branch+8\n"
msg_f3_taken: .asciiz "FAIL: bltzal $zero was taken (rs<0 is false)\n"
msg_f3_ds:    .asciiz "FAIL: bltzal delay slot did not execute (not likely => always executes)\n"
msg_f3_ra:    .asciiz "FAIL: bltzal did not link when NOT taken (link is unconditional)\n"
msg_f4_taken: .asciiz "FAIL: bltzall $zero was taken (rs<0 is false)\n"
msg_f4_ds:    .asciiz "FAIL: bltzall delay slot EXECUTED (likely + not taken => nullified)\n"
msg_f4_ra:    .asciiz "FAIL: bltzall did not link when NOT taken (link is unconditional)\n"
