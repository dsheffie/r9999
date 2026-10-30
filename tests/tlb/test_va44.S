/*
 * test_va44.S  --  ENABLE_R10000: 44-bit virtual addresses (SEGBITS 44).
 *
 * The IP28 IRIX kernel puts its K2 heap at xkseg addresses with VA[43:40] set
 * (0xc0000fc0...).  With SEGBITS 44 those must translate, the TLB must match all
 * 31 VPN2 bits (two pages differing only in VA[43:40] do not alias), and a refill
 * must report the R10000 XContext layout: PTEBase[63:37], R[36:35], BadVPN2[34:4].
 *
 *   1. tlbwi two global 4K pages: 0xc000000030000000 -> buf0, 0xc0000fc030000000 ->
 *      buf1.  Load both; each must return its own page's word.
 *   2. Load from unmapped 0xc0000fc040002000: XTLB refill.  The handler checks
 *      XContext (PTEBase written as 0xfffffff000000000 keeps bits 63:37),
 *      BadVAddr and EntryHi.
 * Prints PASS, or FAIL<n>.  Needs an ooo_core built with ENABLE_R10000: on an
 * R4400 (SEGBITS 40) the second page is an Address Error.  Self-contained like
 * test_xtlb.S (own vectors at the BEV=0 offsets, magic-halt).
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

    .macro  FAIL n
    SIMCON_PUTLIT('F')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('I')
    SIMCON_PUTLIT('L')
    SIMCON_PUTLIT(\n)
    SIMCON_PUTLIT('\n')
    HALT
    .endm

    .section .except_vec, "ax"
    .org    0x000               /* 32-bit TLB refill: wrong vector */
    FAIL    '1'
    .org    0x080               /* 64-bit XTLB refill: check the fault state */
    j       xtlb_check
    nop
    .org    0x180               /* general exception (e.g. an Address Error) */
    FAIL    '5'

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x80           /* Status: KX=1, kernel, EXL=ERL=BEV=0 */
    mtc0    $t0, $12
    nop
    nop
    nop
    mtc0    $zero, $5           /* PageMask: 4K */
    mtc0    $zero, $6           /* Wired */
    dli     $t0, 0xfffffff000000000
    dmtc0   $t0, $20            /* XContext PTEBase (bits below 37 must not survive) */
    /* the two words, through kseg0 */
    la      $a0, buf0
    li      $t1, 0x1111
    sw      $t1, 0($a0)
    la      $a1, buf1
    li      $t1, 0x2222
    sw      $t1, 0($a1)
    /* EntryLo0 = PFN(pa) | C=3 (cacheable noncoherent) | D | V | G; EntryLo1 = G only */
    li      $t2, 0x1fffffff
    and     $t3, $a0, $t2
    srl     $t3, $t3, 12
    sll     $t3, $t3, 6
    ori     $t3, $t3, 0x1f
    dmtc0   $t3, $2
    li      $t4, 1
    dmtc0   $t4, $3
    dli     $t5, 0xc000000030000000
    dmtc0   $t5, $10
    mtc0    $zero, $0           /* Index 0 */
    nop
    tlbwi
    nop
    and     $t3, $a1, $t2
    srl     $t3, $t3, 12
    sll     $t3, $t3, 6
    ori     $t3, $t3, 0x1f
    dmtc0   $t3, $2
    dmtc0   $t4, $3
    dli     $t6, 0xc0000fc030000000
    dmtc0   $t6, $10
    li      $t7, 1
    mtc0    $t7, $0             /* Index 1 */
    nop
    tlbwi
    nop
    mtc0    $zero, $10          /* EntryHi ASID 0 for the accesses */
    nop
    /* 1. the two pages must not alias */
    lw      $s0, 0($t5)
    li      $t1, 0x1111
    bne     $s0, $t1, 8f
    nop
    lw      $s1, 0($t6)
    li      $t1, 0x2222
    bne     $s1, $t1, 9f
    nop
    /* 2. a refill on an unmapped page with VA[43:40] set */
    dli     $t0, 0xc0000fc040002000
    lw      $t1, 0($t0)
    FAIL    '6'                 /* should not get here */
8:  FAIL    '7'
9:  FAIL    '8'
    .size   _start, . - _start

xtlb_check:
    dmfc0   $k0, $20            /* XContext */
    dli     $k1, 0xffffffffe0200010
    bne     $k0, $k1, 2f
    nop
    dmfc0   $k0, $8             /* BadVAddr */
    dli     $k1, 0xc0000fc040002000
    bne     $k0, $k1, 3f
    nop
    dmfc0   $k0, $10            /* EntryHi: R | VPN2 | ASID 0 */
    dli     $k1, 0xc0000fc040002000
    bne     $k0, $k1, 4f
    nop
    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT
2:  FAIL    '2'
3:  FAIL    '3'
4:  FAIL    '4'

    .data
    .align  12
buf0:
    .word   0
    .align  12
buf1:
    .word   0
