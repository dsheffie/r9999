/* start_csmith_pt.S -- "real page table" csmith variant.
 *
 * Runs with an EMPTY TLB + a software refill handler so the program's data
 * accesses fault in dynamically (Random eviction churns all 48 entries),
 * hammering the TLB refill/eviction path. The VA->PA mapping is a scrambled
 * page permutation set up by pt_setup() (pt_support.c).
 *
 * Vectoring (see baremetal_pt.ld / core.sv): we run BEV=0 so the refill vector
 * is 0x80000000 (BEV=1's would collide with reset@0xbfc00000). KX=0 (32-bit
 * kernel addressing) so useg misses use the regular refill vector, not XTLB.
 */

    /* ---------------- reset entry (kseg1, BEV=1 at reset) ---------------- */
    .section .boot.reset, "ax"
    .set noreorder
    .align 2
    .globl _start
_start:
    move $gp, $zero
    la   $k1, reset_init
    jr   $k1
    nop

    /* ---------------- TLB refill fast path @ 0x80000000 ----------------
     * On a refill the RTL has already set EntryHi.VPN2 = BadVPN2. We index the
     * software page table (kseg0, never faults) by VPN2 and load EntryLo0/1,
     * then TLBWR (Random slot). Entries cover VA 0x400000.. (VPN2 base 0x200),
     * 16 bytes/entry (two 64-bit EntryLo). k0/k1 are kernel scratch. */
    .section .vec.refill, "ax"
    .set noreorder
    .set noat
    .globl _tlb_refill_vec
_tlb_refill_vec:
    dmfc0 $26, $8              /* k0 = BadVAddr */
    dsrl  $26, $26, 13         /* VPN2 = BadVAddr >> 13 */
    addiu $26, $26, -0x200     /* relative index (0x400000>>13 = 0x200) */
    sll   $26, $26, 4          /* * 16 bytes/entry */
    lui   $27, %hi(g_page_table)
    addiu $27, $27, %lo(g_page_table)
    addu  $27, $27, $26
    ld    $26, 0($27)          /* EntryLo0 */
    dmtc0 $26, $2
    ld    $26, 8($27)          /* EntryLo1 */
    dmtc0 $26, $3
    tlbwr
    nop
    nop
    eret
    nop
    .set at

    /* ---------------- general exception vector @ 0x80000180 ----------------
     * break/unaligned/etc.  Saves GPRs to pt_exc_regfile (kseg0), calls
     * exc_handler (baremetal_support.c); v0==1 -> ERET, v0==0 -> halt. */
    .section .boot.exc, "ax"
    .set noreorder
    .set noat
    .globl _exc_handler_stub
_exc_handler_stub:
    lui   $k0, %hi(pt_exc_regfile)
    addiu $k0, $k0, %lo(pt_exc_regfile)
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
    sd    $28, 224($k0)
    sd    $29, 232($k0)
    sd    $30, 240($k0)
    sd    $31, 248($k0)
    lui   $k1, %hi(exc_handler)
    addiu $k1, $k1, %lo(exc_handler)
    move  $a0, $k0
    jalr  $k1
    nop
    beqz  $v0, _exc_halt
    nop
    lui   $k0, %hi(pt_exc_regfile)
    addiu $k0, $k0, %lo(pt_exc_regfile)
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

    /* ---------------- reset_init (kseg0 text) ---------------- */
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

    /* kseg0 stack for pt_setup() (kseg0 = unmapped, never faults) */
    la   $sp, _kstack_top

    /* PageMask = 0 (4 KB pages) */
    mtc0 $zero, $5
    nop

    /* build the scrambled page table + permute physical pages */
    jal  pt_setup
    nop

    /* clean kernel Status: BEV=0, KSU=0 (kernel), KX/SX/UX=0 (32-bit), IE=0,
     * EXL=0, ERL=0.  Now refills vector to 0x80000000 (32-bit, not XTLB). */
    mtc0 $zero, $12
    nop
    nop

    /* mapped stack: SP = _end + 64KB (kuseg 0x400000 range -> refills in) */
    la   $sp, _end
    addiu $sp, $sp, 0x7ff0
    addiu $sp, $sp, 0x7ff0

    jal  main
    nop

    break
    nop
$Lhalt:
    b    $Lhalt
    nop

    /* ---------------- kernel data (kseg0, unmapped, never faults) ----------------
     * The refill handler reads g_page_table here; the general stub saves GPRs to
     * pt_exc_regfile here; pt_setup runs on kstack here -- all before/without the
     * user TLB mapping, so none of it may live in the mapped 0x400000 region. */
    .section .kdata, "aw"
    .align 4
    .globl g_page_table
g_page_table:
    .space 64*16          /* 64 VPN2 entries * (EntryLo0+EntryLo1, 8 bytes each) */
    .align 4
    .globl pt_exc_regfile
pt_exc_regfile:
    .space 256
    .align 4
kstack:
    .space 8192
    .globl _kstack_top
_kstack_top:
    .space 8             /* a slot below the top so the first push has room */
