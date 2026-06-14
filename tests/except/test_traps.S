/*
 * test_traps.S -- trap instructions + REGIMM branch-and-link (self-contained).
 *
 * Regression for the decode gaps surfaced by the cheritest import:
 *   - register traps TGE/TGEU/TLT/TLTU (TEQ/TNE already worked)
 *   - trap-immediates TGEI/TGEIU/TLTI/TLTIU/TEQI/TNEI
 *   - branch-and-link BLTZAL/BLTZALL/BGEZALL (BGEZAL already worked)
 * All of these previously RI'd.
 *
 * A general-exception handler counts traps and skips the faulting insn.  The
 * test runs a fixed sequence and checks the trap count, plus a BLTZAL link.
 * Prints 'P' on success; runs clean under the co-sim checker.
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
    .org    0x180
_exc_handler:
    la      $k0, trap_count
    lw      $k1, 0($k0)
    addiu   $k1, $k1, 1
    sw      $k1, 0($k0)         /* trap_count++ */
    mfc0    $k0, $14
    addiu   $k0, $k0, 4         /* skip the trapping insn */
    mtc0    $k0, $14
    eret
    nop

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00           /* BEV=0, kernel, EXL=0 */
    mtc0    $t0, $12
    nop
    nop
    nop
    la      $19, trap_count
    sw      $0, 0($19)

    /* ---- register traps ---- */
    li  $8, 5 ; li $9, 3 ; tge  $8, $9          /* 5>=3  -> trap */
    li  $8, 3 ; li $9, 5 ; tge  $8, $9          /* 3>=5  -> no trap */
    li  $8, 3 ; li $9, 5 ; tlt  $8, $9          /* 3<5   -> trap */
    li  $8, 1 ; li $9, -1; tltu $8, $9          /* 1 < 0xffff..ff (uns) -> trap */
    li  $8, 7 ; li $9, 7 ; teq  $8, $9          /* ==    -> trap */
    li  $8, 7 ; li $9, 8 ; tne  $8, $9          /* !=    -> trap */
    li  $8, 9 ; li $9, 2 ; tgeu $8, $9          /* 9>=2 (uns) -> trap */

    /* ---- trap-immediates ---- */
    li  $8, 5 ; tgei  $8, 3                     /* 5>=3  -> trap */
    li  $8, 3 ; tlti  $8, 5                     /* 3<5   -> trap */
    li  $8, 7 ; teqi  $8, 7                     /* ==    -> trap */
    li  $8, 7 ; tnei  $8, 8                     /* !=    -> trap */
    li  $8, 3 ; tltiu $8, 5                     /* 3<5 (uns) -> trap */
    li  $8, 9 ; tgeiu $8, 2                     /* 9>=2 (uns) -> trap */
    li  $8, 3 ; tgei  $8, 9                     /* 3>=9  -> no trap */

    /* expect 12 traps so far */
    lw  $2, 0($19)
    li  $3, 12
    bne $2, $3, fail
    nop

    /* ---- BLTZAL: taken (rs<0), links $31 = addr after delay slot ---- */
    li  $8, -1
bltzal_site:
    bltzal $8, bl_taken
    nop
link_pt:                        /* = bltzal_site + 8 = the architectural link value */
    j   fail                    /* not-taken path -> fail */
    nop
bl_taken:
    la  $21, link_pt            /* expected link */
    bne $31, $21, fail
    nop

    /* ---- BGEZALL (likely), not taken (rs<0): delay slot nullified ---- */
    li  $8, -1
    li  $22, 0
    bgezall $8, fail            /* rs<0 -> not taken */
    addiu $22, $22, 1           /* likely + not taken -> THIS must be nullified */
    bne $22, $0, fail           /* if it ran, $22==1 -> fail */
    nop

    li  $25, 0x50               /* 'P' */
    mtc0 $25, $7
    HALT
fail:
    li  $25, 0x46               /* 'F' */
    mtc0 $25, $7
    HALT

    .data
    .align 3
trap_count: .word 0
