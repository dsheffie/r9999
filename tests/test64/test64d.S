/* test64d.S -- adjacent mtc0(enter 64b) ; daddiu.  Forces the mode-flipping
 * mtc0 into dec0 and the 64-bit op into dec1 of the SAME decode pair, which is
 * the exact same-cycle stale-mode hazard. Expect ABC if correct, AB if daddiu RIs. */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type  main, @function
main:
    li    $t9, 0x41
    mtc0  $t9, $7            /* 'A' */
    /* clear KX first (start in 32-bit mode) */
    mfc0  $t0, $12
    lui   $at, 0xffff
    ori   $at, $at, 0xff7f   /* ~0x80 */
    and   $t0, $t0, $at
    mtc0  $t0, $12
    .word 0x000000c0         /* ehb : KX now 0 */
    li    $t9, 0x42
    mtc0  $t9, $7            /* 'B' */
    ori   $t0, $t0, 0x80     /* prepare KX=1 */
    .align 3                 /* 8-byte align so the mtc0 lands in dec0 */
    mtc0  $t0, $12           /* <-- enter 64-bit mode (dec0) */
    daddiu $t1, $zero, 0x1234 /* <-- 64-bit op, same pair (dec1) */
    li    $t9, 0x43
    mtc0  $t9, $7            /* 'C' : reached iff daddiu did NOT trap */
    break
    .size main, .-main
