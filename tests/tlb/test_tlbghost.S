/*
 * test_tlbghost.S  --  hunt WRONG-PATH (ghost) TLBWR side effects.
 *
 * TLBWR/TLBWI are oldest_first: they issue only when rob_ptr ==
 * head_of_rob_ptr.  r9999 takes mispredict restarts at COMMIT, so there is a
 * suspected race: the mispredicted branch commits -> head bumps onto the
 * wrong-path tlbwr already sitting ready in the ALU scheduler -> if the
 * flash-clear lands a cycle later the tlbwr issues and pulses
 * tlb_entry_out_valid = a GHOST TLB write (both CAM+shadow, consistently) of
 * wrong-path staging data at the current Random.  Ghost entries = duplicate /
 * stale keys = the IRIX mapped-corruption signature (silicon TLBSWEEP2:
 * 13/21 live entries probing to a different index).
 *
 * Method: 32 iterations; iteration i stages a unique sentinel
 * EntryHi = 0x00700000 + i*0x2000, then takes an xorshift-random branch:
 *   taken     -> skip the tlbwr  (architecturally NOT written)
 *   not-taken -> tlbwr           (architecturally written; bit i set in s7)
 * A predicted-not-taken/actually-taken mispredict fetches the wrong-path
 * tlbwr into the scheduler -> the suspected commit-window ghost.
 *
 * Verdict per sentinel: tlbp hit && bit clear  ->  GHOST  -> FAIL 'G'
 *                       miss && bit set        ->  legal Random-collision
 *                                                  eviction -> ignored
 * PASS if no ghosts.  Self-contained, RTL-only (-c 0), magic-halt.
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
    mtc0    $zero, $5           /* PageMask = 0 (4KB) */
    li      $t0, 2
    mtc0    $t0, $6             /* Wired=2: keep Random in [2..47] */

    li      $s2, 0x2545f491     /* xorshift32 seed */
    move    $s7, $zero          /* bitmap: bit i = sentinel i architecturally written */
    li      $s0, 0              /* i */
    li      $s1, 32

loop:
    /* stage sentinel i: EntryHi=0x00700000+i*0x2000, lo0/lo1 valid+global */
    sll     $t0, $s0, 13
    lui     $t1, 0x0070
    addu    $t0, $t0, $t1
    mtc0    $t0, $10
    li      $t1, 0x0000801f
    mtc0    $t1, $2
    li      $t1, 0x0000805f
    mtc0    $t1, $3

    /* xorshift32 -> unpredictable low bit */
    sll     $t2, $s2, 13
    xor     $s2, $s2, $t2
    srl     $t2, $s2, 17
    xor     $s2, $s2, $t2
    sll     $t2, $s2, 5
    xor     $s2, $s2, $t2
    andi    $t3, $s2, 1

    bnez    $t3, 1f             /* ~50/50: taken -> skip the tlbwr */
    nop
    tlbwr                       /* not-taken (architectural) path */
    li      $t4, 1
    sllv    $t4, $t4, $s0
    or      $s7, $s7, $t4       /* record: sentinel i legitimately written */
1:  addiu   $s0, $s0, 1
    bne     $s0, $s1, loop
    nop

    /* ---- verdict: probe each sentinel; hit with bit CLEAR = ghost ---- */
    li      $s0, 0
check:
    sll     $t0, $s0, 13
    lui     $t1, 0x0070
    addu    $t0, $t0, $t1
    mtc0    $t0, $10            /* EntryHi = sentinel i (ASID 0) */
    nop
    tlbp
    nop
    mfc0    $t2, $0
    bltz    $t2, 2f             /* miss: fine either way (eviction is legal) */
    nop
    li      $t4, 1
    sllv    $t4, $t4, $s0
    and     $t4, $t4, $s7
    bnez    $t4, 2f             /* hit and expected -> ok */
    nop
    li      $a3, 'G'            /* hit but NEVER architecturally written: GHOST */
    move    $a0, $s0
    b       fail
    move    $t2, $t2
2:  addiu   $s0, $s0, 1
    li      $t5, 32
    bne     $s0, $t5, check
    nop

    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT

/* fail: print F<phase> <a0-hex8> <t2-hex8>, halt */
fail:
    move    $a1, $t2
    SIMCON_PUTLIT('F')
    mtc0    $a3, $7
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
