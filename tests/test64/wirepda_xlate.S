/* wirepda_xlate.S -- exercise the TLB *lookup* (CAM match + PFN mux) for a high
 * VA, the part wirepda_pfn.S did NOT cover (that one round-trips by index via
 * tlbr; this one does a real translated memory access).
 *
 * Map ckseg3 VA 0xffffffffffffa000 -> PFN 0x100 (PA 0x100000, in range), in
 * 64-bit mode (KX), then STORE 0xdead to 0x...a240 (the actual CAM lookup ->
 * PFN -> PA) and read it back through the uncached physical alias kseg1
 * 0xa0100240.  If the lookup yields PFN 0x100 the readback sees 0xdead -> 'P'.
 * If the FPGA lookup corrupts the PFN (the IRIX 0x6828e bug), the store goes to
 * an out-of-range PA -> AXI hang (no 'P' within the timeout) = bug reproduced;
 * an in-range wrong PA -> 'F'.  Verilator: ../../ooo_core -f wirepda_xlate.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat

    .macro PUTC reg
8:  mfc0  $k0, $7
    andi  $k0, $k0, 1
    bne   $k0, $zero, 8b
    nop
    mtc0  \reg, $7
    .endm
    .macro PUTL c
    li    $t9, \c
    PUTC  $t9
    .endm

    .text
    .globl main
    .type  main, @function
main:
    PUTL  0x41                   /* 'A' */

    /* enter 64-bit mode (KX) so the ckseg3 high VA is usable */
    mfc0  $t0, $12
    ori   $t0, $t0, 0x0080
    mtc0  $t0, $12
    .word 0x000000c0             /* ehb */

    /* map VA 0xffffffffffffa000 -> PFN 0x100 (PA 0x100000), uncached */
    li    $t0, 0xffffa000        /* EntryHi page base (sign-extends in GPR) */
    mtc0  $t0, $10
    li    $t0, 0x00004017        /* EntryLo0: PFN=0x100, C=2(uncached), D=1,V=1,G=1 */
    mtc0  $t0, $2
    li    $t0, 0x00004057        /* EntryLo1: PFN=0x101, C=2, D=1,V=1,G=1 */
    mtc0  $t0, $3
    mtc0  $zero, $5             /* PageMask = 0 */
    mtc0  $zero, $0             /* Index = 0 */
    tlbwi

    /* the real translated store: VA 0x...a240 -> (CAM lookup) -> PFN 0x100 -> PA 0x100240 */
    li    $t1, 0xffffa240        /* -> 0xffffffffffffa240 */
    li    $t2, 0x0000dead
    sw    $t2, 0($t1)

    /* read back via uncached physical alias kseg1 0xa0100240 (PA 0x100240) */
    li    $t3, 0xa0100240
    lw    $t4, 0($t3)

    move  $s4, $t4             /* save readback + magic (put_hex32 clobbers t-regs) */
    move  $s5, $t2
    li    $t9, 0x78             /* 'x' */
    PUTC  $t9
    li    $t9, 0x3d             /* '=' */
    PUTC  $t9
    move  $a0, $s4
    jal   put_hex32             /* print what the alias actually read */
    nop
    li    $t9, 0x20
    PUTC  $t9

    bne   $s4, $s5, fail
    nop
    PUTL  0x50                  /* 'P' : lookup PFN correct */
    break
fail:
    PUTL  0x46                  /* 'F' */
    break

    .globl put_hex32
    .type  put_hex32, @function
put_hex32:
    li    $t0, 8
    li    $t1, 28
1:  srlv  $t2, $a0, $t1
    andi  $t2, $t2, 0xf
    sltiu $k1, $t2, 10
    bne   $k1, $zero, 2f
    nop
    addiu $t2, $t2, 0x57
    b     3f
    nop
2:  addiu $t2, $t2, 0x30
3:  PUTC  $t2
    addiu $t1, $t1, -4
    addiu $t0, $t0, -1
    bne   $t0, $zero, 1b
    nop
    jr    $ra
    nop
    .size main, .-main
