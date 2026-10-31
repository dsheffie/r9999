/*
 * test_uc_l1d_alias.S  --  an uncached access to a line the L1D holds dirty (l2.sv: the
 * L2 probes the L1D copy out before dropping its own, reason 8).  Without the probe the
 * L2 dropped a line the L1D kept: the uncached load read stale DRAM, and inclusion was
 * broken, so a later block op missed the line in the L2 and never flushed the L1D.
 *
 *   1  cached store NEW (dirty in the L1D), uncached load of the same PA -> NEW
 *   2  cached store NEW2 again (the line is back in the L1D and the L2), then
 *      0x17 on its block, then 0x13 (drop anything cached) and an uncached load -> NEW2
 *      (only if the 0x17 found the line and wrote the L1D copy back)
 *   3  the line CLEAN in the L1D, an uncached load of it (the IRIX case: [l2-pd-drop]
 *      opcode 4), then new data in DRAM behind the caches (an uncached store, standing
 *      in for a DMA), then 0x13 on the block -- the kernel's invalidate after a DMA --
 *      and a cached load -> the new data (only if the L1D copy is gone: either the
 *      uncached load probed it out, or the 0x13 still found the line in the L2)
 *   4  as 3, but the line cached at ANOTHER colour: a mapped VA 0x1000 (va[13:12] = 01,
 *      test_l1_synonym's mapping) of PA 0x00300000, whose kseg1 alias indexes colour
 *      00.  The L1D's own uncached check looks in the colour-00 set and misses, so only
 *      the L2's probe at pidx can remove the copy -> the new data, or the stale one.
 *      (Cases 1-3 pass either way: the L1D drops a same-colour copy itself.)
 *
 * RTL SELF-CHECK ONLY (-c 0), ENABLE_R10000 ooo_core; also grep the run for [l2-pd-drop].
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

    .text
    .globl  main
    .type   main, @function
main:
    addiu   $sp, $sp, -8
    sw      $ra, 4($sp)

    la      $a0, msg_start
    jal     puts_sim
    nop

    la      $s0, line              /* kseg0 */
    li      $t0, 0x20000000
    or      $s2, $s0, $t0          /* kseg1 alias of the same PA */

    li      $s1, 1
    lw      $t8, 0($s0)          /* the line into the L1D (and the L2, pd) */
    li      $t1, 0xBBBB
    sw      $t1, 0($s0)            /* dirty in the L1D */
    lw      $v0, 0($s2)            /* uncached */
    bne     $v0, $t1, fail
    nop

    li      $s1, 2
    lw      $t8, 0($s0)
    li      $t1, 0xCCCC
    sw      $t1, 0($s0)            /* dirty in the L1D again */
    cache   0x17, 0($s0)           /* Hit WB-Inv S: must find it */
    cache   0x13, 0($s0)           /* drop whatever is cached */
    lw      $v0, 0($s2)            /* uncached: DRAM */
    bne     $v0, $t1, fail
    nop

    li      $s1, 3
    la      $s0, line2
    or      $s2, $s0, $t0
    lw      $t8, 0($s0)          /* clean in the L1D (and the L2, pd) */
    lw      $t8, 0($s2)          /* uncached load of the same line */
    li      $t1, 0xDDDD
    sw      $t1, 0($s2)            /* new data in DRAM, behind the caches */
    cache   0x13, 0($s0)           /* the kernel's invalidate after a DMA */
    lw      $v0, 0($s0)            /* cached */
    bne     $v0, $t1, fail
    nop

    li      $s1, 4
    mfc0    $t0, $12
    li      $t2, ~4
    and     $t0, $t0, $t2
    mtc0    $t0, $12                /* clear ERL: with it set, kuseg is unmapped and uncached */
    nop
    nop
    mtc0    $zero, $10              /* EntryHi: VPN2 0 (VA 0x0000/0x1000), ASID 0 */
    li      $t0, 0x0000001f         /* EntryLo0: PFN 0, C=3,D=1,V=1,G=1 (unused) */
    mtc0    $t0, $2
    li      $t0, 0x0000c01f         /* EntryLo1: PFN 0x300 -> VA 0x1000, C=3 (cacheable) */
    mtc0    $t0, $3
    mtc0    $zero, $5               /* PageMask: 4 KB */
    mtc0    $zero, $0               /* Index 0 */
    tlbwi
    nop
    nop
    li      $s0, 0x00001000         /* mapped, colour 01 */
    li      $s2, 0xa0300000         /* the same PA through kseg1: colour 00 */
    li      $t1, 0x1111
    sw      $t1, 0($s2)             /* seed DRAM */
    lw      $t8, 0($s0)           /* clean in the L1D at colour 01 */
    lw      $t8, 0($s2)           /* uncached, indexes colour 00 */
    li      $t1, 0xEEEE
    sw      $t1, 0($s2)             /* new data in DRAM, behind the caches */
    cache   0x13, 0($s0)            /* the kernel's invalidate after a DMA */
    lw      $v0, 0($s0)             /* cached through the mapping */
    bne     $v0, $t1, fail
    nop

    la      $a0, msg_pass
    jal     puts_sim
    nop
    HALT

fail:
    addiu   $t9, $s1, 0x30
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

    .data
    .align  7
line:
    .rept   32
    .word   0xAAAA
    .endr
    .align  7
line2:
    .rept   32
    .word   0xAAAA
    .endr

    .section .rodata
msg_start: .asciz "test_uc_l1d_alias: uncached access to an L1D-dirty line\n"
msg_pass:  .asciz "PASS\n"
msg_fail:  .asciz "FAIL\n"
