/*
 * henry_newport.c  --  Newport (XL8/XL24) graphics bring-up for the Henry PROM.
 *
 * On a real IP22 the Boot PROM programs the Newport board during power-on, then the
 * OS uses it.  Linux's newport_con driver relies on that: it programs ONLY the CMAP
 * palette and the VC2 hardware cursor itself, and ASSUMES firmware already set up
 *   - the VC2 video-timing tables (screen size / active-line layout),
 *   - the XMAP9 pixel-mode table (how framebuffer CI words are scanned out),
 *   - the REX3 raster mode  (drawmode1: logic-op = copy, draw into the RGB planes),
 *   - the REX3 CID clip mode (clipmode CIDMATCH = all-pass).
 * henry_arcs jumps straight to /unix and skips all of that, so without this bring-up
 * newport_con sizes the console 0x0 and every glyph it draws is masked away.  We do
 * the minimum firmware init here so the Linux framebuffer console works.
 *
 * Existence is PROBED first (the GFX slot may be empty -- diskless sim, or a Henry
 * build with no graphics); nothing is poked unless the REX3 window answers.  The whole
 * module compiles out under -DNEWPORT_DISABLE (see the Makefile / henry_arcs.S guard).
 *
 * The register values are the validated 1280x1024 high-resolution timing (monitor
 * 'h'), captured by observing a real board's MMIO writes -- used as data, black-box.
 */

#include "sim.h"

#ifndef NEWPORT_DISABLE

/* ---- REX3 register window (kseg1 uncached MMIO) ------------------------------- */
#define REX_BASE        0xbf0f0000u            /* kseg1 of GIO GFX slot 0x1f0f0000 */
#define REX_DRAWMODE1   0x0000u                /* raster mode: logic-op + plane sel  */
#define REX_CLIPMODE    0x1328u                /* screen-mask / CID clip mode        */
#define REX_DCBMODE     0x0238u                /* display-control-bus mode           */
#define REX_DCBDATA0    0x0240u                /* DCB data port (write triggers xfer) */

static inline void rex_w32(unsigned int off, unsigned int v) {
  *(volatile unsigned int *)(REX_BASE + off) = v;
}
static inline unsigned int rex_r32(unsigned int off) {
  return *(volatile unsigned int *)(REX_BASE + off);
}
/* DCB 16-bit data goes to the low short of the data port (byte +2).  The Newport
 * DCB latches the 16-bit RAM word in the opposite byte order from a CPU halfword
 * store, so pre-swap: the word must land in VC2 RAM exactly as the timing table
 * expects (matches the real PROM's DCB writes). */
static inline void rex_dcbdata16(unsigned short v) {
  unsigned int t = (unsigned int)v;
  unsigned short s = (unsigned short)(((t << 8) | (t >> 8)) & 0xffffu);
  *(volatile unsigned short *)(REX_BASE + REX_DCBDATA0 + 2) = s;
}

/* ---- DCB mode fields (hardware bit layout, not vendor code) ------------------- */
#define DCB_W4          0x0u                   /* 4-byte transfer */
#define DCB_W2          0x2u                   /* 2-byte transfer */
#define DCB_W3          0x3u                   /* 3-byte transfer (VC2 index writes) */
#define DCB_ENCRSINC    0x8u                   /* auto-increment the CRS register sel */
#define DCB_CRS(n)      ((unsigned int)(n) << 4)   /* control-register select [6:4] */
#define DCB_SLAVE(n)    ((unsigned int)(n) << 7)   /* slave select          [10:7]  */
/* slaves */
#define DCB_VC2         0u
#define DCB_XMAP_ALL    4u
#define DCB_XMAP0       5u
/* VC2 CRS addresses */
#define VC2_CRS_INDEX   0u                     /* select an indexed VC2 register     */
#define VC2_CRS_RAM     3u                     /* stream the VC2 static RAM          */
/* protocol timing bits the real DCB needs (the model ignores them; kept for HW) */
#define DCB_PROTOCOL    0x00840000u

/* ---- VC2 indexed registers --------------------------------------------------- */
#define VC2_IDX_VIDEO       0x00u              /* video-entry pointer (sizes screen) */
#define VC2_IDX_CENTRY      0x01u              /* cursor-entry pointer               */
#define VC2_IDX_DID         0x05u              /* display-ID entry pointer           */
#define VC2_IDX_SCANLEN     0x06u              /* scanline length                    */
#define VC2_IDX_RADDR       0x07u              /* RAM address (for RAM streaming)    */
#define VC2_IDX_DISPCTL     0x10u              /* display control                    */
#define VC2_IDX_CONFIG      0x1fu              /* configuration                      */

static void vc2_set(unsigned int idx, unsigned int val) {
  rex_w32(REX_DCBMODE, DCB_SLAVE(DCB_VC2) | DCB_CRS(VC2_CRS_INDEX) | DCB_W3 |
                       DCB_ENCRSINC | DCB_PROTOCOL);
  rex_w32(REX_DCBDATA0, (idx << 24) | (val << 8));
}

/* stream `n` 16-bit words into VC2 static RAM starting at word address `start` */
static void vc2_ram(unsigned int start, const unsigned short *data, unsigned int n) {
  vc2_set(VC2_IDX_RADDR, start);
  rex_w32(REX_DCBMODE, DCB_SLAVE(DCB_VC2) | DCB_CRS(VC2_CRS_RAM) | DCB_W2 | DCB_PROTOCOL);
  for (unsigned int i = 0; i < n; i++) {
    rex_dcbdata16(data[i]);
  }
}

/* ---- XMAP9 ------------------------------------------------------------------- */
#define XMAP_CRS_CONFIG   0u
#define XMAP_CRS_MODETBL  5u                   /* write mode[idx] = (idx<<24)|mode24 */

static void xmap_write(unsigned int crs, unsigned int d) {
  rex_w32(REX_DCBMODE, DCB_SLAVE(DCB_XMAP_ALL) | DCB_CRS(crs) | DCB_W4 | DCB_PROTOCOL);
  rex_w32(REX_DCBDATA0, d);
}

/* ---- 1280x1024 high-res VC2 tables (validated capture, monitor 'h') ---------- */

/* video-timing state microcode @ RAM 0x000: run-length sequences the VC2 walks to
 * decide active vs blank scanlines and horizontal column counts (1280 across). */
static const unsigned short vc2_state[] = {
  0x3f0c, 0xaf52, 0x9f03, 0x1f39, 0xa352, 0xbf03, 0x3f54, 0xaf52,
  0x3f7f, 0xaf53, 0xbf7f, 0xbf7f, 0xbf7f, 0xbf7f, 0xbfaf, 0x0000,
  0x3f0c, 0xaf7a, 0x9f03, 0x1f39, 0xa37a, 0xbf03, 0x3f54, 0xaf7a,
  0x3f7f, 0xaf7b, 0xbf7f, 0xbf7f, 0xbf7f, 0xbf7f, 0xbfaf, 0x1000,
  0x1f0f, 0xa578, 0x1f3c, 0xa178, 0x1f54, 0xa578, 0x1f7f, 0xa579,
  0x9f7f, 0x9f7f, 0x9f7f, 0x9f7f, 0x9faf, 0x2000, 0x3f0c, 0xaf3a,
  0x9f03, 0x1f39, 0xa33a, 0xbf03, 0x3f54, 0xaf3a, 0x3f7f, 0xaf3b,
  0xbf7f, 0xbf7f, 0xbf7f, 0xbf7f, 0xbfaf, 0x2e00, 0x3f0c, 0xaf7a,
  0x9f03, 0x1f39, 0xa37a, 0xbf03, 0x3f54, 0xaf7a, 0x3f0c, 0xaf7b,
  0xbd7f, 0xbd7f, 0xbd7f, 0xbd7f, 0xbd7f, 0xbd18, 0xbf8b, 0x3e00,
  0x2f04, 0xbf7a, 0xbf08, 0x9f03, 0x1f39, 0xb37a, 0xbf03, 0x3f53,
  0xbf7a, 0xb701, 0x370c, 0xbf7b, 0xb512, 0xb001, 0x3007, 0xff7f,
  0xf07f, 0xf07f, 0xf07f, 0xf07f, 0xf07d, 0xf301, 0x7b8a, 0xbfff,
  0x5000, 0x2f04, 0xbf7a, 0xbf08, 0x9f03, 0x1f39, 0xb37a, 0xbf03,
  0x3f53, 0xbf7a, 0xb701, 0x370c, 0xbf7b, 0xb512, 0xb001, 0x3007,
  0xff7f, 0xf07f, 0xf07f, 0xf07f, 0xf07f, 0xf077, 0x7006, 0xfe7f,
  0xf301, 0x7b8a, 0xbeff, 0x6900,
};

/* video-entry table @ RAM 0x400: (state-pointer, line-run) pairs the size walk
 * follows from VC2_IDX_VIDEO; the active run totals 1024 lines (y 41..1064). */
static const unsigned short vc2_ventry[] = {
  0x0000, 0x0100, 0x1000, 0x0200, 0x2000, 0x0300, 0x1000, 0x0300,
  0x2e00, 0x0100, 0x3e00, 0x1f00, 0x5000, 0xff03, 0x6900, 0x0100,
};

/* hardware-cursor glyph/colour tables @ RAM 0x500 (newport_con repositions it) */
static const unsigned short vc2_cursor[] = {
  0x0000, 0x0000, 0x0010, 0x0000, 0x0018, 0x0000, 0x001c, 0x0000,
  0x001e, 0x0000, 0x001f, 0x0000, 0x801f, 0x0000, 0xc01f, 0x0000,
  0xe01f, 0x0000, 0x001f, 0x0000, 0x001b, 0x0000, 0x8011, 0x0000,
  0x8001, 0x0000, 0xc000, 0x0000, 0xc000, 0x0000, 0x0000, 0x0000,
  0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
  0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
  0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
  0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
  0x0030, 0x0000, 0x0028, 0x0000, 0x0024, 0x0000, 0x0022, 0x0000,
  0x0021, 0x0000, 0x8020, 0x0000, 0x4020, 0x0000, 0x2020, 0x0000,
  0x1020, 0x0000, 0xf020, 0x0000, 0x8024, 0x0000, 0x402a, 0x0000,
  0x4032, 0x0000, 0x2001, 0x0000, 0x2001, 0x0000, 0xe000, 0x0000,
};

#define VC2_DID_BASE    0x0600u                /* per-scanline display-ID table      */
#define VC2_DID_LINES   1024u
#define VC2_DID_VALUE   0x0010u                /* every line -> XMAP mode-table slot 0x10 */

#define XMAP_CONFIG     0x05u                  /* 8bpp CI framebuffer                 */
#define XMAP_MODE       0x000400u             /* pix_mode=CI, pix_size=8bpp          */
#define REX3_DRAWMODE1  0x30007109u           /* logic-op SRC | RGB planes | 8bpp    */
#define REX3_CLIPMODE   0x00001e00u           /* CIDMATCH = 0xf (all pixels pass)    */

static void scc_putc(char c) {
  volatile unsigned char *stat = (volatile unsigned char *)0xbfbd9830;  /* RR0, TxEmpty=0x04 */
  volatile unsigned char *data = (volatile unsigned char *)0xbfbd9837;
  while (((*stat) & 0x04) == 0) { }
  *data = (unsigned char)c;
}
static void scc_puts(const char *s) {
  while (*s) { scc_putc(*s++); }
}

/* probe: the GFX-slot REX3 window answers with a non-zero power-on register value
 * when a board is present; an empty slot in the sim reads back 0.  (A Henry build
 * with no graphics uses -DNEWPORT_DISABLE and never gets here.) */
static int newport_present(void) {
  return rex_r32(REX_DRAWMODE1) != 0u;
}

void newport_init(void) {
  if (!newport_present()) {
    return;
  }
  scc_puts("Newport found\n");

  /* VC2 static RAM: timing microcode, video-entry, cursor, and the per-line DID */
  vc2_ram(0x000, vc2_state,  sizeof(vc2_state)  / sizeof(vc2_state[0]));
  vc2_ram(0x400, vc2_ventry, sizeof(vc2_ventry) / sizeof(vc2_ventry[0]));
  vc2_ram(0x500, vc2_cursor, sizeof(vc2_cursor) / sizeof(vc2_cursor[0]));
  vc2_set(VC2_IDX_RADDR, VC2_DID_BASE);
  rex_w32(REX_DCBMODE, DCB_SLAVE(DCB_VC2) | DCB_CRS(VC2_CRS_RAM) | DCB_W2 | DCB_PROTOCOL);
  for (unsigned int i = 0; i < VC2_DID_LINES; i++) {
    rex_dcbdata16(VC2_DID_VALUE);
  }

  /* VC2 indexed registers; program VIDEO last -- it triggers the screen-size walk */
  vc2_set(VC2_IDX_CENTRY,  0x0500);
  vc2_set(VC2_IDX_DID,     VC2_DID_BASE);
  vc2_set(VC2_IDX_SCANLEN, 0xa080);
  vc2_set(VC2_IDX_DISPCTL, 0x009f);
  vc2_set(VC2_IDX_CONFIG,  0x0001);
  vc2_set(VC2_IDX_VIDEO,   0x0400);

  /* XMAP9: 8bpp CI scanout for every DID slot the console uses */
  xmap_write(XMAP_CRS_CONFIG, XMAP_CONFIG);
  for (unsigned int i = 0; i < 0x20; i++) {
    xmap_write(XMAP_CRS_MODETBL, (i << 24) | XMAP_MODE);
  }

  /* REX3 raster state newport_con leaves to firmware */
  rex_w32(REX_DRAWMODE1, REX3_DRAWMODE1);
  rex_w32(REX_CLIPMODE,  REX3_CLIPMODE);
}

#endif /* !NEWPORT_DISABLE */
