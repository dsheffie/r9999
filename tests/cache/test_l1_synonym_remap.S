/* test_l1_synonym_remap.S -- synonym + REMAP + EVICTION, modelled on what IRIX
 * actually does when L1D_VA_INDEX panics.
 *
 * test_l1_synonym.S covers the simple case (one PA, two VAs, store through one and
 * load through the other) and it PASSES.  IRIX still panics, so the simple case is
 * not what breaks.  The trace of the failing boot shows two things the simple test
 * does NOT do:
 *
 *   1. REMAPPING.  PA 0x0838e000 is reached through kseg2 0xc004a000 AND through the
 *      u-area 0xffffa0xx, and IRIX remaps the u-area VA thousands of times per boot
 *      (see the "IRIX u-area fixed-VA remap" note).  So a VA's translation CHANGES
 *      under a line that may still be resident and dirty.
 *   2. EVICTION + REFILL.  The panic fires when a TLB entry is evicted and the refill
 *      reads a PTE that has gone invalid -- i.e. the line had left and come back.
 *
 * Geometry: meaningful only at LG_L1D_NUM_SETS>8.  At 64KB the index is va[15:4], so
 * VA_A and VA_B below pick sets 0x1 and 0x9.
 *
 *   VA_A = 0x00001000  va[15:12]=1 \  both -> PA 0x00300000 (PFN 0x300)
 *   VA_B = 0x00009000  va[15:12]=9 /
 *   VA_C = 0x00011000  va[15:12]=1 -- SAME SET as VA_A, different page: the evictor
 *
 * EntryLo C MUST be 3 (low bits 0x1f).  l1d.sv gates caching on `w_tlb_c == 3'd3`
 * exactly; an earlier test used C=7 (0x3f), ran entirely uncached, and passed in every
 * configuration including the one that must fail.
 *
 * Phases, each leaving a verdict char:
 *   1 'A' start
 *   2 store via VA_A, load via VA_B          -> single-copy across a synonym
 *   3 remap VA_B to a different PFN, store,
 *     remap back, load via VA_A              -> stale translation under a live line
 *   4 evict set(VA_A) via VA_C, reload VA_A  -> line left and came back
 *   'P' all consistent / 'F' first mismatch
 *
 *   run: ./obj_dir/henry_tb --kernel test_l1_synonym_remap.elf --maxcyc 400000
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat

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

/* WRTLB idx, hi, lo1 : one 4KB mapping on the ODD page of the pair */
    .macro WRTLB idx, hi, lo1
    li    $t0, \hi
    mtc0  $t0, $10
    li    $t0, 0x0000001f          /* EntryLo0: PFN 0, C=3,D=1,V=1,G=1 (unused) */
    mtc0  $t0, $2
    li    $t0, \lo1
    mtc0  $t0, $3
    mtc0  $zero, $5                /* PageMask = 4KB */
    li    $t0, \idx
    mtc0  $t0, $0
    tlbwi
    .endm

    .text
    .globl main
    .type  main, @function
main:
    PUTL  0x41                     /* 'A' */

    /* entry 0: VA 0x1000 -> PFN 0x300 ; entry 1: VA 0x9000 -> PFN 0x300 (synonym)
     * entry 2: VA 0x11000 -> PFN 0x301 (evictor, same set as VA_A) */
    WRTLB 0, 0x00000000, 0x0000c01f
    WRTLB 1, 0x00008000, 0x0000c01f
    WRTLB 2, 0x00010000, 0x0000c05f     /* PFN 0x301 */

    /* seed both physical pages uncached so DRAM is unambiguous */
    li    $t1, 0xa0300000
    li    $t2, 0x11111111
    sw    $t2, 0($t1)
    li    $t1, 0xa0301000
    li    $t2, 0x22222222
    sw    $t2, 0($t1)

    /* ---- phase 2: plain synonym.  store via A, load via B ---- */
    /* Phase result cell at PA 0x00400000, written UNCACHED so the value cannot
     * itself be a casualty of the bug under test.  Read it back with
     * `--dump 0x400000`: 2/3/4 = that phase mismatched, 0xff = all passed.
     * (Console chars proved unreadable here -- boot hex dumps contain the same
     * digits, so any tr/grep over stdout mixes them in.) */
    li    $s6, 0xa0400000
    li    $t8, 0x000000ee          /* 'started' sentinel */
    sw    $t8, 0($s6)

    li    $s3, 0x00001000          /* VA_A */
    li    $s4, 0x00009000          /* VA_B */
    li    $s5, 0x00011000          /* VA_C (evictor) */
    li    $t4, 0x0000dead
    sw    $t4, 0($s3)
    lw    $s0, 0($s4)
    bne   $s0, $t4, fail2
    nop

    /* ---- phase 3: REMAP under a live line.
     * Store a new value via VA_A (dirty at set 1), then point VA_B at a DIFFERENT
     * page, touch it, then point VA_B back at PFN 0x300 and read.  The remap must
     * not leave a stale copy of the old translation's line behind. */
    li    $t4, 0x0000beef
    sw    $t4, 0($s3)              /* dirty at set(VA_A) */
    WRTLB 1, 0x00008000, 0x0000c05f   /* VA_B -> PFN 0x301 now */
    lw    $s1, 0($s4)              /* reads the OTHER page */
    WRTLB 1, 0x00008000, 0x0000c01f   /* VA_B -> PFN 0x300 again */
    lw    $s0, 0($s4)
    bne   $s0, $t4, fail3          /* must observe 0xbeef through the restored map */
    nop

    /* ---- phase 4: evict set(VA_A) with VA_C, then come back to VA_A.
     * VA_C's index bits [15:12] are 1, the same set as VA_A, so touching it evicts
     * the line; the reload must still produce the value stored through VA_A. */
    li    $t4, 0x0000cafe
    sw    $t4, 0($s3)              /* dirty at set(VA_A) again */
    lw    $s2, 0($s5)              /* evict: same set, different tag */
    nop
    lw    $s0, 0($s3)              /* back to VA_A -- the line left and returned */
    bne   $s0, $t4, fail4
    nop
    lw    $s0, 0($s4)              /* and the synonym must agree */
    bne   $s0, $t4, fail5          /* distinct code: 4 = reload via VA_A, 5 = synonym via VA_B */
    nop

pass:
    li    $t8, 0x000000ff
    sw    $t8, 0($s6)
    PUTL  0x50                     /* 'P' */
    b     done
    nop
fail2:
    li    $t8, 2
    b     failw
    nop
fail3:
    li    $t8, 3
    b     failw
    nop
fail4:
    li    $t8, 4
    b     failw
    nop
fail5:
    li    $t8, 5
failw:
    sw    $t8, 0($s6)
    PUTL  0x46                     /* 'F' */
done:
    PUTL  0x0a
    jr    $ra
    nop
    .size main, .-main
