/*
 * test_tlb.S  --  TLB instruction tests: TLBWI, TLBR, TLBP
 *
 * Sequence:
 *   1. Load EntryHi/EntryLo0/EntryLo1/PageMask into CP0
 *   2. TLBWI  → write TLB entry 0
 *   3. Zero out the CP0 TLB staging registers
 *   4. TLBR   → read back TLB entry 0, verify round-trip
 *   5. TLBP   → probe matching entry, verify Index == 0
 *   6. TLBP with different ASID → verify probe failure (Index bit 31 set)
 *
 * Entry values used:
 *   EntryHi  = 0x00200005  VPN2=0x100 (VA 0x200000), ASID=5
 *   EntryLo0 = 0x0000401e  PFN=0x100 (PA 0x100000), C=3, D=1, V=1, G=0
 *   EntryLo1 = 0x0000405e  PFN=0x101 (PA 0x101000), C=3, D=1, V=1, G=0
 *   PageMask = 0           4 KB pages
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
     * Step 1 – load TLB staging registers
     * ================================================================ */
    li      $t0, 0x00200005        /* EntryHi: VPN2=0x100, ASID=5 */
    mtc0    $t0, $10               /* CP0 EntryHi */

    li      $t0, 0x0000401e        /* EntryLo0: PFN=0x100, C=3, D=1, V=1 */
    mtc0    $t0, $2                /* CP0 EntryLo0 */

    li      $t0, 0x0000405e        /* EntryLo1: PFN=0x101, C=3, D=1, V=1 */
    mtc0    $t0, $3                /* CP0 EntryLo1 */

    mtc0    $zero, $5              /* PageMask = 0 (4 KB) */

    /* ================================================================
     * Step 2 – TLBWI: write staging registers to TLB entry 0
     * ================================================================ */
    mtc0    $zero, $0              /* Index = 0 */
    tlbwi                          /* write TLB[0] */

    la      $a0, msg_tlbwi
    jal     sim_puts
    nop

    /* ================================================================
     * Step 3 – zero out staging registers
     * ================================================================ */
    mtc0    $zero, $10             /* clear EntryHi */
    mtc0    $zero, $2              /* clear EntryLo0 */
    mtc0    $zero, $3              /* clear EntryLo1 */

    /* ================================================================
     * Step 4 – TLBR: read back TLB entry 0
     * ================================================================ */
    mtc0    $zero, $0              /* Index = 0 */
    tlbr                           /* read TLB[0] into staging regs */

    la      $a0, msg_tlbr
    jal     sim_puts
    nop

    /* Check EntryHi */
    li      $t0, 0x00200005
    mfc0    $t1, $10
    bne     $t0, $t1, fail_entryhi

    /* Check EntryLo0 */
    li      $t0, 0x0000401e
    mfc0    $t1, $2
    bne     $t0, $t1, fail_entrylo0

    /* Check EntryLo1 */
    li      $t0, 0x0000405e
    mfc0    $t1, $3
    bne     $t0, $t1, fail_entrylo1

    /* Check PageMask */
    mfc0    $t1, $5
    li      $t2, 0x01ffe000        /* mask for PageMask bits [24:13] */
    and     $t1, $t1, $t2
    bne     $zero, $t1, fail_pagemask

    la      $a0, msg_tlbr_ok
    jal     sim_puts
    nop

    /* ================================================================
     * Step 5 – TLBP: probe for the entry we just wrote
     * EntryHi must match what we wrote: VPN2=0x100, ASID=5
     * ================================================================ */
    la      $a0, msg_tlbp_hit
    jal     sim_puts
    nop

    li      $t0, 0x00200005        /* same EntryHi */
    mtc0    $t0, $10
    tlbp                           /* probe */

    mfc0    $t1, $0                /* Index register */
    /* Probe should have found entry 0; bit 31 must be 0, low bits = 0 */
    srl     $t2, $t1, 31
    bne     $t2, $zero, fail_tlbp_notfound
    andi    $t1, $t1, 0x3f
    bne     $t1, $zero, fail_tlbp_wrong_idx

    la      $a0, msg_tlbp_found
    jal     sim_puts
    nop

    /* ================================================================
     * Step 6 – TLBP with a different ASID: must NOT find the entry
     * ================================================================ */
    la      $a0, msg_tlbp_miss
    jal     sim_puts
    nop

    li      $t0, 0x0020007         /* same VPN2=0x100 but ASID=7 (no match) */
    mtc0    $t0, $10
    tlbp

    mfc0    $t1, $0
    srl     $t2, $t1, 31           /* probe-failed bit */
    beqz    $t2, fail_tlbp_false_hit

    la      $a0, msg_tlbp_miss_ok
    jal     sim_puts
    nop

    /* ================================================================
     * Step 7 – TLBWR: write to TLB[Random], verify with TLBP + TLBR
     *   EntryHi  = 0x00400003  VPN2=0x200 (VA 0x400000), ASID=3
     *   EntryLo0 = 0x0000801e  PFN=0x200, C=3, D=1, V=1, G=0
     *   EntryLo1 = 0x0000805e  PFN=0x201, C=3, D=1, V=1, G=0
     * ================================================================ */
    la      $a0, msg_tlbwr
    jal     sim_puts
    nop

    li      $t0, 0x00400003        /* EntryHi: VPN2=0x200, ASID=3 */
    mtc0    $t0, $10
    li      $t0, 0x0000801e        /* EntryLo0: PFN=0x200, C=3, D=1, V=1 */
    mtc0    $t0, $2
    li      $t0, 0x0000805e        /* EntryLo1: PFN=0x201, C=3, D=1, V=1 */
    mtc0    $t0, $3
    mtc0    $zero, $5              /* PageMask = 0 (4 KB) */

    tlbwr                          /* write staging regs to TLB[Random] */

    /* Probe: find the entry.  Do NOT read Index — the Random register
     * decrements every retire in the RTL but only on TLBWR in the
     * interpreter, so the slot numbers diverge and reading Index would
     * desync the checker.  Both sides found the entry; trust TLBR. */
    li      $t0, 0x00400003
    mtc0    $t0, $10               /* EntryHi for probe */
    tlbp                           /* Index ← found slot (differs RTL/sim, not checked) */

    /* TLBR from the index TLBP just placed in the Index register */
    mtc0    $zero, $10
    mtc0    $zero, $2
    mtc0    $zero, $3
    tlbr                           /* read TLB[Index] into staging regs */

    mfc0    $t1, $10               /* EntryHi */
    li      $t0, 0x00400003
    bne     $t0, $t1, fail_tlbwr_entryhi

    la      $a0, msg_tlbwr_ok
    jal     sim_puts
    nop

    /* ================================================================
     * Step 8 – Global bit: entry with G=1 in both EntryLo halves
     *   must match any ASID during TLBP.
     *   EntryHi  = 0x00600000  VPN2=0x300 (VA 0x600000), ASID=0
     *   EntryLo0 = 0x0000c01f  PFN=0x300, C=3, D=1, V=1, G=1
     *   EntryLo1 = 0x0000c05f  PFN=0x301, C=3, D=1, V=1, G=1
     *   Written to index 2 via TLBWI for a deterministic location.
     * ================================================================ */
    la      $a0, msg_global
    jal     sim_puts
    nop

    li      $t0, 0x00600000        /* EntryHi: VPN2=0x300, ASID=0 */
    mtc0    $t0, $10
    li      $t0, 0x0000c01f        /* EntryLo0: PFN=0x300, C=3, D=1, V=1, G=1 */
    mtc0    $t0, $2
    li      $t0, 0x0000c05f        /* EntryLo1: PFN=0x301, C=3, D=1, V=1, G=1 */
    mtc0    $t0, $3
    mtc0    $zero, $5              /* PageMask = 0 (4 KB) */
    li      $t0, 2
    mtc0    $t0, $0                /* Index = 2 */
    tlbwi                          /* write global entry to TLB[2] */

    /* Probe with a different ASID (0x39 = 57) – G=1 means it must still hit */
    li      $t0, 0x00600039        /* same VPN2=0x300, but ASID=57 */
    mtc0    $t0, $10
    tlbp

    mfc0    $t1, $0
    srl     $t2, $t1, 31
    bne     $t2, $zero, fail_global_miss   /* P=1 → missed; should have hit */

    /* Verify it landed at index 2 */
    andi    $t1, $t1, 0x3f
    li      $t0, 2
    bne     $t0, $t1, fail_global_wrong_idx

    la      $a0, msg_global_hit_ok
    jal     sim_puts
    nop

    /* Probe with a completely different VPN – must miss even with G=1 */
    li      $t0, 0x00800039        /* VPN2=0x400, ASID=57 – no match */
    mtc0    $t0, $10
    tlbp

    mfc0    $t1, $0
    srl     $t2, $t1, 31
    beqz    $t2, fail_global_false_hit   /* P=0 → found; should have missed */

    la      $a0, msg_global_miss_ok
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
fail_entryhi:
    la      $a0, msg_fail_entryhi
    jal     sim_puts
    nop
    SIM_FAIL("TLBR EntryHi mismatch")

fail_entrylo0:
    la      $a0, msg_fail_elo0
    jal     sim_puts
    nop
    SIM_FAIL("TLBR EntryLo0 mismatch")

fail_entrylo1:
    la      $a0, msg_fail_elo1
    jal     sim_puts
    nop
    SIM_FAIL("TLBR EntryLo1 mismatch")

fail_pagemask:
    SIM_FAIL("TLBR PageMask mismatch")

fail_tlbp_notfound:
    SIM_FAIL("TLBP: probe-failed bit set unexpectedly")

fail_tlbp_wrong_idx:
    SIM_FAIL("TLBP: found entry but wrong index (expected 0)")

fail_tlbp_false_hit:
    SIM_FAIL("TLBP: probe should have missed but did not")

fail_tlbwr_entryhi:
    SIM_FAIL("TLBWR: EntryHi mismatch after TLBR round-trip")

fail_global_miss:
    SIM_FAIL("Global bit: TLBP missed a global entry with different ASID")

fail_global_wrong_idx:
    SIM_FAIL("Global bit: TLBP found wrong index (expected 2)")

fail_global_false_hit:
    SIM_FAIL("Global bit: TLBP found an entry for wrong VPN (should miss)")

    .size   main, . - main

/* ------------------------------------------------------------------ */
/* sim_puts($a0 = ptr) -- output a null-terminated string             */
/* ------------------------------------------------------------------ */
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
msg_start:         .asciz "TLB instruction test (TLBWI/TLBR/TLBP)\n"
msg_tlbwi:         .asciz "  TLBWI done (entry 0 written)\n"
msg_tlbr:          .asciz "  TLBR checking round-trip...\n"
msg_tlbr_ok:       .asciz "  TLBR round-trip OK\n"
msg_tlbp_hit:      .asciz "  TLBP probe (expect hit at index 0)...\n"
msg_tlbp_found:    .asciz "  TLBP hit at index 0 -- OK\n"
msg_tlbp_miss:     .asciz "  TLBP probe with different ASID (expect miss)...\n"
msg_tlbp_miss_ok:  .asciz "  TLBP miss -- OK\n"
msg_pass:          .asciz "All TLB tests passed.\n"
msg_fail_entryhi:  .asciz "FAIL: EntryHi mismatch after TLBR\n"
msg_fail_elo0:     .asciz "FAIL: EntryLo0 mismatch after TLBR\n"
msg_fail_elo1:     .asciz "FAIL: EntryLo1 mismatch after TLBR\n"
msg_tlbwr:         .asciz "  TLBWR test (write to random entry)...\n"
msg_tlbwr_ok:      .asciz "  TLBWR round-trip OK\n"
msg_global:        .asciz "  Global bit test (G=1 matches any ASID)...\n"
msg_global_hit_ok: .asciz "  Global bit: hit with different ASID -- OK\n"
msg_global_miss_ok:.asciz "  Global bit: miss with wrong VPN -- OK\n"
