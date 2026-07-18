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
main:
    la $14, data
    lw $8, 0($14)
    mtc1 $8, $f0 ; nop
    cvt.d.w $f2, $f0 ; nop ; nop ; nop
    sdc1 $f2, 64($14) ; nop ; nop
    lw $9, 64($14)
    lui $13, 0x405d ; ori $13,$13,0x0000
    bne $9, $13, fail0 ; nop
    lw $8, 4($14)
    mtc1 $8, $f0 ; nop
    cvt.d.w $f2, $f0 ; nop ; nop ; nop
    sdc1 $f2, 64($14) ; nop ; nop
    lw $9, 64($14)
    lui $13, 0x406b ; ori $13,$13,0x0000
    bne $9, $13, fail1 ; nop
    lw $8, 8($14)
    mtc1 $8, $f0 ; nop
    cvt.d.w $f2, $f0 ; nop ; nop ; nop
    sdc1 $f2, 64($14) ; nop ; nop
    lw $9, 64($14)
    lui $13, 0x404d ; ori $13,$13,0x0000
    bne $9, $13, fail2 ; nop
    lw $8, 12($14)
    mtc1 $8, $f0 ; nop
    cvt.d.w $f2, $f0 ; nop ; nop ; nop
    sdc1 $f2, 64($14) ; nop ; nop
    lw $9, 64($14)
    lui $13, 0x4059 ; ori $13,$13,0x0000
    bne $9, $13, fail3 ; nop
    lw $8, 16($14)
    mtc1 $8, $f0 ; nop
    cvt.d.w $f2, $f0 ; nop ; nop ; nop
    sdc1 $f2, 64($14) ; nop ; nop
    lw $9, 64($14)
    lui $13, 0x401c ; ori $13,$13,0x0000
    bne $9, $13, fail4 ; nop
    lw $8, 20($14)
    mtc1 $8, $f0 ; nop
    cvt.d.w $f2, $f0 ; nop ; nop ; nop
    sdc1 $f2, 64($14) ; nop ; nop
    lw $9, 64($14)
    lui $13, 0x4090 ; ori $13,$13,0x0000
    bne $9, $13, fail5 ; nop
    lw $8, 24($14)
    mtc1 $8, $f0 ; nop
    cvt.d.w $f2, $f0 ; nop ; nop ; nop
    sdc1 $f2, 64($14) ; nop ; nop
    lw $9, 64($14)
    lui $13, 0x4008 ; ori $13,$13,0x0000
    bne $9, $13, fail6 ; nop
    PUTC 0x50 ; HALT
fail0: PUTC 0x46 ; PUTC 0x30 ; HALT
fail1: PUTC 0x46 ; PUTC 0x31 ; HALT
fail2: PUTC 0x46 ; PUTC 0x32 ; HALT
fail3: PUTC 0x46 ; PUTC 0x33 ; HALT
fail4: PUTC 0x46 ; PUTC 0x34 ; HALT
fail5: PUTC 0x46 ; PUTC 0x35 ; HALT
fail6: PUTC 0x46 ; PUTC 0x36 ; HALT
    .data
    .align 3
data:
    .word 116, 216, 58, 100, 7, 1024, 3
    .align 3
    .space 16
