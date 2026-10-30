/* idxfp.c -- ENABLE_MIPS4 indexed FP loads/stores (lwxc1/ldxc1/swxc1/sdxc1) on
 * ooo_core.  Built -mlxc1-sxc1 so gcc emits them for array accesses with a
 * register index; the cases gcc will not emit are in edges.S.  The checksum is
 * printed; co-sim (-c 1) checks every instruction against interpret.cc. */
#include "sim.h"

extern unsigned edge_cases(void);

#define N 64
static float xs[N], ys[N];
static double xd[N], yd[N];
static int perm[N];

static void puthex(unsigned v) {
  simcon_puthex32(v);
  simcon_putchar('\n');
}

int main(void) {
  unsigned seed = 12345, sum = 0;
  for(int i = 0; i < N; i++) {
    seed = seed * 1103515245u + 12345u;
    xs[i] = (float)(seed >> 20);
    xd[i] = (double)(seed >> 12) * 0.5;
    perm[i] = (int)((seed >> 8) & (N - 1));
  }
  for(int r = 0; r < 4; r++) {
    for(int i = 0; i < N; i++) {
      int j = perm[i];
      ys[j] = xs[i] + xs[j];		/* lwxc1 / swxc1 with a register index */
      yd[i] = xd[j] - yd[perm[j]];	/* ldxc1 / sdxc1 */
    }
    for(int i = 0; i < N; i++) {
      union { float f; unsigned u; } uf; uf.f = ys[i];
      union { double d; unsigned long long u; } ud; ud.d = yd[i];
      sum = (sum << 1 | sum >> 31) ^ uf.u ^ (unsigned)ud.u ^ (unsigned)(ud.u >> 32);
    }
  }
  sum += edge_cases();
  simcon_puts("idxfp checksum ");
  puthex(sum);
  return 0;
}
