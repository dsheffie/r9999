/*
 * pingpong.c -- bare-metal PS<->PL DDR-ordering test (no Linux).
 *
 * The ARM (driver, PINGPONG=1) is the producer: it writes DATA = n, a memory
 * barrier, then SEQ = n, incrementing n forever.  DATA and SEQ live in
 * different DRAM pages (1 MB apart) so the SEQ write can race ahead of the DATA
 * write across the PS<->PL boundary.
 *
 * This MIPS core is the consumer: spin until SEQ changes, read DATA exactly
 * once, and check DATA == SEQ.  A seqlock (re-read SEQ after DATA; skip if it
 * moved) removes the producer-advanced-mid-read false positive, so a surviving
 * mismatch == the SEQ became visible before its DATA == the PS<->PL ordering bug.
 *
 * Uncached (kseg1) view first: tests the raw DDR/AXI ordering with no cache.
 *
 * Run: mips-axi -f pingpong.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
 *      (with PINGPONG=1 in the driver's env for the ARM producer)
 */
#include "henry_io.h"

/* uncached (kseg1) views of the shared DDR ping-pong region (phys 0x0900_0000) */
#define A2M_DATA (*(volatile unsigned int *)0xA9000000u)
#define A2M_SEQ  (*(volatile unsigned int *)0xA9100000u)   /* 1 MB from DATA -> different DRAM row */

#define NSAMPLES 1000000u

int main(void)
{
    puts_("PINGPONG MIPS consumer (uncached kseg1)\n");

    unsigned int last = 0, ok = 0, bad = 0, samples = 0, shown = 0;

    /* wait for the ARM producer to start (seq becomes nonzero) */
    while (A2M_SEQ == 0u) { }

    for (;;) {
        unsigned int s1, s2, d;
        do { s1 = A2M_SEQ; } while (s1 == last);   /* wait for a NEW seq value */
        d  = A2M_DATA;                              /* read DATA exactly once after the signal */
        s2 = A2M_SEQ;
        if (s1 != s2) continue;                    /* producer advanced mid-read -> skip (seqlock) */
        last = s1;
        if (d == s1) {
            ok++;
        } else {
            bad++;
            if (shown < 8) { puts_("PP MISMATCH seq="); puthex32(s1); puts_(" data="); puthex32(d); putch('\n'); shown++; }
        }
        if (++samples >= NSAMPLES) {
            puts_("PP FINAL ok="); puthex32(ok); puts_(" bad="); puthex32(bad); putch('\n');
            sim_halt();
        }
    }
    return 0;
}
