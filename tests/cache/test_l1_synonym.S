/* test_l1_synonym.S -- VIPT synonym single-copy test (R10000 PIdx).
 *
 * Two VAs are mapped to ONE physical page, chosen so their L1D index bits above
 * the page offset differ:
 *
 *   VA_A = 0x00001000   va[15:12] = 0x1
 *   VA_B = 0x00009000   va[15:12] = 0x9      both -> PA 0x00300000 (PFN 0x300)
 *
 * At a 64KB L1D (LG_L1D_NUM_SETS=12) the index is va[15:4], so those land in
 * DIFFERENT sets -- a synonym.  At <=4KB the index is entirely physical, both VAs
 * pick the same set, and this test degenerates into an ordinary same-line access
 * that passes trivially: it is only meaningful at LG_L1D_NUM_SETS > 8.
 *
 * CACHEABILITY IS LOAD-BEARING.  EntryLo C must be 3: l1d.sv gates caching on
 * `w_tlb_c == 3'd3` exactly.  An earlier version of this file encoded the low bits
 * as 0x3f (C=7), so every access ran UNCACHED, straight to DRAM, trivially coherent
 * -- and the test printed PASS in all three configurations below, including the one
 * that must FAIL.  The positive control is what exposed it.
 *
 * Sequence:
 *   1. seed the page through uncached kseg1 with 0x11111111
 *   2. store 0xdead through VA_A cached   -> dirty line in set(0x1)
 *   3. load  through VA_B cached          -> must observe 0xdead
 *
 * What each configuration must do at step 3:
 *   PA replay (today)      set(VA_B) misses, replays re-indexed by PA, converges on
 *                          the same set as step 2 -> hits the dirty line -> PASS
 *   VA indexed, no PIdx    set(VA_B) misses and fills from the L2, which still holds
 *                          the PRE-store data because the dirty line never left the
 *                          L1D -> reads 0x11111111 -> FAIL.  This is the intended
 *                          failure: it is the positive control proving the test can
 *                          detect a lost synonym at all.
 *   VA indexed + PIdx      the fill carries pidx=0x9; the L2 finds l1d_present with
 *                          pidx=0x1, back-invalidates set(0x1) first, recovers the
 *                          dirty line, then serves -> 0xdead -> PASS
 *
 *   sim:  ../../ooo_core -f test_l1_synonym.elf -c 0 --maxicnt 200000
 *   fpga: mips-axi -f test_l1_synonym.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat

/* PUTC \reg : poll CP0 $7 full flag (bit0), then push reg[7:0]. clobbers $k0. */
    .macro PUTC reg
9:  mfc0  $k0, $7
    andi  $k0, $k0, 1
    bne   $k0, $zero, 9b
    nop
    mtc0  \reg, $7
    .endm
    .macro PUTL c
    li    $t9, \c
    PUTC  $t9
    .endm

    .text
    .globl main
    .type  main, @function
main:
    PUTL  0x41                    /* 'A' */

    /* ---- TLB entry 0: VA 0x0000 pair -> VA_A 0x1000 is the ODD page (bit12=1),
     * so it takes EntryLo1.  PFN 0x300 = PA 0x00300000, C=3 (cacheable), D=1, V=1,
     * G=1.  EntryLo fields: PFN<<6 | C<<3 | D<<2 | V<<1 | G. */
    mtc0  $zero, $10              /* EntryHi: VPN2 = 0 (covers VA 0x0000/0x1000) */
    li    $t0, 0x0000001f         /* EntryLo0: PFN 0, C=3,D=1,V=1,G=1 (unused page) */
    mtc0  $t0, $2
    li    $t0, 0x0000c01f         /* EntryLo1: PFN 0x300, C=3 (cacheable), D=1,V=1,G=1 */
    mtc0  $t0, $3
    mtc0  $zero, $5               /* PageMask = 0 (4KB) */
    mtc0  $zero, $0               /* Index = 0 */
    tlbwi

    /* ---- TLB entry 1: VPN2 = 0x8000>>13 = 4 -> EntryHi 0x8000, covering VA
     * 0x8000/0x9000.  VA_B 0x9000 is again the ODD page -> EntryLo1, SAME PFN
     * 0x300.  This is the synonym. */
    li    $t0, 0x00008000
    mtc0  $t0, $10
    li    $t0, 0x0000001f         /* EntryLo0: PFN 0, C=3 (unused) */
    mtc0  $t0, $2
    li    $t0, 0x0000c01f         /* EntryLo1: PFN 0x300, C=3 -> VA 0x9000 (the synonym) */
    mtc0  $t0, $3
    mtc0  $zero, $5
    li    $t0, 1
    mtc0  $t0, $0                 /* Index = 1 */
    tlbwi

    /* ---- 1. seed PA 0x00300000 through the UNCACHED kseg1 alias, so the starting
     * value is unambiguously in DRAM and in neither cache. */
    li    $t1, 0xa0300000
    li    $t2, 0x11111111
    sw    $t2, 0($t1)

    /* ---- 2. store through VA_A (cached).  Leaves a DIRTY line in set(va[15:12]=1). */
    li    $t3, 0x00001000
    li    $t4, 0x0000dead
    sw    $t4, 0($t3)

    /* ---- 3. load through VA_B (cached).  Different set; only a working
     * single-copy mechanism makes this observe the store. */
    li    $t5, 0x00009000
    lw    $s0, 0($t5)
    nop

    bne   $s0, $t4, fail
    nop

pass:
    PUTL  0x50                    /* 'P' */
    b     done
    nop
fail:
    PUTL  0x46                    /* 'F' */
done:
    PUTL  0x0a                    /* '\n' */
    jr    $ra
    nop
    .size main, .-main
