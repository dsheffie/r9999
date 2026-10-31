#include "sgi_hpc.hh"
#include "interpret.hh"
#include "sgi_scsi.hh"
#include "sgi_seeq.hh"
#include "sgi_scc.hh"
#include "sgi_newport.hh"
#include "sgi_ps2.hh"
#include "sgi_mc.hh"
#include "cache_model.hh"
#include "sclog.hh"
#include "globals.hh"

static sgi_scsi *ip28_scsi1(state_t *s);   /* --ip28 second WD33C93, below */
#include <cassert>
#include <cstdlib>
#include <ctime>

/* device-trace spew is off by default (it floods the console stream and slows the
 * boot to a crawl); set DEVTRACE=1 to re-enable. */
static const bool dev_verbose = getenv("DEVTRACE") != nullptr;
#define DPRINTF(...) do { if(dev_verbose) fprintf(stderr, __VA_ARGS__); } while(0)

/* RTC time source. Default: the live host wall-clock. Deterministic-time mode
 * (DETTIME env -- set on BOTH interp_mips and the JIT sim for reproducible
 * lockstep co-sim): a fixed plausible epoch advanced by retired-instruction
 * count, so the DS1286 clock is identical run-to-run instead of reading
 * ::time(nullptr). The base + rate must match the JIT sim's rtc_now exactly. */
static time_t rtc_now(state_t *s) {
  static const bool det = getenv("DETTIME") != nullptr;
  if(det) {
    static const time_t   DETTIME_BASE = 1717200000;     /* 2024-06-01 00:00:00 UTC */
    static const uint64_t DETTIME_RATE = 100000000ull;   /* ~100 M retired insns / simulated sec */
    return DETTIME_BASE + (time_t)(s->icnt / DETTIME_RATE);
  }
  return ::time(nullptr);
}

/* hundredths of a second for the DS1386 clock (same time source as rtc_now);
 * the SGI PROM polls it to check that the oscillator runs */
static uint32_t rtc_hundredths(state_t *s) {
  static const bool det = getenv("DETTIME") != nullptr;
  if(det) {
    return (uint32_t)((s->icnt / 1000000ull) % 100);   /* DETTIME_RATE / 100 */
  }
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (uint32_t)(ts.tv_nsec / 10000000);
}

/*
 * HPC3 (High Performance Peripheral Controller, 3rd gen) register map.
 *
 * The Indy has two HPC3 chips; the "first" one (which carries the boot PROM,
 * SCSI, ethernet, serial EEPROM and PBUS peripherals) is based at physical
 * 0x1fb80000. `offs` here is the byte offset into that window, i.e.
 * pa - 0x1fb80000 (see sgi_indy.hh hpc_regs range).
 *
 * Region map (offset = spec address - 0x1fb80000). Cross-checked against the
 * HPC3 chip spec (indy_docs/hpc3.pdf), Linux arch/mips/include/asm/sgi/hpc3.h,
 * and NetBSD arch/sgimips/hpc/hpcreg.h:
 *
 *   0x00000..0x0ffff  PBUS DMA channel registers (8 channels: bp/dp/ctrl)
 *   0x10000..0x1ffff  HD0/HD1/ENET DMA channel registers
 *   0x20000..0x2ffff  FIFO access ports
 *   0x30000..0x3ffff  General registers (see below)
 *   0x40000..0x47fff  HD0 (SCSI channel 0, WD33C93) device registers
 *   0x48000..0x4ffff  HD1 (SCSI channel 1) device registers
 *   0x50000..0x57fff  ENET (Seeq 8003) device registers
 *   0x58000..0x5ffff  PBUS device registers (PIO data + DMA/PIO config)
 *   0x60000..0x7ffff  Battery-backed SRAM (NVRAM)
 *
 * General registers (0x30000 block), per NetBSD/Linux ordering:
 *   0x30000  istat0    interrupt status, bits [4:0] reliable
 *   0x30004  gio_misc  GIO misc control ("misc")
 *   0x3000b  eeprom    serial EEPROM data register (byte; NMC93CS56)
 *   0x3000c  istat1    interrupt status, bits [9:5] reliable
 *   0x30010  bestat    GIO64 bus-error interrupt status
 *
 * PBUS device sub-decode within 0x58000..0x5ffff (id = (offs>>8)&mask):
 *   0x58000..0x5bfff  per-channel PIO data ports
 *   0x5c000..0x5cfff  PBUS DMA channel config (8 channels)
 *   0x5d000..0x5dfff  PBUS PIO channel config (10 channels)
 */

/* i8254 counter 2 counts DOWN at the chip's 1 MHz against CP0 Count (which we
 * tick once per retired insn).  dosample() (ip22-time.c) derives the CPU clock
 * from Delta(c0_count) / (counter2 ticks at SGINT_TIMER_CLOCK=1MHz), so the
 * reported mips_hpt_frequency = 1e6 * RATIO and reported CPU = 2 * RATIO MHz.
 * RATIO=50 -> 100 MHz, matching the Ultra96 r9999 FPGA core clock. */
static const uint32_t T2_RATIO = 50;
/* --ip28: counters 0 and 1 count counter 2's output, not the 1 MHz clock: startrtclock
 * loads counter 2 with 200 and counter 0 with 50 -> 1 MHz / 200 / 50 = 100 Hz */
uint32_t sgi_hpc::pit_period(uint16_t load) const {
  const uint64_t n0 = load ? load : 0x10000u;
  const uint64_t n2 = t2_load ? t2_load : 0x10000u;
  const uint64_t p = n0 * n2 * T2_RATIO;
  return (p < (1u << 30)) ? (uint32_t)p : (1u << 30);
}

bool sgi_hpc::pit_irq(int n) {
  pit_counter_t &c = pit[n];
  if(c.armed) {
    const uint32_t now = s->cpr0[CPR0_COUNT];
    if((int32_t)(now - c.next_fire) >= 0) {
      c.irq = true;
      c.period = pit_period(c.load);  /* counter 2 (the prescaler) may have been reloaded */
      do {                          /* missed terminal counts collapse into one */
        c.next_fire += c.period;
      } while((int32_t)(now - c.next_fire) >= 0);
    }
  }
  return c.irq;
}

uint16_t sgi_hpc::t2_value() {
  uint32_t elapsed = (uint32_t)(s->cpr0[CPR0_COUNT] - t2_count_at_load);
  uint32_t dec = elapsed / T2_RATIO;
  if(dec >= t2_load) return 0;       /* counted down to (or past) zero */
  return (uint16_t)(t2_load - dec);
}

/* read a big-endian 32-bit word from physical DRAM (descriptors are stored in
 * guest big-endian byte order; sparse_mem holds raw guest bytes). */
static inline uint32_t rd_be32(state_t *s, uint32_t pa) {
  uint8_t *p = s->mem.get_raw_ptr(pa);
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static inline void wr_be32(state_t *s, uint32_t pa, uint32_t v) {
  uint8_t *p = s->mem.get_raw_ptr(pa);
  p[0] = (v >> 24) & 0xff; p[1] = (v >> 16) & 0xff; p[2] = (v >> 8) & 0xff; p[3] = v & 0xff;
  sgi_dma_wrote(s, pa, 4);
}

void sgi_hpc::scsi_fetch_chain(int ch) {
  scsi_dma_t &d = scsi_dma[ch];
  uint32_t desc = d.nbdp;
  d.cbp   = rd_be32(s, desc);
  d.bc    = rd_be32(s, desc + 4);
  d.nbdp  = rd_be32(s, desc + 8);
  d.count = d.bc & 0x3fff;
  sclog(d.to_device ? 3 : 2, s->icnt, d.cbp, d.count, (uint32_t)s->pc, 0);
  static const bool dbg = getenv("SCSIDBG") != nullptr;
  if(dbg) fprintf(stderr, "sgi_hpc: ch%d FETCH desc=%08x cbp=%08x bc=%08x count=%u next=%08x %s%s\n",
                  ch, desc, d.cbp, d.bc, d.count, d.nbdp,
                  (d.bc & 0x80000000u) ? "EOX " : "", (d.bc & 0x20000000u) ? "XIE" : "");
}

/* Descriptor-walk FSM, pumped while it can make progress.  CH_XFER drains the
 * current descriptor against the WD33C93 byte-port until count==0 or DRQ drops
 * (data exhausted on the device side); CH_DESC_DONE handles XIE/EOX and either
 * advances to the next descriptor or deactivates the channel. */
void sgi_hpc::scsi_run_dma(int ch) {
  scsi_dma_t &d = scsi_dma[ch];
  bool progress = true;
  while(d.active && progress) {
    progress = false;
    switch(d.state) {
    case CH_IDLE:
      break;
    case CH_FETCH:
      scsi_fetch_chain(ch);
      d.state = CH_XFER;
      progress = true;
      break;
    case CH_XFER:
      while(d.count != 0 && s->scsi && s->scsi->drq_pending()) {
        uint8_t *p = s->mem.get_raw_ptr(d.cbp);
        if(d.to_device) {
          s->scsi->dma_w(*p);
        } else {
          /* SPEC_DMA: model r9999 OOO speculation -- pull this DMA-target line
           * into cache (PRE-DMA DRAM contents) before the DMA overwrites DRAM,
           * so a stale speculative copy exists that IRIX never invalidates. */
          static const bool g_spec = getenv("SPEC_DMA") != nullptr;
          if(g_spec && g_cmodel) { g_cmodel->spec_fill((uint32_t)d.cbp); }
          *p = s->scsi->dma_r();                                   /* DMA -> DRAM (post-DMA) */
          sgi_dma_wrote(s, d.cbp, 1);
          /* COHERENT_DMA: the fix -- snoop-invalidate the written line so the
           * stale speculative copy cannot survive to the next CPU read. */
          static const bool g_coh = getenv("COHERENT_DMA") != nullptr;
          if(g_coh && g_cmodel) { g_cmodel->snoop_inval((uint32_t)d.cbp); }
        }
        // WATCHLINE: at the DMA write of the crash line, is that line currently
        // RESIDENT in the CPU cache?  resident => the CPU architecturally cached
        // it before this DMA (page-recycling, reproducible in-order); never
        // resident => it can only get stale via OOO speculation (unreachable here).
        { static const bool g_wl = getenv("WATCHLINE") != nullptr;
          if(g_wl && !d.to_device && g_cmodel &&
             ((uint32_t)d.cbp & ~(cache_model::L1_LINE - 1)) == cache_model::WATCH_LINE) {
            cache_model::presence pr = g_cmodel->probe((uint32_t)d.cbp);
            fprintf(stderr, "[wl-dma] icnt=%llu pa=%08x wrote=%02x resident=%d dirty=%d %s\n",
                    (unsigned long long)s->icnt, (uint32_t)d.cbp, *p, pr.resident, pr.dirty,
                    pr.resident ? "(RECYCLING: cached before DMA)" : "(not cached -> needs speculation)"); }
        }
        // WATCHDMA: catch the DMA landing the /sbin/sh .data pointer 0x0e07bbc0 (big-endian
        // 0e 07 bb c0) into DRAM -> pins physical(0x0e0981c4) + confirms it is DMA-paged-in.
        { static const bool g_wdma = getenv("WATCHDMA") != nullptr;
          if(g_wdma && !d.to_device && *p == 0xc0u && d.cbp >= 3) {
            uint8_t *q = s->mem.get_raw_ptr(d.cbp - 3);
            if(q[0]==0x0eu && q[1]==0x07u && q[2]==0xbbu && q[3]==0xc0u)
              fprintf(stderr, "[dma-wr-c0] pa=%09llx icnt=%llu\n",
                      (unsigned long long)(d.cbp - 3), (unsigned long long)s->icnt); }
        }
        d.cbp++; d.count--;
      }
      if(d.count == 0) { d.state = CH_DESC_DONE; progress = true; }
      break;  /* else DRQ dropped mid-descriptor: wait for the next DRQ */
    case CH_DESC_DONE:
      if(d.bc & 0x20000000u) intstat |= (0x100u << ch);    /* XIE -> SCSI channel IRQ */
      if(d.bc & 0x80000000u) {                              /* EOX -> deactivate */
        /* Chunked transfer: IRIX programs the WD33C93 transfer count (and this
         * DMA chain) for fewer bytes than the SCSI command's full length, then
         * resumes with a fresh chain + SEL_ATN_XFER. If the device data-in buffer
         * isn't fully drained when the chain ends (EOX), post a transfer-paused
         * interrupt so IRIX continues, rather than stalling with no INTRQ. */
        if(s->scsi && s->scsi->residual() > 0) s->scsi->pause_transfer();
        d.active = false; d.ctrl &= ~0x10u; d.state = CH_IDLE;
      } else {
        d.state = CH_FETCH;
      }
      progress = true;
      break;
    }
  }
}

/* HPC3 ENET descriptor-walk against the Seeq 8003 (ch0 = RX device->mem,
 * ch1 = TX mem->device).  Mirrors scsi_run_dma; the Seeq replaces the WD33C93.
 * TX drains the whole chain into a frame then transmits at EOX; RX writes a
 * staged [pad][frame][status] byte stream into the buffer until it's consumed. */
/* HPCDMA descriptor cntinfo bits (asm/sgi/hpc3.h) */
static const uint32_t HPCDMA_EOX  = 0x80000000u;  /* tx: end of chain */
static const uint32_t HPCDMA_EOR  = 0x80000000u;  /* rx: end of ring */
static const uint32_t HPCDMA_XIE  = 0x20000000u;  /* irq at end of this desc */
static const uint32_t HPCDMA_ETXD = 0x00008000u;  /* set by HPC when packet tx'd */
static const uint32_t HPCDMA_OWN  = 0x00004000u;  /* rx: HPC owns the buffer */
static const uint32_t HPCDMA_BCNT = 0x00003fffu;  /* buffer byte count */

/* Deferred-TX experiment knobs (default 0 = the original synchronous model, so the
 * co-sim golden path is unchanged).  ENET_TX_LATENCY=n makes the TX channel process
 * one descriptor per enet_poll() tick and hold ch_active for n more ticks after EOX,
 * modelling the Seeq's wire time.  Only then can the guest ever OBSERVE ETXCTRL_ACTIVE
 * set, which is what makes IRIX's if_ecintr take its CRBDP (0x1a000/0x1a004) path --
 * with the synchronous model that path is unreachable and never gets traced.
 * ENET_TX_CRBDP_NEXT=1 reports the descriptor AFTER the in-flight one, which is what
 * the FPGA's ARM servicer publishes; 0 reports the in-flight one itself. */
static const uint32_t g_tx_lat = getenv("ENET_TX_LATENCY") ? strtoul(getenv("ENET_TX_LATENCY"), nullptr, 0) : 0;
/* ENET_TX_CRBDP_ARMLIKE=1 mimics the FPGA's ARM servicer: it publishes the TX CRBDP
 * only once, at the END of a servicing pass, as the descriptor the walk stopped at.
 * While a NEW chain is in flight the register therefore still holds the PREVIOUS
 * chain's value, so neither of if_ecintr's two bounds can match any descriptor in the
 * current walk and the reap loop has no terminator.  =0 models real HPC3 behaviour:
 * the register tracks the in-flight descriptor live. */
static const bool g_tx_crbdp_armlike = getenv("ENET_TX_CRBDP_ARMLIKE") != nullptr;
static const bool g_tx_crbdp_dbg = getenv("ENET_TX_CRBDP_DBG") != nullptr;

/* Drive one ENET DMA channel against the sgiseeq descriptor rings. Channel 1 is
 * TX (mem->Seeq->tap); channel 0 is RX (tap->Seeq->mem). Each descriptor is
 * {pbuf, cntinfo, pnext} in guest DRAM (big-endian, read via rd_be32). */
/* ENET_TXLOG=1: log the IRIX TX descriptor protocol in program order -- guest stores
 * into the TX ring (interpret.cc), CACHE ops on it, the TX NBDP/ACTIVE doorbells, and
 * what this DMA model reads per descriptor.  The ring is located from the first TX
 * NBDP write (4 KB around it).  Read once. */
bool     g_txlog = getenv("ENET_TXLOG") != nullptr;
uint32_t g_txlog_lo = 0, g_txlog_hi = 0;
uint64_t g_txlog_icnt = 0;

void sgi_hpc::enet_run_dma(int ch) {
  scsi_dma_t &d = enet_dma[ch];
  if(!s->seeq) { return; }
  if(ch == 1) {
    /* TX: walk the chain from tx_ndptr, transmit each buffer, mark ETXD so the
     * driver's sgiseeq_tx acks it; XIE raises the TX-channel irq. */
    while(d.active) {
      uint32_t desc    = d.nbdp;
      uint32_t pbuf    = rd_be32(s, desc);
      uint32_t cntinfo = rd_be32(s, desc + 4);
      uint32_t pnext   = rd_be32(s, desc + 8);
      uint32_t cnt     = cntinfo & HPCDMA_BCNT;
      static uint32_t s_frame_len = 0, s_ip_want = 0;
      if(s_frame_len == 0 && cnt >= 18) {               /* frame start: Ethernet + IP header */
        /* per-byte: pbuf..pbuf+17 may straddle a page in the paged wasm backing */
        auto hb = [&](uint32_t k) -> uint8_t { return *s->mem.peek_raw_ptr(pbuf + k); };
        s_ip_want = (hb(12) == 0x08 && hb(13) == 0x00) ? 14u + (((uint32_t)hb(16) << 8) | hb(17)) : 0;
      }
      s_frame_len += cnt;
      if(g_txlog) {
        fprintf(stderr, "[txlog] %llu DMA desc %08x bp %08x bc %08x dp %08x\n",
                (unsigned long long)g_txlog_icnt, desc, pbuf, cntinfo, pnext);
      }
      if(cntinfo & HPCDMA_EOX) {
        if(g_txlog && s_ip_want && s_frame_len != s_ip_want && !(s_ip_want < 60 && s_frame_len <= 60)) {
          fprintf(stderr, "[txlog] %llu FRAME LEN MISMATCH frame %u ip %u\n",
                  (unsigned long long)g_txlog_icnt, s_frame_len, s_ip_want);
        }
        s_frame_len = 0;
        s_ip_want = 0;
      }
      /* ENET_CRBDP_PKT=1: CRBDP moves per PACKET (the in-flight packet's head).  IRIX's
       * clean_xd_chain (if_ec2.c:958-1043), while TX is ACTIVE, reclaims every whole
       * packet whose head lies before CRBDP -- without checking ETXD -- so a CRBDP inside
       * a packet lets it reclaim the rest of that packet mid-walk (truncated frames). */
      static const bool g_crbdp_pkt = getenv("ENET_CRBDP_PKT") != nullptr;
      static bool s_pkt_open = false;
      if(!g_tx_crbdp_armlike && (!g_crbdp_pkt || !s_pkt_open)) {
        enet_tx_crbdp = desc;                           /* real HPC3: tracks the in-flight descriptor */
      }
      s_pkt_open = !(cntinfo & (HPCDMA_EOX | 0x40000000u));
      for(uint32_t i = 0; i < cnt; i++) {
        uint8_t *p = s->mem.get_raw_ptr(pbuf + i);
        s->seeq->tx_dma_w(*p);
      }
      /* ENET_HEADETXD=1: IRIX reads ETXD on a packet's HEAD descriptor as "whole packet
       * sent" and reclaims all of it -- so set the head's ETXD only at packet end */
      static const bool g_headetxd = getenv("ENET_HEADETXD") != nullptr;
      static uint32_t s_head = 0, s_head_bc = 0;
      if(s_head == 0) {
        s_head = desc;
        s_head_bc = cntinfo;
      }
      if(!g_headetxd || desc != s_head) {
        wr_be32(s, desc + 4, cntinfo | HPCDMA_ETXD);    /* HPC transmitted this buffer */
      }
      if(cntinfo & (HPCDMA_EOX | 0x40000000u)) {        /* packet end (EOXP or EOX) */
        if(g_headetxd) {
          wr_be32(s, s_head + 4, rd_be32(s, s_head + 4) | HPCDMA_ETXD);
          if(g_txlog) {
            fprintf(stderr, "[txlog] %llu DMA head ETXD %08x\n", (unsigned long long)g_txlog_icnt, s_head);
          }
        }
        s_head = 0;
      }
      if(cntinfo & HPCDMA_XIE) { intstat |= 0x800u; }   /* XIE -> TX chan irq (istat bit 11) */
      d.cbp  = pbuf;
      d.nbdp = pnext;
      /* Flush ONLY at end-of-chain: IRIX's if_ec scatter-gathers a frame across
       * several descriptors (e.g. ethernet header in one buffer, payload in the
       * next), so accumulate the whole chain into one frame and transmit it once.
       * (Flushing per-buffer split each descriptor into its own bogus frame -- worked
       * for Linux sgiseeq only because it puts the whole frame in one buffer.) */
      if(cntinfo & HPCDMA_EOX) {
        if(g_txlog) {
          fprintf(stderr, "[txlog] %llu DMA flush (EOX)\n", (unsigned long long)g_txlog_icnt);
        }
        s->seeq->tx_flush();                            /* whole frame assembled -> out the tap */
        if(g_tx_crbdp_armlike) {
          enet_tx_crbdp = pnext;                        /* ARM servicer's tx_end, published once */
        }
        if(g_tx_lat == 0) {
          d.active = false;                             /* end of chain */
        }
        else {
          enet_tx_hold = g_tx_lat;                      /* draining onto the wire: ch_active stays set */
        }
        break;
      }
      if(g_tx_lat != 0) {
        break;                                          /* one descriptor per poll tick */
      }
    }
    if(!d.active) {
      d.ctrl &= ~0x200u;                                /* ETXCTRL_ACTIVE clears when idle */
    }
  }
  else {
    /* RX: ring of HPC-owned descriptors. For each staged frame, fill the current
     * descriptor's buffer with [pad][pad][frame][status], write back cntinfo with
     * OWN cleared and BCNT=residual (driver: len = PKT_BUF_SZ - residual - 3). */
    while(d.active and s->seeq->rx_avail()) {
      uint32_t desc    = d.nbdp;
      uint32_t cntinfo = rd_be32(s, desc + 4);
      if(!(cntinfo & HPCDMA_OWN)) { break; }            /* CPU still owns it: stall (retry next poll) */
      enet_crbdp = desc;                                /* HPC now filling this descriptor (reg 0x18000) */
      uint32_t pbuf    = rd_be32(s, desc);
      uint32_t pnext   = rd_be32(s, desc + 8);
      uint32_t bufsz   = cntinfo & HPCDMA_BCNT;         /* PKT_BUF_SZ */
      uint32_t written = 0;
      bool last = false;
      while(written < bufsz and s->seeq->rx_avail()) {
        uint8_t *p = s->mem.get_raw_ptr(pbuf + written);
        *p = s->seeq->rx_dma_r(last);
        sgi_dma_wrote(s, pbuf + written, 1);
        written++;
        if(last) { break; }                             /* [pad][pad][frame][status] complete */
      }
      uint32_t residual = bufsz - written;
      wr_be32(s, desc + 4, (cntinfo & ~HPCDMA_OWN & ~HPCDMA_BCNT) | (residual & HPCDMA_BCNT));
      if(cntinfo & HPCDMA_XIE) { intstat |= 0x400u; }   /* XIE -> RX chan irq (istat bit 10) */
      {
        static const bool g_ed = getenv("ENET_DBG") != nullptr;
        if(g_ed) {
          uint8_t *fr = s->mem.get_raw_ptr(pbuf + 2);    /* frame starts after the 2-byte pad */
          fprintf(stderr, "ENET RX-DMA: wrote %u B pbuf=%08x desc=%08x cntinfo=%08x bufsz=%u resid=%u irixlen=%d dst=%02x:%02x:%02x:%02x:%02x:%02x XIE=%d\n",
                  written, pbuf, desc, cntinfo, bufsz, residual, 1583 - (int)residual,
                  fr[0], fr[1], fr[2], fr[3], fr[4], fr[5], (cntinfo & HPCDMA_XIE) != 0);
        }
      }
      d.cbp  = pbuf;
      d.nbdp = pnext;                                   /* advance around the ring */
      if(cntinfo & HPCDMA_EOR) { break; }               /* end of ring: HPC pauses, driver re-arms */
    }
  }
}

/* Per-tick hook (called from maybe_take_interrupt): pull inbound frames off the
 * tap into the Seeq, then run the RX DMA if the RX channel is armed. */
void sgi_hpc::enet_poll() {
  if(!s->seeq) { return; }
  /* poll() reads the tap fd -- a syscall. Called per-instruction it dominates the
   * profile (libc read + tun_chr_read_iter), so throttle to 1-in-1024. RX latency
   * of ~1024 insns is negligible vs. the ms-scale network; the tap's own kernel
   * buffer holds frames between polls. */
  if((++enet_poll_ctr & 0x3ffu) != 0) { return; }
  s->seeq->poll();
  if(enet_dma[0].active) { enet_run_dma(0); }
  if(g_tx_lat != 0 and enet_dma[1].active) {
    if(enet_tx_hold != 0) {
      if(--enet_tx_hold == 0) {
        enet_dma[1].active = false;
        enet_dma[1].ctrl &= ~0x200u;
      }
    }
    else {
      enet_run_dma(1);
    }
  }
}

/* Live mappable interrupt status (kernel's vmeistat).  bit5 = SCC serial INT
 * (the Z8530 INT line: Tx-buffer-empty, and Rx when modeled). */
uint8_t sgi_hpc::ioc2_vmeistat_live() {
  uint8_t v = 0;
  if(s->scc && s->scc->int_pending()) v |= 0x20u;   /* bit5 = SERIAL DUART */
  if(s->ps2 && s->ps2->irq()) {                      /* bit4 = keyboard/mouse 8042 */
    v |= 0x10u;
  }
  return v;
}

/* local0 interrupt status with the live SCSI0 INTRQ bit (0x02) folded in from the
 * WD33C93 (level-sensitive: reflects intrq, cleared when IRIX reads SCSI Status),
 * plus LIO2 (bit7) = OR of the mappable cascade (vmeistat & cmeimask0) -- this is
 * how the SCC serial INT reaches IP2. */
uint8_t sgi_hpc::ioc2_local0_live() {
  uint8_t st = ioc2_local_status[0];
  if(s->scsi && s->scsi->intrq_pending()) st |= 0x02u;
  else                                    st &= ~0x02u;
  { /* SCSIIRQDBG: each change of the WD93 INTRQ as local0 sees it, with the mask */
    static const bool g_dbg = getenv("SCSIIRQDBG") != nullptr;
    static bool last = false;
    const bool now = (st & 0x02u) != 0;
    if(g_dbg && now != last) {
      fprintf(stderr, "[scsiirq] icnt=%llu intrq=%d mask0=%02x SR=%08x Cause=%08x pc=%016llx\n",
              (unsigned long long)s->icnt, now, ioc2_local_mask[0], (uint32_t)s->cpr0[CPR0_SR],
              (uint32_t)s->cpr0[CPR0_CAUSE], (unsigned long long)s->pc);
      last = now;
    }
  }
  if(globals::ip28) {                     /* Full House: SCSI1 INTRQ = bit 2 */
    st = ip28_scsi1(s)->intrq_pending() ? (st | 0x04u) : (st & ~0x04u);
  }
  /* ENET (bit3): the CPU interrupt is the HPC3 DMA-channel XIE latch (intstat bits
   * 10/11), cleared by the ENET reset reg CLRIRQ. The Seeq's own INTRQ is consumed
   * by the HPC internally (per-frame DMA'd status), NOT routed to IP2 -- folding it
   * here caused an interrupt storm since the driver never reads the Seeq rstat reg
   * to clear it. */
  if(intstat & 0x00000c00u) st |= 0x08u;
  else                      st &= ~0x08u;
  if(s->mc && s->mc->dma_irq_pending()) {     /* MC graphics DMA done (bit4) */
    st |= 0x10u;
  }
  if((ioc2_vmeistat_live() & ioc2_cmeimask[0]) != 0) st |= 0x80u;   /* LIO2 */
  else                                               st &= ~0x80u;
  return st;
}

uint8_t sgi_hpc::ioc2_local1_live() {
  uint8_t st = ioc2_local_status[1] | (s->np ? s->np->local1_bits() : 0);
  if(ioc2_cmeimask[1] != 0 && (ioc2_vmeistat_live() & ioc2_cmeimask[1]) != 0) {   /* LIO3 (mappable 1) */
    st |= 0x08u;
  }
  return st;
}

uint32_t sgi_hpc::read_impl(uint32_t offs, size_t sz) {
  DPRINTF("%s at pc %x : %x unimplemented\n", __PRETTY_FUNCTION__, s->pc, offs);
  /* IOC2-window access log (0x59800..0x598ff) for diffing this model's device
   * stream against another implementation's. */
  static const bool g_ioc2_dbg = getenv("IOC2DBG") != nullptr;
  if(g_ioc2_dbg and offs >= 0x59800u and offs <= 0x598ffu) {
    fprintf(stderr, "IOC2-R offs=%05x sz=%zu pc=%08x\n", offs, sz, (uint32_t)s->pc);
  }
  static const bool g_maclog = getenv("MACLOG") != nullptr;
  if(g_maclog and (uint32_t)s->pc >= 0x8800ab20u and (uint32_t)s->pc <= 0x8800b0b8u) {
    fprintf(stderr, "[maclog] pc=%08x get_nvreg reads offs=%05x sz=%zu\n",
            (uint32_t)s->pc, offs, sz);
  }
  static const bool g_enet_dbg = getenv("ENET_DBG") != nullptr;
  if(g_enet_dbg and ((offs >= 0x14000 and offs <= 0x17fff) or
                     (offs >= 0x54000 and offs <= 0x5401f) or
                     (offs >= 0x60000 and offs <= 0x67fff))) {
    fprintf(stderr, "ENET-R pc=%08x offs=%05x sz=%zu\n", s->pc, offs, sz);
  }
  if(offs == 0x598bb) {           /* i8254 counter 2: return latched low then high byte */
    uint8_t b = (t2_rd_phase == 0) ? (uint8_t)(t2_latch & 0xff)
                                   : (uint8_t)((t2_latch >> 8) & 0xff);
    t2_rd_phase ^= 1;
    return b;
  }

  if(offs <= 0x0000ffff) {        /* PBUS DMA channel registers */
    DPRINTF("pbus dma read\n");
  }
  else if(offs >= 0x00010000 and offs <= 0x00013fff) { /* SCSI HD0/HD1 DMA channel regs */
    int ch = (offs & 0x2000) ? 1 : 0;
    uint32_t n = offs & ~0x2000u;
    scsi_dma_t &d = scsi_dma[ch];
    uint32_t r = 0;                                      /* 32-bit regs: BE load path will swap the result */
    switch(n) {
    case 0x10000: r = d.cbp; break;
    case 0x10004: r = d.nbdp; break;
    case 0x11000: r = (d.count & 0x3fff) | (d.bc & ~0x3fffu); break;
    case 0x11004:                                        /* ctrl: read clears the IRQ bit */
      r = d.ctrl;
      if(intstat & (0x100u << ch)) { r |= 0x01u; intstat &= ~(0x100u << ch); }
      break;
    case 0x11010: r = d.dmacfg; break;
    case 0x11014: r = d.piocfg; break;
    default:      r = 0; break;                          /* gio/dev fifo ptr */
    }
    return __builtin_bswap32(r);
  }
  else if(offs >= 0x00014000 and offs <= 0x0001ffff) { /* ENET RX(0x14000)/TX(0x16000) DMA regs */
    int ch = (offs & 0x2000) ? 1 : 0;
    uint32_t n = offs & ~0x2000u;
    scsi_dma_t &d = enet_dma[ch];
    uint32_t r = 0;
    switch(n) {
    case 0x14000: r = d.cbp; break;
    case 0x14004: r = d.nbdp; break;
    case 0x15000: r = (d.count & 0x3fff) | (d.bc & ~0x3fffu); break;
    case 0x15004:                                       /* rx_ctrl/tx_ctrl: ACTIVE + seeq status */
      r = (d.ctrl & 0x200u);                            /* HPC3_E*XCTRL_ACTIVE reflects channel state */
      if(s->seeq) { r |= (ch == 0) ? s->seeq->rstat_peek() : s->seeq->tstat_peek(); }
      break;
    case 0x15014:                                       /* reset reg read: CLRIRQ(0x2) reflects a
                                                         * pending ENET DMA-channel irq. IRIX's ec ISR
                                                         * reads this, and only writes CLRIRQ if bit 0x2
                                                         * is set -- without it the irq never clears -> storm. */
      r = (intstat & 0x00000c00u) ? 0x2u : 0x0u;
      break;
    case 0x15018: r = d.dmacfg; break;
    case 0x18000:
    case 0x18004:                                       /* if_ecintr samples the TX CRBDP twice */
      r = ch ? enet_tx_crbdp : ((n == 0x18000) ? enet_crbdp : 0);
      if(g_tx_crbdp_dbg and ch) {
        fprintf(stderr, "[txcrbdp] read w%u -> %08x (nbdp=%08x active=%d) pc=%08x\n",
                (n == 0x18000) ? 0u : 1u, r, d.nbdp, (int)d.active, (uint32_t)s->pc);
      }
      break;
    default:      r = 0; break;
    }
    return __builtin_bswap32(r);
  }
  else if(offs >= 0x00054000 and offs <= 0x0005401f) {
    /* Seeq 8003/80C03 ENET device regs: 8 byte-registers, word-spaced (reg N at
     * +N*4). Model the Indy as "ethernet present, cable unplugged": reg0
     * collision counter = 0 (the ec driver reads this as 0 to identify the SGI
     * 80C03 EDLC, i.e. controller present), reg5 flags = NO_CARRIER, and the
     * rx/tx status regs report OLD (stale, nothing pending). No packets are
     * ever delivered, so a process polling the interface stops blocking once it
     * sees "no carrier" instead of waiting forever on a controller-less ISS. */
    uint32_t idx = ((offs - 0x54000) >> 2) & 7;
    uint8_t v = s->seeq ? s->seeq->pio_r(idx) : 0;
    return (sz == 1) ? v : ((uint32_t)v << 24);
  }
  else if(offs >= 0x00040000 and offs <= 0x00047fff) { /* WD33C93 HD0 (SASR=+3/SCMD=+7) */
    /* HPC3 map (MAME hpc3.cpp): HD0 SCSI0 = 0x40000-0x47fff, HD1 = 0x48000-0x4ffff.
     * NOT 0x44000 -- that came from MAME's buggy unhandled-access log string. */
    if(s->scsi) return s->scsi->pio_r(((offs - 0x40000) >> 2) & 1);
    return 0;
  }
  else if(globals::ip28 and offs >= 0x00048000 and offs <= 0x0004ffff) { /* WD33C93 HD1 */
    return ip28_scsi1(s)->pio_r(((offs - 0x48000) >> 2) & 1);
  }
  else if(offs == 0x30000) {      /* istat0: interrupt status [4:0] */
    return intstat;
  }
  else if(offs == 0x30004) {      /* gio_misc */
    return misc;
  }
  else if(offs == 0x59858) {      /* IOC2 System ID register (phys 0x1fbd9858) */
    /* 0x26 = guinness/Indy board id; getsysid uses bits [7:5] (->001) + bit 0
     * to pick the system type. (MAME co-sim, MAME_QUESTIONS.md Q5 round-3.)
     * Return it pre-byte-swapped (like the MC mconfig regs): the load path
     * bswaps device reads, so the kernel sees 0x26 in byte [7:0]. */
    /* --ip28: 0x1b = Full House (bit 0), board rev 13 -- IRIX warns "CPU baseboard
     * downrev (IP26 not IP28)" below 13 (IRIS src/dev/ioc.rs) */
    return globals::ip28 ? 0x1b000000u : 0x26000000u;
  }
  else if(offs == 0x5985b) {      /* the same System ID as a byte (Linux: sgioc->sysid,
                                   * ip22_is_fullhouse() tests its bit 0) */
    return globals::ip28 ? 0x1bu : 0x26u;
  }
  /* IOC2/INT2 local interrupt status/mask (byte regs at IOC2 off N -> 0x59800+N*4+3) */
  else if(offs == 0x59883) { return ioc2_local0_live(); }   /* local0 status */
  else if(offs == 0x59887) { return ioc2_local_mask[0]; }   /* local0 mask   */
  else if(offs == 0x5988b) { return ioc2_local1_live(); }   /* local1 status */
  else if(offs == 0x5988f) { return ioc2_local_mask[1]; }   /* local1 mask   */
  else if(offs == 0x59893) { return ioc2_vmeistat_live(); } /* map status (vmeistat) */
  else if(offs == 0x59897) { return ioc2_cmeimask[0]; }     /* map mask0 (cmeimask0) */
  else if(offs == 0x5989b) { return ioc2_cmeimask[1]; }     /* map mask1 (cmeimask1) */
  else if(offs == 0x5989f) { return ioc2_cmepol; }          /* map polarity (cmepol) */
  else if(offs >= 0x60000 and offs <= 0x67fff) {  /* DS1386 RTC + bbRAM (rtc_read) */
    /* byte value in [31:24] for a word load -- the BE load path bswaps device
     * reads (like SYSID); a byte load (the SGI PROM's lbu at reg*4+3) gets it as is */
    const uint8_t v = rtc_read((offs - 0x60000) >> 2);
    return (sz == 1) ? v : ((uint32_t)v << 24);
  }
  else if(offs >= 0x00058000 and offs <= 0x0005bfff) { /* PBUS PIO data ports */
    int id = ((offs>>8) & 0x7f)>>2;
    DPRINTF("pio data on channel %u\n", id);
  }
  //else {

  //assert(false);
    //}

  //exit(-1);
  return 0;
}

/* DS1286/DS1386 RTC in the bbRAM window (byte-per-word x4: reg N at 0x60000+N*4).
 * Until the guest sets the clock, return the live host wall-clock in BCD so IRIX
 * boots with a sane date instead of 1970/2000 -- a bogus clock makes the man-page
 * index (makewhatis/sgindex) look perpetually stale, triggering a full rebuild on
 * every boot.  localtime() is read fresh per access; the few reads of a full clock
 * snapshot land within microseconds of each other, so the fields stay coherent.
 * A guest write to a clock field (the SGI PROM sets it when it finds it invalid)
 * becomes an offset from host time, so the clock reads back what was written and
 * keeps ticking.  Everything above the clock is battery-backed RAM. */
static uint8_t to_bcd(int n) { return (uint8_t)(((n / 10) << 4) | (n % 10)); }
static int from_bcd(uint8_t v) { return ((v >> 4) * 10) + (v & 0xf); }

uint8_t sgi_hpc::rtc_read(uint32_t reg) {
  if(reg >= 0x13a && reg <= 0x13f) {
    /* IP22 station ethernet address in the ds1386 bbRAM at word 250..255
     * (ip22-nvram.c: ip22_nvram_read, EADDR_NVOFS=250, Indy/Guiness path reads
     * hpc3c0->bbram[reg*2 + {0,1}]; bbram base is 0x60100, so reg 250 -> 0x604e8).
     * Real SGI OUI 08:00:69 so the sgiseeq driver gets a valid MAC instead of the
     * all-zero address (which fails is_valid_ether_addr). */
    static const uint8_t mac[6] = {0x08, 0x00, 0x69, 0x12, 0x34, 0x56};
    return mac[reg - 0x13a];
  }
  if(reg > 0xa) {
    return rtc_ram[reg];
  }
  /* HENNY-MATCH: under DETTIME, return the henny FPGA RTL's FROZEN ds1386 date
   * (rtl/hpc3.sv: 2030-01-01 00:00:00, dow=1) bit-exactly, so the golden ISS takes
   * the SAME date-dependent reconfigure path as silicon. IRIX rtodc() (IP22.c:3617-3644)
   * decodes the BCD year as year = 1940 + bcd, with a pivot: bcd<45 adds 30 (so bcd
   * 00-44 -> 1970-2014, bcd 45-99 -> 1985-2039). BCD 0x90 = 90 >= 45 -> 1940+90 = 2030.
   * 2030 is deliberately AFTER the clean image's ~2026-06 /var/sysgen mtimes, so a
   * reconfigure writes /unix with mtime > sysgen and IRIX reconfigures ONCE, then skips
   * it on every later boot -- no disk backdating needed. month/date default 1. */
  static const bool g_det = getenv("DETTIME") != nullptr;
  if(g_det) {
    switch(reg)
      {
      case 0x6: return 0x01;   /* day-of-week = 1 */
      case 0x8: return 0x01;   /* date = 1st */
      case 0x9: return 0x01;   /* month = January */
      case 0xa: return 0x90;   /* year BCD 90 -> IRIX rtodc 1940+90 = 2030 (matches hpc3.sv) */
      default:  return 0x00;   /* sec/min/hour/cmd = 0 (BCD 00) */
      }
  }
  if(reg == 0x0) {
    return to_bcd(rtc_hundredths(s));            /* hundredths: no calendar needed */
  }
  /* localtime_r costs ~1K host instructions and the guest polls the clock, so only
   * recompute the calendar when the second changes */
  const time_t now = rtc_now(s) + (time_t)rtc_offset;
  if(now != rtc_lt_time) {
    localtime_r(&now, &rtc_lt);
    rtc_lt_time = now;
  }
  const struct tm &lt = rtc_lt;
  switch(reg)
    {
    case 0x1: return to_bcd(lt.tm_sec);          /* seconds */
    case 0x2: return to_bcd(lt.tm_min);          /* minutes */
    case 0x4: return to_bcd(lt.tm_hour);         /* hours (24h BCD) */
    case 0x6: return to_bcd(lt.tm_wday + 1);     /* day-of-week (1-7) */
    case 0x8: return to_bcd(lt.tm_mday);         /* date (1-31) */
    case 0x9: return to_bcd(lt.tm_mon + 1);      /* month (1-12); EOSC/ESQW = 0 (running) */
    case 0xa: return to_bcd(lt.tm_year % 100);   /* year (BCD 2-digit) */
    default:  return rtc_ram[reg];               /* alarms -> stored */
    }
}

static const char *g_nvram_file = getenv("NVRAM_FILE");

void sgi_hpc::rtc_ram_load() {
  if(g_nvram_file == nullptr) {
    return;
  }
  FILE *f = fopen(g_nvram_file, "rb");
  if(f == nullptr) {
    fprintf(stderr, "[nvram] %s not found: ds1386 RAM starts zeroed\n", g_nvram_file);
    return;
  }
  const size_t n = fread(rtc_ram, 1, sizeof(rtc_ram), f);
  fclose(f);
  fprintf(stderr, "[nvram] loaded %zu bytes of ds1386 RAM from %s\n", n, g_nvram_file);
}

void sgi_hpc::rtc_ram_save() {
  if(g_nvram_file == nullptr) {
    return;
  }
  FILE *f = fopen(g_nvram_file, "wb");
  if(f == nullptr) {
    return;
  }
  fwrite(rtc_ram, 1, sizeof(rtc_ram), f);
  fclose(f);
}

void sgi_hpc::rtc_write(uint32_t reg, uint8_t v) {
  if(reg > 0xa || reg == 0x6) {
    rtc_ram[reg] = v;                            /* RAM; day-of-week follows the date */
    if(reg > 0xa) {
      rtc_ram_save();                            /* NVRAM_FILE persistence */
    }
    return;
  }
  const time_t now = rtc_now(s) + (time_t)rtc_offset;
  struct tm lt;
  localtime_r(&now, &lt);
  const int n = from_bcd(v & 0x7f);
  switch(reg)
    {
    case 0x1: lt.tm_sec = n; break;
    case 0x2: lt.tm_min = n; break;
    case 0x4: lt.tm_hour = from_bcd(v & 0x3f); break;
    case 0x8: lt.tm_mday = n; break;
    case 0x9: lt.tm_mon = from_bcd(v & 0x1f) - 1; break;
    case 0xa: lt.tm_year = 100 + n; break;       /* 20xx; only the 2-digit BCD reads back */
    default:
      rtc_ram[reg] = v;                          /* hundredths (ignored), alarms */
      return;
    }
  lt.tm_isdst = -1;
  rtc_offset = (int64_t)mktime(&lt) - (int64_t)rtc_now(s);
}

/* full HPC3 register access log, for diffing against another implementation */
static const bool hpc_access_log = getenv("HPCDBG") != nullptr;

/* --ip28: Full House's INT2 (and the 8254 with it) sits at IOC offset 0x59000, where
 * the Indy has ISDN; INT3 in the IOC2 is the same register file at 0x59880 ("the base
 * address will change from 0x1FBD9000 to 0x1FBD9880", IOC2 spec, Guinness/Full House
 * differences).  INT2's LED register lands on INT3's Map Pol. */
static inline uint32_t ip28_int2(uint32_t offs) {
  return (globals::ip28 and offs >= 0x59000u and offs < 0x59040u) ? (offs + 0x880u) : offs;
}

/* --ip28: Full House keeps the PROM environment and the MAC in a 93CS56 (128 x 16)
 * serial EEPROM on the HPC3's eeprom register (0x30008, byte lane 0x3000b), where the
 * Indy uses the ds1386's RAM.  The PROM bit-bangs it: bit 1 CS, bit 2 SK, bit 3 DI,
 * bit 4 DO.  Commands are a start bit, 2 opcode bits and 8 address bits (the top
 * address bit is don't-care); READ shifts out a dummy 0 then D15..D0.  Not persisted.
 * Protocol and the erased-part defaults below follow IRIS (src/dev/eeprom_93c56.rs). */
struct ip28_eeprom_t {
  enum class st_t { standby, idle, opcode, address, data_in, data_out };
  uint16_t data[128];
  st_t st = st_t::standby;
  bool cs = false, sk = false, do_pin = true, wen = false;
  uint32_t reg = 0, shifter = 0, nbits = 0, opcode = 0, addr = 0;

  /* an erased IP28 EEPROM as the PROM's defaults leave it: layout revision 9, a few
   * env defaults, the MAC in words 0x7d..0x7f and the checksum in byte 0 */
  ip28_eeprom_t() {
    uint8_t b[256] = {0};
    b[1] = 9;
    static const struct { int off; const char *v; } defs[] = {
      {2, "g"}, {116, "9600"}, {121, "0"}, {122, "PST8PDT"}, {178, "Y"},
      {232, "80"}, {235, "0"}, {236, "y"}, {239, "y"}, {242, "1"},
    };
    for(const auto &d : defs) {
      memcpy(b + d.off, d.v, strlen(d.v));
    }
    for(int i = 0; i < 128; i++) {
      data[i] = (uint16_t)((b[2*i] << 8) | b[2*i+1]);
    }
    data[0x7d] = 0x0800; data[0x7e] = 0x6912; data[0x7f] = 0x3456;   /* 08:00:69:12:34:56 */
    uint8_t ck = 0xa5;
    for(int i = 0; i < 128; i++) {
      ck ^= (uint8_t)data[i];
      if(i != 0) {
        ck ^= (uint8_t)(data[i] >> 8);
      }
      ck = (uint8_t)((ck << 1) | (ck >> 7));
    }
    data[0] = (uint16_t)((data[0] & 0xff) | (ck << 8));
  }
  uint8_t read() const {
    return (uint8_t)((reg & ~0x10u) | (do_pin ? 0x10u : 0u));
  }
  void write(uint8_t v) {
    reg = v;
    const bool ncs = (v >> 1) & 1, nsk = (v >> 2) & 1, di = (v >> 3) & 1;
    if(ncs != cs) {
      cs = ncs;
      st = cs ? st_t::idle : st_t::standby;
      if(!cs) {
        do_pin = true;
      }
    }
    const bool rising = nsk and not sk;
    sk = nsk;
    if(cs and rising) {
      tick(di);
    }
  }
  void tick(bool di) {
    switch(st)
      {
      case st_t::standby:
        break;
      case st_t::idle:
        if(di) {
          st = st_t::opcode;
          nbits = shifter = 0;
        }
        break;
      case st_t::opcode:
        shifter = (shifter << 1) | di;
        if(++nbits == 2) {
          opcode = shifter & 3;
          st = st_t::address;
          nbits = shifter = 0;
        }
        break;
      case st_t::address:
        shifter = (shifter << 1) | di;
        if(++nbits < 8) {
          break;
        }
        addr = shifter & 0xff;
        nbits = shifter = 0;
        st = st_t::idle;
        if(opcode == 2) {                              /* READ */
          shifter = data[addr & 0x7f];
          do_pin = false;                              /* the dummy 0 */
          st = st_t::data_out;
        }
        else if(opcode == 1 or (opcode == 0 and (addr >> 6) == 1)) {   /* WRITE, WRAL */
          if(wen) {
            st = st_t::data_in;
          }
        }
        else if(opcode == 3) {                         /* ERASE */
          if(wen) {
            data[addr & 0x7f] = 0xffff;
          }
        }
        else if((addr >> 6) == 2) {                    /* ERAL */
          if(wen) {
            for(auto &w : data) {
              w = 0xffff;
            }
          }
        }
        else {
          wen = ((addr >> 6) == 3);                    /* EWEN; EWDS = 0 */
        }
        break;
      case st_t::data_in:
        shifter = (shifter << 1) | di;
        if(++nbits == 16) {
          if(opcode == 1) {
            data[addr & 0x7f] = (uint16_t)shifter;
          }
          else {
            for(auto &w : data) {
              w = (uint16_t)shifter;
            }
          }
          st = st_t::idle;
        }
        break;
      case st_t::data_out:
        if(nbits < 16) {
          do_pin = (shifter >> (15 - nbits)) & 1;
          nbits++;
        }
        else {
          do_pin = true;
          st = st_t::idle;
        }
        break;
      }
  }
};
static ip28_eeprom_t g_ip28_eeprom;

/* --ip28: Full House's second WD33C93 (HD1, registers at 0x48000, local0 bit 2).
 * Nothing is attached: it is here for the PROM's "SCSI controller 1" diagnostic.
 * Created on first use; no DMA channel is wired to it. */
static sgi_scsi *ip28_scsi1(state_t *s) {
  static sgi_scsi *scsi1 = new sgi_scsi(s, "");
  return scsi1;
}

uint32_t sgi_hpc::read(uint32_t offs, size_t sz) {
  offs = ip28_int2(offs);
  /* SCSI1DBG: the --ip28 second SCSI controller -- WD33C93 HD1 regs and HPC3 DMA ch1 */
  static const bool g_scsi1_dbg = getenv("SCSI1DBG") != nullptr;
  if(g_scsi1_dbg and ((offs >= 0x48000 and offs <= 0x4ffff) or (offs >= 0x12000 and offs <= 0x13fff))) {
    fprintf(stderr, "[scsi1] R offs=%05x sz=%zu icnt=%llu pc=%016llx\n", offs, sz,
            (unsigned long long)s->icnt, (unsigned long long)s->pc);
  }
  if(globals::ip28 and (offs == 0x30008u or offs == 0x3000bu)) {
    const uint8_t v = g_ip28_eeprom.read();
    return (sz == 1) ? v : ((uint32_t)v << 24);
  }
  /* IOC2 regs 0x10/0x11: 8042 data, status (byte at +3; word reads carry it in [31:24]) */
  if(s->ps2 && (offs & ~7u) == 0x59840u) {
    const uint8_t v = s->ps2->read((offs & 4) != 0);
    return (sz == 1) ? v : ((uint32_t)v << 24);
  }
  uint32_t x = read_impl(offs, sz);
  if(hpc_access_log) {
    fprintf(stderr, "HPC-R offs=%05x -> %08x sz=%zu\n", offs, x, sz);
  }
  return x;
}

void sgi_hpc::write(uint32_t offs, uint32_t x, size_t sz) {
  offs = ip28_int2(offs);
  static const bool g_scsi1_dbg = getenv("SCSI1DBG") != nullptr;
  if(g_scsi1_dbg and ((offs >= 0x48000 and offs <= 0x4ffff) or (offs >= 0x12000 and offs <= 0x13fff))) {
    fprintf(stderr, "[scsi1] W offs=%05x v=%08x sz=%zu icnt=%llu pc=%016llx\n", offs, x, sz,
            (unsigned long long)s->icnt, (unsigned long long)s->pc);
  }
  if(globals::ip28 and (offs == 0x30008u or offs == 0x3000bu)) {
    g_ip28_eeprom.write((sz == 1) ? (uint8_t)x : (uint8_t)(x >> 24));
    return;
  }
  //assert(sz == 4);
  if(s->ps2 && (offs & ~7u) == 0x59840u) {
    s->ps2->write((offs & 4) != 0, (sz == 1) ? (uint8_t)x : (uint8_t)(x >> 24));
    return;
  }
  if(hpc_access_log) {
    fprintf(stderr, "HPC-W offs=%05x <- %08x sz=%zu\n", offs, x, sz);
  }
  static const bool g_ioc2_dbg_w = getenv("IOC2DBG") != nullptr;
  if(g_ioc2_dbg_w and offs >= 0x59800u and offs <= 0x598ffu) {
    fprintf(stderr, "IOC2-W offs=%05x val=%08x sz=%zu pc=%08x\n", offs, x, sz, (uint32_t)s->pc);
  }
  static const bool g_enet_dbg = getenv("ENET_DBG") != nullptr;
  if(g_enet_dbg and ((offs >= 0x14000 and offs <= 0x17fff) or
                     (offs >= 0x54000 and offs <= 0x5401f) or
                     (offs >= 0x60000 and offs <= 0x67fff))) {
    fprintf(stderr, "ENET-W pc=%08x offs=%05x val=%08x sz=%zu\n", s->pc, offs, x, sz);
  }
  if(globals::ip28 and offs == 0x598bf and ((x >> 6) & 3) < 2) {
    /* i8254 control word for counter 0 or 1 (SC = bits 7:6): RW=both -> expect a
     * two-byte reload; a latch command (RW=00) has nothing to snapshot here */
    pit_counter_t &c = pit[(x >> 6) & 1];
    if(((x >> 4) & 3) != 0) {
      c.loading = true;
      c.wr_phase = 0;
    }
    return;
  }
  if(globals::ip28 and (offs == 0x598b3 or offs == 0x598b7)) {
    /* i8254 counter 0 (0x598b3) / 1 (0x598b7): low byte then high byte; the
     * high byte (re)starts the counter as a rate generator */
    pit_counter_t &c = pit[(offs == 0x598b7) ? 1 : 0];
    if(c.loading) {
      if(c.wr_phase == 0) {
        c.load = (c.load & 0xff00) | (x & 0xff);
        c.wr_phase = 1;
      }
      else {
        c.load = (c.load & 0x00ff) | ((x & 0xff) << 8);
        c.wr_phase = 0;
        c.loading = false;
        c.period = pit_period(c.load);
        c.next_fire = s->cpr0[CPR0_COUNT] + c.period;
        c.armed = true;
        static const bool g_pit_dbg = getenv("PITDBG") != nullptr;
        if(g_pit_dbg) {
          fprintf(stderr, "[pit] arm ctr%d load=%u period=%u count=%08x pc=%016llx\n", (offs == 0x598b7) ? 1 : 0,
                  c.load, c.period, s->cpr0[CPR0_COUNT], (unsigned long long)s->pc);
        }
      }
    }
    return;
  }
  if(globals::ip28 and offs == 0x598a3) {   /* timer interrupt clear: bit 0 / bit 1 */
    static const bool g_pit_dbg = getenv("PITDBG") != nullptr;
    static uint64_t n_ack = 0;
    ++n_ack;
    if(g_pit_dbg and ((n_ack & (n_ack - 1)) == 0)) {
      fprintf(stderr, "[pit] ack #%llu x=%x irq0=%d irq1=%d count=%08x next0=%08x next1=%08x\n", (unsigned long long)n_ack,
              x, pit[0].irq, pit[1].irq, s->cpr0[CPR0_COUNT], pit[0].next_fire, pit[1].next_fire);
    }
    if(x & 1) {
      pit[0].irq = false;
    }
    if(x & 2) {
      pit[1].irq = false;
    }
    return;
  }
  if(offs == 0x598bf) {           /* i8254 control word (tcword) */
    if(((x >> 4) & 0x3) == 0) {   /* RW=00: counter-latch command -> snapshot live value */
      t2_latch = t2_value();
      t2_rd_phase = 0;
    }
    else {                        /* RW=both: program (or stop) -> expect a 2-byte reload */
      t2_loading = true;
      t2_wr_phase = 0;
    }
    return;
  }
  else if(offs == 0x598bb) {      /* i8254 counter 2 (tcnt2): low byte then high byte */
    if(t2_loading) {
      if(t2_wr_phase == 0) {
        t2_load = (t2_load & 0xff00) | (x & 0xff);
        t2_wr_phase = 1;
      }
      else {
        t2_load = (t2_load & 0x00ff) | ((x & 0xff) << 8);
        t2_wr_phase = 0;
        t2_loading = false;
        t2_count_at_load = s->cpr0[CPR0_COUNT];   /* (re)start the down-count */
      }
    }
    return;
  }
  if(offs <= 0x0000ffff) {        /* PBUS DMA channel registers */
    DPRINTF("pbus dma write\n");
  }
  else if(offs >= 0x00010000 and offs <= 0x00013fff) { /* SCSI HD0/HD1 DMA channel regs */
    int ch = (offs & 0x2000) ? 1 : 0;
    uint32_t n = offs & ~0x2000u;
    scsi_dma_t &d = scsi_dma[ch];
    /* These are 32-bit registers; the BE store path delivers the word byte-
     * swapped to MMIO handlers (byte accesses like the WD33C93 are unaffected).
     * Swap back to the guest's intended value. */
    x = __builtin_bswap32(x);
    switch(n) {
    case 0x10004: d.nbdp   = x; break;
    case 0x11000: d.bc     = x; break;
    case 0x11010: d.dmacfg = x; break;
    case 0x11014: d.piocfg = x; break;
    case 0x11004: {                                   /* ctrl: arm / flush / reset the channel */
      bool was_active = d.active;
      if(x & 0x20u) {                                 /* AMASK: write-protect ch_active */
        d.ctrl = x & ~0x01u & ~0x10u & ~0x20u;
        if(was_active) d.ctrl |= 0x10u;
      } else {
        d.ctrl = x & ~0x01u & ~0x20u;
        d.active = (d.ctrl & 0x10u);
      }
      d.to_device = (d.ctrl & 0x04u);                 /* DIR: 1 = mem->device */
      if(!was_active && d.active) d.state = CH_FETCH;  /* arm -> start the FSM */
      if((x & 0x40u) && s->scsi) s->scsi->reset();    /* CRESET */
      if(x & 0x08u) { d.active = false; d.ctrl &= ~0x10u; d.state = CH_IDLE; }  /* FLUSH -> stop */
      if(d.active) scsi_run_dma(ch);
      break;
    }
    default: break;
    }
    return;
  }
  else if(offs >= 0x00014000 and offs <= 0x0001ffff) { /* ENET RX(0x14000)/TX(0x16000) DMA regs */
    int ch = (offs & 0x2000) ? 1 : 0;
    uint32_t n = offs & ~0x2000u;
    scsi_dma_t &d = enet_dma[ch];
    x = __builtin_bswap32(x);
    switch(n) {
    case 0x14000: d.cbp    = x; break;
    case 0x14004:
      d.nbdp = x;
      if(g_txlog && ch == 1) {
        if(g_txlog_lo == 0) {
          g_txlog_lo = x & ~0xfffu;
          g_txlog_hi = g_txlog_lo + 0x1000u;
        }
        fprintf(stderr, "[txlog] %llu NBDP %08x\n", (unsigned long long)g_txlog_icnt, x);
      }
      break;
    case 0x15000: d.bc     = x; break;
    case 0x15018: d.dmacfg = x; break;
    case 0x18000: enet_crbdp = x; break;              /* CRBDP init (HPC updates it on RX fill) */
    case 0x15004: {                                   /* rx_ctrl(ch0)/tx_ctrl(ch1): ACTIVE = 0x200 */
      bool was_active = d.active;
      d.ctrl   = x;
      d.active = (x & 0x200u) != 0;                    /* HPC3_ERXCTRL/ETXCTRL_ACTIVE */
      if(ch == 1 and d.active != was_active) {
        /* Any arm/halt edge cancels a pending post-EOX drain.  if_ecintr's resync path
         * (0x880582d0) halts the channel and rewinds nbdp, then re-arms; a stale hold
         * would otherwise clear ch_active out from under the NEW chain and wedge TX. */
        enet_tx_hold = 0;
      }
      if(g_txlog && ch == 1) {
        fprintf(stderr, "[txlog] %llu CTRL %08x (was %s)\n", (unsigned long long)g_txlog_icnt, x,
                was_active ? "active" : "idle");
      }
      if(d.active and not was_active) { enet_run_dma(ch); }  /* newly armed: TX runs now, RX waits on frames */
      break;
    }
    case 0x15014:                                     /* ENET reset (RX region): CRESET|CLRIRQ */
      if(x & 0x2u) { intstat &= ~0x00000c00u; }        /* CLRIRQ: clear RX(0x400)+TX(0x800) chan irq */
      if(x & 0x1u) {                                   /* CRESET: reset both ENET DMA channels */
        enet_dma[0].active = false; enet_dma[0].ctrl = 0;
        enet_dma[1].active = false; enet_dma[1].ctrl = 0;
        intstat &= ~0x00000c00u;
        if(s->seeq) { s->seeq->reset(); }
      }
      break;
    default: break;
    }
    return;
  }
  else if(offs >= 0x00054000 and offs <= 0x0005401f) { /* Seeq 8003 ENET device regs */
    /* Byte registers, word-spaced. On a word store (sz==4) the BE MMIO path puts
     * the byte in bits [31:24] (symmetric with the read handler's v<<24); a byte
     * store carries it in [7:0]. Extracting (uint8_t)x unconditionally zeroed
     * rx_cmd + the station MAC -> receiver disabled. */
    uint8_t b = (sz == 1) ? (uint8_t)x : (uint8_t)(x >> 24);
    if(s->seeq) { s->seeq->pio_w(((offs - 0x54000) >> 2) & 7, b); }
    return;
  }
  else if(offs == 0x30004) {      /* gio_misc */
    misc = x&3;
  }
  /* IOC2/INT2 local interrupt masks (byte regs); status regs are read-only */
  else if(offs == 0x59887) { ioc2_local_mask[0] = (uint8_t)x; }
  else if(offs == 0x5988f) { ioc2_local_mask[1] = (uint8_t)x; }
  else if(offs == 0x59897) { ioc2_cmeimask[0] = (uint8_t)x; } /* map mask0 (cmeimask0) */
  else if(offs == 0x5989b) { ioc2_cmeimask[1] = (uint8_t)x; } /* map mask1 (cmeimask1) */
  else if(offs == 0x5989f) { ioc2_cmepol     = (uint8_t)x; } /* map polarity (cmepol)  */
  else if(offs >= 0x60000 and offs <= 0x67fff) { /* DS1386 RTC + bbRAM */
    rtc_write((offs - 0x60000) >> 2, (sz == 1) ? (uint8_t)x : (uint8_t)(x >> 24));
  }
  else if(offs >= 0x40000 and offs <= 0x47fff) { /* WD33C93 HD0 (SASR=+3/SCMD=+7) */
    if(s->scsi) {
      s->scsi->pio_w(((offs - 0x40000) >> 2) & 1, (uint8_t)x);
      /* a COMMAND-register write may assert DRQ; service it if the channel is armed */
      if(scsi_dma[0].active && s->scsi->drq_pending()) scsi_run_dma(0);
    }
  }
  else if(globals::ip28 and offs >= 0x48000 and offs <= 0x4ffff) { /* WD33C93 HD1 */
    ip28_scsi1(s)->pio_w(((offs - 0x48000) >> 2) & 1, (uint8_t)x);
  }
  else if(offs >= 0x00058000 and offs <= 0x0005bfff) { /* PBUS PIO data ports */
    int id = ((offs>>8) & 0x7f)>>2;
    DPRINTF("pio write data on channel %x for offset %x with data %x\n", id, offs, x);
  }
  else if(offs >= 0x5c000 and offs <= 0x5cfff) { /* PBUS DMA channel config */
    int id = ((offs>>8) & 0xf)>>1;
    DPRINTF("pbus dma write for channel %d = %x\n", id, x);
    pbus_dma_config[id] = x;
    return;
  }
  else if(offs >= 0x5d000 and offs <= 0x5dfff) {
    /* pbus pio channel configuration register */
    int id = (offs>>8) & 0xf;
    DPRINTF("pio channel config %d = %x\n", id, x);
    if(id < 10) {
      pbus_pio_config[id] = x;
    }
    else {
      assert(false);
    }
    return;
  }
  else {
    DPRINTF("%s at pc %x : %x unimplemented (lenient -> ignore)\n", __PRETTY_FUNCTION__, s->pc, offs);
  }
}
