/* TDD test 4: mfc1 must sign-extend bits[31:0] into the 64-bit GPR (mips3/4).
 * Uses a value with bit31 set; the co-sim (-c 1) compares the full 64-bit GPR,
 * so a zero- vs sign-extend disagreement between RTL and checker diverges.
 * PASS ('P') iff the low 32 bits survive the mtc1->mfc1 round-trip. */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    lui   $8, 0x8001
    ori   $8, $8, 0xfedc      /* $8 = 0x8001fedc (bit31 set) */
    mtc1  $8, $f6
    nop
    nop
    mfc1  $9, $f6             /* $9 = sign_extend32(f7[31:0]) */
    nop
    bne   $8, $9, 1f          /* 32-bit compare (both sign-extended) */
    nop
    ori   $25, $0, 0x50       /* 'P' */
    mtc0  $25, $7
    break
1:
    ori   $25, $0, 0x46       /* 'F' */
    mtc0  $25, $7
    break
    .size main,.-main
