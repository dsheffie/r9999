/* test_ll_evict.S -- LL/SC where the linked line is EVICTED before the SC.  An SC
 * after line eviction MAY fail (architecturally allowed), so the correct pattern
 * is a retry loop; it must make PROGRESS (eventually succeed) and write the right
 * value.  Livelock (never succeeds) or a wrong stored value -> F. */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    la   $10, scratch
    li   $24, 64                  /* bound the retries so a livelock -> F, not hang */
outer:
    li   $8, 0x00012345
    sw   $8, 0($10)
    ll   $9, 0($10)
    la   $11, sweep
    li   $12, 1024
1:  lw   $0, 0($11)
    addiu $11, $11, 16
    addiu $12, $12, -1
    bne  $12, $0, 1b
    nop
    li   $13, 0x00006789
    sc   $13, 0($10)
    bne  $13, $0, ok             /* SC succeeded */
    nop
    addiu $24, $24, -1
    bne  $24, $0, outer          /* retry (bounded) */
    nop
    b    fail                    /* livelock: never succeeded in 64 tries */
    nop
ok:
    lw   $14, 0($10)
    li   $15, 0x00006789
    bne  $14, $15, fail
    nop
    li   $25, 0x50 ; mtc0 $25, $7 ; break     /* P */
fail:
    li   $25, 0x46 ; mtc0 $25, $7 ; break     /* F */
    .size main,.-main
    .data
    .align 4
scratch: .dword 0
         .dword 0
    .align 4
sweep:   .space 16384
