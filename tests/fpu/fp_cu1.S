/*
 * fp_cu1.S -- lazy-FPU Coprocessor-Unusable (CpU) path.
 *
 * With Status.CU1=0 a COP1 instruction must trap: Coprocessor Unusable,
 * ExcCode 11, with Cause.CE = 1 (coprocessor 1 / FPU).  After the handler
 * enables CU1, FP executes normally.
 *   T1: CU1=0, cfc1 -> CpU trap; verify ExcCode==11 AND Cause.CE==1.
 *   T2: CU1=1 (set by the handler), add.s runs, 1.0+2.0=3.0, no trap.
 * Prints 'P'/'F'.  Self-contained (own vectors, no crt0).  Run under -c 0.
 *
 * Cause.CE = bits [29:28]; ExcCode = bits [6:2].
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

/* Handler at 0x80000180: record ExcCode + CE, ENABLE CU1, skip the faulting
 * insn, return. */
    .section .except_vec, "ax"
    .org    0x180
_exc_handler:
    la      $k0, fpe_flag
    li      $k1, 1
    sw      $k1, 0($k0)         /* fpe_flag = 1 */
    mfc0    $k0, $13            /* Cause */
    srl     $k1, $k0, 2
    andi    $k1, $k1, 0x1f      /* ExcCode */
    la      $k0, fpe_code
    sw      $k1, 0($k0)
    mfc0    $k0, $13            /* Cause again -> CE */
    srl     $k0, $k0, 28
    andi    $k0, $k0, 0x3       /* CE field */
    la      $k1, fpe_ce
    sw      $k0, 0($k1)
    mfc0    $k0, $12            /* enable CU1 so re-run won't re-trap */
    lui     $k1, 0x2000
    or      $k0, $k0, $k1
    mtc0    $k0, $12
    mfc0    $k0, $14            /* EPC */
    addiu   $k0, $k0, 4         /* skip the faulting insn */
    mtc0    $k0, $14
    eret
    nop

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00           /* Status: CU1=0 (FPU disabled), BEV=0, kernel */
    mtc0    $t0, $12
    nop
    nop
    nop
    la      $19, fpe_flag

    /* ---- T1: COP1 with CU1=0 -> CpU (ExcCode 11, CE=1) ---- */
    sw      $0, 0($19)
    cfc1    $20, $31            /* CP1 op, CU1=0 -> MUST trap */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    beq     $2, $0, fail        /* no trap -> CU1 gate missing */
    nop
    la      $4, fpe_code
    lw      $2, 0($4)
    li      $3, 11
    bne     $2, $3, fail        /* ExcCode must be 11 (CpU) */
    nop
    la      $4, fpe_ce
    lw      $2, 0($4)
    li      $3, 1
    bne     $2, $3, fail        /* Cause.CE must be 1 (CP1) */
    nop

    /* ---- T2: CU1 now enabled by handler -> FP runs, no trap ---- */
    sw      $0, 0($19)
    lui     $8, 0x3f80          /* 1.0f */
    mtc1    $8, $f0
    lui     $8, 0x4000          /* 2.0f */
    mtc1    $8, $f2
    add.s   $f4, $f0, $f2       /* 1.0 + 2.0 = 3.0 */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* spurious trap with CU1=1 */
    nop
    mfc1    $9, $f4
    lui     $3, 0x4040          /* 3.0f */
    bne     $9, $3, fail
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
fpe_ce:     .word 0
