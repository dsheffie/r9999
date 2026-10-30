/*
 * test_tlb64.S  --  directed test for a 64-entry JTLB (machine.vh N_TLB_ENTRIES 64).
 *
 *  1. TLBWI a distinct VPN2 into every index 0..63.
 *  2. TLBP each VPN2: Index must come back == i with P clear (the CAM really
 *     has 64 live entries, the top 16 included).
 *  3. TLBR index 63: EntryHi reads back its VPN2.
 *  4. Load through the mappings in entries 48 and 63 (sentinel seeded via kseg1).
 *  5. Wired=0, then sample Random 4096x: every value 0..63 must appear
 *     (Random wraps to 63, not 47).
 *
 * Self-contained (own BEV=0 vectors, no crt0), magic-halt.  Any exception = FAIL.
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

    .macro  FAILHALT c
    SIMCON_PUTLIT('F')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('I')
    SIMCON_PUTLIT('L')
    SIMCON_PUTLIT(\c)
    SIMCON_PUTLIT('\n')
    HALT
    .endm

    .section .except_vec, "ax"
    .org    0x000               /* 32-bit TLB refill */
    FAILHALT 'r'
    .org    0x080               /* XTLB refill */
    FAILHALT 'x'
    .org    0x180               /* general exception */
    FAILHALT 'g'

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    mtc0    $zero, $12          /* Status=0: kernel, BEV=0, ERL=0 -> kuseg mapped */
    nop
    nop
    nop
    mtc0    $zero, $5           /* PageMask = 0 (4 KB pages) */
    mtc0    $zero, $6           /* Wired = 0 */

    /* ---- 1. TLBWI every index: VA 0x01000000+i*0x2000 -> PA 0x00400000+i*0x2000 ---- */
    li      $t2, 0              /* i */
    li      $t3, 64
fill:
    sll     $t4, $t2, 13
    lui     $t5, 0x0100
    addu    $t5, $t5, $t4
    mtc0    $t5, $10            /* EntryHi: VPN2, ASID 0 */
    srl     $t6, $t4, 12        /* 2*i */
    addiu   $t6, $t6, 0x400     /* PFN even = 0x400 + 2i */
    sll     $t6, $t6, 6
    ori     $t0, $t6, 0x1f      /* C=3 D V G */
    mtc0    $t0, $2
    addiu   $t0, $t0, 0x40      /* PFN odd */
    mtc0    $t0, $3
    mtc0    $t2, $0             /* Index = i */
    nop
    tlbwi
    addiu   $t2, $t2, 1
    bne     $t2, $t3, fill
    nop

    /* ---- 2. TLBP each VPN2: Index == i, P == 0 ---- */
    li      $t2, 0
probe:
    sll     $t4, $t2, 13
    lui     $t5, 0x0100
    addu    $t5, $t5, $t4
    mtc0    $t5, $10
    nop
    tlbp
    nop
    nop
    mfc0    $t0, $0
    nop
    bne     $t0, $t2, fail_p
    nop
    addiu   $t2, $t2, 1
    bne     $t2, $t3, probe
    nop

    /* ---- 3. TLBR index 63: EntryHi = VPN2 of 0x01000000 + 63*0x2000 ---- */
    li      $t0, 63
    mtc0    $t0, $0
    nop
    tlbr
    nop
    nop
    mfc0    $t0, $10
    li      $t1, 0x0107e000
    bne     $t0, $t1, fail_r
    nop

    /* ---- 4. loads through entries 48 and 63 ---- */
    li      $t0, 0xa0460000     /* PA of entry 48 (0x400000 + 48*0x2000), kseg1 */
    li      $t1, 0x48484848
    sw      $t1, 0($t0)
    li      $t0, 0xa047e000     /* PA of entry 63 */
    li      $t1, 0x63636363
    sw      $t1, 0($t0)
    li      $t0, 0x01060000     /* VA of entry 48 */
    lw      $v0, 0($t0)
    li      $t1, 0x48484848
    bne     $v0, $t1, fail_l
    nop
    li      $t0, 0x0107e000     /* VA of entry 63 */
    lw      $v0, 0($t0)
    li      $t1, 0x63636363
    bne     $v0, $t1, fail_l
    nop

    /* ---- 5. Random coverage: all of 0..63 seen ---- */
    mtc0    $zero, $6           /* Wired = 0 (also resets Random to the top) */
    li      $t6, 0              /* seen mask, Random 0..31 */
    li      $t7, 0              /* seen mask, Random 32..63 */
    li      $t2, 4096
    li      $s0, 1
rnd:
    mfc0    $t0, $1
    andi    $t1, $t0, 0x20
    sllv    $t4, $s0, $t0       /* 1 << (Random & 31) */
    bnez    $t1, rnd_hi
    nop
    b       rnd_next
    or      $t6, $t6, $t4
rnd_hi:
    or      $t7, $t7, $t4
rnd_next:
    srl     $t1, $t0, 6         /* Random must fit in 6 bits */
    bnez    $t1, fail_n
    nop
    addiu   $t2, $t2, -1
    bnez    $t2, rnd
    nop
    li      $t1, -1
    bne     $t6, $t1, fail_n
    nop
    bne     $t7, $t1, fail_n
    nop

    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT

fail_p:
    FAILHALT 'p'
fail_r:
    FAILHALT 'R'
fail_l:
    FAILHALT 'l'
fail_n:
    FAILHALT 'n'
    .size   _start, . - _start
