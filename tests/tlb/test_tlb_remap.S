/*
 * test_tlb_remap.S  --  directed same-VA-different-PA remap stress.
 *
 * WHY: measured on the interp golden model, IRIX drives ~149M accesses through ONE
 * fixed kernel VA (0xffffffffffffc000, the per-process u-area) whose PHYSICAL page is
 * re-pointed 4000+ times per boot -- it is the hottest kernel-mapped page by a wide
 * margin.  Linux never does this (it keeps the kernel in unmapped kseg0/XKPHYS), which
 * is why Linux runs clean on silicon while IRIX corrupts.  Same-VA-different-PA is the
 * hardest case for a TLB: every remap must invalidate/replace the old entry EXACTLY,
 * and one stale hit hands the kernel another process's u-area -- precisely the observed
 * "small int where a pointer belongs" face.  randgen has never generated this pattern
 * because it never remaps a LIVE VA.
 *
 * METHOD: 8 physical pages at PA 0x300000 + i*0x1000, page i stamped 0xA5A50000|i
 * through kseg0.  The stamp is written CACHED and read back CACHED through the mapped
 * VA: r9999's L1D is VIPT with cache-size <= page-size, so both accesses land in the
 * same set and carry the same physical tag -- no coherence artifact, the test isolates
 * translation.  Then loop: point the fixed kseg2 VA at page i, read it, require
 * signature i.  A wrong signature == a stale/incorrect translation.
 *
 * The page order is scrambled (i = iter*5 mod 8, 5 coprime with 8) so a lucky
 * "same page twice in a row" never masks a stale entry, and a decoy mapping is kept
 * live at another index so the CAM must actually disambiguate rather than trivially
 * matching its only entry.
 *
 * PASS prints "REMAP OK"; FAIL prints "REMAP BAD" then iter/expected/got as hex and
 * leaves them in $s0/$s2/$s3.
 *
 * build: make -f Makefile.remap   (or see tests/test64/Makefile for the flags)
 * run:   ../../ooo_core -f test_tlb_remap.elf
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

    .section .text.startup, "ax"
    .globl  _start
_start:
    /* ---- run in 64-bit kernel mode (Status.KX=1) like IRIX 6.5, so kseg2/xkseg
     *      addressing and the EntryHi R field behave as they do under the real OS.
     *      At reset KX=0, which is NOT how IRIX runs. ---- */
    mfc0    $t0, $12
    nop
    ori     $t0, $t0, 0x80          /* Status.KX (bit 7) */
    mtc0    $t0, $12
    nop
    nop
    nop

    /* ---- stamp 8 physical pages with a per-page signature, via kseg0 (cached) ---- */
    li      $t0, 0x80300000         /* kseg0 alias of PA 0x300000 */
    li      $t1, 0                  /* i */
stamp:
    li      $t2, 0xA5A50000
    or      $t2, $t2, $t1
    sw      $t2, 0($t0)
    addiu   $t1, $t1, 1
    slti    $t3, $t1, 8
    bne     $t3, $zero, stamp
    addiu   $t0, $t0, 0x1000        /* delay slot: advance to the next page */

    /* ---- a decoy mapping kept live at index 5, so the CAM has more than one
     *      candidate and cannot pass by trivially matching its only entry ---- */
    mtc0    $zero, $5               /* PageMask = 0 -> 4KB pages */
    li      $t0, 0xc0004000         /* decoy VA */
    dmtc0   $t0, $10                /* EntryHi -- DMTC0: a 64-bit kernel writes the FULL
                                     * register.  MTC0 here would drop the R field
                                     * (EntryHi[63:62]) and no kseg2 VA could ever match. */
    li      $t0, 0x0000cc1f         /* EntryLo0: PFN 0x330, C=3 D=1 V=1 G=1 */
    mtc0    $t0, $2
    li      $t0, 0x0000cc5f         /* EntryLo1: PFN 0x331 */
    mtc0    $t0, $3
    li      $t0, 5
    mtc0    $t0, $0                 /* Index = 5 */
    tlbwi
    nop
    nop
    nop
    nop

    li      $s4, 0xc0000000         /* THE fixed kernel VA under test (kseg2) */
    li      $s0, 0                  /* iter */
    li      $s5, 256                /* iterations */

remap_loop:
    /* i = (iter * 5) & 7 */
    sll     $t1, $s0, 2
    addu    $t1, $t1, $s0
    andi    $s1, $t1, 7

    /* re-point the SAME VA at physical page i */
    mtc0    $zero, $5               /* PageMask = 4KB */
    dmtc0   $s4, $10                /* EntryHi = the fixed VA, ASID 0 (full 64-bit write) */
    li      $t2, 0x300
    addu    $t2, $t2, $s1
    sll     $t2, $t2, 6             /* PFN field */
    ori     $t2, $t2, 0x1f          /* C=3 D=1 V=1 G=1 */
    mtc0    $t2, $2                 /* EntryLo0 */
    li      $t3, 0x0000c81f         /* EntryLo1: fixed scratch PFN 0x320 */
    mtc0    $t3, $3
    li      $t5, 4
    mtc0    $t5, $0                 /* Index = 4 (mirrors IRIX's tlbp->tlbr->tlbwi) */
    tlbwi
    nop                             /* architectural TLB hazard spacing */
    nop
    nop
    nop

    /* read through the fixed VA -- must observe the page we just installed */
    lw      $s3, 0($s4)
    nop
    li      $t6, 0xA5A50000
    or      $s2, $t6, $s1           /* expected signature */
    bne     $s3, $s2, remap_bad
    nop

    /* touch the decoy so its entry stays live/competing */
    li      $t7, 0xc0004000
    lw      $t8, 0($t7)
    nop

    addiu   $s0, $s0, 1
    slt     $t9, $s0, $s5
    bne     $t9, $zero, remap_loop
    nop

remap_ok:
    la      $a1, msg_ok
    jal     puts
    nop

/* ===================== PHASE 2: ASID-switched mapping =====================
 * IRIX does not merely re-point the u-area VA -- it does so as PART OF A CONTEXT
 * SWITCH, pairing the remap with an ASID change (set_tlbpid).  Phase 1 held ASID=0
 * throughout and passed, so this phase adds the missing variable: TWO non-global
 * entries for the SAME VA distinguished only by ASID, with the current ASID flipping
 * underneath.  A TLB that ignores or mismatches ASID hands back the other process's
 * page -- which is exactly the "another process's u-area" failure being hunted.
 */
    /* Retire the phase-1 GLOBAL entry at index 4: a global entry matches ANY ASID and
     * would shadow both per-ASID entries below.  Park it on an unused VPN2 with V=0. */
    li      $t0, 0xc0100000
    dmtc0   $t0, $10
    mtc0    $zero, $2               /* EntryLo0: V=0 */
    mtc0    $zero, $3               /* EntryLo1: V=0 */
    li      $t0, 4
    mtc0    $t0, $0
    tlbwi
    nop
    nop
    nop
    nop

    /* entry for ASID 1 -> physical page 1, non-global (G=0) */
    ori     $t0, $s4, 1
    dmtc0   $t0, $10
    li      $t0, 0x0000c05e         /* PFN 0x301, C=3 D=1 V=1 G=0 */
    mtc0    $t0, $2
    li      $t0, 0x0000c81e         /* EntryLo1 scratch PFN 0x320, G=0 */
    mtc0    $t0, $3
    li      $t0, 8
    mtc0    $t0, $0
    tlbwi
    nop
    nop
    nop
    nop

    /* entry for ASID 2 -> physical page 2, non-global (G=0), SAME VA */
    ori     $t0, $s4, 2
    dmtc0   $t0, $10
    li      $t0, 0x0000c09e         /* PFN 0x302 */
    mtc0    $t0, $2
    li      $t0, 0x0000c81e
    mtc0    $t0, $3
    li      $t0, 9
    mtc0    $t0, $0
    tlbwi
    nop
    nop
    nop
    nop

    /* flip the current ASID back and forth; each read must see ITS OWN page */
    li      $s0, 0
    li      $s5, 128
asid_loop:
    andi    $t0, $s0, 1
    addiu   $s1, $t0, 1             /* asid = 1 or 2; page index == asid */
    or      $t1, $s4, $s1
    dmtc0   $t1, $10                /* EntryHi write sets the CURRENT ASID */
    nop
    nop
    nop
    nop
    lw      $s3, 0($s4)
    nop
    li      $t6, 0xA5A50000
    or      $s2, $t6, $s1           /* expected signature for this ASID */
    bne     $s3, $s2, asid_bad
    nop
    addiu   $s0, $s0, 1
    slt     $t9, $s0, $s5
    bne     $t9, $zero, asid_loop
    nop

    /* Now remap ONLY ASID 1's entry to page 5.  Two invariants: the remap must take
     * effect for ASID 1, and ASID 2's mapping must be left completely undisturbed. */
    ori     $t1, $s4, 1
    dmtc0   $t1, $10
    li      $t0, 0x0000c15e         /* PFN 0x305 */
    mtc0    $t0, $2
    li      $t0, 0x0000c81e
    mtc0    $t0, $3
    li      $t0, 8
    mtc0    $t0, $0
    tlbwi
    nop
    nop
    nop
    nop
    lw      $s3, 0($s4)             /* current ASID is 1 -> must be page 5 */
    nop
    li      $s2, 0xA5A50005
    bne     $s3, $s2, asid_bad
    nop

    ori     $t1, $s4, 2
    dmtc0   $t1, $10                /* switch to ASID 2 */
    nop
    nop
    nop
    nop
    lw      $s3, 0($s4)             /* must STILL be page 2 -- untouched by the remap */
    nop
    li      $s2, 0xA5A50002
    bne     $s3, $s2, asid_bad
    nop

asid_ok:
    la      $a1, msg_asid_ok
    jal     puts
    nop

/* ============ PHASE 3: the real IRIX update flow, tlbp -> tlbr -> modify -> tlbwi ============
 * IRIX never writes a mapping at a blindly chosen index.  set_tlbpid / tlbdropin / _unmaptlb
 * all do: EntryHi = VA; tlbp (find the index in the CAM); tlbr (read that entry back, which
 * comes from the SHADOW RAM); modify EntryLo; tlbwi (write it back at the probed index).
 * That silently assumes the matching CAM and the shadow RAM agree on index<->entry
 * association -- and the on-silicon IRIX sweep (unix.tlbsweep2) reported 13/21 live entries
 * whose shadow key probed to a DIFFERENT CAM index.  Phases 1 and 2 wrote a known index
 * directly, so neither exercised the probe at all.  Here EVERY remap goes through it, and
 * all three steps are checked independently: the probe must land on the right index, the
 * read-back must return what was installed, and the re-pointed mapping must take effect.
 */
    li      $s6, 0xc0200000         /* phase-3 VA base; entry i covers VA + i*0x2000 */

    /* install 8 global entries at indices 16..23; entry i -> physical page i */
    li      $s0, 0
p3_install:
    sll     $t1, $s0, 13
    addu    $t1, $s6, $t1
    dmtc0   $t1, $10                /* EntryHi = VA_i */
    li      $t2, 0x300
    addu    $t2, $t2, $s0
    sll     $t2, $t2, 6
    ori     $t2, $t2, 0x1f          /* PFN 0x300+i, C=3 D=1 V=1 G=1 */
    mtc0    $t2, $2
    li      $t3, 0x0000c81f
    mtc0    $t3, $3
    mtc0    $zero, $5
    addiu   $t4, $s0, 16
    mtc0    $t4, $0                 /* Index = 16+i */
    tlbwi
    nop
    nop
    nop
    nop
    addiu   $s0, $s0, 1
    slti    $t5, $s0, 8
    bne     $t5, $zero, p3_install
    nop

    li      $s0, 0
p3_loop:
    sll     $s7, $s0, 13
    addu    $s7, $s6, $s7           /* VA_i */
    dmtc0   $s7, $10                /* EntryHi = VA_i, for the probe */
    nop
    nop
    nop
    nop
    tlbp                            /* --- step 1: find the index in the CAM --- */
    nop
    nop
    nop
    nop
    mfc0    $t0, $0                 /* Index */
    nop
    bltz    $t0, p3_probe_bad       /* Index[31] set == probe MISSED */
    nop
    addiu   $t1, $s0, 16
    bne     $t0, $t1, p3_probe_bad  /* ...and it must be the index we installed */
    nop

    tlbr                            /* --- step 2: read that entry back (shadow RAM) --- */
    nop
    nop
    nop
    nop
    mfc0    $t2, $2                 /* EntryLo0 as read back */
    nop
    li      $t3, 0x300
    addu    $t3, $t3, $s0
    sll     $t3, $t3, 6
    ori     $t3, $t3, 0x1f
    bne     $t2, $t3, p3_read_bad   /* must equal what we installed at this index */
    nop

    /* --- step 3: re-point at page j=(i+4)&7 and write back at the PROBED index --- */
    addiu   $t4, $s0, 4
    andi    $s1, $t4, 7
    li      $t5, 0x300
    addu    $t5, $t5, $s1
    sll     $t5, $t5, 6
    ori     $t5, $t5, 0x1f
    mtc0    $t5, $2                 /* EntryLo0 = page j */
    mtc0    $t0, $0                 /* Index = the PROBED index */
    tlbwi
    nop
    nop
    nop
    nop

    lw      $s3, 0($s7)             /* --- and the remap must be visible through the VA --- */
    nop
    li      $t6, 0xA5A50000
    or      $s2, $t6, $s1
    bne     $s3, $s2, p3_flow_bad
    nop

    addiu   $s0, $s0, 1
    slti    $t7, $s0, 8
    bne     $t7, $zero, p3_loop
    nop

p3_ok:
    la      $a1, msg_probe_ok
    jal     puts
    nop

/* ================= PHASE 4: I-SIDE remap -- does TLBWI reach the ITLB? =================
 * Phases 1-3 only ever did DATA loads through the remapped VA, so they exercised the D-side
 * translation path exclusively.  r9999 has a SEPARATE instruction-side TLB (the 48-way
 * compare that is also the timing critical path), and a context switch remaps TEXT pages
 * exactly as it remaps the u-area.  If a TLBWI does not invalidate the I-side, instruction
 * fetch through a re-pointed VA runs the OLD page's code -- which would corrupt control flow
 * directly, with no wild pointer needed.
 *
 * Two tiny routines are written into PA 0x340000 / 0x341000 (each just sets $v0 to its own
 * signature and returns), the same VA is pointed alternately at each, and after every remap
 * we CALL it and require the signature of the page that is mapped RIGHT NOW.  The routines
 * are written through the kseg1 UNCACHED alias so no dirty D-cache line has to be pushed out
 * before the I-side can see them (same trick as test_ixlate.S).
 */
    li      $t0, 0xa0340000         /* uncached alias of PA 0x340000 -- routine A */
    li      $t1, 0x3c02aaaa         /* lui  $v0, 0xaaaa      */
    sw      $t1, 0($t0)
    li      $t1, 0x34421111         /* ori  $v0, $v0, 0x1111 */
    sw      $t1, 4($t0)
    li      $t1, 0x03e00008         /* jr   $ra              */
    sw      $t1, 8($t0)
    sw      $zero, 12($t0)          /* nop (delay slot)      */

    li      $t0, 0xa0341000         /* uncached alias of PA 0x341000 -- routine B */
    li      $t1, 0x3c02bbbb         /* lui  $v0, 0xbbbb      */
    sw      $t1, 0($t0)
    li      $t1, 0x34422222         /* ori  $v0, $v0, 0x2222 */
    sw      $t1, 4($t0)
    li      $t1, 0x03e00008         /* jr   $ra              */
    sw      $t1, 8($t0)
    sw      $zero, 12($t0)

    li      $s6, 0xc0300000         /* the VA we EXECUTE from */
    li      $s0, 0
    li      $s5, 32
p4_loop:
    andi    $s1, $s0, 1             /* 0 -> page A (PFN 0x340), 1 -> page B (PFN 0x341) */
    mtc0    $zero, $5
    dmtc0   $s6, $10
    li      $t2, 0x340
    addu    $t2, $t2, $s1
    sll     $t2, $t2, 6
    ori     $t2, $t2, 0x1f          /* C=3 D=1 V=1 G=1 */
    mtc0    $t2, $2
    li      $t3, 0x0000c81f
    mtc0    $t3, $3
    li      $t4, 12
    mtc0    $t4, $0                 /* Index = 12 */
    tlbwi
    nop
    nop
    nop
    nop

    la      $ra, p4_back
    jr      $s6                     /* I-FETCH through the remapped VA */
    nop
p4_back:
    bne     $s1, $zero, p4_expect_b
    nop
    li      $s2, 0xaaaa1111
    b       p4_check
    nop
p4_expect_b:
    li      $s2, 0xbbbb2222
p4_check:
    move    $s3, $v0
    bne     $s3, $s2, p4_bad
    nop
    addiu   $s0, $s0, 1
    slt     $t7, $s0, $s5
    bne     $t7, $zero, p4_loop
    nop

p4_ok:
    la      $a1, msg_iside_ok
    jal     puts
    nop
    HALT

p4_bad:
    la      $a1, msg_iside_bad
    jal     puts
    nop
    move    $a0, $s0                /* iteration */
    jal     puthex32
    nop
    li      $t9, 0x20
    mtc0    $t9, $7
    move    $a0, $s2                /* expected signature */
    jal     puthex32
    nop
    li      $t9, 0x20
    mtc0    $t9, $7
    move    $a0, $s3                /* got */
    jal     puthex32
    nop
    li      $t9, 0x0a
    mtc0    $t9, $7
    HALT

p3_probe_bad:
    la      $a1, msg_probe_bad
    move    $s2, $t1                /* expected index */
    b       p3_report
    move    $s3, $t0                /* got index (delay slot) */
p3_read_bad:
    la      $a1, msg_tlbr_bad
    move    $s2, $t3                /* expected EntryLo0 */
    b       p3_report
    move    $s3, $t2                /* got EntryLo0 (delay slot) */
p3_flow_bad:
    la      $a1, msg_flow_bad       /* $s2/$s3 already hold expected/got */
p3_report:
    jal     puts
    nop
    move    $a0, $s0                /* which entry */
    jal     puthex32
    nop
    li      $t9, 0x20
    mtc0    $t9, $7
    move    $a0, $s2
    jal     puthex32
    nop
    li      $t9, 0x20
    mtc0    $t9, $7
    move    $a0, $s3
    jal     puthex32
    nop
    li      $t9, 0x0a
    mtc0    $t9, $7
    HALT

asid_bad:
    la      $a1, msg_asid_bad
    jal     puts
    nop
    move    $a0, $s1                /* asid in play */
    jal     puthex32
    nop
    li      $t9, 0x20
    mtc0    $t9, $7
    move    $a0, $s2                /* expected */
    jal     puthex32
    nop
    li      $t9, 0x20
    mtc0    $t9, $7
    move    $a0, $s3                /* got */
    jal     puthex32
    nop
    li      $t9, 0x0a
    mtc0    $t9, $7
    HALT

remap_bad:
    la      $a1, msg_bad
    jal     puts
    nop
    move    $a0, $s0                /* which iteration */
    jal     puthex32
    nop
    li      $t9, 0x20
    mtc0    $t9, $7
    move    $a0, $s2                /* expected */
    jal     puthex32
    nop
    li      $t9, 0x20
    mtc0    $t9, $7
    move    $a0, $s3                /* got */
    jal     puthex32
    nop
    li      $t9, 0x0a
    mtc0    $t9, $7
    HALT

/* puts: print the NUL-terminated string at $a1 (clobbers $a1,$t1) */
puts:
    lbu     $t1, 0($a1)
    beq     $t1, $zero, puts_done
    nop
    mtc0    $t1, $7
    b       puts
    addiu   $a1, $a1, 1             /* delay slot */
puts_done:
    jr      $ra
    nop

/* puthex32: print $a0 as 8 hex digits (clobbers $t2,$t3,$t4) */
puthex32:
    li      $t4, 28
ph_loop:
    srlv    $t2, $a0, $t4
    andi    $t2, $t2, 0xf
    slti    $t3, $t2, 10
    beq     $t3, $zero, ph_alpha
    nop
    addiu   $t2, $t2, 0x30          /* '0' */
    b       ph_emit
    nop
ph_alpha:
    addiu   $t2, $t2, 0x57          /* 'a' - 10 */
ph_emit:
    mtc0    $t2, $7
    addiu   $t4, $t4, -4
    bgez    $t4, ph_loop
    nop
    jr      $ra
    nop

    .data
msg_ok:
    .asciiz "REMAP OK\n"
msg_bad:
    .asciiz "REMAP BAD iter/exp/got "
msg_asid_ok:
    .asciiz "ASID OK\n"
msg_asid_bad:
    .asciiz "ASID BAD asid/exp/got "
msg_probe_ok:
    .asciiz "PROBE OK\n"
msg_probe_bad:
    .asciiz "PROBE BAD i/expidx/gotidx "
msg_tlbr_bad:
    .asciiz "TLBR BAD i/exp/got "
msg_flow_bad:
    .asciiz "FLOW BAD i/exp/got "
msg_iside_ok:
    .asciiz "ISIDE OK\n"
msg_iside_bad:
    .asciiz "ISIDE BAD iter/exp/got "
