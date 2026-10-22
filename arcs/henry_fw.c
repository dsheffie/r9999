/*
 * henry_fw.c  --  C body of the Henry synthetic ARCS/FSBL firmware.
 *
 * The reset vector, the MC early init (MEMCFG / GIO abort-enable), the stack setup
 * and the final jump into the kernel stay in henry_arcs.S -- they run before a usable
 * stack or RAM config exists, or need exact register control.  Everything else lives
 * here: relocating the SPB/romvec block into RAM, the SCC console heartbeat, the
 * station-MAC write, the Newport bring-up, staging argv/envp, and the ARCS firmware
 * callbacks the romvec points at.
 *
 * Freestanding O32, big-endian, -mno-abicalls -fno-pic (absolute addressing; the PROM
 * is linked and loaded at the same address, so no runtime relocation of this code).
 * The SPB/romvec/pvec and argv/envp blobs keep their precise layout in henry_arcs.S;
 * we reference them as externs.
 */

#include "sim.h"

#define ARCS_BB     0x88fff000u                /* runtime base for the argv/envp blob */
#define ARCS_ARGC   8u
#define SPB_VMA     0xA0001000u                /* ARCS SPB block, copied PROM -> RAM   */
#define KENTRY_SLOT 0xBFC00008u                /* driver-patched kernel entry (BE)     */

/* linker- and asm-provided symbols (addresses; _spb_size's value IS the length) */
extern unsigned char _spb_lma[];
extern unsigned char _spb_size[];
extern unsigned char arcs_argv_blob[];
extern unsigned char arcs_argv_blob_end[];
extern unsigned char arcs_argv_arr[];
extern unsigned char arcs_envp_arr[];

/* asm trampoline: a0..a3 already hold argc/argv/envp/entry on the C call */
void jump_kernel(unsigned int argc, char **argv, char **envp, unsigned int entry);
#ifndef NEWPORT_DISABLE
void newport_init(void);                       /* henry_newport.c */
#endif

/* ---- SCC channel A console (the serial heartbeat the real FSBL prints) -------- */
static void scc_putc(char c) {
  volatile unsigned char *stat = (volatile unsigned char *)0xbfbd9830; /* RR0, TxEmpty=0x04 */
  volatile unsigned char *data = (volatile unsigned char *)0xbfbd9837;
  while (((*stat) & 0x04) == 0) { }
  *data = (unsigned char)c;
}
static void scc_puts(const char *s) {
  while (*s) { scc_putc(*s++); }
}

/* ---- FSBL: relocate the SPB/romvec block from the PROM into RAM @ 0xA0001000 --- */
static void fsbl_relocate_spb(void) {
  volatile unsigned int *src = (volatile unsigned int *)_spb_lma;
  volatile unsigned int *dst = (volatile unsigned int *)SPB_VMA;   /* kseg1 uncached */
  unsigned int n = (unsigned int)(unsigned long)_spb_size;
  for (unsigned int i = 0; i < n; i += 4) {
    *dst++ = *src++;
  }
}

/* station MAC 08:00:69:12:34:56 -> ds1386 bbRAM EADDR (one byte per 32-bit word, low
 * byte) so IRIX if_ec reads a valid address.  HPC3 0x1fb80000 + 0x604e8 = 0xbfbe04e8. */
static void fsbl_write_mac(void) {
  volatile unsigned int *p = (volatile unsigned int *)0xbfbe04e8u;
  static const unsigned char mac[6] = { 0x08, 0x00, 0x69, 0x12, 0x34, 0x56 };
  for (int i = 0; i < 6; i++) {
    p[i] = mac[i];
  }
}

void fsbl_main(void) {
  scc_puts("r9999 PROM: CPU alive, handing off to the kernel\n");

  fsbl_relocate_spb();
  fsbl_write_mac();

#ifndef NEWPORT_DISABLE
  newport_init();                              /* probe + program Newport if present */
#endif

  /* stage the argv/envp blob at its runtime base 0x88fff000 */
  {
    unsigned char *s = arcs_argv_blob;
    volatile unsigned char *d = (volatile unsigned char *)ARCS_BB;
    while (s < arcs_argv_blob_end) {
      *d++ = *s++;
    }
  }
  char **argv = (char **)(ARCS_BB + (unsigned int)(arcs_argv_arr - arcs_argv_blob));
  char **envp = (char **)(ARCS_BB + (unsigned int)(arcs_envp_arr - arcs_argv_blob));
  unsigned int entry = *(volatile unsigned int *)KENTRY_SLOT;

  jump_kernel(ARCS_ARGC, argv, envp, entry);   /* a0=argc a1=argv a2=envp -> jr entry */
}

/* ====================================================================
 * ARCS firmware callbacks (O32: args a0..a3, return v0).  The romvec in
 * henry_arcs.S points here; the data they return stays in henry_arcs.S.
 * ==================================================================== */

extern char monitor_str[];                     /* getenv("monitor") -> "h"            */
extern char eaddr_str[];                        /* getenv default    -> the MAC string */
#ifdef SINGLE_USER
extern char single_str[];                        /* getenv("initstate") -> "SINGLE"    */
#endif
extern unsigned int mdesc_ram[];               /* ARCS free-RAM memory descriptor     */
extern unsigned int root_component[];          /* ARCS root component ("SGI-IP22")    */

static inline unsigned int cp0_putchar_full(void) {
  unsigned int v;
  __asm__ volatile("mfc0 %0, $7" : "=r"(v));   /* bit0 = putchar FIFO full */
  return v & 1u;
}

/* LONG Write(handle, buf, len, *cnt): to the CP0 $7 putchar FIFO (the kernel console) */
long stub_write(long handle, const char *buf, unsigned long len, unsigned long *cnt) {
  const unsigned char *b = (const unsigned char *)buf;   /* bytes, not signed chars */
  (void)handle;
  for (unsigned long i = 0; i < len; i++) {
    while (cp0_putchar_full()) { }
    simcon_putchar(b[i]);
  }
  if (cnt) {
    *cnt = len;
  }
  return 0;
}

/* MEMORYDESCRIPTOR *GetMemoryDescriptor(cur): the one free-RAM descriptor, then NULL */
void *stub_mdesc(void *cur) {
  return cur ? (void *)0 : (void *)mdesc_ram;
}

/* char *GetEnvironmentVariable(name): "mon..." -> monitor; (SINGLE_USER) "i..." ->
 * SINGLE; else the eaddr string (etoh parses it, harmless for others). */
char *stub_getenv(const char *name) {
  if (name && name[0] == 'm' && name[1] == 'o' && name[2] == 'n') {
    return monitor_str;
  }
#ifdef SINGLE_USER
  if (name && name[0] == 'i') {
    return single_str;
  }
#endif
  return eaddr_str;
}

/* COMPONENT *GetChild(cur): root for NULL, else NULL */
void *stub_child(void *cur) {
  return cur ? (void *)0 : (void *)root_component;
}

/* COMPONENT *GetPeer(cur): none */
void *stub_peer(void *cur) {
  (void)cur;
  return (void *)0;
}

/* Default: return 0 cleanly */
long stub_default(void) {
  return 0;
}

/* Halt/PowerDown/Restart/Reboot: hit the magic-halt register, then spin */
void stub_halt(void) {
  *(volatile unsigned int *)0xBFD00000u = 1;
  for (;;) { }
}
