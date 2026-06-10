/* mtc0 (enter 64-bit mode) in the delay slot of a taken forward bne (predicted
 * not-taken first time -> mispredict + recover). Correct -> ABC; bug -> AB. */
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
    lui   $at, 0xffff
    ori   $at, $at, 0xff7f
    and   $t0, $t0, $at      /* clear KX */
    mtc0  $t0, $12
    .word 0x000000c0         /* ehb */
    li    $t9, 0x42
    mtc0  $t9, $7            /* 'B' */
    ori   $t0, $t0, 0x80     /* t0 = SR | KX */
    li    $t4, 1
    bne   $t4, $zero, bne_target  /* taken (forward -> likely mispredicted) */
    mtc0  $t0, $12                /* DELAY SLOT: enter 64-bit mode */
    li    $t9, 0x59
    mtc0  $t9, $7                 /* 'Y' : not-taken fall-through, must NOT print */
bne_target:
    daddiu $t1, $zero, 0x1234
    li    $t9, 0x43
    mtc0  $t9, $7                 /* 'C' */
    break
    .size main, .-main
