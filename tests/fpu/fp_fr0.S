/*
 * fp_fr0.S -- FR=0 (o32) FP-compute register rules.
 *
 * In FR=0 the FPRs are 16 even/odd 32-bit pairs and ARITHMETIC is even-register
 * only (R10000 UM p.307).  An odd register on a compute op is UNPREDICTABLE in
 * the MIPS ISA (no mandated exception; Sail doesn't even model FR) -- r9999
 * CHOOSES a loud Reserved Instruction (ExcCode 10) rather than the R10000's
 * silent force-to-even.  This checks:
 *   T1: FR=0, EVEN-reg add.s  -> runs, 1.0+2.0=3.0, no fault.
 *   T2: FR=0, ODD-reg  add.s  -> Reserved Instruction (cause 10).  (.word: gas
 *       refuses odd FP regs under .set mips3.)
 *   T3: FR=1, ODD-reg  add.s  -> runs, no fault (FR=1 has no even/odd rule).
 * Prints 'P'/'F'.  Self-contained (own vectors, no crt0).  Run under -c 0.
 *   1.0=0x3f800000  2.0=0x40000000  3.0=0x40400000
 *   add.s $f5,$f0,$f2 (fd=$f5 odd) = 0x46020140
 *   Status: CU1=1 (bit29); FR = bit26.
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

/* handler @0x80000180: record ExcCode, skip the faulting insn, return. */
    .section .except_vec, "ax"
    .org    0x180
_exc_handler:
    la      $k0, fpe_flag
    li      $k1, 1
    sw      $k1, 0($k0)
    mfc0    $k0, $13
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f
    la      $k1, fpe_code
    sw      $k0, 0($k1)
    mfc0    $k0, $14
    addiu   $k0, $k0, 4
    mtc0    $k0, $14
    eret
    nop

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x20000000     /* Status: CU1=1, FR=0 (bit26 clear), BEV=0, kernel */
    mtc0    $t0, $12
    nop
    nop
    nop
    la      $19, fpe_flag

    /* ---- T1: FR=0 even-reg add.s -> runs, 3.0 ---- */
    sw      $0, 0($19)
    lui     $8, 0x3f80          /* 1.0 */
    mtc1    $8, $f0
    lui     $8, 0x4000          /* 2.0 */
    mtc1    $8, $f2
    add.s   $f4, $f0, $f2       /* even regs -> legal in FR=0 */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* must NOT fault */
    nop
    mfc1    $9, $f4
    lui     $3, 0x4040          /* 3.0 */
    bne     $9, $3, fail
    nop

    /* ---- T2: FR=0 odd-reg add.s -> Reserved Instruction (cause 10) ---- */
    sw      $0, 0($19)
    .word   0x46020140          /* add.s $f5,$f0,$f2 (fd=$f5 odd) */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    beq     $2, $0, fail        /* must fault */
    nop
    la      $4, fpe_code
    lw      $2, 0($4)
    li      $3, 10              /* Reserved Instruction */
    bne     $2, $3, fail
    nop

    /* ---- T3: FR=1 odd-reg add.s -> runs, no fault ---- */
    li      $t0, 0x24000000     /* Status: CU1=1, FR=1 (bit26 set) */
    mtc0    $t0, $12
    nop
    nop
    nop
    sw      $0, 0($19)
    .word   0x46020140          /* add.s $f5,$f0,$f2 -- legal when FR=1 */
    nop
    nop
    nop
    nop
    lw      $2, 0($19)
    bne     $2, $0, fail        /* must NOT fault in FR=1 */
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
