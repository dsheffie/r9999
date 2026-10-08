/* test_chop_remap.S -- CACHE Hit ops through a REMAPPED window VA (NT's flush window).
 *
 * Windows NT/MIPS keeps a cache-maintenance window at kseg3 VA 0xfffe0000-0xfffe7fff: it maps an
 * arbitrary RAM page into a slot with tlbwi (same TLB index, same VA, new PFN), then issues
 * Hit-Writeback-Invalidate / Hit-Invalidate / stores through it. A QEMU trace of an NT 4.0 boot
 * rewrites those slots ~36k times (~/code/jazz/JAZZ_NT_HANDOFF.md §4a). If a remap ever leaves a
 * stale translation in the D-TLB (or any micro-TLB), the store or the Hit op lands on the PREVIOUS
 * page -- silent DMA corruption, no fault.
 *
 * Pages (different L1D sets: PA[13:12] = 0 vs 1, so B's fills never evict A's dirty lines):
 *   A = PA 0x08110000 (kseg1 0xa8110000, kseg0 0x88110000)
 *   B = PA 0x08111000 (kseg1 0xa8111000)
 * Window W = VA 0xfffe0000 (even half of TLB pair 0), W1 = 0xfffe1000 (odd half). One TLB index (0)
 * is rewritten for every remap, the way NT does it. 3 nops after each tlbwi cover the R4400 hazard.
 *
 * Checked by run_chop_remap.sh against DRAM (--dump):
 *   R1 store+CHWBINV after remap A->B go to B:   B+0x000 = 22222222, A+0x000 = a0000000 (A untouched)
 *   R2 CHINV after remap A->B must not drop A:   A+0x100 = 33333333 (A's dirty line survives, then
 *                                                 flushed via kseg0)
 *   R3 64 alternating remaps, store+CHWBINV each: A+0x200 = c000003e, B+0x200 = c000003f
 *   R4 same as R1 on the ODD half (W1):          B+0x300 = 55555555, A+0x300 = a0000300
 *
 * Counter at PA 0x08101000 (kseg1): 1..4 = R1..R4 done, 5 = all done.
 */
    .set    mips3
    .set    noreorder
    .set    noat
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    lui     $s1, 0xa810
    ori     $s7, $s1, 0x1000          /* counter, uncached kseg1 */
    sw      $zero, 0($s7)

    li      $s2, 0xa8110000           /* A, kseg1 */
    li      $s3, 0xa8111000           /* B, kseg1 */
    li      $s4, 0x88110000           /* A, kseg0 */
    li      $s0, 0xfffe0000           /* window W (even half); W1 = W + 0x1000 */
    li      $s5, 0x0020441f           /* EntryLo: PFN 0x08110 (A) C=3 D=1 V=1 G=1 */
    li      $s6, 0x0020445f           /* EntryLo: PFN 0x08111 (B) C=3 D=1 V=1 G=1 */

    /* DRAM "old" values via kseg1 (cache is cold): A = a00000xx, B = b00000xx */
    li      $t0, 0xa0000000
    sw      $t0, 0x000($s2)
    li      $t0, 0xa0000100
    sw      $t0, 0x100($s2)
    li      $t0, 0xa0000200
    sw      $t0, 0x200($s2)
    li      $t0, 0xa0000300
    sw      $t0, 0x300($s2)
    li      $t0, 0xb0000000
    sw      $t0, 0x000($s3)
    li      $t0, 0xb0000100
    sw      $t0, 0x100($s3)
    li      $t0, 0xb0000200
    sw      $t0, 0x200($s3)
    li      $t0, 0xb0000300
    sw      $t0, 0x300($s3)

    mtc0    $zero, $5                 /* PageMask = 4KB */
    mtc0    $zero, $0                 /* Index = 0, reused for every remap */
    mtc0    $s0, $10                  /* EntryHi: VPN2 of 0xfffe0000, ASID 0 */

/* R1: dirty A through W, remap W->B, store through W, CHWBINV through W -> must hit B */
    mtc0    $s5, $2                   /* even -> A */
    li      $t0, 1                    /* odd: invalid, G=1 */
    mtc0    $t0, $3
    tlbwi
    nop
    nop
    nop
    li      $t1, 0x11111111
    sw      $t1, 0x000($s0)           /* A+0 dirty in L1D; D-TLB now holds W->A */
    mtc0    $s6, $2                   /* even -> B */
    tlbwi
    nop
    nop
    nop
    li      $t1, 0x22222222
    sw      $t1, 0x000($s0)           /* must dirty B+0, not A+0 */
    cache   0x15, 0x000($s0)          /* Hit-WB-Inval: must write B+0 back */
    li      $t2, 1
    sw      $t2, 0($s7)

/* R2: dirty A+0x100 through W, remap W->B, CHINV through W -> must NOT discard A's dirty line */
    mtc0    $s5, $2                   /* even -> A */
    tlbwi
    nop
    nop
    nop
    li      $t1, 0x33333333
    sw      $t1, 0x100($s0)           /* A+0x100 dirty */
    mtc0    $s6, $2                   /* even -> B */
    tlbwi
    nop
    nop
    nop
    cache   0x11, 0x100($s0)          /* Hit-Inval on B+0x100 (not resident): must leave A alone */
    cache   0x15, 0x100($s4)          /* flush A+0x100 via kseg0 -> DRAM must see 33333333 */
    li      $t2, 2
    sw      $t2, 0($s7)

/* R3: 64 back-to-back remaps alternating A/B; each does store + CHWBINV through W */
    li      $t3, 0                    /* i */
    li      $t4, 64
    lui     $t5, 0xc000
3:  andi    $t6, $t3, 1
    beq     $t6, $zero, 4f
    move    $t0, $s5                  /* delay slot: even i -> A */
    move    $t0, $s6                  /* odd i -> B */
4:  mtc0    $t0, $2
    tlbwi
    nop
    nop
    nop
    or      $t1, $t5, $t3             /* c0000000 | i */
    sw      $t1, 0x200($s0)
    cache   0x15, 0x200($s0)
    addiu   $t3, $t3, 1
    bne     $t3, $t4, 3b
    nop
    li      $t2, 3
    sw      $t2, 0($s7)

/* R4: R1 on the ODD half (W1 = W + 0x1000): even invalid, odd -> A then B */
    li      $t0, 1
    mtc0    $t0, $2                   /* even: invalid, G=1 */
    mtc0    $s5, $3                   /* odd -> A */
    tlbwi
    nop
    nop
    nop
    li      $t1, 0x44444444
    sw      $t1, 0x1300($s0)          /* A+0x300 dirty via W1 */
    mtc0    $s6, $3                   /* odd -> B */
    tlbwi
    nop
    nop
    nop
    li      $t1, 0x55555555
    sw      $t1, 0x1300($s0)          /* must dirty B+0x300 */
    cache   0x15, 0x1300($s0)         /* must write B+0x300 back */
    li      $t2, 4
    sw      $t2, 0($s7)

    li      $t7, 2000
1:  addiu   $t7, $t7, -1
    bne     $t7, $zero, 1b
    nop
    li      $t2, 5
    sw      $t2, 0($s7)
    lui     $k0, 0xbfd0
    li      $k1, 1
    sw      $k1, 0($k0)
2:  b       2b
    nop
    .size   _start, .-_start
