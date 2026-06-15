/* LL/SC reservation: an intervening load or store between LL and SC must BREAK
 * the link, so the SC fails (rt<-0) and memory is NOT modified (R10000 p.27,
 * R4400 Ch.11 conservative model).  Prints P on pass, F on fail; halts on break.
 *
 * RED until the RTL clears the link on intervening loads/stores: the interpreter
 * (correct) fails the SC, the lenient RTL succeeds it -> co-sim (-c 1) diverges
 * and the RTL-only run (-c 0) prints F.  GREEN once the RTL matches. */
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

    /* ---- intervening LOAD -> SC must FAIL, memory unchanged ---- */
    li   $8, 0x1111          ; sw $8, 0($10)
    ll   $9, 0($10)          ; bne $9, $8, fail ; nop  /* link set */
    lw   $20, 8($10)                                   /* INTERVENING LOAD -> break link */
    li   $13, 0x2222
    sc   $13, 0($10)                                   /* must FAIL: $13<-0 */
    bne  $13, $0, fail       ; nop                     /* expect rt==0 */
    lw   $14, 0($10)         ; li $15, 0x1111 ; bne $14, $15, fail ; nop  /* mem unchanged */

    /* ---- intervening STORE -> SC must FAIL, memory unchanged ---- */
    li   $8, 0x3333          ; sw $8, 0($10)
    ll   $9, 0($10)          ; bne $9, $8, fail ; nop  /* link set */
    li   $21, 0x9            ; sw $21, 8($10)           /* INTERVENING STORE -> break link */
    li   $13, 0x4444
    sc   $13, 0($10)                                   /* must FAIL: $13<-0 */
    bne  $13, $0, fail       ; nop                     /* expect rt==0 */
    lw   $14, 0($10)         ; li $15, 0x3333 ; bne $14, $15, fail ; nop  /* mem unchanged */

    ori  $25, $0, 0x50      ; mtc0 $25, $7 ; break     /* P */
fail:
    ori  $25, $0, 0x46      ; mtc0 $25, $7 ; break     /* F */
    .size main,.-main
    .data
    .align 3
scratch: .dword 0
         .dword 0
