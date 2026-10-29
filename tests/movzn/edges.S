/* edges.S -- movn/movz cases gcc does not emit: $zero operands, rd aliasing
 * rs/rt, a condition from the instruction just before (ALU and load), chains,
 * and movn/movz in branch delay slots.  Returns a checksum of the results. */
#include "sim.h"
	.set	noreorder
	.set	mips4
	.text
	.globl	edge_cases
edge_cases:
	li	$t0, 5
	li	$t1, 9
	li	$t2, 0
	li	$v0, 0
	/* rt = $zero: movz always moves, movn never does */
	move	$t3, $t1
	movz	$t3, $t0, $zero		/* t3 = 5 */
	movn	$t3, $t1, $zero		/* t3 stays 5 */
	addu	$v0, $v0, $t3
	/* rs = $zero: moves a zero */
	move	$t4, $t1
	movn	$t4, $zero, $t0		/* t4 = 0 */
	addu	$v0, $v0, $t4
	/* rd = $zero: a nop */
	movn	$zero, $t1, $t0
	addu	$v0, $v0, $zero
	/* rd == rs, rd == rt */
	move	$t5, $t0
	movn	$t5, $t5, $t1		/* t5 = 5 */
	movz	$t5, $t1, $t5		/* t5 != 0: stays 5 */
	addu	$v0, $v0, $t5
	move	$t6, $t1
	movn	$t6, $t0, $t6		/* cond is the old rd itself: t6 = 5 */
	addu	$v0, $v0, $t6
	/* condition produced by the instruction just before */
	subu	$t7, $t0, $t0		/* 0 */
	movz	$t2, $t1, $t7		/* t2 = 9 */
	addu	$v0, $v0, $t2
	addiu	$t7, $t7, 3		/* 3 */
	movn	$t2, $t0, $t7		/* t2 = 5 */
	addu	$v0, $v0, $t2
	/* condition from a load just before (load-use) */
	la	$a0, edge_mem
	lw	$t8, 0($a0)		/* 0 */
	movz	$t2, $t1, $t8		/* t2 = 9 */
	lw	$t8, 4($a0)		/* 0x1234 */
	movz	$t2, $t0, $t8		/* stays 9 */
	addu	$v0, $v0, $t2
	/* chains: each condition is the previous result */
	li	$t3, 0
	li	$t4, 1
	movz	$t4, $zero, $t3		/* t4 = 0 */
	movz	$t3, $t1, $t4		/* t3 = 9 */
	movn	$t4, $t3, $t3		/* t4 = 9 */
	addu	$v0, $v0, $t4
	/* in a taken branch's delay slot, and in a not-taken one's */
	li	$t3, 1
	beq	$zero, $zero, 1f
	movn	$t3, $t1, $t0		/* t3 = 9 */
	li	$t3, 77			/* skipped */
1:	addu	$v0, $v0, $t3
	bne	$zero, $zero, 2f
	movz	$t3, $t0, $zero		/* t3 = 5 */
2:	addu	$v0, $v0, $t3
	/* integer movt/movf on FCC bits; FP movt/movf/movz/movn.fmt */
	li	$t0, 0x3f800000		/* 1.0f */
	mtc1	$t0, $f0
	li	$t0, 0x40000000		/* 2.0f */
	mtc1	$t0, $f2
	c.lt.s	$fcc0, $f0, $f2		/* 1 < 2: fcc0 = 1 */
	c.lt.s	$fcc3, $f2, $f0		/* 2 < 1: fcc3 = 0 */
	li	$t3, 1
	li	$t4, 2
	movt	$t3, $t1, $fcc0		/* t3 = 9 */
	movf	$t4, $t1, $fcc0		/* stays 2 */
	movf	$t4, $t0, $fcc3		/* fcc3 = 0: t4 = 0x40000000 */
	srl	$t4, $t4, 28		/* 4 */
	addu	$v0, $v0, $t3
	addu	$v0, $v0, $t4
	mov.s	$f4, $f0		/* 1.0f */
	movt.s	$f4, $f2, $fcc0		/* f4 = 2.0f */
	movf.s	$f4, $f0, $fcc0		/* stays 2.0f */
	movt.s	$f4, $f0, $fcc3		/* stays 2.0f */
	mfc1	$t5, $f4
	srl	$t5, $t5, 28		/* 4 */
	addu	$v0, $v0, $t5
	cvt.d.s	$f6, $f0		/* 1.0 */
	cvt.d.s	$f8, $f2		/* 2.0 */
	movn.d	$f6, $f8, $zero		/* rt = $zero: stays 1.0 */
	movz.d	$f6, $f8, $zero		/* f6 = 2.0 */
	addiu	$t6, $zero, 0		/* condition produced just before */
	movz.d	$f8, $f6, $t6		/* f8 = 2.0 (unchanged value, moved) */
	li	$t6, 7
	movn.s	$f4, $f0, $t6		/* f4 = 1.0f */
	mfc1	$t7, $f4
	srl	$t7, $t7, 28		/* 3 */
	addu	$v0, $v0, $t7
	cvt.s.d	$f10, $f8		/* 2.0f */
	mfc1	$t8, $f10		/* 0x40000000 */
	srl	$t8, $t8, 28		/* 4 */
	addu	$v0, $v0, $t8
	/* expected: 61 + 9 + 4 + 4 + 3 + 4 = 85 */
	jr	$ra
	nop

	.data
	.align	2
edge_mem:
	.word	0, 0x1234
