/* LL/SC (32-bit) + LLD/SCD (64-bit) round-trip. Single-thread => SC/SCD always
 * succeed (return 1). Runs in kernel mode so the 64-bit ops are valid. P on pass. */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    la   $10, scratch
    /* ---- 32-bit LL/SC ---- */
    li   $8, 0x6789           ; sw $8, 0($10)
    ll   $9, 0($10)           ; bne $9, $8, fail ; nop      /* ll reads back */
    li   $13, 0x1abc
    sc   $13, 0($10)                                          /* store; $13<-1 */
    li   $3, 1                ; bne $13, $3, fail ; nop       /* sc succeeded? */
    lw   $14, 0($10)          ; li $15, 0x1abc ; bne $14, $15, fail ; nop
    /* ---- 64-bit LLD/SCD ---- */
    lui  $8, 0x1234 ; ori $8,$8,0x5678 ; dsll32 $8,$8,0
    lui  $9, 0x6abc ; ori $9,$9,0xdef0 ; or $8,$8,$9          /* 0x123456786abcdef0 */
    sd   $8, 8($10)
    lld  $16, 8($10)         ; bne $16, $8, fail ; nop        /* lld reads 64b */
    li   $17, 0x55
    scd  $17, 8($10)                                          /* store; $17<-1 */
    li   $3, 1               ; bne $17, $3, fail ; nop        /* scd succeeded? */
    ld   $18, 8($10)         ; li $19, 0x55 ; bne $18, $19, fail ; nop
    ori  $25, $0, 0x50       ; mtc0 $25, $7 ; break           /* P */
fail:
    ori  $25, $0, 0x46       ; mtc0 $25, $7 ; break           /* F */
    .size main,.-main
    .data
    .align 3
scratch: .dword 0
         .dword 0
