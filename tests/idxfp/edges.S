/* edges.S -- indexed FP load/store cases gcc does not emit: index = $zero, base =
 * $zero, a negative index, the index from the instruction just before (ALU and
 * load: the int->mem and mem->mem srcC bypasses), FR=0 odd-register halves, an
 * indexed store read back by an indexed load and by a plain lw (store-to-load
 * through the store buffer), and an indexed load in a branch delay slot.
 * Returns a checksum of everything loaded. */
#include "sim.h"
	.set	noreorder
	.set	mips4
	.text
	.globl	edge_cases
edge_cases:
	la	$a0, edge_buf
	li	$v0, 0
	/* ldxc1: base + index, even register */
	li	$t0, 8
	ldxc1	$f2, $t0($a0)			/* words 2,3 */
	mfc1	$t1, $f2
	mfc1	$t2, $f3
	addu	$v0, $v0, $t1
	xor	$v0, $v0, $t2
	/* lwxc1 into an even and an odd register (FR=0: the two halves of $f4) */
	li	$t0, 16
	lwxc1	$f4, $t0($a0)			/* word 4 */
	li	$t0, 20
	lwxc1	$f5, $t0($a0)			/* word 5 */
	mfc1	$t1, $f4
	mfc1	$t2, $f5
	addu	$v0, $v0, $t1
	sll	$t2, $t2, 1
	addu	$v0, $v0, $t2
	/* index = $zero: plain base */
	lwxc1	$f6, $zero($a0)			/* word 0 */
	mfc1	$t1, $f6
	addu	$v0, $v0, $t1
	/* base = $zero: the index is the whole address */
	addiu	$t3, $a0, 4
	lwxc1	$f6, $t3($zero)			/* word 1 */
	mfc1	$t1, $f6
	xor	$v0, $v0, $t1
	/* negative index */
	addiu	$t4, $a0, 32
	li	$t0, -12
	lwxc1	$f8, $t0($t4)			/* word 5 */
	mfc1	$t1, $f8
	addu	$v0, $v0, $t1
	/* index from the instruction just before (int->mem bypass) */
	li	$t5, 3
	sll	$t0, $t5, 2			/* 12 */
	lwxc1	$f8, $t0($a0)			/* word 3 */
	mfc1	$t1, $f8
	addu	$v0, $v0, $t1
	/* index from a load just before (mem->mem bypass) */
	la	$t6, edge_idx
	lw	$t0, 0($t6)			/* 24 */
	lwxc1	$f8, $t0($a0)			/* word 6 */
	mfc1	$t1, $f8
	xor	$v0, $v0, $t1
	/* sdxc1 then ldxc1 of the same address, then plain lw of both words */
	la	$a1, edge_out
	li	$t0, 8
	sdxc1	$f2, $t0($a1)
	ldxc1	$f10, $t0($a1)
	mfc1	$t1, $f10
	mfc1	$t2, $f11
	addu	$v0, $v0, $t1
	addu	$v0, $v0, $t2
	lw	$t1, 8($a1)
	lw	$t2, 12($a1)
	xor	$v0, $v0, $t1
	addu	$v0, $v0, $t2
	/* swxc1 from an even and an odd register, read back with lw */
	li	$t0, 0
	swxc1	$f4, $t0($a1)
	li	$t0, 4
	swxc1	$f5, $t0($a1)
	lw	$t1, 0($a1)
	lw	$t2, 4($a1)
	addu	$v0, $v0, $t1
	sll	$t2, $t2, 3
	xor	$v0, $v0, $t2
	/* indexed load in a branch delay slot */
	li	$t0, 28
	beq	$zero, $zero, 1f
	lwxc1	$f12, $t0($a0)			/* word 7 */
	li	$v0, 0				/* skipped */
1:	mfc1	$t1, $f12
	addu	$v0, $v0, $t1
	jr	$ra
	nop

	.data
	.align	3
edge_buf:
	.word	0x11111111, 0x22222222, 0x3333aaaa, 0x4444bbbb
	.word	0x55550001, 0x66660002, 0x77770003, 0x88880004
edge_idx:
	.word	24
	.align	3
edge_out:
	.space	16
