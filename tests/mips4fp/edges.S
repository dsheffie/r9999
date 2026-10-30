/* edges.S -- ENABLE_MIPS4 FP arithmetic: madd/msub/nmadd/nmsub (.s/.d, unfused),
 * recip/rsqrt (.s/.d).  Covers what gcc's scheduling will not: back-to-back madds,
 * a madd whose fr is the madd just before it (wakeup), a madd followed at once by
 * add/mul (fpu0's reserved add-pass slot), and recip/rsqrt next to each other and to
 * an integer divide (the shared divider).  Even registers only (FR=0).  Returns a
 * checksum of every result's bits. */
#include "sim.h"
	.set	noreorder
	.set	mips4
	.text
	.globl	fp_edges
fp_edges:
	la	$a0, fpdata
	li	$v0, 0
	lwc1	$f2, 0($a0)		/* 1.5f */
	lwc1	$f4, 4($a0)		/* 2.25f */
	lwc1	$f6, 8($a0)		/* -0.75f */
	lwc1	$f8, 12($a0)		/* 3.0f */
	ldc1	$f10, 16($a0)		/* 1.25 */
	ldc1	$f12, 24($a0)		/* 7.0 */
	ldc1	$f14, 32($a0)		/* -2.5 */
	ldc1	$f16, 40($a0)		/* 0.1 */
	/* the four kinds, single */
	madd.s	$f20, $f2, $f4, $f6	/* f4*f6 + f2 */
	msub.s	$f22, $f2, $f4, $f8
	nmadd.s	$f24, $f6, $f8, $f4
	nmsub.s	$f26, $f8, $f2, $f6
	/* back to back, and fr = the previous result (wakes on it) */
	madd.d	$f28, $f10, $f12, $f14
	madd.d	$f30, $f28, $f12, $f16
	msub.d	$f0, $f30, $f16, $f10
	nmadd.d	$f18, $f0, $f14, $f12
	/* a madd, then an add and a mul straight after (the add pass's slot) */
	nmsub.d	$f28, $f16, $f10, $f12
	add.s	$f2, $f4, $f6
	mul.d	$f30, $f10, $f14
	madd.s	$f4, $f2, $f4, $f8
	sub.s	$f6, $f8, $f2
	/* recip / rsqrt, with an integer divide in between on the shared divider */
	recip.s	$f8, $f8
	li	$t0, 1000003
	li	$t1, 37
	div	$zero, $t0, $t1
	rsqrt.s	$f10, $f4
	recip.d	$f12, $f12
	mflo	$t2
	rsqrt.d	$f14, $f16		/* 1/sqrt(0.1): an inexact root */
	addu	$v0, $v0, $t2
	/* fold every result in */
	.irp	r, 20, 22, 24, 26, 2, 4, 6, 8, 10
	mfc1	$t0, $f\r
	sll	$t1, $v0, 5
	srl	$v0, $v0, 27
	or	$v0, $v0, $t1
	xor	$v0, $v0, $t0
	.endr
	/* doubles: FR=0, the high word of $fN is $f(N+1) */
	.macro	FOLDD lo, hi
	mfc1	$t0, $f\lo
	mfc1	$t1, $f\hi
	addu	$v0, $v0, $t0
	xor	$v0, $v0, $t1
	.endm
	FOLDD	28, 29
	FOLDD	30, 31
	FOLDD	0, 1
	FOLDD	18, 19
	FOLDD	12, 13
	FOLDD	14, 15
	jr	$ra
	nop

	.data
	.align	3
fpdata:
	.float	1.5, 2.25, -0.75, 3.0
	.double	1.25, 7.0, -2.5, 0.1
