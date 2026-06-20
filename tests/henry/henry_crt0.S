/*
 * henry_crt0.S -- minimal C runtime for Henry-SoC bare-metal tests booted via
 * the henry_arcs FSBL.
 *
 * Entry: the FSBL jumps here (driver-patched kentry = this ELF's e_entry) with
 * a0=argc, a1=argv, a2=envp and the temp regs zeroed.  No stack is set up yet,
 * so we set $sp ourselves, zero .bss, then call main(argc,argv,envp).  On
 * return we stop the simulator via the magic-halt register (same as the FSBL's
 * stub_halt), so the driver's run terminates cleanly.
 */

    .set    mips3
    .set    noreorder
    .set    noat

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    la      $sp, _stack_top         /* our own stack (FSBL left none) */
    move    $fp, $sp

    /* zero .bss */
    la      $t0, __bss_start
    la      $t1, __bss_end
1:  beq     $t0, $t1, 2f
    nop
    sw      $zero, 0($t0)
    addiu   $t0, $t0, 4
    b       1b
    nop
2:
    /* main(argc, argv, envp) -- a0/a1/a2 are still as the FSBL left them */
    jal     main
    nop

    /* halt: write the magic-halt register (0xBFD00000), same as FSBL stub_halt */
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
3:  b       3b
    nop
    .size   _start, .-_start
