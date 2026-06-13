/* TDD test 2: int store -> lwc1 -> mfc1 round-trip through an FP register.
 * PASS ('P') iff a word stored to memory loads back through f0 unchanged. */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    la    $30, scratch
    lui   $8, 0x1234
    ori   $8, $8, 0x5678      /* $8 = 0x12345678 */
    sw    $8, 0($30)          /* mem[scratch] = $8 (plain int store) */
    lwc1  $f0, 0($30)         /* f0 <- mem[scratch]  (FP load) */
    nop
    nop
    mfc1  $9, $f0             /* $9 <- f0 */
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
    .bss
    .align 3
scratch:
    .space 64
