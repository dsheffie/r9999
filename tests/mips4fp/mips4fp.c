/* mips4fp.c -- ENABLE_MIPS4 FP arithmetic on ooo_core: gcc emits madd/msub/nmadd/
 * nmsub from a*b+c with -mmadd4 -ffp-contract=fast; the hand-placed cases, recip and
 * rsqrt are in edges.S.  The checksum is printed; co-sim (-c 1) checks every
 * instruction against interpret.cc (unfused madd, 1/sqrt rounded twice). */
#include "sim.h"

extern unsigned fp_edges(void);

#define N 48
static float xs[N], ys[N];
static double xd[N], yd[N];

static void puthex(unsigned v) {
  simcon_puthex32(v);
  simcon_putchar('\n');
}

int main(void) {
  unsigned seed = 4242, sum = 0;
  for(int i = 0; i < N; i++) {
    seed = seed * 1103515245u + 12345u;
    xs[i] = (float)((seed >> 16) & 1023) * 0.0625f + 1.0f;
    xd[i] = (double)((seed >> 8) & 65535) * 0.001953125 + 0.5;
    ys[i] = 0.5f;
    yd[i] = 0.25;
  }
  for(int r = 0; r < 6; r++) {
    for(int i = 1; i < N; i++) {
      ys[i] = xs[i] * ys[i - 1] + xs[i - 1];		/* madd.s */
      yd[i] = yd[i - 1] - xd[i] * xd[(i * 7) % N];	/* nmsub.d / msub.d */
      ys[i] = -(ys[i] * 0.125f + xs[i]);		/* nmadd.s */
    }
  }
  for(int i = 0; i < N; i++) {
    union { float f; unsigned u; } uf; uf.f = ys[i];
    union { double d; unsigned long long u; } ud; ud.d = yd[i];
    sum = (sum << 1 | sum >> 31) ^ uf.u ^ (unsigned)ud.u ^ (unsigned)(ud.u >> 32);
  }
  sum += fp_edges();
  simcon_puts("mips4fp checksum ");
  puthex(sum);
  return 0;
}
