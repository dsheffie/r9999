# dump.s -- register-dump + halt support for the r9999 cheritest shim.
#
# r9999 console API (tests/common/sim.h):
#   mtc0 $rt, $7  -> pushes $rt[7:0] to a putchar FIFO drained to stdout
#   break         -> terminates the simulator
#
# cheritest's epilogue is "mtc0 $rt,$26" (dump all GPRs) then "mtc0 $rt,$23"
# (halt).  r9999 does not model CP0 regs 23/26, so the shim macros (macros.s)
# expand "mtc0 _,$26" to the DUMP_GPRS sequence and "mtc0 _,$23" to `break`.
#
# DUMP_GPRS snapshots all 32 GPRs to memory FIRST (clobbering only $k0/$k1,
# which no imported alu/branch/mem/cp0/tlb .py asserts on, and NOT $ra), then
# calls __dump_print which formats from the snapshot as "R<dd>=<16hex>\n".

	.set mips64
	.set noreorder
	.set noat

	.section .bss
	.balign 8
.global __gpr_snapshot
__gpr_snapshot:
	.space 8*32
	.size __gpr_snapshot, 8*32
	.text

# putchar: low byte of $a0 -> console.  Encoded as a literal mtc0 $4,$7 so the
# macro override of `mtc0` in macros.s does not recurse.  Clobbers $1/$at.
# Spins on the FIFO-full flag first: `mfc0 $7` returns {31'd0, fifo_full} (the
# 8-deep putchar FIFO).  Without this backpressure a bulk dump (~640 chars)
# overflows the FIFO on silicon, where the AXI driver drains far slower than the
# core pushes (invisible in ooo_core, which drains the FIFO instantly).
	.set push
	.set noreorder
	.set noat
.global __putc
.ent __putc
__putc:
1:	mfc0	$1, $7			# bit0 = putchar-FIFO full flag
	andi	$1, $1, 1
	bnez	$1, 1b			# spin while full (8-deep FIFO backpressure)
	nop
	.word 0x40843800		# mtc0 $4, $7  (0x40800000 | 4<<16 | 7<<11)
	jr $ra
	nop
.end __putc
	.set pop

# __dump_print: read __gpr_snapshot, print R00..R31 as "R<dd>=<16hex>\n".
# Clobbers caller-saved regs freely (reads only from the snapshot).
	.set push
	.set noreorder
	.set noat
.global __dump_print
.ent __dump_print
__dump_print:
	move	$16, $ra		# preserve return to caller (the halt)
	dla	$2, __gpr_snapshot
	move	$17, $2			# $17 = snapshot base
	li	$18, 0			# $18 = reg index
.Lreg_loop:
	li	$4, 'R'
	jal	__putc
	nop
	li	$3, 10
	div	$0, $18, $3
	mflo	$5			# tens
	mfhi	$6			# ones
	addiu	$4, $5, '0'
	jal	__putc
	nop
	addiu	$4, $6, '0'
	jal	__putc
	nop
	li	$4, '='
	jal	__putc
	nop
	dsll	$2, $18, 3
	daddu	$2, $17, $2
	ld	$19, 0($2)		# $19 = 64b value
	li	$20, 60			# shift
.Lhex_loop:
	dsrlv	$3, $19, $20
	andi	$3, $3, 0xf
	sltiu	$5, $3, 10
	beq	$5, $0, .Lhex_alpha
	nop
	addiu	$4, $3, '0'
	b	.Lhex_emit
	nop
.Lhex_alpha:
	addiu	$4, $3, 'a'-10
.Lhex_emit:
	jal	__putc
	nop
	addiu	$20, $20, -4
	bgez	$20, .Lhex_loop
	nop
	li	$4, '\n'
	jal	__putc
	nop
	addiu	$18, $18, 1
	slti	$2, $18, 32
	bne	$2, $0, .Lreg_loop
	nop
	jr	$16
	nop
.end __dump_print
	.set pop
