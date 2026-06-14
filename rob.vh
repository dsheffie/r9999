`ifndef __rob_hdr__
`define __rob_hdr__

`include "machine.vh"

typedef struct packed {
   logic       faulted;
   logic       is_ii;
   logic       is_cpu;   /* coprocessor unusable (CpU, cause 11) */
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
   logic [6:0]			 opcode;
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

typedef struct packed {
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic 		       complete;
   logic 		       faulted;
   logic [`M_WIDTH-1:0]        restart_pc;
   logic 		       take_br;
   logic 		       is_ii;
   logic		       overflow;
   logic		       trap;
   logic [(`M_WIDTH-1):0]      data;
} complete_t;

typedef struct packed {
   logic [31:0] data;
   logic [(`M_WIDTH-1):0] pc;
   logic [(`M_WIDTH-1):0] pred_target;
   logic 		  pred;
   logic [(`LG_PHT_SZ-1):0] pht_idx;
   logic		    misaligned;
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
   logic [(`M_WIDTH-1):0]      data;
`ifdef VERILATOR
   logic [(`M_WIDTH-1):0]      pc;
`endif
} mem_req_t;

typedef struct packed {
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic [`LG_PRF_ENTRIES-1:0] src_ptr;
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
   logic 		       bad_addr;
   logic		       tlb_refill;
   logic		       tlb_invalid;
   logic		       tlb_modified;
   logic		       tlb_hit;
   logic [5:0]		       tlb_index;
} mem_rsp_t;


typedef struct packed {

   logic [5:0]  entry;
   logic [11:0] pagemask;
   logic [7:0]  asid;
   logic [1:0]  r;      /* region: va[63:62] */
   logic [26:0] vpn;    /* va[39:13], 27 bits for 64-bit mode */

   logic [27:0] pfn0;   /* pa[39:12], 28 bits for 40-bit PA */
   logic        d0;
   logic        v0;
   logic        g0;
   logic [2:0]  c0;

   logic [27:0] pfn1;   /* pa[39:12], 28 bits for 40-bit PA */
   logic        d1;
   logic        v1;
   logic        g1;
   logic [2:0]  c1;
} tlb_data_t;

`endif
