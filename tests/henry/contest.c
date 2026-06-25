/*
 * contest.c -- console throughput comparison, Henry-SoC bare-metal (FSBL boot).
 *
 * Writes N characters via each console path and reports the CP0 Count-register
 * delta (cycles) for each, so we can compare effective throughput on silicon:
 *
 *   (1) CP0 reg-7 putchar FIFO   -- the "arc/mtc0" path (fast: drained directly
 *                                   by mips-axi's slv_reg console reader)
 *   (2) SCC channel-A (ttyS0) Tx, polled -- spin on RR0 bit2 (Tx-Buffer-Empty),
 *                                   then write the data reg (the slow path Linux
 *                                   userspace uses)
 *   (3) SCC Tx, interrupt-driven -- TODO (needs IP2 plumbing; added next)
 *
 * Both loops actually emit the N chars; only the reported Count delta matters.
 * Run: mips-axi -f contest.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
 */
#include "henry_io.h"

#define N 10000u

/* SCC console channel (ttyS0 / chanA): control @ 0xbfbd9830, data @ 0xbfbd9834
 * (uncached kseg1).  RR0 bit2 = Tx-Buffer-Empty (set => ready to accept a char;
 * cleared while a char shifts out or the downstream console FIFO is full). */
#define SCC_CTRL (*(volatile unsigned char *)0xBFBD9830u)
#define SCC_DATA (*(volatile unsigned char *)0xBFBD9834u)
#define RR0_TX_EMPTY 0x04u

/* free-running cycle counter hacked into CP0 reg 23 (r_cycle, +1 every cycle). */
static inline unsigned int rd_cycle(void)
{
    unsigned int c;
    __asm__ volatile("mfc0 %0, $23" : "=r"(c));
    return c;
}

/* INT3 (sgint) mask regs: LOCAL0 MASK bit7 = MAP_INT0->IP2; MAP MASK0 bit5 =
 * Serial-DUART mappable source (SCC Tx/Rx). */
#define INT3_LOCAL0_MASK   (*(volatile unsigned char *)0xBFBD9887u)
#define INT3_MAP_MASK0     (*(volatile unsigned char *)0xBFBD9897u)
#define INT3_LOCAL0_STATUS (*(volatile unsigned char *)0xBFBD9883u)  /* bit7=MAP_INT0 */
#define INT3_MAP_STATUS    (*(volatile unsigned char *)0xBFBD9893u)  /* vmeistat=map_src */

/* shared with the IP2 handler in irqvec.S */
volatile unsigned int g_sent, g_done, g_n;

static inline void set_status(unsigned int s)
{
    __asm__ volatile("mtc0 %0, $12; nop; nop; nop" :: "r"(s));
}

/* (1) CP0-$7: spin while FIFO full (bit0), then push the byte. */
static inline void cp7_putc(int c)
{
    unsigned int full;
    do { __asm__ volatile("mfc0 %0, $7" : "=r"(full)); } while (full & 1u);
    __asm__ volatile("mtc0 %0, $7" :: "r"(c));
}

/* (2) SCC polled: spin while Tx-Buffer-Empty clear, then write the data reg. */
static inline void scc_putc_polled(int c)
{
    while (!(SCC_CTRL & RR0_TX_EMPTY)) { }
    SCC_DATA = (unsigned char)c;
}

static void print_dec(unsigned int v)
{
    char buf[12];
    int i = 0;
    if (v == 0) { putch('0'); return; }
    while (v) { buf[i++] = '0' + (v % 10u); v /= 10u; }
    while (i--) putch(buf[i]);
}

int main(int argc, char **argv, char **envp)
{
    (void)argc; (void)argv; (void)envp;
    unsigned int t0, t1, c_cp7, c_scc;
    unsigned int i;

    puts_("\n=== console throughput: ");
    print_dec(N);
    puts_(" chars/path ===\n");

    /* (1) CP0 reg-7 putchar FIFO */
    t0 = rd_cycle();
    for (i = 0; i < N; i++) cp7_putc('.');
    t1 = rd_cycle();
    c_cp7 = t1 - t0;

    /* (2) SCC chanA Tx, polled.  Reset the SCC register pointer to 0 first so the
     * control read returns RR0 (a WR0=0 write sets ptr=0). */
    SCC_CTRL = 0x00u;
    t0 = rd_cycle();
    for (i = 0; i < N; i++) scc_putc_polled('.');
    t1 = rd_cycle();
    c_scc = t1 - t0;

    /* (3) SCC chanA Tx, interrupt-driven (IP2). */
    unsigned int c_irq = 0, cause = 0, ip2_routed = 0, guard;
    SCC_CTRL = 0x00u;                 /* ptr=0 */
    g_n = N; g_sent = 0; g_done = 0;
    SCC_CTRL = 0x01u;                 /* WR0: point to WR1 */
    SCC_CTRL = 0x02u;                 /* WR1 = TxINT_ENAB (bit1) */
    INT3_MAP_MASK0   = 0x20u;         /* unmask Serial-DUART (map src5) */
    INT3_LOCAL0_MASK = 0x80u;         /* unmask MAP_INT0 -> IP2 */

    /* read the masks back to confirm the writes landed (right addr/decode) */
    puts_("\nmask readback: MAP0="); puthex32(INT3_MAP_MASK0);
    puts_(" LOCAL0="); puthex32(INT3_LOCAL0_MASK); putch('\n');

    /* routing probe: with interrupts OFF, wait for Tx-ready, kick a char and poll
     * Cause.IP2 (bit10) to see whether the SCC Tx-IP reaches the CPU at all. */
    while (!(SCC_CTRL & RR0_TX_EMPTY)) { }
    SCC_DATA = '.';
    /* does busy clear again (bit2 re-set)?  busy clears at the SAME cnt==0 event
     * that sets tx_ip, so this proves tx_ip fired -- independent of WR1.TxIE. */
    unsigned int drained = 0;
    for (i = 0; i < 2000000u; i++) {
        if (SCC_CTRL & RR0_TX_EMPTY) { drained = 1; break; }
    }
    puts_("drained(tx_ip fired)="); print_dec(drained); putch('\n');
    for (i = 0; i < 2000000u; i++) {
        __asm__ volatile("mfc0 %0, $13" : "=r"(cause));
        if (cause & (1u << 10)) { ip2_routed = 1; break; }
    }
    puts_("\nIP2 routed = "); print_dec(ip2_routed);
    puts_("  Cause = "); puthex32(cause); putch('\n');

    /* dump the full interrupt chain to see where it breaks:
     * RR3 (gated Tx-IP per chan) -> MAP STATUS (vmeistat=map_src, bit5=SCC) ->
     * LOCAL0 STATUS (bit7=MAP_INT0) -> Cause.IP2 */
    SCC_CTRL = 0x03u;                    /* point to RR3 */
    { unsigned int rr3 = SCC_CTRL, rr0 = SCC_CTRL;
      puts_("  RR3="); puthex32(rr3);
      puts_(" RR0="); puthex32(rr0);
      puts_(" MAPstat="); puthex32(INT3_MAP_STATUS);
      puts_(" LOC0stat="); puthex32(INT3_LOCAL0_STATUS); putch('\n'); }

    /* clear the probe char's Tx-IP, then run interrupt-driven with a guard so a
     * non-firing handler can't hang the test. */
    SCC_CTRL = 0x00u; SCC_CTRL = 0x28u;   /* WR0 = RES_TXP */
    g_sent = 0; g_done = 0;
    while (!(SCC_CTRL & RR0_TX_EMPTY)) { }
    t0 = rd_cycle();
    SCC_DATA = '.'; g_sent = 1u;      /* kick the first char */
    set_status(0x00000401u);          /* IM2 (bit10) | IE (bit0), EXL=0, kernel */
    for (guard = 0; !g_done && guard < 60000000u; guard++) { }
    set_status(0x00000000u);          /* IE off */
    t1 = rd_cycle();
    c_irq = t1 - t0;

    puts_("\nCP0-reg7      cycles = "); print_dec(c_cp7); putch('\n');
    puts_("SCC-Tx-polled cycles = "); print_dec(c_scc); putch('\n');
    puts_("SCC-Tx-IRQ    cycles = "); print_dec(c_irq);
    puts_("  (g_done="); print_dec(g_done);
    puts_(" g_sent="); print_dec(g_sent); puts_(")\n");

    /* let the CP0-$7 console FIFO drain to the host before halting (sim_halt
     * stops the core immediately, which would otherwise lose the last lines). */
    { unsigned int d0 = rd_cycle(); while (rd_cycle() - d0 < 5000000u) { } }

    sim_halt();
    return 0;
}
