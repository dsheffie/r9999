/*
 * memlat.c -- Henry-SoC bare-metal pointer-chase latency sweep.
 *
 * Same working-set sweep as ~/code/mips-linux-apps/memlat, minus the OS.  The
 * arena is in kseg0 (unmapped, cached), so there are no TLB misses: the
 * plateaus are pure L1D / L2 / DRAM load-to-use.  Nodes are 64B apart (4
 * L1D/L2 lines) and linked as one random cycle (Sattolo), so neither a
 * sequential pattern nor a shared line helps.  Cycles = CP0 $23 (low 32b is
 * plenty for a delta; no libgcc for 64-bit divide here).
 *
 * Run: mips-axi -f memlat.elf --sgi true --arcs henry_arcs.bin --start-pc 0xbfc00000
 */
#include "henry_io.h"

#define NODE_SZ  64
#define LOADS    (1u << 17)
#define ARENA    0x88100000u     /* above the stack, PA 0x08100000 */

static unsigned int g_lcg = 12345;

static unsigned int rnd(void)
{
    g_lcg = g_lcg * 1103515245u + 12345u;
    return g_lcg >> 8;
}

static unsigned int rdcycle(void)
{
    unsigned int c;
    __asm__ volatile("mfc0 %0, $23" : "=r"(c));
    return c;
}

static void putdec(unsigned int v, int width)
{
    char b[12];
    int n = 0;
    do {
        b[n++] = '0' + (v % 10);
        v /= 10;
    } while (v);
    while (width-- > n) {
        putch(' ');
    }
    while (n) {
        putch(b[--n]);
    }
}

static void **build(char *arena, unsigned int bytes)
{
    unsigned int n = bytes / NODE_SZ, i;
    unsigned int *perm = (unsigned int *)(arena + bytes);
    for (i = 0; i < n; i++) {
        perm[i] = i;
    }
    for (i = n - 1; i > 0; i--) {
        unsigned int j = rnd() % i;
        unsigned int t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
    }
    for (i = 0; i < n; i++) {
        *(void **)(arena + perm[i] * NODE_SZ) = (void *)(arena + perm[(i + 1) % n] * NODE_SZ);
    }
    return (void **)arena;
}

static void **chase(void **p, unsigned int iters)
{
    unsigned int i;
    for (i = 0; i < iters; i += 8) {
        p = (void **)*p; p = (void **)*p; p = (void **)*p; p = (void **)*p;
        p = (void **)*p; p = (void **)*p; p = (void **)*p; p = (void **)*p;
    }
    return p;
}

int main(void)
{
    char *arena = (char *)ARENA;
    unsigned int kb, sub, sink = 0;
    puts_("memlat node 64B, 131072 dependent loads per size\n");
    for (kb = 4; kb <= 32768; kb *= 2) {
        for (sub = 0; sub < 2; sub++) {
            unsigned int bytes = kb * 1024 + sub * kb * 512;
            unsigned int n = bytes / NODE_SZ, c0, c1, x100;
            void **p;
            if (kb == 32768 && sub) {
                break;
            }
            p = build(arena, bytes);
            p = chase(p, n < LOADS ? n : LOADS);        /* warm */
            c0 = rdcycle();
            p = chase(p, LOADS);
            c1 = rdcycle();
            sink ^= (unsigned int)p;
            x100 = (c1 - c0) / (LOADS / 100);
            puts_("MEMLAT ");
            putdec(bytes, 9);
            puts_(" bytes ");
            putdec(x100 / 100, 4);
            putch('.');
            putdec((x100 / 10) % 10, 1);
            putdec(x100 % 10, 1);
            puts_(" cyc/load\n");
        }
    }
    puts_("memlat done ");
    puthex32(sink);
    putch('\n');
    return 0;
}
