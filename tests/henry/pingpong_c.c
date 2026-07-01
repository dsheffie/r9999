/*
 * pingpong_c.c -- CACHED variant of the PS<->PL ping-pong (mimics dma_cache_inv).
 *
 * Same ARM producer (writes DATA then SEQ, 1 MB apart).  This MIPS consumer
 * reads DATA through the CACHED kseg0 alias, doing a `cache Hit_Invalidate_D`
 * on the line first -- exactly what the kernel's dma_cache_inv does before the
 * CPU reads a DMA'd buffer.  SEQ stays uncached (kseg1) for a reliable signal.
 *
 * If this throws PP MISMATCH (DATA stale despite the invalidate) the cache-
 * coherence-vs-DMA path is the bug; if clean, the data-read coherence works and
 * the SCSI hazard is elsewhere (descriptor / MIPS->ARM direction).
 *
 * Run: PINGPONG=1 mips-axi -f pingpong_c.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
 */
#include "henry_io.h"

#define A2M_DATA_K0 ((volatile unsigned int *)0x89000000u)   /* cached kseg0 view of phys 0x0900_0000 */
#define A2M_SEQ     (*(volatile unsigned int *)0xA9100000u)   /* uncached kseg1 signal, 1 MB away */

#define NSAMPLES 5000u

/* Hit_Invalidate_D = op 4 (Hit_Invalidate) | cache 1 (D) = 0x11 -- drop the line, no writeback. */
static inline void dcache_hit_inv(volatile void *p)
{
    __asm__ volatile(".set push\n\t.set mips3\n\tcache 0x11, 0(%0)\n\t.set pop"
                     :: "r"(p) : "memory");
}

int main(void)
{
    puts_("PINGPONG MIPS consumer (CACHED kseg0 + Hit_Invalidate_D)\n");

    unsigned int last = 0, ok = 0, bad = 0, samples = 0, shown = 0;

    while (A2M_SEQ == 0u) { }

    for (;;) {
        unsigned int s1, s2, d;
        do { s1 = A2M_SEQ; } while (s1 == last);    /* wait for a NEW seq (uncached) */
        dcache_hit_inv(A2M_DATA_K0);                /* invalidate the cached DATA line (dma_cache_inv) */
        d = *A2M_DATA_K0;                           /* cached read -> miss -> re-fetch from DDR */
        s2 = A2M_SEQ;
        if (s1 != s2) continue;                     /* producer advanced mid-read -> skip (seqlock) */
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
