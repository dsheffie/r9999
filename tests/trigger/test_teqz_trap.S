/* test_teqz_trap.S -- POSITIVE CONTROL for the TEQZ uop.
 *
 * Steering `teq rX,$zero' to a TEQZ uop removes the $zero operand read.  The
 * danger of that change is the SILENT one: if TEQZ never fires, we have disabled
 * divide-by-zero detection and nothing in a passing test would say so (dhrystone
 * only proves TEQZ does not trap SPURIOUSLY -- its guards never see a zero).
 *
 * So trap on purpose: set the guarded register to 0 and execute the exact
 * construct gcc emits, `teq rX,zero,0x7'.
 *
 * PASS: the core takes a trap (cause 13 = Tr) at the teq.
 * FAIL: execution falls through to the marker -- TEQZ is dead and divide-by-zero
 *       guards are no longer armed.
 */
	.set    mips3
	.set    noreorder
	.set    noat
	.section .text.startup, "ax"
	.globl  _start
	.type   _start, @function
_start:
	lui     $s1, 0xa810
	ori     $s7, $s1, 0x1000      /* uncached progress counter */
	sw      $zero, 0($s7)

	li      $t7, 50
1:	addiu   $t7, $t7, -1
	bne     $t7, $zero, 1b
	nop

	li      $t1, 1
	sw      $t1, 0($s7)           /* about to trap */

	/* the guarded register IS zero -> the guard MUST fire */
	move    $a3, $zero
	teq     $a3, $zero, 0x7

	/* not reached if TEQZ works */
	li      $t1, 2
	sw      $t1, 0($s7)
2:	b       2b
	nop
	.size   _start, .-_start
