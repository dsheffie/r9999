/* test_dma_coherence.S -- directed repro / localization of the DMA-descriptor
 * coherence bug.  Write a pattern to a CACHED kseg0 address, apply a CACHE flush,
 * then the TESTBENCH reads DRAM via --dump (the HPC3 / host-service's view -- a
 * pure g_mem read, no CPU access, so no uncached-alias auto-writeback).  Four
 * lines isolate where the writeback stops:
 *
 *   A 0x08100000: write 0x11111111, NO flush             (control -- stays cached)
 *   B 0x08100040: write 0x22222222, cache 0x15 (L1 only) (does L1-WB reach DRAM?)
 *   C 0x08100080: write 0x33333333, cache 0x15 + 0x17    (L1 then L2)
 *   D 0x081000c0: write 0x44444444, cache 0x01 (Index-WB-Inval-D, IRIX-style)
 *
 * Run: henry_tb --kernel test_dma_coherence.elf --maxcyc 200000 \
 *        --dump 0x08100000 --dump 0x08100040 --dump 0x08100080 --dump 0x081000c0
 * If B is stale but C reaches DRAM -> L1-WB stops at L2; the L2 flush is required
 * (and IRIX's descriptor sits in L2, not DRAM, when our service reads it).
 */
    .set    mips3
    .set    noreorder
    .set    noat
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    lui     $t0, 0x8810           /* kseg0 0x8810_0000 -> PA 0x0810_0000 (cached) */

    /* A: cached write, NO flush */
    li      $t1, 0x11111111
    sw      $t1, 0x00($t0)

    /* B: cached write + L1 Hit_Writeback_Invalidate_D (0x15) only */
    ori     $t2, $t0, 0x40
    li      $t3, 0x22222222
    sw      $t3, 0($t2)
    cache   0x15, 0($t2)

    /* C: cached write + L1 (0x15) then L2 Hit_Writeback_Invalidate_S (0x17) */
    ori     $t2, $t0, 0x80
    li      $t3, 0x33333333
    sw      $t3, 0($t2)
    cache   0x15, 0($t2)
    cache   0x17, 0($t2)

    /* D: cached write + Index_Writeback_Invalidate_D (0x01) */
    ori     $t2, $t0, 0xc0
    li      $t3, 0x44444444
    sw      $t3, 0($t2)
    cache   0x01, 0($t2)

    li      $t4, 4000             /* drain delay */
1:  addiu   $t4, $t4, -1
    bne     $t4, $zero, 1b
    nop

    lui     $k0, 0xbfd0           /* magic-halt @ 0xbfd00000 */
    li      $k1, 1
    sw      $k1, 0($k0)
2:  b       2b
    nop
