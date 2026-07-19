/*
 * test_vipt_alias.S -- directed VIPT L1D synonym (alias) test.
 *
 * Deliberately MIS-COLORS the TLB: maps two virtual pages that differ only in
 * one alias bit (VA[12], [13], [14] or [15]) to the SAME physical frame, so
 * VA[15:12] != PA[15:12].  IRIX page-coloring normally prevents this; here we
 * force it to exercise a >4KB VIPT L1D.
 *
 *   For alias bit b: VA_lo (bit b = 0) and VA_hi (bit b = 1) both translate to
 *   the same PA.  At 4KB the L1D index is inside the page offset so both hit the
 *   SAME set -> trivially coherent.  At the size where bit b enters the index
 *   (8KB->b12, 16KB->b13, 32KB->b14, 64KB->b15) the two VAs index DIFFERENT sets
 *   -> a naive VIPT L1D keeps two incoherent lines.
 *
 * Check (synonym coherence): seed PA via kseg1 (uncached) = V0; cached store V1
 * via VA_lo; SYNC (drain store buffer into the L1D, defeat store->load forward);
 * cached load via VA_hi.  Alias-correct -> V1; aliasing bug -> stale V0.
 *
 * Self-checking (SIM_PASS/SIM_FAIL) so it runs under -c 0 (the co-sim golden is
 * 1:1 va2pa and cannot model the mis-coloring).  PASSES at 4KB for all bits;
 * at >=8KB it is the real test of the tag-widening alias handling.
 *
 * Physical frames (all PA[15:12]=0, so VA_hi is mis-colored): 0x300000 (b12),
 * 0x400000 (b13), 0x500000 (b14), 0x600000 (b15).  TLB indices 0..6.
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

/* write TLB entry: idx, EntryHi, EntryLo0, EntryLo1 (PageMask=0 -> 4KB). */
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

/* synonym coherence check: seed PA (kseg1) = v0, store v1 via va_lo (cached),
 * sync, load via va_hi (cached); branch flabel if load != v1. */
    .macro  SYNCHK va_lo, va_hi, pa_k1, v0, v1, flabel
    li      $t1, \pa_k1
    li      $t0, \v0
    sw      $t0, 0($t1)          /* seed physical memory (uncached kseg1) = v0 */
    li      $t3, \va_hi
    lw      $t4, 0($t3)          /* KEY: populate VA_hi's set = v0 (cached) */
    li      $t2, \va_lo
    li      $t0, \v1
    sw      $t0, 0($t2)          /* cached store via VA_lo = v1 (dirty) */
    sync                         /* drain store buffer -> L1D (no fwd to the load) */
    lw      $t4, 0($t3)          /* re-load VA_hi: aliasing -> stale v0; coherent -> v1 */
    li      $t5, \v1
    bne     $t4, $t5, \flabel
    nop
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

    /* ---- bit 12 (8KB): one entry, PFN0==PFN1 (even+odd -> same PA) ---- */
    TLBW    0, 0x00800000, 0x0000c01f, 0x0000c01f    /* VPN2=0x400 -> PA 0x300000 */
    SYNCHK  0x00800000, 0x00801000, 0xa0300000, 0xdead0012, 0xc0de0012, fail12
    la      $a0, msg_b12; jal sim_puts; nop

    /* ---- bit 13 (16KB): two entries (VPN2 differ in bit 0) -> same PA ---- */
    TLBW    1, 0x00810000, 0x0001001f, 0x00000001    /* VPN2=0x408 -> PA 0x400000 */
    TLBW    2, 0x00812000, 0x0001001f, 0x00000001    /* VPN2=0x409 -> PA 0x400000 */
    SYNCHK  0x00810000, 0x00812000, 0xa0400000, 0xdead0013, 0xc0de0013, fail13
    la      $a0, msg_b13; jal sim_puts; nop

    /* ---- bit 14 (32KB) ---- */
    TLBW    3, 0x00820000, 0x0001401f, 0x00000001    /* VPN2=0x410 -> PA 0x500000 */
    TLBW    4, 0x00824000, 0x0001401f, 0x00000001    /* VPN2=0x412 -> PA 0x500000 */
    SYNCHK  0x00820000, 0x00824000, 0xa0500000, 0xdead0014, 0xc0de0014, fail14
    la      $a0, msg_b14; jal sim_puts; nop

    /* ---- bit 15 (64KB) ---- */
    TLBW    5, 0x00840000, 0x0001801f, 0x00000001    /* VPN2=0x420 -> PA 0x600000 */
    TLBW    6, 0x00848000, 0x0001801f, 0x00000001    /* VPN2=0x424 -> PA 0x600000 */
    SYNCHK  0x00840000, 0x00848000, 0xa0600000, 0xdead0015, 0xc0de0015, fail15
    la      $a0, msg_b15; jal sim_puts; nop

    la      $a0, msg_pass
    jal     sim_puts
    nop
    SIM_PASS()

fail12: la $a0, msg_f12; jal sim_puts; nop; SIM_FAIL("VIPT alias bit12 (8KB)")
fail13: la $a0, msg_f13; jal sim_puts; nop; SIM_FAIL("VIPT alias bit13 (16KB)")
fail14: la $a0, msg_f14; jal sim_puts; nop; SIM_FAIL("VIPT alias bit14 (32KB)")
fail15: la $a0, msg_f15; jal sim_puts; nop; SIM_FAIL("VIPT alias bit15 (64KB)")
    .size   main, . - main

/* ---- sim_puts ---- */
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
msg_start: .asciz "VIPT L1D alias (synonym) test\n"
msg_b12:   .asciz "  bit12 (8KB):  OK\n"
msg_b13:   .asciz "  bit13 (16KB): OK\n"
msg_b14:   .asciz "  bit14 (32KB): OK\n"
msg_b15:   .asciz "  bit15 (64KB): OK\n"
msg_pass:  .asciz "All VIPT alias tests passed.\n"
msg_f12:   .asciz "FAIL: bit12 synonym stale (8KB alias)\n"
msg_f13:   .asciz "FAIL: bit13 synonym stale (16KB alias)\n"
msg_f14:   .asciz "FAIL: bit14 synonym stale (32KB alias)\n"
msg_f15:   .asciz "FAIL: bit15 synonym stale (64KB alias)\n"
