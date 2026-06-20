/*
 * test_va_range.S -- VA out-of-range Address Error test (Sail TLBTranslate MAX_VA).
 *
 * In 64-bit kernel addressing (Status.KX=1), a MAPPED, non-compat VA whose
 * address within the region exceeds SEGBITS (VA[61:SEGBITS] != 0) must raise an
 * Address Error (AdEL/AdES, ExcCode 4/5) -- NOT silently truncate to the bus.
 *
 * Sets KX=1, BEV=0, loads from 0x0000_0001_0000_0000 (region R=00 xkuseg, bit 48
 * set => VA[61:40]!=0 for SEGBITS=40), and verifies the handler saw ExcCode=4.
 * Self-contained (own reset entry + handler at the BEV=0 0x80000180 vector).
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

/* ---- general exception handler at 0x80000180 (BEV=0) ---- */
    .section .except_vec, "ax"
    .org    0x180
    .globl  _exc_handler
_exc_handler:
    la      $k0, exc_flag
    li      $k1, 1
    sw      $k1, 0($k0)         /* exc_flag = 1 */
    mfc0    $k0, $13            /* Cause */
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f      /* ExcCode */
    la      $k1, saved_cause
    sw      $k0, 0($k1)         /* saved_cause = ExcCode */
    mfc0    $k0, $14            /* EPC */
    addiu   $k0, $k0, 4         /* skip the faulting load */
    mtc0    $k0, $14
    eret
    nop

/* ---- reset entry ---- */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x80           /* Status: KX=1 (64-bit kernel), BEV=0, EXL=0, ERL=0 */
    mtc0    $t0, $12
    nop
    nop
    nop

    la      $t0, exc_flag
    sw      $zero, 0($t0)
    la      $t0, saved_cause
    sw      $zero, 0($t0)

    la      $a0, msg_start
    jal     sim_puts
    nop

    /* out-of-range mapped VA: 0x0000_0001_0000_0000 (R=00 xkuseg, bit 48 > SEGBITS) */
    lui     $t1, 0x0001
    dsll32  $t1, $t1, 0
    .globl  test_oor_insn
test_oor_insn:
    lw      $t2, 0($t1)         /* mapped + out-of-range -> AdEL (ExcCode 4) */

    /* verify the handler was reached with ExcCode == 4 */
    la      $t0, exc_flag
    lw      $t1, 0($t0)
    beq     $t1, $zero, fail_not_taken
    nop
    la      $t0, saved_cause
    lw      $t1, 0($t0)
    li      $t2, 4
    bne     $t1, $t2, fail_wrong_cause
    nop

    la      $a0, msg_pass
    jal     sim_puts
    nop
    HALT

fail_not_taken:
    la      $a0, msg_fail_taken
    jal     sim_puts
    nop
    HALT

fail_wrong_cause:
    la      $a0, msg_fail_cause
    jal     sim_puts
    nop
    HALT

/* ---- sim_puts: print NUL-terminated string at $a0 ---- */
    .globl  sim_puts
sim_puts:
1:  lb      $t9, 0($a0)
    beq     $t9, $zero, 2f
    nop
    mtc0    $t9, $7
    addiu   $a0, $a0, 1
    b       1b
    nop
2:  jr      $ra
    nop

    .section .rodata
msg_start:        .asciz "VA-range AdEL test\n"
msg_pass:         .asciz "PASS\n"
msg_fail_taken:   .asciz "FAIL: no Address Error raised\n"
msg_fail_cause:   .asciz "FAIL: wrong ExcCode (expected 4=AdEL)\n"

    .data
    .globl exc_flag
exc_flag:    .word 0
    .globl saved_cause
saved_cause: .word 0
