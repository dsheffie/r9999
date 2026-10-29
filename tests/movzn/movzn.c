/* movzn.c -- MIPS IV movn/movz (ENABLE_MIPS4) under co-sim.
 *
 * Built with -march=mips4, so gcc turns the conditional selects below into
 * movn/movz with conditions from loads, compares and arithmetic, often
 * produced by the instruction just before (the zero-flag wakeup path).  The
 * edge cases gcc will not emit are in edges.S.  The checksum is printed;
 * run with ooo_core -c 1 so every retired movn/movz is checked against the
 * interpreter. */
#include "sim.h"

extern unsigned edge_cases(void);

static unsigned lcg(unsigned *s) {
  *s = *s * 1103515245u + 12345u;
  return *s >> 8;
}

static unsigned data[256];

static void puthex(unsigned v) {
  for(int i = 7; i >= 0; i--) {
    unsigned d = (v >> (4*i)) & 15;
    simcon_putchar(d < 10 ? ('0' + d) : ('a' + d - 10));
  }
  simcon_putchar('\n');
}

int main(void) {
  unsigned s = 1, sum = 0;
  /* o32 code assumes Status.FR = 0 (as Linux runs it); crt0 leaves the reset FR=1.
   * FR=0 is where decode's odd-register gate is live (the .fmt cond moves' bit 16
   * is tf / rt, not an odd ft -- the silicon RI this test now covers) */
  {
    unsigned sr;
    __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
    sr &= ~(1u << 26);
    __asm__ volatile("mtc0 %0, $12\n\tnop\n\tnop\n\tnop" : : "r"(sr));
  }
  for(int i = 0; i < 256; i++) {
    unsigned r = lcg(&s);
    /* a quarter of the entries are zero: both arms of every select happen */
    data[i] = (r & 3) ? r : 0;
  }
  for(int it = 0; it < 64; it++) {
    for(int i = 0; i < 255; i++) {
      unsigned a = data[i], b = data[i+1];
      unsigned x = a ? b : sum;		/* load-produced condition */
      unsigned y = (a < b) ? x : a;	/* slt-produced condition */
      unsigned z = (x ^ y) ? y : b;	/* xor-produced condition */
      unsigned w = (z & 1) ? z : x;	/* and-produced condition */
      sum = sum * 31 + (w ? w : 7);
      data[i] = (sum & 7) ? data[i] : 0;
    }
  }
  /* FP selects: gcc -march=mips4 emits movt.s/movf.s (FCC) and movn.d/movz.d (GPR) */
  {
    float fx = 1.0f, fy = 2.0f;
    double dx = 3.0, dy = 4.0;
    for(int it = 0; it < 64; it++) {
      for(int i = 0; i < 255; i++) {
	float a = (float)(data[i] & 255), b = (float)(data[i+1] & 255);
	float m = (a < b) ? a : b;			/* movt.s / movf.s on an FCC */
	fx = (m > fy) ? fx + m : fy - m;
	double d = (data[i] & 1) ? (double)a : dx;	/* movn.d / movz.d on a GPR */
	dx = (d < dy) ? d + 0.5 : dy;
	fy = fy * 0.5f + m;
	dy = dy * 0.25 + d;
      }
    }
    union { float f; unsigned u; } uf; uf.f = fx + fy;
    union { double d; unsigned long long u; } ud; ud.d = dx + dy;
    sum += uf.u ^ (unsigned)ud.u ^ (unsigned)(ud.u >> 32);
  }
  sum += edge_cases();
  simcon_puts("movzn checksum ");
  puthex(sum);
  return 0;
}
