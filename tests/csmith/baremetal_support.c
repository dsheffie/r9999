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

/* ---- Exception handler (called from start.s .boot.exc stub) ----------- */

/*
 * SIM_HALT_ADDR is in kseg1 (uncached, direct-mapped).  Writing a non-zero
 * value here signals the C++ harness to stop simulation.  The harness polls
 * this physical address (0x1FD00000) each time it processes a store.
 */
#define SIM_HALT_ADDR ((volatile uint32_t *)0xBFD00000U)

void exc_handler(void) {
    /*
     * Read CP0 Cause.ExcCode (bits [6:2]).  ExcCode 9 = Bp (breakpoint).
     * If this is a BREAK-triggered exception write the halt sentinel so the
     * simulator harness can stop cleanly.  For all other exceptions we just
     * spin; the harness will eventually time out or detect the loop.
     */
    uint32_t cause;
    __asm__ volatile("mfc0 %0, $13" : "=r" (cause));
    if (((cause >> 2) & 0x1fu) == 9u) {
        *SIM_HALT_ADDR = 1u;
    }
    for (;;) ;
}

/* ---- Termination ------------------------------------------------------- */

void abort(void) {
    __asm__ volatile("break");
}
