/* TDD test 3: mtc1 -> swc1 -> lw round-trip.  An FP register's value is stored
 * to memory via swc1 and read back with a plain int load.
 * PASS ('P') iff the FP-store wrote the correct word to memory. */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    la    $30, scratch
    lui   $8, 0xcafe
    ori   $8, $8, 0xb0ba      /* $8 = 0xcafeb0ba */
    mtc1  $8, $f4             /* f4 <- $8 */
    nop
    nop
    swc1  $f4, 8($30)         /* mem[scratch+8] <- f4  (FP store) */
    nop
    nop
    lw    $9, 8($30)          /* $9 <- mem[scratch+8] */
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
