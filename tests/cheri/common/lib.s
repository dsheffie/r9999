# lib.s -- minimal r9999 stand-ins for the cheritest lib.s helpers that the
# BEGIN_TEST-style tests call.  Only the handful actually referenced by the
# imported alu/branch/mem/cp0/tlb tests are provided.
#
# Handler dispatch model: crt0's BEV=0 vectors (0x80000000/.../0x80000180) all
# jump to `jump_to_real_trap_handler`, which loads the function pointer in
# `__active_handler` and jumps to it.  bev0_handler_install / the BEGIN_TEST
# common-handler macros write that pointer.  If unset, we halt (break) so a
# stray exception is loud.

	.set mips64
	.set noreorder
	.set noat

	.section .data
	.balign 8
.global __active_handler
__active_handler:
	.8byte 0
.global __trap_count
__trap_count:
	.8byte 0
.global exception_count
exception_count:
	.8byte 0
.global continue_after_exception
continue_after_exception:
	.8byte 0

	.text

# jump_to_real_trap_handler: entered from every BEV0 vector (see crt0).  Loads
# __active_handler and tail-jumps to it.  Uses $k0 only (k0/k1 are the kernel
# scratch regs and are not asserted on by these tests' .py checks).
	.set push
	.set noreorder
	.set noat
.global jump_to_real_trap_handler
.ent jump_to_real_trap_handler
jump_to_real_trap_handler:
	dla	$k0, __active_handler
	ld	$k0, 0($k0)
	beqz	$k0, .Lno_handler
	nop
	jr	$k0
	nop
.Lno_handler:
	break
.end jump_to_real_trap_handler

# bev_clear: clear pending timer interrupt / nothing else needed here.
.global bev_clear
.ent bev_clear
bev_clear:
	mtc0	$zero, $11		# Compare: clear timer IP
	jr	$ra
	nop
.end bev_clear

# bev0_handler_install($a0 = handler addr): record it as the active handler.
.global bev0_handler_install
.ent bev0_handler_install
bev0_handler_install:
	dla	$k0, __active_handler
	sd	$a0, 0($k0)
	jr	$ra
	nop
.end bev0_handler_install

# bev0_set_common_handler_raw($a0 = start, $a1 = end): same as install (we don't
# copy the handler to the vector, we dispatch by pointer).
.global bev0_set_common_handler_raw
.ent bev0_set_common_handler_raw
bev0_set_common_handler_raw:
	dla	$k0, __active_handler
	sd	$a0, 0($k0)
	jr	$ra
	nop
.end bev0_set_common_handler_raw

# get_corethread_id: single core/thread -> 0.
.global get_corethread_id
.ent get_corethread_id
get_corethread_id:
	jr	$ra
	move	$v0, $zero		# delay slot
.end get_corethread_id

# bzero($a0 = ptr, $a1 = len): zero len bytes.
.global bzero
.ent bzero
bzero:
	beqz	$a1, .Lbz_done
	nop
.Lbz_loop:
	sb	$zero, 0($a0)
	daddiu	$a0, $a0, 1
	daddiu	$a1, $a1, -1
	bnez	$a1, .Lbz_loop
	nop
.Lbz_done:
	jr	$ra
	nop
.end bzero
	.set pop

	.section .bss
	.balign 8
.global __sp
__sp:
	.space 8
