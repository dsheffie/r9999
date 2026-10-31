#include "top.hh"
#include <deque>
#include "sgi_indy.hh"
#include "sgi_scsi.hh"
#include "sgi_seeq.hh"
#include "sgi_ps2.hh"

/* l2.sv's `ifdef VERILATOR` L2DBG descriptor-line tracer DPI probes are only
 * implemented in the henry full-system tb (henry_tb.cpp).  ooo_core does no L2
 * tracing, so give it no-op defs to satisfy the link. */
extern "C" void l2_line_log(int, unsigned long long, unsigned long long,
                            unsigned long long, int, int) {}
extern "C" void l2_chk_log(unsigned long long, int, int, int, int,
                           unsigned long long, unsigned long long) {}

/* Checkpoint-resume DPI seed hooks (used by the henry full-system tb to inject a
 * fast-forwarded ISS state at reset).  ooo_core never resumes from a checkpoint, so
 * have_checkpoint() returns 0 -> the RTL seed branches are dead; these stubs only
 * satisfy the linker for the `ifdef VERILATOR` DPI imports in the core RTL. */
extern "C" {
  int       have_checkpoint(void)               { return 0; }
  long long loadgpr(int regid)                  { (void)regid; return 0; }
  long long loadfpr(int regid)                  { (void)regid; return 0; }
  int       loadcp0(int regid)                  { (void)regid; return 0; }
  long long loadcp0_64(int regid)               { (void)regid; return 0; }
  long long loadhilo(int half)                  { (void)half;  return 0; }
  int       loadfcsr(void)                      { return 0; }
  long long loadtlb(int entry, int field)       { (void)entry; (void)field; return 0; }
}

#define BRANCH_DEBUG 1
#define CACHE_STATS 1


bool globals::enClockFuncts = false;
uint64_t globals::icountMIPS = 0;
uint64_t globals::cycle = 0;
bool globals::trace_retirement = false;
bool globals::trace_fp = false;
bool globals::ip28 = false;


static state_t *s = nullptr;
static state_t *ss = nullptr;
static void watch_note(const char *what, uint64_t pc, uint64_t pa, uint64_t data);   /* --watch-va */
static void tag_iss_store(state_t *iss, uint64_t pc, uint64_t st_seq0);               /* last-writer tags */

/* Co-sim TLB mirror (as henry_tb): itlb.sv's tlb_wr_log DPI hook (ENABLE_TLB_MIRROR)
 * hands every RTL TLBWI/TLBWR to the checker, and the ISS TLB is written ONLY from
 * this lossless queue (g_iss_tlb_ext suppresses the ISS's own tlbwi/tlbwr).  Without
 * it the ISS's tlbwr picked its own Random slot, the two 48-entry TLBs drifted, and
 * the checker took refills the RTL did not (checkpoint co-sim desyncs). */
struct pend_tlb_t { int idx; uint64_t ehi, elo0, elo1; uint32_t pm; };
static std::deque<pend_tlb_t> g_pend_tlb;
extern void iss_apply_tlb_write(state_t *s, int idx, uint64_t ehi, uint64_t elo0, uint64_t elo1, uint32_t pm);
extern bool g_iss_tlb_ext;
extern bool g_iss_os_mode;
extern "C" void tlb_wr_log(int entry, long long ehi, long long elo0, long long elo1, int pm) {
  g_pend_tlb.push_back({ entry, (uint64_t)ehi, (uint64_t)elo0, (uint64_t)elo1, (uint32_t)pm << 13 });
}
/* mfc0/dmfc0 of Random (1) or Count (9) reads a value that changes every cycle; the
 * RTL samples it when the mfc0 executes, the checker steps at retire, so the two can
 * never agree exactly.  Adopt the RTL's result for these (the checker still checks
 * everything else the instruction does).  The instruction word must come through the
 * ISS TLB (iss_fetch_inst): get_insn(pc & 0x1fffffff) reads an unrelated physical page
 * for user code, which once "adopted" the RTL's stale v0 into the ISS mid-delay-slot
 * (the go-checkpoint divergence). */
static inline void adopt_timing_cp0(uint32_t insn, state_t *rtl, state_t *iss) {
  const uint32_t op = insn >> 26, fmt = (insn >> 21) & 31, rd = (insn >> 11) & 31;
  if(op == 0x10 && (fmt == 0 || fmt == 1) && (rd == 1 || rd == 9)) {
    const uint32_t rt = (insn >> 16) & 31;
    iss->gpr[rt] = rtl->gpr[rt];
  }
}

/* cfc1 $31 (FCSR): the sticky cause/flag bits differ between the RTL and the ISS for some
 * FP op (the IP28 PROM's FPU POST leaves Inexact set on the RTL only) -- a separate FP
 * question.  Report each difference (the first few), then adopt the RTL's FCSR so the
 * checker keeps running. */
static inline void adopt_fcsr_read(uint32_t insn, uint64_t pc, state_t *rtl, state_t *iss) {
  const uint32_t op = insn >> 26, fmt = (insn >> 21) & 31, rd = (insn >> 11) & 31;
  if((op == 0x11) && (fmt == 2) && (rd == 31)) {
    const uint32_t rt = (insn >> 16) & 31;
    if(iss->gpr[rt] != rtl->gpr[rt]) {
      static int n = 0;
      if(n++ < 16) {
	fprintf(stderr, "[fcsr-adopt] pc=%08x FCSR rtl=%08x iss=%08x\n", (uint32_t)pc,
		(uint32_t)rtl->gpr[rt], (uint32_t)iss->gpr[rt]);
      }
      iss->gpr[rt] = rtl->gpr[rt];
      iss->fcr1[CP1_CR31] = (uint32_t)rtl->gpr[rt];
    }
  }
}

/* The hook fires at the negedge, after the cycle's checker steps, so apply the queue
 * BEFORE every ISS step: an instruction retiring after a TLB write must see it. */
static inline void iss_step(state_t *iss) {
  while(!g_pend_tlb.empty()) {
    const pend_tlb_t &p = g_pend_tlb.front();
    iss_apply_tlb_write(iss, p.idx, p.ehi, p.elo0, p.elo1, p.pm);
    g_pend_tlb.pop_front();
  }
  const size_t n_st = g_iss_stores.size();
  const uint64_t pc0 = iss->pc, st_seq0 = g_iss_st_seq;
  execMips(iss);
  tag_iss_store(iss, pc0, st_seq0);
  iss->gpr[0] = 0;   /* some ISS paths write $zero (a device read `lw $zero, ...`) */
  if(g_iss_stores.size() > n_st) {
    const store_rec &r = g_iss_stores.back();
    watch_note("iss-store", r.pc, r.addr, r.data);
  }
}
/* The L1I is not coherent with stores, so the RTL may legally run a stale word: IRIX
 * utlbmiss_reset rewrites the first word of the refill vectors (0x80000000/0x80000080)
 * with no I-cache flush -- the old `ld k1,PDA` and the new `b` reach the same handler.
 * The ISS has no I-cache, so for one step it runs the word the RTL fetched (patched
 * into ISS memory, then put back unless that step stored over it). */
struct stale_fetch_t {
  uint32_t pa = 0, mem_word = 0, rtl_word = 0;
  bool active = false;
};
static uint64_t g_stale_fetches = 0;
static stale_fetch_t stale_fetch_begin(state_t *iss, uint64_t pc, uint32_t rtl_insn) {
  stale_fetch_t f;
  uint32_t pa = 0;
  const uint32_t w = iss_fetch_inst(iss, pc, &pa);
  if((pa == ~0u) || (w == rtl_insn)) {
    return f;
  }
  if(g_stale_fetches++ < 32) {
    fprintf(stderr, "[stale-ifetch] cyc %llu pc=%016llx pa=%08x: RTL ran %08x, memory holds %08x\n",
	    (unsigned long long)globals::cycle, (unsigned long long)pc, pa, rtl_insn, w);
  }
  f.pa = pa;
  f.mem_word = iss->mem.get<uint32_t>(pa);
  f.rtl_word = bswap<IS_LITTLE_ENDIAN>(rtl_insn);
  f.active = true;
  iss->mem.set<uint32_t>(pa, f.rtl_word);
  return f;
}
static void stale_fetch_end(state_t *iss, const stale_fetch_t &f) {
  if(f.active && (iss->mem.get<uint32_t>(f.pa) == f.rtl_word)) {
    iss->mem.set<uint32_t>(f.pa, f.mem_word);
  }
}
static uint64_t insns_retired = 0;
static uint64_t pipestart = 0, pipeend = ~(0UL);
static pipeline_logger *pl = nullptr;
static uint64_t l1d_misses = 0, l1d_insns = 0;
static uint64_t last_retire_cycle = 0, last_retire_pc  = 0;

static std::map<uint64_t, uint64_t> retire_map;

static uint64_t n_fetch[5] = {0};
static uint64_t n_resteer_bubble = 0;
static uint64_t n_fq_full = 0;

static uint64_t n_uq_full[3] = {0};
static uint64_t n_alloc[3] = {0};
static uint64_t n_rdy[3] = {0};

static uint64_t n_int_exec[2] = {0};
static uint64_t n_mem_exec[3] = {0};

static uint64_t q_full[3] = {0};
static uint64_t dq_empty =  0;
static uint64_t uq_full = 0;
static uint64_t n_active = 0;
static uint64_t rob_full = 0;

static uint64_t l1d_reqs = 0;
static uint64_t l1d_acks = 0;
static uint64_t l1d_stores = 0;

static std::map<int,uint64_t> block_distribution;
static std::map<int,uint64_t> restart_distribution;
static std::map<int,uint64_t> restart_ds_distribution;
static std::map<int,uint64_t> fault_distribution;
static std::map<int,uint64_t> branch_distribution;
static std::map<int,uint64_t> fault_to_restart_distribution;

/* boot a real SGI PROM from the current directory: --ip22 (Indy, R4400) or --ip28
 * (Indigo2, R10000; build with ENABLE_R10000).  sgi_prom = either. */
static bool sgi_ip22 = false, sgi_ip28 = false, sgi_prom = false;
/* --disk: the SCSI disk (target 1, dksc(0,1,*)); guest writes stay in memory */
static std::string disk_image;
static sgi_mc *mc = nullptr;
static sgi_hpc *hpc = nullptr;
static sgi_scc *scc = nullptr;

/* the SGI board: indysim's device models (sgi_hpc/mc/scc/scsi/seeq/ps2), which hang off
 * state_t; mc/hpc/scc above are the same objects, for the MMIO paths below */
static void attach_sgi_devices(state_t *st) {
  st->mc = mc = new sgi_mc(st);
  st->hpc = hpc = new sgi_hpc(st);
  st->scc = scc = new sgi_scc(st);
  st->scsi = new sgi_scsi(st, disk_image);   /* no --disk: every selection times out */
  st->seeq = new sgi_seeq(st);
  if(globals::ip28) {
    st->ps2 = new sgi_ps2(st);       /* the IP28 PROM's POST tests the 8042 */
  }
}

/* --ip28: the memory decode the MC applies to a CPU physical address (indysim
 * interpret.cc ip28_mem_window).  The PROM sizes memory by programming MEMCFG -- in 16 MB
 * units, base 0x20 -- and probing; a flat 4 GB array would answer everywhere (it sized
 * 2 GB and overflowed).  A bank decodes [base, base + (size field + 1) * 16 MB); bank 0
 * holds the 256 MB, stored in place at 0x20000000 (the DMA models use the real PA) and
 * wrapping as real SIMMs alias; the low 512 KB alias is the base of memory.  Returns
 * false where nothing decodes: loads read 0, stores vanish. */
/* --ip28: the Indigo2's EISA bus with no cards -- I/O (0x00080000-0x0009ffff, alias
 * included) and memory (0x000a0000-0x07ffffff).  An empty bus floats high: reads are all
 * ones, writes go nowhere.  Backed by memory, the slot ID registers read 0 and Linux
 * found four "@@@0000" cards. */
static inline bool ip28_eisa(uint32_t pa) {
  return globals::ip28 && (pa >= 0x00080000u) && (pa < 0x08000000u);
}

static bool ip28_mem_pa(uint32_t &pa) {
  if(pa < 0x00080000u) {
    pa += 0x20000000u;
    return true;
  }
  if((pa < 0x20000000u) || (pa >= 0x60000000u)) {
    return true;
  }
  for(int b = 0; b < 4; b++) {
    const uint32_t reg = (b < 2) ? mc->memcfg0_cpu() : mc->memcfg1_cpu();
    const uint32_t cfg = ((b & 1) ? reg : (reg >> 16)) & 0xffffu;
    if(((cfg >> 13) & 1) == 0) {
      continue;
    }
    const uint32_t base = (cfg & 0xffu) << 24;
    const uint32_t size = (((cfg >> 8) & 0x1fu) + 1u) << 24;
    if((pa >= base) && ((pa - base) < size)) {
      if(b == 0) {
        pa = 0x20000000u + ((pa - base) & 0x0fffffffu);
        return true;
      }
      return false;
    }
  }
  return false;
}

/* --- co-sim checker for SGI PROM / IRIX runs (--ip22/--ip28 with --checker true).  The ISS
 * has no devices; it follows the RTL where it cannot know the answer and checks the rest. */

/* a load the ISS cannot model -- a device register, an uncached access, or (IP28) memory
 * the MC decode does not back as the ISS's flat memory does -- takes the RTL's value.
 * Classified BEFORE the ISS executes it (the load may overwrite its own base register):
 * returns the destination GPR to adopt after the step, or 0 */
static uint32_t unmodeled_load_dst_at(state_t *iss, uint64_t pc) {
  const uint32_t insn = iss_fetch_inst(iss, pc, nullptr);
  const uint32_t op = insn >> 26;
  const bool gpr_load = ((op >= 0x20) && (op <= 0x27)) || (op == 0x37) || (op == 0x1a) ||
			(op == 0x1b) || (op == 0x30) || (op == 0x34);
  if(!gpr_load) {
    return 0;
  }
  const uint64_t va = (uint64_t)iss->gpr[(insn >> 21) & 31] + (uint64_t)(int64_t)(int16_t)(insn & 0xffffu);
  uint32_t pa = 0;
  bool uncached = false;
  if(!iss_load_class(iss, va, &pa, &uncached)) {
    return 0;
  }
  uint32_t mpa = pa;
  const bool unbacked = ip28_eisa(pa) ||
			(globals::ip28 && (pa >= 0x20000000u) && (!ip28_mem_pa(mpa) || (mpa != pa)));
  return (uncached || unbacked) ? ((insn >> 16) & 31) : 0;
}

/* sc/scd may fail whenever the link is lost (an interrupt, an exception, the line leaving
 * the L1D), so its outcome is timing: before the ISS executes one, give it the RTL's
 * (s->gpr[rt], already the retired 1/0) -- linked to the SC's line if the RTL succeeded,
 * unlinked if not -- so it also stores, or does not, as the RTL did */
static void follow_rtl_sc(state_t *rtl, state_t *iss, uint64_t pc) {
  const uint32_t insn = iss_fetch_inst(iss, pc, nullptr);
  const uint32_t op = insn >> 26;
  if((op != 0x38) && (op != 0x3c)) {
    return;
  }
  const uint32_t rt = (insn >> 16) & 31;
  const uint64_t va = (uint64_t)iss->gpr[(insn >> 21) & 31] + (uint64_t)(int64_t)(int16_t)(insn & 0xffffu);
  uint32_t pa = 0;
  bool uncached = false;
  if(!iss_load_class(iss, va, &pa, &uncached)) {
    return;   /* faults: no link question */
  }
  iss->ll_link_valid = (rtl->gpr[rt] != 0);
  iss->ll_link_addr = (uint64_t)pa & ~UINT64_C(0xf);
}

/* the ISS executes a branch and its delay slot in one step, but the RTL may retire the
 * slot a cycle later: an unmodeled load in a delay slot is adopted when the RTL retires
 * it (g_ds_adopt_pc) */
static uint64_t g_ds_adopt_pc = 0;
static uint32_t g_ds_adopt_rt = 0;
static inline bool has_delay_slot(uint32_t insn) {
  const uint32_t op = insn >> 26, funct = insn & 63;
  return ((op == 0) && ((funct == 8) || (funct == 9))) ||      /* jr, jalr */
	 (op == 1) || (op == 2) || (op == 3) ||                  /* regimm, j, jal */
	 ((op >= 4) && (op <= 7)) || ((op >= 0x14) && (op <= 0x17)) ||   /* b* , b*l */
	 ((op == 0x11) && (((insn >> 21) & 31) == 8));            /* bc1* */
}
static uint32_t unmodeled_load_dst(state_t *iss, uint64_t pc) {
  if(has_delay_slot(iss_fetch_inst(iss, pc, nullptr))) {
    g_ds_adopt_rt = unmodeled_load_dst_at(iss, pc + 4);
    g_ds_adopt_pc = pc + 4;
    return 0;
  }
  return unmodeled_load_dst_at(iss, pc);
}
static inline void adopt_ds_load(uint64_t rpc) {
  if((g_ds_adopt_rt != 0) && ((uint32_t)rpc == (uint32_t)g_ds_adopt_pc)) {
    ss->gpr[g_ds_adopt_rt] = s->gpr[g_ds_adopt_rt];
    g_ds_adopt_rt = 0;
  }
}

/* last-writer tags (co-sim, --ip28): for every 16-byte line of IP28 RAM, who wrote it last
 * -- in the RTL's architectural view (its store commits), in the RTL's memory (L2
 * writebacks and uncached stores at the memory port, DMA) and in the ISS's memory (its
 * stores, DMA mirrored).  A register mismatch on a load prints all three for that line,
 * which says whether the word came from the core or from traffic outside it. */
enum wtag_who_t : uint8_t { WT_NONE = 0, WT_RTL_STORE, WT_MEM_PORT, WT_DMA, WT_ISS_STORE };
struct wtag_t {
  uint64_t cyc;
  uint32_t pc;
  uint8_t who;
};
static wtag_t *g_tag_rtl_arch = nullptr, *g_tag_rtl_mem = nullptr, *g_tag_iss = nullptr;
static const uint32_t TAG_BASE = 0x20000000u, TAG_SIZE = 0x10000000u;
static void tags_alloc() {
  const size_t n = TAG_SIZE >> 4;
  g_tag_rtl_arch = static_cast<wtag_t*>(calloc(n, sizeof(wtag_t)));
  g_tag_rtl_mem = static_cast<wtag_t*>(calloc(n, sizeof(wtag_t)));
  g_tag_iss = static_cast<wtag_t*>(calloc(n, sizeof(wtag_t)));
}
static inline wtag_t *tag_at(wtag_t *t, uint32_t pa) {
  if(t == nullptr) {
    return nullptr;
  }
  if(pa < 0x00080000u) {
    pa += TAG_BASE;   /* the low alias is the base of RAM */
  }
  return ((pa >= TAG_BASE) && (pa < (TAG_BASE + TAG_SIZE))) ? &t[(pa - TAG_BASE) >> 4] : nullptr;
}
static inline void tag_set(wtag_t *t, uint32_t pa, uint8_t who, uint64_t pc) {
  wtag_t *e = tag_at(t, pa);
  if(e != nullptr) {
    e->cyc = globals::cycle;
    e->pc = (uint32_t)pc;
    e->who = who;
  }
}
static void tag_print(const char *side, wtag_t *t, uint32_t pa) {
  static const char *names[] = {"never written", "RTL store", "memory port (L2 wb / uncached)", "DMA", "ISS store"};
  const wtag_t *e = tag_at(t, pa);
  if(e == nullptr) {
    fprintf(stderr, "    %-9s: (not tracked)\n", side);
    return;
  }
  fprintf(stderr, "    %-9s: %s, pc=%08x, cyc=%llu\n", side, names[e->who], e->pc, (unsigned long long)e->cyc);
}
static void tag_iss_store(state_t *iss, uint64_t pc, uint64_t st_seq0) {
  uint32_t pa = 0;
  bool uncached = false;
  if((g_tag_iss != nullptr) && (g_iss_st_seq != st_seq0) && iss_load_class(iss, g_iss_last_st_va, &pa, &uncached)) {
    tag_set(g_tag_iss, pa, WT_ISS_STORE, pc);
  }
}

/* on a checker mismatch: the ISS's last load, its line's three last writers and the
 * doubleword in each memory */
static void tags_report_last_load() {
  if((g_tag_iss == nullptr) || (ss == nullptr)) {
    return;
  }
  uint32_t pa = 0;
  bool uncached = false;
  if(!iss_load_class(ss, g_iss_last_ld_va, &pa, &uncached)) {
    return;
  }
  uint32_t rpa = pa & ~7u;
  if(globals::ip28) {
    ip28_mem_pa(rpa);
  }
  fprintf(stderr, "[last-writer] ISS last load va=%016llx pa=%08x%s: ISS mem=%016llx RTL DRAM=%016llx\n",
	  (unsigned long long)g_iss_last_ld_va, pa, uncached ? " (uncached)" : "",
	  (unsigned long long)__builtin_bswap64(ss->mem.get<uint64_t>(pa & ~7u)),
	  (unsigned long long)__builtin_bswap64(s->mem.get<uint64_t>(rpa)));
  tag_print("RTL arch", g_tag_rtl_arch, pa);
  tag_print("RTL mem", g_tag_rtl_mem, pa);
  tag_print("ISS mem", g_tag_iss, pa);
}

/* the device models' DMA writes land in the RTL's memory; the checker ISS keeps its own */
static bool g_dma_mirror = false;
void sgi_dma_wrote(state_t *st, uint64_t pa, size_t n) {
  if(g_dma_mirror && (ss != nullptr)) {
    memcpy(ss->mem.get_raw_ptr(pa), st->mem.get_raw_ptr(pa), n);
  }
  watch_note("dma", 0, pa, n);
  for(size_t i = 0; i < n; i += 16) {
    tag_set(g_tag_rtl_mem, (uint32_t)(pa + i), WT_DMA, 0);
    tag_set(g_tag_iss, (uint32_t)(pa + i), WT_DMA, 0);
  }
}

/* store check (rv64core's, via henry_tb): l1d.sv reports each store written into the L1D
 * array (wr_log, ENABLE_STORE_CHECK), the ISS each store it executes (interpret.cc
 * STORE_CHECK); both are program order, so the first front-to-front mismatch is the
 * root store -- a lost, extra or wrong store, caught where it happens */
/* --watch-va: follow one virtual address's line through both sides -- RTL store commits,
 * ISS stores, DMA, and the L2's fills / writebacks -- resolved to a PA through the ISS's
 * TLB (the RTL's, mirrored) at each event */
static uint64_t g_watch_va = 0;
static uint32_t watch_line() {
  uint32_t pa = 0;
  bool uncached = false;
  if((g_watch_va == 0) || (ss == nullptr) || !iss_load_class(ss, g_watch_va, &pa, &uncached)) {
    return ~0u;
  }
  return pa & ~0xfu;
}
static void watch_note(const char *what, uint64_t pc, uint64_t pa, uint64_t data) {
  if((g_watch_va != 0) && (((uint32_t)pa & ~0xfu) == watch_line())) {
    fprintf(stderr, "[watch] cyc=%llu %s pc=%08x pa=%09llx data=%016llx\n", (unsigned long long)globals::cycle,
	    what, (uint32_t)pc, (unsigned long long)pa, (unsigned long long)data);
  }
}

/* at the end of a run: the watched doubleword as each side's memory holds it (the RTL's
 * DRAM copy; the newest may still sit in its caches) */
static void watch_dump() {
  const uint32_t line = watch_line();
  if((g_watch_va == 0) || (line == ~0u)) {
    return;
  }
  uint32_t pa = 0;
  bool uncached = false;
  iss_load_class(ss, g_watch_va, &pa, &uncached);
  pa &= ~7u;
  uint32_t rpa = pa;
  if(globals::ip28) {
    ip28_mem_pa(rpa);
  }
  fprintf(stderr, "[watch] va=%016llx pa=%08x: ISS mem=%016llx  RTL DRAM=%016llx\n",
	  (unsigned long long)g_watch_va, pa,
	  (unsigned long long)__builtin_bswap64(ss->mem.get<uint64_t>(pa)),
	  (unsigned long long)__builtin_bswap64(s->mem.get<uint64_t>(rpa)));
  tag_print("RTL arch", g_tag_rtl_arch, pa);
  tag_print("RTL mem", g_tag_rtl_mem, pa);
  tag_print("ISS mem", g_tag_iss, pa);
}

std::deque<store_rec> g_iss_stores;
static std::deque<store_rec> g_rtl_stores;
static bool g_store_check = false, g_store_diverged = false;
static uint64_t g_stores_checked = 0;
extern "C" void wr_log(long long pc, int rob_ptr, unsigned long long addr,
		       unsigned long long data, int is_atomic) {
  (void)rob_ptr;
  (void)is_atomic;
  if(g_store_check) {
    g_rtl_stores.emplace_back((uint64_t)pc, addr, data);
  }
  watch_note("rtl-store", (uint64_t)pc, addr, data);
  tag_set(g_tag_rtl_arch, (uint32_t)addr, WT_RTL_STORE, (uint64_t)pc);
}
/* the rest of l1d.sv's ENABLE_STORE_CHECK hooks: henry_tb's line-lifecycle traces (no-ops
 * here), and the dirty-set-drop watch, which flags a store whose dirty bit lost the L1D's
 * dirty-bit write port to a refill or invalidate -- the line then looks clean and can be
 * evicted without its writeback, i.e. a lost store */
extern "C" void l1d_wb_log(unsigned long long, unsigned long long, unsigned long long) {
}
extern "C" void rd_log(long long, unsigned long long, unsigned long long, int) {
}
extern "C" void l1d_fill(unsigned long long, long long, unsigned long long, unsigned long long,
			 unsigned long long) {
}
extern "C" void l1d_cacheop(unsigned long long, long long, unsigned long long, int) {
}
extern "C" void dirtydrop(unsigned long long cycle, long long pc, unsigned long long pa, int by_refill) {
  static uint64_t n = 0;
  if(n++ < 64) {
    fprintf(stderr, "[dirtydrop] cyc=%llu pc=%08x pa=%09llx store's dirty bit lost to %s\n",
	    cycle, (uint32_t)pc, pa, by_refill ? "a refill" : "an invalidate");
  }
}
static void drain_store_check() {
  while(!g_iss_stores.empty() && !g_rtl_stores.empty()) {
    const store_rec &i = g_iss_stores.front(), &r = g_rtl_stores.front();
    if((((uint32_t)i.pc) != ((uint32_t)r.pc)) || (i.addr != r.addr) || (i.data != r.data)) {
      fprintf(stderr, "[STORE-CHECK] ROOT STORE DIVERGENCE at cycle %llu\n"
	      "  ISS pc=%08x addr=%09llx data=%016llx\n"
	      "  RTL pc=%08x addr=%09llx data=%016llx\n",
	      (unsigned long long)globals::cycle,
	      (uint32_t)i.pc, (unsigned long long)i.addr, (unsigned long long)i.data,
	      (uint32_t)r.pc, (unsigned long long)r.addr, (unsigned long long)r.data);
      fprintf(stderr, "  [queues] ISS depth=%zu RTL depth=%zu\n", g_iss_stores.size(), g_rtl_stores.size());
      for(size_t k = 0; (k < 8) && (k < g_iss_stores.size()); k++) {
	fprintf(stderr, "    ISS[%zu] pc=%08x addr=%09llx data=%016llx\n", k, (uint32_t)g_iss_stores[k].pc,
		(unsigned long long)g_iss_stores[k].addr, (unsigned long long)g_iss_stores[k].data);
      }
      for(size_t k = 0; (k < 8) && (k < g_rtl_stores.size()); k++) {
	fprintf(stderr, "    RTL[%zu] pc=%08x addr=%09llx data=%016llx\n", k, (uint32_t)g_rtl_stores[k].pc,
		(unsigned long long)g_rtl_stores[k].addr, (unsigned long long)g_rtl_stores[k].data);
      }
      g_store_diverged = true;
      return;
    }
    g_iss_stores.pop_front();
    g_rtl_stores.pop_front();
    g_stores_checked++;
  }
}

/* a device read/write at the access's own size: the models take it (the IP28 8254,
 * EEPROM and SYS_ID are byte registers), the RTL presents a word and its byte mask
 * wm.  A contiguous 1/2/4-byte access goes as one; anything else byte by byte. */
template <typename R>
static uint32_t device_word_read(uint32_t addr, uint32_t wm, R rd) {
  if(wm == 15) {
    return rd(addr, 4);
  }
  if(wm == 0) {
    return 0;
  }
  const uint32_t first = __builtin_ctz(wm), n = __builtin_popcount(wm);
  if(((wm >> first) == ((1u << n) - 1)) && (n <= 2)) {
    return rd(addr + first, n) << (8 * first);
  }
  uint32_t d = 0;
  for(uint32_t j = 0; j < 4; j++) {
    if((wm >> j) & 1) {
      d |= (rd(addr + j, 1) & 0xffu) << (8 * j);
    }
  }
  return d;
}
template <typename W>
static void device_word_write(uint32_t addr, uint32_t wm, uint32_t d, W wr) {
  if(wm == 15) {
    wr(addr, d, 4);
    return;
  }
  if(wm == 0) {
    return;
  }
  const uint32_t first = __builtin_ctz(wm), n = __builtin_popcount(wm);
  if(((wm >> first) == ((1u << n) - 1)) && (n <= 2)) {
    wr(addr + first, (d >> (8 * first)) & ((n == 1) ? 0xffu : 0xffffu), n);
    return;
  }
  for(uint32_t j = 0; j < 4; j++) {
    if((wm >> j) & 1) {
      wr(addr + j, (d >> (8 * j)) & 0xffu, 1);
    }
  }
}
static const uint32_t SCC_BASE = 0x1fbd9830u;  /* IOC2 serial SCC window base */


static const char* l1d_stall_str[8] =
  {
   "no stall", //0
   "got miss", //1 
   "full memory queue", //2
   "not possible", //3
   "load retry", //4
   "store to same set", //5
   "cm block stall", //6
   "inflight rob ptr", //7
};
static uint64_t l1d_stall_reasons[8] = {0};

static bool pending_fault = false;
static uint64_t fault_start_cycle = 0;

void record_branches(int n_branches) {
  branch_distribution[n_branches]++;
}

// timer-IRQ trace DPI: only henry_tb records it (for its monitor `timer` query);
// ooo_core just needs the symbol, so this is a no-op here.
void log_timer_irq(void) {}

void record_faults(int n_faults) {
  fault_distribution[n_faults]++;
  if(n_faults && not(pending_fault)) {
    pending_fault = true;
    fault_start_cycle = globals::cycle;
  }
}

void record_restart(int cycles) {
  restart_distribution[cycles]++;
  pending_fault = false;

  fault_to_restart_distribution[(globals::cycle - fault_start_cycle)]++;
  fault_start_cycle = 0;
  //std::cout << "clearing fault took "
  //<< (globals::cycle - fault_start_cycle)
  //<< " cycles\n";
}

void record_ds_restart(int cycles) {
  restart_ds_distribution[cycles]++;
}


void record_l1d(int req, int ack, int ack_st, int blocked, int stall_reason) {
  l1d_reqs += req;
  l1d_acks += ack;
  l1d_stores += ack_st;
  block_distribution[__builtin_popcount(blocked)]++;
  l1d_stall_reasons[stall_reason&15]++;
}

static std::map<int, uint64_t> int_sched_rdy_map;

void report_exec(int int_valid, int int_ready,
		 int mem_valid, int mem_ready,
		 int fp_valid,  int fp_ready,
		 int intq_full, int memq_full,
		 int fpq_full,
		 int blocked_by_store,
		 int ready_int) {
  n_int_exec[0] += int_valid;
  n_int_exec[1] += int_ready;
  n_mem_exec[0] += mem_valid;
  n_mem_exec[1] += mem_ready;
  n_mem_exec[2] += blocked_by_store;
    
  q_full[0] += intq_full;
  q_full[1] += memq_full;
  q_full[2] += fpq_full;
  
  int_sched_rdy_map[__builtin_popcount(ready_int)]++;
}


void record_alloc(int rf,
		  int a1, int a2, int de,
		  int f1, int f2,
		  int r1, int r2, int active) {

  rob_full += rf;
  dq_empty += de;
  uq_full += f1;
  n_active += active;
  
  if(a2)
    ++n_alloc[2];
  else if(a1)
    ++n_alloc[1];
  else
    ++n_alloc[0];

  if(f2)
    ++n_uq_full[2];
  else if(f1)
    ++n_uq_full[1];
  else
    ++n_uq_full[0];
  
  if(r2)
    ++n_rdy[2];
  else if(r1)
    ++n_rdy[1];
  else
    ++n_rdy[0];
  
}


void record_fetch(int p1, int p2, int p3, int p4, 
		  long long pc1, long long pc2, long long pc3, long long pc4,
		  int bubble, int fq_full) {
  n_resteer_bubble += bubble;
  n_fq_full += fq_full;


  if(p1)
    ++n_fetch[1];
  else if(p2)
    ++n_fetch[2];
  else if(p3)
    ++n_fetch[3];
  else if(p4)
    ++n_fetch[4];
  else
    ++n_fetch[0];
}

static std::map<int, uint64_t> mem_lat_map, fp_lat_map, non_mem_lat_map;

int check_insn_bytes(long long pc, int data) {
  uint32_t insn = get_insn(pc, s);
  return (*reinterpret_cast<uint32_t*>(&data)) == insn;
}

static long long lrc = -1;
static uint64_t record_insns_retired = 0;

/* TOP-DOWN accounting (core.sv `ifdef TOPDOWN, --topdown).  core.sv reports, every
 * cycle, the state, how many uops the decode queue offered (0/1/2), how many
 * allocated and retired, and why an offered slot did not allocate.  Accumulated
 * only inside the --pipestart/--pipeend retired-insn window. */
namespace topdown {
  static bool enabled = false;
  static uint64_t cycles = 0, retired = 0, allocated = 0;
  static uint64_t fe_lat = 0, fe_bw = 0;        /* 0 offered / 1 offered (slots) */
  static uint64_t be[8] = {0};                  /* offered-not-allocated slots by reason */
  static uint64_t state_cyc[32] = {0};          /* cycles by core state */
}
extern "C" void topdown_cycle(int st, int avail, int nalloc, int nret, int be0, int be1) {
  if(!topdown::enabled || record_insns_retired < pipestart || record_insns_retired >= pipeend) {
    return;
  }
  topdown::cycles++;
  topdown::retired += nret;
  topdown::allocated += nalloc;
  topdown::state_cyc[st & 31]++;
  if(st == 2) {                                 /* ACTIVE: classify the 2 slots */
    if(avail == 0) {
      topdown::fe_lat += 2;
    }
    else if(avail == 1) {
      topdown::fe_bw += 1;
    }
    if(be0) {
      topdown::be[be0 & 7] += avail;            /* nothing allocated: every offered slot */
    }
    if(be1) {
      topdown::be[be1 & 7] += 1;
    }
  }
}
/* fetch groups (l1i.sv TOPDOWN): insns pushed into the fetch queue per cycle,
 * why the group ended, and fetch queue occupancy */
namespace topdown {
  static uint64_t f_cyc = 0, f_insns = 0;
  static uint64_t f_why_cyc[16] = {0}, f_why_insns[16] = {0};
  static uint64_t f_npush[8] = {0}, f_fqcnt[64] = {0};
}
extern "C" void topdown_fetch(int npush, int why, int fq_cnt) {
  if(!topdown::enabled || record_insns_retired < pipestart || record_insns_retired >= pipeend) {
    return;
  }
  topdown::f_cyc++;
  topdown::f_insns += npush;
  topdown::f_why_cyc[why & 15]++;
  topdown::f_why_insns[why & 15] += npush;
  topdown::f_npush[npush & 7]++;
  topdown::f_fqcnt[fq_cnt & 63]++;
}
/* per-uop stage stamps (core.sv / exec.sv TOPDOWN), keyed by rob index.  All in
 * globals::cycle; the ROB's completion stamp is on the core's own r_cycle and is
 * converted with the offset measured at retirement. */
namespace topdown {
  struct stamp_t { uint64_t a = 0, q = 0, i = 0, m = 0; };
  static stamp_t slot[64];
  /* per class (0 alu, 1 branch, 2 load, 3 store): n, and sums of alloc->sched,
   * sched->issue, issue->complete, alloc->complete, complete->retire */
  static uint64_t cls_n[4] = {0};
  static double cls_seg[4][5] = {{0}};
  static uint64_t cls_min[4][5];
  static bool min_init = false;
}
extern "C" void topdown_uop(int ev, int rob_ptr) {
  if(!topdown::enabled) {
    return;
  }
  topdown::stamp_t &e = topdown::slot[rob_ptr & 63];
  const uint64_t c = globals::cycle;
  switch(ev)
    {
    case 0: e = topdown::stamp_t(); e.a = c; break;   /* allocation: a fresh entry */
    case 1: e.q = c; break;                           /* enters the ALU scheduler */
    case 2: e.i = c; break;                           /* ALU execute starts */
    case 3: e.m = c; break;                           /* memory uop to address gen */
    default: break;
    }
}
extern "C" void topdown_retire_uop(int rob_ptr, long long alloc_c, long long complete_c,
                                   long long retire_c, int is_br, int is_store) {
  using namespace topdown;
  if(!enabled || record_insns_retired < pipestart || record_insns_retired >= pipeend) {
    return;
  }
  if(!min_init) {
    for(auto &r : cls_min) { for(auto &x : r) { x = ~0ull; } }
    min_init = true;
  }
  const stamp_t &e = slot[rob_ptr & 63];
  const long long off = (long long)globals::cycle - retire_c;     /* core r_cycle -> globals::cycle */
  const uint64_t c = (uint64_t)(complete_c + off), r = globals::cycle;
  if(e.a == 0 || c < e.a) {
    return;                                        /* no allocation stamp (window edge) */
  }
  int k;
  uint64_t start;                                  /* when it left the queue for execution */
  if(e.m) {
    k = is_store ? 3 : 2;
    start = e.m;
  }
  else if(e.i) {
    k = is_br ? 1 : 0;
    start = e.i;
  }
  else {
    return;                                        /* nop / never issued: skip */
  }
  const uint64_t q = e.m ? e.m : (e.q ? e.q : start);
  const uint64_t seg[5] = {q - e.a, start - q, c - start, c - e.a, r - c};
  cls_n[k]++;
  for(int j = 0; j < 5; j++) {
    cls_seg[k][j] += seg[j];
    cls_min[k][j] = std::min(cls_min[k][j], seg[j]);
  }
}
static void topdown_report() {
  using namespace topdown;
  static const char *st_name[16] = {"FLUSH_FOR_HALT","HALT","ACTIVE","DRAIN","RAT","DELAY_SLOT",
    "ALLOC_FOR_SERIALIZE","HALT_WAIT_FOR_RESTART","WAIT_FOR_SERIALIZE_AND_RESTART","ARCH_FAULT",
    "WRITE_EPC","EXCEPTION_DRAIN","SERIALIZE_IN_FAULTED_DELAY_SLOT",
    "WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT","CACHE_FLUSH","DEAD"};
  static const char *be_name[8] = {"-","ROB full","uop queue full","free list short",
    "oldest-first pending","pending fault","other","pairing rule"};
  const double slots = 2.0 * cycles;
  if(cycles == 0) {
    std::cout << "topdown: no cycles in window\n";
    return;
  }
  /* non-ACTIVE cycles: recovery after a mispredict/exception = bad speculation,
   * serialization = backend */
  uint64_t recov = 0, serial = 0;
  for(int i = 0; i < 16; i++) {
    if(i == 3 || i == 4 || i == 5 || i == 9 || i == 10 || i == 11 || i == 12 || i == 13) {
      recov += state_cyc[i];
    }
    else if(i != 2) {
      serial += state_cyc[i];
    }
  }
  uint64_t be_sum = 0;
  for(int i = 1; i < 8; i++) {
    be_sum += be[i];
  }
  const double squashed = (allocated > retired) ? (double)(allocated - retired) : 0.0;
  const double t_ret = retired / slots, t_bad = (squashed + 2.0 * recov) / slots;
  const double t_fe = (fe_lat + fe_bw) / slots, t_be = (be_sum + 2.0 * serial) / slots;
  std::cout << "==== TOP-DOWN (retired-insn window " << pipestart << ".." << pipeend
            << ", " << cycles << " cycles, " << (uint64_t)slots << " slots, IPC "
            << (double)retired / cycles << ") ====\n";
  printf("  retiring        %5.1f%%\n", 100 * t_ret);
  printf("  bad speculation %5.1f%%   (squashed uops %.0f + recovery %lu cyc)\n", 100 * t_bad, squashed, (unsigned long)recov);
  printf("  frontend bound  %5.1f%%   (latency: nothing offered %5.1f%%, bandwidth: 1 of 2 offered %5.1f%%)\n",
         100 * t_fe, 100 * fe_lat / slots, 100 * fe_bw / slots);
  printf("  backend bound   %5.1f%%   (serializing states %lu cyc)\n", 100 * t_be, (unsigned long)serial);
  for(int i = 1; i < 8; i++) {
    if(be[i]) {
      printf("      %-22s %5.1f%%\n", be_name[i], 100 * be[i] / slots);
    }
  }
  static const char *cls_name[4] = {"alu", "branch", "load", "store"};
  printf("  stage latency, mean (min) cycles:   alloc->sched   sched->issue   issue->complete   alloc->complete   complete->retire\n");
  for(int k = 0; k < 4; k++) {
    if(cls_n[k] == 0) {
      continue;
    }
    printf("    %-7s n=%-6lu", cls_name[k], (unsigned long)cls_n[k]);
    for(int j = 0; j < 5; j++) {
      printf("   %6.2f (%2lu)", cls_seg[k][j] / cls_n[k], (unsigned long)cls_min[k][j]);
    }
    printf("\n");
  }
  printf("    (memory ops: 'sched' = dispatch from the memory uop queue to address generation)\n");
  printf("  (sum %.1f%%)  cycles by state:", 100 * (t_ret + t_bad + t_fe + t_be));
  for(int i = 0; i < 16; i++) {
    if(state_cyc[i]) {
      printf(" %s=%lu", st_name[i], (unsigned long)state_cyc[i]);
    }
  }
  printf("\n");
  if(f_cyc) {
    static const char *why_name[10] = {"full group of 4","cut at 16B line end","cut before taken cflow",
      "cflow insn alone","delay slot alone","fetch queue full","resteer bubble","miss/tlb/other state",
      "restart/flush","group + taken br + ds"};
    printf("  fetch: %.3f insns/cycle over %lu cycles; group size hist:", (double)f_insns / f_cyc,
           (unsigned long)f_cyc);
    for(int i = 0; i <= 4; i++) {
      printf(" %d=%.1f%%", i, 100.0 * f_npush[i] / f_cyc);
    }
    printf("\n    why the group ended      %%cycles   insns/group\n");
    for(int i = 0; i < 10; i++) {
      if(f_why_cyc[i]) {
        printf("    %-24s %6.1f%%   %.2f\n", why_name[i], 100.0 * f_why_cyc[i] / f_cyc,
               (double)f_why_insns[i] / f_why_cyc[i]);
      }
    }
    double occ = 0;
    printf("    fetch queue occupancy:");
    for(int i = 0; i < 64; i++) {
      occ += (double)i * f_fqcnt[i];
      if(f_fqcnt[i]) {
        printf(" %d=%.1f%%", i, 100.0 * f_fqcnt[i] / f_cyc);
      }
    }
    printf("  (mean %.2f)\n", occ / f_cyc);
  }
}

/* pipetrace stage events (+define+PIPETRACE hooks in core/exec/l1d), keyed by rob
 * index: cleared at allocation, appended by the pipe, attached to the record
 * when pt_retire names the rob slot record_retirement is about to retire. */
namespace pt {
  static std::list<std::pair<uint64_t, char>> ev[64];
  static int cur = -1;
}
extern "C" void pt_alloc(int rob_ptr) {
  pt::ev[rob_ptr & 63].clear();
}
extern "C" void pt_event(int rob_ptr, int letter, long long cycle) {
  if(pl != nullptr) {
    pt::ev[rob_ptr & 63].emplace_back((uint64_t)cycle, (char)letter);
  }
}
extern "C" void pt_retire(int rob_ptr) {
  pt::cur = rob_ptr & 63;
}

void record_retirement(long long pc, long long fetch_cycle, long long alloc_cycle, long long complete_cycle, long long retire_cycle,
		       int faulted , int is_mem, int is_fp, int missed_l1d) {

  //if(pc == 0x2033c || pc == 0x20340 || pc == 0x20344 || pc == 0x20348) {
  //auto i = getAsmString(get_insn(pc, s), pc);
  //std::cout << std::hex << pc << std::dec << " " << i << " : " << alloc_cycle << "," << complete_cycle << "," << retire_cycle << "," << faulted << "\n";
  //}
  uint32_t insn = get_insn(pc, s);
  uint64_t delta = retire_cycle - last_retire_cycle;

  if(retire_cycle < lrc) {
    std::cout << "retirement cycle out-of-order\n";
    exit(-1);
  }
  lrc = retire_cycle;
  
  if(is_mem) {
    //auto i = getAsmString(insn, pc);
    //std::cout << std::hex << pc << std::dec << " " << i << " : " << alloc_cycle << ","
    //<< complete_cycle << "," << retire_cycle << "," << faulted << "\n";
    //std::cout << std::hex << pc << std::dec << " " << i << " : "
    mem_lat_map[(complete_cycle-alloc_cycle)]++;
    //<< (complete_cycle-alloc_cycle) << "\n";    
  }
  else if(is_fp) {
    fp_lat_map[(complete_cycle-alloc_cycle)]++;
  }
  else {
    non_mem_lat_map[(complete_cycle-alloc_cycle)]++;
  }
  //if(delta == 3) {
  //std::cout << "curr = " << std::hex << pc << std::dec << " : " << getAsmString(get_insn(pc, s), pc) << "\n";
  //std::cout << "last = " << std::hex << last_retire_pc << std::dec << " : " << getAsmString(get_insn(last_retire_pc, s), last_retire_pc) << "\n";
  //}
  //std::cout << "delta = " << delta << "\n";
  retire_map[delta]++;
  
  last_retire_cycle = retire_cycle;
  last_retire_pc = pc;
  
  if(missed_l1d) {
    //std::cout << "pc = " << std::hex << pc << " missed cache " << std::dec
    //<< " : " << getAsmString(get_insn(pc, s), pc)
    //<< "\n";
    ++l1d_misses;
  }
  l1d_insns += is_mem;
  
  if((pl != nullptr) and (record_insns_retired >= pipestart) and (record_insns_retired < pipeend)) {
    /* loadelf stores the image at va2pa(vaddr), but get_insn() was handed the
     * raw virtual pc -- so every kseg0 (bare-metal) pipetrace disassembled as
     * "nop" (the zero it read decodes to nop).  Translate first. */
    static const std::list<std::pair<uint64_t, char>> no_events;
    pl->append(record_insns_retired, getAsmString(get_insn(va2pa(pc), s), pc), pc, fetch_cycle, alloc_cycle, complete_cycle, retire_cycle, faulted,
	       (pt::cur >= 0) ? pt::ev[pt::cur] : no_events);
  }
  pt::cur = -1;
  ++record_insns_retired;
}

static uint32_t perform_word_load(state_t *s, uint32_t addr, uint16_t m) {
  uint32_t d = 0;
  uint32_t k = addr & 15;
  uint32_t w = (addr>>2) & 3;
  mem_range_t mr = mem_range_t::low_local;
  if(sgi_prom or (mc != nullptr)) {
    mr = compute_mem_range_type(addr);
  }
  uint16_t wm = (m >> (4*w)) & 15;

  switch(mr)
    {
    case mem_range_t::hpc_regs:
      //printf("hpc load addr %x, offs %u, mask %x\n", addr, w, wm);
      d = device_word_read(addr, wm, [](uint32_t a, size_t sz) { return hpc->read(a & 0x7ffff, sz); });
      break;
    case mem_range_t::mc_regs:
      //printf("mc  load addr %x, offs %u, mask %x\n", addr, w, wm);
      d = device_word_read(addr, wm, [](uint32_t a, size_t sz) { return mc->read(a & 0x1ffff, sz); });
      break;
    case mem_range_t::scc_regs:
      /* IOC2 serial SCC -- byte-granular (control reads = RR0 status) */
      for(int j = 0; j < 4; j++) {
	if( ((m >> k) & 1) ) {
	  uint32_t by = scc->read((addr+j) - SCC_BASE);
	  d |= (by << (j*8));
	}
	k++;
      }
      break;
    default:
      /* everything else (sys_mem_alias, low/high_local, boot_rom, eisa, ...)
       * is plain physical memory */
      for(int j = 0; j < 4; j++) {
	if( ((m >> k) & 1) ) {
	  uint32_t pa = addr + j;
	  uint32_t by = ip28_eisa(pa) ? 0xffu :
			((!globals::ip28 || ip28_mem_pa(pa)) ? s->mem.get<uint8_t>(pa) : 0);
	  d |= (by << (j*8));
	}
	k++;
      }
      break;
    }
  return d;
}


static void perform_word_store(state_t *s, uint32_t addr, uint16_t m, uint32_t d) {
  uint32_t k = addr & 15;
  uint32_t w = (addr >> 2) & 0x3;
  mem_range_t mr = mem_range_t::low_local;
  if(sgi_prom or (mc != nullptr)) {
    mr = compute_mem_range_type(addr);
  }
  uint16_t wm = (m >> (4*w)) & 15;
  //if(wm == 0) {
  //return 0;
  //}
  //printf("wm = %x\n", wm);
  
  switch(mr)
    {
      //case mem_range_t::hpc_regs:
      // std::cout << "hpc : " << std::hex << addr << std::dec  << "\n";      
      // d = hpc->read(addr & 0x7ffff, 4);
      // break;
      case mem_range_t::mc_regs:
	///printf("mc  store addr %x, offs %u, mask %x\n", addr, w, wm);	
	device_word_write(addr, wm, d, [](uint32_t a, uint32_t v, size_t sz) { mc->write(a & 0x1ffff, v, sz); });
	break;
    case mem_range_t::low_local:
      for(int j = 0; j < 4; j++) {
	if(((m >> k) & 1)) {
	  uint32_t by = (d>>(8*j)) & 0xff;	      
	  //printf("write byte %x to address %lx\n", by, ea+j);
	  s->mem.set<uint8_t>(addr+j, by);
	}
	k++;
      }
      break;
    case mem_range_t::hpc_regs:
      device_word_write(addr, wm, d, [](uint32_t a, uint32_t v, size_t sz) { hpc->write(a & 0x7ffff, v, sz); });
      break;
    case mem_range_t::scc_regs:
      /* IOC2 serial SCC -- byte-granular (data writes transmit to stdout) */
      for(int j = 0; j < 4; j++) {
	if(((m >> k) & 1)) {
	  uint8_t by = (d>>(8*j)) & 0xff;
	  scc->write((addr+j) - SCC_BASE, by);
	}
	k++;
      }
      break;
    default:
      /* plain physical memory */
      for(int j = 0; j < 4; j++) {
	if(((m >> k) & 1)) {
	  uint32_t by = (d>>(8*j)) & 0xff;
	  uint32_t pa = addr + j;
	  if(!ip28_eisa(pa) && (!globals::ip28 || ip28_mem_pa(pa))) {
	    s->mem.set<uint8_t>(pa, by);
	  }
	}
	k++;
      }
      break;
    }
}


int main(int argc, char **argv) {
  static_assert(sizeof(itype) == 4, "itype must be 4 bytes");
  //std::fesetround(FE_TOWARDZERO);
  namespace po = boost::program_options; 
  // Initialize Verilators variables
  bool enable_checker = true;
  bool checker_given = false;
  std::string watch_va_str;   /* --checker on the command line (PROM runs default it off) */
  bool os_mode = false;
  bool magic_halt = true;
  /* Physical address of the simulator halt register (kseg1 0xBFD00000). */
  static const uint32_t MAGIC_HALT_PHYS = 0x1FD00000u;
  std::string pipelog;
  std::string mips_binary = "dhrystone3";
  std::string arcs_image;
  std::string memdump_spec;
  std::string log_name = "log.txt";
  std::string pushout_name = "pushout.txt";
  std::string branch_name = "branch_info.txt";
  uint64_t heartbeat = 1UL<<36, start_trace_at = ~0UL;
  uint64_t max_cycle = 0, max_icnt = 0, mem_lat = 2;
  bool single_step = false;
  uint64_t step_hold = 0;
  uint64_t last_store_addr = 0, last_load_addr = 0, last_addr = 0;
  int misses_inflight = 0;
  std::map<uint32_t, uint64_t> pushout_histo;
  std::map<uint64_t, double> tip_map;          /* full per-cycle attribution (TIP, ported from rv64core) */
  std::map<uint64_t, uint64_t> tip_insn_cnts;
  int64_t mem_reply_cycle = -1L;
  /* --snoop-delay N (debug stress, inclusive L2): every line the L2 reads from DRAM
   * is snooped WBINV (probe the L1D, write back, invalidate) N cycles later -- by
   * then it is likely in the L1D, often dirty.  WBINV is architecturally invisible,
   * so the co-sim checker must stay clean.  One snoop outstanding; queue capped. */
  uint64_t snoop_delay = 0;
  uint64_t snoop_every = 1, snoop_seen = 0;   /* snoop 1 of every snoop_every DRAM line reads */
  std::deque<std::pair<uint64_t, uint64_t>> snoop_q;   /* {due cycle, line PA} */
  bool snoop_busy = false, snoop_acked = false;
  uint64_t snoop_issued = 0, snoop_done_n = 0, snoop_dropped = 0;
  try {
    po::options_description desc("Options");
    desc.add_options() 
      ("help", "Print help messages")
      ("checker,c", po::value<bool>(&enable_checker)->default_value(true), "use checker")
      ("snoop-delay", po::value<uint64_t>(&snoop_delay)->default_value(0), "debug: WBINV-snoop every line read from DRAM this many cycles later (0 = off)")
      ("snoop-every", po::value<uint64_t>(&snoop_every)->default_value(1), "debug: with --snoop-delay, snoop only 1 of every N lines read from DRAM (frequency knob)")
      ("os-mode", po::value<bool>(&os_mode)->default_value(false), "the binary runs an OS (Linux checkpoint): SYSCALL/BREAK trap to the kernel in the checker ISS, like the RTL, instead of halting it")
      ("file,f", po::value<std::string>(&mips_binary), "mips binary")
      ("heartbeat,h", po::value<uint64_t>(&heartbeat)->default_value(1<<24), "heartbeat for stats")
      ("log,l", po::value<std::string>(&log_name), "stats log filename")
      ("pushout", po::value<std::string>(&pushout_name), "pushout log filename")
      ("branch", po::value<std::string>(&branch_name), "branch log filename")
      ("memlat,m", po::value<uint64_t>(&mem_lat)->default_value(4), "memory latency")
      ("pipelog,p", po::value<std::string>(&pipelog), "log for pipeline tracing")
      ("pipestart", po::value<uint64_t>(&pipestart)->default_value(0), "when to start logging")
      ("pipeend", po::value<uint64_t>(&pipeend)->default_value(~0UL), "when to stop logging")      
      ("topdown", po::value<bool>(&topdown::enabled)->default_value(false), "top-down slot accounting over the pipestart..pipeend window (build with +define+TOPDOWN)")
      ("maxcycle", po::value<uint64_t>(&max_cycle)->default_value(1UL<<34), "maximum cycles")
      ("maxicnt", po::value<uint64_t>(&max_icnt)->default_value(1UL<<50), "maximum icnt")
      ("singlestep", po::value<bool>(&single_step)->default_value(false), "single-step the core (one retire per step pulse)")
      ("step_hold", po::value<uint64_t>(&step_hold)->default_value(0), "FPGA-like step: hold step high N cycles between edges (0=clean toggle)")
      ("tracefp", po::value<bool>(&globals::trace_fp)->default_value(false), "trace fp instructions")
      ("trace,t", po::value<bool>(&globals::trace_retirement)->default_value(false), "trace retired instruction stream")
      ("starttrace,s", po::value<uint64_t>(&start_trace_at)->default_value(~0UL), "start tracing retired instructions")
      ("ip22", po::value<bool>(&sgi_ip22)->default_value(false), "boot the SGI IP22 (Indy) PROM, ip24prom.070-9101-005.bin")
      ("ip28", po::value<bool>(&sgi_ip28)->default_value(false), "boot the SGI IP28 (Indigo2 R10000) PROM, ip28prom.070-1477-002.bin")
      ("watch-va", po::value<std::string>(&watch_va_str), "co-sim: log every store / DMA / fill / writeback of this VA's line (hex)")
      ("disk", po::value<std::string>(&disk_image), "SCSI disk image (raw or qcow2) for the SGI board, target 1; writes stay in memory")
      ("arcs", po::value<std::string>(&arcs_image),
       "synthetic ARCS firmware image; loaded at physical 0x1000 (kseg1 0xA0001000)")
      ("memdump", po::value<std::string>(&memdump_spec),
       "dump physical memory at exit; format hexPA:hexLEN:file")
      ("magic-halt", po::value<bool>(&magic_halt)->default_value(true),
       "stop simulation when magic halt address (kseg1 0xBFD00000) is written")
      ;
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm); 
    checker_given = !vm["checker"].defaulted();
    if(!watch_va_str.empty()) {
      g_watch_va = strtoull(watch_va_str.c_str(), nullptr, 16);
    }
    sgi_prom = sgi_ip22 or sgi_ip28;
    /* ooo_core carries no libchdr (sgi_shim.cc): a MAME CHD would be read as a raw disk */
    if(not(disk_image.empty())) {
      char magic[8] = {0};
      FILE *df = fopen(disk_image.c_str(), "rb");
      if(df == nullptr) {
        std::cerr << "cannot open disk image " << disk_image << "\n";
        return -1;
      }
      const size_t got = fread(magic, 1, sizeof(magic), df);
      fclose(df);
      if((got == sizeof(magic)) && (memcmp(magic, "MComprHD", 8) == 0)) {
        std::cerr << disk_image << " is a MAME CHD, which ooo_core cannot read: convert it to raw or qcow2\n";
        return -1;
      }
    }
    globals::ip28 = sgi_ip28;
  }
  catch(po::error &e) {
    std::cerr <<"command-line error : " << e.what() << "\n";
    return -1;
  }
  uint32_t max_insns_per_cycle = 4;
  uint32_t max_insns_per_cycle_hist_sz = 2*max_insns_per_cycle;

  std::map<uint32_t, uint64_t> mispredicts;

  uint64_t hist = 0, spec_hist = 0;
  static const int TBL_SIZE = (1<<24);
  static const int BTB_SIZE = (1<<6);
  
  
  uint64_t inflight[32] = {0};
  uint64_t *insns_delivered = new uint64_t[max_insns_per_cycle_hist_sz];
  memset(insns_delivered, 0, sizeof(uint64_t)*max_insns_per_cycle_hist_sz);
  
  uint32_t max_inflight = 0;


  const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
  contextp->commandArgs(argc, argv);  
  //contextp->traceEverOn(true);
  
  sparse_mem *sm0 = new sparse_mem();
  sparse_mem *sm1 = new sparse_mem();
  s = new state_t(*sm0);
  ss = new state_t(*sm1);
  initState(s);
  initState(ss);
  ss->silent = true;  /* checker: suppress putchar side-effects */
  initCapstone();

  if(not(sgi_prom)) {
    if(mips_binary.empty()) {
      std::cout << "no elf binary\n";
      exit(-1);
    }
    load_elf(mips_binary.c_str(), s);
    load_elf(mips_binary.c_str(), ss);

    /* Optional synthetic ARCS firmware: the kernel's PROMLIB reads the ARCS
     * System Parameter Block at kseg1 0xA0001000 (physical 0x1000).  Load the
     * blob there so prom_init passes the magic check and the romvec callbacks
     * (Write->putchar, GetMemoryDescriptor, ...) are available. */
    if(not(arcs_image.empty())) {
      struct stat ast;
      int afd = open(arcs_image.c_str(), O_RDONLY);
      if(afd < 0) {
        std::cerr << "could not open arcs image " << arcs_image << "\n";
        exit(-1);
      }
      if(fstat(afd, &ast) < 0) {
        std::cerr << "fstat failed on arcs image " << arcs_image << "\n";
        exit(-1);
      }
      char *abuf = (char*)mmap(nullptr, ast.st_size, PROT_READ, MAP_PRIVATE, afd, 0);
      /* ARCS SPB lives at kseg1 0xA0001000 -> physical 0x1000 */
      memcpy(s->mem.mem  + 0x1000, abuf, ast.st_size);
      memcpy(ss->mem.mem + 0x1000, abuf, ast.st_size);
      munmap(abuf, ast.st_size);
      close(afd);
      std::cout << "loaded ARCS firmware (" << ast.st_size
                << " bytes) at physical 0x1000\n";

      /* Model the SGI MC/HPC devices for the kernel boot (decoupled from the
       * --ip22/--ip28 ROM path): the IP22 kernel probes the MC for the memory map. */
      attach_sgi_devices(s);
    }
  }
  else {
    /* the ISS has no devices: off unless asked for, and then it follows the RTL on device
     * loads (adopt_unmodeled_load), interrupts (raise_int) and DMA (sgi_dma_wrote) */
    enable_checker = checker_given && enable_checker;
    if(enable_checker) {
      g_dma_mirror = true;
      if(sgi_ip28) {
	tags_alloc();
      }
      if(sgi_ip28) {
	ss->mem.route_devices = true;        /* the low 512 KB alias, as ip28_mem_pa */
	ss->mem.alias_base = 0x20000000UL;
      }
    }
    struct stat st;
    int rc;
    const char *prom = sgi_ip28 ? "ip28prom.070-1477-002.bin" : "ip24prom.070-9101-005.bin";
    int fd = open(prom, O_RDONLY);
    if(fd<0) {
      printf("INTERP: open() returned %d\n", fd);
      exit(-1);
    }
    rc = fstat(fd,&st);
    if(rc<0) {
      printf("INTERP: fstat() returned %d\n", rc);
      exit(-1);
    }
    char *buf = (char*)mmap(nullptr, st.st_size,
                            PROT_READ, MAP_PRIVATE, fd, 0);

    memcpy(s->mem.mem +(0xbfc00000 & 0x1fffffff), buf, st.st_size);
    memcpy(ss->mem.mem +(0xbfc00000 & 0x1fffffff), buf, st.st_size);    

    s->pc = 0xbfc00000;
    ss->pc = (int64_t)(int32_t)0xbfc00000;   /* the checker ISS starts at the reset vector too */
    close(fd);
    attach_sgi_devices(s);
  }
  
  
  // Create an instance of our module under test
   //Vcore_l1d_l1i *tb = new Vcore_l1d_l1i;
  std::unique_ptr<Vcore_l1d_l1i> tb(new Vcore_l1d_l1i);
  state_t::reg_t last_match_pc = 0;
  uint64_t last_retire = 0, last_check = 0, last_restart = 0;
  uint64_t last_retired_pc = 0, last_retired_fp_pc = 0;
  uint64_t mismatches = 0, n_stores = 0, n_loads = 0;
  uint64_t n_branches = 0, n_mispredicts = 0, n_checks = 0, n_flush_cycles = 0;
  bool got_mem_req = false, got_mem_rsp = false, incorrect = false, got_putchar = false;
  bool sim_halted = false;
  //assert reset
  tb->retire_allowed = 1;
  tb->mem_rsp_bad = 0;
  for(globals::cycle = 0; (globals::cycle < 4) && !Verilated::gotFinish(); ++globals::cycle) {
    contextp->timeInc(1);  // 1 timeprecision period passes...
    tb->mem_rsp_valid = 0;
    tb->reset = 1;
    tb->ip6 = tb->ip5 = tb->ip4 = tb->ip3 = tb->ip2 = 0;
    tb->clk = 1;
    tb->eval();
    tb->clk = 0;
    tb->eval();
    ++globals::cycle;
  }
  
  tb->resume_pc = (uint64_t)(int64_t)(int32_t)(uint32_t)s->pc;
  contextp->timeInc(1);  // 1 timeprecision period passes...
  tb->reset = 0;
  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();


  while(!tb->ready_for_resume) {
    ++globals::cycle;
    tb->clk = 1;
    tb->eval();
    tb->clk = 0;
    tb->eval();
  }

  ++globals::cycle;
  tb->resume = 1;

  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();
  
  ++globals::cycle;  
  tb->resume = 0;
  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();


  if(not(pipelog.empty())) {
    pl = new pipeline_logger(pipelog);
  }
  
    
  ++globals::cycle;
  tb->resume = 1;
  tb->resume_pc = (uint64_t)(int64_t)(int32_t)(uint32_t)s->pc;
  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();
  ++globals::cycle;  
  tb->resume = 0;
  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();
  //done with initialize
  globals::cycle = 0;  

  
  tb->single_step = single_step;
  tb->step = 0;
  double t0 = timestamp();
  g_iss_tlb_ext = enable_checker;   /* checker ISS TLB = the RTL's (tlb_wr_log mirror) */
  g_iss_os_mode = os_mode || sgi_prom;   /* checker ISS: SYSCALL/BREAK trap to the kernel (IRIX too) */
#ifdef STORE_CHECK
  g_store_check = enable_checker;
#endif
  while(!Verilated::gotFinish() && (globals::cycle < max_cycle) && (insns_retired < max_icnt)) {
    /* the device models (MC RPSS, ...) clock off s->icnt, but a PROM boot runs with no
     * checker to step s: their clock is the RTL's retire count instead */
    if(sgi_prom) {
      /* the 8254 model (sgi_hpc pit_irq, t2_value) clocks off the ISS's CP0 Count, which
       * indysim ticks once per instruction: without this it stays 0, the timers never
       * fire again once armed, and IRIX sleeps forever (the miniroot after its mounts) */
      s->icnt = insns_retired;
      s->cpr0[CPR0_COUNT] = (uint32_t)insns_retired;
      /* indysim steps the devices per instruction: the SCC's TX timing every one, the
       * interrupt sources every 64 (or when one pokes); here the retire count is the
       * instruction clock, and the interrupt sources drive the core's IP lines */
      static uint64_t scc_icnt = 0, next_poll = 0;
      while(scc_icnt < insns_retired) {
        scc->tick1();
        ++scc_icnt;
      }
      if(s->irq_poke || (insns_retired >= next_poll)) {
        s->irq_poke = false;
        next_poll = insns_retired + 64;
        hpc->enet_poll();
        tb->ip2 = hpc->ioc2_ip2_pending();
        if(globals::ip28) {
          tb->ip4 = hpc->pit_irq(0);   /* 8254 counter 0, rtclock */
          tb->ip5 = hpc->pit_irq(1);   /* 8254 counter 1, kgclock */
        }
      }
    }
    /* EARLY-RETIRE PROBE: how many instructions have actually retired by cycle N?
     * Needed to interpret BMC depth: a formal run that is "clean to frame 30" is
     * only meaningful if the machine has executed something by cycle 30. */
    { static const bool early = getenv("R9999_EARLY_RETIRE") != nullptr;
      if(early && globals::cycle <= 120) {
        static uint64_t last = ~0ull;
        if(insns_retired != last) {
          fprintf(stderr, "[early] cyc=%lu retired=%lu\n",
                  (unsigned long)globals::cycle, (unsigned long)insns_retired);
          last = insns_retired;
        }
      }
    }
    /* --snoop-delay injector: drive the L2 snoop port (see snoop_q) */
    if(snoop_delay) {
      if(snoop_busy) {
        if(!snoop_acked && tb->snoop_req_ack) {
          snoop_acked = true;
          tb->snoop_req_valid = 0;
        }
        if(snoop_acked && tb->snoop_done) {
          snoop_busy = false;
          ++snoop_done_n;
        }
      }
      else if(!snoop_q.empty() && snoop_q.front().first <= globals::cycle) {
        tb->snoop_req_valid = 1;
        tb->snoop_req_wbinv = 1;
        tb->snoop_req_addr = snoop_q.front().second;
        snoop_q.pop_front();
        snoop_busy = true;
        snoop_acked = false;
        ++snoop_issued;
      }
    }
    contextp->timeInc(1);  // 1 timeprecision periodd passes...

    tb->clk = 1;

    if(step_hold > 0) {
      /* FPGA-like: low for 4 cyc, rising edge, then hold step high step_hold cyc
       * (mimics step held high through the AXI dump_registers window). */
      uint64_t period = step_hold + 400;
      tb->step = ((globals::cycle % period) >= 4) ? 1 : 0;
    }
    else if((globals::cycle & 3) == 0) {
      tb->step = (~tb->step) & 1;
    }
    /* manual external-IRQ exercise: R9999_ASSERT_IP=<2..6> drives ipN high
     * (level-held) from cycle R9999_ASSERT_CYCLE onward, so we can inject an
     * IP2..IP6 interrupt into the core from the TB. The handler must mask IM[N]
     * (a held line would otherwise re-fire after ERET). Run with -c0: the cosim
     * checker would diverge since the interpreter doesn't model the injected IRQ. */
    { static int      aip  = getenv("R9999_ASSERT_IP")    ? atoi(getenv("R9999_ASSERT_IP")) : 0;
      static uint64_t acyc = getenv("R9999_ASSERT_CYCLE") ? strtoull(getenv("R9999_ASSERT_CYCLE"),0,0) : 0;
      if(aip && globals::cycle >= acyc) {
        switch(aip) {
          case 2: tb->ip2 = 1; break;  case 3: tb->ip3 = 1; break;
          case 4: tb->ip4 = 1; break;  case 5: tb->ip5 = 1; break;
          case 6: tb->ip6 = 1; break;
        }
      }
    }
    tb->eval();

    { static uint32_t psr = 0xffffffffu;
      if(tb->status_reg != psr) {
        bool exl_rise = ((tb->status_reg>>1)&1) && !((psr>>1)&1);
        printf("[sr] cyc %lu sr=%08x KX=%d KSU=%d EXL=%d ERL=%d\n",
               (unsigned long)globals::cycle, tb->status_reg, (tb->status_reg>>7)&1,
               (tb->status_reg>>3)&3, (tb->status_reg>>1)&1, (tb->status_reg>>2)&1);
        if(exl_rise) {
          uint32_t e = (uint32_t)tb->epc;
          uint32_t fi = get_insn(e & 0x1fffffffu, s);
          printf("[exc] cyc %lu EPC=%08x insn=%08x : %s\n",
                 (unsigned long)globals::cycle, e, fi,
                 getAsmString(fi, e).c_str());
          fflush(stdout);
        }
        psr = tb->status_reg;
      } }

    if(not(tb->putchar_fifo_empty)) {
      //printf("got first putchar at icnt %lu\n", insns_retired);
      //exit(-1);
      char putch = (char)tb->putchar_fifo_out;
      std::cout << putch;
      /* Flush after each newline so output is visible even if the
       * process is killed by a timeout (stdout may be fully-buffered
       * when connected to a pipe). */
      if(putch == '\n') std::cout.flush();
      got_putchar = true;
      tb->putchar_fifo_pop = 1;
    }
    
    
    if(tb->retire_reg_valid) {
      s->gpr[tb->retire_reg_ptr] = tb->retire_reg_data;
      //std::cout << "register " << getGPRName(tb->retire_reg_ptr)
      //	<< std::hex
      //<< " : " 	
      //<< tb->retire_reg_data
      //<< std::dec << "\n";
    }
    
    if(tb->branch_pc_valid) {
      ++n_branches;
    }
    if(tb->branch_fault) {
      mispredicts[tb->branch_pc]++; 
    }
    if(tb->branch_fault) {
      ++n_mispredicts;
    }
    if(tb->in_flush_mode) {
      ++n_flush_cycles;
    }

    /* Keep the sim's CP0 Count register in sync with the RTL every cycle.
     * Without this, mfc0 rd,$9 reads in the sim return 0 while the RTL
     * returns the real cycle count, causing a checker register mismatch. */
    if(enable_checker) {
      ss->cpr0[CPR0_COUNT] = (uint32_t)tb->cp0_count;
      /* Random too: timing-dependent, and the ISS TLB comes from the RTL mirror, so
       * the ISS's own Random only matters for the kernel's mfc0 Random reads */
      ss->cpr0[CPR0_RANDOM] = (uint32_t)tb->cp0_random;
      /* Likewise Cause.IP[7:0]: the pending bits are timing-dependent (IP7 is set
       * when Count reaches Compare -- at reset both are 0), and the ISS does not
       * model them, so any handler's raw `mfc0 Cause` mismatched (0x8030 vs 0x30)
       * whenever IP7 happened to be pending.  The RTL reads exactly cause_ip
       * (exec.sv w_ip) in Cause[15:8]. */
      const uint32_t cause_ip = ((uint32_t)tb->cause_ip & 0xffu) << 8;
      ss->cpr0[CPR0_CAUSE]    = (ss->cpr0[CPR0_CAUSE] & ~0xff00u) | cause_ip;
      ss->cpr0_64[CPR0_CAUSE] = (ss->cpr0_64[CPR0_CAUSE] & ~0xff00ull) | cause_ip;
    }


    /* When the RTL takes a timer interrupt, synchronise the sim by jumping
     * it to the exception vector with the correct EPC/Cause/SR.  This fires
     * in WRITE_EPC (retire_valid is 0 at that point) so the checker sees
     * RTL and sim both at bfc00180 when the handler starts retiring. */
    if(tb->took_irq && enable_checker) {
      raise_int(ss, (uint64_t)tb->epc);
    }
    /* A synchronous exception: the faulting instruction never retires, so the ISS would
     * never step it.  On entry to WRITE_EPC (core.sv state 10) without took_irq, if the ISS
     * sits at the RTL's EPC, step it there: with the RTL's TLB mirrored, it takes the same
     * exception (e.g. a TLB miss inside the XTLB refill handler, which nests to the general
     * vector and the kernel's handler, where the PC-range resync below cannot follow). */
    { static uint32_t prev_core_state = 0;
      if(enable_checker && (tb->core_state == 10) && (prev_core_state != 10) && !tb->took_irq) {
	if((uint32_t)ss->pc == (uint32_t)tb->epc) {
	  iss_step(ss);
	  /* the stepped ISS must land in an exception vector, or it did not fault */
	  if(((uint32_t)ss->pc & 0xfffff000u) != 0x80000000u &&
	     ((uint32_t)ss->pc & 0xfffff000u) != 0xbfc00000u) {
	    fprintf(stderr, "[sync-exc-nofault] cyc %llu rtl epc=%016llx: ISS stepped it without faulting, now pc=%016llx\n",
		    (unsigned long long)globals::cycle, (unsigned long long)tb->epc,
		    (unsigned long long)ss->pc);
	  }
	}
	else {
	  fprintf(stderr, "[sync-exc-skip] cyc %llu rtl epc=%016llx but ISS pc=%016llx: not stepped\n",
		  (unsigned long long)globals::cycle, (unsigned long long)tb->epc,
		  (unsigned long long)ss->pc);
	}
      }
      prev_core_state = tb->core_state; }

    /* TIP: full per-cycle attribution (rv64core top.cc parity). ROB-empty ->
     * blame last-retired (stall is upstream/fetch); nothing retires -> blame the
     * true ROB head (dbg_head_pc); something retires -> split 1.0/total across the
     * retiring ops. sum(tip) == total cycles. */
    if(tb->dbg_head_status & 0x1) {
      tip_map[last_retired_pc] += 1.0;
    }
    else if(!(tb->retire_valid || tb->retire_two_valid)) {
      tip_map[tb->dbg_head_pc] += 1.0;
    }
    else {
      double total = static_cast<double>(tb->retire_valid) + static_cast<double>(tb->retire_two_valid);
      tip_map[tb->retire_pc] += 1.0 / total;
      tip_insn_cnts[tb->retire_pc]++;
      if(tb->retire_two_valid) {
	tip_map[tb->retire_two_pc] += 1.0 / total;
	tip_insn_cnts[tb->retire_two_pc]++;
      }
    }

    if(tb->retire_valid) {
      ++insns_retired;
      if(last_retire > 1) {
	pushout_histo[tb->retire_pc] += last_retire;
      }
      last_retire = 0;

      last_retired_pc = tb->retire_pc;

      if(insns_retired >= start_trace_at)
	globals::trace_retirement = true;


      
      if(((insns_retired % heartbeat) == 0) or globals::trace_retirement ) {
	//uint32_t r_inst = s->mem.get<uint32_t>(tb->retire_pc);
	//r_inst = bswap<IS_LITTLE_ENDIAN>(r_inst);	
	std::cout << "retiring "
		  << std::hex
		  << tb->retire_pc
		  << std::dec
		  << " cycle " << globals::cycle
		  << " "  <<  getAsmString(get_insn(tb->retire_pc&0x1fffffff, s), tb->retire_pc&0x1fffffff)	  
		  << std::fixed
		  << ", " << static_cast<double>(insns_retired) / globals::cycle << " IPC "
		  << ", insns_retired "
		  << insns_retired
		  << ", mispredict pki "
		  << (static_cast<double>(n_mispredicts) / insns_retired) * 1000.0
		  << std::defaultfloat	  
		  <<" \n";
      }
      if(tb->retire_two_valid) {
	++insns_retired;
	if(((insns_retired % heartbeat) == 0) or globals::trace_retirement ) {
	  std::cout << "retiring "
		    << std::hex
		    << tb->retire_two_pc
		    << std::dec
		    << " cycle " << globals::cycle
		    << " "  <<  getAsmString(get_insn(tb->retire_two_pc&0x1fffffff, s), tb->retire_two_pc&0x1fffffff)	  	    
		    << std::fixed
		    << ", " << static_cast<double>(insns_retired) / globals::cycle << " IPC "	    
		    << ", insns_retired "
		    << insns_retired
		    << ", mispredict pki "
		    << (static_cast<double>(n_mispredicts) / insns_retired) * 1000.0
		    << std::defaultfloat
		    <<" \n";
	}
      }
      if(tb->got_bad_addr) {
	std::cout << "fatal - unaligned address\n";
	break;
      }

      if(!enable_checker) {
	uint32_t ri = get_insn(tb->retire_pc & 0x1fffffffu, s);
	if((ri >> 26) == 0 && ((ri & 63) == 0xC || (ri & 63) == 0xD)) {
	  break; /* BREAK or SYSCALL retired; stop without checker */
	}
      }

      if( enable_checker) {
	adopt_ds_load(tb->retire_pc);
	if((uint32_t)tb->retire_pc == (uint32_t)ss->pc) {
	  //std::cout << std::hex << tb->retire_pc << "," << ss->pc << std::dec << "\n";
	  const stale_fetch_t sf = stale_fetch_begin(ss, tb->retire_pc, tb->retire_insn);
	  const uint32_t r_insn = iss_fetch_inst(ss, tb->retire_pc, nullptr);
	  const uint32_t ld_dst = unmodeled_load_dst(ss, tb->retire_pc);
	  follow_rtl_sc(s, ss, tb->retire_pc);
	  iss_step(ss);
	  stale_fetch_end(ss, sf);
	  adopt_timing_cp0(r_insn, s, ss);
	  adopt_fcsr_read(r_insn, tb->retire_pc, s, ss);
	  if(ld_dst != 0) {
	    ss->gpr[ld_dst] = s->gpr[ld_dst];
	  }
	  drain_store_check();
	  if(g_store_diverged) {
	    incorrect = true;
	    break;
	  }
	  /* If checker just executed BREAK or SYSCALL, stop gracefully */
	  if(ss->brk) {
	    break;
	  }
	  // if(static_cast<uint32_t>(ss->mem.at(0x4cadc)) == 3) {
	  //   std::cout << "changed memory at " << std::hex << ss->pc << std::dec << "\n";
	  //   exit(-1);
	  // }

	  bool diverged = false;
	  if((uint32_t)ss->pc == (uint32_t)(tb->retire_pc + 4)) {
	    for(int i = 0; i < 32; i++) {
	      if((ss->gpr[i] != s->gpr[i])) {
		int wrong_bits = __builtin_popcount(ss->gpr[i] ^ s->gpr[i]);
		++mismatches;
		std::cout << "register " << getGPRName(i)
			  << " does not match : rtl "
			  << std::hex
			  << s->gpr[i]
			  << " simulator "
			  << ss->gpr[i]
			  << std::dec
			  << " bits in difference "
			  << wrong_bits
			  << "\n";
		//globals::trace_retirement |= (wrong_bits != 0);
		diverged = true;//(wrong_bits > 16);
		/* Mask PC to 32 bits before accessing memory */
		uint32_t r_inst = s->mem.get<uint32_t>((uint32_t)ss->pc & 0x1fffffffu);
		r_inst = bswap<IS_LITTLE_ENDIAN>(r_inst);
		std::cout << "incorrect "
			  << std::hex
			  << (uint32_t)ss->pc
			  << std::dec
			  << " : " << getAsmString(r_inst, (uint32_t)ss->pc)
			  << "\n";

	      }
	    }


	  }

	  if(diverged) {
	    incorrect = true;
	    fprintf(stderr, "[diverge] rtl retire_pc=%016llx  ISS pc=%016llx\n",
		    (unsigned long long)tb->retire_pc, (unsigned long long)ss->pc);
	    tags_report_last_load();
	    /* Mask retire_pc to 32 bits before accessing memory */
	    uint32_t r_inst = s->mem.get<uint32_t>((uint32_t)tb->retire_pc & 0x1fffffffu);
	    r_inst = bswap<IS_LITTLE_ENDIAN>(r_inst);
	    std::cout << "incorrect "
		      << std::hex
		      << (uint32_t)tb->retire_pc
		      << std::dec
		      << " : " << getAsmString(r_inst, (uint32_t)tb->retire_pc)
		      << "\n";
	    for(int i = 0; i < 32; i+=4) {
	      std::cout << "reg "
			<< getGPRName(i)
			<< " = "
			<< std::hex
			<< s->gpr[i]
			<< " reg "
			<< getGPRName(i+1)
			<< " = "
			<< s->gpr[i+1]
			<< " reg "
			<< getGPRName(i+2)
			<< " = "
			<< s->gpr[i+2]
			<< " reg "
			<< getGPRName(i+3)
			<< " = "
			<< s->gpr[i+3]
			<< std::dec <<"\n";
	    }
	    break;
	  }


	  
	  ++n_checks;
	  last_check = 0;
	  last_match_pc =  tb->retire_pc; 
	}
	else {
	  /* When the RTL takes an exception (retiring instructions from the
	   * exception handler at bfc00180-bfc003ff) while the sim is still
	   * at the faulting instruction in non-ROM code, advance the sim to
	   * execute the fault and re-sync.  All other mismatches (e.g. a
	   * normal branch delay slot) are handled by the original last_check
	   * counter. */
	  uint32_t rtl_pc32 = (uint32_t)tb->retire_pc;
	  uint32_t sim_pc32 = (uint32_t)ss->pc;
	  /* BEV=1 puts the vectors in the boot ROM (bfc00180+), but a Linux
	   * checkpoint runs with BEV=0, where they live in kseg0: TLB refill
	   * 0x80000000, XTLB refill 0x80000080, general 0x80000180.  Without the
	   * BEV=0 range the sim is never advanced past the faulting instruction,
	   * so it sits on the store while the RTL runs the handler and the desync
	   * watchdog kills the run a few retires later. */
	  bool rtl_in_exc_handler = (rtl_pc32 >= 0xbfc00180u &&
				     rtl_pc32 <  0xbfc00400u) ||
				    (rtl_pc32 >= 0x80000000u &&
				     rtl_pc32 <  0x80000200u);
	  /* "sim in user code" = the sim has NOT yet taken the exception, i.e. it
	   * is in neither vector area */
	  bool sim_in_user_code   = !((sim_pc32 >= 0xbfc00000u &&
				       sim_pc32 <  0xbfc00400u) ||
				      (sim_pc32 >= 0x80000000u &&
				       sim_pc32 <  0x80000200u));
	  bool caught_up = false;

	  if(rtl_in_exc_handler && sim_in_user_code) {
	    /* Advance the sim past the faulting instruction (which raises the
	     * exception and sets sim->pc to bfc00180).  If it now matches the
	     * retiring handler PC, advance one more step to restore the
	     * normal invariant: ss->pc == next_retire_pc. */
	    iss_step(ss);
	    if(ss->brk) {
	      break;
	    }
	    if((uint32_t)tb->retire_pc == (uint32_t)ss->pc) {
	      iss_step(ss);
	      if(ss->brk) {
		break;
	      }
	      ++n_checks;
	      last_check = 0;
	      last_match_pc = tb->retire_pc;
	      caught_up = true;
	    }
	  }

	  if(!caught_up) {
	    ++last_check;
	    /* Peek at the pending checker instruction.  If it is BREAK or
	     * SYSCALL the RTL has entered exception/halt mode and the
	     * simulation is effectively over -- terminate cleanly. */
	    {
	      uint32_t pending = bswap<IS_LITTLE_ENDIAN>(
		ss->mem.get<uint32_t>(va2pa((uint32_t)ss->pc)));
	      uint32_t pend_op   = pending >> 26;
	      uint32_t pend_func = pending & 63;
	      if(pend_op == 0 && (pend_func == 0x0C || pend_func == 0x0D)) {
		/* BREAK or SYSCALL is the next checker instruction */
		break;
	      }
	    }
	    if(last_check > 2) {
	      /* The RTL and the checker have taken DIFFERENT control flow.  This is
	       * a real failure -- notably it is the shape of a mis-resolved branch,
	       * the bug this core is being hunted for -- but it used to break out
	       * without setting `incorrect', so the run wrote its normal stats log
	       * and a stdout-only reader saw nothing wrong.  (run_parallel.sh greps
	       * stderr for "no match", but a direct ooo_core invocation does not.)
	       * Mark it failed and put a greppable marker on stdout. */
	      incorrect = true;
	      std::cout << "COSIM DESYNC: rtl pc " << std::hex << tb->retire_pc
			<< " != sim pc " << ss->pc << std::dec
			<< " -- control flow diverged\n";
	      uint32_t linsn = bswap<IS_LITTLE_ENDIAN>(s->mem.get<uint32_t>((uint32_t)last_match_pc & 0x1fffffffu));
	      std::cerr << "no match in a while, last match : "
		        << std::hex
		        << last_match_pc
		        << " "
		        << getAsmString(linsn, last_match_pc)
		        << ", rtl pc =" << std::hex << tb->retire_pc
		        << ", sim pc =" << std::hex << ss->pc
		        << std::dec
		        <<"\n";
	      for(int i = 0; i < 32; i+=4) {
		std::cout << "reg "
			  << getGPRName(i)
			  << " = "
			  << std::hex
			  << s->gpr[i]
			  << " reg "
			  << getGPRName(i+1)
			  << " = "
			  << s->gpr[i+1]
			  << " reg "
			  << getGPRName(i+2)
			  << " = "
			  << s->gpr[i+2]
			  << " reg "
			  << getGPRName(i+3)
			  << " = "
			  << s->gpr[i+3]
			  << std::dec <<"\n";
	      }
	      break;
	    }
	  }
	}
      }
      //do       
    }
    
    if(tb->retire_reg_two_valid) {
      s->gpr[tb->retire_reg_two_ptr] = tb->retire_reg_two_data;
      //std::cout << "register " << getGPRName(tb->retire_reg_two_ptr)
      //<< std::hex
      //<< " : " 
      //	<< tb->retire_reg_two_data
      //<< std::dec << "\n";
      
      //if(tb->retire_reg_two_ptr == R_a0) {
      //std::cout << std::hex << "insn two with pc " << tb->retire_two_pc << " updates a0 \n"
      //<< std::dec;
      //}
    }
    

    if(enable_checker && tb->retire_two_valid) {
      adopt_ds_load(tb->retire_two_pc);
      if((uint32_t)tb->retire_two_pc == (uint32_t)ss->pc) {
	const stale_fetch_t sf = stale_fetch_begin(ss, tb->retire_two_pc, tb->retire_two_insn);
	const uint32_t r_insn = iss_fetch_inst(ss, tb->retire_two_pc, nullptr);
	const uint32_t ld_dst = unmodeled_load_dst(ss, tb->retire_two_pc);
	follow_rtl_sc(s, ss, tb->retire_two_pc);
	iss_step(ss);
	stale_fetch_end(ss, sf);
	adopt_timing_cp0(r_insn, s, ss);
	adopt_fcsr_read(r_insn, tb->retire_two_pc, s, ss);
	if(ld_dst != 0) {
	  ss->gpr[ld_dst] = s->gpr[ld_dst];
	}
	drain_store_check();
	if(g_store_diverged) {
	  incorrect = true;
	  break;
	}
	if(ss->brk) {
	  break;
	}
	++n_checks;
	last_check = 0;
	last_match_pc =  tb->retire_two_pc;
      }
    }

    
    ++last_retire;
    if(last_retire > (1U<<16) && not(tb->in_flush_mode)) {
      std::cout << "in flush mode = " << static_cast<int>(tb->in_flush_mode) << "\n";
      std::cerr << "no retire in " << last_retire << " cycles, last retired "
    		<< std::hex
    		<< last_retired_pc + 0
    		<< std::dec
    		<< " "
    		<< getAsmString(get_insn(last_retired_pc+0, s), last_retired_pc+0)
		<< "\ncore state "
		<< static_cast<int>(tb->core_state)
    		<< "\n";
      break;
    }
    if(sim_halted) {
      break;
    }
    if(tb->got_break) {
      std::cout << "got break, epc = " << std::hex << tb->epc << std::dec << "\n";
      break;
    }
    else if(tb->got_ud) {
      std::cerr << "GOT UD for "
		<< std::hex
		<< tb->epc
		<< std::dec
		<< " "
		<< getAsmString(get_insn(tb->retire_pc&0x1fffffff, s), tb->retire_pc&0x1fffffff)
		<< "\n";
      break;
    }
    else if(tb->got_bad_addr) {
      std::cerr << "GOT BAD VA for "
		<< std::hex
		<< tb->epc
		<< std::dec
		<< " "
		<< getAsmString(get_insn(tb->epc, s), tb->epc)
		<< "\n";
      break;
    }
    if(!enable_checker) {
      g_pend_tlb.clear();   /* no checker: nothing consumes the mirror */
    }
    inflight[tb->inflight & 31]++;
    max_inflight = std::max(max_inflight, static_cast<uint32_t>(tb->inflight));

    //negedge
    tb->mem_rsp_valid = 0;

    if(tb->mem_req_valid && (mem_reply_cycle == -1)) {
      /* RANDOM per-request latency (xorshift, machine-deterministic) when MEM_SEED
       * is set -- perturbs D-side load timing to hunt the mapped load-corruption
       * race (single outstanding req here, so no ordering issue). Else fixed. */
      uint64_t lat = mem_lat;
      { static uint64_t mls = 0; static bool mli = false; static uint64_t lmin=1, lmax=16;
        if(!mli){ mli=true; const char*es=getenv("MEM_SEED");
                  if(getenv("MEM_LAT_MIN")) lmin=strtoull(getenv("MEM_LAT_MIN"),0,0);
                  if(getenv("MEM_LAT_MAX")) lmax=strtoull(getenv("MEM_LAT_MAX"),0,0);
                  mls = es ? strtoull(es,0,0) : 0;
                  if(es) fprintf(stderr,"[memlat] RANDOM xorshift [%lu,%lu] seed=%lu\n",lmin,lmax,mls); }
        if(mls){ mls^=mls<<13; mls^=mls>>7; mls^=mls<<17; lat = lmin + (mls % (lmax-lmin+1)); } }
      mem_reply_cycle = globals::cycle + (tb->mem_req_opcode == 4 ? 1 : 2)*lat;
      if(snoop_delay && (tb->mem_req_opcode == 4) && ((snoop_seen++ % snoop_every) == 0)) {
        if(snoop_q.size() < 256) {
          snoop_q.push_back({globals::cycle + snoop_delay, (uint64_t)tb->mem_req_addr & ~15ull});
        }
        else {
          ++snoop_dropped;
        }
      }
    }
    
    if(/*tb->mem_req_valid*/mem_reply_cycle ==globals::cycle) {
      uint16_t m = tb->mem_req_mask;      
      //std::cout << "got " << (tb->mem_req_opcode==4 ? "load" : "store") << " request for address "
      //		<< std::hex << tb->mem_req_addr
      //<< " mask " << m
      //<< std::dec
      //	<<"\n";
      last_retire = 0;
      mem_reply_cycle = -1;
      assert(tb->mem_req_valid);

      if(tb->mem_req_opcode == 4) {/*load word */

	for(int i = 0; i < 4; i++) {
	  uint32_t ea = (tb->mem_req_addr + 4*i) & (~0U);
	  uint32_t d = perform_word_load(s, ea, m);
	  tb->mem_rsp_load_data[i] = d;
	  watch_note("mem-fill", 0, ea, __builtin_bswap32(d));
	}
	last_load_addr = tb->mem_req_addr;
	assert((tb->mem_req_addr & 0xf) == 0);
	++n_loads;
      }
      else if(tb->mem_req_opcode == 7) { /* store word */

	for(int i = 0; i < 4; i++) {
	  uint32_t d = tb->mem_req_store_data[i];
	  uint32_t ea = (tb->mem_req_addr + 4*i) & (~0U);
	  perform_word_store(s, ea, m, d);
	  watch_note("mem-wb", 0, ea, __builtin_bswap32(d));
	  if(((m >> (4 * i)) & 15) != 0) {
	    tag_set(g_tag_rtl_mem, ea, WT_MEM_PORT, 0);
	  }
	  if(magic_halt && (ea & 0x1fffffffu) == MAGIC_HALT_PHYS && d != 0u) {
	    sim_halted = true;
	  }
	}
	last_store_addr = tb->mem_req_addr;
	++n_stores;
      }
      last_addr = tb->mem_req_addr;
      tb->mem_rsp_valid = 1;
    }

    
    tb->clk = 0;
    tb->eval();
    if(got_mem_req) {
      got_mem_req = false;
    }
    if(got_mem_rsp) {
      tb->mem_rsp_valid = 0;
      got_mem_rsp = false;
    }
    if(got_putchar) {
      tb->putchar_fifo_pop = 0;
      got_putchar = false;
    }    
    ++globals::cycle;
  }

  // ---- dump trace buffer (validate the cycle-accounting buffer) ----
  {
    unsigned wptr = tb->dbg_trace_wptr;
    printf("=== TRACE BUFFER: %u rows ===\n", wptr);
    for(unsigned row = 0; row < wptr; row++) {
      tb->dbg_trace_index = (row << 4);
      tb->clk = 1; tb->eval(); tb->clk = 0; tb->eval();   // latch r_trace_row
      uint32_t rec[12];
      for(unsigned w = 0; w < 12; w++) {
        tb->dbg_trace_index = (row << 4) | w;
        tb->eval();
        rec[w] = tb->dbg_trace_data;
      }
      for(int r = 0; r < 2; r++) {
        int b = r*6;
        uint32_t fl = rec[b+5];
        if(!((fl >> 6) & 1)) continue;   // valid bit
        printf("row %3u s%d: pc=%08x fetch=%u alloc=%u complete=%u retire=%u faulted=%u cause=%u\n",
               row, r, rec[b+0], rec[b+1], rec[b+2], rec[b+3], rec[b+4],
               (fl>>5)&1, fl&0x1f);
      }
    }
  }

  /* last-restart record (core.sv: dbg_trace_index[14]&[4], word = index[2:0]).
   * Same readback the board does with devmem; word0 top byte must be 0x5a. */
  {
    static const char *why_names[8] = {"none","mispredict","exception","serialize",
                                       "cache_flush","resume","?","?"};
    uint32_t rec[6];
    for(uint32_t w = 0; w < 6; w++) {
      tb->dbg_trace_index = 0x4010 | w;
      tb->eval();
      rec[w] = tb->dbg_trace_data;
    }
    if((rec[0]>>24) == 0x5a) { /* only the ENABLE_PC_TRACE build muxes it out */
    printf("=== LAST RESTART: magic=%02x why=%s cause=%u head_slot=%u pc=%08x src_pc=%08x cycle=%u count=%u retired_since=%u\n",
           rec[0]>>24, why_names[rec[0]&7], (rec[0]>>3)&0x1f, (rec[0]>>8)&0xff,
           rec[1], rec[2], rec[3], rec[4], rec[5]);
    }
  }

  tb->final();
  t0 = timestamp() - t0;

  if(incorrect) {
    s->mem.compare(ss->mem);
  }
  
  if(!incorrect) {
    std::ofstream out(log_name);
    out << "n_mispredicts = " << n_mispredicts
	<<  ", cycles = " << globals::cycle
	<< ", insns = " << insns_retired
	<< ", n_checks = " << n_checks
	<< "\n";
    out << static_cast<double>(insns_retired) / globals::cycle << " insn per cycle\n";
    double avg_inflight = 0, sum = 0;
    for(int i = 0; i < 32; i++) {
      if(inflight[i] == 0) continue;
      avg_inflight += i * inflight[i];
      sum += inflight[i];
      //printf("inflight[%d] = %lu\n", i, inflight[i]);
    }
    avg_inflight /= sum;
    out << insns_retired << " insns retired\n";

  
    out << "avg insns in ROB = " << avg_inflight
	      << ", max inflight = " << max_inflight << "\n";
  

    out << "l1d cache hits = " << tb->l1d_cache_hits << "\n";
    out << "l1d cache accesses = " << tb->l1d_cache_accesses << "\n";
    out << "l1d hit rate = "
	      << 100.0 *(static_cast<double>(tb->l1d_cache_hits) / tb->l1d_cache_accesses)
	      << "\n";
    out << "l1i cache hits = " << tb->l1i_cache_hits << "\n";
    out << "l1i cache accesses = " << tb->l1i_cache_accesses << "\n";
    out << "l1i hit rate = "
	      << 100.0 *(static_cast<double>(tb->l1i_cache_hits) / tb->l1i_cache_accesses)
	      << "\n";

    out << "l2 cache hits = " << tb->l2_cache_hits << "\n";
    out << "l2 cache accesses = " << tb->l2_cache_accesses << "\n";


    out << "branch mispredict rate = "
	      << (static_cast<double>(n_mispredicts)/n_branches)*100.0
	      << "\n";

    out << "mispredicts per kiloinsn = "
	      << (static_cast<double>(n_mispredicts) / insns_retired) * 1000.0
	      << "\n";
    out << n_flush_cycles << " cycles spent flushing caches\n";
    out << n_loads << " cache line loads\n";
    out << n_stores << " cache line stores\n";
    out << l1d_misses << " l1d misses\n";
    out << l1d_insns << " insns access the l1d\n";

    uint64_t total_fetch = 0, total_fetch_cycles = 0;
    for(int i = 0; i < 5; i++) {
      //out << "n_fetch[" << i << "] = " << n_fetch[i] << "\n";
      total_fetch_cycles += n_fetch[i];
      total_fetch += n_fetch[i] * i;
    }
    out << "avg fetch = " << static_cast<double>(total_fetch) / total_fetch_cycles << "\n";
    out << "resteer bubble = " << n_resteer_bubble << "\n";
    out << "front-end queues full = " << n_fq_full << "\n";
    double total_fetch_cap = 0.0;

  
    // for(int i = 0; i < 3; i++) {
    //   out << "uq_full[" << i << "] = " << n_uq_full[i] << "\n";
    // }
    // for(int i = 0; i < 3; i++) {
    //   out << "alloc[" << i << "] = " << n_alloc[i] << "\n";
    // }
    out << n_int_exec[0] << " cycles where int exec queue is not empty\n";
    out << n_int_exec[1] << " cycles where int exec queue dispatches\n";
    out << n_mem_exec[0] << " cycles where mem exec queue is not empty\n";
    out << n_mem_exec[1] << " cycles where mem exec queue dispatches\n";
    out << n_mem_exec[2] << " cycles where mem exec queue is blocked by a store\n";

    out << q_full[0] << " cycles with int queue full\n";
    out << q_full[1] << " cycles with mem queue full\n";
    out << dq_empty  << " cycles with an empty decode queue\n";
    out << uq_full   << " cycles with a  full uop queue\n";
    out << n_active << " cycles where the machine is in active state\n";
    out << rob_full << " cycles where the rob is full\n";
  
    //for(int i = 0; i < 3; i++) {
    //out << "insn ready " << i
    //		<< " "
    //<< n_rdy[i] << "\n";
    //}
    double avg_restart = 0.0;
    uint64_t total_restart = 0, accum_restart = 0;
    for(auto &p : restart_distribution) {
      avg_restart += (p.first * p.second);
      total_restart += p.second;
    }
    for(auto &p : restart_distribution) {
      accum_restart += p.second;
      if(accum_restart >= (total_restart/2)) {
	out << p.first << " median flush cycles\n";
	break;
      }
    }
    if(total_restart != 0) {
      out << avg_restart << " cycles spent in pipeline flush\n";
      avg_restart /= total_restart;
      out << total_restart << " times pipeline was flushed\n";
      out << avg_restart << " cycles to flush on avg\n";
      out << restart_distribution.begin()->first << " min cycles to flush\n";
      out << restart_distribution.rbegin()->first << " max cycles to flush\n";
    }
    
    double avg_ds_restart = 0.0;
    uint64_t total_ds_restart = 0, accum_ds_restart = 0;
    for(auto &p : restart_ds_distribution) {
      avg_ds_restart += (p.first * p.second);
      total_ds_restart += p.second;
    }
    for(auto &p : restart_ds_distribution) {
      accum_ds_restart += p.second;
      if(accum_ds_restart >= (total_ds_restart/2)) {
	out << p.first << " median delay slot flush cycles\n";
	break;
      }
    }
    if(total_ds_restart != 0) {
      out << avg_ds_restart << " cycles spent waiting for delay slot in flush\n";
      avg_ds_restart /= total_ds_restart;
      out << avg_ds_restart << " cycles waiting on delay slot on avg\n";
      out << restart_ds_distribution.begin()->first << " min cycles for delay slot\n";
      out << restart_ds_distribution.rbegin()->first << " max cycles for delay slot\n";
    }
    for(auto &p : fault_distribution) {
      out << p.first << " faults inflight, " << p.second << " times\n";
    }
    for(auto &p : branch_distribution) {
      out << p.first << " branches inflight, " << p.second << " times\n";
    }
    for(auto &p : fault_to_restart_distribution) {
      out << p.first << " cycles before restart, " << p.second << " times\n";
    }
    dump_histo(branch_name, mispredicts, s);
    uint64_t total_pushout = 0;
    for(auto &p : pushout_histo) {
      total_pushout += p.second;
    }
    out << total_pushout << " cycles of pushout\n";
    dump_histo(pushout_name, pushout_histo, s);

    /* TIP dump (rv64core-format: PC:disasm,cycles,per-kiloinsn), sorted desc */
    {
      double tip_total = 0.0;
      for(auto &p : tip_map) { tip_total += p.second; }
      std::cout << "tip cycles  = " << tip_total << "\n";
      std::vector<std::pair<uint64_t,double>> tv(tip_map.begin(), tip_map.end());
      std::sort(tv.begin(), tv.end(), [](const std::pair<uint64_t,double> &a, const std::pair<uint64_t,double> &b){ return a.second > b.second; });
      std::ofstream tf("tip.txt");
      for(auto &p : tv) {
	uint64_t pc = p.first & 0x1fffffff;
	tf << std::hex << p.first << std::dec << ":"
	   << getAsmString(get_insn(pc, s), pc) << ","
	   << p.second << ","
	   << (insns_retired ? (p.second / insns_retired) * 1000.0 : 0.0) << "\n";
      }
      tf.close();
    }

    //std::ofstream branch_info("retire_info.csv");
    uint64_t total_retire = 0, total_cycle = 0;
    for(auto &p : retire_map) {
      total_retire += p.second;
    }
    for(auto &p : retire_map) {
      //branch_info << p.first << "," << p.second << "," << static_cast<double>(p.second) / total_retire << "\n";
      total_cycle += (p.first * p.second);
    }
    //branch_info.close();
    int median_int_rdy;
    double avg_int_rdy = histo_mean_median(int_sched_rdy_map, median_int_rdy);
    out << "avg int rdy insn = " << avg_int_rdy << "\n";
    out << "median int rdy insn = " << median_int_rdy << "\n";
    
    int median_mem_lat = 0;
    double avg_mem_lat = histo_mean_median(mem_lat_map, median_mem_lat);
    out << "avg mem alloc to complete = " << avg_mem_lat << "\n";
    out << "median mem alloc to complete = " << median_mem_lat << "\n";

    avg_mem_lat = histo_mean_median(non_mem_lat_map, median_mem_lat);
    out << "avg non-mem alloc to complete = " << avg_mem_lat << "\n";
    out << "median non-mem alloc to complete = " << median_mem_lat << "\n";

    
    out << "l1d_reqs = " << l1d_reqs << "\n";
    out << "l1d_acks = " << l1d_acks << "\n";
    out << "l1d_stores = " << l1d_stores << "\n";
    out << "l1d tput = " << (static_cast<double>(l1d_acks) /l1d_reqs) << "\n";
    
    //for(auto &p :block_distribution) {
    //out << p.first << "," << p.second << "\n";
    //}
    for(int i = 1; i < 8; i++) {
      if(l1d_stall_reasons[i] != 0) {
	out << l1d_stall_reasons[i] << " " << l1d_stall_str[i] << "\n";
      }
    }
    std::cout << "total_retire = " << total_retire << "\n";
    if(snoop_delay) {
      std::cout << "[snoopinj] delay " << snoop_delay << ": issued " << snoop_issued
                << " completed " << snoop_done_n << " dropped (queue full) " << snoop_dropped
                << " still queued " << snoop_q.size() << "\n";
    }
    std::cout << "total_cycle  = " << total_cycle << "\n";
    std::cout << "total ipc    = " << static_cast<double>(total_retire) / total_cycle << "\n";
    /* L1D/L1I/L2 access+hit counters (l1d.sv).  Tied off at the henry_soc level,
     * so nothing has ever read them -- print here to establish WHAT THEY COUNT
     * before wiring them to AXI regs. */
    std::cout << "[ctr] l1d acc=" << tb->l1d_cache_accesses << " hit=" << tb->l1d_cache_hits;
    if(tb->l1d_cache_accesses) std::cout << " (" << (100.0*tb->l1d_cache_hits)/tb->l1d_cache_accesses << "%)";
    std::cout << "\n[ctr] l1i acc=" << tb->l1i_cache_accesses << " hit=" << tb->l1i_cache_hits;
    std::cout << "\n[ctr] l2  acc=" << tb->l2_cache_accesses  << " hit=" << tb->l2_cache_hits << "\n";
    if(topdown::enabled) {
      topdown_report();
    }

    uint64_t total_histo = 0;
    for(auto &p : ss->insn_histo) {
      if(p.second) {
	out << p.first << "," << p.second << "\n";
	total_histo += p.second;
      }
    }
    out << "total_histo = " << total_histo << "\n";
    out.close();
  }
  else {
    std::cout << "instructions retired = " << insns_retired << "\n";
  /* L1D/L1I/L2 access+hit counters (l1d.sv r_cache_accesses/r_cache_hits).  These
   * have never been read by anything -- they are tied off at the henry_soc level
   * -- so print them here to establish WHAT THEY COUNT before anyone wires them
   * to AXI regs and draws conclusions from them. */
  std::cout << "[ctr] l1d_accesses = " << tb->l1d_cache_accesses
            << "  l1d_hits = " << tb->l1d_cache_hits;
  if(tb->l1d_cache_accesses) {
    std::cout << "  (" << (100.0*tb->l1d_cache_hits)/tb->l1d_cache_accesses << "% hit)";
  }
  std::cout << "\n[ctr] l1i_accesses = " << tb->l1i_cache_accesses
            << "  l1i_hits = " << tb->l1i_cache_hits << "\n";
  std::cout << "[ctr] l2_accesses  = " << tb->l2_cache_accesses
            << "  l2_hits  = " << tb->l2_cache_hits << "\n";
  }
  
  std::cout << "simulation took " << t0 << " seconds, " << (insns_retired/t0)
	    << " insns per second\n";


  /* Optional physical-memory dump (e.g. to read the kernel printk buffer).
   * Format: hexPA:hexLEN:file.  s->mem reflects RTL stores in -c 0 mode. */
  if(not(memdump_spec.empty())) {
    uint64_t dpa = 0, dlen = 0;
    char dfile[512] = {0};
    if(sscanf(memdump_spec.c_str(), "%lx:%lx:%511s", &dpa, &dlen, dfile) == 3) {
      FILE *df = fopen(dfile, "wb");
      if(df) {
        fwrite(s->mem.mem + dpa, 1, dlen, df);
        fclose(df);
        std::cout << "memdump: wrote " << dlen << " bytes from PA 0x"
                  << std::hex << dpa << std::dec << " to " << dfile << "\n";
      }
      else { std::cerr << "memdump: cannot open " << dfile << "\n"; }
    }
    else { std::cerr << "memdump: bad spec (want hexPA:hexLEN:file)\n"; }
  }

  watch_dump();
  delete s;
  delete ss;
  delete [] insns_delivered;
  if(pl) {
    delete pl;
  }
  if(mc) {
    delete mc;
  }
  if(hpc) {
    delete hpc;
  }

  if(g_stale_fetches) {
    fprintf(stderr, "[stale-ifetch] %llu retired ops ran a stale L1I word\n",
	    (unsigned long long)g_stale_fetches);
  }
  if(g_store_check) {
    fprintf(stderr, "[STORE-CHECK] %llu stores matched (ISS %zu, RTL %zu still queued)\n",
	    (unsigned long long)g_stores_checked, g_iss_stores.size(), g_rtl_stores.size());
  }
  stopCapstone();
  exit(EXIT_SUCCESS);
}
