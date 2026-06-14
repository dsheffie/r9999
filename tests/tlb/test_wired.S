/*
 * test_wired.S  --  directed test for WIRED TLB entries.
 *
 * The Wired register reserves TLB slots [0..Wired-1] from random replacement:
 * TLBWR's Random index must stay >= Wired, so wired entries are never
 * overwritten by TLBWR.  This is exactly what IRIX's wirepda relies on (it
 * wires the per-CPU PDA), and the suspected r9999 RTL bug behind the IRIX boot
 * wall (the wirepda return TLB-misses -> utlbmiss spiral).
 *
 * Test: set Wired=2, install two wired entries (slots 0,1) mapping
 *   VA 0x00100000 -> PA 0x300000  and  VA 0x00200000 -> PA 0x310000,
 * seed sentinels at those PAs (via the kseg1 uncached alias), then hammer
 * TLBWR 64x with distinct VPN2s.  If Random honors Wired the two wired entries
 * survive and still translate; if Random dips below Wired a TLBWR clobbers one
 * -> the verify load TLB-misses (-> the refill vector = FAIL) or reads garbage.
 *
 *   wired entries survive -> loads return the sentinels -> "PASS"
 *   clobbered            -> TLB refill vector fires OR wrong data -> "FAIL"
 *
 * Self-contained (own BEV=0 vectors, no crt0), RTL-only (-c 0), magic-halt.
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

    .macro  FAILHALT
    SIMCON_PUTLIT('F')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('I')
    SIMCON_PUTLIT('L')
    SIMCON_PUTLIT('\n')
    HALT
    .endm

/* ================================================================
 * BEV=0 vectors.  Any TLB refill or general exception during the verify
 * loads means a wired entry was clobbered -> FAIL.
 * ================================================================ */
    .section .except_vec, "ax"
    .org    0x000               /* 32-bit TLB refill */
_vec_tlb:
    FAILHALT
    .org    0x080               /* XTLB refill */
    FAILHALT
    .org    0x180               /* general exception */
_vec_gen:
    FAILHALT

/* ================================================================
 * Reset entry
 * ================================================================ */
    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    mtc0    $zero, $12          /* Status=0: BEV=0, kernel, EXL=0, ERL=0 -> kuseg TLB-mapped */
    nop
    nop
    nop
    mtc0    $zero, $5           /* PageMask = 0 (4 KB pages) */

    li      $t0, 2              /* Wired = 2  (slots 0,1 protected) */
    mtc0    $t0, $6

    /* ---- wired entry 0 (slot 0): VA 0x00100000 -> PA 0x300000 ---- */
    li      $t0, 0x00100000     /* EntryHi: VPN2 for 0x100000, ASID=0 */
    mtc0    $t0, $10
    li      $t0, 0x0000c01f     /* EntryLo0: PFN=0x300, C=3,D=1,V=1,G=1 */
    mtc0    $t0, $2
    li      $t0, 0x0000c05f     /* EntryLo1: PFN=0x301 */
    mtc0    $t0, $3
    mtc0    $zero, $0           /* Index = 0 */
    tlbwi

    /* ---- wired entry 1 (slot 1): VA 0x00200000 -> PA 0x310000 ---- */
    li      $t0, 0x00200000
    mtc0    $t0, $10
    li      $t0, 0x0000c41f     /* PFN=0x310 */
    mtc0    $t0, $2
    li      $t0, 0x0000c45f     /* PFN=0x311 */
    mtc0    $t0, $3
    li      $t0, 1
    mtc0    $t0, $0             /* Index = 1 */
    tlbwi

    /* ---- seed sentinels at the two PAs via the kseg1 uncached alias ---- */
    li      $t0, 0xa0300000
    li      $t1, 0xaaaa1111
    sw      $t1, 0($t0)
    li      $t0, 0xa0310000
    li      $t1, 0xbbbb2222
    sw      $t1, 0($t0)

    /* ---- hammer TLBWR 64x with distinct VPN2s (must hit only slots [2..47]) ---- */
    li      $t2, 0              /* i */
    li      $t3, 64
hammer:
    sll     $t4, $t2, 13        /* i * 0x2000  (one VPN2 = 8 KB) */
    lui     $t5, 0x0040         /* 0x00400000 */
    addu    $t4, $t4, $t5
    mtc0    $t4, $10            /* EntryHi: VPN2 = 0x400000 + i*0x2000 */
    li      $t0, 0x0000801f     /* EntryLo0: PFN=0x200, V=1, G=1 */
    mtc0    $t0, $2
    li      $t0, 0x0000805f     /* EntryLo1 */
    mtc0    $t0, $3
    tlbwr
    addiu   $t2, $t2, 1
    bne     $t2, $t3, hammer
    nop

    /* ---- verify both wired entries survived (a miss -> refill vector = FAIL) ---- */
    li      $t0, 0x00100000
    lw      $v0, 0($t0)         /* -> PA 0x300000 */
    li      $t1, 0xaaaa1111
    bne     $v0, $t1, fail
    nop
    li      $t0, 0x00200000
    lw      $v0, 0($t0)         /* -> PA 0x310000 */
    li      $t1, 0xbbbb2222
    bne     $v0, $t1, fail
    nop

    /* ---- both wired entries intact ---- */
    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT

fail:
    FAILHALT
    .size   _start, . - _start
