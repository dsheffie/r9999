/* mtc0 (enter 64-bit mode) in the delay slot of a direct jump `j`.
 * The daddiu is first at the target, so it decodes right after the jump while
 * the delay-slot mtc0 is still in flight. Correct -> ABC; bug (stale mode RI) -> AB. */
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
    and   $t0, $t0, $at      /* clear KX -> 32-bit mode */
    mtc0  $t0, $12
    .word 0x000000c0         /* ehb */
    li    $t9, 0x42
    mtc0  $t9, $7            /* 'B' */
    ori   $t0, $t0, 0x80     /* t0 = SR | KX (value for the delay-slot mtc0) */
    j     dj_target
    mtc0  $t0, $12           /* DELAY SLOT: enter 64-bit mode */
    li    $t9, 0x58
    mtc0  $t9, $7            /* 'X' : fall-through, must NOT print */
dj_target:
    daddiu $t1, $zero, 0x1234 /* 64-bit op, first at target */
    li    $t9, 0x43
    mtc0  $t9, $7            /* 'C' : prints iff daddiu did NOT trap */
    break
    .size main, .-main
