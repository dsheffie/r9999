/*
 * test_cache_mapped.S -- CACHE Hit-type ops on TLB-MAPPED EAs (the IRIX
 * buffer-cache / vfs_mountroot EWRONGFS scenario).
 *
 * The old funnel path masked the CACHE EA as PA=VA&0x1fffffff (unmapped-only),
 * so a Hit-WB on a mapped K2SEG/kuseg buffer hit a garbage PA and the real
 * line stayed dirty/stale.  The mem-pipe port translates the EA through the
 * dtlb like a load.
 *
 * Wire TLB[0]: VA 0x00100000/0x00101000 -> PA 0x08101000/0x08102000, then:
 *   M1  sw 0x77777777 via VA 0x00100200 ; cache 0x15,(VA)  -> DRAM@0x08101200 = 77777777
 *   M2  sw 0x88888888 via VA 0x00100300 ; NO cache op      -> DRAM@0x08101300 = 00000000
 *       (control: proves M1's writeback came from the CACHE op, not eviction)
 *   M3  sw 0x99999999 via VA 0x00101400 ; cache 0x19,(VA)  -> DRAM@0x08102400 = 99999999
 *       (odd page of the pair, Hit-WB no-inval form)
 *
 * Run via run_cache_mapped.sh (DRAM oracle).  Self-contained, BEV=0 vectors.
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
    HALT                          /* any fault -> DRAM stays 0 -> oracle FAILs */

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    mtc0    $zero, $12            /* Status=0: BEV=0, kernel */
    nop
    nop
    nop
    mtc0    $zero, $5             /* PageMask = 0 (4KB) */
    li      $t0, 1
    mtc0    $t0, $6               /* Wired = 1 */

    /* TLB[0]: VA 0x00100000 -> PA 0x08101000 (even), 0x00101000 -> 0x08102000 (odd) */
    li      $t0, 0x00100000
    mtc0    $t0, $10              /* EntryHi */
    li      $t0, 0x0020405f       /* EntryLo0: PFN=0x8101, C=3,D=1,V=1,G=1 */
    mtc0    $t0, $2
    li      $t0, 0x0020409f       /* EntryLo1: PFN=0x8102 */
    mtc0    $t0, $3
    mtc0    $zero, $0             /* Index = 0 */
    tlbwi

    /* M1: dirty a line THROUGH THE MAPPING, then CACHE Hit-WB-Inval on the VA */
    li      $t2, 0x00100200
    li      $t3, 0x77777777
    sw      $t3, 0($t2)
    cache   0x15, 0($t2)

    /* M2: dirty, NO cache op (control -- must NOT reach DRAM) */
    li      $t2, 0x00100300
    li      $t3, 0x88888888
    sw      $t3, 0($t2)

    /* M3: odd page, Hit-WB (0x19, no-inval form) */
    li      $t2, 0x00101400
    li      $t3, 0x99999999
    sw      $t3, 0($t2)
    cache   0x19, 0($t2)

    li      $t4, 4000             /* drain */
1:  addiu   $t4, $t4, -1
    bne     $t4, $zero, 1b
    nop
    HALT
