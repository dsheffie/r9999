/* pt_support.c -- page-table setup for the "real page table" csmith harness.
 *
 * Called once from reset_init (start_csmith_pt.S) on a kseg0 stack, BEFORE the
 * user TLB mapping is active. Two jobs:
 *   1. permute the program's physical data pages (a runtime page swap), so the
 *      scrambled VA->PA mapping needs no LMA!=VMA loader support; and
 *   2. fill g_page_table (read by the asm TLB-refill handler).
 *
 * User data lives in kuseg VA 0x400000.. (PT_NPAGES 4 KB pages, a power of two
 * so XOR is a bijection). VMA page p maps to PA page (p ^ PT_MASK).
 * PT_MASK = 0 gives the 1:1 identity map (use for bring-up); a non-zero mask
 * gives a scrambled non-1:1 map that catches PFN-bit translation bugs.
 */
#include <stdint.h>

#define PT_NPAGES   128u                 /* 512 KB region (matches baremetal_pt.ld) */
#define PT_NVPN2    (PT_NPAGES / 2u)     /* 64 TLB entries (one VPN2 = 2 pages) */
/* 0 = identity (VALIDATED: dynamic refill+eviction, 12/12 seeds match QEMU).
 * non-zero = scrambled non-1:1 -- WIP: the physical page-swap below produces
 * seed-dependent checksum mismatches (NOT a TLB bug: identity dynamic-refill is
 * clean). The swap/scramble path needs debugging before enabling. */
#define PT_MASK     0x00u
#define PT_DATA_PA  0x00400000u          /* user-data physical base */
#define PT_PFN0     (PT_DATA_PA >> 12)   /* 0x400 */
/* kseg1 (unmapped UNCACHED) view of PA 0x400000. The swap must be uncached:
 * the program later reads these pages via the kuseg cached alias, and this L1 is
 * VIPT-with-aliases, so a cached kseg0 swap would leave stale lines incoherent
 * with the kuseg reads (seed-dependent wrong checksums). kseg1 writes go
 * straight to memory; the kuseg cache fills from there. */
#define PT_DATA_K0  0xffffffffa0400000UL
#define PT_LO_FLAGS 0x1fu                /* C=3, D=1, V=1, G=1 */

extern uint64_t g_page_table[PT_NVPN2 * 2];

void pt_setup(void) {
    /* 1. permute physical pages: VMA page p's bytes (loaded contiguously at PA
     *    page p) move to PA page (p ^ PT_MASK). XOR is an involution, so swap
     *    each pair {p, p^MASK} once. */
    if (PT_MASK != 0u) {
        volatile unsigned char *base = (volatile unsigned char *)PT_DATA_K0;
        for (unsigned p = 0; p < PT_NPAGES; p++) {
            unsigned q = p ^ PT_MASK;
            if (p < q) {
                volatile unsigned char *a = base + p * 4096u;
                volatile unsigned char *b = base + q * 4096u;
                for (unsigned k = 0; k < 4096u; k++) {
                    unsigned char t = a[k]; a[k] = b[k]; b[k] = t;
                }
            }
        }
    }

    /* 2. fill the page table: entry i covers VPN2 (0x200+i) = VMA pages
     *    {2i (even), 2i+1 (odd)}; each maps to PA page (page ^ PT_MASK). */
    for (unsigned i = 0; i < PT_NVPN2; i++) {
        unsigned pe = (2u * i)      ^ PT_MASK;
        unsigned po = (2u * i + 1u) ^ PT_MASK;
        g_page_table[2u * i]      = ((uint64_t)(PT_PFN0 + pe) << 6) | PT_LO_FLAGS;
        g_page_table[2u * i + 1u] = ((uint64_t)(PT_PFN0 + po) << 6) | PT_LO_FLAGS;
    }
}
