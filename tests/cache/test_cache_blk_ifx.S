/*
 * test_cache_blk_ifx.S  --  R10000 block ops invalidate the block in the L1I too (the
 * L2 has the L1I clear it, l1i.sv blk_inv_*): the L1I is not covered by the L2's
 * inclusion, so without that a patched function keeps running its old code.
 *
 * Each case runs a function on line 5 of its own 128-byte block (it lands in the
 * L1I), patches its `li v0, 1' to `li v0, 2' (the store sits dirty in the L1D),
 * runs the block op on the block, then an mtc0 (serializing: fetch restarts after
 * it, so nothing behind the op was fetched early) and calls the function again:
 *   1  0x17 Hit WB-Inv S              v0 = 2
 *   2  0x03 + 0x03,1 Index WB-Inv     v0 = 2
 *
 * RTL SELF-CHECK ONLY (-c 0), ENABLE_R10000 ooo_core.
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

#define LI_V0_2 0x24020002          /* addiu v0, zero, 2 */

    .macro  CASE id, fn, op1, op2
    li      $s1, \id
    jal     \fn                     /* into the L1I */
    nop
    li      $t2, 1
    bne     $v0, $t2, fail
    nop
    la      $s0, \fn
    li      $t1, LI_V0_2
    sw      $t1, 0($s0)
    srl     $s2, $s0, 7
    sll     $s2, $s2, 7             /* the block */
    cache   \op1, 0($s2)
    .ifnb   \op2
    cache   \op2, 1($s2)
    .endif
    mfc0    $t0, $12
    mtc0    $t0, $12                /* refetch from here on */
    nop
    nop
    jal     \fn
    nop
    li      $t2, 2
    bne     $v0, $t2, fail
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

    CASE    1, fn_a, 0x17
    CASE    2, fn_b, 0x03, 0x03

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

    /* each function on line 5 of its own block */
    .align  7
    .space  0x50
fn_a:
    li      $v0, 1
    jr      $ra
    nop
    .align  7
    .space  0x50
fn_b:
    li      $v0, 1
    jr      $ra
    nop

    .section .rodata
msg_start: .asciz "test_cache_blk_ifx: R10000 block ops invalidate the L1I\n"
msg_pass:  .asciz "PASS\n"
msg_fail:  .asciz "FAIL\n"
