/*
 * test_sext32_kuseg.S -- 32-bit addressing mode must sign-extend EA[31:0].
 *
 * NT 3.1/MIPS (ntdll) reads its TEB at useg 0x7ffff4a8 as `lui t,0x8000; lw -0xb58(t)`.
 * lui sign-extends, so t = 0xffffffff_80000000 and the 64-bit AGU sum is
 * 0xffffffff_7ffff4a8: a useg address with hi32 set.  In 32-bit addressing mode
 * (here: kernel, KX=0) the R4000 uses the sign-extension of EA[31:0] = 0x7ffff4a8.
 * Before the fix mipsseg passed the 64-bit form to the TLB, which compares R and
 * VPN2 in full, so the access missed the user entry (TLB refill -> wrong page).
 *
 * Setup: TLB pair VPN2 0x7fffe000 -> PFN 0x300 / 0x301 (PA 0x300000 / 0x301000),
 * global, cached.  Marker at PA 0x3014a8 (via kseg1).  Then:
 *   1. load through the NT idiom must read the marker;
 *   2. store through it must land at PA 0x3014a8 (read back via kseg1).
 *
 * Self-checking via console; run under -c 1 (checker ISS has the same rule).
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
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

    /* 32-bit addressing: clear KX (SR bit 7) */
    mfc0    $t0, $12
    li      $t1, ~0x80
    and     $t0, $t0, $t1
    mtc0    $t0, $12
    nop
    nop

    /* marker at PA 0x3014a8 */
    li      $t1, 0xa03014a8
    li      $t0, 0x1234abcd
    sw      $t0, 0($t1)

    /* TLB entry 0: VPN2 0x7fffe000, even -> PFN 0x300, odd -> PFN 0x301 (C=3 D V G) */
    li      $t0, 0x7fffe000
    mtc0    $t0, $10
    li      $t0, 0x0000c01f
    mtc0    $t0, $2
    li      $t0, 0x0000c05f
    mtc0    $t0, $3
    mtc0    $zero, $5
    mtc0    $zero, $0
    nop
    tlbwi
    nop
    nop

    /* 1: load via the NT idiom: base 0xffffffff_80000000, offset -0xb58 */
    lui     $t2, 0x8000
    lw      $t3, -0xb58($t2)
    li      $t0, 0x1234abcd
    bne     $t3, $t0, fail_ld
    nop

    /* 2: store via the same form, check it landed at PA 0x3014a8 */
    li      $t0, 0x5a5a1234
    sw      $t0, -0xb58($t2)
    lw      $t4, -0xb58($t2)            /* and reads back through the TLB */
    bne     $t4, $t0, fail_st
    nop
    cache   0x15, -0xb58($t2)           /* Hit_WB_Inv_D: push it to memory */
    nop
    li      $t1, 0xa03014a8
    lw      $t5, 0($t1)
    bne     $t5, $t0, fail_st
    nop

    la      $a0, msg_pass
    jal     sim_puts
    nop
    SIM_PASS()

fail_ld: la $a0, msg_fld; jal sim_puts; nop; SIM_FAIL("load via non-canonical useg EA")
fail_st: la $a0, msg_fst; jal sim_puts; nop; SIM_FAIL("store via non-canonical useg EA")
    .size   main, . - main

    .type   sim_puts, @function
sim_puts:
1:  lb      $t9, 0($a0)
    beqz    $t9, 2f
    nop
    SIMCON_PUTCHAR($t9)
    addiu   $a0, $a0, 1
    b       1b
    nop
2:  jr      $ra
    nop
    .size   sim_puts, . - sim_puts

    .section .rodata
msg_start: .asciz "32-bit mode EA sign-extension (NT TEB idiom) test\n"
msg_pass:  .asciz "  sext32 OK (lui 0x8000; lw -0xb58 hit useg 0x7ffff4a8)\n"
msg_fld:   .asciz "FAIL: load via 0xffffffff7ffff4a8 missed useg 0x7ffff4a8\n"
msg_fst:   .asciz "FAIL: store via 0xffffffff7ffff4a8 did not land at PA 0x3014a8\n"
