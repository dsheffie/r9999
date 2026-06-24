/*
 * fp_fpe.S -- FP exception (R4000 FPE, ExcCode 15) fault path + FCSR Cause/Flags.
 *
 * Phase-1 (fault path): exec w_fp_fault -> complete_bundle_2.faulted -> ROB is_fpe
 *   -> ARCH_FAULT -> CP0 cause 15.
 * Phase-2 (FCSR FCR31 values): the side-band {denorm,fflags} -> on a trap set
 *   FCSR.Cause (bits 17:12, E V Z O U I) and DO NOT touch sticky Flags; on a
 *   non-trapping FP op accumulate fflags into FCSR.Flags (bits 6:2) at retire.
 *
 *   T1: denormal operand -> unconditional trap (enables off); FCSR.Cause.E set.
 *   T2: inexact, enable OFF -> no trap, result correct (negative control).
 *   T3: inexact, enable ON -> trap; FCSR.Cause.I set AND Flags.I NOT set (trap
 *       suppresses accumulation).
 *   T4: inexact, enable OFF -> no trap; FCSR.Flags.I AND Cause.I set (accumulate).
 * Every trap must report ExcCode 15.  Prints 'P' on success, 'F' on any miss.
 * Self-contained (own vectors, no crt0).  Run under -c 0 (the co-sim checker
 * models neither FPE nor the FCSR Cause/Flags fields).
 *
 * FCSR bit layout: Cause E=17 V=16 Z=15 O=14 U=13 I=12; Enable I=7; Flags I=2.
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

/* General exception handler at 0x80000180 (BEV=0): record ExcCode, skip the
 * faulting instruction, return.  Does NOT clear FCSR (the main flow reads it). */
    .section .except_vec, "ax"
    .org    0x180
_exc_handler:
    la      $k0, fpe_flag
    li      $k1, 1
    sw      $k1, 0($k0)         /* fpe_flag = 1 */
    mfc0    $k0, $13            /* Cause */
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f      /* ExcCode */
    la      $k1, fpe_code
    sw      $k0, 0($k1)         /* fpe_code = ExcCode */
    mfc0    $k0, $14            /* EPC */
    addiu   $k0, $k0, 4         /* skip the faulting insn */
    mtc0    $k0, $14
    eret
    nop

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x20000000     /* Status: CU1=1 (FPU enabled), BEV=0, kernel, EXL=0 */
    mtc0    $t0, $12
    nop
    nop
    nop
    ctc1    $0, $31             /* FCSR = 0: no enables, RN, clear Cause/Flags */
    nop
    nop
    nop
    la      $19, fpe_flag       /* $19 = &fpe_flag (handler uses k0/k1) */

    /* ---- T1: denormal operand -> unconditional FPE (enables off) ---- */
    sw      $0, 0($19)
    li      $8, 1               /* 0x00000001 = smallest single denormal */
    mtc1    $8, $f0
    nop
    nop
    add.s   $f4, $f0, $f0       /* denorm operand -> Unimplemented -> MUST trap */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    beq     $2, $0, fail        /* flag NOT set -> denorm fault missed */
    nop
    la      $4, fpe_code
    lw      $2, 0($4)
    li      $3, 15
    bne     $2, $3, fail        /* must be ExcCode 15 */
    nop
    cfc1    $20, $31            /* FCSR.Cause.E (bit 17) must be set */
    nop
    srl     $21, $20, 17
    andi    $21, $21, 1
    beq     $21, $0, fail
    nop

    /* ---- T2: inexact, enable OFF -> NO trap (negative control) ---- */
    sw      $0, 0($19)
    lui     $8, 0x4060          /* 3.5f */
    mtc1    $8, $f6
    nop
    nop
    trunc.w.s $f8, $f6          /* (int)3.5 = 3, inexact; enables off -> no trap */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* spurious trap with enable off */
    nop
    mfc1    $9, $f8
    li      $3, 3
    bne     $9, $3, fail        /* result must still be 3 */
    nop

    /* ---- T3: inexact, enable ON (FCSR.Enable.I = bit 7) -> MUST trap ---- */
    ctc1    $0, $31             /* clear FCSR first (drop T1/T2 residue) */
    nop
    nop
    nop
    sw      $0, 0($19)
    li      $8, 0x80            /* FCSR: enable inexact (bit 7) */
    ctc1    $8, $31
    nop
    nop
    nop
    lui     $8, 0x4060          /* 3.5f */
    mtc1    $8, $f10
    nop
    nop
    trunc.w.s $f12, $f10        /* inexact + enabled -> MUST trap */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    beq     $2, $0, fail        /* flag NOT set -> enabled-inexact fault missed */
    nop
    la      $4, fpe_code
    lw      $2, 0($4)
    li      $3, 15
    bne     $2, $3, fail        /* must be ExcCode 15 */
    nop
    cfc1    $20, $31            /* Cause.I (bit 12) set, Flags.I (bit 2) NOT set */
    nop
    srl     $21, $20, 12
    andi    $21, $21, 1
    beq     $21, $0, fail       /* Cause.I must be set */
    nop
    srl     $21, $20, 2
    andi    $21, $21, 1
    bne     $21, $0, fail       /* a trapped op must NOT accumulate into Flags */
    nop

    /* ---- T4: inexact, enable OFF -> no trap; Flags.I + Cause.I accumulate ---- */
    ctc1    $0, $31             /* clear FCSR (no enables) */
    nop
    nop
    nop
    sw      $0, 0($19)
    lui     $8, 0x4060          /* 3.5f */
    mtc1    $8, $f14
    nop
    nop
    trunc.w.s $f16, $f14        /* inexact, enables off -> no trap, accumulate */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* must NOT trap */
    nop
    cfc1    $20, $31
    nop
    srl     $21, $20, 2
    andi    $21, $21, 1
    beq     $21, $0, fail       /* Flags.I must be set (sticky accumulate) */
    nop
    srl     $21, $20, 12
    andi    $21, $21, 1
    beq     $21, $0, fail       /* Cause.I must also be set */
    nop

    li      $25, 0x50           /* 'P' */
    mtc0    $25, $7
    HALT
fail:
    li      $25, 0x46           /* 'F' */
    mtc0    $25, $7
    HALT

    .data
    .align  3
fpe_flag:   .word 0
fpe_code:   .word 0
