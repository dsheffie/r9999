/* Directed FP test: add.d(100,116)==216 (the IRIX capacity case) + x2-probe sweep.
 * fp_arith_d only tests tiny exact cases; this uses larger magnitudes to expose an
 * exponent-off-by-one in fpu_add/fpu_mul. Emits 'P' or 'F'<idx> on the console, then HALT. */
    .set mips3
    .set noreorder
    .set noat
    .macro HALT
    li $k0,0xBFD00000
    li $k1,1
    sw $k1,0($k0)
1:  b 1b
    nop
    .endm
    .macro PUTC c
    ori $25,$0,\c
    mtc0 $25,$7
    .endm
    .text
    .globl main
    .type main,@function
main:
    la $14, data
    /* case 0: add.d 100,116 -> 216 */
    ldc1 $f0, 0($14) ; ldc1 $f2, 8($14) ; nop ; nop
    add.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 16($14) ; nop ; nop
    lw $8, 16($14) ; lw $9, 20($14)
    lui $13,0x406b ; ori $13,$13,0x0000 ; bne $8,$13,fail0 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail0 ; nop
    /* case 1: add.d 100,115 -> 215 */
    ldc1 $f0, 24($14) ; ldc1 $f2, 32($14) ; nop ; nop
    add.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 40($14) ; nop ; nop
    lw $8, 40($14) ; lw $9, 44($14)
    lui $13,0x406a ; ori $13,$13,0xe000 ; bne $8,$13,fail1 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail1 ; nop
    /* case 2: add.d 100,117 -> 217 */
    ldc1 $f0, 48($14) ; ldc1 $f2, 56($14) ; nop ; nop
    add.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 64($14) ; nop ; nop
    lw $8, 64($14) ; lw $9, 68($14)
    lui $13,0x406b ; ori $13,$13,0x2000 ; bne $8,$13,fail2 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail2 ; nop
    /* case 3: add.d 108,108 -> 216 */
    ldc1 $f0, 72($14) ; ldc1 $f2, 80($14) ; nop ; nop
    add.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 88($14) ; nop ; nop
    lw $8, 88($14) ; lw $9, 92($14)
    lui $13,0x406b ; ori $13,$13,0x0000 ; bne $8,$13,fail3 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail3 ; nop
    /* case 4: add.d 128,128 -> 256 */
    ldc1 $f0, 96($14) ; ldc1 $f2, 104($14) ; nop ; nop
    add.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 112($14) ; nop ; nop
    lw $8, 112($14) ; lw $9, 116($14)
    lui $13,0x4070 ; ori $13,$13,0x0000 ; bne $8,$13,fail4 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail4 ; nop
    /* case 5: add.d 64,64 -> 128 */
    ldc1 $f0, 120($14) ; ldc1 $f2, 128($14) ; nop ; nop
    add.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 136($14) ; nop ; nop
    lw $8, 136($14) ; lw $9, 140($14)
    lui $13,0x4060 ; ori $13,$13,0x0000 ; bne $8,$13,fail5 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail5 ; nop
    /* case 6: add.d 200,16 -> 216 */
    ldc1 $f0, 144($14) ; ldc1 $f2, 152($14) ; nop ; nop
    add.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 160($14) ; nop ; nop
    lw $8, 160($14) ; lw $9, 164($14)
    lui $13,0x406b ; ori $13,$13,0x0000 ; bne $8,$13,fail6 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail6 ; nop
    /* case 7: add.d 1,2 -> 3 */
    ldc1 $f0, 168($14) ; ldc1 $f2, 176($14) ; nop ; nop
    add.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 184($14) ; nop ; nop
    lw $8, 184($14) ; lw $9, 188($14)
    lui $13,0x4008 ; ori $13,$13,0x0000 ; bne $8,$13,fail7 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail7 ; nop
    /* case 8: mul.d 2,3 -> 6 */
    ldc1 $f0, 192($14) ; ldc1 $f2, 200($14) ; nop ; nop
    mul.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 208($14) ; nop ; nop
    lw $8, 208($14) ; lw $9, 212($14)
    lui $13,0x4018 ; ori $13,$13,0x0000 ; bne $8,$13,fail8 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail8 ; nop
    /* case 9: mul.d 100,2 -> 200 */
    ldc1 $f0, 216($14) ; ldc1 $f2, 224($14) ; nop ; nop
    mul.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 232($14) ; nop ; nop
    lw $8, 232($14) ; lw $9, 236($14)
    lui $13,0x4069 ; ori $13,$13,0x0000 ; bne $8,$13,fail9 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail9 ; nop
    /* case 10: mul.d 108,2 -> 216 */
    ldc1 $f0, 240($14) ; ldc1 $f2, 248($14) ; nop ; nop
    mul.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 256($14) ; nop ; nop
    lw $8, 256($14) ; lw $9, 260($14)
    lui $13,0x406b ; ori $13,$13,0x0000 ; bne $8,$13,fail10 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail10 ; nop
    /* case 11: mul.d 54,2 -> 108 */
    ldc1 $f0, 264($14) ; ldc1 $f2, 272($14) ; nop ; nop
    mul.d $f4, $f0, $f2 ; nop ; nop ; nop ; nop
    sdc1 $f4, 280($14) ; nop ; nop
    lw $8, 280($14) ; lw $9, 284($14)
    lui $13,0x405b ; ori $13,$13,0x0000 ; bne $8,$13,fail11 ; nop
    lui $13,0x0000 ; ori $13,$13,0x0000 ; bne $9,$13,fail11 ; nop
    PUTC 0x50    /* 'P' all pass */
    HALT
fail0: PUTC 0x46 ; PUTC 0x30 ; HALT
fail1: PUTC 0x46 ; PUTC 0x31 ; HALT
fail2: PUTC 0x46 ; PUTC 0x32 ; HALT
fail3: PUTC 0x46 ; PUTC 0x33 ; HALT
fail4: PUTC 0x46 ; PUTC 0x34 ; HALT
fail5: PUTC 0x46 ; PUTC 0x35 ; HALT
fail6: PUTC 0x46 ; PUTC 0x36 ; HALT
fail7: PUTC 0x46 ; PUTC 0x37 ; HALT
fail8: PUTC 0x46 ; PUTC 0x38 ; HALT
fail9: PUTC 0x46 ; PUTC 0x39 ; HALT
fail10: PUTC 0x46 ; PUTC 0x3a ; HALT
fail11: PUTC 0x46 ; PUTC 0x3b ; HALT
    .size main,.-main
    .data
    .align 3
data:
    .dword 0x4059000000000000, 0x405d000000000000, 0x0
    .dword 0x4059000000000000, 0x405cc00000000000, 0x0
    .dword 0x4059000000000000, 0x405d400000000000, 0x0
    .dword 0x405b000000000000, 0x405b000000000000, 0x0
    .dword 0x4060000000000000, 0x4060000000000000, 0x0
    .dword 0x4050000000000000, 0x4050000000000000, 0x0
    .dword 0x4069000000000000, 0x4030000000000000, 0x0
    .dword 0x3ff0000000000000, 0x4000000000000000, 0x0
    .dword 0x4000000000000000, 0x4008000000000000, 0x0
    .dword 0x4059000000000000, 0x4000000000000000, 0x0
    .dword 0x405b000000000000, 0x4000000000000000, 0x0
    .dword 0x404b000000000000, 0x4000000000000000, 0x0
