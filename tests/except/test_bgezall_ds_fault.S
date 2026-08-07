/*
 * test_bgezall_ds_fault.S -- branch-and-link whose DELAY SLOT takes a TLB refill.
 *
 * WHAT THIS CATCHES (observed in IRIX `be`, henry_tb, 2026-08-06)
 * --------------------------------------------------------------
 * MIPSpro emits `bgezall $zero, target` as an unconditional call idiom ($zero >= 0
 * is always true).  In the failing trace the delay slot was a load that missed the
 * TLB, and the retire order came out:
 *
 *     bgezall          <- branch retires
 *     <target>+0x00    <- TARGET RETIRES, committing `addiu sp,sp,-112`
 *     <target>+0x04    <- and its stores
 *     bgezall          <- restart at the branch (EPC=branch, BD set: correct)
 *     <delay slot>     <- delay slot only retires HERE
 *     <target>+0x00    <- prologue runs a SECOND time -> sp decremented TWICE
 *
 * The delay slot never retired before the branch target did, which violates
 * in-order retirement (the delay slot precedes the target in program order).
 * Restarting at the branch -- correct behaviour for a faulting delay slot -- then
 * re-executes a prologue whose sp update had ALREADY COMMITTED.  sp ends up one
 * frame too low, and every later frame access reads the wrong stack slot.
 *
 * THE CHECK
 * ---------
 * The "callee" does nothing but `addiu sp,sp,-FRAME` and return.  A correct
 * machine executes that exactly once per call, so sp must move by exactly FRAME.
 * The bug makes it move by 2*FRAME.  We compare against a golden delta computed
 * from the SAME callee reached with a NON-faulting delay slot, so the test does
 * not bake in any assumption about the core's frame handling -- only that a
 * faulting delay slot must not change how many times the target commits.
 *
 * Also checked: ra must equal branch+8 (the *al family links unconditionally --
 * r9999 previously gated the link on branch-taken, which broke PIC linkers), and
 * the delay slot must actually have executed (its load result must be visible).
 *
 * Coverage note: randgen emits neither bgezall nor faulting delay slots, which is
 * why ~600 randgen tests and a full csmith sweep never surfaced this.
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

/* Halt the simulator: store non-zero to the magic-halt register. */
    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

#define FRAME   112             /* same frame size as the be function that failed */

/* How long the TLB-refill handler stalls before installing the mapping.  The real
 * failure had a ~500-cycle resolution; override with -DREFILL_DELAY=N to sweep. */
#ifndef REFILL_DELAY
#define REFILL_DELAY 200
#endif

/* VA whose translation we deliberately leave uninstalled so the delay-slot load
 * misses.  kuseg (mapped); the refill handler installs it on demand. */
#define TESTVA  0x00400000
#define TESTPFN 0x00000200      /* PA 0x200000 */

/* ================================================================
 * 32-bit TLB refill vector (BEV=0) at 0x80000000
 * Installs the mapping for TESTVA and returns; the faulting delay-slot
 * load then re-executes and succeeds -- exactly the IRIX sequence.
 * ================================================================ */
    .section .except_vec, "ax"
    .org    0x000
    .globl  _tlb_refill
_tlb_refill:
    la      $k0, refill_count
    lw      $k1, 0($k0)
    addiu   $k1, $k1, 1
    sw      $k1, 0($k0)         /* count refills so we can prove one happened */

    /* SLOW the handler down (REFILL_DELAY iterations).  In the IRIX failure the
     * refill took ~500 cycles and the branch retired THREE times across two
     * exceptions -- the branch TARGET only wins the race to retire when the fault
     * resolution is long enough.  A fast handler resolves before the target can
     * commit, which is why the minimal version of this test passed. */
    li      $k1, REFILL_DELAY
1:  addiu   $k1, $k1, -1
    bne     $k1, $zero, 1b
    nop

    /* EntryHi already holds the faulting VPN2 (hardware wrote it). */
    li      $k0, ((TESTPFN << 6) | 0x1e)    /* PFN, C=3, D=1, V=1, G=0 */
    mtc0    $k0, $2                          /* EntryLo0 */
    li      $k0, (((TESTPFN + 1) << 6) | 0x1e)
    mtc0    $k0, $3                          /* EntryLo1 */
    mtc0    $zero, $5                        /* PageMask = 0 (4 KB) */
    li      $k0, 4
    mtc0    $k0, $0                          /* Index = 4 (outside Wired) */
    nop
    tlbwi
    nop
    nop
    eret
    nop

/* ================================================================
 * General exception vector at 0x80000180 -- nothing should land here.
 * If it does, record the cause so the failure is diagnosable.
 * ================================================================ */
    .org    0x180
    .globl  _exc_handler
_exc_handler:
    la      $k0, unexpected_exc
    li      $k1, 1
    sw      $k1, 0($k0)
    mfc0    $k0, $13
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f
    la      $k1, unexpected_code
    sw      $k0, 0($k1)
    HALT

/* ================================================================
 * Reset entry
 * ================================================================ */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    mtc0    $zero, $12          /* Status: BEV=0, kernel, EXL=0, ERL=0, IE=0 */
    nop
    nop
    nop
    mtc0    $zero, $5           /* PageMask = 0 */
    li      $t0, 2
    mtc0    $t0, $6             /* Wired = 2 */
    mtc0    $zero, $10          /* EntryHi: ASID 0 */
    nop

    /* zero the bookkeeping words */
    la      $t0, refill_count
    sw      $zero, 0($t0)
    la      $t0, unexpected_exc
    sw      $zero, 0($t0)
    la      $t0, unexpected_code
    sw      $zero, 0($t0)

    /* stack */
    li      $sp, 0x80070000

    la      $a0, msg_start
    jal     sim_puts
    nop

    /* ============================================================
     * Phase 1 -- GOLDEN: same callee, delay slot that CANNOT fault.
     * Establishes how far sp moves for one call on this machine.
     * ============================================================ */
    move    $s0, $sp                    /* sp before */
    .globl  golden_branch
golden_branch:
    bgezall $zero, callee
    nop                                 /* delay slot: cannot fault */
    move    $s1, $sp                    /* sp after */
    subu    $s2, $s0, $s1               /* s2 = golden delta (expect FRAME) */
    move    $s3, $ra                    /* golden linked ra */

    /* restore sp for phase 2 */
    move    $sp, $s0

    /* ============================================================
     * Phase 2 -- THE TEST: identical call, but the delay slot is a
     * load through an UNMAPPED VA, so it takes a TLB refill.
     * ============================================================ */
    /* Stage TESTVA in UNCACHED memory so the load that produces the delay slot's
     * base register is slow.  This mirrors the real code:
     *     lw a0,4(s1)  /  bgezall  /  lw a0,28(a0)
     * the delay-slot load DEPENDS on a prior load, so it cannot issue -- and its
     * fault cannot be discovered -- until that load returns.  That late discovery
     * is what gives the branch target time to execute and RETIRE.  With a0 set by
     * an immediate the fault resolves at once and the target never gets ahead. */
    li      $t0, 0xA0002000             /* kseg1: uncached, unmapped */
    li      $t1, TESTVA
    sw      $t1, 4($t0)                 /* [0xA0002004] = TESTVA */
    move    $s4, $sp                    /* sp before */
    /* Independent long-latency work in flight across the branch: the minimal test
     * had an almost-empty ROB, so the target could never race ahead of the delay
     * slot.  These multiplies keep the window occupied without touching sp/ra. */
    li      $t4, 0x12345678
    li      $t5, 0x9abcdef0
    mult    $t4, $t5
    mflo    $t6
    mult    $t6, $t5
    mult    $t4, $t6
    lw      $a0, 4($t0)                 /* SLOW uncached load -> a0 = TESTVA */
    .globl  faulting_branch
faulting_branch:
    bgezall $zero, callee
    lw      $a1, 0($a0)                 /* DELAY SLOT: depends on the slow load */
    move    $s5, $sp                    /* sp after */
    subu    $s6, $s4, $s5               /* s6 = delta under test */
    move    $s7, $ra                    /* linked ra under test */

    /* ============================================================
     * Checks
     * ============================================================ */

    /* 1. the refill actually happened (else the test proved nothing) */
    la      $t0, refill_count
    lw      $t1, 0($t0)
    beq     $t1, $zero, fail_norefill
    nop

    /* 2. no unexpected exception */
    la      $t0, unexpected_exc
    lw      $t1, 0($t0)
    bne     $t1, $zero, fail_exc
    nop

    /* 3. THE BUG: sp must move by the same amount as the golden call.
     *    Double-commit of the prologue makes s6 == 2 * s2. */
    bne     $s6, $s2, fail_sp
    nop

    /* 4. the *al link is unconditional and points at branch+8 */
    la      $t0, faulting_branch
    addiu   $t0, $t0, 8
    bne     $s7, $t0, fail_ra
    nop
    bne     $s3, $s3, fail_ra           /* (golden ra sanity, never taken) */
    nop

    /* 5. the delay slot really executed -- its load result must be present.
     *    PA 0x200000 is untouched DRAM; we only require the load retired
     *    without leaving a2 as the pre-load poison. */
    li      $t0, 0xdeadbeef
    beq     $a1, $t0, fail_ds
    nop

    la      $a0, msg_pass
    jal     sim_puts
    nop
    HALT

/* ----------------------------------------------------------------
 * The callee: one frame allocation and a return.  Deliberately minimal
 * so the only architectural effect of calling it is the sp delta.
 * ---------------------------------------------------------------- */
    .globl  callee
    .type   callee, @function
callee:
    addiu   $sp, $sp, -FRAME            /* the instruction that must commit ONCE */
    /* mirror the be prologue's stores.  sw, not sd: Status=0 means KX=0, and this
     * core RIs 64-bit ops in 32-bit mode, which would trip the unexpected-exception
     * check for a reason unrelated to what we are testing. */
    sw      $s2, 56($sp)
    sw      $a0, 16($sp)
    jr      $ra
    nop                                 /* NOTE: no sp restore -- caller measures */

/* ---- failure exits ---- */
fail_norefill:
    la      $a0, msg_fail_norefill
    jal     sim_puts
    nop
    HALT
fail_exc:
    la      $a0, msg_fail_exc
    jal     sim_puts
    nop
    HALT
fail_sp:
    la      $a0, msg_fail_sp
    jal     sim_puts
    nop
    HALT
fail_ra:
    la      $a0, msg_fail_ra
    jal     sim_puts
    nop
    HALT
fail_ds:
    la      $a0, msg_fail_ds
    jal     sim_puts
    nop
    HALT

/* ----------------------------------------------------------------
 * sim_puts -- write a NUL-terminated string via the CP0 reg7 FIFO
 * ---------------------------------------------------------------- */
    .globl  sim_puts
    .type   sim_puts, @function
sim_puts:
    lbu     $t9, 0($a0)
    beq     $t9, $zero, 2f
    nop
1:  SIMCON_PUTCHAR($t9)
    addiu   $a0, $a0, 1
    lbu     $t9, 0($a0)
    bne     $t9, $zero, 1b
    nop
2:  jr      $ra
    nop

    .section .data
    .align  2
refill_count:    .word 0
unexpected_exc:  .word 0
unexpected_code: .word 0

    .section .rodata
msg_start:
    .asciiz "bgezall delay-slot-fault test\n"
msg_pass:
    .asciiz "PASS: sp moved once per call\n"
msg_fail_norefill:
    .asciiz "FAIL: no TLB refill -- delay slot never faulted, test vacuous\n"
msg_fail_exc:
    .asciiz "FAIL: unexpected exception\n"
msg_fail_sp:
    .asciiz "FAIL: sp delta differs from golden -- target committed more than once\n"
msg_fail_ra:
    .asciiz "FAIL: bgezall did not link branch+8\n"
msg_fail_ds:
    .asciiz "FAIL: delay slot did not execute\n"
