/*
 * test_except.S  --  exception delivery and ERET test (self-contained).
 *
 * Installs a general-exception handler at 0x80000180 (BEV=0), causes a
 * SYSCALL, and verifies:
 *   - the handler was reached (exc_flag == 1)
 *   - EPC pointed at the SYSCALL instruction
 *   - execution continued past the SYSCALL after ERET
 *
 * Self-contained: defines its own reset entry and its own vector at the exact
 * BEV=0 offset (no crt0).  Earlier this test linked against crt0.o, whose
 * .except_vec "break" stubs occupied 0x000..0x180, so the real handler was
 * appended at 0x304 and never ran.  Halts via the magic-halt register.
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
 * General exception handler at 0x80000180 (BEV=0)
 * ================================================================ */
    .section .except_vec, "ax"
    .org    0x180
    .globl  _exc_handler
_exc_handler:
    la      $k0, exc_flag
    li      $k1, 1
    sw      $k1, 0($k0)         /* exc_flag = 1 */
    mfc0    $k0, $14            /* read EPC */
    la      $k1, saved_epc
    sw      $k0, 0($k1)         /* saved_epc = EPC */
    addiu   $k0, $k0, 4         /* advance past SYSCALL */
    mtc0    $k0, $14
    eret
    nop

/* ================================================================
 * Reset entry
 * ================================================================ */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    /* Status = BEV=0, kernel mode, EXL=0, ERL=0, IE=0 */
    li      $t0, 0x00
    mtc0    $t0, $12
    nop
    nop
    nop

    /* clear shared variables */
    la      $t0, exc_flag
    sw      $zero, 0($t0)
    la      $t0, saved_epc
    sw      $zero, 0($t0)

    la      $a0, msg_start
    jal     sim_puts
    nop

    /* ---- cause a SYSCALL exception ---- */
    .globl  test_syscall_insn
test_syscall_insn:
    syscall                     /* general exception -> 0x80000180 */

    /* ---- after ERET we land here ---- */
    la      $a0, msg_after_eret
    jal     sim_puts
    nop

    /* verify exc_flag was set */
    la      $t0, exc_flag
    lw      $t1, 0($t0)
    beq     $t1, $zero, fail_not_taken
    nop

    /* verify saved_epc == &test_syscall_insn */
    la      $t0, saved_epc
    lw      $t1, 0($t0)
    la      $t2, test_syscall_insn
    bne     $t1, $t2, fail_wrong_epc
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

fail_wrong_epc:
    la      $a0, msg_fail_epc
    jal     sim_puts
    nop
    HALT

/* ---- sim_puts: print NUL-terminated string at $a0 (leaf, uses $ra) ---- */
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
msg_start:       .asciz "Exception / ERET test\n"
msg_after_eret:  .asciz "  Returned from handler via ERET\n"
msg_pass:        .asciz "PASS\n"
msg_fail_taken:  .asciz "FAIL: handler was never reached\n"
msg_fail_epc:    .asciz "FAIL: EPC did not point to the SYSCALL\n"

    .data
    .globl exc_flag
exc_flag:   .word 0
    .globl saved_epc
saved_epc:  .word 0
