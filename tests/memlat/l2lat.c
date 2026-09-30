/* L2-hit latency probe (and LSU liveness regression -- see below): 16B nodes (one L1D line each) over 32KB -- 8x the 4KB
 * direct-mapped L1D, well inside the 128KB L2 -- linked with a large stride so
 * consecutive nodes map to different L1D sets.  After one warm-up lap every
 * dependent load is an L1D miss that hits the L2.
 *
 * Regression: the magic-halt store below (uncached kseg1) sits on the
 * not-taken path of the loop branch, so it is fetched and issued
 * speculatively while the chase loads are still blocking and replaying.  A
 * uncached op that waits for the ROB head INSIDE the in-order exec->l1d
 * request FIFO deadlocks an older load queued behind it ("no retire in 65537
 * cycles"); uncached LSU ops must answer BLK_UNCACHEABLE instead. */
#include "sim.h"

#define N      2048      /* nodes x 16B = 32KB */
#define STRIDE 257       /* odd => one cycle through all N; spreads the sets */
#define LAPS   8

struct node { struct node *next; int pad[3]; };
static struct node nodes[N];

int main(void) {
    int i;
    long it;
    struct node *n;
    for (i = 0; i < N; i++) {
        nodes[i].next = &nodes[(i + STRIDE) % N];
    }
    n = &nodes[0];
    for (it = 0; it < (long)N * LAPS / 8; it++) {
        n = n->next; n = n->next; n = n->next; n = n->next;
        n = n->next; n = n->next; n = n->next; n = n->next;
    }
    *(volatile unsigned int *)0xBFD00000u = ((unsigned)(unsigned long)n) | 1u;
    while (1) {}
    return 0;
}
