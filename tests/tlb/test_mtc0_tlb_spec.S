/*
 * test_mtc0_tlb_spec.S  --  MTC0 to Index/EntryLo0/EntryLo1/PageMask is oldest_first,
 * not serializing (decode_mips.sv w_mtc0_tlb_reg).  Hunt the hazards that opens up:
 *   - a WRONG-PATH mtc0 (predicted fall-through, branch actually taken) must not write
 *   - an mtc0 in a regular delay slot always writes
 *   - an mtc0 in a branch-likely delay slot writes only when the branch is taken
 *   - a serializing mtc0 (Wired) in a not-taken branch-likely slot must not commit
 *   - mtc0 immediately followed by tlbwi must write the new staging values (tlbr back)
 *   - mfc0 right after mtc0 (and right after tlbp) must see the new value -- MFC0 is
 *     not oldest_first; core.sv holds it at alloc while a CP0 writer is in flight
 * xorshift-random branch directions defeat the predictor.  The architectural value of
 * each register is shadowed in s3..s6 and checked via mfc0 and via tlbwi/tlbr.
 * Self-contained, magic-halt, prints 'P' (or 'F' + a code).  Run RTL-only (-c 0) and
 * under the co-sim checker (-c 1).
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

    .macro  FAILC c
    li      $a3, \c
    b       fail
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
    SIMCON_PUTLIT('F')
    SIMCON_PUTLIT('V')
    SIMCON_PUTLIT('\n')
    HALT

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    mtc0    $zero, $12          /* Status=0: BEV=0, kernel */
    nop
    nop
    nop
    li      $t0, 2
    mtc0    $t0, $6             /* Wired=2 */
    mtc0    $zero, $2
    mtc0    $zero, $3
    mtc0    $zero, $5
    li      $t0, 2
    mtc0    $t0, $0
    move    $s3, $zero          /* shadow EntryLo0 */
    move    $s4, $zero          /* shadow EntryLo1 */
    li      $s5, 2              /* shadow Index */
    move    $s6, $zero          /* shadow PageMask */
    li      $s7, 2              /* shadow Wired */

    li      $s2, 0x2545f491     /* xorshift32 seed */
    li      $s0, 0              /* i */
    li      $s1, 2000

loop:
    sll     $t4, $s2, 13        /* xorshift32 */
    xor     $s2, $s2, $t4
    srl     $t4, $s2, 17
    xor     $s2, $s2, $t4
    sll     $t4, $s2, 5
    xor     $s2, $s2, $t4

    sll     $t0, $s0, 6
    ori     $t0, $t0, 0x1f      /* EntryLo0 candidate: PFN=i, C=3, D, V, G */
    sll     $t2, $s0, 6
    ori     $t2, $t2, 0x17      /* EntryLo1 candidate: PFN=i, C=2, V, G */
    andi    $t3, $s0, 31
    addiu   $t3, $t3, 2         /* Index candidate 2..33 */
    andi    $t5, $s2, 0x40
    sll     $t5, $t5, 7         /* PageMask candidate 0 or 0x2000 */
    beq     $t5, $zero, 0f
    nop
    li      $t5, 0x6000         /* 16 KB */
0:
    /* 1. EntryLo0 on a possibly-wrong path */
    andi    $t1, $s2, 1
    bnez    $t1, 1f
    nop
    mtc0    $t0, $2
    move    $s3, $t0
1:
    /* 2. EntryLo1 in a regular delay slot (always executes) */
    andi    $t1, $s2, 2
    beqz    $t1, 2f
    mtc0    $t2, $3
    nop
2:  move    $s4, $t2
    /* 3. Index in a branch-likely delay slot (executes only if taken) */
    andi    $t1, $s2, 4
    bnezl   $t1, 3f
    mtc0    $t3, $0
    b       4f
    nop
3:  move    $s5, $t3
4:
    /* 4. PageMask on a possibly-wrong path */
    andi    $t1, $s2, 8
    beqz    $t1, 5f
    nop
    mtc0    $t5, $5
    move    $s6, $t5
5:
    /* 5. Wired (still a SERIALIZING mtc0) in a branch-likely delay slot: the faulted-
     *    delay-slot funnel allocates it behind the mispredicted branch; it must not
     *    commit when the branch is not taken */
    andi    $t9, $s0, 1
    addiu   $t9, $t9, 2         /* Wired candidate 2 or 3 */
    andi    $t1, $s2, 16
    bnezl   $t1, 6f
    mtc0    $t9, $6
    b       7f
    nop
6:  move    $s7, $t9
7:
    mfc0    $t6, $6
    bne     $t6, $s7, fa
    nop

    /* mfc0 readback of all four */
    mfc0    $t6, $2
    bne     $t6, $s3, f1
    nop
    mfc0    $t6, $3
    bne     $t6, $s4, f2
    nop
    mfc0    $t6, $0
    andi    $t6, $t6, 0x3f
    bne     $t6, $s5, f3
    nop
    mfc0    $t6, $5
    bne     $t6, $s6, f4
    nop

    /* every 4th iteration: mtc0 back-to-back with tlbwi, then tlbr */
    andi    $t1, $s0, 3
    bnez    $t1, next
    nop
    sll     $t7, $s5, 20
    lui     $t6, 0x0080
    addu    $t7, $t7, $t6       /* EntryHi: VPN2 unique per Index (1 MB apart: no overlap at 16 KB pages) */
    mtc0    $t7, $10
    xori    $t0, $t0, 0x8       /* fresh EntryLo0: flip C bit 3 */
    mtc0    $t0, $2
    move    $s3, $t0
    tlbwi
    mtc0    $zero, $2           /* clobber staging; tlbr must restore */
    mtc0    $zero, $3
    mtc0    $zero, $5
    tlbr
    mfc0    $t6, $2
    bne     $t6, $s3, f5
    nop
    mfc0    $t6, $3
    bne     $t6, $s4, f6
    nop
    mfc0    $t6, $5
    bne     $t6, $s6, f7
    nop
    mfc0    $t6, $0
    andi    $t6, $t6, 0x3f
    bne     $t6, $s5, f8
    nop
    /* tlbp writes Index from the memory pipe; the mfc0 right behind it must see it */
    mtc0    $zero, $0           /* Index = 0 (a wrong answer if the probe is not seen) */
    mtc0    $t7, $10            /* EntryHi = the entry just written at Index s5 */
    tlbp
    mfc0    $t6, $0
    bne     $t6, $s5, f9        /* hit at s5, P bit clear */
    nop

next:
    addiu   $s0, $s0, 1
    bne     $s0, $s1, loop
    nop

    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('\n')
    HALT

f1: FAILC '1'
f2: FAILC '2'
f3: FAILC '3'
f4: FAILC '4'
f5: FAILC '5'
f6: FAILC '6'
f7: FAILC '7'
f8: FAILC '8'
f9: FAILC '9'
fa: FAILC 'A'
fail:
    SIMCON_PUTLIT('F')
    SIMCON_PUTCHAR($a3)
    SIMCON_PUTLIT('\n')
    HALT
