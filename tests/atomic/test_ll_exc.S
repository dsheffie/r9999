/*
 * test_ll_exc.S -- LL/SC reservation across an EXCEPTION (the malloc-under-
 * interrupt scenario, which the existing atomic tests do NOT cover).
 *
 * R4000/R4400: the LLbit (reservation) is cleared by ERET (and on exception
 * entry).  So an LL, then ANY exception+ERET, then SC -> the SC MUST FAIL.
 * If the RTL leaves the reservation valid across the exception, the SC
 * spuriously SUCCEEDS -- which for a lock-free allocator means an update
 * computed from a now-stale free-list head commits anyway => heap corruption
 * (exactly the IRIX o32 malloc-overlap crash).
 *
 * Self-contained (own reset entry + vectors at BEV=0 offsets, no crt0, like
 * test_except.S).  Console: 'P' on pass, 'F' on fail; BREAK halts the sim.
 *
 * Subtest 1: LL; syscall (handler just ERETs); SC   -> MUST FAIL, mem unchanged.
 * Subtest 2: LL; syscall (handler WRITES the linked line); SC -> MUST FAIL and
 *            memory must hold the HANDLER's value (a spurious SC-success would
 *            clobber the handler's write == the lost-update corruption).
 */
#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

/* ================================================================
 * BEV=0 exception vectors
 * ================================================================ */
    .section .except_vec, "ax"
    .org    0x000
    break                       /* TLB refill  (unused) */
    .org    0x080
    break                       /* XTLB miss   (unused) */
    .org    0x100
    break                       /* cache error (unused) */
    .org    0x180
    .globl  _exc_handler
_exc_handler:
    mfc0    $k0, $14            /* EPC */
    addiu   $k0, $k0, 4         /* step past the SYSCALL */
    mtc0    $k0, $14
    /* if handler_modify != 0, store the marker into the linked line */
    la      $k1, handler_modify
    lw      $k1, 0($k1)
    beq     $k1, $0, 1f
    nop
    la      $k1, scratch
    li      $k0, 0x0000beef
    sw      $k0, 0($k1)         /* handler modifies the reserved line */
1:
    eret
    nop

/* ================================================================
 * Reset entry
 * ================================================================ */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00           /* Status: kernel, BEV=0, EXL=0, IE=0 */
    mtc0    $t0, $12
    nop
    nop
    nop
    la      $10, scratch

    /* ---- subtest 1: exception (no modify) must break the reservation ---- */
    la      $t0, handler_modify
    sw      $0, 0($t0)          /* modify OFF */
    li      $8, 0x0000aaaa
    sw      $8, 0($10)
    ll      $9, 0($10)          /* set reservation */
    bne     $9, $8, fail
    nop
    syscall                     /* exception -> handler -> ERET (must clear LLbit) */
    li      $13, 0x00005555
    sc      $13, 0($10)         /* MUST FAIL: $13 <- 0 */
    bne     $13, $0, fail       /* fail if SC succeeded (rt != 0) */
    nop
    lw      $14, 0($10)
    li      $15, 0x0000aaaa
    bne     $14, $15, fail      /* memory must be unchanged */
    nop

    /* ---- subtest 2: handler writes the line; SC must not clobber it ---- */
    la      $t0, handler_modify
    li      $8, 1
    sw      $8, 0($t0)          /* modify ON */
    li      $8, 0x0000cccc
    sw      $8, 0($10)
    ll      $9, 0($10)          /* set reservation */
    bne     $9, $8, fail
    nop
    syscall                     /* handler writes 0xbeef, ERETs */
    li      $13, 0x00007777
    sc      $13, 0($10)         /* MUST FAIL: $13 <- 0 */
    bne     $13, $0, fail       /* fail if SC succeeded */
    nop
    lw      $14, 0($10)
    li      $15, 0x0000beef
    bne     $14, $15, fail      /* memory must hold the HANDLER's value */
    nop

    /* pass */
    li      $25, 0x50
    mtc0    $25, $7             /* 'P' */
    break
fail:
    li      $25, 0x46
    mtc0    $25, $7             /* 'F' */
    break
    .size   _start, .-_start

    .section .data
    .align  3
scratch:
    .dword  0
handler_modify:
    .word   0
