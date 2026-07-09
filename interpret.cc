#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <fcntl.h>
#include <unistd.h>
#include <sys/time.h>
#include <sys/times.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/utsname.h>


#include "interpret.hh"
#include "disassemble.hh"
#include "helper.hh"
#include "globals.hh"

static fpMode currFpMode = fpMode::mipsii;

state_t::~state_t() {
  //std::cout << mem.bytes_allocated() << " bytes present in memory image\n";
  delete &mem;
}

static void execCoproc0(uint32_t inst, state_t *s);
static void execCoproc2(uint32_t inst, state_t *s);

/* Non-faulting full-TLB VA->PA probe -- forward-ported verbatim from interp_mips
 * (interpret.cc tlb_probe_ro): mirrors va_translate's segment + 48-entry CAM
 * lookup, minus the fault paths.  Used where we need the real PA WITHOUT raising a
 * TLB exception -- the co-sim store-check and the LL/CACHE cache-line address (the
 * real load/store handler does the faulting va_translate).
 * Returns true + sets *pa on a valid (V=1) mapping; false if unmapped. */
static bool tlb_probe_ro(state_t *s, uint64_t va, uint32_t *pa) {
  uint32_t hi32 = (uint32_t)(va >> 32);
  uint32_t lo32 = (uint32_t)va;
  if(hi32 == 0x00000000u || hi32 == 0xffffffffu) {
    uint32_t seg = lo32 >> 29;
    if(seg == 0x4 || seg == 0x5) { *pa = lo32 & 0x1fffffff; return true; }
  } else if(((va >> 62) & 0x3) == 0x2) {
    *pa = (uint32_t)(va & 0xffffffffffULL); return true;
  }
  bool wide = !(hi32 == 0x00000000u || hi32 == 0xffffffffu);
  uint64_t cur_asid = s->cpr0_64[CPR0_ENTRYHI] & 0xffULL;
  uint64_t cmp_mask = wide ? ~0x3ULL : 0xffffffffULL;
  for(int i = 0; i < state_t::NUM_TLB_ENTRIES; i++) {
    uint64_t pm     = s->tlb[i].page_mask & 0x1ffe000ULL;
    uint64_t mask   = (~(uint64_t)(pm | 0x1fffULL)) & cmp_mask;
    uint64_t e_hi   = s->tlb[i].entry_hi;
    bool global     = (s->tlb[i].entry_lo0 & 1u) && (s->tlb[i].entry_lo1 & 1u);
    bool vpn_match  = (va & mask) == (e_hi & mask);
    if(wide) vpn_match = vpn_match && (((va >> 62) & 0x3) == ((e_hi >> 62) & 0x3));
    bool asid_match = global || (cur_asid == (e_hi & 0xffULL));
    if(!(vpn_match && asid_match)) continue;
    uint64_t pair_mask = pm | 0x1fffULL;
    uint64_t off_mask  = pair_mask >> 1;
    uint64_t sel_bit   = (pair_mask + 1) >> 1;
    bool odd           = (va & sel_bit) != 0;
    uint64_t e_lo      = odd ? s->tlb[i].entry_lo1 : s->tlb[i].entry_lo0;
    if(!(e_lo & 0x2u)) return false;
    uint64_t pfn = (e_lo >> 6) & 0xfffffffULL;
    *pa = (uint32_t)((pfn << 12) | (va & off_mask));
    return true;
  }
  return false;
}

template <bool EL> void execMips(state_t *s);

void execMips(state_t *s) {
  execMips<IS_LITTLE_ENDIAN>(s);
}

uint64_t sext64(uint32_t x) {
  int64_t xx = static_cast<int64_t>(x);
  return (xx << 32) >> 32;
}

#if 1
std::ostream &operator<<(std::ostream &out, const state_t & s) {
  using namespace std;
  for(int i = 0; i < 32; i++) {
    out << getGPRName(i) << " : 0x"
	<< hex << s.gpr[i] << dec
	<< "(" << s.gpr[i] << ")\n";
  }
#if 0
  for(int i = 0; i < 32; i++) {
    out << "cpr0_" << i << " : 0x"
	<< hex << s.cpr0[i] << dec
	<< "\n";
  }
  for(int i = 0; i < 32; i++) {
    out << "cpr1_" << i << " : 0x"
	<< hex << s.cpr1[i] << dec
	<< "\n";
  }
  for(int i = 0; i < 5; i++) {
    out << "fcr" << i << " : 0x"
	<< hex << s.fcr1[i] << dec
	<< "\n";
  }
#endif
  out << "icnt : " << s.icnt << "\n";
  return out;
}
#endif

static uint32_t getConditionCode(state_t *s, uint32_t cc);
static void setConditionCode(state_t *s, uint32_t v, uint32_t cc);


/* IType instructions */
static void _lb(uint32_t inst, state_t *s);
static void _lbu(uint32_t inst, state_t *s);
static void _sb(uint32_t inst, state_t *s);


static void _mtc1(uint32_t inst, state_t *s);
static void _mfc1(uint32_t inst, state_t *s);

static void _sc(uint32_t inst, state_t *s);

/* FLOATING-POINT */
static void _c(uint32_t inst, state_t *s);

static void _cvts(uint32_t inst, state_t *s);
static void _cvtd(uint32_t inst, state_t *s);

static void _truncw(uint32_t inst, state_t *s);
static void _truncl(uint32_t inst, state_t *s);

static void _movci(uint32_t inst, state_t *s);

static void _fmovc(uint32_t inst, state_t *s);
static void _fmovn(uint32_t inst, state_t *s);
static void _fmovz(uint32_t inst, state_t *s);


static void _movcs(uint32_t inst, state_t *s);
static void _movcd(uint32_t inst, state_t *s);

static void _movnd(uint32_t inst, state_t *s);
static void _movns(uint32_t inst, state_t *s);
static void _movzd(uint32_t inst, state_t *s);
static void _movzs(uint32_t inst, state_t *s);

void initState(state_t *s) {
  /* Matches the RTL's cpr0_status_reg reset in exec.sv: CU2 hardwired 1, CU0
   * resets 1, CU1 resets 0 (R/W; lazy-FPU), FR hardwired 1 (flat FR=1 datapath). */
  s->cpr0[CPR0_SR] |= SR_ERL | SR_BEV | SR_CU0 | SR_CU2 | SR_FR;
  /* Random starts at max TLB index; it cycles downward to Wired */
  s->cpr0[CPR0_RANDOM] = state_t::NUM_TLB_ENTRIES - 1;
  /* PRId: read-only processor id (R4000 family for now) */
  s->cpr0[CPR0_PRID] = PRID_VALUE;
  s->cpr0_64[CPR0_PRID] = PRID_VALUE;
  /* Config: same constant as the RTL -- R4600 cache geometry (16K I$/D$, 32B
   * lines, SC=1) so mlreset derives cachecolormask=1 (MAME_QUESTIONS.md Q5 r2) */
  s->cpr0[CPR0_CONFIG] = 0x0002e4b3;
}

/* Raise MIPS Reserved Instruction exception (ExcCode=10).
 * Called by the interpreter when it encounters an unimplemented opcode.
 * Sets EPC/Cause/Status and redirects the interpreter to the exception
 * vector so execution follows the bare-metal exc_handler path. */
/* Sign-extend a 32-bit value to 64-bit, matching MIPS hardware behaviour
 * for registers and PC values where bit 31 indicates kernel address space. */
static inline state_t::reg_t sext32(uint32_t v) {
  return (state_t::reg_t)(int64_t)(int32_t)v;
}

/* Set EPC + Cause.BD for an exception, accounting for the branch-delay-slot case
 * (EPC = branch pc = pc-4, BD=1); matches the RTL.  Call before the ExcCode write
 * (which preserves BD by masking only bits [6:2]). */
static inline void set_exc_pc(state_t *s) {
  s->ll_link_valid = false;   /* any exception breaks the LL/SC link (R10000 p.27) */
  /* R4000: EPC and Cause.BD update ONLY when Status.EXL==0.  A nested exception
   * (EXL already set, e.g. a TLB miss inside the refill handler) must leave EPC +
   * BD holding the ORIGINAL access so its eret retries it.  Matches the RTL, where
   * exec.sv gates the EPC write on r_sr_exl==0. */
  if(s->cpr0[CPR0_SR] & SR_EXL) return;
  if(s->in_delay_slot) {
    s->cpr0[CPR0_EPC]    = (uint32_t)(s->pc - 4);
    s->cpr0[CPR0_CAUSE] |=  (1u << 31);
  } else {
    s->cpr0[CPR0_EPC]    = (uint32_t)s->pc;
    s->cpr0[CPR0_CAUSE] &= ~(1u << 31);
  }
}

/* General exception vector (R4000): BEV=1 -> base 0xBFC00200, BEV=0 -> 0x80000000;
 * general/common offset 0x180.  So 0xBFC00380 (BEV=1) or 0x80000180 (BEV=0).  All
 * sites below are general exceptions (AdEL/AdES/RI/Ov/Tr/Int); TLB refill/XTLB use
 * 0x000/0x080 and are not raised by this interpreter. */
static inline uint32_t exc_vector_general(state_t *s) {
  uint32_t base = (s->cpr0[CPR0_SR] & SR_BEV) ? 0xBFC00200u : 0x80000000u;
  return base | 0x180u;
}

static void raise_adel(state_t *s) {
  set_exc_pc(s);
  s->cpr0[CPR0_CAUSE] = (s->cpr0[CPR0_CAUSE] & ~(0x1fu << 2)) | (4u << 2);
  s->cpr0[CPR0_SR]    = (s->cpr0[CPR0_SR] & ~SR_ERL) | SR_EXL;
  s->pc = sext32(exc_vector_general(s));
}

static void raise_ades(state_t *s) {
  set_exc_pc(s);
  s->cpr0[CPR0_CAUSE] = (s->cpr0[CPR0_CAUSE] & ~(0x1fu << 2)) | (5u << 2);
  s->cpr0[CPR0_SR]    = (s->cpr0[CPR0_SR] & ~SR_ERL) | SR_EXL;
  s->pc = sext32(exc_vector_general(s));
}

/* Reserved Instruction exception setup (ExcCode=10), no diagnostic message. */
static void take_exception_ri(state_t *s) {
  set_exc_pc(s);
  s->cpr0[CPR0_CAUSE] = (s->cpr0[CPR0_CAUSE] & ~(0x1fu << 2)) | (10u << 2);
  s->cpr0[CPR0_SR]    = (s->cpr0[CPR0_SR] & ~SR_ERL) | SR_EXL;
  s->pc = sext32(exc_vector_general(s));
}

/* FP exception (ExcCode 15) with the Unimplemented-Op (E) bit set in FCSR.Cause
 * (bit 17) -- the catch-all for any COP1 op not implemented in hardware (matches
 * the RTL FP_UNIMPL path; the OS soft-float emulator handles it). */
static void take_exception_fpe(state_t *s) {
  set_exc_pc(s);
  s->cpr0[CPR0_CAUSE] = (s->cpr0[CPR0_CAUSE] & ~(0x1fu << 2)) | (15u << 2);
  s->cpr0[CPR0_SR]    = (s->cpr0[CPR0_SR] & ~SR_ERL) | SR_EXL;
  s->fcr1[CP1_CR31]  |= (1u << 17);
  s->pc = sext32(exc_vector_general(s));
}

static void raise_ri(state_t *s, uint32_t inst) {
  fprintf(stderr, "unimplemented: opcode=0x%02x funct=0x%02x @ pc=0x%08x\n",
          inst >> 26, inst & 0x3fu, (uint32_t)s->pc);
  take_exception_ri(s);
}

/* Execute a branch/jump delay-slot instruction.  Returns true iff the delay slot
 * raised an exception (Status.EXL went 0->1, i.e. it vectored).  In that case the
 * branch/jump must NOT be taken: the exception has already redirected pc to the
 * handler with EPC = the branch pc (BD=1), and overwriting pc with the branch
 * target would SWALLOW the delay-slot fault (the RTL takes it -> co-sim diverges). */
template <bool EL>
static inline bool run_delay_slot(state_t *s) {
  bool exl_before = (s->cpr0[CPR0_SR] & SR_EXL) != 0;
  bool saved = s->in_delay_slot;
  s->in_delay_slot = true;
  execMips<EL>(s);
  s->in_delay_slot = saved;
  return (!exl_before) && ((s->cpr0[CPR0_SR] & SR_EXL) != 0);
}

/* 64-bit operating mode, matching exec.sv:2640-2646:
 *   kernel=(KSU==0)|EXL|ERL ; user=(KSU==2)&!EXL&!ERL ; super=(KSU==1)&!EXL&!ERL
 *   in_64b = (kernel&KX) | (user&UX) | (super&SX). */
static inline bool in_64b_mode(state_t *s) {
  uint32_t sr = s->cpr0[CPR0_SR];
  uint32_t ksu = (sr >> 3) & 3u;
  bool exl = (sr & SR_EXL) != 0, erl = (sr & SR_ERL) != 0;
  bool kernel = (ksu == 0u) || exl || erl;
  bool user   = (ksu == 2u) && !exl && !erl;
  bool super  = (ksu == 1u) && !exl && !erl;
  /* 64-bit operations are always valid in Kernel mode (KX gates 64-bit
   * addressing / the XTLB vector, not op availability); Supervisor/User need
   * SX/UX.  Must match decode_mips.sv's w_in_64b_mode for the co-sim. */
  return  kernel ||
         (user   && (sr & SR_UX)) ||
         (super  && (sr & SR_SX));
}

/* The 64-bit instructions decode_mips.sv gates behind 64-bit mode -- must match
 * EXACTLY so the co-sim agrees (RTL does NOT gate dsll32/dsrl32/dsra32, daddi,
 * or 64-bit loads/stores, so neither do we). */
static inline bool is_64b_gated(uint32_t inst) {
  uint32_t op = inst >> 26;
  if(op == 0x18) return true;                  /* daddi  */
  if(op == 0x19) return true;                  /* daddiu */
  if(op == 0x34) return true;                  /* lld    */
  if(op == 0x3c) return true;                  /* scd    */
  if(op != 0) return false;
  switch(inst & 0x3fu) {
    case 0x14: case 0x16: case 0x17:            /* dsllv dsrlv dsrav        */
    case 0x1c: case 0x1d: case 0x1e: case 0x1f: /* dmult dmultu ddiv ddivu  */
    case 0x2c: case 0x2d: case 0x2e: case 0x2f: /* dadd daddu dsub dsubu    */
    case 0x38: case 0x3a: case 0x3b:            /* dsll dsrl dsra           */
      return true;
    default: return false;
  }
}

static void raise_overflow(state_t *s) {
  set_exc_pc(s);
  s->cpr0[CPR0_CAUSE] = (s->cpr0[CPR0_CAUSE] & ~(0x1fu << 2)) | (12u << 2);
  s->cpr0[CPR0_SR]    = (s->cpr0[CPR0_SR] & ~SR_ERL) | SR_EXL;
  s->pc = sext32(exc_vector_general(s));
}

static void raise_trap(state_t *s) {
  set_exc_pc(s);
  s->cpr0[CPR0_CAUSE] = (s->cpr0[CPR0_CAUSE] & ~(0x1fu << 2)) | (13u << 2);
  s->cpr0[CPR0_SR]    = (s->cpr0[CPR0_SR] & ~SR_ERL) | SR_EXL;
  s->pc = sext32(exc_vector_general(s));
}

void raise_int(state_t *s, uint32_t epc) {
  s->ll_link_valid = false;   /* interrupt breaks the LL/SC link */
  s->cpr0[CPR0_EPC]   = epc;
  s->cpr0[CPR0_CAUSE] = (1u << 15);  /* IP[7]=1 (timer), ExcCode=0, BD=0 */
  s->cpr0[CPR0_SR]    = (s->cpr0[CPR0_SR] & ~SR_ERL) | SR_EXL;
  s->pc = sext32(exc_vector_general(s));
}

static uint32_t getConditionCode(state_t *s, uint32_t cc) {
  return ((s->fcr1[CP1_CR25] & (1U<<cc)) >> cc) & 0x1;
}

/* ===== TLB address translation (forward-ported from interp_mips) ===========
 * r9999's interp historically used a 1:1 va2pa STUB (kseg0/1 strip, else
 * identity), which mistranslates every MAPPED (useg/kseg2/xkseg) access.  That is
 * fine for the ooo_core kseg0/identity-TLB co-sim but WRONG as the henry_tb golden
 * ISS for IRIX (kseg2-heavy): a kseg2 load the stub sent to the wrong PA read 0
 * while the RTL (real TLB) read the correct seeded value -> a false divergence.
 * This is interp_mips's real TLB (va_translate), so the golden ISS translates
 * exactly like the RTL. */

enum class tlb_op { fetch, load, store };

/* TLB-refill/XTLB-aware exception vector (interp_mips exc_vector): refill uses
 * offset 0x000 (TLB) / 0x080 (XTLB) only when EXL==0, else the 0x180 common
 * offset (a nested miss inside the refill handler). */
static inline uint32_t exc_vector(state_t *s, bool is_refill, bool exl_was_set,
                                  bool is_xtlb) {
  uint32_t base   = (s->cpr0[CPR0_SR] & SR_BEV) ? 0xBFC00200u : 0x80000000u;
  uint32_t offset = 0x180u;
  if(is_refill && !exl_was_set)
    offset = is_xtlb ? 0x080u : 0x000u;
  return base + offset;
}

/* Fold the faulting VA into BadVAddr / EntryHi.VPN2 / Context / XContext
 * (interp_mips tlb_set_fault_state), preserving the software PTEBase + ASID. */
static void tlb_set_fault_state(state_t *s, uint64_t va) {
  s->cpr0[CPR0_BADVADDR]     = (uint32_t)va;
  s->cpr0_64[CPR0_BADVADDR]  = va;
  uint64_t r    = (va >> 62) & 0x3;
  uint64_t vpn2 = (va >> 13) & 0x7ffffffULL;             /* VPN2[39:13] -> 27 bits */
  uint64_t asid = s->cpr0_64[CPR0_ENTRYHI] & 0xffULL;
  uint64_t ehi  = (r << 62) | (vpn2 << 13) | asid;
  s->cpr0_64[CPR0_ENTRYHI] = ehi;
  s->cpr0[CPR0_ENTRYHI]    = (uint32_t)ehi;
  uint64_t ctx = s->cpr0_64[CPR0_CONTEXT] & ~0x7fffffULL; /* preserve PTEBase */
  ctx |= ((va >> 13) & 0x7ffffULL) << 4;                  /* VA[31:13] -> Context[22:4] */
  s->cpr0_64[CPR0_CONTEXT] = ctx;
  s->cpr0[CPR0_CONTEXT]    = (uint32_t)ctx;
  uint64_t xctx = s->cpr0_64[CPR0_XCONTEXT] & ~0x1ffffffffULL;
  xctx |= ((va >> 13) & 0x7ffffffULL) << 4;               /* BadVPN2 -> XContext[30:4] */
  xctx |= r << 31;                                        /* R -> XContext[32:31] */
  s->cpr0_64[CPR0_XCONTEXT] = xctx;
  s->cpr0[CPR0_XCONTEXT]    = (uint32_t)xctx;
}

/* Raise a TLB exception (Refill/Invalid/Modified) and set s->tlb_fault so the
 * calling load/store/fetch handler aborts.  Mirrors r9999's other raise_* helpers
 * (set_exc_pc -> Cause.ExcCode -> SR.EXL -> pc=vector) with the refill vector. */
static void raise_tlb(state_t *s, uint64_t va, uint32_t exccode,
                      bool is_refill, bool is_xtlb) {
  bool exl_was_set = (s->cpr0[CPR0_SR] & SR_EXL) != 0;
  tlb_set_fault_state(s, va);
  set_exc_pc(s);
  s->cpr0[CPR0_CAUSE] = (s->cpr0[CPR0_CAUSE] & ~(0x1fu << 2)) | (exccode << 2);
  s->cpr0[CPR0_SR]    = (s->cpr0[CPR0_SR] & ~SR_ERL) | SR_EXL;
  s->pc = sext32(exc_vector(s, is_refill && !exl_was_set, exl_was_set, is_xtlb));
  s->tlb_fault = true;
}

/* Software micro-TLB: a direct-mapped cache of recent (VPN,ASID)->PPN in front of
 * the 48-entry architectural CAM (a pure sim accelerator; the CAM stays the source
 * of truth).  Flushed on any TLB write (TLBWI/TLBWR) so a hit can never diverge. */
static const int UTLB_SZ = 64;
struct utlb_entry { uint64_t vpn, asid; uint32_t ppn; bool dirty, valid; };
static utlb_entry g_utlb[UTLB_SZ];
static inline void utlb_flush() { for(auto &e : g_utlb) e.valid = false; }

/* Translate a virtual address (interp_mips va_translate).  On a TLB exception,
 * sets s->tlb_fault and returns 0 -- the caller MUST check s->tlb_fault and abort.
 * Unmapped kseg0/kseg1 and xkphys are fast paths with no lookup. */
static uint32_t va_translate(state_t *s, uint64_t va, tlb_op op) {
  uint32_t hi32 = (uint32_t)(va >> 32);
  uint32_t lo32 = (uint32_t)va;
  if(hi32 == 0x00000000u || hi32 == 0xffffffffu) {
    uint32_t seg = lo32 >> 29;
    if(seg == 0x4 || seg == 0x5) {                 /* kseg0/kseg1: unmapped */
      return lo32 & 0x1fffffff;
    }
  } else {
    if(((va >> 62) & 0x3) == 0x2) {                /* xkphys: unmapped direct PA */
      return (uint32_t)(va & 0xffffffffffULL);
    }
  }
  bool xtlb = !(hi32 == 0x00000000u || hi32 == 0xffffffffu);
  uint64_t cur_asid = s->cpr0_64[CPR0_ENTRYHI] & 0xffULL;
  uint64_t vpn = va >> 12;
  utlb_entry &ce = g_utlb[vpn & (UTLB_SZ - 1)];
  if(ce.valid && ce.vpn == vpn && ce.asid == cur_asid &&
     !(op == tlb_op::store && !ce.dirty)) {        /* store to clean page -> CAM (Modified) */
    return (ce.ppn << 12) | (uint32_t)(va & 0xfffULL);
  }
  for(int i = 0; i < state_t::NUM_TLB_ENTRIES; i++) {
    uint64_t pm      = s->tlb[i].page_mask & 0x1ffe000ULL;
    uint64_t vpnMask = (~(uint64_t)(pm | 0x1fffULL)) & 0x000000ffffffe000ULL; /* VPN2[39:13] */
    uint64_t e_hi    = s->tlb[i].entry_hi;
    bool global      = (s->tlb[i].entry_lo0 & 1u) && (s->tlb[i].entry_lo1 & 1u);
    bool vpn_match   = ((va & vpnMask) == (e_hi & vpnMask))
                    && (((va >> 62) & 0x3) == ((e_hi >> 62) & 0x3));
    bool asid_match  = global || (cur_asid == (e_hi & 0xffULL));
    if(!(vpn_match && asid_match))
      continue;
    uint64_t pair_mask = pm | 0x1fffULL;
    uint64_t off_mask  = pair_mask >> 1;
    uint64_t sel_bit   = (pair_mask + 1) >> 1;
    bool odd           = (va & sel_bit) != 0;
    uint64_t e_lo      = odd ? s->tlb[i].entry_lo1 : s->tlb[i].entry_lo0;
    if(!(e_lo & 0x2u)) {                           /* V == 0 -> TLB Invalid */
      uint32_t code = (op == tlb_op::store) ? 3u : 2u;
      raise_tlb(s, va, code, /*is_refill=*/false, xtlb);
      return 0;
    }
    if(op == tlb_op::store && !(e_lo & 0x4u)) {     /* D == 0 -> TLB Modified */
      raise_tlb(s, va, 1u, /*is_refill=*/false, xtlb);
      return 0;
    }
    uint64_t pfn = (e_lo >> 6) & 0xfffffffULL;
    uint64_t pa  = (pfn << 12) | (va & off_mask);
    ce.vpn = vpn; ce.asid = cur_asid; ce.ppn = (uint32_t)(pa >> 12);
    ce.dirty = (e_lo & 0x4u) != 0; ce.valid = true;
    return (uint32_t)pa;
  }
  uint32_t code = (op == tlb_op::store) ? 3u : 2u;   /* no match -> TLB Refill */
  raise_tlb(s, va, code, /*is_refill=*/true, xtlb);
  return 0;
}

static void setConditionCode(state_t *s, uint32_t v, uint32_t cc) {
  uint32_t m0,m1,m2;
  m0 = 1U<<cc;
  m1 = ~m0;
  m2 = ~(v-1);
  s->fcr1[CP1_CR25] = (s->fcr1[CP1_CR25] & m1) | ((1U<<cc) & m2);
}



template <typename T>
struct c1xExec {
  void operator()(const coproc1x_t& insn, state_t *s) {
    T _fr = *reinterpret_cast<T*>(s->cpr1+insn.fr);
    T _fs = *reinterpret_cast<T*>(s->cpr1+insn.fs);
    T _ft = *reinterpret_cast<T*>(s->cpr1+insn.ft);
    T &_fd = *reinterpret_cast<T*>(s->cpr1+insn.fd);  
    switch(insn.id)
      {
      case 4:
	_fd = _fs*_ft + _fr;
	break;
      case 5:
	_fd = _fs*_ft - _fr;
	break;
      default:
	std::cerr << "unhandled coproc1x insn @ 0x"
		  << std::hex << s->pc << std::dec
		  << ", id = " << insn.id
		  <<"\n";
	exit(-1);
      }
    s->pc += 4;
  }
};


template <bool EL, typename T>
void lxc1(uint32_t inst, state_t *s) {
  mips_t mi(inst);
  uint32_t ea = va_translate(s, s->gpr[mi.lc1x.base] + s->gpr[mi.lc1x.index], tlb_op::load); if(s->tlb_fault) return;
  *reinterpret_cast<T*>(s->cpr1 + mi.lc1x.fd) = bswap<EL>(s->mem.get<T>(ea));
  s->pc += 4;
}

template <bool EL>
static void execCoproc1x(uint32_t inst, state_t *s) {
  mips_t mi(inst);

  switch(mi.lc1x.id)
    {
    case 0:
      //lwxc1
      lxc1<EL,int32_t>(inst, s);
      return;
    case 1:
      //ldxc1
      lxc1<EL,int64_t>(inst, s);
      return;
    default:
      break;
    }
  
  switch(mi.c1x.fmt)
   {
   case 0: {
     c1xExec<float> e;
     e(mi.c1x, s);
     return;
   }
   case 1: {
     c1xExec<double> e;
     e(mi.c1x, s);
     return;
   }
   default:
     std::cerr << "weird type in do_c1x_op @ 0x"
	       << std::hex << s->pc << std::dec
	       <<"\n";
     exit(-1);
   }
}



template <bool EL, branch_type bt>
void branch(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = ((int32_t)himm) << 2;
  state_t::reg_t npc = s->pc+4; 
  bool isLikely = false, takeBranch = false, saveReturn = false;
  switch(bt)
    {
    case branch_type::beql:
      takeBranch = (s->gpr[rt] == s->gpr[rs]);
      s->insn_histo[mipsInsn::BEQL]++;
      isLikely = true;
      break;
    case branch_type::beq:
      takeBranch = (s->gpr[rt] == s->gpr[rs]);
      s->insn_histo[mipsInsn::BEQ]++;
      break;
    case branch_type::bnel:
      isLikely = true;
      takeBranch = (s->gpr[rt] != s->gpr[rs]);
      s->insn_histo[mipsInsn::BNEL]++;
      break;
    case branch_type::bne:
      takeBranch = (s->gpr[rt] != s->gpr[rs]);
      s->insn_histo[mipsInsn::BNE]++;
      break;
    case branch_type::blezl:
      isLikely = true;
      takeBranch = (s->gpr[rs] <= 0);
      s->insn_histo[mipsInsn::BLEZL]++;
      break;
    case branch_type::blez:
      takeBranch = (s->gpr[rs] <= 0);
      s->insn_histo[mipsInsn::BLEZ]++;
      break;
    case branch_type::bgtzl:
      isLikely = true;
      takeBranch = (s->gpr[rs] > 0);
      s->insn_histo[mipsInsn::BGTZL]++;
      break;
    case branch_type::bgtz:
      takeBranch = (s->gpr[rs] > 0);
      s->insn_histo[mipsInsn::BGTZ]++;
      break;
    case branch_type::bgezl:
      isLikely = true;
      takeBranch = (s->gpr[rs] >= 0);
      s->insn_histo[mipsInsn::BGEZL]++;
      break;      
    case branch_type::bgez:
      takeBranch = (s->gpr[rs] >= 0);
      s->insn_histo[mipsInsn::BGEZ]++;
      break;
    case branch_type::bltzl:
      isLikely = true;
      takeBranch = (s->gpr[rs] < 0);
      s->insn_histo[mipsInsn::BLTZL]++;
      break;
    case branch_type::bltz:
      takeBranch = (s->gpr[rs] < 0);
      s->insn_histo[mipsInsn::BLTZ]++;
      break;
    case branch_type::bgezal:
      takeBranch = (s->gpr[rs] >= 0);
      s->insn_histo[mipsInsn::BGEZAL]++;
      saveReturn = true;
      break;
    case branch_type::bltzal:
      takeBranch = (s->gpr[rs] < 0);
      s->insn_histo[mipsInsn::BLTZAL]++;
      saveReturn = true;
      break;
    case branch_type::bgezall:
      isLikely = true;
      takeBranch = (s->gpr[rs] >= 0);
      s->insn_histo[mipsInsn::BGEZALL]++;
      saveReturn = true;
      break;
    case branch_type::bltzall:
      isLikely = true;
      takeBranch = (s->gpr[rs] < 0);
      s->insn_histo[mipsInsn::BLTZALL]++;
      saveReturn = true;
      break;
    case branch_type::bc1tl:
      isLikely = true;
      takeBranch = getConditionCode(s,((inst>>18)&7))==1;
      s->insn_histo[mipsInsn::BC1TL]++;
      break;
    case branch_type::bc1t:
      takeBranch = getConditionCode(s,((inst>>18)&7))==1;
      s->insn_histo[mipsInsn::BC1T]++;
      break;
    case branch_type::bc1fl:
      isLikely = true;
      takeBranch = getConditionCode(s,((inst>>18)&7))==0;
      s->insn_histo[mipsInsn::BC1FL]++;
      break;
    case branch_type::bc1f:
      takeBranch = getConditionCode(s,((inst>>18)&7))==0;
      s->insn_histo[mipsInsn::BC1F]++;
      break;
    default:
      UNREACHABLE();
    }

  s->pc += 4;
  if(isLikely) {
    if(takeBranch) {
      if(saveReturn)
	s->gpr[31] = npc + 4;   /* full 64-bit link (match RTL int_uop.pc+8; no 32b trunc) */
      if(!run_delay_slot<EL>(s))
	s->pc = (imm+npc);
    }
    else {
      s->pc += 4;
    }
  }
  else {
    bool ds_faulted = run_delay_slot<EL>(s);
    if(takeBranch){
      if(saveReturn) {
	s->gpr[31] = npc + 4;   /* full 64-bit link (match RTL int_uop.pc+8; no 32b trunc) */
      }
      if(!ds_faulted)
	s->pc = (imm+npc);
    }
  }
}

template <bool EL>
void _bgez_bltz(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  switch(rt)
    {
    case 0:
      branch<EL,branch_type::bltz>(inst, s);
      break;
    case 1:
      branch<EL,branch_type::bgez>(inst, s);
      break;
    case 2:
      branch<EL,branch_type::bltzl>(inst, s);
      break;
    case 3:
      branch<EL,branch_type::bgezl>(inst, s);
      break;
    case 17:
      branch<EL,branch_type::bgezal>(inst, s);
      break;
    case 16:
      branch<EL,branch_type::bltzal>(inst, s);
      break;
    case 18:
      branch<EL,branch_type::bltzall>(inst, s);
      break;
    case 19:
      branch<EL,branch_type::bgezall>(inst, s);
      break;
    case 8: case 9: case 10: case 11: case 12: case 14: { /* trap-immediates */
      uint32_t rs = (inst >> 21) & 31;
      int64_t a = (int64_t)s->gpr[rs];
      int64_t simm = (int64_t)(int16_t)(inst & 0xffff);
      bool trap = false;
      switch(rt) {
      case 8:  trap = (a >= simm);                           s->insn_histo[mipsInsn::TGEI]++;  break;
      case 9:  trap = ((uint64_t)a >= (uint64_t)simm);       s->insn_histo[mipsInsn::TGEIU]++; break;
      case 10: trap = (a < simm);                            s->insn_histo[mipsInsn::TLTI]++;  break;
      case 11: trap = ((uint64_t)a < (uint64_t)simm);        s->insn_histo[mipsInsn::TLTIU]++; break;
      case 12: trap = (a == simm);                           s->insn_histo[mipsInsn::TEQI]++;  break;
      case 14: trap = (a != simm);                           s->insn_histo[mipsInsn::TNEI]++;  break;
      }
      if(trap) raise_trap(s); else s->pc += 4;
      break;
    }
    default:
      std::cerr << "case " << rt << " not handled!\n";
      exit(-1);
    }
}


template <bool EL>
void _lw(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  if(ea & 3) { raise_adel(s); return; }
  s->gpr[rt] = bswap<EL>(s->mem.get<int32_t>(ea));
  //#define TRACE_MEM
  //printf("_lw pc %x from ea %x = %x\n", s->pc, (uint32_t)s->gpr[rs] + imm,
  //s->gpr[rt]);
  //#undef TRACE_MEM
  s->pc += 4;
  s->insn_histo[mipsInsn::LW]++;
}

template <bool EL>
void _lh(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;

  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  if(ea & 1) { raise_adel(s); return; }
  int16_t mem = bswap<EL>(s->mem.get<int16_t>(ea));
  
  s->gpr[rt] = static_cast<int32_t>(mem);
#ifdef TRACE_MEM
  printf("_lh from %x = %x\n", ea, s->gpr[rt]);
#endif
  s->pc +=4;
  s->insn_histo[mipsInsn::LH]++;  
}


static void _lb(uint32_t inst, state_t *s){
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  s->gpr[rt] = static_cast<int32_t>(s->mem.get<int8_t>(ea));
#ifdef TRACE_MEM
  printf("_lb from %x = %x\n", ea, s->gpr[rt]);
#endif  
  s->pc += 4;
  s->insn_histo[mipsInsn::LB]++;  
}

static void _lbu(uint32_t inst, state_t *s){
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;

  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  uint32_t zExt = s->mem.get<uint8_t>(ea);
  *((uint64_t*)&(s->gpr[rt])) = zExt;
  s->pc += 4;
  s->insn_histo[mipsInsn::LBU]++;
}


template <bool EL>
void _lhu(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;

  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  if(ea & 1) { raise_adel(s); return; }
  uint32_t zExt = bswap<EL>(s->mem.get<uint16_t>(ea));
  *((uint64_t*)&(s->gpr[rt])) = zExt;
  //printf("_lhu from %x = %x\n", ea, s->gpr[rt]);  
  s->pc += 4;
  s->insn_histo[mipsInsn::LHU]++;  
}


template <bool EL>
void _sw(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  if(ea & 3) { raise_ades(s); return; }
  s->mem.set<int32_t>(ea,  bswap<EL>(static_cast<int32_t>(s->gpr[rt])));
  s->pc += 4;
  s->insn_histo[mipsInsn::SW]++;
}

template <bool EL>
void _sd(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int32_t imm = (int32_t)(int16_t)(inst & 0xffffu);
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  if(ea & 7) { raise_ades(s); return; }
  s->mem.set<int64_t>(ea, bswap<EL>(s->gpr[rt]));
  s->pc += 4;
  s->insn_histo[mipsInsn::SD]++;
}

template <bool EL>
void _ld(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int32_t imm = (int32_t)(int16_t)(inst & 0xffffu);
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  if(ea & 7) { raise_adel(s); return; }
  s->gpr[rt] = bswap<EL>(s->mem.get<int64_t>(ea));
  s->pc += 4;
  s->insn_histo[mipsInsn::LD]++;
}

template <bool EL>
void _sc(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  /* SC succeeds iff the reservation is still valid and on this cache line. */
  bool ok = s->ll_link_valid && (s->ll_link_addr == (ea & ~UINT64_C(0xf)));
  if(ok) s->mem.set<int32_t>(ea,  bswap<EL>(static_cast<int32_t>(s->gpr[rt])));
  s->ll_link_valid = false;   /* SC always clears the link */
  s->gpr[rt] = ok ? 1 : 0;
  s->pc += 4;
  s->insn_histo[mipsInsn::SC]++;
}

template <bool EL>
void _lld(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int32_t imm = (int32_t)(int16_t)(inst & 0xffffu);
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  if(ea & 7) { raise_adel(s); return; }
  /* load-linked doubleword: 64-bit load (link bit is a no-op in a functional sim) */
  s->gpr[rt] = bswap<EL>(s->mem.get<int64_t>(ea));
  s->pc += 4;
  s->insn_histo[mipsInsn::LLD]++;
}

template <bool EL>
void _scd(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int32_t imm = (int32_t)(int16_t)(inst & 0xffffu);
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  if(ea & 7) { raise_ades(s); return; }
  /* SCD succeeds iff the reservation is still valid and on this cache line. */
  bool ok = s->ll_link_valid && (s->ll_link_addr == (ea & ~UINT64_C(0xf)));
  if(ok) s->mem.set<int64_t>(ea, bswap<EL>(s->gpr[rt]));
  s->ll_link_valid = false;   /* SC always clears the link */
  s->gpr[rt] = ok ? 1 : 0;
  s->pc += 4;
  s->insn_histo[mipsInsn::SCD]++;
}


template <bool EL>
void _sh(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
    
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  if(ea & 1) { raise_ades(s); return; }
  s->mem.set<int16_t>(ea,  bswap<EL>(((int16_t)s->gpr[rt])));
  s->pc += 4;
  s->insn_histo[mipsInsn::SH]++;
}

static void _sb(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
    
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  s->mem.set<uint8_t>(ea, static_cast<uint8_t>(s->gpr[rt]));
  
  s->pc +=4;
  s->insn_histo[mipsInsn::SB]++;
}

static void _mtc1(uint32_t inst, state_t *s) {
  uint32_t fs = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;
  uint32_t w = (uint32_t)s->gpr[rt];
  if((s->cpr0[CPR0_SR] & SR_FR) == 0) {
    /* FR=0: merge the new word into the fs[0]-selected half of the even reg, preserving
     * the other half (R10000 UM p.307). */
    uint64_t old = s->cpr1[fs & ~1u];
    s->cpr1[fs & ~1u] = (fs & 1) ? ((old & 0xffffffffull) | ((uint64_t)w << 32))
                                 : ((old & 0xffffffff00000000ull) | w);
  } else {
    /* FR=1: FPR[fs] = sign_extend32(GPR[rt][31:0]) */
    s->cpr1[fs] = (uint64_t)(int64_t)(int32_t)w;
  }
  s->pc += 4;
  s->insn_histo[mipsInsn::MTC1]++;
}

static void _mfc1(uint32_t inst, state_t *s) {
  uint32_t fs = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;
  /* FR=1: GPR[rt] = sign_extend32(FPR[fs][31:0]).  FR=0: the even reg of the pair
   * holds the 64-bit double; fs[0] selects the half (even=low, odd=high). */
  uint64_t v = s->cpr1[fs & ~1u];
  uint32_t w = ((s->cpr0[CPR0_SR] & SR_FR) == 0) ? (uint32_t)((fs & 1) ? (v >> 32) : v)
                                                 : (uint32_t)s->cpr1[fs];
  s->gpr[rt] = (int64_t)(int32_t)w;
  s->pc +=4;
  s->insn_histo[mipsInsn::MFC1]++;
}

static void _dmtc1(uint32_t inst, state_t *s) {
  uint32_t fs = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;
  /* FR=1: FPR[fs] = GPR[rt] (full 64-bit, no sign-ext) */
  s->cpr1[fs] = s->gpr[rt];
  s->pc += 4;
  s->insn_histo[mipsInsn::DMTC1]++;
}

static void _dmfc1(uint32_t inst, state_t *s) {
  uint32_t fs = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;
  /* FR=1: GPR[rt] = FPR[fs] (full 64-bit) */
  s->gpr[rt] = s->cpr1[fs];
  s->pc += 4;
  s->insn_histo[mipsInsn::DMFC1]++;
}

/* map a raw FP control-register number to the compact fcr1[] index */
static inline int fcr_index(uint32_t cr) {
  switch(cr) {
  case 0:  return CP1_CR0;   /* FIR  */
  case 31: return CP1_CR31;  /* FCSR */
  case 25: return CP1_CR25;
  case 26: return CP1_CR26;
  case 28: return CP1_CR28;
  default: return CP1_CR31;
  }
}

static void _cfc1(uint32_t inst, state_t *s) {
  uint32_t cr = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;
  /* GPR[rt] = sign_extend32(FCR[cr]); FCR0 is the read-only FIR */
  uint32_t v = (cr == 0) ? 0x00000500u : (uint32_t)s->fcr1[fcr_index(cr)];
  s->gpr[rt] = (int64_t)(int32_t)v;
  s->pc += 4;
  s->insn_histo[mipsInsn::CFC1]++;
}

static void _ctc1(uint32_t inst, state_t *s) {
  uint32_t cr = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;
  /* FCR[cr] = GPR[rt][31:0]; FCR0 (FIR) is read-only */
  if(cr != 0)
    s->fcr1[fcr_index(cr)] = (uint32_t)s->gpr[rt];
  s->pc += 4;
  s->insn_histo[mipsInsn::CTC1]++;
}


template <bool EL>
void _swl(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  uint32_t ma = ea & 3;
  ea &= 0xfffffffc;
  if(EL)
    ma = 3 - ma;
  uint32_t r = bswap<EL>(s->mem.get<uint32_t>(ea));   
  uint32_t xx=0,x = s->gpr[rt];
  
  uint32_t xs = x >> (8*ma);
  /* 64-bit shift: at ma==0 the count is 32, a 32-bit-shift UB (x86 masks to 0,
   * making m=0xffffffff and storing r|rt instead of rt). */
  uint32_t m = (uint32_t)~(((uint64_t)1u << (8*(4 - ma))) - 1);
  xx = (r & m) | xs;
  //std::cout << "SIM SWL EA " << std::hex << ea
  //<< ", MA = " << ma
  //<< ", X = " << x
  //<< ", R = " << r
  //<< ", M = " << m
  //	    << ", XX = " << xx << std::dec << "\n";
  
  s->mem.set<uint32_t>(ea, bswap<EL>(xx));
  s->pc += 4;
  s->insn_histo[mipsInsn::SWL]++;  
}

template <bool EL>
void _swr(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  uint32_t ma = ea & 3;
  if(EL)
    ma = 3 - ma;
  ea &= ~(3U);
  uint32_t r = bswap<EL>(s->mem.get<uint32_t>(ea));   
  uint32_t xx=0,x = s->gpr[rt];
  
  uint32_t xs = 8*(3-ma);
  uint32_t rm = (1U << xs) - 1;

  xx = (x << xs) | (rm & r);
  s->mem.set<uint32_t>(ea, bswap<EL>(xx));
  s->pc += 4;
  s->insn_histo[mipsInsn::SWR]++;
}

template <bool EL>
void _lwl(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  
  uint32_t ea = va_translate(s, (uint32_t)s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  uint32_t u_ea = ea;
  uint32_t ma = ea & 3;
  ea &= 0xfffffffc;
  if(EL)
    ma = 3 - ma;
  uint32_t r = bswap<EL>(s->mem.get<uint32_t>(ea));
  state_t::reg_t x =  s->gpr[rt];
  
  switch(ma)
    {
    case 0:
      s->gpr[rt] = sext64(r);
      break;
    case 1:
      s->gpr[rt] = sext64(((r & 0x00ffffff) << 8) | (x & 0x000000ff)) ;
      break;
    case 2:
      s->gpr[rt] = sext64(((r & 0x0000ffff) << 16)  | (x & 0x0000ffff)) ;
      break;
    case 3:
      s->gpr[rt] = sext64(((r & 0x00ffffff) << 24)  | (x & 0x00ffffff));
      break;
    }
#ifdef TRACE_MEM
  printf("_lwl from %x = %x\n", u_ea, s->gpr[rt]);
#endif  
  s->pc += 4;
  s->insn_histo[mipsInsn::LWL]++;  
}

template<bool EL>
void _lwr(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
 
  uint32_t ea = va_translate(s, (uint32_t)s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  uint32_t u_ea = ea;
  uint32_t ma = ea & 3;
  ea &= 0xfffffffc;
  if(EL)
    ma = 3-ma;

  uint32_t r = bswap<EL>(s->mem.get<uint32_t>(ea));
  state_t::reg_t x =  s->gpr[rt];
  
  switch(ma)
    {
    case 0:
      s->gpr[rt] = sext64((x & 0xffffff00) | (r>>24));
      break;
    case 1:
      s->gpr[rt] = sext64((x & 0xffff0000) | (r>>16));
      break;
    case 2:
      s->gpr[rt] = sext64((x & 0xff000000) | (r>>8));
      break;
    case 3:
      s->gpr[rt] = sext64(r);
      break;
    }

#ifdef TRACE_MEM
  printf("_lwr from %x = %x (x=%x, r = %x)\n", u_ea, s->gpr[rt], x, r);
#endif  
  
  s->pc += 4;
  s->insn_histo[mipsInsn::LWR]++;
}

template <bool EL>
void _ldl(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int32_t imm = (int32_t)(int16_t)(inst & 0xffff);
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  uint32_t ma = ea & 7;
  ea &= ~7u;
  if(EL) ma = 7 - ma;
  uint64_t r = bswap<EL>(s->mem.get<uint64_t>(ea));
  uint64_t x = s->gpr[rt];
  /* Load (8-ma) bytes from positions [ma..7] of aligned dword into rt[63:ma*8].
   * In BE: r[63:56]=pos0, r[7:0]=pos7.  Bytes [ma..7] = r[(8-ma)*8-1:0].
   * Shift them left by ma*8 to place at rt[63:ma*8]. */
  switch(ma) {
    case 0: s->gpr[rt] = r; break;
    case 1: s->gpr[rt] = (r & 0x00ffffffffffffffULL) << 8  | (x & 0xffULL); break;
    case 2: s->gpr[rt] = (r & 0x0000ffffffffffffULL) << 16 | (x & 0xffffULL); break;
    case 3: s->gpr[rt] = (r & 0x000000ffffffffffULL) << 24 | (x & 0xffffffULL); break;
    case 4: s->gpr[rt] = (r & 0x00000000ffffffffULL) << 32 | (x & 0xffffffffULL); break;
    case 5: s->gpr[rt] = (r & 0x0000000000ffffffULL) << 40 | (x & 0xffffffffffULL); break;
    case 6: s->gpr[rt] = (r & 0x000000000000ffffULL) << 48 | (x & 0xffffffffffffULL); break;
    case 7: s->gpr[rt] = (r & 0x00000000000000ffULL) << 56 | (x & 0x00ffffffffffffffULL); break;
  }
  s->pc += 4;
  s->insn_histo[mipsInsn::LDL]++;
}

template <bool EL>
void _ldr(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int32_t imm = (int32_t)(int16_t)(inst & 0xffff);
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  uint32_t ma = ea & 7;
  ea &= ~7u;
  if(EL) ma = 7 - ma;
  uint64_t r = bswap<EL>(s->mem.get<uint64_t>(ea));
  uint64_t x = s->gpr[rt];
  /* Load (ma+1) bytes from positions [0..ma] of aligned dword into rt[(ma+1)*8-1:0].
   * Bytes [0..ma] = r[63:63-ma*8].  Shift right by (7-ma)*8 to place at rt[(ma+1)*8-1:0]. */
  switch(ma) {
    case 0: s->gpr[rt] = (x & 0xffffffffffffff00ULL) | (r >> 56); break;
    case 1: s->gpr[rt] = (x & 0xffffffffffff0000ULL) | (r >> 48); break;
    case 2: s->gpr[rt] = (x & 0xffffffffff000000ULL) | (r >> 40); break;
    case 3: s->gpr[rt] = (x & 0xffffffff00000000ULL) | (r >> 32); break;
    case 4: s->gpr[rt] = (x & 0xffffff0000000000ULL) | (r >> 24); break;
    case 5: s->gpr[rt] = (x & 0xffff000000000000ULL) | (r >> 16); break;
    case 6: s->gpr[rt] = (x & 0xff00000000000000ULL) | (r >>  8); break;
    case 7: s->gpr[rt] = r; break;
  }
  s->pc += 4;
  s->insn_histo[mipsInsn::LDR]++;
}

template <bool EL>
void _sdl(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int32_t imm = (int32_t)(int16_t)(inst & 0xffff);
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  uint32_t ma = ea & 7;
  ea &= ~7u;
  if(EL) ma = 7 - ma;
  uint64_t r = bswap<EL>(s->mem.get<uint64_t>(ea));
  uint64_t x = s->gpr[rt];
  /* SDL: store x's high (8-ma) bytes at memory positions [ma..7];
   * preserve memory positions [0..ma-1].
   * xs = x >> (ma*8) places x[63:ma*8] at bits [63-ma*8:0].
   * m masks the top ma bytes to preserve from memory. */
  uint64_t xs = x >> (8 * ma);
  uint64_t m  = (ma == 0) ? 0ULL : (-(1ULL << (8 * (8 - ma))));
  uint64_t merged = (r & m) | xs;
  s->mem.set<uint64_t>(ea, bswap<EL>(merged));
  s->pc += 4;
  s->insn_histo[mipsInsn::SDL]++;
}

template <bool EL>
void _sdr(uint32_t inst, state_t *s) {
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int32_t imm = (int32_t)(int16_t)(inst & 0xffff);
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  uint32_t ma = ea & 7;
  ea &= ~7u;
  if(EL) ma = 7 - ma;
  uint64_t r = bswap<EL>(s->mem.get<uint64_t>(ea));
  uint64_t x = s->gpr[rt];
  /* SDR: store x's low (ma+1) bytes at memory positions [0..ma];
   * preserve memory positions [ma+1..7].
   * Shift x left by (7-ma)*8 to align x's low bytes to the high positions.
   * rm masks the low bytes to preserve from memory. */
  uint32_t xs_bits = 8 * (7 - ma);
  uint64_t rm = (xs_bits == 0) ? 0ULL : ((1ULL << xs_bits) - 1);
  uint64_t merged = (x << xs_bits) | (rm & r);
  s->mem.set<uint64_t>(ea, bswap<EL>(merged));
  s->pc += 4;
  s->insn_histo[mipsInsn::SDR]++;
}

static inline char* get_open_string(sparse_mem &mem, uint32_t offset) {
  size_t len = 0;
  char *ptr = reinterpret_cast<char*>(mem.get_raw_ptr(offset));
  char *buf = nullptr;
  while(*ptr != '\0') {
    ptr++;
    len++;
  }
  buf = new char[len+1];
  memset(buf, 0, len+1);
  ptr = reinterpret_cast<char*>(mem.get_raw_ptr(offset));
  for(size_t i = 0; i < len; i++) {
    buf[i] = *ptr;
    ptr++;
  }
  return buf;
}



template <bool EL>
void _ldc1(uint32_t inst, state_t *s) {
  uint32_t ft = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  /* FR=0: a doubleword load to an odd register is invalid -> RI (matches RTL). */
  if(((s->cpr0[CPR0_SR] & SR_FR) == 0) && (ft & 1)) { take_exception_ri(s); return; }
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  /* FR=1: the whole 64-bit register ft (no even/odd pair) */
  s->cpr1[ft] = bswap<EL>(s->mem.get<uint64_t>(ea));
  s->pc += 4;
  s->insn_histo[mipsInsn::LDC1]++;
}

template <bool EL>
void _sdc1(uint32_t inst, state_t *s) {
  uint32_t ft = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  /* FR=0: a doubleword store from an odd register is invalid -> RI (matches RTL). */
  if(((s->cpr0[CPR0_SR] & SR_FR) == 0) && (ft & 1)) { take_exception_ri(s); return; }
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  s->mem.set<uint64_t>(ea, bswap<EL>(s->cpr1[ft]));
  s->pc += 4;
  s->insn_histo[mipsInsn::SDC1]++;
}

template <bool EL>
void _lwc1(uint32_t inst, state_t *s) {
  uint32_t ft = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::load); if(s->tlb_fault) return;
  uint32_t v = bswap<EL>(s->mem.get<uint32_t>(ea));
  if((s->cpr0[CPR0_SR] & SR_FR) == 0) {
    /* FR=0: merge the loaded word into the ft[0]-selected half of the even reg,
     * preserving the other half (R10000 UM p.305). */
    uint64_t old = s->cpr1[ft & ~1u];
    s->cpr1[ft & ~1u] = (ft & 1) ? ((old & 0xffffffffull) | ((uint64_t)v << 32))
                                 : ((old & 0xffffffff00000000ull) | v);
  } else {
    /* FR=1: load the word into bits[31:0]; RTL's MEM_LW sign-extends to 64b */
    s->cpr1[ft] = (uint64_t)(int64_t)(int32_t)v;
  }
  s->pc += 4;
  s->insn_histo[mipsInsn::LWC1]++;
}

template <bool EL>
void _swc1(uint32_t inst, state_t *s) {
  uint32_t ft = (inst >> 16) & 31;
  uint32_t rs = (inst >> 21) & 31;
  int16_t himm = (int16_t)(inst & ((1<<16) - 1));
  int32_t imm = (int32_t)himm;
  uint32_t ea = va_translate(s, s->gpr[rs] + imm, tlb_op::store); if(s->tlb_fault) return;
  /* FR=1 / FR=0-even: low 32; FR=0-odd: high 32 of the even reg. */
  uint64_t rv = s->cpr1[((s->cpr0[CPR0_SR] & SR_FR) == 0) ? (ft & ~1u) : ft];
  uint32_t v = (((s->cpr0[CPR0_SR] & SR_FR) == 0) && (ft & 1)) ? (uint32_t)(rv >> 32)
                                                               : (uint32_t)rv;
  s->mem.set<uint32_t>(ea, bswap<EL>(v));
  s->pc += 4;
  s->insn_histo[mipsInsn::SWC1]++;
}

static void _truncl(uint32_t inst, state_t *s) {
  printf("%s\n",__func__);
  exit(-1);
}

static void _truncw(uint32_t inst, state_t *s) {
  uint32_t fmt = (inst >> 21) & 31;
  uint32_t fd = (inst>>6) & 31;
  uint32_t fs = (inst>>11) & 31;
  float f;
  double d;
  int32_t *ptr = ((int32_t*)(s->cpr1 + fd));   /* result word -> FPR[fd][31:0] (FR=1) */
  switch(fmt)
    {
    case FMT_S:
      f = (*((float*)(s->cpr1 + fs)));
      //printf("f=%g\n", f);
      *ptr = (int32_t)f;
      s->insn_histo[mipsInsn::TRUNC_SP_W]++;
      break;
    case FMT_D:
      d = (*((double*)(s->cpr1 + fs)));
      *ptr = (int32_t)d;
      s->insn_histo[mipsInsn::TRUNC_DP_W]++;
      //printf("id=%d\n", *ptr);
      break;
    default:
      printf("unknown trunc for fmt %d\n", fmt);
      exit(-1);
      break;
    }
  s->pc += 4;
}

/* float -> int32 with selectable rounding: ROUND.W(RN)/CEIL.W(RP)/FLOOR.W(RM)/
 * CVT.W(FCSR.RM).  rm: 0=RN(half-even) 1=RZ 2=RP 3=RM.  Result -> FPR[fd][31:0]. */
static void _cvtw_rm(uint32_t inst, state_t *s, int rm) {
  uint32_t fmt = (inst >> 21) & 31;
  uint32_t fd = (inst>>6) & 31, fs = (inst>>11) & 31;
  double d = (fmt == FMT_S) ? (double)(*((float*)(s->cpr1 + fs)))
                            : (*((double*)(s->cpr1 + fs)));
  double r;
  switch(rm) {
    case 0:  r = std::nearbyint(d); break;   /* RN (host fenv default = round-half-even) */
    case 1:  r = std::trunc(d);     break;   /* RZ */
    case 2:  r = std::ceil(d);      break;   /* RP */
    default: r = std::floor(d);     break;   /* RM */
  }
  *((int32_t*)(s->cpr1 + fd)) = (int32_t)r;
  s->pc += 4;
}

/* float -> int64 with selectable rounding (ROUND/TRUNC/CEIL/FLOOR.L / CVT.L).
 * rm: 0=RN 1=RZ 2=RP 3=RM.  Result -> full 64-bit FPR[fd]. */
static void _cvtl_rm(uint32_t inst, state_t *s, int rm) {
  uint32_t fmt = (inst >> 21) & 31;
  uint32_t fd = (inst>>6) & 31, fs = (inst>>11) & 31;
  double d = (fmt == FMT_S) ? (double)(*((float*)(s->cpr1 + fs)))
                            : (*((double*)(s->cpr1 + fs)));
  double r;
  switch(rm) {
    case 0:  r = std::nearbyint(d); break;
    case 1:  r = std::trunc(d);     break;
    case 2:  r = std::ceil(d);      break;
    default: r = std::floor(d);     break;
  }
  *((int64_t*)(s->cpr1 + fd)) = (int64_t)r;
  s->pc += 4;
}

static void _movnd(uint32_t inst, state_t *s) {
  uint32_t fd = (inst>>6) & 31;
  uint32_t fs = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;
  bool notZero = (s->gpr[rt] != 0);
  s->cpr1[fd] = notZero ? s->cpr1[fs] : s->cpr1[fd];
  s->pc += 4;
}

static void _movns(uint32_t inst, state_t *s) {
  uint32_t fd = (inst>>6) & 31;
  uint32_t fs = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;
  bool notZero = (s->gpr[rt] != 0);
  s->cpr1[fd+0] = notZero ? s->cpr1[fs+0] : s->cpr1[fd+0];
  s->pc += 4;
}

static void _movzd(uint32_t inst, state_t *s) {
  uint32_t fd = (inst>>6) & 31;
  uint32_t fs = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;
 
  s->cpr1[fd] = (s->gpr[rt] == 0) ? s->cpr1[fs] : s->cpr1[fd];
  s->pc += 4;
}

static void _movzs(uint32_t inst, state_t *s) {
  uint32_t fd = (inst>>6) & 31;
  uint32_t fs = (inst>>11) & 31;
  uint32_t rt = (inst>>16) & 31;

  s->cpr1[fd+0] = (s->gpr[rt] == 0) ? s->cpr1[fs+0] : s->cpr1[fd+0];
  s->pc += 4;
}

static void _movcd(uint32_t inst, state_t *s) {
  uint32_t cc = (inst >> 18) & 7;
  uint32_t fd = (inst>>6) & 31;
  uint32_t fs = (inst>>11) & 31;
  uint32_t tf = (inst>>16) & 1;

  if(tf==0) {
    if(getConditionCode(s,cc)==0) {
      s->cpr1[fd] = s->cpr1[fs];
    }
    s->insn_histo[mipsInsn::FP_MOVF];
  }
  else {
    if(getConditionCode(s,cc)==1) {
      s->cpr1[fd] = s->cpr1[fs];
    }
    s->insn_histo[mipsInsn::FP_MOVT];
  }
  s->pc += 4;
}

static void _movcs(uint32_t inst, state_t *s) {
  uint32_t cc = (inst >> 18) & 7;
  uint32_t fd = (inst>>6) & 31;
  uint32_t fs = (inst>>11) & 31;
  uint32_t tf = (inst>>16) & 1;
  if(tf==0) {
    s->cpr1[fd+0] = getConditionCode(s, cc) ? s->cpr1[fd+0] : s->cpr1[fs+0];
    s->insn_histo[mipsInsn::FP_MOVF];
  }
  else {
    s->cpr1[fd+0] = getConditionCode(s, cc) ? s->cpr1[fs+0] : s->cpr1[fd+0];
    s->insn_histo[mipsInsn::FP_MOVT];
  }
  s->pc += 4;
}


static void _movci(uint32_t inst, state_t *s) {
  uint32_t cc = (inst >> 18) & 7;
  uint32_t tf = (inst>>16) & 1;
  uint32_t rd = (inst>>11) & 31;
  uint32_t rs = (inst >> 21) & 31;
  if(tf==0) {
    /* movf */
    s->gpr[rd] = getConditionCode(s, cc) ? s->gpr[rd] : s->gpr[rs];
    s->insn_histo[mipsInsn::MOVF]++;
  }
  else {
    /* movt */
    s->gpr[rd] = getConditionCode(s, cc) ? s->gpr[rs] : s->gpr[rd];
    s->insn_histo[mipsInsn::MOVT]++;    
  }
  s->pc += 4;
}

static void _cvts(uint32_t inst, state_t *s) {
  uint32_t fmt = (inst >> 21) & 31;
  uint32_t fd = (inst>>6) & 31;
  uint32_t fs = (inst>>11) & 31;
  switch(fmt)
    {
    case FMT_D:
      *((float*)(s->cpr1 + fd)) = (float)(*((double*)(s->cpr1 + fs)));
      s->cpr1_state[fd] = fp_reg_state::sp;
      break;
    case FMT_W:
      *((float*)(s->cpr1 + fd)) = (float)(*((int32_t*)(s->cpr1 + fs)));
      break;
    case FMT_L:
      *((float*)(s->cpr1 + fd)) = (float)(*((int64_t*)(s->cpr1 + fs)));
      break;
    default:
      printf("%s @ %d\n", __func__, __LINE__);
      exit(-1);
      break;
    }
  s->pc += 4;
}

static void _cvtd(uint32_t inst, state_t *s) {
  uint32_t fmt = (inst >> 21) & 31;
  uint32_t fd = (inst>>6) & 31;
  uint32_t fs = (inst>>11) & 31;
  switch(fmt)
    {
    case FMT_S:
      *((double*)(s->cpr1 + fd)) = (double)(*((float*)(s->cpr1 + fs)));
      s->cpr1_state[fd] = fp_reg_state::dp;
      break;
    case FMT_W:
     *((double*)(s->cpr1 + fd)) = (double)(*((int32_t*)(s->cpr1 + fs)));
      break;
    case FMT_L:
      *((double*)(s->cpr1 + fd)) = (double)(*((int64_t*)(s->cpr1 + fs)));
      break;
    default:
      printf("%s @ %d\n", __func__, __LINE__);
      exit(-1);
      break;
    }
  s->pc += 4;
}

static void _fmovn(uint32_t inst, state_t *s) {
  uint32_t fmt = (inst >> 21) & 31;
  switch(fmt)
    {
    case FMT_S:
      _movns(inst, s);
      break;
    case FMT_D:
      _movnd(inst, s);
      break;
    default:
      printf("unsupported %s\n", __func__);
      exit(-1);
      break;
    }
}


static void _fmovz(uint32_t inst, state_t *s) {
  uint32_t fmt = (inst >> 21) & 31;
  switch(fmt)
    {
    case FMT_S:
      _movzs(inst, s);
      break;
    case FMT_D:
      _movzd(inst, s);
      break;
    default:
      printf("unsupported %s\n", __func__);
      exit(-1);
      break;
    }
}

static void _fmovc(uint32_t inst, state_t *s) {
  uint32_t fmt = (inst >> 21) & 31;
  switch(fmt)
    {
    case FMT_S:
      _movcs(inst, s);
      break;
    case FMT_D:
      _movcd(inst, s);
      break;
    default:
      printf("unsupported %s\n", __func__);
      exit(-1);
      break;
    }
}



template <typename T>
static void fpCmp(uint32_t inst, state_t *s) {
  uint32_t cond = inst & 15;
  uint32_t cc = (inst >> 8) & 7;
  uint32_t ft = (inst >> 16) & 31;
  uint32_t fs = (inst >> 11) & 31;
  T Tfs = *((T*)(s->cpr1+fs));
  T Tft = *((T*)(s->cpr1+ft));
  uint32_t v = 0;

  /* All 16 C.cond predicates: result = less&cond[2] | equal&cond[1] |
   * unordered&cond[0].  (C++ NaN comparisons are false, so lt/eq are 0 when
   * unordered.)  cond[3]=signaling only affects the Invalid flag, which this
   * checker does not model. */
  {
    bool un = std::isnan(Tfs) || std::isnan(Tft);
    bool lt = (Tfs <  Tft);
    bool eq = (Tfs == Tft);
    v = (((cond & 4) && lt) || ((cond & 2) && eq) || ((cond & 1) && un)) ? 1u : 0u;
    s->fcr1[CP1_CR25] = setBit(s->fcr1[CP1_CR25],v,cc);
  }
  if(globals::trace_retirement) {
    std::cout << std::hex
	      << s->pc
	      << std::dec
	      << " c. "
	      << Tfs
	      << " "
	      << getCondName(cond)
	      << " "
	      << Tft
	      << " = "
	      << v
	      << "\n";
  }
  
  s->pc += 4;
}

static void _c(uint32_t inst, state_t *s) {
  uint32_t fmt = (inst >> 21) & 31;
  switch(fmt)
    {
    case FMT_S:
      fpCmp<float>(inst,s);
      break;
    case FMT_D:
      fpCmp<double>(inst,s);
      break;
    default:
      printf("unsupported comparison\n");
      exit(-1);
      break;
    }
}

template< typename T, fpOperation op>
static void execFP(uint32_t inst, state_t *s) {
  uint32_t ft = (inst>>16)&31, fs=(inst>>11)&31, fd=(inst>>6)&31;
  T _fs = *reinterpret_cast<T*>(s->cpr1+fs);
  T _ft = *reinterpret_cast<T*>(s->cpr1+ft);
  T &_fd = *reinterpret_cast<T*>(s->cpr1+fd);

  switch(op)
    {
    case fpOperation::abs:
      _fd = std::abs(_fs);
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_ABS, mipsInsn::SP_ABS)]++;      
      break;
    case fpOperation::neg:
      _fd = -_fs;
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_NEG, mipsInsn::SP_NEG)]++;
      break;
    case fpOperation::mov:
      _fd = _fs;
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_MOV, mipsInsn::SP_MOV)]++;            
      break;
    case fpOperation::add:
      _fd = _fs + _ft;
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_ADD, mipsInsn::SP_ADD)]++;            
      break;
    case fpOperation::sub:
      _fd = _fs - _ft;
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_SUB, mipsInsn::SP_SUB)]++;                  
      break;
    case fpOperation::mul:
      _fd = _fs * _ft;
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_MUL, mipsInsn::SP_MUL)]++;      
      break;
    case fpOperation::div:
      if(_ft==0.0) {
	_fd = std::numeric_limits<T>::max();
      }
      else {
	_fd = _fs / _ft;
      }
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_DIV, mipsInsn::SP_DIV)]++;       
      break;
    case fpOperation::sqrt:
      _fd = std::sqrt(_fs);
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_SQRT, mipsInsn::SP_SQRT)]++;      
      break;
    case fpOperation::rsqrt:
      _fd = static_cast<T>(1.0) / std::sqrt(_fs);
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_RSQRT, mipsInsn::SP_RSQRT)]++;
      break;
    case fpOperation::recip:
      _fd = static_cast<T>(1.0) / _fs;
      s->insn_histo[select_fp_insn<T>(mipsInsn::DP_RECIP, mipsInsn::SP_RECIP)]++;
      break;
    default:
      UNREACHABLE();
    }
  s->pc+=4;
}

template <fpOperation op>
void do_fp_op(uint32_t inst, state_t *s) {
  int fd=(inst>>6)&31;
  switch((inst>>21)&31) {
  case FMT_S:
    execFP<float,op>(inst,s);
    s->cpr1_state[fd] = fp_reg_state::sp;
    break;
  case FMT_D:
    execFP<double,op>(inst,s);
    s->cpr1_state[fd] = fp_reg_state::dp;
    break;
  default:
    UNREACHABLE();
  }
}


template <bool EL>
static void execCoproc1(uint32_t inst, state_t *s) {
  uint32_t opcode = inst>>26;
  uint32_t functField = (inst>>21) & 31;
  uint32_t lowop = inst & 63;  
  uint32_t fmt = (inst >> 21) & 31;
  uint32_t nd_tf = (inst>>16) & 3;
  
  uint32_t lowbits = inst & ((1<<11)-1);
  opcode &= 0x3;

  if(fmt == 0x8)
    {
      switch(nd_tf)
	{
	case 0x0:
	  branch<EL,branch_type::bc1f>(inst, s);
	  break;
	case 0x1:
	  branch<EL,branch_type::bc1t>(inst, s);
	  break;
	case 0x2:
	  branch<EL,branch_type::bc1fl>(inst, s);
	  break;
	case 0x3:
	  branch<EL,branch_type::bc1tl>(inst, s);
	  break;
	}
      /*BRANCH*/
    }
  else if((lowbits == 0) && ((functField==0x0) || (functField==0x4) ||
			     (functField==0x2) || (functField==0x6) ||
			     (functField==0x1) || (functField==0x5)))
    {
      if(functField == 0x0)
	{
	  /* move from coprocessor */
	  _mfc1(inst,s);
	}
      else if(functField == 0x4)
	{
	  /* move to coprocessor */
	  _mtc1(inst,s);
	}
      else if(functField == 0x1)
	{
	  /* doubleword move from coprocessor (dmfc1) */
	  _dmfc1(inst,s);
	}
      else if(functField == 0x5)
	{
	  /* doubleword move to coprocessor (dmtc1) */
	  _dmtc1(inst,s);
	}
      else if(functField == 0x2)
	{
	  /* move from control coprocessor (cfc1) */
	  _cfc1(inst,s);
	}
      else if(functField == 0x6)
	{
	  /* move to control coprocessor (ctc1) */
	  _ctc1(inst,s);
	}
    }
  else
    {
      /* FR=0 odd-register FP-compute -> Reserved Instruction, matching the RTL
       * decode gate (decode_mips.sv).  MIPS is underspecified here (UNPREDICTABLE,
       * no mandated exception; Sail doesn't model FR) -- we choose loud RI over the
       * R10000's silent force-to-even.  Covers arith/cvt/abs/neg/mov + compare;
       * moves/cfc1/ctc1 are handled above and are FR-half ops, not faulted. */
      if(((s->cpr0[CPR0_SR] & SR_FR) == 0) &&
	 ((((inst >> 11) | (inst >> 16) | (inst >> 6)) & 1u) != 0u))
	{
	  take_exception_ri(s);
	  return;
	}
      if((lowop >> 4) == 3)
	{
	  _c(inst, s);
	}
      else{
	switch(lowop)
	  {
	  case 0x0:
	    do_fp_op<fpOperation::add>(inst, s);
	    break;
	  case 0x1:
	    do_fp_op<fpOperation::sub>(inst, s);
	    break;
	  case 0x2:
	    do_fp_op<fpOperation::mul>(inst, s);
	    break;
	  case 0x3:
	    do_fp_op<fpOperation::div>(inst, s);
	    break;
	  case 0x4:
	    do_fp_op<fpOperation::sqrt>(inst, s);
	    break;
	  case 0x5:
	    do_fp_op<fpOperation::abs>(inst, s);
	    break;
	  case 0x6:
	    do_fp_op<fpOperation::mov>(inst, s);
	    break;
	  case 0x7:
	    do_fp_op<fpOperation::neg>(inst, s);
	    break;
	  case 0x8:
	    _cvtl_rm(inst, s, 0);   /* ROUND.L -> RN */
	    break;
	  case 0xa:
	    _cvtl_rm(inst, s, 2);   /* CEIL.L -> RP */
	    break;
	  case 0xb:
	    _cvtl_rm(inst, s, 3);   /* FLOOR.L -> RM */
	    break;
	  case 0x25:
	    _cvtl_rm(inst, s, (int)(s->fcr1[CP1_CR31] & 3));   /* CVT.L -> FCSR.RM */
	    break;
	  case 0x9:
	    _cvtl_rm(inst, s, 1);   /* TRUNC.L -> RZ */
	    break;
	  case 0xc:
	    _cvtw_rm(inst, s, 0);   /* ROUND.W -> RN */
	    break;
	  case 0xe:
	    _cvtw_rm(inst, s, 2);   /* CEIL.W -> RP */
	    break;
	  case 0xf:
	    _cvtw_rm(inst, s, 3);   /* FLOOR.W -> RM */
	    break;
	  case 0x24:
	    _cvtw_rm(inst, s, (int)(s->fcr1[CP1_CR31] & 3));   /* CVT.W -> FCSR.RM */
	    break;
	  case 0xd:
	    _truncw(inst, s);
	    break;
	  case 0x11:
	    _fmovc(inst, s);
	    break;
	  case 0x12:
	    _fmovz(inst, s);
	    break;
	  case 0x13:
	    _fmovn(inst, s);
	    break;
	  case 0x15:
	    do_fp_op<fpOperation::recip>(inst, s);
	    break;
	  case 0x16:
	    do_fp_op<fpOperation::rsqrt>(inst, s);
	    break;
	  case 0x20:
	    /* cvt.s */
	    _cvts(inst, s);
	    break;
	  case 0x21:
	    _cvtd(inst, s);
	    break;
	  default:
	    /* any COP1 op not implemented -> Unimplemented (E) FPE, matching the RTL
	     * FP_UNIMPL catch-all (OS soft-float emulates). */
	    take_exception_fpe(s);
	    return;
	  }
      }
    }
}

template <bool EL>
bool is_store_insn(state_t *s) {
  sparse_mem &mem = s->mem;
  uint32_t inst = bswap<EL>(mem.get<uint32_t>(va2pa(s->pc)));
  uint32_t opcode = inst>>26;
  switch(opcode)
    {
    case 0x28: //_sb(inst, s); 
    case 0x29: //_sh<EL>(inst, s); 
    case 0x2a: //_swl<EL>(inst, s); 
    case 0x2B: //_sw<EL>(inst, s); 
    case 0x2e: //_swr<EL>(inst, s);
    case 0x39: //_swc1<EL>(inst, s);
    case 0x38: //_sc
    case 0x3D: //_sdc1<EL>(inst, s);
      return true;
    default:
      break;
    }
  return false;
}


bool is_store_insn(state_t *s) {
  return is_store_insn<false>(s);
}


template <bool EL>
void execMips(state_t *s) {
  sparse_mem &mem = s->mem;
  s->gpr[0] = 0;   /* MIPS $0 is hardwired to zero; e.g. `mflo $0` must not stick */
  s->tlb_fault = false;   /* fresh each instruction; set by va_translate on a TLB fault */
  uint32_t ipa = va_translate(s, (uint64_t)s->pc, tlb_op::fetch);
  if(s->tlb_fault) return;   /* instruction-fetch TLB miss -> already vectored */
  uint32_t inst = bswap<EL>(mem.get<uint32_t>(ipa));
  if(globals::trace_retirement and false) {
    std::cout << std::hex
	      << "cosim "
	      << s->pc << ","
	      << std::dec << " : "
	      << getAsmString(inst, s->pc) << "\n";
  }
  //std::cout << std::hex << s->pc << std::dec << " : "
  //<< getAsmString(inst, s->pc) << "\n";
  uint32_t opcode = inst>>26;
  bool isRType = (opcode==0);
  bool isJType = ((opcode>>1)==1);
  bool isCoproc0 = (opcode == 0x10);
  bool isCoproc1 = (opcode == 0x11);
  bool isCoproc1x = (opcode == 0x13);
  bool isCoproc2 = (opcode == 0x12);
  bool isSpecial2 = (opcode == 0x1c); 
  bool isSpecial3 = (opcode == 0x1f);
  bool isLoadLinked = (opcode == 0x30) || (opcode == 0x34);
  bool isStoreCond = (opcode == 0x38) || (opcode == 0x3c);
  uint32_t rs = (inst >> 21) & 31;
  uint32_t rt = (inst >> 16) & 31;
  uint32_t rd = (inst >> 11) & 31;
  s->icnt++;

  /* 64-bit ops raise Reserved Instruction when not in 64-bit mode (matches the
   * RTL decode_mips.sv gate; the random instruction tests rely on this). */
  if(is_64b_gated(inst) && !in_64b_mode(s)) {
    take_exception_ri(s);
    return;
  }

  /* LL/SC link clearing on an intervening access (model in interpret.hh; the mem
   * pipe is in-order so doing this at dispatch is in program order). */
  {
    bool is_mem_store =
      (opcode >= 0x28 && opcode <= 0x2e) ||   /* sb sh swl sw sdl sdr swr */
      opcode == 0x3f ||                        /* sd   */
      opcode == 0x39 || opcode == 0x3d;        /* swc1, sdc1 */
#ifdef LLSC_BREAK_ON_LOAD
    /* R10000 (p.27): ANY normal load or store breaks the link. */
    bool is_mem_load =
      (opcode >= 0x20 && opcode <= 0x27) ||   /* lb lh lwl lw lbu lhu lwr lwu */
      opcode == 0x1a || opcode == 0x1b ||     /* ldl, ldr */
      opcode == 0x37 ||                        /* ld   */
      opcode == 0x31 || opcode == 0x35;        /* lwc1, ldc1 */
    if(is_mem_load || is_mem_store) s->ll_link_valid = false;
#else
    /* BERI/CHERI (default): only a STORE to the linked cache line breaks it. */
    if(is_mem_store && s->ll_link_valid) {
      int32_t simm = (int32_t)(int16_t)(inst & 0xffffu);
      uint32_t spa2 = 0;   /* non-faulting: the store handler does the real va_translate */
      if(!tlb_probe_ro(s, s->gpr[rs] + simm, &spa2)) spa2 = va2pa(s->gpr[rs] + simm);
      uint64_t sline = (uint64_t)spa2 & ~UINT64_C(0xf);
      if(sline == s->ll_link_addr) s->ll_link_valid = false;
    }
#endif
  }

#ifdef STORE_CHECK
  /* record committed ISS integer stores in program order for the henry_tb store-check.
   * Captured at dispatch (source regs are ready; the store itself runs below). */
  {
    /* aligned single-write stores only (sb/sh/sw/sd) -- each fires the RTL's
     * t_wr_array exactly once, so the two FIFOs stay aligned.  The UNALIGNED
     * swl/swr/sdl/sdr are excluded (they can fire multiple array-writes/insn). */
    int store_sz = (opcode == 0x28) ? 1 : (opcode == 0x29) ? 2 :
                   (opcode == 0x2b) ? 4 : (opcode == 0x3f) ? 8 : 0;
    if(store_sz) {
      int32_t simm_sc = (int32_t)(int16_t)(inst & 0xffffu);
      uint64_t sva = s->gpr[rs] + simm_sc;
      uint32_t spa = 0;                                  /* REAL PA via the ported TLB probe */
      /* only record stores that translate cleanly -- a store that will TLB-fault
       * writes nothing (the RTL faults too), so pushing it would drift the FIFO. */
      if(tlb_probe_ro(s, sva, &spa)) {
        uint32_t srt = (inst >> 16) & 31;
        uint64_t sdata = s->gpr[srt];
        if(store_sz < 8) sdata &= (UINT64_C(1) << (store_sz * 8)) - 1;  /* mask to store size */
        g_iss_stores.emplace_back((uint64_t)s->pc, spa, sdata);
      }
    }
  }
#endif

  if(isRType) {
    uint32_t funct = inst & 63;
    uint32_t sa = (inst >> 6) & 31;
    switch(funct) 
      {
      case 0x00: /*sll*/
	s->gpr[rd] = static_cast<int32_t>(s->gpr[rt]) << sa;
	s->pc += 4;
	if(inst == 0) {
	  s->insn_histo[mipsInsn::NOP]++;
	}
	else {
	  s->insn_histo[mipsInsn::SLL]++;
	}
	break;
      case 0x01: /* movci */
	_movci(inst,s);
	break;
      case 0x02: /* srl */
	s->gpr[rd] = sext64(((uint32_t)s->gpr[rt] >> sa));
	s->pc += 4;
	s->insn_histo[mipsInsn::SRL]++;
	break;
      case 0x03: /* sra */
	s->gpr[rd] = static_cast<int32_t>(s->gpr[rt]) >> sa;
	s->pc += 4;
	s->insn_histo[mipsInsn::SRA]++;
	break;	
      case 0x04: /* sllv */
	s->gpr[rd] = sext64(static_cast<uint32_t>(s->gpr[rt]) << (s->gpr[rs] & 0x1f));
	s->pc += 4;
	s->insn_histo[mipsInsn::SLLV]++;
	break;
      case 0x06:  /* srlv: sign-extend the 32-bit logical-shift result (MIPS64) */
	s->gpr[rd] = sext64((uint32_t)s->gpr[rt] >> (s->gpr[rs] & 0x1f));
	s->pc += 4;
	s->insn_histo[mipsInsn::SRLV]++;
	break;
      case 0x07:  /* srav: 32-bit arithmetic shift, result sign-extended (MIPS64) */
	s->gpr[rd] = static_cast<int32_t>(s->gpr[rt]) >> (s->gpr[rs] & 0x1f);
	s->pc += 4;
	s->insn_histo[mipsInsn::SRAV]++;
	break;
      case 0x08: { /* jr */
	state_t::reg_t jaddr = s->gpr[rs];
	s->pc += 4;
	if(!run_delay_slot<EL>(s))
	  s->pc = jaddr;
	s->insn_histo[mipsInsn::JR]++;
	break;
      }
      case 0x09: { /* jalr */
	state_t::reg_t jaddr = s->gpr[rs];
	s->gpr[31] = s->pc + 8;   /* full 64-bit link (match RTL int_uop.pc+8; no 32b trunc) */
	s->pc += 4;
	if(!run_delay_slot<EL>(s))
	  s->pc = jaddr;
	s->insn_histo[mipsInsn::JALR]++;
	break;
      }
      case 0x0C: /* syscall */
      case 0x0D: /* break */
	s->brk = 1;
	s->pc += 4;    /* advance so the checker stays in sync */
	if(!s->silent) {
	  std::cout << "got break or syscall\n";
	}
	s->insn_histo[mipsInsn::BREAK]++;
	break;
      case 0x0f: /* sync */
	s->pc += 4;
	s->insn_histo[mipsInsn::SYNC]++;
	break;
      case 0x10: /* mfhi */
	s->gpr[rd] = s->hi;
	s->pc += 4;
	s->insn_histo[mipsInsn::MFHI]++;
	break;
      case 0x11: /* mthi */ 
	s->hi = s->gpr[rs];
	s->pc += 4;
	s->insn_histo[mipsInsn::MTHI]++;
	break;
      case 0x12: /* mflo */
	s->gpr[rd] = s->lo;
	s->pc += 4;
	s->insn_histo[mipsInsn::MFLO]++;	
	break;
      case 0x13: /* mtlo */
	s->lo = s->gpr[rs];
	s->pc += 4;
	s->insn_histo[mipsInsn::MTLO]++;		
	break;
      case 0x18: { /* mult: 32x32 signed (operands are the low 32 bits) */
	int64_t y;
	y = (int64_t)(int32_t)s->gpr[rs] * (int64_t)(int32_t)s->gpr[rt];
	s->lo = (int32_t)(y & 0xffffffff);
	s->hi = (int32_t)(y >> 32);
	s->pc += 4;
	s->insn_histo[mipsInsn::MULT]++;			
	break;
      }
      case 0x19: { /* multu */
	uint64_t y;
	uint64_t u0 = (uint64_t)(uint32_t)s->gpr[rs];
	uint64_t u1 = (uint64_t)(uint32_t)s->gpr[rt];
	y = u0*u1;
	s->lo = sext64((uint32_t)y);
	s->hi = sext64((uint32_t)(y>>32));
	s->pc += 4;
	s->insn_histo[mipsInsn::MULTU]++;
	break;
      }
      case 0x1A: /* div: 32-bit signed, sign-extended (int64 avoids INT_MIN/-1 UB) */
	if((int32_t)s->gpr[rt] != 0) {
	  int64_t a = (int32_t)s->gpr[rs], b = (int32_t)s->gpr[rt];
	  s->lo = sext64((uint32_t)(int32_t)(a / b));
	  s->hi = sext64((uint32_t)(int32_t)(a % b));
	}
	s->pc += 4;
	s->insn_histo[mipsInsn::DIV]++;
	break;
      case 0x1B: /* divu */
	if(s->gpr[rt] != 0) {
	  s->lo = sext64((uint32_t)s->gpr[rs] / (uint32_t)s->gpr[rt]);
	  s->hi = sext64((uint32_t)s->gpr[rs] % (uint32_t)s->gpr[rt]);
	}
	s->pc += 4;
	s->insn_histo[mipsInsn::DIVU]++;
	break;
      case 0x1C: { /* dmult: signed 64x64 -> 128, hi:lo */
	__int128 y = (__int128)s->gpr[rs] * (__int128)s->gpr[rt];
	s->lo = (int64_t)(y & 0xffffffffffffffffULL);
	s->hi = (int64_t)(y >> 64);
	s->pc += 4;
	s->insn_histo[mipsInsn::DMULT]++;
	break;
      }
      case 0x1D: { /* dmultu: unsigned 64x64 -> 128, hi:lo */
	unsigned __int128 y = (unsigned __int128)(uint64_t)s->gpr[rs]
	                    * (unsigned __int128)(uint64_t)s->gpr[rt];
	s->lo = (int64_t)(y & 0xffffffffffffffffULL);
	s->hi = (int64_t)(uint64_t)(y >> 64);
	s->pc += 4;
	s->insn_histo[mipsInsn::DMULTU]++;
	break;
      }
      case 0x1E: /* ddiv: signed 64-bit divide */
	if(s->gpr[rt] != 0) {
	  s->lo = s->gpr[rs] / s->gpr[rt];
	  s->hi = s->gpr[rs] % s->gpr[rt];
	}
	s->pc += 4;
	s->insn_histo[mipsInsn::DDIV]++;
	break;
      case 0x1F: /* ddivu: unsigned 64-bit divide */
	if(s->gpr[rt] != 0) {
	  s->lo = (int64_t)((uint64_t)s->gpr[rs] / (uint64_t)s->gpr[rt]);
	  s->hi = (int64_t)((uint64_t)s->gpr[rs] % (uint64_t)s->gpr[rt]);
	}
	s->pc += 4;
	s->insn_histo[mipsInsn::DDIVU]++;
	break;
      case 0x20: { /* add */
	uint32_t u_rs = (uint32_t)s->gpr[rs];
	uint32_t u_rt = (uint32_t)s->gpr[rt];
	uint32_t result = u_rs + u_rt;
	/* Overflow iff same-sign inputs produce different-sign result.
	 * Matches RTL: w_add32_overflow = (result[31]!=rt[31]) & (rs[31]==rt[31]) */
	if (((result >> 31) != (u_rt >> 31)) && ((u_rs >> 31) == (u_rt >> 31))) {
	  raise_overflow(s);
	  break;
	}
	s->gpr[rd] = sext64(result);
	s->pc += 4;
	s->insn_histo[mipsInsn::ADD]++;
	break;
      }
      case 0x21: { /* addu */
	uint32_t u_rs = (uint32_t)s->gpr[rs];
	uint32_t u_rt = (uint32_t)s->gpr[rt];
	s->gpr[rd] = sext64(u_rs + u_rt);
	s->pc += 4;
	s->insn_histo[mipsInsn::ADDU]++;
	break;
      }
      case 0x22: { /* sub */
	uint32_t u_rs = (uint32_t)s->gpr[rs];
	uint32_t u_rt = (uint32_t)s->gpr[rt];
	uint32_t result = u_rs - u_rt;
	/* A-B overflows iff operands differ in sign AND result sign != rs (minuend).
	 * Matches RTL: w_sub32_overflow = (result[31]!=rs[31]) & (rs[31]!=rt[31]) */
	if (((result >> 31) != (u_rs >> 31)) && ((u_rs >> 31) != (u_rt >> 31))) {
	  raise_overflow(s);
	  break;
	}
	s->gpr[rd] = sext64(result);
	s->pc += 4;
	s->insn_histo[mipsInsn::SUB]++;
	break;
      }
      case 0x23:{ /*subu*/  
	uint32_t u_rs = (uint32_t)s->gpr[rs];
	uint32_t u_rt = (uint32_t)s->gpr[rt];
	uint32_t y = u_rs - u_rt;
	s->gpr[rd] = sext64(y);
	s->pc += 4;
	s->insn_histo[mipsInsn::SUBU]++;
	break;
      }
      case 0x24: /* and */
	s->gpr[rd] = s->gpr[rs] & s->gpr[rt];
	s->pc += 4;
	s->insn_histo[mipsInsn::AND]++;
	break;
      case 0x25: /* or */
	if(rd != 0) {
	  s->gpr[rd] = s->gpr[rs] | s->gpr[rt];
	}
	s->pc += 4;
	s->insn_histo[mipsInsn::OR]++;
	break;
      case 0x26: /* xor */
	s->gpr[rd] = s->gpr[rs] ^ s->gpr[rt];
	s->pc += 4;
	s->insn_histo[mipsInsn::XOR]++;	
	break;
      case 0x27: /* nor */
	s->gpr[rd] = ~(s->gpr[rs] | s->gpr[rt]);
	s->pc += 4;
	s->insn_histo[mipsInsn::NOR]++;
	break;
      case 0x2A: /* slt */
	s->gpr[rd] = s->gpr[rs] < s->gpr[rt];
	s->pc += 4;
	s->insn_histo[mipsInsn::SLT]++;	
	break;
      case 0x2B: { /* sltu */
	s->gpr[rd] = ((uint64_t)s->gpr[rs] < (uint64_t)s->gpr[rt]);
	s->pc += 4;
	s->insn_histo[mipsInsn::SLTU]++;
	break;
      }
      case 0x0B: /* movn */
	s->gpr[rd] = (s->gpr[rt] != 0) ? s->gpr[rs] : s->gpr[rd];
	s->pc +=4;
	s->insn_histo[mipsInsn::MOVN]++;
	break;
      case 0x0A: /* movz */
	s->gpr[rd] = (s->gpr[rt] == 0) ? s->gpr[rs] : s->gpr[rd];
	s->pc += 4;
	s->insn_histo[mipsInsn::MOVZ]++;	
	break;
      case 0x30: /* tge  */
	if((int64_t)s->gpr[rs] >= (int64_t)s->gpr[rt]) { raise_trap(s); return; }
	s->pc += 4; s->insn_histo[mipsInsn::TGE]++; break;
      case 0x31: /* tgeu */
	if((uint64_t)s->gpr[rs] >= (uint64_t)s->gpr[rt]) { raise_trap(s); return; }
	s->pc += 4; s->insn_histo[mipsInsn::TGEU]++; break;
      case 0x32: /* tlt  */
	if((int64_t)s->gpr[rs] < (int64_t)s->gpr[rt]) { raise_trap(s); return; }
	s->pc += 4; s->insn_histo[mipsInsn::TLT]++; break;
      case 0x33: /* tltu */
	if((uint64_t)s->gpr[rs] < (uint64_t)s->gpr[rt]) { raise_trap(s); return; }
	s->pc += 4; s->insn_histo[mipsInsn::TLTU]++; break;
      case 0x34: /* teq */
	if(s->gpr[rs] == s->gpr[rt]) {
	  raise_trap(s);
	  return;
	}
	s->pc += 4;
	s->insn_histo[mipsInsn::TEQ]++;
	break;
      case 0x36: /* tne */
	if(s->gpr[rs] != s->gpr[rt]) {
	  raise_trap(s);
	  return;
	}
	s->pc += 4;
	s->insn_histo[mipsInsn::TNE]++;
	break;
      case 0x2C: { /* dadd */
	uint64_t u_rs = (uint64_t)s->gpr[rs];
	uint64_t u_rt = (uint64_t)s->gpr[rt];
	uint64_t result = u_rs + u_rt;
	/* Matches RTL: w_add64_overflow = (result[63]!=rt[63]) & (rs[63]==rt[63]) */
	if (((result >> 63) != (u_rt >> 63)) && ((u_rs >> 63) == (u_rt >> 63))) {
	  raise_overflow(s);
	  break;
	}
	s->gpr[rd] = (int64_t)result;
	s->pc += 4;
	s->insn_histo[mipsInsn::DADD]++;
	break;
      }
      case 0x2D: /* daddu */
	s->gpr[rd] = s->gpr[rs] + s->gpr[rt];
	s->pc += 4;
	s->insn_histo[mipsInsn::DADDU]++;
	break;
      case 0x2E: { /* dsub */
	uint64_t u_rs = (uint64_t)s->gpr[rs];
	uint64_t u_rt = (uint64_t)s->gpr[rt];
	uint64_t result = u_rs - u_rt;
	/* A-B overflows iff operands differ in sign AND result sign != rs (minuend).
	 * Matches RTL: w_sub64_overflow = (result[63]!=rs[63]) & (rs[63]!=rt[63]) */
	if (((result >> 63) != (u_rs >> 63)) && ((u_rs >> 63) != (u_rt >> 63))) {
	  raise_overflow(s);
	  break;
	}
	s->gpr[rd] = (int64_t)result;
	s->pc += 4;
	s->insn_histo[mipsInsn::DSUB]++;
	break;
      }
      case 0x2F: /* dsubu */
	s->gpr[rd] = s->gpr[rs] - s->gpr[rt];
	s->pc += 4;
	s->insn_histo[mipsInsn::DSUBU]++;
	break;
      case 0x14: /* dsllv: rd = rt << rs[5:0] */
	s->gpr[rd] = s->gpr[rt] << (s->gpr[rs] & 63);
	s->pc += 4;
	s->insn_histo[mipsInsn::DSLLV]++;
	break;
      case 0x16: /* dsrlv: rd = rt >> rs[5:0] (logical) */
	s->gpr[rd] = (int64_t)((uint64_t)s->gpr[rt] >> (s->gpr[rs] & 63));
	s->pc += 4;
	s->insn_histo[mipsInsn::DSRLV]++;
	break;
      case 0x17: /* dsrav: rd = rt >> rs[5:0] (arithmetic) */
	s->gpr[rd] = s->gpr[rt] >> (s->gpr[rs] & 63);
	s->pc += 4;
	s->insn_histo[mipsInsn::DSRAV]++;
	break;
      case 0x38: /* dsll: rd = rt << sa */
	s->gpr[rd] = s->gpr[rt] << sa;
	s->pc += 4;
	s->insn_histo[mipsInsn::DSLL]++;
	break;
      case 0x3A: /* dsrl: rd = rt >> sa (logical) */
	s->gpr[rd] = (int64_t)((uint64_t)s->gpr[rt] >> sa);
	s->pc += 4;
	s->insn_histo[mipsInsn::DSRL]++;
	break;
      case 0x3B: /* dsra: rd = rt >> sa (arithmetic) */
	s->gpr[rd] = s->gpr[rt] >> sa;
	s->pc += 4;
	s->insn_histo[mipsInsn::DSRA]++;
	break;
      case 0x3C: /* dsll32: rd = rt << (sa + 32) */
	s->gpr[rd] = s->gpr[rt] << (sa + 32);
	s->pc += 4;
	s->insn_histo[mipsInsn::DSLL32]++;
	break;
      case 0x3E: /* dsrl32: rd = rt >> (sa + 32) (logical) */
	s->gpr[rd] = (int64_t)((uint64_t)s->gpr[rt] >> (sa + 32));
	s->pc += 4;
	s->insn_histo[mipsInsn::DSRL32]++;
	break;
      case 0x3F: /* dsra32: rd = rt >> (sa + 32) (arithmetic) */
	s->gpr[rd] = s->gpr[rt] >> (sa + 32);
	s->pc += 4;
	s->insn_histo[mipsInsn::DSRA32]++;
	break;
      default:
	raise_ri(s, inst);
	break;
      }
  }
  else if(isSpecial2 || isSpecial3)
    raise_ri(s, inst);   /* MIPS32 SPECIAL2/SPECIAL3 are not in MIPS-III (R4000) */
  else if(isJType) {
    state_t::reg_t jaddr = inst & ((1<<26)-1);
    jaddr <<= 2;
    if(opcode==0x2) { /* j */
      s->pc += 4;
      s->insn_histo[mipsInsn::J]++;
    }
    else if(opcode==0x3) { /* jal */
      s->gpr[31] = s->pc + 8;   /* full 64-bit link (match RTL int_uop.pc+8; no 32b trunc) */
      s->pc += 4;
      s->insn_histo[mipsInsn::JAL]++;
    }
    else {
      printf("Unknown JType instruction\n");
      exit(-1);
    }
    jaddr |= (s->pc & (~static_cast<state_t::reg_t>((1<<28)-1)));
    if(!run_delay_slot<EL>(s))
      s->pc = jaddr;
    //printf("new pc = %lx\n", jaddr);
  }
  else if(isCoproc0) {
    if( ((inst >> 25)&1) ) {
      /* CO=1 instructions: TLB ops, ERET, WAIT */
      switch(inst & 63)
	{
	case 0x1: { /* TLBR -- read TLB[Index] into staging regs */
	  uint32_t idx = s->cpr0[CPR0_INDEX] & 63;
	  if(idx < (uint32_t)state_t::NUM_TLB_ENTRIES) {
	    s->cpr0_64[CPR0_ENTRYHI]  = s->tlb[idx].entry_hi;
	    s->cpr0_64[CPR0_ENTRYLO0] = s->tlb[idx].entry_lo0;
	    s->cpr0_64[CPR0_ENTRYLO1] = s->tlb[idx].entry_lo1;
	    s->cpr0[CPR0_ENTRYHI]     = (uint32_t)s->tlb[idx].entry_hi;
	    s->cpr0[CPR0_ENTRYLO0]    = (uint32_t)s->tlb[idx].entry_lo0;
	    s->cpr0[CPR0_ENTRYLO1]    = (uint32_t)s->tlb[idx].entry_lo1;
	    s->cpr0[CPR0_PAGEMASK]    = s->tlb[idx].page_mask;
	  }
	  s->insn_histo[mipsInsn::TLBR]++;
	  break;
	}
	case 0x2: { /* TLBWI -- write staging regs to TLB[Index] */
	  uint32_t idx = s->cpr0[CPR0_INDEX] & 63;
	  if(idx < (uint32_t)state_t::NUM_TLB_ENTRIES) {
	    s->tlb[idx].entry_hi  = s->cpr0_64[CPR0_ENTRYHI];
	    s->tlb[idx].entry_lo0 = s->cpr0_64[CPR0_ENTRYLO0];
	    s->tlb[idx].entry_lo1 = s->cpr0_64[CPR0_ENTRYLO1];
	    s->tlb[idx].page_mask = s->cpr0[CPR0_PAGEMASK];
	  }
	  utlb_flush();   /* a mapping changed -> drop the micro-TLB */
	  s->insn_histo[mipsInsn::TLBWI]++;
	  break;
	}
	case 0x6: { /* TLBWR -- write staging regs to TLB[Random] */
	  uint32_t idx = s->cpr0[CPR0_RANDOM] & 63;
	  if(idx < (uint32_t)state_t::NUM_TLB_ENTRIES) {
	    s->tlb[idx].entry_hi  = s->cpr0_64[CPR0_ENTRYHI];
	    s->tlb[idx].entry_lo0 = s->cpr0_64[CPR0_ENTRYLO0];
	    s->tlb[idx].entry_lo1 = s->cpr0_64[CPR0_ENTRYLO1];
	    s->tlb[idx].page_mask = s->cpr0[CPR0_PAGEMASK];
	  }
	  utlb_flush();   /* a mapping changed -> drop the micro-TLB */
	  /* Decrement Random, wrap to NUM_TLB_ENTRIES-1 when it reaches Wired */
	  {
	    uint32_t wired  = s->cpr0[CPR0_WIRED] & 63;
	    uint32_t random = s->cpr0[CPR0_RANDOM] & 63;
	    s->cpr0[CPR0_RANDOM] = (random <= wired)
	      ? (uint32_t)(state_t::NUM_TLB_ENTRIES - 1) : (random - 1);
	  }
	  s->insn_histo[mipsInsn::TLBWR]++;
	  break;
	}
	case 0x8: { /* TLBP -- probe TLB for matching entry */
	  uint64_t probe_hi   = s->cpr0_64[CPR0_ENTRYHI];
	  uint64_t probe_asid = probe_hi & 0xffu;
	  bool found = false;
	  for(int i = 0; i < state_t::NUM_TLB_ENTRIES; i++) {
	    /* Apply page-mask to get the significant VPN2 bits */
	    uint64_t mask    = ~(uint64_t)(s->tlb[i].page_mask | 0x1fffu);
	    bool global      = (s->tlb[i].entry_lo0 & 1u) &&
	                       (s->tlb[i].entry_lo1 & 1u);
	    bool vpn_match   = (probe_hi & mask) == (s->tlb[i].entry_hi & mask);
	    bool asid_match  = global ||
	                       (probe_asid == (s->tlb[i].entry_hi & 0xffu));
	    if(vpn_match && asid_match) {
	      s->cpr0[CPR0_INDEX] = (uint32_t)i; /* P=0, index=i */
	      found = true;
	      break;
	    }
	  }
	  if(!found) {
	    s->cpr0[CPR0_INDEX] |= (1u << 31); /* P=1 (probe failed) */
	  }
	  s->insn_histo[mipsInsn::TLBP]++;
	  break;
	}
	case 24: { /* ERET -- exception return */
	  s->ll_link_valid = false;   /* ERET breaks the LL/SC link (R10000 p.27, R4400 Ch.11) */
	  if(s->cpr0[CPR0_SR] & SR_ERL) {
	    /* Return from error: EPC = ErrorEPC, clear ERL */
	    s->pc = (int32_t)s->cpr0[CPR0_ERROREPC] - 4;
	    s->cpr0[CPR0_SR] &= ~SR_ERL;
	  } else {
	    /* Return from exception: PC = EPC, clear EXL */
	    s->pc = (int32_t)s->cpr0[CPR0_EPC] - 4;
	    s->cpr0[CPR0_SR] &= ~SR_EXL;
	  }
	  s->insn_histo[mipsInsn::ERET]++;
	  break;
	}
	case 32: //WAIT
	  if((s->cpr0[CPR0_SR] & 1) == 0) {
	    printf("attempting to wait with interrupts disabled @ VA %x, PA %x\n",
		   s->pc, VA2PA(s->pc));
	    exit(-1);
	  }
	  s->insn_histo[mipsInsn::WAIT]++;
	  break;
	default:
	  exit(-1);
	}
    }
    else if( (((inst >> 21) & 31) == 11 ) &&
	     ((inst & 65535) == 0x6000) ) {
      //DI
      if(rt != 0) {
	s->gpr[rt] = s->cpr0[CPR0_SR];
      }
      s->cpr0[CPR0_SR] &= (~1U);
      s->insn_histo[mipsInsn::DI]++;
    }
    else if( (((inst >> 21) & 31) == 11 ) &&
	     ((inst & 65535) == 0x6020) ) {
      //EI
      if(rt != 0) {
	s->gpr[rt] = s->cpr0[CPR0_SR];
      }
      s->cpr0[CPR0_SR] |= 1U;
      s->insn_histo[mipsInsn::EI]++;
    }

    else {
      switch(rs)
	{
	case 0x0: /*mfc0*/
	  if(rd == 7) {
	    s->gpr[rt] = 0;
	  } else {
	    /* mfc0 sign-extends the 32-bit CP0 value to 64 bits, matching HW. */
	    s->gpr[rt] = sext32(s->cpr0[rd]);
	  }
	  s->insn_histo[mipsInsn::MFC0]++;
	  break;
	case 0x1: /*dmfc0 -- read full 64-bit CP0 register */
	  s->gpr[rt] = s->cpr0_64[rd];
	  s->insn_histo[mipsInsn::DMFC0]++;
	  break;
	case 0x4: /*mtc0*/
	  if(rd != 15) { /* PRId (reg 15) is read-only */
	    s->cpr0[rd] = (uint32_t)s->gpr[rt];
	    s->cpr0_64[rd] = (uint64_t)(uint32_t)s->gpr[rt];
	  }
	  /* CP0 reg 7 is the simulator putchar port */
	  if(rd == 7 && !s->silent) {
	    fputc((int)(s->gpr[rt] & 0xff), stdout);
	    fflush(stdout);
	  }
	  s->insn_histo[mipsInsn::MTC0]++;
	  break;
	case 0x5: /*dmtc0 -- write full 64-bit CP0 register */
	  if(rd != 15) { /* PRId (reg 15) is read-only */
	    s->cpr0_64[rd] = s->gpr[rt];
	    s->cpr0[rd] = (uint32_t)s->gpr[rt];
	  }
	  if(rd == 7 && !s->silent) {
	    fputc((int)(s->gpr[rt] & 0xff), stdout);
	    fflush(stdout);
	  }
	  s->insn_histo[mipsInsn::DMTC0]++;
	  break;
	default:
	  std::cerr << "unhandled cpr0 instruction @ "
		    << std::hex << s->pc << std::dec << "\n";
	  exit(-1);
	  break;
	}
      }
    s->pc += 4;
  }
  else if(isCoproc1) 
    execCoproc1<EL>(inst,s);
  else if(isCoproc1x)
    execCoproc1x<EL>(inst,s);
  else if(isCoproc2) {
    printf("coproc2 unimplemented\n");  exit(-1);
  }
  else if(isLoadLinked) {
    /* Set the reservation on the linked cache line before the load: if the load
     * faults, the exception path (set_exc_pc) clears it again -> no stale link. */
    int32_t llimm = (int32_t)(int16_t)(inst & 0xffffu);
    uint32_t llpa = 0;   /* non-faulting: the _lw/_lld below does the real va_translate */
    if(!tlb_probe_ro(s, s->gpr[rs] + llimm, &llpa)) llpa = va2pa(s->gpr[rs] + llimm);
    uint64_t ll_ea = llpa;
    s->ll_link_valid = true;
    s->ll_link_addr  = ll_ea & ~UINT64_C(0xf);   /* 16B line (LG_L1D_CL_LEN=4) */
    if(opcode == 0x34) _lld<EL>(inst, s);   /* lld = 64-bit */
    else               _lw<EL>(inst, s);    /* ll  = 32-bit */
  }
  else if(isStoreCond) {
    if(opcode == 0x3c) _scd<EL>(inst, s);   /* scd = 64-bit */
    else               _sc<EL>(inst, s);    /* sc  = 32-bit */
  }
  else { /* itype */
    uint32_t uimm32 = inst & ((1<<16) - 1);
    int16_t simm16 = (int16_t)uimm32;
    int32_t simm32 = (int32_t)simm16;
    int32_t tmp;
    switch(opcode) 
      {
      case 0x01:
	_bgez_bltz<EL>(inst, s); 
	break;
      case 0x04:
	branch<EL,branch_type::beq>(inst, s);
	break;
      case 0x05:
	branch<EL,branch_type::bne>(inst, s); 
	break;
      case 0x06:
	branch<EL,branch_type::blez>(inst, s); 
	break;
      case 0x07:
	branch<EL,branch_type::bgtz>(inst, s); 
	break;
      case 0x08: /* addi */
	s->gpr[rt] = s->gpr[rs] + simm32;  
	s->pc+=4;
	s->insn_histo[mipsInsn::ADDI]++;
	break;
      case 0x09: /* addiu: 32-bit add, result sign-extended (MIPS64) */
	tmp = sext64((uint32_t)(s->gpr[rs] + simm32));
	s->gpr[rt] = tmp;
	s->pc+=4;
	s->insn_histo[mipsInsn::ADDIU]++;
	break;
      case 0x0A: /* slti */
	s->gpr[rt] = (s->gpr[rs] < simm32);
	s->pc += 4;
	s->insn_histo[mipsInsn::SLTI]++;
	break;
      case 0x0B:/* sltiu */
	s->gpr[rt] = ((uint64_t)s->gpr[rs] < (uint64_t)(int64_t)simm32);
	s->pc += 4;
	s->insn_histo[mipsInsn::SLTIU]++;
	break;
      case 0x0c: /* andi */
	s->gpr[rt] = s->gpr[rs] & uimm32;
	s->pc += 4;
	s->insn_histo[mipsInsn::ANDI]++;
	break;
      case 0x0d: /* ori */
	s->gpr[rt] = s->gpr[rs] | uimm32;
	s->pc += 4;
	s->insn_histo[mipsInsn::ORI]++;
	break;
      case 0x0e: /* xori */
	s->gpr[rt] = s->gpr[rs] ^ uimm32;
	s->pc += 4;
	s->insn_histo[mipsInsn::XORI]++;
	break;
      case 0x0F: /* lui */
	uimm32 <<= 16;
	s->gpr[rt] = sext64(uimm32);
	s->pc += 4;
	s->insn_histo[mipsInsn::LUI]++;
	break;
      case 0x14:
	branch<EL,branch_type::beql>(inst, s); 
	break;
      case 0x16:
	branch<EL,branch_type::blezl>(inst, s); 
	break;
      case 0x15:
	branch<EL,branch_type::bnel>(inst, s); 
	break;
      case 0x17:
	branch<EL,branch_type::bgtzl>(inst, s);
	break;
      case 0x18: { /* daddi: 64-bit add-immediate, TRAPS on signed overflow */
	int64_t a = s->gpr[rs];
	int64_t b = (int64_t)simm32;            /* sign-extended 16-bit imm */
	int64_t result = (int64_t)((uint64_t)a + (uint64_t)b);
	/* matches RTL w_add64_overflow: operands same sign AND result sign differs */
	if(((result >> 63) != (b >> 63)) && ((a >> 63) == (b >> 63))) {
	  raise_overflow(s);
	  return;
	}
	s->gpr[rt] = result;
	s->pc += 4;
	s->insn_histo[mipsInsn::DADDI]++;
	break;
      }
      case 0x19: /* daddiu */
	s->gpr[rt] = s->gpr[rs] + simm32;
	s->pc += 4;
	s->insn_histo[mipsInsn::DADDIU]++;
	break;
      case 0x1a:
	_ldl<EL>(inst, s);
	break;
      case 0x1b:
	_ldr<EL>(inst, s);
	break;
      case 0x20:
	_lb(inst, s);
	break;
      case 0x21:
	_lh<EL>(inst, s);
	break;
      case 0x22: 
	_lwl<EL>(inst, s);
	break;
      case 0x23:
	_lw<EL>(inst, s);
	break;
      case 0x24:
	_lbu(inst, s);
	break;
      case 0x27: { /* lwu: load word unsigned (zero-extend to 64 bits) */
	uint32_t rs_ = (inst >> 21) & 31;
	uint32_t rt_ = (inst >> 16) & 31;
	int32_t imm  = (int32_t)(int16_t)(inst & 0xffffu);
	uint32_t ea  = va_translate(s, s->gpr[rs_] + imm, tlb_op::load); if(s->tlb_fault) break;
	if(ea & 3) { raise_adel(s); break; }
	s->gpr[rt_] = (uint64_t)(uint32_t)bswap<EL>(s->mem.get<int32_t>(ea));
	s->pc += 4;
	s->insn_histo[mipsInsn::LWU]++;
	break;
      }
      case 0x25:
	_lhu<EL>(inst, s);
	break;
      case 0x26:
	_lwr<EL>(inst, s);
	break;
      case 0x28:
	_sb(inst, s); 
	break;
      case 0x29:
	_sh<EL>(inst, s); 
	break;
      case 0x2a:
	_swl<EL>(inst, s);
	break;
      case 0x2B:
	_sw<EL>(inst, s);
	break;
      case 0x2c:
	_sdl<EL>(inst, s);
	break;
      case 0x2d:
	_sdr<EL>(inst, s);
	break;
      case 0x2e:
	_swr<EL>(inst, s);
	break;
      case 0x2f: /* cache -- treated as NOP for now */
	s->pc += 4;
	break;
      case 0x31:
	_lwc1<EL>(inst, s);
	break;
      case 0x33: /* prefetch */
	s->pc += 4;
	break;
      case 0x35:
	_ldc1<EL>(inst, s);
	break;
      case 0x39:
	_swc1<EL>(inst, s);
	break;
      case 0x37:
	_ld<EL>(inst, s);
	break;
      case 0x3D:
	_sdc1<EL>(inst, s);
	break;
      case 0x3F:
	_sd<EL>(inst, s);
	break;
      default:
	raise_ri(s, inst);
	break;
      }
  }
}
