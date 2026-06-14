# macros.s -- r9999 shim replacement for cheritest's macros.s
#
# Provides exactly the macros the imported alu/branch/mem/cp0/tlb tests use,
# retargeted to the r9999 bare-metal console (mtc0 $7 putchar + break).  The
# original cheritest macros.s is CHERI/BERI specific (capability ops, BERI CP0
# regs, multicore barriers) and is NOT used here.
#
# Key retarget: cheritest dumps registers with "mtc0 $rt,$26" and halts with
# "mtc0 $rt,$23".  r9999 models neither CP0 reg, so we override the `mtc0`
# mnemonic with a macro that expands those two writes to our dump/halt sequence
# and passes every other mtc0 through to the real instruction (.word-encoded).

# ---------------------------------------------------------------------------
# mtc0 override (inline-dump tests only)
# ---------------------------------------------------------------------------
# The old-style alu/branch/mem tests define their own `start:` and end with
#   mtc0 $rt,$26   (dump all GPRs)
#   mtc0 $rt,$23   (halt)
# and use `mtc0` for NOTHING else (verified across the imported set).  When the
# Makefile builds those with -DINLINE_DUMP we override the `mtc0` mnemonic so
# those two writes become our dump/halt sequence.  The cp0/tlb tests use real
# mtc0/dmtc0 and are built WITHOUT -DINLINE_DUMP, so the real instruction stands
# and their dump/halt happens in crt0's `finish` after test() returns.
.ifdef INLINE_DUMP
.macro mtc0 reg, cp0reg
	.ifc \cp0reg,$26
		DUMP_GPRS
	.else
	.ifc \cp0reg,$23
		break
	.else
		.error "INLINE_DUMP build saw mtc0 to a CP0 reg other than $26/$23"
	.endif
	.endif
.endm
.endif

# ---------------------------------------------------------------------------
# DUMP_GPRS: snapshot all 32 GPRs (pristine $ra preserved; clobbers $k0/$k1),
# then call __dump_print (defined in dump.s) to format them to the console.
# ---------------------------------------------------------------------------
.macro DUMP_GPRS
	.set push
	.set noreorder
	.set noat
	dla	$k0, __gpr_snapshot	# clobbers $k0 only
	sd	$0,  0($k0)
	sd	$1,  8($k0)
	sd	$2,  16($k0)
	sd	$3,  24($k0)
	sd	$4,  32($k0)
	sd	$5,  40($k0)
	sd	$6,  48($k0)
	sd	$7,  56($k0)
	sd	$8,  64($k0)
	sd	$9,  72($k0)
	sd	$10, 80($k0)
	sd	$11, 88($k0)
	sd	$12, 96($k0)
	sd	$13, 104($k0)
	sd	$14, 112($k0)
	sd	$15, 120($k0)
	sd	$16, 128($k0)
	sd	$17, 136($k0)
	sd	$18, 144($k0)
	sd	$19, 152($k0)
	sd	$20, 160($k0)
	sd	$21, 168($k0)
	sd	$22, 176($k0)
	sd	$23, 184($k0)
	sd	$24, 192($k0)
	sd	$25, 200($k0)
	sd	$26, 208($k0)		# (k0 already clobbered; not asserted on)
	sd	$27, 216($k0)
	sd	$28, 224($k0)
	sd	$29, 232($k0)
	sd	$30, 240($k0)
	sd	$31, 248($k0)
	jal	__dump_print
	nop
	.set pop
.endm

# ---------------------------------------------------------------------------
# Test entry/exit (BEGIN_TEST / END_TEST style)
# ---------------------------------------------------------------------------
.macro __SET_DEFAULT_TEST_ASM_OPTS
	.set mips64
	.set noreorder
	.set nobopt
.endm

.macro BEGIN_TEST_WITH_CUSTOM_TRAP_HANDLER extra_stack_space=0
	__SET_DEFAULT_TEST_ASM_OPTS
	.text
	.global test
	.ent test
	test:
		# Save $ra (= crt0's finish) on the stack: the test body uses `jal`
		# (e.g. bev0_handler_install) which clobbers $ra, and END_TEST must
		# return to crt0, not to a stray jal site.  Mirrors cheritest's
		# mips_function_entry.
		daddiu	$sp, $sp, -(\extra_stack_space + 16)
		sd	$ra, (\extra_stack_space + 8)($sp)
		sd	$fp, (\extra_stack_space)($sp)
		daddiu	$fp, $sp, (\extra_stack_space + 16)
.endm

.macro BEGIN_CUSTOM_TRAP_HANDLER
	.global default_trap_handler
	.ent default_trap_handler
	default_trap_handler:
.endm

.macro END_CUSTOM_TRAP_HANDLER
	.end default_trap_handler
.endm

# BEGIN_TEST: install the counting trap handler (so traps land in our handler
# and set $v0 = trap count, $k1 = compressed cause), then begin test().
.macro BEGIN_TEST extra_stack_space=0, trap_count_reg=$v0
	.text
	__SET_DEFAULT_TEST_ASM_OPTS
	DEFINE_COUNTING_TRAP_HANDLER default_trap_handler, trap_count_reg=\trap_count_reg
	BEGIN_TEST_WITH_CUSTOM_TRAP_HANDLER \extra_stack_space
		dli $v0, 0
		dli $k1, 0
.endm

.macro BEGIN_TEST_WITH_OLD_EXCEPTION_HANDLER extra_stack_space=0
	.text
	__SET_DEFAULT_TEST_ASM_OPTS
	BEGIN_CUSTOM_TRAP_HANDLER
		dla $k0, exception_count_handler
		jr $k0
		nop
	END_CUSTOM_TRAP_HANDLER
	BEGIN_TEST_WITH_CUSTOM_TRAP_HANDLER \extra_stack_space
.endm

# END_TEST: restore $ra from the stack and return to crt0, which dumps + halts.
# Mirrors cheritest's mips_function_return.
.macro END_TEST extra_stack_space=0
	ld	$ra, (\extra_stack_space + 8)($sp)
	ld	$fp, (\extra_stack_space)($sp)
	jr	$ra
	daddiu	$sp, $sp, (\extra_stack_space + 16)	# delay slot
	.end test
.endm

# ---------------------------------------------------------------------------
# ERET helper
# ---------------------------------------------------------------------------
.macro DO_ERET
	ssnop
	ssnop
	ssnop
	ssnop
	eret
.endm

# ---------------------------------------------------------------------------
# Counting trap handler (r9999 / R4000 model).
#   On entry: exception.  Saves nothing CHERI-specific.
#   Records:  $v0 = #traps handled, $k1 = compressed cause (bits16-31 = low 16
#             of CP0_Cause), $k0 = BadVAddr.  Skips the faulting instruction
#             (EPC+=4, or EPC+=8 if in branch-delay) and ERETs.  syscall exits.
# This mirrors cheritest's DEFINE_COUNTING_CHERI_TRAP_HANDLER, minus capcause.
# Uses CP0 UserLocal-substitute: we store the count in a memory word.
# ---------------------------------------------------------------------------
.macro __get_trap_count dest
	dla	$k0, __trap_count
	ld	\dest, 0($k0)
.endm

.macro __set_trap_count src
	dla	$k0, __trap_count
	sd	\src, 0($k0)
.endm

.macro collect_compressed_trap_info compressed_info_reg=$k1, tmp_reg=$k0, trap_count_reg=$v0
	dmfc0	\tmp_reg, $13			# Cause
	dsll	\tmp_reg, \tmp_reg, 32
	dsrl	\compressed_info_reg, \tmp_reg, 16	# low 16 of Cause -> bits16-31
	__get_trap_count \trap_count_reg
	daddiu	\trap_count_reg, \trap_count_reg, 1
	__set_trap_count \trap_count_reg
	dsll	\trap_count_reg, \trap_count_reg, 48
	or	\compressed_info_reg, \compressed_info_reg, \trap_count_reg
	dsrl	\trap_count_reg, \trap_count_reg, 48
.endm

.macro DEFINE_COUNTING_TRAP_HANDLER name=default_trap_handler, trap_count_reg=$v0
.text
.global \name
.ent \name
\name:
	.set push
	.set noat
	dmfc0	$k0, $13			# Cause
	andi	$k1, $k0, (0x1f << 2)		# ExcCode field
	daddiu	$k1, -(8 << 2)			# syscall == 8
	beqz	$k1, .Lsyscall_\@
	nop
.Lnot_syscall_\@:
	collect_compressed_trap_info trap_count_reg=\trap_count_reg
	# branch-delay? Cause bit 31 (BD)
	dmfc0	$k0, $13
	dsrl	$k0, $k0, 31
	andi	$k0, $k0, 1
	bne	$k0, $zero, .Lbd_\@
	nop
.Lnobd_\@:
	dmfc0	$k0, $14			# EPC
	daddiu	$k0, $k0, 4
	dmtc0	$k0, $14
	b	.Leret_\@
	nop
.Lbd_\@:
	dmfc0	$k0, $14
	daddiu	$k0, $k0, 8
	dmtc0	$k0, $14
.Leret_\@:
	dmfc0	$k0, $8				# BadVAddr
	DO_ERET
.Lsyscall_\@:
	# syscall: exit the test (return to crt0 via $ra, which is finish)
	__get_trap_count $v0
	dla	$ra, finish
	jr	$ra
	nop
	.set pop
.end \name
.global end_of_\name
end_of_\name\():
	nop
.endm

# Old-style exception_count_handler used by BEGIN_TEST_WITH_OLD_EXCEPTION_HANDLER
.macro DEFINE_OLD_EXCEPTION_HANDLER
.text
.global exception_count_handler
.ent exception_count_handler
exception_count_handler:
	.set push
	.set noat
	__get_trap_count $k0
	daddiu	$k0, $k0, 1
	__set_trap_count $k0
	dmfc0	$k0, $13			# is it a timer interrupt?
	andi	$k0, $k0, 0x8000
	beq	$zero, $k0, .Loeh_inc
	nop
	mtc0 $zero, $11				# clear timer compare
	b	.Loeh_done
	nop
.Loeh_inc:
	dmfc0	$k0, $14
	daddiu	$k0, $k0, 4
	dmtc0	$k0, $14
.Loeh_done:
	DO_ERET
	.set pop
.end exception_count_handler
.endm

# clear handler scratch regs (used by check_instruction_traps)
.macro clear_counting_exception_handler_regs
	dli $k0, 0
	dli $k1, 0
.endm

.macro check_instruction_traps compressed_info, insn:vararg
	dli \compressed_info, 0
	clear_counting_exception_handler_regs
	\insn
	move \compressed_info, $k1
	clear_counting_exception_handler_regs
.endm

# ---------------------------------------------------------------------------
# TLB helper (R4000): install one indexed entry.  Args mirror cheritest's
# install_tlb_entry(index, physaddr, vaddr, pagemask) in $a0..$a3.
# ---------------------------------------------------------------------------
.macro init_tlb
	dmtc0	$zero, $5			# PageMask = 0 (4K)
	dmtc0	$zero, $2			# EntryLo0 (V=0)
	dmtc0	$zero, $3			# EntryLo1 (V=0)
	dmfc0	$t0, $16, 1			# Config1
	dsrl	$t0, $t0, 25
	andi	$t0, $t0, 0x3f			# max TLB index
	dli	$t1, 0x3fffffff80000000
1:
	dsll	$t2, $t0, 13
	dadd	$t2, $t1, $t2
	dmtc0	$t2, $10			# EntryHi
	dmtc0	$t0, $0				# Index
	ssnop
	ssnop
	ssnop
	ssnop
	tlbwi
	dsub	$t0, $t0, 1
	bgez	$t0, 1b
	nop
	ssnop
	ssnop
	ssnop
	ssnop
.endm
