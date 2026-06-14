/*
 * test_cache_priv.S  --  CACHE in user mode raises Coprocessor Unusable (CpU)
 *
 * CACHE is privileged: legal in kernel mode, but in user mode it must raise a
 * Coprocessor Unusable exception (Cause.ExcCode == 11).  The CACHE instruction
 * itself must be fetched from a user-accessible (TLB-mapped) page, since a
 * kseg0 fetch in user mode would fault AdEL first.
 *
 * Setup (in kernel mode):
 *   - map useg VA 0x00400000 -> PA 0x00400000 (global, V=1) in the TLB,
 *   - write a tiny user stub to that page (via the kseg1 uncached alias so the
 *     later instruction fetch sees it): "cache 0x0,0($0)" then a self-loop,
 *   - ERET into user mode at 0x00400000.
 *   - the CACHE faults CpU -> general vector 0x80000180; the handler checks
 *     Cause.ExcCode == 11 and prints PASS, else FAIL.  No PASS within the
 *     watchdog (e.g. CACHE didn't fault) is also a failure.
 *
 * RTL self-check only (-c 0): the interpreter does not model CP0 privilege.
 * Self-contained (own vectors), halts via the magic-halt register.
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
 * General exception handler at 0x80000180 (BEV=0) -- CpU lands here
 * ================================================================ */
    .section .except_vec, "ax"
    .org    0x180
    .globl  _vec_gen
_vec_gen:
    mfc0    $k0, $13            /* Cause */
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f      /* ExcCode */
    li      $k1, 11             /* Coprocessor Unusable */
    bne     $k0, $k1, _bad
    nop
    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT
_bad:
    SIMCON_PUTLIT('F')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('I')
    SIMCON_PUTLIT('L')
    SIMCON_PUTLIT('\n')
    HALT

/* ================================================================
 * Reset entry (kernel mode)
 * ================================================================ */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00           /* BEV=0, kernel, EXL=0, ERL=0, KX=0 */
    mtc0    $t0, $12
    nop
    nop
    nop

    /* ---- map useg VA 0x00400000 -> PA 0x00400000 (global) ---- */
    li      $t0, 0x00400000     /* EntryHi: VPN2=0x200, ASID=0 */
    mtc0    $t0, $10
    li      $t0, 0x0001001f     /* EntryLo0: PFN=0x400, C=3, D=1, V=1, G=1 */
    mtc0    $t0, $2
    li      $t0, 0x0001005f     /* EntryLo1: PFN=0x401, C=3, D=1, V=1, G=1 */
    mtc0    $t0, $3
    mtc0    $zero, $5           /* PageMask = 0 (4 KB) */
    mtc0    $zero, $0           /* Index = 0 */
    tlbwi
    nop

    /* ---- write the user stub to PA 0x00400000 via the kseg1 alias ---- */
    li      $t0, 0xA0400000
    li      $t1, 0xbc000000     /* cache 0x0, 0($zero)  (I-Index-Invalidate) */
    sw      $t1, 0($t0)
    li      $t1, 0x1000ffff     /* b . (self-loop, in case CACHE fails to fault) */
    sw      $t1, 4($t0)
    sw      $zero, 8($t0)       /* nop (delay slot) */

    /* ---- ERET into user mode at 0x00400000 ---- */
    li      $t0, 0x00400000
    mtc0    $t0, $14            /* EPC */
    li      $t0, 0x12           /* Status: KSU=2 (user), EXL=1 -> ERET clears EXL */
    mtc0    $t0, $12
    nop
    nop
    eret
    nop
    .size   _start, . - _start
