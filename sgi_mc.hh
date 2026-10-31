#ifndef __sgi_mc__
#define __sgi_mc__

#include <cstdint>
#include <cstddef>
#include <cstdlib>

/* systemid value (MC reg 0x1c): [3:0]=revision, [4]=EISA present. Indy has no
 * EISA so bit4 stays clear; MAME reports revision 3 ("rev c"). */
/* Stored pre-swapped so the guest's BE lw yields 0x00000013 -- EXACTLY the RTL's
 * MC_SYSID (henry rtl/mc.sv: 32'h13000000).  The bare 0x3 reached the kernel as
 * 0x03000000 (low nibble 0) and Linux printed "MC revision 0" while the FPGA said 3. */
static const uint32_t sys_id = 0x13000000; /* mame says rev c (3) */

struct state_t;

/* SGI Indy Memory Controller. Backing store for the MC register window; see
 * the register map and bit definitions in sgi_mc.cc. */
class sgi_mc {
  state_t *s;
  uint32_t eeprom_ctrl;           /* reg 0x30/0x34: serial EEPROM bit-bang state */
  /* 93CS56 serial EEPROM (the Indy NVRAM: 128 x 16-bit words) behind reg 0x34. */
  uint16_t ee_mem[128];
  uint32_t ee_sr = 0;             /* bits shifted in since CS rose */
  uint32_t ee_nbits = 0;
  uint32_t ee_out = 0;            /* READ: bits still to shift out, MSB first */
  uint32_t ee_nout = 0;
  uint32_t ee_op = 0, ee_addr = 0;
  bool ee_wen = false;            /* EWEN seen */
  bool ee_reading = false;        /* a READ is streaming: more clocks = the next word */
  bool ee_di = true;              /* level on the DI (to-host) pin */
  void eeprom_write(uint32_t ctrl);
  /* EEPROM_FILE=<path>: the 93CS56 persists across runs (Indigo2 keeps its PROM env here;
   * an Indy only probes it -- see NVRAM_FILE in sgi_hpc for the Indy env) */
  void eeprom_load();
  void eeprom_save();
  uint32_t cpu_error_status;      /* reg 0xec (cstat) */
  uint32_t gio_error_status;      /* reg 0xfc (gstat) */
  uint32_t cpu_mem_access_config; /* reg 0xd4 (cmacc) */
  uint32_t gio_mem_access_config; /* reg 0xdc (gmacc) */
  uint32_t gio64_arb_param;       /* reg 0x84 (giopar) */
  uint32_t rpss_divider;          /* reg 0x2c (divider) */
  uint32_t rpss_counter;          /* reg 0x1004 (rpss free-running counter) */
  uint32_t cpu_control[2] = {0};  /* reg 0x04/0x0c (cpuctrl0/cpuctrl1) */
  uint32_t memcfg[2] = {0};       /* reg 0xc4/0xcc (mconfig0/mconfig1) */
  /* GIO64 graphics DMA ("virtual DMA", MC spec p.24; MAME sgi_mc perform_dma):
   * moves lines between DRAM (through the 4-entry DMA TLB) and a GIO64 address --
   * in practice the Newport REX3 host data port. */
  uint32_t dma_gio_mask = 0, dma_gio_sub = 0, dma_cause = 0, dma_ctl = 0;
  uint32_t dma_tlb_hi[4] = {0}, dma_tlb_lo[4] = {0};
  uint32_t dma_memadr = 0, dma_size = 0, dma_stride = 0, dma_gio_adr = 0;
  uint32_t dma_mode = 0, dma_count = 0, dma_run = 0;
  bool dma_irq = false;           /* INT3 local0 MC_DMA (0x10) */
  bool dma_read(uint32_t offs, uint32_t *x);
  bool dma_write(uint32_t offs, uint32_t x);
  uint32_t dma_translate(uint32_t va);
  void dma_perform();
public:
  bool dma_irq_pending() const { return dma_irq; }
  sgi_mc(state_t *s) : s(s),
		       eeprom_ctrl(0),
		       cpu_error_status(0),
		       gio_error_status(0),
		       cpu_mem_access_config(0),
		       gio_mem_access_config(0),
		       gio64_arb_param(0),
		       rpss_divider(0x104),
		       rpss_counter(0) {
    /* Advertise installed DRAM as the IP22 PROM would, so the kernel MC probe
     * finds it.  bank0 = mconfig0[31:16]; MC rev<5 decode: base=(cfg&0xff)<<22,
     * size=((cfg&0x1f00)+0x100)<<14.  cfg = BVALID(0x2000)|RMASK|BASE(0x20).
     * The kernel reads mconfig0/1 directly in mlreset() at the +4/+c BE aliases
     * (0x1fa000c4 / 0x1fa000cc); stored byte-swapped so the kernel reads
     * 0x23200000 / 0.
     *
     * Default = 16 MiB @ PA 0x08000000 (cfg 0x2320, size field [12:8]=0x03) --
     * this is the real SGI Indy / MAME config (confirmed via MAME hinv; see
     * MAME_QUESTIONS.md Q4). 128 MiB (cfg 0x3f20) and 256 MiB (two banks, below)
     * now boot to the IRIX banner + login and hinv reports the size -- the old
     * init_pmap panic was cured by the mconfig0/1 decode fix (22958a2).
     * MEMCFG=<hex cfg> overrides at runtime. */
    /* MEMCFG = bank0 cfg (default 16 MiB), MEMCFG1 = bank1 cfg (default none).
     * 256 MiB (matches henny 0x3f203f40): MEMCFG=3f20 MEMCFG1=3f40 -> two 128 MiB
     * banks contiguous at PA 0x08000000 (base 0x20) and 0x10000000 (base 0x40). */
    for(int i = 0; i < 128; i++) {
      ee_mem[i] = 0xffff;          /* erased */
    }
    eeprom_load();
    const char *e  = getenv("MEMCFG");
    const char *e1 = getenv("MEMCFG1");
    uint32_t cfg0 = e  ? (uint32_t)strtoul(e,  nullptr, 16) : 0x2320u;
    uint32_t cfg1 = e1 ? (uint32_t)strtoul(e1, nullptr, 16) : 0u;
    memcfg[0] = __builtin_bswap32(cfg0 << 16);
    memcfg[1] = __builtin_bswap32(cfg1 << 16);
  };
  uint32_t read(uint32_t offs, size_t sz);
  void write(uint32_t offs, uint32_t x, size_t sz);  
  /* mconfig0 in CPU order (bank0 [31:16], bank1 [15:0]): the PROM's bank-probe window */
  uint32_t memcfg0_cpu() const { return __builtin_bswap32(memcfg[0]); }
  uint32_t memcfg1_cpu() const { return __builtin_bswap32(memcfg[1]); }
};


#endif


