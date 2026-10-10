/*
 * test_index_oneline.S -- ONE Index_WB_Invalidate_D (cache 0x01) acts on exactly the
 * 16B block containing its address (R4400 manual A-42: a CACHE op operates on "the cache
 * block"; Config DB=0 -> 16B).  The neighbouring 16B line must NOT be touched.  IRIX on
 * an R4400 PRId walks every cache op at a 16B stride (measured in the ISS, 2026-10-10),
 * so the old 32B "double beat" was never needed and broke inclusion at page ends.
 *
 * TLB[0]: VA 0x00100000 -> PA 0x08101000 (cached).
 *   A   sw 0xAAAAAAAA via VA 0x00100200 (PA 0x08101200 -> set 0x120, dirty)
 *   A16 sw 0xBBBBBBBB via VA 0x00100210 (PA 0x08101210 -> set 0x121, dirty)
 *   C   sw 0xCCCCCCCC via VA 0x00100300 (PA 0x08101300 -> set 0x130, dirty)
 *   cache 0x01, (0x80001200)  -- Index op selects set 0x120 (16KB L1D: bits [13:4]).
 *     The funnel writes the line back by its REAL cached tag, so set 0x120 ->
 *     0x08101200.  Set 0x121 (A16) must stay untouched.  (The 4KB-L1D version used
 *     0x80000200 = set 0x20, which misses on today's 16KB L1D and tested nothing.)
 * Oracle (ooo_core --memdump 8101200:110:<file>): DRAM 0x08101200==aaaaaaaa (the
 * addressed line written back) AND 0x08101210==00000000 (the neighbour stays dirty in
 * the L1D -- the op must not touch it) AND 0x08101300==00000000 (control).
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

    .section .except_vec, "ax"
    .org    0x000
    b       vec_fail
    nop
    .org    0x080
    b       vec_fail
    nop
    .org    0x180
vec_fail:
    HALT

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    mtc0    $zero, $12
    nop
    nop
    nop
    mtc0    $zero, $5
    li      $t0, 1
    mtc0    $t0, $6

    /* TLB[0]: VA 0x00100000 -> PA 0x08101000, cached */
    li      $t0, 0x00100000
    mtc0    $t0, $10
    li      $t0, 0x0020405f
    mtc0    $t0, $2
    li      $t0, 0x0020409f
    mtc0    $t0, $3
    mtc0    $zero, $0
    tlbwi

    /* dirty line A (set 0x20) */
    li      $t2, 0x00100200
    li      $t3, 0xAAAAAAAA
    sw      $t3, 0($t2)
    /* dirty line A+16 (set 0x21, same 32B block, NOT separately cache-op'd) */
    li      $t2, 0x00100210
    li      $t3, 0xBBBBBBBB
    sw      $t3, 0($t2)
    /* dirty a control line in a different 32B block (set 0x30) */
    li      $t2, 0x00100300
    li      $t3, 0xCCCCCCCC
    sw      $t3, 0($t2)

    /* ONE Index_WB_Invalidate at set 0x120 -> must flush set 0x120 only, NOT 0x121.
     * 0x80001200[13:4] = 0x120; the CACHE_OP funnel does NOT translate (kseg0 EA ok). */
    li      $t2, 0x80001200
    cache   0x01, 0($t2)

    li      $t4, 4000
1:  addiu   $t4, $t4, -1
    bne     $t4, $zero, 1b
    nop
    HALT
