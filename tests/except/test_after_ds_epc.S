/*
 * test_after_ds_epc.S -- an exception on the instruction AFTER a delay slot must
 * report EPC = that instruction and Cause.BD = 0.
 *
 * core.sv stamps both allocation slots with the same r_in_delay_slot.  When a
 * branch allocates alone and its delay slot then allocates together with the next
 * instruction, that next instruction is flagged in_delay_slot too -- so if it
 * faults, EPC would be its pc-4 and BD set.  The branch here is not taken and
 * trained that way, so the delay slot and the unaligned lw after it sit next to
 * each other in the decode queue.
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
    .globl  _exc_handler
_exc_handler:
    mfc0    $k0, $14
    la      $k1, rec_epc
    sw      $k0, 0($k1)
    mfc0    $k0, $13
    la      $k1, rec_cause
    sw      $k0, 0($k1)
    la      $k0, after_e            /* resume past the faulting lw either way */
    mtc0    $k0, $14
    nop
    nop
    eret
    nop

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    mtc0    $zero, $12              /* BEV=0, kernel, EXL=0 */
    nop
    nop
    nop
    li      $sp, 0x80070000
    la      $a0, msg_start
    jal     sim_puts
    nop

    la      $a0, buf                /* aligned: 1($a0) is unaligned for lw */
    li      $t1, 1
    li      $s2, 64
    li      $s0, 0
loop:
    beq     $t1, $zero, never       /* never taken */
    addiu   $s0, $s0, 1             /* delay slot */
    .globl  fault_e
fault_e:
    lw      $t2, 1($a0)             /* AdEL, right after the delay slot */
    b       bad_noexc               /* not reached: the handler resumes at after_e */
    nop
after_e:
    la      $t3, rec_epc
    lw      $t4, 0($t3)
    la      $t5, fault_e
    bne     $t4, $t5, bad_epc
    nop
    la      $t3, rec_cause
    lw      $t4, 0($t3)
    srl     $t6, $t4, 31            /* BD */
    bne     $t6, $zero, bad_bd
    nop
    srl     $t6, $t4, 2
    andi    $t6, $t6, 0x1f
    li      $t7, 4                  /* AdEL */
    bne     $t6, $t7, bad_code
    nop
    addiu   $s2, $s2, -1
    bne     $s2, $zero, loop
    nop
    li      $t7, 64
    bne     $s0, $t7, bad_ds        /* the (non-likely) delay slot ran every time */
    nop
    la      $a0, msg_pass
    jal     sim_puts
    nop
    HALT
never:
    la      $a0, msg_never
    b       fail
    nop
bad_noexc:
    la      $a0, msg_noexc
    b       fail
    nop
bad_epc:
    la      $a0, msg_epc
    b       fail
    nop
bad_bd:
    la      $a0, msg_bd
    b       fail
    nop
bad_code:
    la      $a0, msg_code
    b       fail
    nop
bad_ds:
    la      $a0, msg_ds
fail:
    jal     sim_puts
    nop
    HALT

    .globl  sim_puts
    .type   sim_puts, @function
sim_puts:
    lbu     $t9, 0($a0)
    beq     $t9, $zero, 2f
    nop
1:  SIMCON_PUTCHAR($t9)
    addiu   $a0, $a0, 1
    lbu     $t9, 0($a0)
    bne     $t9, $zero, 1b
    nop
2:  jr      $ra
    nop

    .section .rodata
msg_start: .asciiz "exception after a delay slot: EPC/BD test\n"
msg_pass:  .asciiz "PASS: EPC = the faulting insn, BD = 0, 64 times\n"
msg_never: .asciiz "FAIL: a never-taken branch was taken\n"
msg_noexc: .asciiz "FAIL: the unaligned lw did not trap\n"
msg_epc:   .asciiz "FAIL: EPC != the faulting lw (flagged as a delay slot?)\n"
msg_bd:    .asciiz "FAIL: Cause.BD set for an insn that is not in a delay slot\n"
msg_code:  .asciiz "FAIL: ExcCode != AdEL\n"
msg_ds:    .asciiz "FAIL: delay slot did not execute 64 times\n"
    .data
    .align 3
buf:       .word 0x11223344, 0x55667788
rec_epc:   .word 0
rec_cause: .word 0
