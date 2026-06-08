/* start_csmith_mapped64_insn.S -- .text in kuseg via I-TLB, 64-bit TLB format.
 *
 * Identical to start_csmith_mapped_insn.S except the EntryHi/EntryLo writes
 * that install each TLB entry use dmtc0 (64-bit CP0 access) instead of mtc0,
 * exercising the 64-bit TLB register format (EntryHi region[63:62]+VPN2[39:13],
 * EntryLo PFN[33:6]).  All install values are < 2^32, so the resulting entries
 * are bit-identical to the 32-bit mtc0 path and the 1:1 checker trick holds.
 *
 * The .boot.reset section (kseg1, 0xBFC00000) installs 48 TLB entries covering
 * the instruction fetch range 0x200000-0x25FFFF (1:1 VA→PA) before jumping
 * into kuseg text.  Data, BSS, and stack remain in kseg0 (unmapped), so only
 * the I-side TLB is exercised by this configuration.
 *
 * Why the TLB setup must be in .boot.reset (not .text):
 *   The CPU must fetch instructions through the I-TLB once it enters kuseg.
 *   Installing the TLB entries while still in kseg1 (unmapped/uncached) avoids
 *   the chicken-and-egg problem where the first kuseg fetch would miss the TLB.
 *
 * TLB map (installed before any kuseg fetch):
 *   48 entries, G=1, ASID=0, PageMask=0 (4 KB pages).
 *   Entry i: VPN2 = 0x100 + i, pfn0 = 0x200 + i*2, pfn1 = 0x201 + i*2
 *   Covers kuseg VA 0x200000-0x25FFFF → PA 0x200000-0x25FFFF (1:1).
 *
 * 1:1 mapping: va2pa() in the interpreter returns VA unchanged for
 * bit-31=0 addresses, so the checker requires no modification.
 *
 * Register allocation in boot stub (N32-safe; avoid $t4-$t7):
 *   $a0=$a3,$v0 used for TLB loop; $k0,$k1 for jumps.
 */

    .section .boot.reset, "ax"
    .set noreorder
    .align 2
    .globl _start
_start:
    move $gp, $zero

    /* Install 48 TLB entries for kuseg text (0x200000-0x25FFFF) while still
     * in kseg1.  TLBWI is oldest_first in the RTL, so each entry commits
     * before the next mtc0 sequence begins.                               */
    li      $a0, 48             /* entry count */
    li      $a1, 0              /* loop index  */
    lui     $a2, 0x20           /* VA base = 0x00200000 */
    li      $a3, 0x1f           /* EntryLo flags: C=3, D=1, V=1, G=1 */
    mtc0    $zero, $5           /* PageMask = 0 → 4 KB pages */
    nop
    nop

1:
    sll     $v0, $a1, 13        /* VPN2 offset = index * 8192 */
    addu    $v0, $v0, $a2       /* EntryHi = VA_base + VPN2_offset, ASID=0 */
    dmtc0   $v0, $10            /* 64-bit EntryHi: region=$v0[63:62], VPN2=$v0[39:13] */

    sll     $v0, $a1, 1
    addiu   $v0, $v0, 0x200     /* pfn0 = 0x200 + index*2 */
    sll     $v0, $v0, 6
    or      $v0, $v0, $a3
    dmtc0   $v0, $2             /* 64-bit EntryLo0: PFN=$v0[33:6] */

    sll     $v0, $a1, 1
    addiu   $v0, $v0, 0x201     /* pfn1 = 0x201 + index*2 */
    sll     $v0, $v0, 6
    or      $v0, $v0, $a3
    dmtc0   $v0, $3             /* 64-bit EntryLo1: PFN=$v0[33:6] */

    mtc0    $a1, $0             /* Index = current entry */
    tlbwi
    nop

    addiu   $a1, $a1, 1
    bne     $a1, $a0, 1b
    nop

    mtc0    $zero, $10          /* clear stale EntryHi ASID */
    nop
    nop

    /* I-TLB now covers 0x200000-0x25FFFF; jump into kuseg .text. */
    la      $k1, reset_init
    jr      $k1
    nop

    /* ------------------------------------------------------------------ *
     * .boot.exc @ 0xBFC00180 -- general exception vector.                *
     * Identical to start_csmith.S.                                        *
     * ------------------------------------------------------------------ */
    .section .boot.exc, "ax"
    .set noreorder
    .set noat
    .globl _exc_handler_stub
_exc_handler_stub:
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
    /* exc_handler is in kuseg .text; use jalr for any-address call */
    lui   $k1, %hi(exc_handler)
    addiu $k1, $k1, %lo(exc_handler)
    move  $a0, $k0
    jalr  $k1
    nop
    beqz  $v0, _exc_halt
    nop
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

    /* Stack in kseg0 (_end is in the kseg0 data section). */
    la    $sp, _end
    addiu $sp, $sp, 0x7ff0
    addiu $sp, $sp, 0x7ff0
#ifdef ENABLE_TIMER_IRQ
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

    jal   main
    nop

    break
    nop

$Lhalt:
    b     $Lhalt
    nop
