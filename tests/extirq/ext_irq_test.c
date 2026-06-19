/*
 * ext_irq_test.c -- bare-metal external-interrupt (IP2..IP6) test for the r9999
 * MIPS core. Enables IP2 (SR.IM[2]+IE, clears ERL) then spins; the TB injects
 * ip2 (run with R9999_ASSERT_IP=2 and --checker false -- the cosim checker would
 * diverge since the interpreter doesn't model the injected line). The handler
 * (baremetal_support.c) records Cause.IP[6:2] and masks IM[2] so the held line
 * stops re-firing after ERET. Self-check: g_ext_irq_ip == 0x04 (IP2).
 */
#include <stdint.h>
#include "printf.h"

extern volatile int      g_ext_irq_count;
extern volatile uint32_t g_ext_irq_ip;

int main(void)
{
    /* Enable IP2: SR.IM[2] (bit 10) + IE (bit 0); clear ERL (bit 2, set at reset
     * -- irq_pending in the RTL requires ~ERL). */
    uint32_t sr;
    __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
    sr &= ~(1u << 2);                 /* clear ERL */
    sr |= (0x1fu << 10) | 1u;         /* IM[2..6] (bits 10..14) + IE */
    __asm__ volatile("mtc0 %0, $12" : : "r"(sr) : "memory");

    /* Wait for the TB-injected ip2 interrupt. */
    while (g_ext_irq_count < 1) { }

    printf_("ext irq count: %d  ip-bits: 0x%x\n", g_ext_irq_count, g_ext_irq_ip);
    printf_("checksum %d\n", (int)g_ext_irq_ip);   /* expect 4 (IP2 = Cause bit 10) */
    return 0;
}
