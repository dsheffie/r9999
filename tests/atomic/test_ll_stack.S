/*
 * test_ll_stack.S -- lock-free LIFO push via LL/SC, the canonical malloc-style
 * pattern the existing tests miss: between LL(head) and SC(head) there is a
 * STORE to node->next which is on a DIFFERENT cache line.  BERI model: a store
 * to a NON-linked line must NOT break the reservation, so every push SC must
 * succeed and the final list must have all 8 nodes.  If r9999 breaks the link
 * on any store (not just the linked line) the push retries forever -> timeout.
 */
#include "sim.h"
    .set    mips3
    .set    noreorder
    .set    noat
    .text
    .globl  main
    .type   main,@function
main:
    la      $16, head
    sw      $0, 0($16)            /* head = 0 (empty) */
    la      $17, nodes
    li      $19, 0                /* i = 0 */
push_loop:
    sll     $20, $19, 5           /* i*32 (each node on its own line) */
    addu    $20, $17, $20         /* $20 = &node[i] */
retry:
    ll      $8, 0($16)            /* $8 = old head */
    sw      $8, 0($20)            /* node->next = old head (DIFFERENT line != head) */
    move    $9, $20
    sc      $9, 0($16)            /* head = node */
    beq     $9, $0, retry         /* retry if SC failed */
    nop
    addiu   $19, $19, 1
    li      $21, 8
    bne     $19, $21, push_loop
    nop
    /* count the list */
    lw      $8, 0($16)
    li      $22, 0
count_loop:
    beq     $8, $0, count_done
    nop
    addiu   $22, $22, 1
    lw      $8, 0($8)
    b       count_loop
    nop
count_done:
    li      $23, 8
    bne     $22, $23, fail        /* must have all 8 nodes */
    nop
    li      $25, 0x50
    mtc0    $25, $7               /* P */
    break
fail:
    li      $25, 0x46
    mtc0    $25, $7               /* F */
    break
    .size   main,.-main
    .data
    .align  5
head:    .space 32
nodes:   .space 256
