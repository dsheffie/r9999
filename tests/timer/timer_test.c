/*
 * timer_test.c  --  bare-metal timer interrupt test for r9999 MIPS simulator
 *
 * Arms the CP0 Count/Compare timer at a fixed initial Compare value, then
 * waits for N_IRQS interrupts.  The exception handler (in baremetal_support.c)
 * rearms by incrementing g_timer_next_compare by g_timer_interval each time,
 * so CP0 Count is never read in C code — that avoids a checker register mismatch
 * caused by the inherent timing difference between RTL execution and retirement.
 */

#include <stdint.h>
#include "printf.h"

/* Exposed by baremetal_support.c */
extern volatile uint32_t g_timer_interval;
extern volatile uint32_t g_timer_next_compare;
extern volatile int      g_timer_irq_count;

#define TIMER_INTERVAL   10000u   /* cycles between successive interrupts */
/* The RTL Count keeps running during the simulator init phase (~66K cycles).
 * INITIAL_COMPARE must be above Count when main() is reached.  200K gives a
 * comfortable margin (first IRQ fires ~134K cycles into main()). */
#define INITIAL_COMPARE  200000u  /* first interrupt fires at Count == 200000 */
#define N_IRQS           5        /* number of interrupts to wait for        */

int main(void)
{
    /* 1. Tell the handler the interval to use when rearming Compare. */
    g_timer_interval    = TIMER_INTERVAL;
    g_timer_next_compare = INITIAL_COMPARE;

    /* 2. Arm first interrupt: write INITIAL_COMPARE to CP0 Compare (reg 11).
     *    MTC0 to Compare clears any pending timer interrupt (MIPS spec). */
    uint32_t compare = INITIAL_COMPARE;
    __asm__ volatile("mtc0 %0, $11" : : "r"(compare) : "memory");

    /* 3. Enable timer interrupt: SR.IM[7]=1 (bit 15) and SR.IE=1 (bit 0).
     *    Also clear ERL (bit 2) which is set at reset.  irq_pending in the
     *    RTL requires ~ERL, so if ERL stays 1 interrupts can never fire. */
    uint32_t sr;
    __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
    sr &= ~(1u << 2);           /* clear ERL */
    sr |= (1u << 15) | 1u;     /* set IM[7] and IE */
    __asm__ volatile("mtc0 %0, $12" : : "r"(sr) : "memory");

    /* 4. Spin until N_IRQS interrupts have been received. */
    while (g_timer_irq_count < N_IRQS) {
        /* nothing — interrupts fire asynchronously */
    }

    printf_("timer irqs received: %d\n", g_timer_irq_count);
    printf_("checksum %d\n", g_timer_irq_count);

    return 0;
}
