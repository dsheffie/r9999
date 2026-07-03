/*
 * test_tlbconsist.S  --  directed CAM/shadow TLB consistency test.
 *
 * r9999 keeps TWO structures per TLB entry: the matching CAM (tlb.sv r_tlb,
 * used by translation and TLBP) and the shadow RAM (exec.sv r_shadow_tlb,
 * read by TLBR).  IRIX's TLB flows (set_tlbpid, tlbdropin, _unmaptlb) do
 * tlbp -> tlbr@Index -> modify -> tlbwi@Index, which silently ASSUMES the two
 * structures agree on index<->entry association.  The on-silicon IRIX sweep
 * (unix.tlbsweep2) reported 13/21 live entries whose shadow key probes to a
 * DIFFERENT CAM index -- this test checks the invariant directly on a clean
 * machine:
 *
 *   dir1 (shadow->CAM): for each written index i: tlbr@i then tlbp must
 *        return Index==i (tlbr loads EntryHi from the shadow; tlbp matches
 *        the CAM with it).
 *   dir2 (CAM->shadow): for each written VA: tlbp -> idx, tlbr@idx, EntryHi
 *        must equal the VA (the IRIX RMW direction).
 *
 * Environment mimics IRIX: Wired=12, 12 tlbwi live entries (idx 0..11),
 * 4 entries PARKED at the same EntryHi=0x80000000 (IRIX _invaltlb style --
 * deliberate key duplicates), then 16 tlbwr entries, then dir1+dir2 sweeps,
 * then an IRIX-style RMW pass (tlbp->tlbr->tlbwi unchanged) and re-sweep.
 *
 * FAIL prints: F<phase> i=<hex8> got=<hex8>, then halts.  PASS prints PASS.
 * Self-contained (own BEV=0 vectors, no crt0), RTL-only (-c 0), magic-halt.
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

/* ================================================================
 * BEV=0 vectors: no exception is expected anywhere in this test.
 * ================================================================ */
    .section .except_vec, "ax"
    .org    0x000               /* 32-bit TLB refill */
    b       vec_fail
    nop
    .org    0x080               /* XTLB refill */
    b       vec_fail
    nop
    .org    0x180               /* general exception */
vec_fail:
    SIMCON_PUTLIT('F')
    SIMCON_PUTLIT('V')
    SIMCON_PUTLIT('\n')
    HALT

/* ================================================================
 * Reset entry
 * ================================================================ */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    mtc0    $zero, $12          /* Status=0: BEV=0, kernel */
    nop
    nop
    nop
    mtc0    $zero, $5           /* PageMask = 0 (4 KB pages) */
    li      $t0, 12
    mtc0    $t0, $6             /* Wired = 12 (tlbwr stays in [12..47]) */

    /* ---- phase A: 12 live tlbwi entries at idx 0..11:
     *      VA 0x00100000 + i*0x2000, PFN arbitrary, V=1,G=1 ---- */
    li      $s0, 0              /* i */
    li      $s1, 12
1:  sll     $t0, $s0, 13
    lui     $t1, 0x0010
    addu    $t0, $t0, $t1
    mtc0    $t0, $10            /* EntryHi = 0x00100000 + i*0x2000 */
    li      $t1, 0x0000801f     /* EntryLo0: PFN=0x200, C=3,D=1,V=1,G=1 */
    mtc0    $t1, $2
    li      $t1, 0x0000805f     /* EntryLo1 */
    mtc0    $t1, $3
    mtc0    $s0, $0             /* Index = i */
    tlbwi
    addiu   $s0, $s0, 1
    bne     $s0, $s1, 1b
    nop

    /* ---- phase B: park idx 12..15 IRIX-style (SAME EntryHi=0x80000000,
     *      lo0=lo1=0) -- deliberate key duplicates like _invaltlb makes ---- */
    lui     $t0, 0x8000
    mtc0    $t0, $10
    mtc0    $zero, $2
    mtc0    $zero, $3
    li      $s0, 12
    li      $s1, 16
1:  mtc0    $s0, $0
    tlbwi
    addiu   $s0, $s0, 1
    bne     $s0, $s1, 1b
    nop

    /* ---- phase C: 16 tlbwr entries: VA 0x00400000 + i*0x2000 ---- */
    li      $s0, 0
    li      $s1, 16
1:  sll     $t0, $s0, 13
    lui     $t1, 0x0040
    addu    $t0, $t0, $t1
    mtc0    $t0, $10
    li      $t1, 0x0000801f
    mtc0    $t1, $2
    li      $t1, 0x0000805f
    mtc0    $t1, $3
    tlbwr
    addiu   $s0, $s0, 1
    bne     $s0, $s1, 1b
    nop

    /* ================================================================
     * dir1 sweep: idx 0..11 (the known live tlbwi indices):
     * tlbr@i ; tlbp ; Index must == i
     * ================================================================ */
    li      $s0, 0
    li      $s1, 12
dir1:
    mtc0    $s0, $0             /* Index = i */
    nop
    tlbr                        /* EntryHi <- shadow[i] */
    nop
    tlbp                        /* Index <- CAM match of EntryHi */
    nop
    mfc0    $t2, $0
    beq     $t2, $s0, 1f
    nop
    li      $a3, '1'
    b       fail                /* a0=i, a1=got */
    move    $a0, $s0
1:  addiu   $s0, $s0, 1
    bne     $s0, $s1, dir1
    nop

    /* ================================================================
     * dir2 sweep: for each written VA (12 tlbwi + 16 tlbwr):
     * mtc0 EntryHi=va ; tlbp (expect hit) ; tlbr@Index ; EntryHi must == va
     * ================================================================ */
    li      $s0, 0
    li      $s1, 28             /* 12 + 16 VAs */
dir2:
    sltiu   $t3, $s0, 12
    beqz    $t3, 2f
    nop
    sll     $t0, $s0, 13        /* first 12: 0x00100000 + i*0x2000 */
    lui     $t1, 0x0010
    b       3f
    addu    $t0, $t0, $t1
2:  addiu   $t4, $s0, -12
    sll     $t0, $t4, 13        /* rest: 0x00400000 + (i-12)*0x2000 */
    lui     $t1, 0x0040
    addu    $t0, $t0, $t1
3:  mtc0    $t0, $10            /* EntryHi = va (ASID=0) */
    nop
    tlbp
    nop
    mfc0    $t2, $0
    bltz    $t2, 4f             /* P set = probe MISS */
    nop
    mtc0    $t2, $0             /* Index = found idx */
    nop
    tlbr                        /* EntryHi <- shadow[idx] */
    nop
    mfc0    $t5, $10
    beq     $t5, $t0, 5f        /* shadow VPN2 must equal the probed VA */
    nop
    move    $t2, $t5            /* second diagnostic word = shadow EntryHi */
    li      $a3, '2'
    b       fail                /* a0=va, a1=shadow-EntryHi */
    move    $a0, $t0
4:  sltiu   $t3, $s0, 12        /* miss on a tlbwi VA (0..11) = real fail; */
    beqz    $t3, 5f             /* a tlbwr VA may have been legally evicted */
    nop                         /* by a colliding later tlbwr -> skip */
    li      $a3, 'M'
    move    $a1, $t2
    b       fail                /* a0=va, a1=Index(P) */
    move    $a0, $t0
5:  addiu   $s0, $s0, 1
    bne     $s0, $s1, dir2
    nop

    /* ================================================================
     * phase D: IRIX-style RMW churn on 8 of the tlbwr VAs:
     * tlbp -> tlbr@Index -> tlbwi@Index (write back unchanged), then
     * re-run dir1.  If CAM/shadow skew, the RMW writes the WRONG entry back.
     * ================================================================ */
    li      $s0, 0
    li      $s1, 8
rmw:
    sll     $t0, $s0, 13
    lui     $t1, 0x0040
    addu    $t0, $t0, $t1
    mtc0    $t0, $10
    nop
    tlbp
    nop
    mfc0    $t2, $0
    bltz    $t2, 9f             /* evicted tlbwr VA: skip the RMW */
    nop
    tlbr                        /* staging <- shadow[Index] */
    nop
    tlbwi                       /* write back unchanged (set_tlbpid shape) */
    nop
9:  addiu   $s0, $s0, 1
    bne     $s0, $s1, rmw
    nop
    b       dir1b
    nop

    /* dir1 again after the churn */
dir1b:
    li      $s0, 0
    li      $s1, 12
7:  mtc0    $s0, $0
    nop
    tlbr
    nop
    tlbp
    nop
    mfc0    $t2, $0
    beq     $t2, $s0, 8f
    nop
    li      $a3, '3'
    b       fail
    move    $a0, $s0
8:  addiu   $s0, $s0, 1
    bne     $s0, $s1, 7b
    nop

    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT

/* ---- fail: print F<phase> <a0-hex8> <a1-hex8> then halt ----
 * (a3 = phase char, a0/a1 = diagnostic words; $t6-$t9 scratch) */
fail:
    move    $a1, $t2            /* default second word = last probe result */
fail_pr:
    SIMCON_PUTLIT('F')
    mtc0    $a3, $7             /* phase char */
    SIMCON_PUTLIT(' ')
    move    $t6, $a0
    jal     put_hex8
    nop
    SIMCON_PUTLIT(' ')
    move    $t6, $a1
    jal     put_hex8
    nop
    SIMCON_PUTLIT('\n')
    HALT

/* print $t6 as 8 hex chars (clobbers $t7,$t8,$t9) */
put_hex8:
    li      $t7, 8
1:  srl     $t8, $t6, 28
    sltiu   $t9, $t8, 10
    beqz    $t9, 2f
    nop
    addiu   $t8, $t8, '0'
    b       3f
    nop
2:  addiu   $t8, $t8, 'a'-10
3:  mtc0    $t8, $7
    sll     $t6, $t6, 4
    addiu   $t7, $t7, -1
    bnez    $t7, 1b
    nop
    jr      $ra
    nop
