/* wirepda_pfn.S -- isolate the FPGA wirepda PFN corruption (PA 0x6828e240).
 *
 * IRIX wirepda builds an EntryLo PFN, round-trips it through dsll32/dsrl32 (a
 * <<32 then >>32), masks it, MTC0's it, then tlbwi's it.  On silicon the wired
 * PFN comes out 0x6828e instead of the intended 0x0828e (extra bits [18:17]);
 * Verilator gets it right.  This replays the sequence in two stages and prints
 * the PFN at each, to localise the corruption WITHOUT the IRIX boot:
 *   stage 1: GPR arithmetic only (shifts/masks/round-trip)   -> "a=" PFN
 *   stage 2: MTC0 EntryLo0 -> tlbwi -> tlbr -> MFC0 read-back -> "t=" PFN
 * Expected PFN = 0x0828e on both.  Trailing 'P' = both == 0x0828e, else 'F'.
 *
 * Console: PUTC polls the CP0 $7 FIFO full flag (bit0) before each push so the
 * 8-deep FIFO doesn't overflow on the FPGA (sim drains every cycle, so it's a
 * no-op there).  Verilator: ../../ooo_core -f wirepda_pfn.elf   FPGA: mips-axi -f wirepda_pfn.elf
 */
#include "sim.h"
    .set mips3
    .set noreorder
    .set noat

/* PUTC \reg : poll CP0 $7 full flag (bit0), then push \reg[7:0]. clobbers $k0. */
    .macro PUTC reg
8:  mfc0  $k0, $7
    andi  $k0, $k0, 1
    bne   $k0, $zero, 8b
    nop
    mtc0  \reg, $7
    .endm
/* PUTL \c : push literal char \c (via $t9). */
    .macro PUTL c
    li    $t9, \c
    PUTC  $t9
    .endm

    .text
    .globl main
    .type  main, @function
main:
    PUTL  0x41                     /* 'A' : reached main */

    /* enter 64-bit mode (KX) so dsll32/dsrl32 don't take a Reserved-Instr trap */
    mfc0  $t0, $12
    ori   $t0, $t0, 0x0080
    mtc0  $t0, $12
    .word 0x000000c0               /* ehb */

    /* ---------- stage 1: wirepda EntryLo arithmetic (GPR only) ---------- */
    lui   $s0, 0x0828
    ori   $s0, $s0, 0xe000         /* PDA paddr 0x0828e000 -> PFN 0x0828e */
    srl   $t4, $s0, 12
    lui   $t5, 0x1
    ori   $t5, $t5, 0xffff         /* 0x1ffff */
    and   $t4, $t4, $t5            /* PFN = (paddr>>12)&0x1ffff */
    dsll  $t4, $t4, 6
    sll   $t4, $t4, 0
    ori   $t3, $t4, 0x1f          /* EntryLo = PFN<<6 | flags */
    dsll32 $t3, $t3, 0            /* round-trip part 1 (wirepda)  */
    dsrl32 $t3, $t3, 0            /* round-trip part 2 (tlbwired) */
    lui   $t7, 0x3ff
    ori   $t7, $t7, 0xffff        /* 0x03ffffff */
    and   $t3, $t3, $t7
    move  $s3, $t3               /* save EntryLo (callee-saved) */
    srl   $t8, $t3, 6
    lui   $t5, 0xff
    ori   $t5, $t5, 0xffff
    and   $s1, $t8, $t5           /* s1 = stage-1 PFN */
    PUTL  0x61                    /* 'a' */
    PUTL  0x3d                    /* '=' */
    move  $a0, $s1
    jal   put_hex32
    nop
    PUTL  0x20                    /* ' ' */

    /* ---------- stage 2: MTC0 EntryLo0 -> tlbwi -> tlbr -> MFC0 ---------- */
    mfc0  $t0, $12               /* leave 64-bit mode (match working tlb-test env) */
    li    $t1, 0xffffff7f
    and   $t0, $t0, $t1
    mtc0  $t0, $12
    li    $t0, 0x00200005
    mtc0  $t0, $10               /* EntryHi: VPN2=0x100, ASID=5 */
    mtc0  $s3, $2               /* EntryLo0 = the wirepda value */
    mtc0  $s3, $3               /* EntryLo1 = same */
    mtc0  $zero, $5            /* PageMask = 0 */
    mtc0  $zero, $0            /* Index = 0 */
    tlbwi
    mtc0  $zero, $10
    mtc0  $zero, $2
    mtc0  $zero, $3
    mtc0  $zero, $0
    tlbr
    mfc0  $t1, $2              /* EntryLo0 read-back */
    srl   $t8, $t1, 6
    lui   $t5, 0xff
    ori   $t5, $t5, 0xffff
    and   $s2, $t8, $t5         /* s2 = TLB-stored PFN */
    PUTL  0x74                  /* 't' */
    PUTL  0x3d                  /* '=' */
    move  $a0, $s2
    jal   put_hex32
    nop
    PUTL  0x20                  /* ' ' */

    /* ---------- verdict ---------- */
    li    $t5, 0x0828e
    bne   $s1, $t5, fail
    nop
    bne   $s2, $t5, fail
    nop
    PUTL  0x50                  /* 'P' */
    break
fail:
    PUTL  0x46                  /* 'F' */
    break

/* put_hex32: print $a0 as 8 lowercase hex digits (polled). clobbers $t0..$t2,$k0. */
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
    addiu $t2, $t2, 0x57         /* 'a'..'f' */
    b     3f
    nop
2:  addiu $t2, $t2, 0x30         /* '0'..'9' */
3:  PUTC  $t2
    addiu $t1, $t1, -4
    addiu $t0, $t0, -1
    bne   $t0, $zero, 1b
    nop
    jr    $ra
    nop
    .size main, .-main
