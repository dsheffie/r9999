/* Reproduce lldscd_span's chain standalone: a SUCCEEDING lld/ld/scd (load
 * doesn't break) immediately followed by an lld/sb/scd that MUST fail (store to
 * the line breaks the link).  Isolates whether the chaining is what breaks. */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    la   $10, scratch
    li   $8, 0x1234         ; sd $8, 0($10)      /* init dword */
    /* subtest 1: lld; ld (load, no break); scd -> SUCCEEDS */
    lld  $6, 0($10)
    ld   $12, 0($10)
    scd  $6, 0($10)                              /* should succeed */
    li   $3, 1              ; bne $6, $3, fail ; nop
    /* subtest 2: lld; sb (store to line, break); scd -> FAILS */
    li   $12, 2
    lld  $14, 0($10)
    sb   $14, 1($10)
    scd  $12, 0($10)                             /* must FAIL: $12<-0 */
    bne  $12, $0, fail      ; nop                /* expect rt==0 */
    ori  $25, $0, 0x50      ; mtc0 $25, $7 ; break   /* P */
fail:
    ori  $25, $0, 0x46      ; mtc0 $25, $7 ; break   /* F */
    .size main,.-main
    .data
    .align 3
scratch: .dword 0
