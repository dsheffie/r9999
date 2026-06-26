/* Bare-metal load-to-use latency probe, ported from ~/rv64-linux-apps/memlat
 * (the traverse() unrolled pointer-chase).  Small L1D-resident chain so every
 * load is a hit -> the loop time is dominated by load-to-use latency, which is
 * exactly what the L1D skid-buffer bypass (ENABLE_L1D_SKID) shaves a cycle off.
 * ooo_core prints cycle/IPC at halt; run the SAME .elf on ooo_core built with
 * the skid OFF vs ON and compare. */
#include "sim.h"

#define N      64        /* nodes (8B each, mabi=32) -> 512B, fits any L1D */
#define OUTER  8192      /* outer iters; inner unroll 32 -> 262144 dependent loads */

struct node { struct node *next; int pad; };
static struct node nodes[N];

int main(void) {
    int i;
    long it;
    struct node *n;

    /* single permutation cycle 0->1->...->N-1->0 (all dependent loads) */
    for (i = 0; i < N; i++)
        nodes[i].next = &nodes[(i + 1) % N];

    n = &nodes[0];
    for (it = 0; it < OUTER; it++) {
        n = n->next; n = n->next; n = n->next; n = n->next;
        n = n->next; n = n->next; n = n->next; n = n->next;
        n = n->next; n = n->next; n = n->next; n = n->next;
        n = n->next; n = n->next; n = n->next; n = n->next;
        n = n->next; n = n->next; n = n->next; n = n->next;
        n = n->next; n = n->next; n = n->next; n = n->next;
        n = n->next; n = n->next; n = n->next; n = n->next;
        n = n->next; n = n->next; n = n->next; n = n->next;
    }

    /* magic-halt (kseg1 0xBFD00000, NON-ZERO data) -- fold n in to defeat DCE */
    *(volatile unsigned int *)0xBFD00000u = ((unsigned)(unsigned long)n) | 1u;
    while (1) {}
    return 0;
}
