/* test64c.S -- kernel-exact: Status setup, then a taken jr, then daddiu at the
 * jump target (mimics kernel_entry d74-d88: lui/daddiu/jr/nop/lui/daddiu). */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    li    $t9, 0x41
    mtc0  $t9, $7            /* 'A' */
    mfc0  $t0, $12
    lui   $at, 0x1000
    ori   $at, $at, 0x9f
    or    $t0, $t0, $at
    xori  $t0, $t0, 0x1f
    mtc0  $t0, $12
    .word 0x000000c0         /* ehb */
    li    $t9, 0x42
    mtc0  $t9, $7            /* 'B' */
    lui   $t0, %hi(L1)
    daddiu $t0, $t0, %lo(L1) /* daddiu #1: build jr target (like kernel d78) */
    jr    $t0
    nop
L1:
    lui   $t1, 0x8845
    daddiu $t1, $t1, 0       /* daddiu #2: AFTER the jump (like kernel d88) */
    li    $t9, 0x43
    mtc0  $t9, $7            /* 'C' : reached iff #2 did NOT trap */
    break
    .size main, .-main
