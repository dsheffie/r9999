/*
 * test_cache_blk_fx.S  --  what the R10000 secondary-cache block ops DO (an
 * ENABLE_R10000 ooo_core; the L2 sequences the 128-byte block, l2.sv r_blk_*).
 *
 * Each case dirties the first word of all 8 lines of a 128-byte block AND of the
 * line just past it (memory holds OLD from the .data image, the caches get NEW),
 * runs the block op, then drops whatever is still cached WITHOUT writeback -- 0x13
 * on the block (L1D and L2) and 0x11 (L1D only) on all 9 lines -- and reloads, so
 * a line reads NEW only if the op put it in DRAM:
 *   1  0x17 Hit WB-Inv S              block NEW, next line OLD
 *   2  0x13 Hit Inv S                 block OLD, next line OLD
 *   3  0x03 + 0x03,1 Index WB-Inv     block NEW, next line OLD (both ways, as the kernel)
 * and on a block whose dirty lines were first evicted from the L1D into the L2 (a
 * load 16 KB away, the L1D size), so the L2's own dirty copy is the newest:
 *   4  0x17                           block NEW, next line NEW (0x11 leaves the L2's copy)
 *   5  0x13                           block OLD, next line NEW
 * (cases 1 and 3 lean on 0x13 dropping, which case 5 checks with the L1D out of
 * the way; case 2 alone would pass with a no-op 0x13)
 *
 * RTL SELF-CHECK ONLY (-c 0): the interpreter has no caches.
 */

#include "sim.h"

    .set    mips3
    .set    reorder
    .set    noat

    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

#define NEW 0xBBBB
#define OLD 0xAAAA

/* dirty word 0 of lines 0..8 of the block at $s0 */
    .macro  DIRTY9
    li      $t1, NEW
    .irp    off, 0,16,32,48,64,80,96,112,128
    sw      $t1, \off($s0)
    .endr
    .endm

/* drop the block at $s0 (0x13), and lines 0..8 from the L1D (0x11 = D Hit Inv) */
    .macro  DROP9
    cache   0x13, 0($s0)
    .irp    off, 0,16,32,48,64,80,96,112,128
    cache   0x11, \off($s0)
    .endr
    nop
    nop
    .endm

/* lines 0..7 must read \want, line 8 \want8; $s1 = case id on failure */
    .macro  CHECK9 want, want8
    li      $t2, \want
    .irp    off, 0,16,32,48,64,80,96,112
    lw      $v0, \off($s0)
    bne     $v0, $t2, fail
    .endr
    lw      $v0, 128($s0)
    li      $t2, \want8
    bne     $v0, $t2, fail
    .endm

/* push lines 0..8 of the block at $s0 out of the L1D into the L2 */
    .macro  EVICT9
    li      $t3, 16384
    addu    $t3, $s0, $t3
    .irp    off, 0,16,32,48,64,80,96,112,128
    lw      $zero, \off($t3)
    .endr
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

    li      $s1, 1
    la      $s0, blk0
    DIRTY9
    cache   0x17, 0($s0)
    DROP9
    CHECK9  NEW, OLD

    li      $s1, 2
    la      $s0, blk1
    DIRTY9
    cache   0x13, 0($s0)
    DROP9
    CHECK9  OLD, OLD

    li      $s1, 3
    la      $s0, blk2
    DIRTY9
    cache   0x03, 0($s0)
    cache   0x03, 1($s0)
    DROP9
    CHECK9  NEW, OLD

    /* L2-resident dirty lines: evict the block from the (16 KB, direct-mapped) L1D */
    li      $s1, 4
    la      $s0, blk3
    DIRTY9
    EVICT9
    cache   0x17, 0($s0)
    DROP9
    CHECK9  NEW, NEW

    li      $s1, 5
    la      $s0, blk4
    DIRTY9
    EVICT9
    cache   0x13, 0($s0)
    DROP9
    CHECK9  OLD, NEW

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
    SIMCON_PUTCHAR($t9)
    addiu   $a0, $a0, 1
    b       1b
2:  jr      $ra
    .size   puts_sim, . - puts_sim

    .data
    .align  7
blk0:
    .rept   64
    .word   OLD
    .endr
blk1:
    .rept   64
    .word   OLD
    .endr
blk2:
    .rept   64
    .word   OLD
    .endr
blk3:
    .rept   64
    .word   OLD
    .endr
blk4:
    .rept   64
    .word   OLD
    .endr
    .space  16384

    .section .rodata
msg_start: .asciz "test_cache_blk_fx: R10000 block CACHE op effects\n"
msg_pass:  .asciz "PASS\n"
msg_fail:  .asciz "FAIL\n"
