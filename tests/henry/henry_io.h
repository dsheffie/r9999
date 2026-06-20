/*
 * henry_io.h -- console I/O for Henry-SoC bare-metal tests.
 *
 * Output goes through the CP0 reg-7 putchar FIFO: read $7 (bit0 = FIFO full),
 * spin while full, then write the byte to $7.  This is byte-for-byte the ARCS
 * "Write" callback (henry_arcs.S stub_write) -- i.e. the same console the
 * firmware and the existing assembly tests under tests/except use.  The
 * mips-axi driver drains the FIFO to stdout.
 */
#ifndef HENRY_IO_H
#define HENRY_IO_H

static inline void putch(int c)
{
    unsigned int full;
    do {
        __asm__ volatile("mfc0 %0, $7" : "=r"(full));
    } while (full & 1u);                 /* spin while FIFO full */
    __asm__ volatile("mtc0 %0, $7" :: "r"(c));
}

static inline void puts_(const char *s)
{
    while (*s) putch((unsigned char)*s++);
}

static inline void puthex32(unsigned int v)
{
    static const char hex[] = "0123456789abcdef";
    int i;
    putch('0'); putch('x');
    for (i = 28; i >= 0; i -= 4)
        putch(hex[(v >> i) & 0xf]);
}

/* Stop the simulator cleanly (magic-halt register, same as FSBL stub_halt). */
static inline void sim_halt(void)
{
    volatile unsigned int *halt = (volatile unsigned int *)0xBFD00000u;
    *halt = 1;
    for (;;) { }
}

#endif /* HENRY_IO_H */
