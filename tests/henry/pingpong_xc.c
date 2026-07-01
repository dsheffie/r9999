/*
 * pingpong_xc.c -- COMPLETION-direction cross-path test (ARM->MIPS), the faithful
 * mirror of the SCSI completion path that produces got=sentinel.
 *
 * ARM (producer, XPATH2=1): writes ring[k]=bswap32(k) to DDR (its mmap), barrier,
 * then pushes one SCC-Rx byte (via S00 reg 0x3b) as the SIGNAL.  This MIPS core
 * (consumer): polls the SCC RR0 Rx-avail bit (an internal IOC read, NOT DDR),
 * reads the data byte (observes the signal + pops), then IMMEDIATELY reads
 * ring[k] from DDR via the NON-COHERENT M00/HP port and checks ==k.
 *
 * Unlike the earlier ping-pong (where the MIPS polled SEQ in DDR, same leg, so the
 * HP read's own ordering carried the data), here the signal arrives via the IOC
 * (S00 leg) independent of the HP read -- so a stale HP view of the ARM's DDR
 * write shows up as a mismatch.  That is the suspected SCSI corruption, isolated.
 *
 * Run: XPATH2=1 mips-axi -f pingpong_xc.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
 */
#include "henry_io.h"

#define SCC_RR0  (*(volatile unsigned char *)0xBFBD9830u)   /* control read: bit0 = Rx char available */
#define SCC_DATA (*(volatile unsigned char *)0xBFBD9837u)   /* chanA DATA read: front byte + pop */

#define RINGMASK 0xFFFFu                                    /* 64K slots, distinct -> no overwrite mask */
#define NSIG     50000u

static volatile unsigned int *const ring =
    (volatile unsigned int *)0xA9000000u;                   /* uncached kseg1 view of phys 0x0900_0000 */

int main(void)
{
    unsigned int k, ok = 0, bad = 0, shown = 0;

    for (k = 0; k < NSIG; k++) {
        while (!(SCC_RR0 & 1u)) { }      /* poll Rx-avail (signal), internal IOC read */
        (void)SCC_DATA;                  /* observe the signal: read the byte + pop the FIFO */
        unsigned int d = ring[k & RINGMASK];   /* read DATA via M00 <- DDR (non-coherent HP), NOW */
        if (d == k) ok++;
        else { bad++; if (shown < 12) { puts_("XC MISMATCH k="); puthex32(k); puts_(" got="); puthex32(d); putch('\n'); shown++; } }
    }

    puts_("XC FINAL ok="); puthex32(ok); puts_(" bad="); puthex32(bad); putch('\n');
    sim_halt();
    return 0;
}
