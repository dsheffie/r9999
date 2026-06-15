/* TIGHT store-to-line: store immediately follows the lld (mimics lldscd_span).
 * BERI model: the store breaks the link -> scd must FAIL.  P on pass. */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    la   $10, scratch
    li   $13, 0x4444
    li   $8, 0x1234         ; sd $8, 0($10)
    lld  $9, 0($10)                              /* link set */
    sb   $9, 1($10)                              /* TIGHT store to line (0 insns gap) */
    scd  $13, 0($10)                             /* must FAIL: $13<-0 */
    bne  $13, $0, fail      ; nop
    ori  $25, $0, 0x50      ; mtc0 $25, $7 ; break   /* P */
fail:
    ori  $25, $0, 0x46      ; mtc0 $25, $7 ; break   /* F */
    .size main,.-main
    .data
    .align 3
scratch: .dword 0
