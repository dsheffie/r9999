/* TDD test 1: int -> FP(f0) -> int round-trip via mtc1/mfc1.
 * PASS ('P') iff the value survives the trip through an FP register. */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    lui   $8, 0x1234
    ori   $8, $8, 0x5678      /* $8 = 0x12345678 */
    mtc1  $8, $f0             /* f0 <- $8  (int -> FP) */
    nop
    nop
    mfc1  $9, $f0             /* $9 <- f0  (FP -> int) */
    nop
    bne   $8, $9, 1f
    nop
    ori   $25, $0, 0x50       /* 'P' */
    mtc0  $25, $7
    break
1:
    ori   $25, $0, 0x46       /* 'F' */
    mtc0  $25, $7
    break
    .size main,.-main
