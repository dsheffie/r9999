`ifndef __rob_hdr__
`define __rob_hdr__

`include "machine.vh"

typedef struct packed {
   logic       faulted;
   logic       is_ii;
   logic       is_cpu;   /* coprocessor unusable (CpU, cause 11) */
   logic       cpu_ce1;  /* the CpU is for CP1 (FPU, CU1=0) -> Cause.CE=1 (else CP0 CpU = CE=0) */
   logic       is_fpe;   /* FP exception (FPE, cause 15): denorm/enabled IEEE flag */
   logic       fp_set_flags; /* completed on FP port 2 (arith/cmp/cvt): update FCSR Cause/Flags at retire */
   logic       overflow;
   logic       trap;
   logic       is_bad_addr;
   logic       is_ret;
   logic       is_call;
   logic       is_irq;
   logic       is_store;
   logic       is_tlbp;
   logic       valid_dst;
   logic       valid_hilo_dst;
   logic       valid_fp_dst;   /* dst is an FP physical reg (free into the FP free list at retire) */
   logic       valid_fcr_dst;  /* dst is an FCR (FP cond-code) physical reg; pdst/old_pdst hold the FCR ptr */
   logic       has_delay_slot;
   logic       has_nullifying_delay_slot;
   logic       in_delay_slot;
   logic [4:0] ldst;

   /* Renamed srcA pointer + its architectural name, captured at ALLOC.  With pdst
    * below this makes the retire trace self-checking for renaming: a consumer whose
    * srcA_ptr does not match the producer's pdst was pointed at the wrong physical
    * register (RAT bug), as opposed to reading the right register and getting stale
    * data (delivery/bypass bug).  The captured jr faults cannot distinguish those
    * two without this. */
   logic [(`LG_PRF_ENTRIES-1):0] srcA_ptr;
   logic [4:0] 		         srcA_arch;
   logic [(`LG_PRF_ENTRIES-1):0] pdst;
   logic [(`LG_PRF_ENTRIES-1):0] old_pdst;
   logic [(`M_WIDTH-1):0] 	 pc;
   logic [(`M_WIDTH-1):0] 	 target_pc;
   logic 			 is_br;
   logic 			 is_indirect;
   logic 			 take_br;
   logic 			 is_break;
   logic			 is_syscall;
   logic			 is_cache;   /* MIPS CACHE op (serializing flush) */
   logic			 cache_is_d; /* CACHE targets D-cache (per-line WB at .data) vs I-cache */
   logic			 cache_inval; /* CACHE Hit-Invalidate: drop line WITHOUT writeback (DMA-in) */
   logic [(`M_WIDTH-1):0]	 data;
   logic [7:0]			 opcode;
   logic [`LG_PHT_SZ-1:0] 	 pht_idx;
   /* PREDICTED direction, kept alongside the RESOLVED take_br so a capture can
    * separate "predictor said taken" from "branch resolved taken".  The
    * 2026-08-29 captures showed a bnez that took wrongly with faulted=0, i.e.
    * NO mispredict was signalled -- prediction and resolution agreed, and both
    * were wrong.  Without this bit we cannot tell which one drove that. */
   logic 			 br_pred;
   logic                         oldest_first;

   logic       tlb_refill;
   logic       tlb_invalid;
   logic       tlb_modified;   
   logic       tlb_hit;
   logic [5:0] tlb_index;
   logic       mode_when_fetched;
   /* Low 8 bits of the free-running cycle counter, stamped when the uop COMPLETES
    * (for a load: when its memory response lands).  Deliberately OUTSIDE the
    * ENABLE_CYCLE_ACCOUNTING guard -- the 64-bit fetch/alloc/complete cycles below
    * are Verilator-only, so silicon had no way to order a producer against its
    * consumer.  Comparing this stamp on a load against the stamp on the branch that
    * consumes it is what distinguishes "consumer issued before the data returned"
    * from "consumer read the right value". */
   logic [7:0] exec_cycle;
   logic [1:0] fwd_sel;   /* operand-mux select at execute; see complete_t */
   logic [1:0] fwd_selB;  /* srcB operand-mux select at execute */
   logic [31:0] srcB_val; /* srcB operand value at execute (branches: the $zero-side compare input) */
   logic hi_nzA;  /* |t_srcA[63:32] at execute -- the compare is 64b, the ring data field 32b */
   logic hi_nzB;  /* |t_srcB[63:32] */
   logic [`LG_ROB_ENTRIES-1:0] wr_echo; /* rob_ptr of the completion that wrote this slot's fields --
                                         * a misdirected field-write stamps a ptr != the slot index */
   logic       post_restart;  /* 1 = first uop allocated after a machine-clear/restart (RAT->ACTIVE) */
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] 	    fetch_cycle;
   logic [63:0] 	    alloc_cycle;
   logic [63:0] 	    complete_cycle;
`endif
   
} rob_entry_t;

typedef struct packed {
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic 		       complete;
   logic 		       faulted;
   logic [`M_WIDTH-1:0]        restart_pc;
   logic 		       take_br;
   logic 		       is_ii;
   logic		       overflow;
   logic		       trap;
   logic [5:0]		       fp_flags;  /* {denorm(E), V,Z,O,U,I} of a completing FP op (port 2) */
   logic [(`M_WIDTH-1):0]      data;
   /* Which source the operand mux actually used for srcA at execute:
    *   bit1 = r_fwd_int_srcA (forwarded ALU result)
    *   bit0 = r_fwd_mem_srcA (forwarded load data)
    *   00   = read from the register file (w_srcA)
    * The 2026-09-02 captures prove two readers of one physreg disagreed but NOT
    * which source delivered the wrong value; every hypothesis (stale PRF read,
    * wrong forward flag, r_mem_result skewed by the next response) fits the
    * evidence equally.  These two bits discriminate. */
   logic [1:0] 		       fwd_sel;
   logic [1:0] 		       fwd_selB;
   logic [31:0] 	       srcB_val;
   logic 		       hi_nzA;
   logic 		       hi_nzB;
} complete_t;

typedef struct packed {
   logic [31:0] data;
   logic [(`M_WIDTH-1):0] pc;
   logic [(`M_WIDTH-1):0] pred_target;
   logic 		  pred;
   logic [(`LG_PHT_SZ-1):0] pht_idx;
   logic		    misaligned;
   logic		    bad_va;       /* i-side AdEL: mipsseg bad_perms (access-level / VA out-of-range) */
   logic		    tlb_miss;
   logic		    tlb_invalid;
   logic		    is_branch;
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] 	    fetch_cycle;
`endif
} insn_fetch_t;

typedef struct packed {
   logic [(`M_WIDTH-1):0] addr;
   logic 	is_store;
   logic	is_atomic;
   mem_op_t op;
   logic 	bad_addr;   
   logic	mapped;
   logic	cached;
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic [`LG_PRF_ENTRIES-1:0] dst_ptr;
   logic 		       dst_valid;
   logic 		       fp_dst;   /* result writes the FP PRF (vs int) — for moves/FP loads */
   /* FR=0 lwc1 merge: write only the fp_hi-selected 32b half of the load result,
    * preserving the other half (fp_pres = the old 32b half read at issue). */
   logic 		       fp_merge;
   logic 		       fp_hi;
   logic [31:0]		       fp_pres;
   logic [(`M_WIDTH-1):0]      data;
   logic [(`M_WIDTH-1):0]      pc;   /* un-guarded for synth: store-tracer PC watchpoint (be birth catch) */
`ifdef VERILATOR
   logic [(`M_WIDTH-1):0]      uuid;
`endif
} mem_req_t;

typedef struct packed {
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic [`LG_PRF_ENTRIES-1:0] src_ptr;
   logic 		       fp;     /* store data comes from the FP PRF (swc1/sdc1) */
   logic 		       fp_hi;  /* FR=0 swc1: store the HIGH 32b half (odd reg) */
} dq_t;

typedef struct packed {
   logic [(`M_WIDTH-1):0] data;
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
} mem_data_t;

typedef struct packed {
   logic [(`M_WIDTH-1):0] data;
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic [`LG_PRF_ENTRIES-1:0] dst_ptr;
   logic 		       dst_valid;
   logic 		       fp_dst;   /* result writes the FP PRF (vs int) */
   logic 		       fp_merge; /* FR=0 lwc1: merge into the fp_hi half, preserve fp_pres */
   logic 		       fp_hi;
   logic [31:0]		       fp_pres;
   logic 		       bad_addr;
   logic		       tlb_refill;
   logic		       tlb_invalid;
   logic		       tlb_modified;
   logic		       tlb_hit;
   logic [5:0]		       tlb_index;
} mem_rsp_t;


/* tlb_stored_t = what each TLB array slot actually holds.  It is tlb_data_t WITHOUT
 * the `entry` (write-index) field: the array position IS the index, so storing it
 * is pure duplication.  KEEP THESE TWO IN SYNC (same fields/order minus entry) --
 * the write casts tlb_data_t -> tlb_stored_t, which drops the leading `entry`. */
typedef struct packed {
   logic [11:0] pagemask;
   logic [7:0]  asid;
   logic [1:0]  r;      /* region: va[63:62] */
   logic [26:0] vpn;    /* va[39:13], 27 bits for 64-bit mode */

   logic [`PFN_WIDTH-1:0] pfn0;   /* pa[PA_WIDTH-1:12] = PA_WIDTH-12 bits (24 for 36-bit PA) */
   logic        d0;
   logic        v0;
   logic        g0;
   logic [2:0]  c0;

   logic [`PFN_WIDTH-1:0] pfn1;   /* pa[PA_WIDTH-1:12] = PA_WIDTH-12 bits (24 for 36-bit PA) */
   logic        d1;
   logic        v1;
   logic        g1;
   logic [2:0]  c1;
} tlb_stored_t;

/* tlb_data_t = the write-interface (plumbing) type: tlb_stored_t + the `entry`
 * write-index as the leading (MSB) field, so tlb_stored_t'(x) truncates it off. */
typedef struct packed {

   logic [5:0]  entry;
   logic [11:0] pagemask;
   logic [7:0]  asid;
   logic [1:0]  r;      /* region: va[63:62] */
   logic [26:0] vpn;    /* va[39:13], 27 bits for 64-bit mode */

   logic [`PFN_WIDTH-1:0] pfn0;   /* pa[PA_WIDTH-1:12] = PA_WIDTH-12 bits (24 for 36-bit PA) */
   logic        d0;
   logic        v0;
   logic        g0;
   logic [2:0]  c0;

   logic [`PFN_WIDTH-1:0] pfn1;   /* pa[PA_WIDTH-1:12] = PA_WIDTH-12 bits (24 for 36-bit PA) */
   logic        d1;
   logic        v1;
   logic        g1;
   logic [2:0]  c1;
} tlb_data_t;

`endif
