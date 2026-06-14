/* TDD: ldc1/sdc1 -- 64-bit FP load/store round-trip (FR=1).
 * dmtc1 a 64b value -> f0, sdc1 to mem, ldc1 back into f2, dmfc1 -> GPR, compare.
 * Validates the 64-bit FP load/store path (now decoded regardless of 64-bit
 * integer mode). Runs in kernel mode; co-sim clean + prints 'P'. */
    .set mips3
    .set noreorder
    .set noat
    .text
    .globl main
    .type main,@function
main:
    lui   $8, 0x1234 ; ori $8,$8,0x5678 ; dsll32 $8,$8,0
    lui   $9, 0x6abc ; ori $9,$9,0xdef0
    or    $8, $8, $9              /* $8 = 0x123456786abcdef0 */
    dmtc1 $8, $f0
    la    $10, scratch
    sdc1  $f0, 0($10)            /* store 64b */
    nop
    ldc1  $f2, 0($10)            /* load it back */
    nop
    dmfc1 $11, $f2
    nop
    bne   $8, $11, fail
    nop
    ori   $25, $0, 0x50 ; mtc0 $25, $7 ; break
fail:
    ori   $25, $0, 0x46 ; mtc0 $25, $7 ; break
    .size main,.-main
    .data
    .align 3
scratch: .dword 0
