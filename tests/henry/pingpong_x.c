/*
 * pingpong_x.c -- CROSS-PATH ordering test (no RTL needed).
 *
 * Hypothesis: a signal on the S00 AXI-Lite leg can be observed by the consumer
 * BEFORE a DDR write (issued before it in program order) has landed, because the
 * S00 control path and the M00 memory path are independent AXI interfaces with
 * no cross-interface ordering.  (The earlier ping-pong put the signal IN DDR --
 * same leg as the data -- and was 0/1M; that proved same-leg ordering, not this.)
 *
 * MIPS (producer): for each k, write ring[k]=k to DDR (uncached -> M00), then
 * push a console char (CP0 $7 -> on-chip FIFO -> read by the ARM via S00).  The
 * char is the SIGNAL; the ring slot is the DATA.  Distinct slots (64K ring) so a
 * late write is never masked by a later one (MIPS runs at most FIFO-depth ahead).
 *
 * ARM (consumer, XPATH=1 in the driver): the instant it sees a char on the FIFO
 * (S00), it reads ring[k] from DDR and checks ==k.  A mismatch = the S00 signal
 * beat the M00 DDR write = the cross-path hazard, reproduced in isolation.
 *
 * Run: XPATH=1 mips-axi -f pingpong_x.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
 */
#include "henry_io.h"

#define RINGMASK 0xFFFFu                                   /* 64K slots */
#define NSIG     50000u

static volatile unsigned int *const ring =
    (volatile unsigned int *)0xA9000000u;                  /* uncached kseg1 view of phys 0x0900_0000 */

int main(void)
{
    unsigned int k;
    putch(0x02);                     /* START marker: the ARM aligns xk=0 to the first dot below */
    for (k = 0; k < NSIG; k++) {
        ring[k & RINGMASK] = k;      /* DATA -> DDR (M00), uncached */
        putch('.');                  /* SIGNAL -> CP0 $7 FIFO -> S00 (issued AFTER the data write) */
    }
    /* The ARM tallies ok/bad as it drains; we just stop the sim. */
    sim_halt();
    return 0;
}
