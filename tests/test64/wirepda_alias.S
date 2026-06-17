/* wirepda_alias.S -- prove the mode-aware TLB match prevents 64b VPN2 aliasing.
 *
 * Two TLB entries deliberately share the low 19 VPN2 bits (va[31:13]) but differ
 * in the upper VPN2 (va[39:32]):
 *   entry 0 (index 0): VA 0x00000000_0000a000  -> PFN 0x200 (PA 0x200000)
 *   entry 1 (index 1): VA 0x000000ff_0000a000  -> PFN 0x100 (PA 0x100000)
 * Both have va[31:13] = 0xa000>>13 = 5; they differ only in va[39:32] (0x00 vs 0xff),
 * which the old low-19 match ignores -> it would alias them.
 *
 * In 64-bit mode we store via the HIGH VA 0xffffffffffffa240 and read back through
 * BOTH physical aliases.  The OLD low-19 match lights up both entries; find_first_set
 * picks index 0 -> PFN 0x200 -> the data lands at PA 0x200240 (WRONG).  The mode-aware
 * full-VPN2+R match hits only entry 1 -> PFN 0x100 -> PA 0x100240 (CORRECT).
 * PASS prints 'P' iff the data is at the PFN-0x100 alias and NOT the PFN-0x200 alias.
 *
 *   sim:  ../../ooo_core -f wirepda_alias.elf -c 0 --maxicnt 200000
 *   fpga: mips-axi -f wirepda_alias.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat

/* PUTC \reg : poll CP0 $7 full flag (bit0), then push reg[7:0]. clobbers $k0. */
    .macro PUTC reg
9:  mfc0  $k0, $7
    andi  $k0, $k0, 1
    bne   $k0, $zero, 9b
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
    PUTL  0x41                    /* 'A' */

    /* enter 64-bit mode (KX) */
    mfc0  $t0, $12
    ori   $t0, $t0, 0x0080
    mtc0  $t0, $12
    .word 0x000000c0              /* ehb */

    /* CORRECT target at index 0: VA 0x000000ff_0000a000 (va[39:32]=0xff) -> PFN 0x100
     * (PA 0x100000).  Build the 64b EntryHi: 0xa000 | (0xff<<32).
     * NB: find_first_set picks the HIGHEST matching index, so the aliasing decoy
     * must sit at a higher index for the old low-19 match to wrongly win. */
    li    $t6, 0xff
    dsll32 $t6, $t6, 0           /* $t6 = 0x000000ff_00000000 */
    li    $t0, 0xa000
    or    $t0, $t0, $t6          /* $t0 = 0x000000ff_0000a000 */
    mtc0  $t0, $10                /* EntryHi */
    li    $t0, 0x00004017         /* EntryLo0: PFN=0x100, C=2,D=1,V=1,G=1 */
    mtc0  $t0, $2
    li    $t0, 0x00004057         /* EntryLo1: PFN=0x101 */
    mtc0  $t0, $3
    mtc0  $zero, $5              /* PageMask=0 */
    mtc0  $zero, $0             /* Index=0 */
    tlbwi

    /* ALIASING DECOY at index 1: VA 0x00000000_0000a000 (va[39:32]=0, same va[31:13]=5)
     * -> PFN 0x200 (PA 0x200000).  Under the old low-19 match this also matches the
     * high VA and, being the higher index, find_first_set picks it -> wrong PFN. */
    li    $t0, 0x0000a000
    mtc0  $t0, $10
    li    $t0, 0x00008017         /* EntryLo0: PFN=0x200, C=2,D=1,V=1,G=1 */
    mtc0  $t0, $2
    li    $t0, 0x00008057         /* EntryLo1: PFN=0x201 */
    mtc0  $t0, $3
    li    $t0, 1
    mtc0  $t0, $0               /* Index=1 */
    tlbwi

    /* seed both physical pages with a sentinel via uncached kseg1 aliases so a
     * wrong-entry hit is visibly distinguishable from a correct one. */
    li    $t1, 0xa0100240         /* PA 0x100240 (PFN 0x100 = entry 1, correct)  */
    li    $t2, 0xa0200240         /* PA 0x200240 (PFN 0x200 = entry 0, aliased)  */
    li    $t3, 0x11111111
    sw    $t3, 0($t1)
    li    $t3, 0x22222222
    sw    $t3, 0($t2)

    /* the translated store via entry 1's VA 0x000000ff_0000a240 -> select entry 1 -> PA 0x100240.
     * Under the old low-19 match this VA also matches entry 0 (va[31:13]=5) and
     * find_first_set picks index 0 -> PFN 0x200 -> data wrongly lands at PA 0x200240. */
    li    $t6, 0xff
    dsll32 $t6, $t6, 0
    li    $t4, 0xa240
    or    $t4, $t4, $t6          /* $t4 = 0x000000ff_0000a240 */
    li    $t5, 0x0000dead
    sw    $t5, 0($t4)

    /* read back both aliases */
    lw    $s0, 0($t1)             /* PFN 0x100 alias: should be 0xdead (correct) */
    lw    $s1, 0($t2)             /* PFN 0x200 alias: should be UNCHANGED 0x22222222 */

    li    $s2, 0x0000dead
    li    $s3, 0x22222222
    bne   $s0, $s2, fail          /* data must have landed at PFN 0x100 */
    nop
    bne   $s1, $s3, fail          /* PFN 0x200 must be untouched (no alias) */
    nop
    PUTL  0x50                    /* 'P' : correct entry selected, no aliasing */
    break
fail:
    PUTL  0x46                    /* 'F' */
    break
    .size main, .-main
