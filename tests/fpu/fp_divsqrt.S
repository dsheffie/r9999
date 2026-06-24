/*
 * fp_divsqrt.S -- DIV.[sd] / SQRT.[sd] are NOT implemented in hardware: the fpu
 * raises the Unimplemented-Op (E) bit, so each one faults (FPE, ExcCode 15, with
 * FCSR.Cause.E set) and the OS soft-float emulator is expected to handle it.
 *
 * This verifies the HARDWARE behaviour: every div/sqrt traps with ExcCode 15 and
 * FCSR.Cause.E (bit 17) set, regardless of FCSR enables (E has no enable bit).
 * Prints 'P' on success, 'F' on any miss.  Self-contained (own vectors, no crt0).
 * Run under -c 0 (the co-sim checker neither faults nor models FCSR).
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
 * faulting instruction, return. */
    .section .except_vec, "ax"
    .org    0x180
_exc_handler:
    la      $k0, fpe_flag
    li      $k1, 1
    sw      $k1, 0($k0)
    mfc0    $k0, $13            /* Cause */
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f      /* ExcCode */
    la      $k1, fpe_code
    sw      $k0, 0($k1)
    mfc0    $k0, $14            /* EPC */
    addiu   $k0, $k0, 4         /* skip the faulting insn */
    mtc0    $k0, $14
    eret
    nop

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x20000000     /* Status: CU1=1 (FPU enabled), BEV=0, kernel */
    mtc0    $t0, $12
    nop
    nop
    nop
    la      $19, fpe_flag

    /* operands (values are irrelevant -- every op faults): $f0=1.0s, $f2=2.0s */
    lui     $8, 0x3f80          /* 1.0f */
    mtc1    $8, $f0
    lui     $8, 0x4000          /* 2.0f */
    mtc1    $8, $f2

    /* ---- T1: DIV.S -> FPE, ExcCode 15, Cause.E ---- */
    ctc1    $0, $31
    nop
    nop
    nop
    sw      $0, 0($19)
    div.s   $f4, $f0, $f2
    nop
    nop
    nop
    nop
    bal     check_fpe_e
    nop

    /* ---- T2: SQRT.S ---- */
    ctc1    $0, $31
    nop
    nop
    nop
    sw      $0, 0($19)
    sqrt.s  $f4, $f2
    nop
    nop
    nop
    nop
    bal     check_fpe_e
    nop

    /* ---- T3: DIV.D ---- */
    ctc1    $0, $31
    nop
    nop
    nop
    sw      $0, 0($19)
    div.d   $f4, $f0, $f2
    nop
    nop
    nop
    nop
    bal     check_fpe_e
    nop

    /* ---- T4: SQRT.D ---- */
    ctc1    $0, $31
    nop
    nop
    nop
    sw      $0, 0($19)
    sqrt.d  $f4, $f2
    nop
    nop
    nop
    nop
    bal     check_fpe_e
    nop

    li      $25, 0x50           /* 'P' */
    mtc0    $25, $7
    HALT
fail:
    li      $25, 0x46           /* 'F' */
    mtc0    $25, $7
    HALT

/* check that the last op trapped with ExcCode 15 and FCSR.Cause.E (bit 17) set.
 * uses $2,$3,$4,$20,$21; returns via $ra (bal). branches to fail on mismatch. */
check_fpe_e:
    lw      $2, 0($19)
    beq     $2, $0, fail        /* must have trapped */
    nop
    la      $4, fpe_code
    lw      $2, 0($4)
    li      $3, 15
    bne     $2, $3, fail        /* ExcCode 15 */
    nop
    cfc1    $20, $31
    nop
    srl     $21, $20, 17
    andi    $21, $21, 1
    beq     $21, $0, fail       /* Cause.E must be set */
    nop
    jr      $ra
    nop

    .data
    .align  3
fpe_flag:   .word 0
fpe_code:   .word 0
