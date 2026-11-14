#ifndef __HENRY_ARCS_H__
#define __HENRY_ARCS_H__
/* The RAM layout henry_arcs.S (the memory descriptor, the FSBL stack, the argv
 * blob's pointers) and henry_fw.c (which copies the blob) must agree on.
 * Override the base / size with ARCS_DEFS (see the Makefile). */

/* Free-RAM descriptor base: reserve the low 16 KiB of main memory (phys
 * 0x08000000..0x08003fff) -- the CPU exception vectors (aliased) and the SPB the FSBL
 * copies to phys 0x1000 live there, below the kernel _text @ 0x08004000. */
#ifndef ARCS_RAM_BASE
#define ARCS_RAM_BASE   0x08004000
#endif
#ifndef ARCS_RAM_SIZE
#define ARCS_RAM_SIZE   0x07ffc000      /* 128 MiB - 16 KiB low-reserved */
#endif

/* The top 64 KiB of RAM holds the FSBL's stack and the argv/envp blob handed to the
 * kernel, and is left out of the free-RAM descriptor (as the low 16 KiB is).  They
 * used to sit at the top of the first 16 MiB (stack below 0x88ffe000, blob at
 * 0x88fff000), inside any kernel image bigger than ~16 MB -- e.g. one with an
 * embedded initramfs -- which the FSBL then overwrote before jumping to it. */
#define ARCS_TOP_RESV   0x10000
#define ARCS_RAM_END    (ARCS_RAM_BASE + ARCS_RAM_SIZE)          /* phys */
#define ARCS_BB_ADDR    (0x80000000 + ARCS_RAM_END - 0x1000)     /* kseg0: argv/envp blob */
#define ARCS_STACK_TOP  (0x80000000 + ARCS_RAM_END - 0x2000)     /* kseg0: FSBL stack top */

#endif
