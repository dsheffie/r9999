`ifndef __machine_hdr__
`define __machine_hdr__

// Debug trace infrastructure (ROB cycle stamps + HW trace buffer): sim-only.
// Synth/FPGA builds omit it -- the 256x384-bit trace RAM dominates build time.
`ifdef VERILATOR
 `define ENABLE_CYCLE_ACCOUNTING 1
 `define ENABLE_TRACE_BUFFER 1
`endif

// On-silicon HW breakpoint/value-watchpoint in core.sv (freeze the pipe at an offending
// instruction; read GPRs/DRAM coherently over AXI).  OFF by default -- uncomment to
// re-enable the on-silicon watchpoint (see docs/methodology.md "Chasing a bug on silicon").
//`define ENABLE_DEBUG_WATCHPOINT 1  // OFF for verilator TLB-dump run
// Tiny 8-line L2 (congestion experiment; no real LUT win -- the FPU dominates).  OFF by default.
//`define TINY_DEBUG_L2 1
// R4400-exact CP0 hazard: defer irq injection after mtc0 c0_sr. REDUNDANT (mtc0 serializes); study only.
//`define R4K_HAZARD_BEHAV 1
//`define DUMP_TLB_WRITES 1  // (off for FPGA synth)

`define FPGA 1

// LL/SC reservation model -- KEEP IN SYNC with interpret.hh (LLSC_BREAK_ON_LOAD).
//   default (undefined) = BERI/CHERI: a STORE to the linked cache line breaks the
//     link; loads (and stores to other lines) do not.  Matches cheritest.
//   LLSC_BREAK_ON_LOAD  = R10000 conservative (p.27): ANY intervening load OR
//     store breaks the link.  R4400 (p.289) breaks only on external coherence +
//     ERET.  Selecting this requires quarantining cheri scd_alias / lld_ld_scd.
//`define LLSC_BREAK_ON_LOAD 1

//`define RESPECT_MAPPED 1

/* L1D request skid buffer: bypass the r_mem_q FIFO when it is empty and the L1D
 * can accept, driving the freshly-AGU'd request straight to the L1D the same
 * cycle (saves 1 cycle of load-to-use); falls back to enqueue ("skid") when the
 * L1D is busy.  Validated: load-to-use 3->2 cyc / +44% IPC on the dependent-load
 * microbench (tests/memlat), randgen 400/400 + FP co-sim 15/15 clean, henry synth
 * WNS +0.204 (worst path unchanged = ITLB CAM, not the bypass).  Comment out to
 * fall back to the plain enqueue-then-dequeue path. */

//`define ENABLE_L1D_SKID 1

`define LG_M_WIDTH 6

`define BIG_ENDIAN 1

/* ALU int matrix scheduler: 4 entries (LG=2), downsized from 8 (LG=3).  The O(N^2)
 * wakeup/select was on the critical path, so 8->4 is a WNS win (timing margin vs
 * metastability) at a small IPC cost -- kept per functional>IPC.  Bump to 3 for full IPC. */
`define LG_INT_SCHED_ENTRIES 3

//gshare branch predictor
`ifdef FORMAL
 `define LG_PHT_SZ 2
`else
 `define LG_PHT_SZ 16
`endif

`define GBL_HIST_LEN 64

//page size
`define LG_PG_SZ 12

`define LG_PRF_ENTRIES 7

`define LG_HILO_PRF_ENTRIES 2

//queue between decode and alloc
`define LG_DQ_ENTRIES 2

//queue between fetch and decode
`define LG_FQ_ENTRIES 3

//rob size
`ifdef FORMAL
 `define LG_ROB_ENTRIES 2
`else
 `define LG_ROB_ENTRIES 4
`endif

`define LG_RET_STACK_ENTRIES 2

/* non-uop queue */
`define LG_UQ_ENTRIES 3
/* mem uop queue */
`define LG_MEM_UQ_ENTRIES 2
/* mem data queue */
`define LG_MEM_DQ_ENTRIES 2
/* mem uop queue */
`define LG_MQ_ENTRIES 2

/* mem retry queue */
`define LG_MRQ_ENTRIES 3

`define MUL_LAT 3

/* FP unit: fixed-latency pipelined add/sub/mul/compare (mirrors mipscore fpu.sv).
 * FP completes on its own ROB port (complete_bundle_2), so no shared wb-bitvec. */
`define FPU_LAT 4
`define FP_MAX_LAT `FPU_LAT
/* renamed FP condition-code (FCR) register file */
`define LG_FCR_PRF_ENTRIES 2
/* FP issue queue (in-order, mirrors the int UQ) */
`define LG_FP_UQ_ENTRIES 3

`define DIV32_LAT (`M_WIDTH+1)

`define MAX_LAT (`DIV32_LAT)


// cacheline length (in bytes)
`define LG_L1D_CL_LEN 4

//number of sets in direct mapped cache
`ifdef FORMAL
 `define LG_L1D_NUM_SETS 2
`else
 `define LG_L1D_NUM_SETS 8
`endif

`ifdef FORMAL
 `define LG_L1I_NUM_SETS 2
`else
 `define LG_L1I_NUM_SETS 8
`endif

`ifdef FORMAL
 `define LG_L2_NUM_SETS 2
`else
 `ifdef TINY_DEBUG_L2
  `define LG_L2_NUM_SETS 3
 `elsif BIG_SIM_L2
  `define LG_L2_NUM_SETS 16     /* 65536 lines x 16B = 1MB (sim-only; too big for FPGA BRAM) */
 `else
  `define LG_L2_NUM_SETS 13     /* 8192 lines x 16B = 128KB (default; fits henry xczu3eg BRAM) */
 `endif
`endif


`define M_WIDTH (1 << `LG_M_WIDTH)

/* Physical address width. VAs stay `M_WIDTH (64); physical addresses (cache tags,
 * the memory bus, TLB PA, L2) are PA_WIDTH. R4000 = 36; IRIX/Indy needs only 29
 * (kseg0 mask is 0x1fffffff = 29 bits). Shmoo {29,32,36} for the area/timing curve. */
`define PA_WIDTH 36

/* Supported virtual-address bits within a region (MIPS SEGBITS). A non-compat 64b
 * VA must fit in SEGBITS, i.e. VA[61:SEGBITS]==0, else Address Error (Sail
 * TLBTranslate MAX_VA). R4000 = 40; R10000 = 48. This also bounds the VPN width
 * carried through the TLB/CAM, so shrinking it saves bits on the critical path. */
`define SEGBITS 40

/* Page-frame-number width = PA_WIDTH - 12 (4KB page offset). The TLB stores
 * PFN this wide (so PA = {pfn, va[11:0]} is exactly PA_WIDTH and can never exceed
 * it -- no translate-time PA-range check needed). 36-bit PA -> 24-bit PFN. */
`define PFN_WIDTH (`PA_WIDTH - 12)

/* JTLB entry count -- the knob for the TLB-CAM timing tradeoff. R4000/R4400 is
 * architecturally 48 (IRIX + Linux both hardcode it by PRId -- there's no Config1
 * MMU-size reg on R4x00), so 48 is the default and the ONLY value IRIX accepts.
 * Set 16 for a Linux-only, timing-optimized FPGA build: the fully-associative TLB
 * CAM is henry's #1 timing path (48->16 measured WNS -0.240 -> +0.191, passes),
 * but it ALSO requires a matching Linux cpu-probe.c `c->tlbsize = 16` and BREAKS
 * IRIX. The keeper fix (both OSes + the timing win) is a micro-TLB in front of a
 * 48-entry JTLB. Single source of truth for tlb.sv (N) + exec.sv (Random reset/
 * wrap + shadow depth); flip here, nowhere else. */
`define N_TLB_ENTRIES 48

/* Micro-ITLB: a small fully-associative cache of translations in front of the
 * 48-way JTLB CAM (itlb.sv).  Hit = 1-cycle translate (skips WAIT_FOR_TLB); miss =
 * probe the 48-way, install with LFSR-random replacement.  Flushed on TLBWR/TLBWI
 * (tlb_entry_in_valid) and on ASID change.  Small = small CAM = closes timing AND
 * removes the per-fetch JTLB re-prime stall.  Power of 2 (for the LFSR replace). */
`define N_UITLB_ENTRIES 2

/* TEMPORARY sim experiment (revert before commit): inject extra timer IRQs to
 * crank exception frequency ~100x and hunt the "corrupt after an interrupt"
 * mapped-corruption bug under Verilator. Period in core cycles between injected
 * IRQs (normal tick ~= 400000 cyc at HZ=250). NOT for synth. */
/* `define TIMER_ACCEL 1   -- DISABLED: the injected timer ticks advance jiffies
 * (fast-time) and wedge the boot in a poll loop before the initcalls. Using random
 * memory latency alone to perturb timing instead. */
`define TIMER_ACCEL_PERIOD 32'd40000

/* Per-structure block-RAM synthesis-attribute guards. Defined as the attribute =
 * force that array into block RAM (frees the LUT/FF fabric, which is the bottleneck
 * on Ultra96); define empty to let Vivado choose (FF/LUTRAM). These apply only to
 * plain INDEXED RAMs -- the associative TLB CAMs (l1i/l1d r_tlb) must stay FFs.
 *   TLB_SHADOW_RAM_STYLE -> exec's CP0 maintenance shadow TLB (r_shadow_tlb)
 *   RF_RAM_STYLE         -> the rf4r2w register-file banks (int/FP/hilo PRFs) */
`define TLB_SHADOW_RAM_STYLE (* ram_style = "block" *)
`define RF_RAM_STYLE         (* ram_style = "block" *)

/* CP0 PRId (processor identification) values. imp field is bits [15:8];
 * the R4000 family shares imp=0x04 and is distinguished by the revision byte. */
`define PRID_R4000  32'h00000400   /* imp 0x04, rev 0x00 */
`define PRID_R4400  32'h00000440   /* imp 0x04, rev 0x40 */
`define PRID_R4600  32'h00002020   /* imp 0x20, rev 0x20 */
`define PRID_R10000 32'h00000900   /* imp 0x09, rev 0x00 */
/* IRIX /unix branches on PRId.IMP in `start`: imp 0x20 (R4600) takes the
 * Indy per-CPU init path; imp 0x04 (R4000/R4400) falls through to a different
 * cache/TLB-refill path that diverges before the KPTEBASE page-table backing
 * (MAME_QUESTIONS.md Q5). The old R4000/R4400 divergence turned out to be a
 * since-fixed TLB bug: R4400 now reaches the SCSI scan, and unlike R4600 (fixed
 * 32-byte L1 line) its Config DB bit lets IRIX manage 16-byte lines matching
 * r9999's LG_L1D_CL_LEN=4. Present R4400. */
`define PRID_VALUE  `PRID_R4400

`define LG_BTB_SZ 7

typedef enum logic [4:0] {
   MEM_LB   = 5'd0,
   MEM_LBU  = 5'd1,
   MEM_LH   = 5'd2,
   MEM_LHU  = 5'd3,
   MEM_LW   = 5'd4,
   MEM_SB   = 5'd5,
   MEM_SH   = 5'd6,
   MEM_SW   = 5'd7,
   MEM_SWR  = 5'd8,
   MEM_SWL  = 5'd9,
   MEM_LWR  = 5'd10,
   MEM_LWL  = 5'd11,
   MEM_SC   = 5'd12,
   MEM_TLBP = 5'd13,
   MEM_LD   = 5'd14,
   MEM_SD   = 5'd15,
   MEM_LWU  = 5'd16,
   MEM_LDL  = 5'd17,
   MEM_LDR  = 5'd18,
   MEM_SDL  = 5'd19,
   MEM_SDR  = 5'd20,
   MEM_LL   = 5'd21,   /* load-linked word  */
   MEM_LLD  = 5'd22,   /* load-linked dword */
   MEM_SCD  = 5'd23,   /* store-conditional dword */
   MEM_INVL = 5'd24,   /* L2 line invalidate (no writeback) -- CACHE DMA-in drop */
   MEM_MOV  = 5'd25,   /* GPR<->FPR move: data carried in req.addr, echoed by L1D (no memory access) */
   MEM_WB   = 5'd26,   /* CACHE writeback-through: L2 hit -> flush line to DRAM + invalidate;
                        * L2 miss -> write the carried data straight to DRAM (so a CACHE
                        * D-writeback reaches memory instead of sitting dirty in L2) */
   MEM_CHWB    = 5'd27, /* CACHE D Hit-Writeback: mem-pipe (dtlb-translated) per-line op */
   MEM_CHWBINV = 5'd28, /* CACHE D Hit-Writeback-Invalidate (mem-pipe) */
   MEM_CHINV   = 5'd29  /* CACHE D Hit-Invalidate, no WB (DMA-in drop; mem-pipe) */
} mem_op_t;

/* MIPS R10000 exception ordering 
* Cold Reset (highest priority)
* Soft Reset
* Nonmaskable Interrupt (NMI)‡
* Cache error –– Instruction cache*
* Cache error –– Data cache*
* Cache error –– Secondary cache*
* Cache error –– System interface*
* Address error –– Instruction fetch
* TLB refill –– Instruction fetch
* TLB invalid –– Instruction fetch
* Bus error –– Instruction fetch
* Integer overflow, 
* Trap, 
* System Call,
* Breakpoint, 
* Reserved Instruction, 
* Coprocessor Unusable
* Floating-Point Exception
* Address error –– Data access
* TLB refill –– Data access
* TLB invalid –– Data access
* TLB modified –– Data write
* Watch
* Bus error –– Data access
* Interrupt (lowest priority)
*/

typedef enum logic [4:0] {
 NO_ERROR = 5'd0,			   
 IC_ERROR = 5'd1,
 DC_ERROR = 5'd2,
 IA_ERROR = 5'd3, /* instruction address error */
 ITLB_REFILL_ERROR = 5'd4,
 ITLB_INVALID_ERROR = 5'd5,
 INSN_BUS_ERROR = 5'd6,
 INT_OVERFLOW = 5'd7,
 RESERVED_INSN = 5'd8,
 COPROC_UNUSABLE = 5'd9,
 FP_EXCEPTION = 5'd10,
 DA_ERROR = 5'd11, /* data address error */
 DTLB_REFILL_ERROR = 5'd12,
 DTLB_INVALID_ERROR = 5'd13,
 DTLB_MODIFIED_ERROR = 5'd14,
 DATA_BUS_ERROR	= 5'd15,
 BR_MISPREDICT = 5'd16			  
} exception_t;


function logic [31:0] bswap32(logic [31:0] in);
`ifdef BIG_ENDIAN
   return {in[7:0], in[15:8], in[23:16], in[31:24]};
`else
   return in;
`endif
endfunction

function logic [15:0] bswap16(logic [15:0] in);
`ifdef BIG_ENDIAN
   return {in[7:0], in[15:8]};
`else
   return in;
`endif
endfunction

function logic sext16(logic [15:0] in);
`ifdef BIG_ENDIAN
   return in[7];
`else
   return in[15];
`endif
endfunction

function logic [`M_WIDTH-1:0] sign_extend32(logic [31:0] in);
   logic [`M_WIDTH-1:0]	x;
   x = {   {(`M_WIDTH-32){in[31]}}, in};
   return x;
endfunction // is_mult

function logic [`M_WIDTH-1:0] zero_extend32(logic [31:0] in);
   logic [`M_WIDTH-1:0]	x;
   x = {   {(`M_WIDTH-32){1'b0}}, in};
   return x;
endfunction // is_mult

`endif
//`define GHOST_DEBUG 1  // TLB side-effect trace (spray bug diagnosis)
//`define CHOP_DEBUG 1  // l1d mem-pipe CACHE-op trace
