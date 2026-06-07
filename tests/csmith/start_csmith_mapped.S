/* start_csmith_mapped.S  --  bare-metal startup for the kuseg-data csmith variant.
 *
 * Identical to start_csmith.S except that 48 TLB entries are installed
 * at the very start of reset_init, before the stack pointer is set up.
 *
 * Why this ordering is safe:
 *   - Register-only instructions before TLB install (no data memory access).
 *   - IE=0 in SR at boot, so no interrupts can fire before TLB is ready.
 *   - TLBWI is oldest_first in the RTL (fully serialises), so each entry is
 *     committed before the next mtc0 sequence begins.
 *   - After TLB install, setting SP = _end + 64KB accesses kuseg, which
 *     now hits the TLB.  Timer IRQ setup (if enabled) also accesses kuseg.
 *
 * TLB map installed:
 *   48 entries, global bit set (G=1 in both lo0/lo1), ASID 0, PageMask=0 (4 KB).
 *   Entry i: VPN2 = (0x400000 + i*8192) >> 13
 *            pfn0  = (0x400000 >> 12) + i*2       = 0x400 + i*2
 *            pfn1  = pfn0 + 1
 *   Covers kuseg VA 0x400000 – 0x45FFFF → PA 0x400000 – 0x45FFFF (1:1).
 *
 * The 1:1 mapping is key: the interpreter's va2pa() returns VA unchanged for
 * bit-31=0 addresses, which equals the TLB-translated PA, so the checker
 * works without any interpreter changes.
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

    /* ------------------------------------------------------------------
     * Install 48 TLB entries: 1:1 kuseg 0x400000-0x45FFFF (384 KB).
     *
     * This must happen before any data memory access (stack, timer
     * variables) because rodata/data/BSS are linked at kuseg 0x400000
     * in the baremetal_mapped.ld linker script.
     *
     * Register allocation (all valid in both O32 and N32 ABI):
     *   $a0 = count (48),  $a1 = index (0..47)
     *   $a2 = VA base (0x400000),  $a3 = EntryLo flags
     *   $v0 = scratch for EntryHi / EntryLo computations
     * ($t4-$t7 do not exist in N32; avoid them here.)
     * ------------------------------------------------------------------ */
    li      $a0, 48             /* number of entries */
    li      $a1, 0              /* loop variable = TLB index */
    li      $a2, 0x400000       /* kuseg VA base */
    li      $a3, 0x1f           /* EntryLo flags: C=3,D=1,V=1,G=1 */
    mtc0    $zero, $5           /* PageMask = 0  (4 KB pages) */
    nop
    nop

1:
    /* EntryHi = base + index * 8192 (two pages per VPN2 entry); ASID=0 */
    sll     $v0, $a1, 13
    addu    $v0, $v0, $a2
    mtc0    $v0, $10

    /* pfn0 = 0x400 + index*2;  EntryLo0 = (pfn0 << 6) | flags */
    sll     $v0, $a1, 1
    addiu   $v0, $v0, 0x400
    sll     $v0, $v0, 6
    or      $v0, $v0, $a3
    mtc0    $v0, $2

    /* pfn1 = pfn0 + 1;  EntryLo1 = (pfn1 << 6) | flags */
    sll     $v0, $a1, 1
    addiu   $v0, $v0, 0x401
    sll     $v0, $v0, 6
    or      $v0, $v0, $a3
    mtc0    $v0, $3

    mtc0    $a1, $0             /* Index = current entry number */
    tlbwi
    nop

    addiu   $a1, $a1, 1
    bne     $a1, $a0, 1b
    nop

    /* Clear EntryHi to avoid leaving a stale ASID after the loop */
    mtc0    $zero, $10
    nop
    nop

    /* ------------------------------------------------------------------
     * Set up stack: SP = _end + 64KB  (all in the TLB-mapped kuseg range)
     * ------------------------------------------------------------------ */
    la   $sp, _end
    addiu $sp, $sp, 0x7ff0
    addiu $sp, $sp, 0x7ff0
#ifdef ENABLE_TIMER_IRQ
    /* Timer data (g_timer_next_compare, g_timer_interval) is in kuseg --
     * TLB is now installed so these stores go through the D-side TLB. */
    li    $t0, 20000
    li    $t1, 10000
    mtc0  $t0, $11
    la    $t2, g_timer_next_compare
    sw    $t0, 0($t2)
    la    $t2, g_timer_interval
    sw    $t1, 0($t2)

    mfc0  $k0, $12
    ori   $k0, $k0, 0x80e1
    li    $k1, -7
    and   $k0, $k0, $k1
    mtc0  $k0, $12
    nop
    nop
#else
    mfc0  $k0, $12
    ori   $k0, $k0, 0xe0
    mtc0  $k0, $12
#endif

    jal  main
    nop

    break
    nop

$Lhalt:
    b    $Lhalt
    nop
