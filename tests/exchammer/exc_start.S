/* exc_start.S -- _start + BEV=0 vectors for the exception-hammer C tests (no crt0).
 * 0x000 TLB refill: maps the faulting kuseg page pair of the window VA 0x00400000.. onto
 *       PA 0x00200000.. (C=3 D V G) with tlbwi at a software round-robin index ($28), so
 *       the RTL and the ISS evict identically (co-sim lockstep).  The op re-executes.
 * 0x180 general: AdEL/AdES are skipped (EPC += 4); anything else prints X and halts.
 * main() returns 0 for PASS. */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .macro HALT
    li $26, 0xBFD00000
    li $27, 1
    sw $27, 0($26)
1:  b 1b
    nop
    .endm

    .section .except_vec, "ax"
    .org 0x000
    mfc0 $26, $8
    srl  $26, $26, 13
    sll  $26, $26, 13
    lui  $27, 0x0040
    subu $26, $26, $27
    lui  $27, 0x0020
    addu $26, $26, $27
    srl  $26, $26, 12
    sll  $26, $26, 6
    ori  $26, $26, 0x1f
    mtc0 $26, $2
    addiu $26, $26, 0x40
    mtc0 $26, $3
    mtc0 $0, $5
    mtc0 $28, $0
    addiu $28, $28, 1
    sltiu $27, $28, 48
    bne  $27, $0, 1f
    nop
    move $28, $0
1:  tlbwi
    eret
    nop
    .org 0x180
    mfc0 $26, $13
    andi $26, $26, 0x7c
    addiu $26, $26, -(4<<2)
    beq  $26, $0, 2f
    addiu $26, $26, -(1<<2)
    beq  $26, $0, 2f
    nop
    SIMCON_PUTLIT('X')
    SIMCON_PUTLIT('\n')
    HALT
2:  mfc0 $26, $14
    addiu $26, $26, 4
    mtc0 $26, $14
    eret
    nop

    .section .text.startup, "ax"
    .globl _start
_start:
    mtc0 $0, $12
    mtc0 $0, $6
    mtc0 $0, $10
    move $28, $0
    la   $sp, 0x80070000
    la   $8, __bss_start
    la   $9, __bss_end
3:  sw   $0, 0($8)
    addiu $8, $8, 4
    sltu $10, $8, $9
    bne  $10, $0, 3b
    nop
    jal  main
    nop
    bne  $2, $0, 4f
    nop
    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT
4:  SIMCON_PUTLIT('F')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('I')
    SIMCON_PUTLIT('L')
    SIMCON_PUTLIT('\n')
    HALT
