/* test_l1i_probe.S -- L1I misses evicting DIRTY L1D lines from the L2
 * (inclusive-l2-v2 stage B: the L2 must back-invalidate the L1D first).
 *
 * `target` is a 64-line (1 KB) straight-line leaf function.  Data line D_i sits exactly
 * 128 KB above code line T_i, so D_i and T_i share an L2 set (any L2 of 128 KB or less,
 * direct-mapped) and an L1 set.  Each round:
 *   1. store a round-tagged value to every D_i      -> D_i dirty in the L1D, and the L1D
 *      fill made D_i the L2's line for that set (pd set)
 *   2. Hit_Invalidate_I on target                   -> the next fetch misses the L1I
 *   3. call target: each T_i fetch misses the L2, which evicts D_i (pd) on behalf of the
 *      L1I -> stage B probes the L1D, gets D_i's dirty data back, writes it to DRAM
 *   4. verify D_i via the UNCACHED alias (DRAM) and the cached alias; v0 must be 255
 * With the probe, the L1D no longer holds D_i after step 3 (the shadow check in
 * core_l1d_l1i must report 0 lines missing from the L2).  Without it (stage A) the run
 * still passes -- the L1D keeps its dirty copy and DRAM converges later -- but the shadow
 * check reports L1D lines missing from the L2: that is the negative control.
 *
 * -c0 self-check, -c1 co-sim.   ../../ooo_core -c1 -f test_l1i_probe.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    move  $s7, $ra
    la    $s0, target           /* kseg0 VA of T_0 */
    lui   $t0, 0x0002           /* +128 KB: same L2 set, same L1 set */
    addu  $s1, $s0, $t0         /* D_0, cached */
    lui   $t0, 0x2000
    or    $s2, $s1, $t0         /* D_0 via kseg1 (uncached, DRAM) */
    li    $s3, 64               /* lines */
    li    $s4, 1                /* round */
    li    $s5, 9                /* rounds + 1 */

round:
    /* 1. dirty every D_i in the L1D: value = (round << 16) | i */
    move  $t2, $s1
    li    $t3, 0
1:  sll   $t4, $s4, 16
    or    $t4, $t4, $t3
    sw    $t4, 0($t2)
    addiu $t2, $t2, 16
    addiu $t3, $t3, 1
    bne   $t3, $s3, 1b
    nop

    /* 2. make the next fetch of target miss the L1I */
    cache 0x10, 0($s0)          /* Hit_Invalidate_I */

    /* 3. execute target: 64 L1I line misses, each evicting a dirty D_i from the L2 */
    move  $v0, $zero
    jalr  $s0
    nop
    li    $t4, 255
    bne   $v0, $t4, fail
    nop

    /* 4. verify every D_i, from DRAM (uncached) and through the caches */
    move  $t2, $s2
    move  $t5, $s1
    li    $t3, 0
2:  sll   $t4, $s4, 16
    or    $t4, $t4, $t3
    lw    $t6, 0($t2)
    bne   $t6, $t4, fail
    nop
    lw    $t6, 0($t5)
    bne   $t6, $t4, fail
    nop
    addiu $t2, $t2, 16
    addiu $t5, $t5, 16
    addiu $t3, $t3, 1
    bne   $t3, $s3, 2b
    nop

    addiu $s4, $s4, 1
    bne   $s4, $s5, round
    nop

    SIMCON_PUTLIT(0x50)
    SIMCON_PUTLIT(0x41)
    SIMCON_PUTLIT(0x53)
    SIMCON_PUTLIT(0x53)
    SIMCON_PUTLIT(0x0a)
    move  $ra, $s7
    break
fail:
    SIMCON_PUTLIT(0x46)
    SIMCON_PUTLIT(0x41)
    SIMCON_PUTLIT(0x49)
    SIMCON_PUTLIT(0x4c)
    SIMCON_PUTLIT(0x0a)
    break
    .size main, .-main

    /* 64 lines of straight-line code: 255 increments, then return */
    .align 4
    .globl target
    .type  target, @function
target:
    .rept 255
    addiu $v0, $v0, 1
    .endr
    jr    $ra
    nop
    .size target, .-target
