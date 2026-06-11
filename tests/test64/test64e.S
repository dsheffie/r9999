/* test64e.S -- vmlinux kernel_entry shape: mtc0(enter 64b); ehb; lui; daddiu.
 * Non-adjacent: an ehb and a normal lui sit between the mode-changing mtc0 and
 * the 64-bit op, exactly like kernel_entry 0x88300d6c..d78. Tests whether the
 * restart-on-commit replays under this shape. Expect ABC if correct, AB if daddiu RIs. */
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
    /* --- kernel_entry shape: mtc0 ; ehb ; lui ; daddiu --- */
    mtc0  $t0, $12           /* d6c: enter 64-bit mode (the mode-changer) */
    .word 0x000000c0         /* d70: ehb */
    lui   $t1, 0x8830        /* d74: normal op */
    daddiu $t1, $t1, 0x1234  /* d78: the 64-bit op */
    li    $t9, 0x43
    mtc0  $t9, $7            /* 'C' : reached iff daddiu did NOT trap */
    break
    .size main, .-main
