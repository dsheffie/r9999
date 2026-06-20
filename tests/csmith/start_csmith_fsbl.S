/* start_csmith_fsbl.S -- kseg0 crt0 for csmith tests booted via the henry_arcs FSBL.
 *
 * Replaces start_csmith_mapped.S (the mapped/TLB runtime that loads + starts but
 * hangs at "ready!, state 1" before main on the Henry SoC FPGA).  Boot the test
 * EXACTLY like the kernel: the FSBL (henry_arcs.bin @ 0xBFC00000) does early CPU
 * bring-up, then `jr`s here -- the mips-axi driver patches the FSBL kentry slot
 * (0xBFC00008) with this ELF's e_entry.  Everything is linked in cached, unmapped
 * kseg0 (csmith_fsbl.ld), so there is NO TLB/kuseg setup to wedge.
 *
 * Console output is the CP0-$7 putchar FIFO (printf.c _putchar -- identical to the
 * ARCS stub_write the firmware uses); a clean stop is the magic-halt register
 * 0xBFD00000 (driver prints "MAGIC HALT"), matching baremetal_support.c.
 *
 * Run:  mips-axi -f X.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
 *
 * N32 ABI (-mabi=n32): $t4-$t7 do not exist; only $t0-$t3 used here.
 */

    .section .text.startup, "ax"
    .set noreorder
    .set noat
    .align 2
    .globl _start
_start:
    move  $gp, $zero            /* -mno-abicalls -G0: $gp unused (matches mapped rt) */
    la    $sp, _stack_top       /* FSBL left no stack */
    move  $fp, $sp

    /* zero .bss (the loader memsets p_memsz too, but be robust) */
    la    $t0, __bss_start
    la    $t1, __bss_end
1:  beq   $t0, $t1, 2f
    nop
    sd    $zero, 0($t0)         /* bss is 16-aligned by the linker */
    addiu $t0, $t0, 8
    b     1b
    nop
2:
    jal   main
    nop

    /* clean stop: MAGIC HALT register (same as baremetal_support.c SIM_HALT_ADDR) */
    li    $k0, 0xBFD00000
    li    $k1, 1
    sw    $k1, 0($k0)
3:  b     3b
    nop
