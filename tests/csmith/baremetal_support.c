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
