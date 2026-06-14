/*
 * sim.h  --  simulator console helpers for bare-metal MIPS tests
 *
 * Output mechanism: MTC0 $rt, $7 pushes $rt[7:0] into the putchar FIFO in
 * exec.sv; the simulator drains it and writes to stdout every clock cycle.
 */
#ifndef __SIM_H__
#define __SIM_H__

/* CP0 PRId values (imp field bits [15:8]; R4000 family shares imp 0x04 and is
 * distinguished by the revision byte).  Keep in sync with machine.vh. */
#define PRID_R4000  0x00000400   /* imp 0x04, rev 0x00 */
#define PRID_R4400  0x00000440   /* imp 0x04, rev 0x40 */
#define PRID_R10000 0x00000900   /* imp 0x09, rev 0x00 */
#define PRID_VALUE  PRID_R4000

#ifdef __ASSEMBLER__

/* Output low byte of $reg as a character (reg must be a register, not a literal) */
#define SIMCON_PUTCHAR(reg)  mtc0 reg, $7

/*
 * Load immediate character value c into $t9, then output it.
 * Use this when you want to print a literal, not a register.
 */
#define SIMCON_PUTLIT(c) \
    li $t9, c        ; \
    mtc0 $t9, $7

/* Terminate simulation (the simulator breaks out of its loop on BREAK) */
#define SIM_PASS()   break
/* msg is ignored in assembly context; put a sim_puts call before SIM_FAIL */
#define SIM_FAIL(msg) break

#else  /* C / C++ */

static inline void simcon_putchar(unsigned int c) {
    __asm__ volatile("mtc0 %0, $7" : : "r"(c & 0xffu));
}
/* Capitalised alias so C and assembly code can share the same name */
#define SIMCON_PUTCHAR(c)  simcon_putchar((unsigned int)(c))

static inline void simcon_puts(const char *s) {
    while (*s)
        simcon_putchar((unsigned char)*s++);
}

/* Print a 32-bit value as 8 hex digits */
static inline void simcon_puthex32(unsigned int v) {
    static const char hex[] = "0123456789abcdef";
    simcon_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        simcon_putchar(hex[(v >> i) & 0xf]);
}

/* Print an unsigned decimal integer */
static inline void simcon_putuint(unsigned int v) {
    char buf[12];
    int i = 11;
    buf[i] = '\0';
    if (v == 0) {
        buf[--i] = '0';
    } else {
        while (v) {
            buf[--i] = '0' + (v % 10);
            v /= 10;
        }
    }
    simcon_puts(buf + i);
}

/* Terminate the simulation and report pass/fail via the console */
#define SIM_PASS() \
    do { simcon_puts("PASS\n"); __asm__ volatile("break"); } while (0)

#define SIM_FAIL(msg) \
    do { simcon_puts("FAIL: " msg "\n"); __asm__ volatile("break"); } while (0)

/* Assert a condition; on failure print message and stop */
#define SIM_CHECK(cond, msg) \
    do { if (!(cond)) SIM_FAIL(msg); } while (0)

#define SIM_CHECK_EQ32(a, b, msg) \
    do { \
        unsigned int _a = (unsigned int)(a), _b = (unsigned int)(b); \
        if (_a != _b) { \
            simcon_puts("FAIL: " msg " got "); \
            simcon_puthex32(_a); \
            simcon_puts(" expected "); \
            simcon_puthex32(_b); \
            simcon_puts("\n"); \
            __asm__ volatile("break"); \
        } \
    } while (0)

#endif  /* __ASSEMBLER__ */
#endif  /* __SIM_H__ */
