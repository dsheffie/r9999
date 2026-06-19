/*
 * sw_irq_test.c -- bare-metal software-interrupt (IP0/IP1) test for the r9999
 * MIPS core. Unlike the external IP2..IP6 (driven by pins), IP0/IP1 are the only
 * software-WRITABLE Cause.IP bits: the program raises them with mtc0 Cause. This
 * test enables IM[0]+IM[1]+IE, raises IP0 then IP1, and checks the handler saw
 * both (g_sw_irq_ip == 0x3). The handler (baremetal_support.c) clears Cause.IP[N]
 * to ack. Self-contained (no TB inject) -- runs fine under -c0.
 */
#include <stdint.h>
#include "printf.h"

extern volatile int      g_sw_irq_count;
extern volatile uint32_t g_sw_irq_ip;

/* set Cause.IP[bit-8] (bit==8 -> IP0, bit==9 -> IP1) */
static inline void raise_sw_irq(uint32_t bit)
{
    uint32_t c;
    __asm__ volatile("mfc0 %0, $13" : "=r"(c));
    c |= (1u << bit);
    __asm__ volatile("mtc0 %0, $13" : : "r"(c) : "memory");
}

int main(void)
{
    /* Enable IM[0] (bit 8) + IM[1] (bit 9) + IE (bit 0); clear ERL (bit 2). */
    uint32_t sr;
    __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
    sr &= ~(1u << 2);
    sr |= (3u << 8) | 1u;             /* IM[0] + IM[1] + IE */
    __asm__ volatile("mtc0 %0, $12" : : "r"(sr) : "memory");

    raise_sw_irq(8);                  /* IP0 */
    while (g_sw_irq_count < 1) { }

    raise_sw_irq(9);                  /* IP1 */
    while (g_sw_irq_count < 2) { }

    printf_("sw irq count: %d  ip-bits: 0x%x\n", g_sw_irq_count, g_sw_irq_ip);
    printf_("checksum %d\n", (int)g_sw_irq_ip);   /* expect 3 (IP0 | IP1) */
    return 0;
}
