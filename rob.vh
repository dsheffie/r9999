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
   logic                         oldest_first;

   logic       tlb_refill;
   logic       tlb_invalid;
   logic       tlb_modified;   
   logic       tlb_hit;
   logic [5:0] tlb_index;
   logic       mode_when_fetched;
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] 	    fetch_cycle;
   logic [63:0] 	    alloc_cycle;
   logic [63:0] 	    complete_cycle;
`endif
   
} rob_entry_t;

/* The ROB is stored as two structures indexed by the same rob_ptr (rv64core's
 * split): fields written only at ALLOC live in mrob_entry_t (one write port per
 * even/odd bank, no reset, so they can map to LUTRAM); fields written at
 * COMPLETION live in crob_entry_t (multi-ported flops).  rob_entry_t stays the
 * merged view every reader uses; core.sv's rob_to_mrob/rob_to_crob/rob_merge
 * convert between them. */
typedef struct packed {
   logic is_cpu;
   logic cpu_ce1;
   logic is_ret;
   logic is_call;
   logic is_irq;
   logic is_store;
   logic is_tlbp;
   logic valid_dst;
   logic valid_hilo_dst;
   logic valid_fp_dst;
   logic valid_fcr_dst;
   logic has_delay_slot;
   logic has_nullifying_delay_slot;
   logic in_delay_slot;
   logic [4:0] ldst;
   logic [(`LG_PRF_ENTRIES-1):0] pdst;
   logic [(`LG_PRF_ENTRIES-1):0] old_pdst;
   logic [(`M_WIDTH-1):0] pc;
   logic is_br;
   logic is_indirect;
   logic is_break;
   logic is_syscall;
   logic is_cache;
   logic cache_is_d;
   logic cache_inval;
   logic [7:0] opcode;
   logic [`LG_PHT_SZ-1:0] pht_idx;
   logic oldest_first;
   logic mode_when_fetched;
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] fetch_cycle;
   logic [63:0] alloc_cycle;
`endif
} mrob_entry_t;

typedef struct packed {
   logic faulted;
   logic is_ii;
   logic is_fpe;
   logic fp_set_flags;
   logic overflow;
   logic trap;
   logic is_bad_addr;
   logic [(`M_WIDTH-1):0] target_pc;
   logic take_br;
   logic [(`M_WIDTH-1):0] data;
   logic tlb_refill;
   logic tlb_invalid;
   logic tlb_modified;
   logic tlb_hit;
   logic [5:0] tlb_index;
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] complete_cycle;
`endif
} crob_entry_t;

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

/* LSU block codes: why a simple load could not complete on its port-2 pass.
 * It parks in its LSU entry until its wake condition, then re-issues.
 *   bit 2 clear: cache-owned -- the MQ entry fetches the line / waits out the
 *                store, then the l1d sends a wakeup with the lsu_idx.
 *   bit 2 set:   LSU-owned -- an older store still in the LSU overlaps the load
 *                (blk_st = which ones); the LSU wakes it itself. */
typedef enum logic [2:0] {
   BLK_NONE = 3'd0,
   BLK_MISS = 3'd1,         /* tag miss: the miss queue reloads the line */
   BLK_ST_CONFLICT = 3'd2,  /* same set + byte overlap with a store in the l1d MQ */
   BLK_SB_CONFLICT = 3'd4,  /* overlaps older LSU store(s), cannot forward: wait for them to drain */
   BLK_SB_DATA = 3'd5,      /* would forward, but the youngest overlapping store has no data yet */
   BLK_UNCACHEABLE = 3'd6   /* uncached (segment or TLB C) and not yet non-speculative:
			     * re-issue once at the ROB head (or its committable delay slot) */
} blk_code_t;

/* exec LSU -> l1d store-buffer view.  The LSU owns the stores (allocation, age,
 * retirement, drain); the l1d holds each store's translated PA / mask / data at
 * its LSU slot, where a load's PA is known, and compares loads against it. */
typedef struct packed {
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] live;     /* slot holds a plain store */
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] epoch;    /* toggles at each slot allocation */
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] data_ok;  /* store data has landed in the l1d */
   /* matrix[j*N+k] = slot k is older than slot j (the LSU age matrix) */
   logic [(1<<(2*`LG_MEM_SCHED_ENTRIES))-1:0] matrix;
   logic 				   retired_pending; /* a retired store has not drained */
   logic 				   data_valid;      /* store data write */
   logic [`LG_MEM_SCHED_ENTRIES-1:0] 	   data_idx;
   logic [63:0] 			   data;
} lsu_sb_t;

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
   /* simple load (LW/LWU/LB/LBU/LH/LHU/LD/LWC1/LDC1): its LSU entry stays until
    * the data returns, so the l1d may block it instead of replaying it */
   logic 		       lsu_hold;
   logic [`LG_MEM_SCHED_ENTRIES-1:0] lsu_idx;
   /* plain store drain: write the store held at lsu_idx (PA/data from the l1d
    * store buffer); the store has retired, so rob_ptr is stale -- never use it */
   logic 		       commit;
   /* restart color (rv64core restart_id, 1 bit): flips at every restart; a
    * request/response of the other color belongs to a flushed era and is dropped
    * (commits are never dead and are exempt) */
   logic 		       restart_id;
   /* load: plain stores older than it at issue, with their slot epochs */
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] lsu_older_st;
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] lsu_older_ep;
`ifdef VERILATOR
   logic [(`M_WIDTH-1):0]      pc;
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
   logic 		       lsu_hold;   /* echo of mem_req_t.lsu_hold */
   logic [`LG_MEM_SCHED_ENTRIES-1:0] lsu_idx;
   blk_code_t		       blk;        /* valid with core_mem_blk_valid */
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] blk_st;  /* BLK_SB_*: the overlapping store slots */
   logic 		       restart_id; /* echo of the request's color */
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
