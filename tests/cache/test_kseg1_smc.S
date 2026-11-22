/*
 * test_kseg1_smc.S -- code written and run UNCACHED (kseg1) needs no CACHE op:
 * uncached is uncached.  Run tgt through its kseg1 alias, byte-copy a different
 * tgt over it through kseg1 (as NetBSD/sparc's bootxx memcpy's /boot over
 * itself), spin, then run it through kseg1 again.  The L1I must not keep an
 * uncached fill (l1i.sv NC_TURNAROUND): the L2 holds no uncached line, so
 * nothing would ever drop it, and the second call would run the stale tgt.
 *
 * Expected: $s0 = 1 (first call), $s1 = 2 (second); the co-sim checker
 * (ooo_core -c 1) flags a stale fetch as a register mismatch.
 *   mips-linux-gnu-gcc -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -G 0 \
 *     -nostdlib -nostartfiles -I../common -c test_kseg1_smc.S -o test_kseg1_smc.o
 *   mips-linux-gnu-ld -T ../common/link.ld -nostdlib -G 0 -static \
 *     ../common/crt0.o test_kseg1_smc.o -o test_kseg1_smc.elf
 *   ../../ooo_core -f test_kseg1_smc.elf -c 1
 */
    .set    mips3
    .set    noreorder
    .set    noat

#define DELAY 100000
#define TLEN  16

    .text
    .globl  main
    .type   main, @function
main:
    addiu   $sp, $sp, -16
    sw      $ra, 0($sp)
    la      $t9, tgt
    li      $t8, 0x20000000
    addu    $t9, $t9, $t8           /* tgt's kseg1 alias */
    jalr    $t9                     /* $v0 = 1 */
    nop
    move    $s0, $v0
    /* bootxx's memcpy: one byte at a time, through kseg1 */
    la      $t0, src
    addu    $t0, $t0, $t8
    move    $t1, $t9
    li      $t2, TLEN
1:  lbu     $t3, 0($t0)
    sb      $t3, 0($t1)
    addiu   $t0, $t0, 1
    addiu   $t2, $t2, -1
    bnez    $t2, 1b
    addiu   $t1, $t1, 1
    li      $t2, DELAY
2:  addiu   $t2, $t2, -1
    bnez    $t2, 2b
    nop
    jalr    $t9                     /* $v0 = 2 */
    nop
    move    $s1, $v0
    lw      $ra, 0($sp)
    addiu   $sp, $sp, 16
    jr      $ra
    move    $v0, $zero

    .align  6
tgt:
    jr      $ra
    li      $v0, 1
    nop
    nop

    .align  4
src:
    jr      $ra
    li      $v0, 2
    nop
    nop
