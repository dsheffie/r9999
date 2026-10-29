/* cmov_linux.c -- every MIPS IV conditional move (ENABLE_MIPS4) under Linux.
 * Built with the franken flags (-march=mips4 -mno-branch-likely -mno-madd4
 * -mno-lxc1-sxc1): the integer and float/double selects below become movn/movz,
 * movt.s/movf.s and movn.d/movz.d; edges.S adds int movt/movf and the remaining
 * .fmt forms.  Prints one checksum; a native build (edges stubbed to 85) and the
 * ISS must agree with silicon. */
#include <stdio.h>

extern unsigned edge_cases(void);

static unsigned lcg(unsigned *s) {
  *s = *s * 1103515245u + 12345u;
  return *s >> 8;
}

static unsigned data[256];

int main(void) {
  unsigned s = 1, sum = 0;
  for(int i = 0; i < 256; i++) {
    unsigned r = lcg(&s);
    data[i] = (r & 3) ? r : 0;
  }
  for(int it = 0; it < 4096; it++) {
    for(int i = 0; i < 255; i++) {
      unsigned a = data[i], b = data[i+1];
      unsigned x = a ? b : sum;
      unsigned y = (a < b) ? x : a;
      unsigned z = (x ^ y) ? y : b;
      unsigned w = (z & 1) ? z : x;
      sum = sum * 31 + (w ? w : 7);
      data[i] = (sum & 7) ? data[i] : 0;
    }
  }
  float fx = 1.0f, fy = 2.0f;
  double dx = 3.0, dy = 4.0;
  for(int it = 0; it < 1024; it++) {
    for(int i = 0; i < 255; i++) {
      float a = (float)(data[i] & 255), b = (float)(data[i+1] & 255);
      float m = (a < b) ? a : b;
      fx = (m > fy) ? fx + m : fy - m;
      double d = (data[i] & 1) ? (double)a : dx;
      dx = (d < dy) ? d + 0.5 : dy;
      fy = fy * 0.5f + m;
      dy = dy * 0.25 + d;
    }
  }
  union { float f; unsigned u; } uf; uf.f = fx + fy;
  union { double d; unsigned long long u; } ud; ud.d = dx + dy;
  sum += uf.u ^ (unsigned)ud.u ^ (unsigned)(ud.u >> 32);
  sum += edge_cases();
  printf("cmov checksum %08x\n", sum);
  return 0;
}
