/*
 * test_xtlb.S  --  validate TLB-refill vs XTLB-refill exception vectoring.
 *
 * A TLB refill (no matching entry) must vector to:
 *   - 0x80000000 (TLB refill)   when the faulting access used 32-bit addressing
 *   - 0x80000080 (XTLB refill)  when it used 64-bit addressing
 * Vectoring to the general exception (0x180) is a failure.
 *
 * Self-contained: defines its own reset entry and its own vector handlers at
 * the exact BEV=0 offsets (no crt0).  Each handler prints which vector fired
 * and halts via the magic-halt register (store of non-zero data to kseg1
 * 0xBFD00000) -- no BREAK/ERET, so the handler never re-faults.
 *
 * Build-time mode select:
 *   -DMODE64 : enter 64-bit kernel mode (KX=1) and fault on an xkseg address
 *              (0x4000_0000_0001_0000).  Expect "VEC=XTLB".
 *   (default): stay in 32-bit kernel mode and fault on a kseg2 address
 *              (0xC000_0000).  Expect "VEC=TLB".
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

/* Halt the simulator: store non-zero data to the magic-halt register. */
    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

/* ================================================================
 * Exception vectors (BEV=0 layout), placed at 0x80000000 by link.ld
 * ================================================================ */
    .section .except_vec, "ax"

    .org    0x000               /* 32-bit TLB refill */
    .globl  _vec_tlb
_vec_tlb:
    SIMCON_PUTLIT('V')
    SIMCON_PUTLIT('E')
    SIMCON_PUTLIT('C')
    SIMCON_PUTLIT('=')
    SIMCON_PUTLIT('T')
    SIMCON_PUTLIT('L')
    SIMCON_PUTLIT('B')
    SIMCON_PUTLIT('\n')
    HALT

    .org    0x080               /* 64-bit XTLB refill */
    .globl  _vec_xtlb
_vec_xtlb:
    SIMCON_PUTLIT('V')
    SIMCON_PUTLIT('E')
    SIMCON_PUTLIT('C')
    SIMCON_PUTLIT('=')
    SIMCON_PUTLIT('X')
    SIMCON_PUTLIT('T')
    SIMCON_PUTLIT('L')
    SIMCON_PUTLIT('B')
    SIMCON_PUTLIT('\n')
    HALT

    .org    0x180               /* general exception */
    .globl  _vec_gen
_vec_gen:
    SIMCON_PUTLIT('V')
    SIMCON_PUTLIT('E')
    SIMCON_PUTLIT('C')
    SIMCON_PUTLIT('=')
    SIMCON_PUTLIT('G')
    SIMCON_PUTLIT('E')
    SIMCON_PUTLIT('N')
    SIMCON_PUTLIT('\n')
    HALT

/* ================================================================
 * Reset entry
 * ================================================================ */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
#ifdef MODE64
    /* Status = KX(bit7)=1, KSU=0(kernel), EXL=0, ERL=0, BEV=0, IE=0 */
    li      $t0, 0x80
#else
    /* Status = 32-bit kernel mode (KX=0), all clear */
    li      $t0, 0x00
#endif
    mtc0    $t0, $12            /* write Status */
    nop
    nop
    nop

#ifdef MODE64
    /* xkseg VA (bits 63:62 = 01, upper word != 0xFFFFFFFF): TLB-mapped,
     * 64-bit addressing.  Not present in the (empty) TLB -> refill. */
    dli     $t0, 0x4000000000010000
#else
    /* kseg2 VA (sign-extended 0xC0000000): TLB-mapped, 32-bit addressing.
     * Not present in the TLB -> refill. */
    li      $t0, 0xc0000000
#endif
    lw      $t1, 0($t0)         /* triggers a TLB refill exception */

    /* should be unreachable */
    SIMCON_PUTLIT('N')
    SIMCON_PUTLIT('O')
    SIMCON_PUTLIT('\n')
    HALT
    .size   _start, . - _start
