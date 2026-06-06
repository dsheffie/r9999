`ifndef __rob_hdr__
`define __rob_hdr__

`include "machine.vh"

typedef struct packed {
   logic       faulted;
   logic       is_ii;
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
   logic [(`M_WIDTH-1):0]	 data;
   logic [6:0]			 opcode;
   logic [`LG_PHT_SZ-1:0] 	 pht_idx;

   logic       tlb_refill;
   logic       tlb_invalid;
   logic       tlb_modified;   
   logic       tlb_hit;
   logic [5:0] tlb_index;
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
   logic		    is_branch;
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] 	    fetch_cycle;
`endif
} insn_fetch_t;

typedef struct packed {
   logic [(`M_WIDTH-1):0] addr;
   logic 	is_store;
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

   logic [5:0] entry;
   logic [11:0]	pagemask;
   logic [7:0]	asid;
   logic [18:0]	vpn;
   
   logic [23:0]	pfn0;
   logic	d0;
   logic	v0;
   logic	g0;
   logic [2:0]	c0;
   
   logic [23:0]	pfn1;
   logic	d1;
   logic	v1;
   logic	g1;
   logic [2:0]	c1;
} tlb_data_t;

`endif
