/*
 * test_iside_alias.S -- directed VIPT L1I false-hit (alias) test.
 *
 * The I-cache alias bug is a FALSE HIT (not a synonym): two DIFFERENT physical
 * code lines that differ only in an alias bit (PA[12]) sit in the SAME VIPT set
 * when VA[12] matches.  If the tag does not carry the alias bits (cache > page),
 * the second fetch matches the first's tag -> executes the WRONG code.
 *
 * Setup (runtime, no linker tricks):
 *   - write stub A to PA 0x300000 (kseg1 uncached): ori $v0,$0,0xAAAA; jr $ra; nop
 *   - write stub B to PA 0x301000 (differs from A only in PA[12]): ...0xBBBB...
 *   - TLB:  VA_a 0x00400000 -> PA 0x300000   (VA[12]=0)
 *           VA_b 0x00402000 -> PA 0x301000   (VA[12]=0, SAME 8KB index; PA[12] differs)
 *
 * Call VA_a (fills the shared I-cache set, tag from PA_a).  Call VA_b: at <=4KB
 * the tag includes PA[12] -> miss -> fetch B -> 0xBBBB (PASS).  At >=8KB a naive
 * VIPT L1I drops PA[12] from the tag -> VA_b FALSE-HITS A's line -> runs A ->
 * 0xAAAA (FAIL).  So this PASSES at 4KB and is the real L1I alias test at >=8KB.
 *
 * Self-checking (SIM_PASS/SIM_FAIL); run under -c 0.
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

    .macro  TLBW idx, ehi, elo0, elo1
    li      $t0, \ehi
    mtc0    $t0, $10
    li      $t0, \elo0
    mtc0    $t0, $2
    li      $t0, \elo1
    mtc0    $t0, $3
    mtc0    $zero, $5
    li      $t0, \idx
    mtc0    $t0, $0
    tlbwi
    nop
    .endm

/* write a 3-word stub {ori $v0,$0,imm; jr $ra; nop} to kseg1 addr (uncached) */
    .macro  WRSTUB k1, oriword
    li      $t1, \k1
    li      $t0, \oriword
    sw      $t0, 0($t1)
    li      $t0, 0x03e00008        /* jr $ra */
    sw      $t0, 4($t1)
    sw      $zero, 8($t1)          /* nop (delay slot) */
    .endm

    .text
    .globl  main
    .type   main, @function
main:
    addiu   $sp, $sp, -8
    sw      $ra, 4($sp)

    la      $a0, msg_start
    jal     sim_puts
    nop

    /* place two distinct code stubs at PA 0x300000 and 0x301000 (differ in PA[12]) */
    WRSTUB  0xa0300000, 0x3402aaaa    /* ori $v0,$0,0xAAAA */
    WRSTUB  0xa0301000, 0x3402bbbb    /* ori $v0,$0,0xBBBB */

    /* TLB: VA_a even-page -> PFN 0x300 ; VA_b even-page -> PFN 0x301 */
    TLBW    0, 0x00400000, 0x0000c01f, 0x00000001   /* VPN2=0x200 -> PA 0x300000 */
    TLBW    1, 0x00402000, 0x0000c05f, 0x00000001   /* VPN2=0x201 -> PA 0x301000 */

    /* call VA_a -> must return 0xAAAA */
    li      $t9, 0x00400000
    jalr    $t9
    nop
    li      $t5, 0x0000aaaa
    bne     $v0, $t5, fail_a
    nop

    /* call VA_b -> must return 0xBBBB (aliasing false-hit -> 0xAAAA) */
    li      $t9, 0x00402000
    jalr    $t9
    nop
    li      $t5, 0x0000bbbb
    bne     $v0, $t5, fail_b
    nop

    la      $a0, msg_pass
    jal     sim_puts
    nop
    SIM_PASS()

fail_a: la $a0, msg_fa; jal sim_puts; nop; SIM_FAIL("VA_a fetched wrong code")
fail_b: la $a0, msg_fb; jal sim_puts; nop; SIM_FAIL("L1I false-hit: VA_b ran VA_a's line")
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
msg_start: .asciz "VIPT L1I false-hit (alias) test\n"
msg_pass:  .asciz "  L1I alias OK (VA_b ran its own code)\n"
msg_fa:    .asciz "FAIL: VA_a returned wrong value\n"
msg_fb:    .asciz "FAIL: L1I false-hit -- VA_b ran VA_a code (alias)\n"
