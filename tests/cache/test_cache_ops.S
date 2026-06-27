/* test_cache_ops.S -- TDD matrix for the D/L2 CACHE ops, validated against a
 * non-CPU view of DRAM (henry_tb --dump, the HPC3 / host-service's view).
 *
 * WHY --dump and not an in-program uncached read: an uncached CPU read of a
 * line that is dirty in L2 makes L2 evict-and-write-back BEFORE the uncached
 * access (L2 is inclusive), so a CPU-side read auto-heals the stranded-in-L2
 * bug and can never observe it.  Only a true non-CPU reader (--dump, or the
 * SCSI/ENET DMA the real IRIX driver uses) sees what actually reached memory.
 *
 * Each line writes a unique pattern to a CACHED kseg0 address, applies one
 * CACHE op, then the runner reads DRAM via --dump and checks the expectation.
 *
 *   T0 0x08100000  0x11111111  (no flush)            -> DRAM 00000000  control: stays cached
 *   T1 0x08100040  0x22222222  cache 0x15 Hit_WB_Inval_D   -> DRAM 22222222  writes back
 *   T2 0x08100080  0x33333333  cache 0x01 Index_WB_Inval_D -> DRAM 33333333  writes back (IRIX-style)
 *   T3 0x081000c0  0x44444444  cache 0x11 Hit_Inval_D      -> DRAM 00000000  drops, NO writeback
 *   T4 0x08100100  0x55555555  cache 0x15 then 0x17        -> DRAM 55555555  L1-WB then L2 secondary
 *   T5 0x08100140  0x66666666  cache 0x19 Hit_WB_D         -> DRAM 66666666  writes back (no-inval form)
 *
 * Run via run_cache_ops.sh (greps the --dump lines and reports PASS/FAIL).
 */
    .set    mips3
    .set    noreorder
    .set    noat
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    lui     $t0, 0x8810           /* kseg0 0x8810_0000 -> PA 0x0810_0000 (cached) */

    /* T0: cached write, NO flush (control -- expect DRAM stays 0) */
    li      $t1, 0x11111111
    sw      $t1, 0x00($t0)

    /* T1: Hit_Writeback_Invalidate_D (0x15) */
    ori     $t2, $t0, 0x40
    li      $t3, 0x22222222
    sw      $t3, 0($t2)
    cache   0x15, 0($t2)

    /* T2: Index_Writeback_Invalidate_D (0x01) -- the op IRIX's driver uses */
    ori     $t2, $t0, 0x80
    li      $t3, 0x33333333
    sw      $t3, 0($t2)
    cache   0x01, 0($t2)

    /* T3: Hit_Invalidate_D (0x11) -- must DROP the dirty line, NO writeback */
    ori     $t2, $t0, 0xc0
    li      $t3, 0x44444444
    sw      $t3, 0($t2)
    cache   0x11, 0($t2)

    /* T4: Hit_WB_Inval_D (0x15) then Hit_WB_Inval_S/L2 (0x17) */
    ori     $t2, $t0, 0x100
    li      $t3, 0x55555555
    sw      $t3, 0($t2)
    cache   0x15, 0($t2)
    cache   0x17, 0($t2)

    /* T5: Hit_Writeback_D (0x19) -- writeback, no-invalidate form */
    ori     $t2, $t0, 0x140
    li      $t3, 0x66666666
    sw      $t3, 0($t2)
    cache   0x19, 0($t2)

    li      $t4, 4000             /* drain delay so all writebacks settle */
1:  addiu   $t4, $t4, -1
    bne     $t4, $zero, 1b
    nop

    lui     $k0, 0xbfd0           /* magic-halt @ 0xbfd00000 */
    li      $k1, 1
    sw      $k1, 0($k0)
2:  b       2b
    nop
