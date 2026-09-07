/* test_break_trap.S -- POSITIVE CONTROL for the ExcCode-09 (break) ring trigger.
 *
 * WHY: the SIGFPE face of the bug is a userspace `break 0x7' -- the compiler's
 * divide-by-zero guard -- firing where it is unreachable.  It was captured twice
 * on 03702fef (2026-09-06, both in `wc', epc 0x40801c, t2=28, a3=10) and BOTH
 * times the ring failed to freeze, because every pre-existing trigger keys on
 * reaching PC 0 / a null restart / a wild EPC, and a break trap does none of
 * those.  Two evidence windows lost.  w_user_break in core.sv closes that hole.
 *
 * Before trusting "the break trigger did not fire", prove it CAN fire.  This
 * executes a plain `break', which commits via t_bump_rob_head with n_cause = 5'd9
 * (core.sv, t_rob_head.is_break) -- the exact condition w_user_break tests.
 *
 * MODE CAVEAT: w_user_break is gated on ~in_kernel_mode, because the kernel's
 * own BUG()/BRK paths use break legitimately.  Bare metal runs in kernel mode, so
 * THIS TEST DOES NOT TRIP THE SHIPPED TRIGGER.  It validates the cause-9 -> commit
 * -> freeze wiring with the mode conjunct temporarily inverted; the conjunct
 * itself is one term on the same in_kernel_mode signal w_kernel_null_fault
 * already uses.  A true end-to-end control needs a user-mode vehicle.
 *
 * PASS (with the gate inverted): rtprobe reports frozen=1.
 * FAIL: frozen=0 -> cause-9 never reaches the freeze logic, and any future
 *       "the break trigger stayed silent" conclusion is void.
 *
 * The progress counter separates "never got there" from "got there, no freeze":
 *   1 = about to execute the break (uncached, so it lands before the trap)
 */
	.set    mips3
	.set    noreorder
	.set    noat
	.section .text.startup, "ax"
	.globl  _start
	.type   _start, @function
_start:
	lui     $s1, 0xa810           /* uncached kseg1 -> PA 0x0810_0000 */
	ori     $s7, $s1, 0x1000      /* progress counter (uncached)      */
	sw      $zero, 0($s7)

	/* Retire a few hundred ordinary instructions first so the ring holds
	 * recognisable context ahead of the event, as it would in the real fault,
	 * and so a frozen ring proves it was recording beforehand. */
	li      $t7, 200
1:	addiu   $t7, $t7, -1
	bne     $t7, $zero, 1b
	nop

	/* Reproduce the operand shape of the captured faults, so the ring rows
	 * ahead of the trap look like the real ones: t2 = 28, a3 = 10. */
	li      $t2, 28
	li      $a3, 10

	li      $t1, 1
	sw      $t1, 0($s7)           /* "about to break" -- uncached, lands now */

	/* the event: the divide-by-zero guard's trap, code 0x7 */
	break   0x7
	nop

	/* not reached; if the core somehow continues, mark it */
	li      $t1, 2
	sw      $t1, 0($s7)
2:	b       2b
	nop
	.size   _start, .-_start
