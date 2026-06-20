/*
 * hello.c -- minimal Henry-SoC bare-metal test booted via the henry_arcs FSBL.
 *
 * Prints a banner, runs a tiny compute self-check, and reports PASS/FAIL over
 * the CP0-$7 console.  Demonstrates the FSBL bare-metal flow (C + printf-style
 * output) as an alternative to the mapped runtime that hangs on the FPGA.
 *
 * Run:  mips-axi -f hello.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
 */
#include "henry_io.h"

int main(int argc, char **argv, char **envp)
{
    (void)argc; (void)argv; (void)envp;

    puts_("Henry bare-metal hello\n");

    /* compute self-check: sum 1..100 == 5050 */
    unsigned int sum = 0;
    for (unsigned int i = 1; i <= 100; i++)
        sum += i;

    puts_("sum(1..100) = ");
    puthex32(sum);
    putch('\n');

    if (sum == 5050u)
        puts_("PASS\n");
    else
        puts_("FAIL\n");

    sim_halt();
    return 0;
}
