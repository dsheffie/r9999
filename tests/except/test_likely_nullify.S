/*
 * test_likely_nullify.S -- every branch-likely form, NOT taken (delay slot must be
 *                          nullified) and taken (delay slot must execute).
 *
 * WHY THIS EXISTS
 * exec.sv's BNEL had its `|| !t_take_br' restart commented out since the initial
 * import.  That restart is what nullifies a branch-likely's delay slot when the
 * branch falls through; every other likely form had it.  It stayed hidden while
 * predecode predicted every branch-likely taken (a not-taken one then mispredicted
 * and restarted anyway).  Once the predictor can learn not-taken, a correctly
 * predicted not-taken bnel lets its delay slot execute.
 *
 * Each case loops 64 times with a fixed outcome so the predictor trains on it; the
 * delay slot bumps a marker, which must end at 0 (not taken) or 64 (taken).
 * Covers BEQL, BNEL, BLEZL, BGTZL, BLTZL, BGEZL and the $zero-compare forms decode
 * turns into BEQZL / BNEZL.
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

    .macro  FAILM msg
    la      $a0, \msg
    jal     sim_puts
    nop
    HALT
    .endm

/* not taken: 64 iterations, the delay slot must never execute */
    .macro  NOTTAKEN2 br, a, b, msg
    li      $s0, 0
    li      $s2, 64
loop\@:
    \br     \a, \b, tgt\@
    addiu   $s0, $s0, 1                 /* delay slot: must be nullified */
    addiu   $s2, $s2, -1
    bne     $s2, $zero, loop\@
    nop
    bne     $s0, $zero, bad\@
    nop
    b       done\@
    nop
bad\@:
    FAILM   \msg
tgt\@:
    FAILM   msg_taken                   /* not-taken branch went to its target */
done\@:
    .endm

    .macro  NOTTAKEN1 br, a, msg
    li      $s0, 0
    li      $s2, 64
loop\@:
    \br     \a, tgt\@
    addiu   $s0, $s0, 1                 /* delay slot: must be nullified */
    addiu   $s2, $s2, -1
    bne     $s2, $zero, loop\@
    nop
    bne     $s0, $zero, bad\@
    nop
    b       done\@
    nop
bad\@:
    FAILM   \msg
tgt\@:
    FAILM   msg_taken                   /* not-taken branch went to its target */
done\@:
    .endm

/* taken: 64 iterations, the delay slot must execute every time */
    .macro  TAKEN2 br, a, b, msg
    li      $s0, 0
    li      $s2, 64
loop\@:
    \br     \a, \b, tgt\@
    addiu   $s0, $s0, 1                 /* delay slot: taken => executes */
    FAILM   msg_fell                    /* taken branch fell through */
tgt\@:
    addiu   $s2, $s2, -1
    bne     $s2, $zero, loop\@
    nop
    li      $t9, 64
    beq     $s0, $t9, done\@
    nop
    FAILM   \msg
done\@:
    .endm

    .macro  TAKEN1 br, a, msg
    li      $s0, 0
    li      $s2, 64
loop\@:
    \br     \a, tgt\@
    addiu   $s0, $s0, 1                 /* delay slot: taken => executes */
    FAILM   msg_fell                    /* taken branch fell through */
tgt\@:
    addiu   $s2, $s2, -1
    bne     $s2, $zero, loop\@
    nop
    li      $t9, 64
    beq     $s0, $t9, done\@
    nop
    FAILM   \msg
done\@:
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

    li      $t0, 1
    li      $t1, 2
    li      $t2, 0
    li      $t3, -1
    li      $t4, 1

    NOTTAKEN2 beql, $t0, $t1, msg_beql      /* 1 == 2  : no */
    NOTTAKEN2 bnel, $t0, $t4, msg_bnel      /* 1 != 1  : no */
    NOTTAKEN2 beql, $t0, $zero, msg_beqzl     /* BEQZL: 1 == 0 : no */
    NOTTAKEN2 bnel, $t2, $zero, msg_bnezl     /* BNEZL: 0 != 0 : no */
    NOTTAKEN1 blezl, $t0, msg_blezl     /* 1 <= 0  : no */
    NOTTAKEN1 bgtzl, $t2, msg_bgtzl     /* 0 > 0   : no */
    NOTTAKEN1 bltzl, $t2, msg_bltzl     /* 0 < 0   : no */
    NOTTAKEN1 bgezl, $t3, msg_bgezl     /* -1 >= 0 : no */

    TAKEN2 beql, $t0, $t4, msg_t_beql
    TAKEN2 bnel, $t0, $t1, msg_t_bnel
    TAKEN2 beql, $t2, $zero, msg_t_beqzl
    TAKEN2 bnel, $t0, $zero, msg_t_bnezl
    TAKEN1 blezl, $t2, msg_t_blezl
    TAKEN1 bgtzl, $t0, msg_t_bgtzl
    TAKEN1 bltzl, $t3, msg_t_bltzl
    TAKEN1 bgezl, $t2, msg_t_bgezl

    la      $a0, msg_pass
    jal     sim_puts
    nop
    HALT

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
msg_start:   .asciiz "branch-likely nullify test\n"
msg_pass:    .asciiz "PASS: all branch-likely forms nullify / execute their delay slot correctly\n"
msg_taken:   .asciiz "FAIL: a not-taken branch-likely went to its target\n"
msg_fell:    .asciiz "FAIL: a taken branch-likely fell through\n"
msg_beql:    .asciiz "FAIL: beql not taken executed its delay slot\n"
msg_bnel:    .asciiz "FAIL: bnel not taken executed its delay slot\n"
msg_beqzl:   .asciiz "FAIL: beqzl not taken executed its delay slot\n"
msg_bnezl:   .asciiz "FAIL: bnezl not taken executed its delay slot\n"
msg_blezl:   .asciiz "FAIL: blezl not taken executed its delay slot\n"
msg_bgtzl:   .asciiz "FAIL: bgtzl not taken executed its delay slot\n"
msg_bltzl:   .asciiz "FAIL: bltzl not taken executed its delay slot\n"
msg_bgezl:   .asciiz "FAIL: bgezl not taken executed its delay slot\n"
msg_t_beql:  .asciiz "FAIL: beql taken: delay slot count != 64\n"
msg_t_bnel:  .asciiz "FAIL: bnel taken: delay slot count != 64\n"
msg_t_beqzl: .asciiz "FAIL: beqzl taken: delay slot count != 64\n"
msg_t_bnezl: .asciiz "FAIL: bnezl taken: delay slot count != 64\n"
msg_t_blezl: .asciiz "FAIL: blezl taken: delay slot count != 64\n"
msg_t_bgtzl: .asciiz "FAIL: bgtzl taken: delay slot count != 64\n"
msg_t_bltzl: .asciiz "FAIL: bltzl taken: delay slot count != 64\n"
msg_t_bgezl: .asciiz "FAIL: bgezl taken: delay slot count != 64\n"
