/*
 * crt0.S  --  bare-metal startup for MIPS kseg0 test programs
 *
 * Layout (see link.ld):
 *   0x80000000  exception vectors  (.except_vec)
 *   0x80010000  test code/data     (.text, .rodata, .data, .bss)
 *   0x8007fff0  stack top          (_stack_top)
 */

#include "sim.h"

    .set    mips3
    .set    reorder         /* assembler manages delay slots */
    .set    noat

/* ------------------------------------------------------------------ */
/*  Exception vector stubs at BEV=0 offsets                           */
/*  These must live at 0x80000000 so the OS can use them later.       */
/* ------------------------------------------------------------------ */
    .section .except_vec, "ax"
    .org    0x000           /* TLB refill (BEV=0) */
    .globl  _tlb_refill_vec
_tlb_refill_vec:
    break   /* placeholder -- not yet handled */

    .org    0x080           /* XTLB miss (64-bit mode) */
    break

    .org    0x100           /* Cache error */
    break

    .org    0x180           /* General exception */
    .globl  _general_exc_vec
_general_exc_vec:
    break   /* placeholder -- override in tests that need it */

/* ------------------------------------------------------------------ */
/*  Reset / program entry point                                        */
/* ------------------------------------------------------------------ */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    /* Initialise stack pointer */
    lui     $sp, %hi(_stack_top)
    addiu   $sp, $sp, %lo(_stack_top)

    /* Zero BSS (word-aligned) */
    la      $t0, __bss_start
    la      $t1, __bss_end
.Lbss_loop:
    beq     $t0, $t1, .Lbss_done
    sw      $zero, 0($t0)
    addiu   $t0, $t0, 4
    b       .Lbss_loop
.Lbss_done:

    /* Call main(0, NULL, NULL) */
    move    $a0, $zero
    move    $a1, $zero
    move    $a2, $zero
    jal     main

    /* main returned -- use the return value as exit code
     * (currently the simulator just breaks here) */
    break
    .size   _start, . - _start
