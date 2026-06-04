/* start_csmith.S  --  bare-metal startup for csmith test programs.
 *
 * Identical to hello/start.s except:
 *  - Uses 'jal main' (sets $ra) instead of 'jr $t0' (leaves $ra = 0).
 *  - After main() returns, executes BREAK so the RTL signals got_break
 *    and the simulator loop exits cleanly.
 *
 * Without this, main() returns to address 0, the CPU executes NOPs until
 * it wraps into the .text section again, and main() is called a second time
 * -- causing repeated checksum output.
 */

    .section .boot.reset, "ax"
    .set noreorder
    .align 2
    .globl _start
_start:
    move $gp, $zero
    la   $k1, reset_init
    jr   $k1
    nop

    .section .boot.exc, "ax"
    .set noreorder
    .globl _exc_handler_stub
$Lexc:
    move $gp, $zero
    la   $k0, exc_handler
    jr   $k0
    nop

    /* ------------------------------------------------------------------ */
    .section .text, "ax"
    .set noreorder
    .globl reset_init
reset_init:
    .set noat
    move $1,  $zero
    move $2,  $zero
    move $3,  $zero
    move $4,  $zero
    move $5,  $zero
    move $6,  $zero
    move $7,  $zero
    move $8,  $zero
    move $9,  $zero
    move $10, $zero
    move $11, $zero
    move $12, $zero
    move $13, $zero
    move $14, $zero
    move $15, $zero
    move $16, $zero
    move $17, $zero
    move $18, $zero
    move $19, $zero
    move $20, $zero
    move $21, $zero
    move $22, $zero
    move $23, $zero
    move $24, $zero
    move $25, $zero
    move $26, $zero
    move $27, $zero
    move $28, $zero
    move $29, $zero
    move $30, $zero
    move $31, $zero
    .set at

    /* Set up stack above BSS: sp = _end + 64KB.
     * A fixed stack address overlaps the data/BSS section for large programs
     * because the data section grows upward while the stack grows downward
     * from the fixed base.  Using _end + a reserve prevents the collision.
     * _end is ALIGN(16)-aligned by the linker, and 0xFFE0 is a multiple of
     * 16, so sp is already 16-byte aligned with no extra masking needed. */
    la   $sp, _end               /* $sp = &_end (= top of BSS) */
    addiu $sp, $sp, 0x7ff0       /* + 32752 */
    addiu $sp, $sp, 0x7ff0       /* + 32752 more  (total +65504 bytes) */
    jal  main                    /* call main; $ra set to the break below */
    nop

    /* main() returned -- terminate simulation cleanly */
    break
    nop

$Lhalt:
    b    $Lhalt
    nop
