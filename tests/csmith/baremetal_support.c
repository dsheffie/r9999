/*
 * baremetal_support.c  --  string / runtime functions for bare-metal csmith tests.
 *
 * Replaces the libc symbols that csmith-generated programs reference so the
 * binary can be linked -nostdlib against the hello/ startup infrastructure.
 */

#include <stddef.h>
#include <stdint.h>

/* ---- Memory ------------------------------------------------------------ */

void *memset(void *dest, int c, size_t n) {
    unsigned char *p = (unsigned char *)dest;
    unsigned char v = (unsigned char)c;
    while (n--) *p++ = v;
    return dest;
}

void *memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dest;
}

void *memmove(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n; s += n;
        while (n--) *--d = *--s;
    }
    return dest;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *p = (const unsigned char *)a;
    const unsigned char *q = (const unsigned char *)b;
    while (n--) {
        if (*p != *q) return (int)*p - (int)*q;
        p++; q++;
    }
    return 0;
}

/* ---- String ------------------------------------------------------------ */

size_t strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

int strcmp(const char *a, const char *b) {
    while (*a && (*a == *b)) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
    while (n-- && *a && (*a == *b)) { a++; b++; }
    if (n == (size_t)-1) return 0;
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

/* ---- Exception handler (called from start_csmith.S .boot.exc stub) ---- */

/*
 * SIM_HALT_ADDR is in kseg1 (uncached, direct-mapped).  Writing a non-zero
 * value here signals the C++ harness to stop simulation.  The harness polls
 * this physical address (0x1FD00000) each time it processes a store.
 */
#define SIM_HALT_ADDR ((volatile uint32_t *)0xBFD00000U)

/* Register save area filled by the assembly stub before calling us. */
uint64_t exc_regfile[32];

/* Timer interrupt support.  Set g_timer_interval > 0 to enable rearm-and-ERET
 * behaviour on every timer interrupt; leave 0 (default) to halt on Int.
 * g_timer_next_compare tracks the next Compare value so the handler never
 * needs to read CP0 Count (which would cause a checker mismatch). */
volatile uint32_t g_timer_interval    = 0;
volatile uint32_t g_timer_next_compare = 0;
volatile int      g_timer_irq_count   = 0;
/* External device interrupts (IP2..IP6, the INT3/IOC2 levels). The TB injects
 * ipN; the handler records the fired IP bits and masks IM[N] so the held line
 * stops re-firing after ERET. */
volatile int      g_ext_irq_count = 0;
volatile uint32_t g_ext_irq_ip    = 0;   /* Cause.IP[6:2] bits seen */
/* When set (INT3 8254 timer tests on the henry SoC), ack IP4/IP5 by clearing the
 * INT3 latch (Timer Clear @0xBFBD98A0) and leave IM enabled so the periodic timer
 * re-fires -- vs the default extirq path, which masks IM[N] to stop a held line. */
volatile int      g_pit_mode      = 0;
/* Software interrupts (IP0/IP1, the only software-WRITABLE Cause.IP bits).
 * Triggered by mtc0 Cause; the handler accumulates which fired and clears the
 * Cause.IP[1:0] bit(s) to ack (else the still-set bit re-fires after ERET). */
volatile int      g_sw_irq_count  = 0;
volatile uint32_t g_sw_irq_ip     = 0;   /* OR of Cause.IP[1:0] bits seen */

/*
 * Called from the .boot.exc stub with a pointer to the saved GPR file.
 * Returns 1 to request ERET (resume after emulation), 0 to halt.
 *
 * Handles:
 *   ExcCode 4 (AdEL) / 5 (AdES) -- unaligned load/store: emulate byte-by-byte
 *   ExcCode 9 (Bp), 10 (RI), 13 (Tr) -- write halt sentinel and stop
 */
int exc_handler(uint64_t *regs) {
    uint32_t cause, epc;
    __asm__ volatile("mfc0 %0, $13" : "=r"(cause));
    __asm__ volatile("mfc0 %0, $14" : "=r"(epc));
    uint32_t exccode = (cause >> 2) & 0x1fu;

    if (exccode == 0u) {
        /* Distinguish external device IRQ (IP2..IP6) from the CP0 timer (IP7). */
        uint32_t ip = (cause >> 8) & 0xffu;          /* Cause.IP[7:0] */
        if (ip & 0x7cu) {                            /* bits 6:2 = IP2..IP6 set */
            g_ext_irq_ip = ip & 0x7cu;
            ++g_ext_irq_count;
            if (g_pit_mode && (ip & 0x30u)) {        /* IP4/IP5 = INT3 8254 timers */
                /* ack the latched timer int via Timer Clear (b0=Timer0/IP4,
                 * b1=Timer1/IP5); keep IM enabled so it re-fires next period. */
                *(volatile uint8_t *)0xBFBD98A0u = (uint8_t)((ip >> 4) & 0x3u);
            } else {
                uint32_t sr;                         /* mask IM[N] for the fired levels */
                __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
                sr &= ~((uint32_t)(ip & 0x7cu) << 8);/* IM bits are SR[15:8], same positions */
                __asm__ volatile("mtc0 %0, $12" : : "r"(sr));
            }
            return 1;                                /* ERET */
        }
        if (ip & 0x03u) {                            /* bits 1:0 = software IP0/IP1 */
            g_sw_irq_ip |= ip & 0x03u;
            ++g_sw_irq_count;
            uint32_t c;                              /* ack: clear Cause.IP[1:0] */
            __asm__ volatile("mfc0 %0, $13" : "=r"(c));
            c &= ~((uint32_t)(ip & 0x03u) << 8);
            __asm__ volatile("mtc0 %0, $13" : : "r"(c));
            return 1;                                /* ERET */
        }
        /* Timer interrupt: rearm Compare and resume.
         * We advance g_timer_next_compare by the interval and write it to
         * Compare — no mfc0 $9 needed (reading Count would diverge between
         * RTL and sim since Count is cycle-dependent). */
        if (g_timer_interval == 0) {
            *SIM_HALT_ADDR = 1u;
            return 0;
        }
        ++g_timer_irq_count;
        g_timer_next_compare += g_timer_interval;
        uint32_t compare = g_timer_next_compare;
        __asm__ volatile("mtc0 %0, $11" : : "r"(compare));
        return 1;
    }

    if (exccode == 9u || exccode == 10u || exccode == 13u) {
        *SIM_HALT_ADDR = 1u;
        return 0;
    }

    if (exccode == 4u || exccode == 5u) {
        /* BD=1 means the faulting instruction is in a branch delay slot;
         * EPC then points to the branch, and the faulting insn is at EPC+4.
         * We emulate the delay-slot insn and resume at EPC+8. */
        uint32_t bd       = (cause >> 31) & 1u;
        uint32_t fault_pc = bd ? epc + 4u : epc;
        uint32_t insn     = *(volatile uint32_t *)fault_pc;

        uint32_t opcode =  (insn >> 26) & 0x3fu;
        uint32_t rs     =  (insn >> 21) & 0x1fu;
        uint32_t rt     =  (insn >> 16) & 0x1fu;
        int32_t  off    =  (int32_t)(int16_t)(insn & 0xffffu);
        uint32_t ea     =  (uint32_t)((int64_t)regs[rs] + off);
        volatile uint8_t *p = (volatile uint8_t *)ea;

        switch (opcode) {
        case 0x21: /* lh -- signed halfword */
            regs[rt] = (int64_t)(int16_t)(((uint16_t)p[0] << 8) | p[1]);
            break;
        case 0x25: /* lhu -- unsigned halfword */
            regs[rt] = ((uint64_t)p[0] << 8) | p[1];
            break;
        case 0x23: /* lw -- sign-extended word */
            regs[rt] = (int64_t)(int32_t)(
                ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
                ((uint32_t)p[2] <<  8) |  (uint32_t)p[3]);
            break;
        case 0x27: /* lwu -- zero-extended word */
            regs[rt] = ((uint64_t)p[0] << 24) | ((uint64_t)p[1] << 16) |
                       ((uint64_t)p[2] <<  8) |  (uint64_t)p[3];
            break;
        case 0x37: /* ld */
            regs[rt] = ((uint64_t)p[0] << 56) | ((uint64_t)p[1] << 48) |
                       ((uint64_t)p[2] << 40) | ((uint64_t)p[3] << 32) |
                       ((uint64_t)p[4] << 24) | ((uint64_t)p[5] << 16) |
                       ((uint64_t)p[6] <<  8) |  (uint64_t)p[7];
            break;
        case 0x29: /* sh */
            p[0] = (regs[rt] >>  8) & 0xffu;
            p[1] =  regs[rt]        & 0xffu;
            break;
        case 0x2b: /* sw */
            p[0] = (regs[rt] >> 24) & 0xffu;
            p[1] = (regs[rt] >> 16) & 0xffu;
            p[2] = (regs[rt] >>  8) & 0xffu;
            p[3] =  regs[rt]        & 0xffu;
            break;
        case 0x3f: /* sd */
            p[0] = (regs[rt] >> 56) & 0xffu;
            p[1] = (regs[rt] >> 48) & 0xffu;
            p[2] = (regs[rt] >> 40) & 0xffu;
            p[3] = (regs[rt] >> 32) & 0xffu;
            p[4] = (regs[rt] >> 24) & 0xffu;
            p[5] = (regs[rt] >> 16) & 0xffu;
            p[6] = (regs[rt] >>  8) & 0xffu;
            p[7] =  regs[rt]        & 0xffu;
            break;
        default:
            /* Unrecognised opcode in an address-error exception -- give up. */
            *SIM_HALT_ADDR = 1u;
            return 0;
        }

        /* Advance EPC past the (now-emulated) faulting instruction. */
        uint32_t new_epc = fault_pc + 4u;
        __asm__ volatile("mtc0 %0, $14" : : "r"(new_epc));
        return 1;
    }

    /* Any other exception -- halt cleanly. */
    *SIM_HALT_ADDR = 1u;
    return 0;
}

/* ---- Termination ------------------------------------------------------- */

void abort(void) {
    __asm__ volatile("break");
}
