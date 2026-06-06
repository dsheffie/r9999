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
    .set noat
    .globl _exc_handler_stub
_exc_handler_stub:
    /* k0 = &exc_regfile[0]; save all GPRs except $0, $k0, $k1 (kernel scratch) */
    lui   $k0, %hi(exc_regfile)
    addiu $k0, $k0, %lo(exc_regfile)
    sd    $1,   8($k0)
    sd    $2,  16($k0)
    sd    $3,  24($k0)
    sd    $4,  32($k0)
    sd    $5,  40($k0)
    sd    $6,  48($k0)
    sd    $7,  56($k0)
    sd    $8,  64($k0)
    sd    $9,  72($k0)
    sd    $10, 80($k0)
    sd    $11, 88($k0)
    sd    $12, 96($k0)
    sd    $13, 104($k0)
    sd    $14, 112($k0)
    sd    $15, 120($k0)
    sd    $16, 128($k0)
    sd    $17, 136($k0)
    sd    $18, 144($k0)
    sd    $19, 152($k0)
    sd    $20, 160($k0)
    sd    $21, 168($k0)
    sd    $22, 176($k0)
    sd    $23, 184($k0)
    sd    $24, 192($k0)
    sd    $25, 200($k0)
    /* $26/$27 are k0/k1 -- skip */
    sd    $28, 224($k0)
    sd    $29, 232($k0)
    sd    $30, 240($k0)
    sd    $31, 248($k0)
    /* jal can't reach .text from bfc00180 (top nibbles differ); use jalr */
    lui   $k1, %hi(exc_handler)
    addiu $k1, $k1, %lo(exc_handler)
    move  $a0, $k0
    jalr  $k1
    nop
    /* v0==1 -> ERET; v0==0 -> exc_handler already wrote halt sentinel */
    beqz  $v0, _exc_halt
    nop
    /* restore all saved GPRs */
    lui   $k0, %hi(exc_regfile)
    addiu $k0, $k0, %lo(exc_regfile)
    ld    $1,   8($k0)
    ld    $2,  16($k0)
    ld    $3,  24($k0)
    ld    $4,  32($k0)
    ld    $5,  40($k0)
    ld    $6,  48($k0)
    ld    $7,  56($k0)
    ld    $8,  64($k0)
    ld    $9,  72($k0)
    ld    $10, 80($k0)
    ld    $11, 88($k0)
    ld    $12, 96($k0)
    ld    $13, 104($k0)
    ld    $14, 112($k0)
    ld    $15, 120($k0)
    ld    $16, 128($k0)
    ld    $17, 136($k0)
    ld    $18, 144($k0)
    ld    $19, 152($k0)
    ld    $20, 160($k0)
    ld    $21, 168($k0)
    ld    $22, 176($k0)
    ld    $23, 184($k0)
    ld    $24, 192($k0)
    ld    $25, 200($k0)
    ld    $28, 224($k0)
    ld    $29, 232($k0)
    ld    $30, 240($k0)
    ld    $31, 248($k0)
    eret
    nop
_exc_halt:
    b     _exc_halt
    nop
    .set at

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
#ifdef ENABLE_TIMER_IRQ
    /* Arm timer: first IRQ at cycle 20000, rearm every 10000 cycles.
     * Use a fixed initial Compare rather than reading Count (mfc0 $9 in an
     * OOO pipeline captures Count at issue time; the checker compares at
     * retire time, so they diverge by however many cycles are in flight). */
    li    $t0, 20000            /* first Compare value */
    li    $t1, 10000            /* rearm interval */
    mtc0  $t0, $11              /* write Compare */
    la    $t2, g_timer_next_compare
    sw    $t0, 0($t2)
    la    $t2, g_timer_interval
    sw    $t1, 0($t2)

    /* SR: IM7 (bit 15) + KX/SX/UX (bits 7:5) + IE (bit 0); clear EXL/ERL (bits 2:1). */
    mfc0  $k0, $12
    ori   $k0, $k0, 0x80e1
    li    $k1, -7               /* ~(ERL|EXL) */
    and   $k0, $k0, $k1
    mtc0  $k0, $12
    nop
    nop
#else
    /* SR: KX/SX/UX only; interrupts remain disabled. */
    mfc0  $k0, $12
    ori   $k0, $k0, 0xe0
    mtc0  $k0, $12
#endif

    jal  main                    /* call main; $ra set to the break below */
    nop

    /* main() returned -- terminate simulation cleanly */
    break
    nop

$Lhalt:
    b    $Lhalt
    nop
