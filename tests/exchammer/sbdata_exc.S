/* sbdata_exc.S -- the dependence shape of 099.go upldrflags (IRIX MIPSpro -Ofast,
 * 0x10035AB4..0x10035B2C), where silicon wedged in EXCEPTION_DRAIN after a TLBL at
 * EPC 0x10035AE0:
 *   lw idx -> lw (TLB refill) -> lw -> lw -> sd 40(sp) whose DATA hangs off the fault
 *   -> lw -> data-dependent bnez -> beq with `ld 40(sp)` in its DELAY SLOT
 * so the aliasing ld must wait (BLK_SB_DATA) on an older sd whose data never arrives
 * when the refill flushes.  The bnez side path stores to chain-dependent addresses
 * (like go's 0x10035A50).
 * Refill (0x000) maps VA 0x00400000.. -> PA 0x00200000.. with a software round-robin
 * tlbwi index ($28) so RTL and ISS evict identically; run with -c 1 for co-sim. */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
#ifndef ITERS
#define ITERS 100000
#endif
#ifndef PAGES
#define PAGES 256             /* mapped window pages (power of 2, > 96 misses the TLB) */
#endif
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
    SIMCON_PUTLIT('X')
    SIMCON_PUTLIT('\n')
    HALT

    .section .text.startup, "ax"
    .globl _start
_start:
    mtc0 $0, $12
    mtc0 $0, $6
    mtc0 $0, $10
    move $28, $0
    li   $29, 0x80070000          /* sp */
    li   $16, 0x80100000          /* idx[4096] */
    li   $18, 0x80110000          /* T1[1024] */
    li   $19, 0x00400000          /* mapped window */
    li   $8, 12345                /* LCG state */
    li   $9, 1103515245
    /* idx[i] = page index; T1[i] = 0..1023 */
    li   $10, 0
1:  multu $8, $9
    mflo $8
    addiu $8, $8, 12345
    srl  $11, $8, 16
    andi $11, $11, PAGES-1
    sll  $12, $10, 2
    addu $12, $12, $16
    sw   $11, 0($12)
    addiu $10, $10, 1
    sltiu $12, $10, 4096
    bne  $12, $0, 1b
    nop
    li   $10, 0
2:  multu $8, $9
    mflo $8
    addiu $8, $8, 12345
    srl  $11, $8, 16
    andi $11, $11, 1023
    sll  $12, $10, 2
    addu $12, $12, $18
    sw   $11, 0($12)
    addiu $10, $10, 1
    sltiu $12, $10, 1024
    bne  $12, $0, 2b
    nop
    /* window page p, word 0x40..: 0..1023, written through the kseg0 alias of PA 0x00200000 */
    li   $13, 0x80200100
    li   $10, 0
3:  multu $8, $9
    mflo $8
    addiu $8, $8, 12345
    srl  $11, $8, 16
    andi $11, $11, 1023
    sw   $11, 0($13)
    addiu $13, $13, 0x1000
    addiu $10, $10, 1
    sltiu $12, $10, PAGES
    bne  $12, $0, 3b
    nop

    li   $17, 0                   /* idx offset */
    li   $20, ITERS
    li   $5, 512                  /* a1: ~50% split of the bnez */
    li   $21, 0                   /* acc */
    sd   $0, 40($29)
    sd   $0, 56($29)
top:
    addu $15, $16, $17
    lw   $15, 0($15)              /* idx (go 0x10035AC4) */
    addiu $17, $17, 4
    andi $17, $17, 0x3ffc
    sll  $15, $15, 12
    addu $7, $19, $15
    lw   $7, 0x100($7)            /* TLB refill (go 0x10035AE0) */
    sll  $7, $7, 2
    addu $7, $7, $18
    lw   $7, 0($7)                /* dependent (go 0x10035AF0) */
    sll  $25, $7, 2
    addu $25, $25, $18
    lw   $14, 0($25)              /* dependent (go 0x10035B00) */
    sll  $24, $14, 2
    addu $24, $24, $18
    sd   $24, 40($29)             /* data hangs off the fault (go 0x10035B0C) */
    lw   $24, 0($24)              /* dependent (go 0x10035B14) */
    slt  $1, $5, $24
    sll  $15, $10, 2
    bnez $1, side                 /* data-dependent (go 0x10035B20) */
    addu $15, $15, $18
    beq  $24, $5, tail            /* (go 0x10035B28) */
    ld   $15, 40($29)             /* aliasing ld in the DELAY SLOT (go 0x10035B2C) */
    daddu $21, $21, $15
    b    tail
    nop
side:
    sw   $10, 0x1000($25)         /* chain-dependent store address (go 0x10035A50) */
    sw   $5, 0x10($15)            /* known address off the bnez delay slot (go 0x10035A5C) */
    lw   $10, 0x3000($15)         /* known address, L1D-conflicting -> misses (go 0x10035A60) */
    sw   $14, 0x3000($15)         /* same address (go 0x10035A64) */
    andi $10, $10, 1023
    lw   $13, 0x2000($18)         /* (go 0x10035A68) */
    sd   $25, 56($29)
    ld   $3, 56($29)              /* (go 0x10035A94) */
    daddu $21, $21, $3
tail:
    addiu $20, $20, -1
    bne  $20, $0, top
    addu $21, $21, $10

    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT
