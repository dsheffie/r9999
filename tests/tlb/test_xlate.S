/* test_xlate.S -- does the D-side TLB actually TRANSLATE (non-identity)?
 * Maps VA 0x00100000 -> PA 0x300000 (PFN 0x300), seeds PA 0x300000 via the
 * kseg1 alias, loads via the kuseg VA, expects the sentinel.
 *   PASS = TLB translated the PFN; FAIL = returned the VA (1:1). */
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
    mtc0    $zero, $5           /* PageMask = 0 */
    li      $t0, 0x00100007     /* EntryHi: VPN2 0x100000, ASID=7 */
    mtc0    $t0, $10
    li      $t0, 0x0000c01e     /* EntryLo0: PFN=0x300, C=3,D=1,V=1,G=0 */
    mtc0    $t0, $2
    li      $t0, 0x0000c05e     /* EntryLo1: PFN=0x301 */
    mtc0    $t0, $3
    mtc0    $zero, $0           /* Index = 0 */
    tlbwi
    nop
    nop
    li      $t0, 0xa0300000     /* seed PA 0x300000 via kseg1 */
    li      $t1, 0xaaaa1111
    sw      $t1, 0($t0)
    li      $t0, 0x00100000     /* load via the kuseg VA -> TLB -> PA 0x300000? */
    lw      $v0, 0($t0)
    li      $t1, 0xaaaa1111
    bne     $v0, $t1, fail
    nop
    SIMCON_PUTLIT('P'); SIMCON_PUTLIT('A'); SIMCON_PUTLIT('S'); SIMCON_PUTLIT('S'); SIMCON_PUTLIT('\n')
    HALT
fail:
    SIMCON_PUTLIT('F'); SIMCON_PUTLIT('A'); SIMCON_PUTLIT('I'); SIMCON_PUTLIT('L'); SIMCON_PUTLIT('\n')
    HALT
    .size   _start, . - _start
