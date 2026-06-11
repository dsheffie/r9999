/* test64g.S -- like test64e (kernel shape mtc0;ehb;lui;daddiu) but with a
 * long-latency div in flight right before the mode-changing mtc0. The div keeps
 * the ROB head incomplete for ~33 cycles, so the ROB is non-empty when the
 * serializing mtc0 reaches the DQ head -- blocking the t_rob_empty serialize-gate
 * (core.sv:1143). Expect ABC if restart still replays, AB if the daddiu RIs. */
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
    ori   $at, $at, 0xff7f
    and   $t0, $t0, $at
    mtc0  $t0, $12
    .word 0x000000c0         /* ehb : KX now 0 */
    li    $t9, 0x42
    mtc0  $t9, $7            /* 'B' */
    ori   $t0, $t0, 0x80     /* prepare KX=1 (do NOT write yet) */
    /* ---- long-latency op in flight: 32-bit divide (~33 cyc) ---- */
    li    $t3, 0x12345
    li    $t4, 7
    div   $zero, $t3, $t4    /* hi/lo busy for many cycles */
    /* --- kernel_entry shape: mtc0 ; ehb ; lui ; daddiu --- */
    mtc0  $t0, $12           /* enter 64-bit mode (the mode-changer) */
    .word 0x000000c0         /* ehb */
    lui   $t1, 0x8830        /* normal op */
    daddiu $t1, $t1, 0x1234  /* the 64-bit op */
    li    $t9, 0x43
    mtc0  $t9, $7            /* 'C' : reached iff daddiu did NOT trap */
    break
    .size main, .-main
