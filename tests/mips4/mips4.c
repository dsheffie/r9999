/* mips4.c -- the MIPS IV instructions r9999's RTL does not implement, on the
 * interpreter alone (iss_mips4, built with -DISS_FULL_MIPS4): COP1X indexed FP
 * loads/stores and prefx, madd/msub/nmadd/nmsub.fmt, recip/rsqrt.fmt.
 *
 * Self-checking: each instruction (inline asm) is compared bit for bit with the
 * same value computed from MIPS III ops.  MIPS IV madd is NOT fused (the product
 * is rounded first), so mul + add is the exact reference; this file is built
 * with -ffp-contract=off so gcc does not turn the reference into madd itself.
 * recip/rsqrt are checked against 1/x and 1/sqrt(x) (the ISS computes them
 * exactly; hardware may be less accurate).  Runs with FR=0, as o32 Linux does. */
#include "sim.h"

static void puts_(const char *p) {
  while(*p) {
    simcon_putchar(*p++);
  }
}

static void puthex(unsigned v) {
  for(int i = 7; i >= 0; i--) {
    unsigned d = (v >> (4*i)) & 15;
    simcon_putchar(d < 10 ? ('0' + d) : ('a' + d - 10));
  }
}

static unsigned fails, checks;

static void check(const char *what, int i, unsigned long long got, unsigned long long exp) {
  checks++;
  if(got != exp) {
    fails++;
    puts_("FAIL ");
    puts_(what);
    puts_(" i=");
    puthex(i);
    puts_(" got ");
    puthex(got >> 32); puthex(got);
    puts_(" exp ");
    puthex(exp >> 32); puthex(exp);
    simcon_putchar('\n');
  }
}

typedef union { double d; unsigned long long u; } du_t;
typedef union { float f; unsigned u; } fu_t;

static double dv[8] = { 1.5, -3.25, 1e300, 1e-300, 0.1, -0.0, 3.0, 7.0 };
static float  fv[8] = { 1.5f, -3.25f, 1e30f, 1e-30f, 0.1f, -0.0f, 3.0f, 7.0f };

#define MADD_D(op, fd, fr, fs, ft) \
  __asm__(op " %0, %1, %2, %3" : "=f"(fd) : "f"(fr), "f"(fs), "f"(ft))

static void test_fma(void) {
  for(int i = 0; i < 8; i++) {
    for(int j = 0; j < 8; j++) {
      for(int k = 0; k < 8; k++) {
        double a = dv[i], b = dv[j], c = dv[k], p = a * b, r;
        du_t g, e;
        MADD_D("madd.d", r, c, a, b);  g.d = r; e.d = p + c;    check("madd.d", i*64+j*8+k, g.u, e.u);
        MADD_D("msub.d", r, c, a, b);  g.d = r; e.d = p - c;    check("msub.d", i*64+j*8+k, g.u, e.u);
        MADD_D("nmadd.d", r, c, a, b); g.d = r; e.d = -(p + c); check("nmadd.d", i*64+j*8+k, g.u, e.u);
        MADD_D("nmsub.d", r, c, a, b); g.d = r; e.d = -(p - c); check("nmsub.d", i*64+j*8+k, g.u, e.u);
        float fa = fv[i], fb = fv[j], fc = fv[k], fp = fa * fb, fr;
        fu_t fg, fe;
        MADD_D("madd.s", fr, fc, fa, fb);  fg.f = fr; fe.f = fp + fc;    check("madd.s", i*64+j*8+k, fg.u, fe.u);
        MADD_D("msub.s", fr, fc, fa, fb);  fg.f = fr; fe.f = fp - fc;    check("msub.s", i*64+j*8+k, fg.u, fe.u);
        MADD_D("nmadd.s", fr, fc, fa, fb); fg.f = fr; fe.f = -(fp + fc); check("nmadd.s", i*64+j*8+k, fg.u, fe.u);
        MADD_D("nmsub.s", fr, fc, fa, fb); fg.f = fr; fe.f = -(fp - fc); check("nmsub.s", i*64+j*8+k, fg.u, fe.u);
      }
    }
  }
  /* rounding: x = 1 + 2^-12, x*x = 1 + 2^-11 + 2^-24; the 2^-24 is a rounding
   * tie in single, so unfused msub gives 2^-11 and a fused one 2^-11 + 2^-24 */
  {
    fu_t x, g, e;
    float r, one = 1.0f;
    x.u = 0x3f800800u;
    MADD_D("msub.s", r, one, x.f, x.f);
    g.f = r;
    e.f = x.f * x.f - one;
    check("msub.s-unfused", 0, g.u, e.u);
  }
}

static void test_recip(void) {
  for(int i = 0; i < 8; i++) {
    double x = dv[i] < 0 ? -dv[i] : dv[i], r;
    du_t g, e;
    if(x == 0.0) {
      continue;
    }
    __asm__("recip.d %0, %1" : "=f"(r) : "f"(x)); g.d = r; e.d = 1.0 / x;           check("recip.d", i, g.u, e.u);
    __asm__("rsqrt.d %0, %1" : "=f"(r) : "f"(x)); g.d = r; e.d = 1.0 / __builtin_sqrt(x); check("rsqrt.d", i, g.u, e.u);
    float fx = (float)x, fr;
    fu_t fg, fe;
    __asm__("recip.s %0, %1" : "=f"(fr) : "f"(fx)); fg.f = fr; fe.f = 1.0f / fx; check("recip.s", i, fg.u, fe.u);
    __asm__("rsqrt.s %0, %1" : "=f"(fr) : "f"(fx)); fg.f = fr; fe.f = 1.0f / __builtin_sqrtf(fx); check("rsqrt.s", i, fg.u, fe.u);
  }
}

static unsigned wsrc[8] = { 0x11111111, 0x22222222, 0xdeadbeef, 0x3f800000, 0, 0xffffffff, 0x80000000, 0x7f7fffff };
static unsigned wdst[8];
static unsigned long long dsrc[4] = { 0x0123456789abcdefull, 0x3ff0000000000000ull, 0xfedcba9876543210ull, 0 };
static unsigned long long ddst[4];

static void test_indexed(void) {
  for(int i = 0; i < 8; i++) {
    unsigned off = i * 4, v;
    /* lwxc1 to an even and an odd register (FR=0: the odd one is the high half of
     * the even pair), back out with swc1 / swxc1 */
    __asm__ volatile("lwxc1 $f2, %1(%2)\n\tswc1 $f2, 0(%3)\n\tlw %0, 0(%3)"
                     : "=r"(v) : "r"(off), "r"(wsrc), "r"(wdst) : "$f2", "memory");
    check("lwxc1-even", i, v, wsrc[i]);
    __asm__ volatile(".set push\n\t.set oddspreg\n\t" "lwxc1 $f3, %1(%2)\n\tswc1 $f3, 0(%3)\n\tlw %0, 0(%3)" "\n\t.set pop"
                     : "=r"(v) : "r"(off), "r"(wsrc), "r"(wdst) : "$f3", "memory");
    check("lwxc1-odd", i, v, wsrc[i]);
    __asm__ volatile(".set push\n\t.set oddspreg\n\t" "lwc1 $f5, 0(%0)\n\tswxc1 $f5, %1(%2)" "\n\t.set pop"
                     : : "r"(&wsrc[i]), "r"(off), "r"(wdst) : "$f5", "memory");
    check("swxc1-odd", i, wdst[i], wsrc[i]);
    __asm__ volatile("lwc1 $f4, 0(%0)\n\tswxc1 $f4, %1(%2)"
                     : : "r"(&wsrc[7-i]), "r"(off), "r"(wdst) : "$f4", "memory");
    check("swxc1-even", i, wdst[i], wsrc[7-i]);
  }
  for(int i = 0; i < 4; i++) {
    unsigned off = i * 8;
    __asm__ volatile("ldxc1 $f6, %0(%1)\n\tsdxc1 $f6, %0(%2)\n\tprefx 0, %0(%1)"
                     : : "r"(off), "r"(dsrc), "r"(ddst) : "$f6", "memory");
    check("ldxc1/sdxc1", i, ddst[i], dsrc[i]);
  }
  /* index and base swapped, negative index */
  {
    unsigned v;
    int neg = -8;
    __asm__ volatile("lwxc1 $f8, %1(%2)\n\tmfc1 %0, $f8"
                     : "=r"(v) : "r"(neg), "r"(&wsrc[4]) : "$f8");
    check("lwxc1-negidx", 0, v, wsrc[2]);
  }
}

int main(void) {
  {
    unsigned sr;
    __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
    sr &= ~(1u << 26);   /* FR=0, as o32 Linux runs */
    __asm__ volatile("mtc0 %0, $12\n\tnop\n\tnop\n\tnop" : : "r"(sr));
  }
  test_fma();
  test_recip();
  test_indexed();
  puts_("mips4 checks ");
  puthex(checks);
  puts_(" fails ");
  puthex(fails);
  simcon_putchar('\n');
  return 0;
}
