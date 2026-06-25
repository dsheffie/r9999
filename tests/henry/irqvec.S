/*
 * irqvec.S -- BEV=0 general-exception handler at 0x80000180 for the SCC Tx-IRQ
 * console-throughput measurement (contest.c, method 3).
 *
 * Linked as its own LOAD segment at vaddr 0x80000180 (PA 0x180, backed via the
 * System Memory Alias) by henry_irq.ld; the I-cache is cold there at test start,
 * so no flush is needed.
 *
 * HARDENED for con_full backpressure: Henry's tx_ip is a fixed 512-cycle timer
 * from the accepted DATA write -- it does NOT track the 8-deep SoC console FIFO.
 * Since the IRQ cadence (512 cyc) is faster than mips-axi's drain (~600 cyc), the
 * FIFO fills and con_full asserts mid-burst; a DATA write while con_full is
 * DROPPED (ioc.sv gates accept on ~con_full).  So on each IP2 we WAIT for
 * RR0.bit2 (Tx-Buffer-Empty = ~con_full & ~busy, bounded) before writing, and
 * only bump g_sent on an accepted write -- one IRQ per char, no drop, no
 * miscount, no re-interrupt storm (EXL=1 masks IRQs while we wait in-handler).
 *
 * Uses $at/$t0/$t1/$t2/$t3 (saved/restored to _isave).
 */
    .set    mips3
    .set    noreorder
    .set    noat

    .section .except_vec, "ax"
    .globl  _irqvec
_irqvec:
    la      $k0, _isave
    sw      $at, 0($k0)
    sw      $t0, 4($k0)
    sw      $t1, 8($k0)
    sw      $t2, 12($k0)
    sw      $t3, 16($k0)

    la      $t0, g_sent
    lw      $t1, 0($t0)             /* t1 = sent */
    la      $t2, g_n
    lw      $t2, 0($t2)             /* t2 = N */
    slt     $at, $t1, $t2           /* at = (sent < N) */
    beq     $at, $zero, 1f          /* sent >= N -> finish */
    nop

    /* wait (bounded) for RR0.bit2 so the next DATA write is actually accepted */
    lui     $t0, 0xbfbd
    ori     $t0, $t0, 0x9830        /* SCC_CTRL */
    li      $t3, 0x00100000         /* spin bound */
2:
    lbu     $t2, 0($t0)             /* RR0 (ptr==0) */
    andi    $t2, $t2, 0x04          /* Tx-Buffer-Empty */
    bne     $t2, $zero, 3f          /* ready -> write */
    nop
    addiu   $t3, $t3, -1
    bne     $t3, $zero, 2b          /* keep waiting */
    nop
    b       4f                      /* timed out: eret w/o write (tx_ip stays -> re-IRQ) */
    nop

3:  /* accepted path: write '.' to SCC_DATA (0xbfbd9834), bump g_sent */
    lui     $t0, 0xbfbd
    ori     $t0, $t0, 0x9834
    ori     $t2, $zero, 0x2e        /* '.' */
    sb      $t2, 0($t0)
    la      $t0, g_sent
    lw      $t1, 0($t0)
    addiu   $t1, $t1, 1
    sw      $t1, 0($t0)
    b       4f
    nop

1:  /* done: WR1.TxIE=0, RES_TXP, g_done=1.  SCC_CTRL = 0xbfbd9830 */
    lui     $t0, 0xbfbd
    ori     $t0, $t0, 0x9830
    ori     $t2, $zero, 0x01        /* WR0: point to WR1 */
    sb      $t2, 0($t0)
    sb      $zero, 0($t0)           /* WR1 = 0 (Tx int disable) */
    ori     $t2, $zero, 0x28        /* WR0 = RES_TXP */
    sb      $t2, 0($t0)
    la      $t0, g_done
    ori     $t1, $zero, 1
    sw      $t1, 0($t0)

4:  la      $k0, _isave
    lw      $at, 0($k0)
    lw      $t0, 4($k0)
    lw      $t1, 8($k0)
    lw      $t2, 12($k0)
    lw      $t3, 16($k0)
    eret
    nop

    .section .bss
    .align  2
_isave: .space 20
