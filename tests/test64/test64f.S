/* test64f.S -- like test64e (kernel shape mtc0;ehb;lui;daddiu) but with a LONG
 * independent-ALU preamble right before the mode-changing mtc0, to keep the ROB
 * non-empty when the serializing mtc0 reaches the DQ head (the t_rob_empty
 * serialize-gate at core.sv:1143). Single-step throttles retire, so fetch-ahead
 * should keep the 32-entry ROB full. Expect ABC if restart still replays, AB if not. */
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
    /* ---- long ALU preamble: 48 ops to flood the ROB ---- */
    li    $t2, 0
    .rept 48
    addiu $t2, $t2, 1
    .endr
    /* --- kernel_entry shape: mtc0 ; ehb ; lui ; daddiu --- */
    mtc0  $t0, $12           /* enter 64-bit mode (the mode-changer) */
    .word 0x000000c0         /* ehb */
    lui   $t1, 0x8830        /* normal op */
    daddiu $t1, $t1, 0x1234  /* the 64-bit op */
    li    $t9, 0x43
    mtc0  $t9, $7            /* 'C' : reached iff daddiu did NOT trap */
    break
    .size main, .-main
