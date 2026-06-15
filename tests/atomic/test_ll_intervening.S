/* LL/SC reservation, BERI/CHERI model (the default; machine.vh without
 * LLSC_BREAK_ON_LOAD): a STORE to the linked cache line breaks the link (SC
 * fails, memory unchanged); an intervening LOAD does NOT break it (SC succeeds).
 * Prints P on pass, F on fail; halts on break.  Runs clean under the co-sim.
 *
 * NB: under LLSC_BREAK_ON_LOAD (R10000-strict) the intervening-load case would
 * instead fail the SC -- this test encodes the default model. */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    la   $10, scratch

    /* ---- sanity: NO intervening access -> SC succeeds ---- */
    li   $8, 0x1234          ; sw $8, 0($10)
    ll   $9, 0($10)          ; bne $9, $8, fail ; nop
    li   $13, 0x5678
    sc   $13, 0($10)                                  /* should succeed: $13<-1 */
    li   $3, 1               ; bne $13, $3, fail ; nop
    lw   $14, 0($10)         ; li $15, 0x5678 ; bne $14, $15, fail ; nop

    /* ---- intervening LOAD -> SC still SUCCEEDS (load does not break link) ---- */
    li   $8, 0x1111          ; sw $8, 0($10)
    ll   $9, 0($10)          ; bne $9, $8, fail ; nop
    lw   $20, 8($10)                                   /* intervening load (same line) */
    li   $13, 0x2222
    sc   $13, 0($10)                                   /* should succeed: $13<-1 */
    li   $3, 1               ; bne $13, $3, fail ; nop
    lw   $14, 0($10)         ; li $15, 0x2222 ; bne $14, $15, fail ; nop

    /* ---- intervening STORE to the link line -> SC FAILS, memory unchanged ---- */
    li   $8, 0x3333          ; sw $8, 0($10)
    ll   $9, 0($10)          ; bne $9, $8, fail ; nop
    li   $21, 0x9            ; sw $21, 8($10)           /* store to the linked 16B line */
    li   $13, 0x4444
    sc   $13, 0($10)                                   /* must FAIL: $13<-0 */
    bne  $13, $0, fail       ; nop                     /* expect rt==0 */
    lw   $14, 0($10)         ; li $15, 0x3333 ; bne $14, $15, fail ; nop  /* unchanged */

    /* ---- intervening BYTE store to the link line -> SC FAILS ---- */
    li   $8, 0x5555          ; sw $8, 0($10)
    ll   $9, 0($10)          ; bne $9, $8, fail ; nop
    li   $22, 0x7            ; sb $22, 4($10)           /* byte store, same line */
    li   $13, 0x6666
    sc   $13, 0($10)                                   /* must FAIL: $13<-0 */
    bne  $13, $0, fail       ; nop
    lw   $14, 0($10)         ; li $15, 0x5555 ; bne $14, $15, fail ; nop

    ori  $25, $0, 0x50      ; mtc0 $25, $7 ; break     /* P */
fail:
    ori  $25, $0, 0x46      ; mtc0 $25, $7 ; break     /* F */
    .size main,.-main
    .data
    .align 3
scratch: .dword 0
         .dword 0
