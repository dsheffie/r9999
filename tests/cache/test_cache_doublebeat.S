/*
 * test_cache_doublebeat.S -- ONE 32B-aligned Hit_WB_Invalidate_D (cache 0x15)
 * must write back BOTH 16B lines of the 32B block (addr and addr+16), so stock
 * IRIX's 32B-stride dma_cache_inv covers r9999's 16B lines. See l1d.sv CHOP_BEAT2.
 *
 * TLB[0]: VA 0x00100000 -> PA 0x08101000 (cached).
 *   A   sw 0xAAAAAAAA via VA 0x00100200 (PA 0x08101200, line A, dirty)
 *   A16 sw 0xBBBBBBBB via VA 0x00100210 (PA 0x08101210, line A+16, dirty)
 *   C   sw 0xCCCCCCCC via VA 0x00100300 (PA 0x08101300, different 32B block, dirty)
 *   cache 0x15,(A)  -- single op at the 32B-aligned A
 * Oracle: DRAM 0x08101200==aaaaaaaa (beat 0) AND 0x08101210==bbbbbbbb (beat 1,
 * the double-beat -- 0 without it) AND 0x08101300==00000000 (control: no op ->
 * stays in cache, never reaches DRAM).
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

    /* dirty line A (32B-aligned) */
    li      $t2, 0x00100200
    li      $t3, 0xAAAAAAAA
    sw      $t3, 0($t2)
    /* dirty line A+16 (same 32B block, NOT separately cache-op'd) */
    li      $t2, 0x00100210
    li      $t3, 0xBBBBBBBB
    sw      $t3, 0($t2)
    /* dirty a control line in a different 32B block */
    li      $t2, 0x00100300
    li      $t3, 0xCCCCCCCC
    sw      $t3, 0($t2)

    /* ONE Hit_WB_Invalidate at A -> double-beat must flush A AND A+16 */
    li      $t2, 0x00100200
    cache   0x15, 0($t2)

    li      $t4, 4000
1:  addiu   $t4, $t4, -1
    bne     $t4, $zero, 1b
    nop
    HALT
