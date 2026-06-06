/*
 * test_dside_tlb.S  --  D-side TLB translation test
 *
 * Strategy: keep instructions in kseg0 (unmapped); exercise only the
 * data-side TLB.  Tests verify the TLB hit path for both loads and
 * stores, and check even- vs odd-page PFN selection.
 *
 *   Physical address used: 0x100000 / 0x101000
 *   kseg1 alias (uncached, unmapped): 0xA0100000 -> PA 0x100000
 *                                     0xA0101000 -> PA 0x101000
 *   kuseg VA under test:              0x00100000 -> TLB -> PA 0x100000 (even page)
 *                                     0x00101000 -> TLB -> PA 0x101000 (odd page)
 *
 * TLB entry installed at index 0:
 *   EntryHi  = 0x00100007   VPN2=0x80, ASID=7
 *   EntryLo0 = 0x0000401e   PFN=0x100, C=3, D=1, V=1, G=0
 *   EntryLo1 = 0x0000405e   PFN=0x101, C=3, D=1, V=1, G=0
 *   PageMask = 0            4 KB pages
 *
 * Tests:
 *   1. Load via TLB (even page): write via kseg1, verify with kuseg load.
 *      The kuseg load misses the cache and fetches from the TLB-translated PA,
 *      so this directly tests that pfn0 gives the right physical address.
 *   2. Store via TLB (even page): write via kuseg, read back via kuseg.
 *      The checker (RTL vs interpreter) validates the store hit the right PA.
 *   3. Load via TLB (odd page):  write via kseg1, verify with kuseg load.
 *      Tests pfn1 / VA[12]=1 path.
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

    /* ================================================================
     * Install TLB entry 0
     * ================================================================ */
    li      $t0, 0x00100007        /* EntryHi: VPN2=0x80, ASID=7 */
    mtc0    $t0, $10
    li      $t0, 0x0000401e        /* EntryLo0: PFN=0x100, C=3, D=1, V=1 */
    mtc0    $t0, $2
    li      $t0, 0x0000405e        /* EntryLo1: PFN=0x101, C=3, D=1, V=1 */
    mtc0    $t0, $3
    mtc0    $zero, $5              /* PageMask = 0 (4 KB) */
    mtc0    $zero, $0              /* Index = 0 */
    tlbwi

    /* ================================================================
     * Test 1: Load via TLB (even page, VA[12]=0 -> pfn0, PA 0x100000)
     *
     * Write via kseg1 (uncached, bypasses L1D) so data is in physical
     * memory.  Then load via kuseg: cache miss -> TLB lookup -> fetch
     * from TLB-translated PA.  If pfn0 is wrong the fetched data
     * won't match.
     * ================================================================ */
    la      $a0, msg_test1
    jal     sim_puts
    nop

    li      $t0, 0x12345678
    li      $t1, 0xa0100000        /* kseg1 -> PA 0x100000 */
    sw      $t0, 0($t1)

    li      $t2, 0x00100000        /* kuseg VA -> TLB -> PA 0x100000 */
    lw      $t3, 0($t2)
    bne     $t3, $t0, fail_load_even

    la      $a0, msg_test1_ok
    jal     sim_puts
    nop

    /* ================================================================
     * Test 2: Store via TLB (even page), then load via TLB.
     *
     * Write a new sentinel to a different offset (0x100010) via kuseg.
     * Read it back via kuseg.  The checker confirms both RTL and
     * interpreter agree the store reached the right location.
     * ================================================================ */
    la      $a0, msg_test2
    jal     sim_puts
    nop

    li      $t0, 0x0badf00d
    li      $t2, 0x00100010        /* kuseg VA -> PA 0x100010 */
    sw      $t0, 0($t2)            /* store through TLB */
    lw      $t3, 0($t2)            /* load through TLB */
    bne     $t3, $t0, fail_store_even

    la      $a0, msg_test2_ok
    jal     sim_puts
    nop

    /* ================================================================
     * Test 3: Load via TLB (odd page, VA[12]=1 -> pfn1, PA 0x101000)
     *
     * Same pattern as Test 1: write via kseg1, verify with kuseg load.
     * ================================================================ */
    la      $a0, msg_test3
    jal     sim_puts
    nop

    li      $t0, 0x55aa55aa
    li      $t1, 0xa0101000        /* kseg1 -> PA 0x101000 */
    sw      $t0, 0($t1)

    li      $t2, 0x00101000        /* kuseg VA (VA[12]=1 -> odd page) */
    lw      $t3, 0($t2)
    bne     $t3, $t0, fail_load_odd

    la      $a0, msg_test3_ok
    jal     sim_puts
    nop

    /* ================================================================
     * All passed
     * ================================================================ */
    la      $a0, msg_pass
    jal     sim_puts
    nop

    lw      $ra, 4($sp)
    addiu   $sp, $sp, 8
    SIM_PASS()

/* ---- failure paths ---- */
fail_load_even:
    la      $a0, msg_fail_load_even
    jal     sim_puts
    nop
    SIM_FAIL("D-TLB load (even page) wrong value")

fail_store_even:
    la      $a0, msg_fail_store_even
    jal     sim_puts
    nop
    SIM_FAIL("D-TLB store (even page) wrong value")

fail_load_odd:
    la      $a0, msg_fail_load_odd
    jal     sim_puts
    nop
    SIM_FAIL("D-TLB load (odd page) wrong value")

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
msg_start:          .asciz "D-side TLB test\n"
msg_test1:          .asciz "  Test 1: load via TLB (even page, pfn0)...\n"
msg_test1_ok:       .asciz "  Test 1: OK\n"
msg_test2:          .asciz "  Test 2: store+load via TLB (even page)...\n"
msg_test2_ok:       .asciz "  Test 2: OK\n"
msg_test3:          .asciz "  Test 3: load via TLB (odd page, pfn1)...\n"
msg_test3_ok:       .asciz "  Test 3: OK\n"
msg_pass:           .asciz "All D-side TLB tests passed.\n"
msg_fail_load_even: .asciz "FAIL: TLB load (even page)\n"
msg_fail_store_even:.asciz "FAIL: TLB store+load (even page)\n"
msg_fail_load_odd:  .asciz "FAIL: TLB load (odd page)\n"
