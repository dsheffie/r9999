/* test_ixlate.S -- does the I-side (micro-)TLB actually TRANSLATE code fetch?
 * Maps VA 0x00100000 -> PA 0x300000 (PFN 0x300), writes a small routine into
 * PA 0x300000 via the kseg1 alias, then JUMPS to the kuseg VA so instruction
 * fetch goes through the ITLB (micro-TLB always-miss -> JTLB WAIT_FOR_TLB).
 * The routine sets $v0 = 0x12345678 and returns ($ra, kseg0); we self-check.
 *   PASS = ITLB fetched the translated PA; FAIL = wrong/garbage fetch. */
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
    .section .text.startup, "ax"
    .globl  _start
_start:
    /* --- program the TLB: VA 0x100000 (even page) -> PA 0x300000 --- */
    mtc0    $zero, $5           /* PageMask = 0 (4KB) */
    li      $t0, 0x00100000     /* EntryHi: VPN2 0x100000, ASID=0 */
    mtc0    $t0, $10
    li      $t0, 0x0000c01f     /* EntryLo0: PFN=0x300, C=3,D=1,V=1,G=1 */
    mtc0    $t0, $2
    li      $t0, 0x0000c05f     /* EntryLo1: PFN=0x301, C=3,D=1,V=1,G=1 */
    mtc0    $t0, $3
    mtc0    $zero, $0           /* Index = 0 */
    tlbwi
    nop
    nop
    /* --- write the mapped routine to PA 0x300000 via kseg1 (uncached) --- */
    li      $t0, 0xa0300000
    li      $t1, 0x3c021234     /* lui  $v0, 0x1234           */
    sw      $t1, 0($t0)
    li      $t1, 0x34425678     /* ori  $v0, $v0, 0x5678      */
    sw      $t1, 4($t0)
    li      $t1, 0x03e00008     /* jr   $ra                   */
    sw      $t1, 8($t0)
    sw      $zero, 12($t0)      /* nop  (jr delay slot)       */
    nop
    nop
    /* --- call into the mapped page (I-fetch through the ITLB) --- */
    la      $ra, back
    li      $t0, 0x00100000
    jr      $t0
    nop
back:
    li      $t1, 0x12345678
    bne     $v0, $t1, fail
    nop
    SIMCON_PUTLIT('P'); SIMCON_PUTLIT('A'); SIMCON_PUTLIT('S'); SIMCON_PUTLIT('S'); SIMCON_PUTLIT('\n')
    HALT
fail:
    SIMCON_PUTLIT('F'); SIMCON_PUTLIT('A'); SIMCON_PUTLIT('I'); SIMCON_PUTLIT('L'); SIMCON_PUTLIT('\n')
    HALT
    .size   _start, . - _start
