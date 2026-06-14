.set mips64
.set noreorder
.set noat
.text
.global _start
_start:
	mfc0 $8, $12
	lui $9, 0x1000
	ori $9, $9, 0xe0
	or  $8, $8, $9
	li  $9, 0xffffffe1
	and $8, $8, $9
	mtc0 $8, $12
	ssnop
	ssnop
	ssnop
	ssnop
	ssnop
	ssnop
	ssnop
	ssnop
	# forwarded operands (back-to-back), 1 + -2 = -1, no overflow
	li $12, 1
	li $13, -2
	add $14, $12, $13
	li $4, 0x4f       # 'O' = no trap
	.word 0x40843800
	li $4, 0x0a
	.word 0x40843800
	break
1: b 1b
	nop
