/* Tight load immediately after a FAILED scd, same address: must read memory
 * (unchanged), NOT forward the failed scd's store data. P on pass. */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    la   $10, scratch
    dli  $8, 0xAAAAAAAAAAAAAAAA ; sd $8, 0($10)
    lld  $9, 0($10)                          /* link set */
    sb   $9, 1($10)                          /* store to line -> breaks link */
    dli  $13, 0x2
    scd  $13, 0($10)                         /* must FAIL (no store) */
    ld   $14, 0($10)                         /* TIGHT same-addr load: must read memory, not 2 */
    bne  $13, $0, fail   ; nop               /* scd should have failed (rt==0) */
    dli  $15, 0xAAAAAAAAAAAAAAAA
    bne  $14, $15, fail  ; nop               /* load must NOT be the failed scd's data */
    ori  $25, $0, 0x50   ; mtc0 $25, $7 ; break   /* P */
fail:
    ori  $25, $0, 0x46   ; mtc0 $25, $7 ; break   /* F */
    .size main,.-main
    .data
    .align 3
scratch: .dword 0
