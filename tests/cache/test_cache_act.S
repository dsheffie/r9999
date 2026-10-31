/*
 * test_cache_act.S  --  the CACHE decode tables (decode_mips.sv r4400_cache_act /
 * r10k_cache_act, chosen by ENABLE_R10000) on the encodings where they differ.
 *
 * Each case dirties its own cached word (memory holds OLD from the .data image,
 * the L1D gets NEW), runs the CACHE op under test, then D-Hit-Invalidate (0x11,
 * the same on both CPUs) to drop the line WITHOUT writeback, and reloads:
 *   the op wrote the line back -> the reload sees NEW
 *   the op was a NOP           -> the dirty NEW is discarded, the reload sees OLD
 *
 *   op    R4400 (default build)          R10000 (-DR10K, ENABLE_R10000 build)
 *   0x01  Index WB-Inv D      -> NEW     Index WB-Inv D         -> NEW
 *   0x05  Index Load Tag D    -> NEW *   Index Load Tag D (NOP) -> OLD
 *   0x14  Fill I              -> OLD     cache barrier (NOP)    -> OLD
 *   0x17  Hit WB-Inv S        -> NEW     Hit WB-Inv S           -> NEW
 *   0x19  Hit WB D            -> NEW     Index Load Data D (NOP)-> OLD
 *   0x1d  Hit Set Virtual D   -> NEW *   Index Store Data D(NOP)-> OLD
 *   (* r9999 runs every other R4400 D op as a one-line writeback)
 * Then all 32 encodings once each on a scratch line: none may fault.
 *
 * Build: test_cache_act.elf (R4400 expectations) and test_cache_act_r10k.elf
 * (-DR10K).  RTL SELF-CHECK ONLY (-c 0): the interpreter has no caches, so it
 * would read NEW everywhere.
 */

#include "sim.h"

    .set    mips3
    .set    reorder
    .set    noat

/* Magic-halt: -c 0 (no-checker) runs stop on a write to kseg1 0xBFD00000. */
    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

/* dirty word \off of `scratch`, run `cache \op`, drop the line, expect \want */
    .macro  CASE op, off, want
    la      $s0, scratch
    addiu   $s0, $s0, \off
    li      $t1, 0xBBBB
    sw      $t1, 0($s0)
    cache   \op, 0($s0)
    nop
    nop
    nop
    cache   0x11, 0($s0)
    nop
    nop
    nop
    lw      $v0, 0($s0)
    li      $t2, \want
    li      $s1, \op
    bne     $v0, $t2, fail
    nop
    .endm

#define NEW 0xBBBB
#define OLD 0xAAAA
#ifdef R10K
#define R4K_OR_R10K(a, b) b
#else
#define R4K_OR_R10K(a, b) a
#endif

    .text
    .globl  main
    .type   main, @function
main:
    addiu   $sp, $sp, -8
    sw      $ra, 4($sp)

    la      $a0, msg_start
    jal     puts_sim
    nop

    CASE    0x01, 0,   NEW
    CASE    0x05, 64,  R4K_OR_R10K(NEW, OLD)
    CASE    0x14, 128, OLD
    CASE    0x17, 192, NEW
    CASE    0x19, 256, R4K_OR_R10K(NEW, OLD)
    CASE    0x1d, 320, R4K_OR_R10K(NEW, OLD)

    /* every encoding once: none may fault */
    la      $s0, spare
    .irp    op, 0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f
    cache   \op, 0($s0)
    .endr
    nop
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

    .data
    .align  6
scratch:
    .rept   (6 * 16)
    .word   0xAAAA
    .endr
    .align  6
spare:
    .rept   16
    .word   0
    .endr

    .section .rodata
msg_start: .asciz "test_cache_act: CACHE decode table\n"
msg_pass:  .asciz "PASS\n"
msg_fail:  .asciz "FAIL\n"
