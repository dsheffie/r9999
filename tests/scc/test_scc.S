/*
 * test_scc.S  --  minimal Z8530/SCC TX model unit test
 *
 * The SGI IP22 IOC2 serial SCC (Z8530) lives at phys 0x1fbd9830 (kseg1
 * 0xbfbd9830).  4 byte-wide registers at 4-byte spacing (ab_dc order):
 *   +0x0 ctrlB  +0x4 dataB  +0x8 ctrlA  +0xc dataA
 * A write to a DATA register transmits the byte to stdout; a read of a CONTROL
 * register returns RR0 with Tx-Buffer-Empty set.
 *
 * This test mimics the du_putchar pattern: poll the control register for
 * Tx-Buffer-Empty (bit2), then write the data register.  Prints "SCC-OK".
 *
 * Run with --arcs (so the MC/HPC/SCC device models are instantiated) and -c 0:
 *   ooo_core --file tests/scc/test_scc.elf --arcs arcs/arcs_fw.bin -c 0
 * Self-contained (own reset entry), halts via the magic-halt register.
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

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00           /* kernel mode, BEV=0 */
    mtc0    $t0, $12
    nop
    nop
    nop

    li      $s0, 0xBFBD9830     /* SCC window base (kseg1, uncached) */
    la      $s1, msg

putloop:
    lbu     $a0, 0($s1)
    beq     $a0, $zero, done
    nop
    /* poll channel-A control reg (offset 0x8) for Tx-Buffer-Empty (bit2) */
1:  lbu     $t1, 0x8($s0)
    andi    $t1, $t1, 0x4
    beq     $t1, $zero, 1b
    nop
    sb      $a0, 0xc($s0)       /* write channel-A data reg -> transmit */
    addiu   $s1, $s1, 1
    b       putloop
    nop

done:
    HALT
    .size   _start, . - _start

    .section .rodata
msg:    .asciz "SCC-OK\n"
