/*
 * test_tlbr_pfn.S  --  TLBR returns the whole architectural EntryLo (R10000: PFN is
 * EntryLo[33:6]) even though the translating TLBs store only TLB_PA_WIDTH of it
 * (exec.sv ENTRYLO_PFN_WIDTH: the shadow keeps the rest).  IRIX keeps software bits
 * just above the PFN, which reach EntryLo as PA bits 32 and up; the board decodes 32.
 *
 *  1. TLBWI index 5: VA 0x01000000 -> PFN 0x400 | PA[39:38,37:36,34:33] set, C=3 D V G
 *  2. clear EntryLo0/1, TLBR: dmfc0 EntryLo0 must read back every bit written, mfc0
 *     EntryLo0 its sign-extended low word
 *  3. a load through the mapping reaches RAM at PA 0x00400000 (the high bits alias away)
 *
 * Self-contained (own BEV=0 vectors), magic-halt; any exception = FAIL.  R10000 build.
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
    li      $t0, 0x80           /* Status: kernel, KX (64-bit CP0 moves), BEV=0, ERL=0 */
    mtc0    $t0, $12
    nop
    nop
    nop
    mtc0    $zero, $5           /* PageMask = 0 (4 KB pages) */
    mtc0    $zero, $6           /* Wired = 0 */

    li      $t0, 0xa0400000     /* seed the target RAM through kseg1 */
    li      $t1, 0x12345678
    sw      $t1, 0($t0)

    /* ---- 1. TLBWI ---- */
    dli     $t0, 0x01000000     /* EntryHi: VPN2 of VA 0x01000000, ASID 0 */
    dmtc0   $t0, $10
    dli     $s0, 0x3D801001F    /* EntryLo0: PFN 0xF600400 (0x400 + PA[39:38,37:36,34:33]), C=3 D V G */
    dmtc0   $s0, $2
    li      $t0, 0x1            /* EntryLo1: G only */
    dmtc0   $t0, $3
    li      $t0, 5
    mtc0    $t0, $0             /* Index 5 */
    nop
    tlbwi
    nop

    /* ---- 2. clear the staging registers, read the entry back ---- */
    dmtc0   $zero, $2
    dmtc0   $zero, $3
    nop
    tlbr
    nop
    dmfc0   $v0, $2
    bne     $v0, $s0, fail_d
    nop
    mfc0    $v1, $2             /* low word, sign-extended */
    sll     $t2, $s0, 0
    bne     $v1, $t2, fail_w
    nop

    /* ---- 3. translate: the high PFN bits alias away ---- */
    li      $t0, 0x01000000
    lw      $v0, 0($t0)
    li      $t1, 0x12345678
    bne     $v0, $t1, fail_l
    nop

    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT

fail_d:
    FAILHALT 'd'
fail_w:
    FAILHALT 'w'
fail_l:
    FAILHALT 'l'
    .size   _start, . - _start
