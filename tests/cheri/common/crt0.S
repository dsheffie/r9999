/*
 * crt0.S -- bare-metal startup for r9999 cheritest shim.
 *
 * Sets up 64-bit kernel mode (KX/SX/UX in Status so 64-bit ops don't RI),
 * a stack, and a known register sentinel pattern (matching cheritest init.s so
 * leaked register values are obvious), then enters the test.
 *
 * Two entry models, selected by the build:
 *   -DENTRY_START : old-style test defines its own global `start`; after setup
 *                   we `j start`.  Such tests dump+halt themselves via the
 *                   overridden `mtc0 $26`/`mtc0 $23` (see macros.s).
 *   (default)     : BEGIN_TEST-style test defines `test` and returns; after
 *                   setup we `jal test`, then fall into `finish` (dump+halt).
 *
 * Vectors live at 0x80000000 (link.ld); the general-exception vector jumps to
 * `jump_to_real_trap_handler`, which the cp0/tlb tests define (via BEGIN_TEST)
 * as `default_trap_handler`.
 */

	.set mips64
	.set noreorder
	.set noat

	.include "macros.s"

/* --- BEV=0 exception vectors at 0x80000000 ----------------------------- */
	.section .except_vec, "ax"
	.org 0x000				/* TLB refill (32-bit) */
	.global _tlb_refill_vec
_tlb_refill_vec:
	dla	$k0, __vec_common
	jr	$k0
	nop

	.org 0x080				/* XTLB refill (64-bit) */
	dla	$k0, __vec_common
	jr	$k0
	nop

	.org 0x100				/* Cache error */
	break

	.org 0x180				/* General exception */
	.global _general_exc_vec
_general_exc_vec:
	dla	$k0, __vec_common
	jr	$k0
	nop

/* Common landing pad: jump to the active trap handler (set via lib.s
 * bev0_handler_install / the BEGIN_TEST counting handler).  Defined in lib.s. */
	.section .text.startup, "ax"
__vec_common:
	dla	$k0, jump_to_real_trap_handler
	jr	$k0
	nop

/* --- reset / entry ----------------------------------------------------- */
	.section .text.startup, "ax"
	.global _start
	.type _start, @function
_start:
	/* Status: clear everything, then set KX|SX|UX (bits 7:5) for 64-bit
	 * ops, CU0 (bit 28) so CP0 is usable, leave EXL/IE clear, kernel mode
	 * (KSU=00). */
	mfc0	$t0, $12
	li	$t1, 0x100000e0			/* CU0(28) | KX(7)|SX(6)|UX(5) */
	or	$t0, $t0, $t1
	li	$t1, 0xffbfffe1			/* clear BEV(22), KSU(4:3), ERL(2), EXL(1) -> kernel, no exc level, BEV=0 vectors */
	and	$t0, $t0, $t1
	mtc0	$t0, $12
	ssnop
	ssnop
	ssnop
	ssnop
	ssnop
	ssnop
	ssnop
	ssnop

	/* Config.K0 = cached (kseg0 coherency) */
	mfc0	$t0, $16
	ori	$t0, $t0, 7
	xori	$t0, $t0, 4
	mtc0	$t0, $16

	/* stack */
	dla	$sp, _stack_top
	dla	$fp, _stack_top
	daddu	$sp, $sp, -64

	/* zero bss */
	dla	$t0, __bss_start
	dla	$t1, __bss_end
1:	beq	$t0, $t1, 2f
	nop
	sd	$zero, 0($t0)
	b	1b
	daddu	$t0, $t0, 8
2:

	/* sentinel register fill (matches cheritest init.s) */
	dli	$1,  0x0101010101010101
	dli	$2,  0x0202020202020202
	dli	$3,  0x0303030303030303
	dli	$4,  0x0404040404040404
	dli	$5,  0x0505050505050505
	dli	$6,  0x0606060606060606
	dli	$7,  0x0707070707070707
	dli	$8,  0x0808080808080808
	dli	$9,  0x0909090909090909
	dli	$10, 0x0a0a0a0a0a0a0a0a
	dli	$11, 0x0b0b0b0b0b0b0b0b
	dli	$12, 0x0c0c0c0c0c0c0c0c
	dli	$13, 0x0d0d0d0d0d0d0d0d
	dli	$14, 0x0e0e0e0e0e0e0e0e
	dli	$15, 0x0f0f0f0f0f0f0f0f
	dli	$16, 0x1010101010101010
	dli	$17, 0x1111111111111111
	dli	$18, 0x1212121212121212
	dli	$19, 0x1313131313131313
	dli	$20, 0x1414141414141414
	dli	$21, 0x1515151515151515
	dli	$22, 0x1616161616161616
	dli	$23, 0x1717171717171717
	dli	$24, 0x1818181818181818
	dli	$25, 0x1919191919191919
	dli	$26, 0x1a1a1a1a1a1a1a1a
	dli	$27, 0x1b1b1b1b1b1b1b1b
	dli	$28, 0x1c1c1c1c1c1c1c1c
	/* not filled: $sp($29) $fp($30) $ra($31) */
	mthi	$1
	mtlo	$1

#ifdef ENTRY_START
	j	start
	nop
#else
	dla	$25, test
	jalr	$25
	nop
	/* fall through into finish */
	.global finish
	.ent finish
finish:
	DUMP_GPRS
	break
	.end finish
#endif
	.size _start, . - _start
