`include "machine.vh"
`include "rob.vh"
`include "uop.vh"

`ifdef VERILATOR
import "DPI-C" function void record_fetch(int push1, int push2, int push3, int push4,
					  longint pc0, longint pc1, longint pc2, longint pc3,
					  int bubble, int fq_full);

`endif





module compute_pht_idx(pc, idx);
   input logic [`M_WIDTH-1:0] pc;
   output logic [`LG_PHT_SZ-1:0]   idx;

   /* the PHT is the PC-indexed bimodal (history goes to the tagged tables), indexed
    * per 16B LINE (bit 4 up): the entry holds a counter for each of the 4 slots */
   assign idx = pc[`LG_PHT_SZ+3:4];
   
endmodule

module l1i(clk,
	   state,
	   asid,
	   reset,
	   in_kernel_mode,
	   in_supervisor_mode,
	   in_user_mode,
	   in_64b_kernel_mode,
	   in_64b_supervisor_mode,
	   in_64b_user_mode,
	   flush_req,
	   flush_complete,
	   restart_pc,
	   restart_src_pc,
	   restart_src_is_indirect,
	   dbg_arch_hist,
	   dbg_spec_hist,
	   restart_valid,
	   restart_ack,
	   retire_valid,
	   retired_call,
	   retired_ret,
	   retire_reg_ptr,
	   retire_reg_data,
	   retire_reg_valid,
	   branch_pc_valid,
	   branch_pc,
	   took_branch,
	   branch_fault,
	   branch_bpu_idx,
	   
	   insn,
	   insn_valid,
	   insn_ack,
	   
	   insn_two,
	   insn_valid_two,
	   insn_ack_two,
	   
	   //output to the memory system
	   mem_req_ack,
	   mem_req_valid,
	   mem_req_addr,
	   mem_req_opcode,
	   mem_req_cacheable,
	   mem_req_mask,
	   //reply from memory system
	   mem_rsp_valid,
	   mem_rsp_load_data,
	   cache_accesses,
	   cache_hits,
	   // I-side TLB entry write port (shared with D-side)
	   tlb_entry_in_valid,
	   tlb_entry_in
	   );

   input logic clk;
   output logic [3:0] state;
   input logic [7:0]  asid;
   
   input logic reset;
   input logic			in_kernel_mode;
   input logic			in_supervisor_mode;
   input logic			in_user_mode;
   input logic			in_64b_kernel_mode;
   input logic			in_64b_supervisor_mode;
   input logic			in_64b_user_mode;
   
   input logic 	      flush_req;
   output logic       flush_complete;
   //restart signals
   input logic [`M_WIDTH-1:0] restart_pc;
   input logic [`M_WIDTH-1:0] restart_src_pc;
   input logic 	      restart_src_is_indirect;
   /* Global history, read back over the existing trace-index debug port.
    * ARCH is the RETIRED history (updated at branch retirement); SPEC is the
    * speculative copy the PHT is actually indexed with.  Dumping BOTH lets a
    * capture test whether speculative history was correctly restored after a
    * squash (n_spec_gbl_hist = n_arch_gbl_hist) -- if it was not, later
    * predictions index the wrong PHT entry, which no per-instruction pht_idx
    * can reveal. */
   output logic [63:0]        dbg_arch_hist;
   output logic [63:0]        dbg_spec_hist;
   input logic 	      restart_valid;
   output logic       restart_ack;
   //return stack signals
   input logic 			retire_valid;
   input logic 			retired_call;
   input logic 			retired_ret;

   input logic [4:0] 		retire_reg_ptr;
   input logic [`M_WIDTH-1:0]	retire_reg_data;
   input logic 			retire_reg_valid;

   input logic 			branch_pc_valid;
   input logic [`M_WIDTH-1:0] 		branch_pc;
   
   input logic 			took_branch;
   input logic 			branch_fault;
   
   input logic [`LG_BPU_TBL_SZ-1:0] branch_bpu_idx;

   
   output insn_fetch_t insn;
   output logic insn_valid;
   input logic 	insn_ack;
   
   output 	insn_fetch_t insn_two;
   output logic insn_valid_two;
   input logic 	insn_ack_two;

   input logic 	mem_req_ack;
   output logic mem_req_valid;
   
   localparam L1I_NUM_SETS = 1 << `LG_L1I_NUM_SETS;
   localparam L1I_CL_LEN = 1 << `LG_L1D_CL_LEN;
   localparam L1I_CL_LEN_BITS = 1 << (`LG_L1D_CL_LEN + 3);
   localparam LG_WORDS_PER_CL = `LG_L1D_CL_LEN - 2;
   localparam WORDS_PER_CL = 1<<LG_WORDS_PER_CL;
   localparam IDX_START = `LG_L1D_CL_LEN;
   localparam IDX_STOP  = `LG_L1D_CL_LEN + `LG_L1I_NUM_SETS;
   /* VIPT alias handling (mirrors l1d): take the tag down to LG_PG_SZ so it CARRIES
    * the alias bits VA[12..] that the index uses but translation changes.  Cache <=
    * page (IDX_STOP<=LG_PG_SZ): TAG_LSB==IDX_STOP -> identical to the old tag (no-op).
    * Cache > page: the widened tag makes an aliased VA-indexed fetch MISS, and the
    * fill is VA-indexed (r_miss_pc, below) so the reload re-lookup finds it.  Read-only
    * cache: a synonym just makes a harmless duplicate line at the other index -- no
    * writeback / physical-retry needed (unlike l1d's dirty case). */
   localparam TAG_LSB = (IDX_STOP < `LG_PG_SZ) ? IDX_STOP : `LG_PG_SZ;
   localparam LG_ALIAS_BITS = IDX_STOP - TAG_LSB;   // == max(0, IDX_STOP - LG_PG_SZ)
   localparam N_TAG_BITS = `PA_WIDTH - TAG_LSB;
   localparam WORD_START = 2;
   localparam WORD_STOP = WORD_START+LG_WORDS_PER_CL;
   localparam N_FQ_ENTRIES = 1 << `LG_FQ_ENTRIES;
   localparam RETURN_STACK_ENTRIES = 1 << `LG_RET_STACK_ENTRIES;
   localparam PHT_ENTRIES = 1 << `LG_PHT_SZ;
   localparam BTB_ENTRIES = 1 << `LG_BTB_SZ;

   output logic [(`PA_WIDTH-1):0] mem_req_addr;
   output logic [4:0] 			  mem_req_opcode;
   output logic				  mem_req_cacheable;
   output logic [15:0]			  mem_req_mask;
   
   input logic 				  mem_rsp_valid;
   input logic [L1I_CL_LEN_BITS-1:0] 	  mem_rsp_load_data;
   output logic [63:0] 			  cache_accesses;
   output logic [63:0] 			  cache_hits;
   input logic 				  tlb_entry_in_valid;
   input 				  tlb_data_t tlb_entry_in;
      
   logic [N_TAG_BITS-1:0] 		  t_cache_tag, r_cache_tag, r_tag_out0, r_tag_out1;

   logic 				  r_pht_update;
   /* PHT entry holds FOUR packed 2-bit counters, one per instruction slot in the
    * 16B line (rv64core l1i_2way parity).  Previously one 2-bit counter indexed at
    * 8-byte granularity, so ADJACENT instructions aliased onto the same counter --
    * and, more importantly, only the first slot's prediction was consulted when
    * forming a fetch group, so a not-taken branch anywhere in the line truncated
    * it.  LG_PHT_SZ drops 16->14 to keep total storage identical (2^14 x 8 bits ==
    * 2^16 x 2 bits = 128Kbit); the bits-per-predicted-branch is unchanged at 2. */
   logic [7:0] 				  r_pht_out_vec, r_pht_update_out;
   logic [1:0] 				  t_pht_out;
   logic [7:0] 				  t_pht_val_vec;
   logic [1:0] 				  t_pht_val;
   logic 				  t_do_pht_wr;
   /* per-slot "is a predicted-TAKEN control transfer" */
   logic 				  t_tcb0, t_tcb1, t_tcb2, t_tcb3;
   logic [1:0] 				  r_pht_update_slot;
   logic [1:0] 				  t_pht_old;
   
   logic [`LG_PHT_SZ-1:0] 		  n_pht_idx,r_pht_idx;
   logic [`LG_PHT_SZ-1:0] 		  r_pht_update_idx;
   logic [`LG_PHT_SZ-1:0] 		  t_retire_pht_idx;
   /* branch-predictor update state kept in the front end: every pushed fetch group
    * writes its PHT index here and its insns carry only r_bpu_idx (rv64core 291b0cb).
    * At retire the core hands back branch_bpu_idx and the PHT index is looked up. */
   localparam N_BPU_TBL = 1 << `LG_BPU_TBL_SZ;
   logic [`LG_PHT_SZ-1:0] 		  r_bpu_tbl[N_BPU_TBL-1:0];
   logic [`LG_BPU_TBL_SZ-1:0] 		  r_bpu_idx;
   logic 				  t_bpu_alloc;
   /* per-slot predicted direction: the bimodal/gshare counter MSBs, with the tagged
    * table's slot overridden on a hit */
   logic [3:0] 				  t_pred_vec;
   /* tagged table entry: [16] valid, [15:7] tag, [6:5] slot, [4:2] 3b ctr, [1:0] useful */
   localparam T1_W = 1 + `TAGE_TAG_W + 2 + 3 + 2;
   localparam N_T1 = 1 << `LG_TAGE_SZ;
   logic [`LG_TAGE_SZ-1:0] 		  t_t1_n_idx, r_t1_idx;
   logic [`TAGE_TAG_W-1:0] 		  t_t1_n_tag, r_t1_tag;
   logic [T1_W-1:0] 			  r_t1_out;
   logic 				  t_t1_hit;
   /* per fetch group, in the front end */
   logic [`LG_TAGE_SZ-1:0] 		  r_bpu_t1_idx[N_BPU_TBL-1:0];
   logic [`TAGE_TAG_W-1:0] 		  r_bpu_t1_tag[N_BPU_TBL-1:0];
   logic 				  r_bpu_t1_hit[N_BPU_TBL-1:0];
   logic [T1_W-1:0] 			  r_bpu_t1_ent[N_BPU_TBL-1:0];
   /* retire stage (aligned with r_pht_update_out) */
   logic [`LG_TAGE_SZ-1:0] 		  r_t1u_idx;
   logic [`TAGE_TAG_W-1:0] 		  r_t1u_tag;
   logic 				  r_t1u_hit;
   logic [T1_W-1:0] 			  r_t1u_ent;
   logic 				  t_t1_provider, t_t1_wr;
   logic [T1_W-1:0] 			  t_t1_wr_data;
   logic [2:0] 				  t_t1_ctr;
   logic [1:0] 				  t_t1_u;
   /* T2: same geometry, long (48b) history */
   logic [`LG_TAGE_SZ-1:0] 		  t_t2_n_idx, r_t2_idx;
   logic [`TAGE_TAG_W-1:0] 		  t_t2_n_tag, r_t2_tag;
   logic [T1_W-1:0] 			  r_t2_out;
   logic 				  t_t2_hit;
   logic [`LG_TAGE_SZ-1:0] 		  r_bpu_t2_idx[N_BPU_TBL-1:0];
   logic [`TAGE_TAG_W-1:0] 		  r_bpu_t2_tag[N_BPU_TBL-1:0];
   logic 				  r_bpu_t2_hit[N_BPU_TBL-1:0];
   logic [T1_W-1:0] 			  r_bpu_t2_ent[N_BPU_TBL-1:0];
   logic [`LG_TAGE_SZ-1:0] 		  r_t2u_idx;
   logic [`TAGE_TAG_W-1:0] 		  r_t2u_tag;
   logic 				  r_t2u_hit;
   logic [T1_W-1:0] 			  r_t2u_ent;
   logic 				  t_t2_provider, t_t2_wr;
   logic [T1_W-1:0] 			  t_t2_wr_data;
   logic [2:0] 				  t_t2_ctr;
   logic [1:0] 				  t_t2_u;
   logic 				  t_prov_pred, t_alt_pred, t_t1_free, t_t2_free;
   
   logic 				  r_take_br;
   
   logic [(`M_WIDTH-1):0] 		  r_btb[BTB_ENTRIES-1:0];
   logic [BTB_ENTRIES-1:0] 		  r_btb_valid;
   
   
   logic [(4*WORDS_PER_CL)-1:0] 	  r_jump_out0, r_jump_out1, t_jump_out;
   
   logic [`LG_L1I_NUM_SETS-1:0] 	    t_cache_idx, r_cache_idx;   
   logic [L1I_CL_LEN_BITS-1:0] 		    r_array_out0, r_array_out1, t_array_out;
   logic 				    r_mem_req_valid, n_mem_req_valid;
   logic [(`PA_WIDTH-1):0] r_mem_req_addr, n_mem_req_addr;
   logic				    r_mem_req_cacheable,n_mem_req_cacheable;
   
   

   /* 2-wide fetch queue in two banks: entry i lives in bank i[0] at row i>>1.  The
    * (at most two) pushes per cycle and the two decode reads are always consecutive
    * entries, so each bank sees one write and one read per cycle (1W1R -> LUTRAM). */
   localparam N_FQ_ROWS = N_FQ_ENTRIES/2;
   insn_fetch_t r_fq_b0[N_FQ_ROWS-1:0];
   insn_fetch_t r_fq_b1[N_FQ_ROWS-1:0];
   
   logic [`LG_FQ_ENTRIES:0] r_fq_head_ptr, n_fq_head_ptr;
   logic [`LG_FQ_ENTRIES:0] r_fq_next_head_ptr, n_fq_next_head_ptr;
   logic [`LG_FQ_ENTRIES:0] r_fq_next_tail_ptr, n_fq_next_tail_ptr;
   
   logic [`LG_FQ_ENTRIES:0] r_fq_tail_ptr, n_fq_tail_ptr;
   logic 		    r_resteer_bubble, n_resteer_bubble;
   /* micro-ITLB always-miss: set for the single cycle after WAIT_FOR_TLB primes the
    * JTLB, marking that the registered itlb outputs are valid for r_cache_pc. */
   logic 		    r_itlb_ready, n_itlb_ready;
   /* WAIT_FOR_TLB dwell counter: hold the (fixed-latency) JTLB lookup for the extra
    * cycle the 2-cycle CAM split needs before pa/hit are valid for r_miss_pc. */
   logic [1:0] 		    r_tlb_wait, n_tlb_wait;
   
   
   logic 		    fq_full, fq_next_empty, fq_empty;
   logic 		    fq_full2;
   
   
   logic [(`M_WIDTH-1):0]   r_spec_return_stack [RETURN_STACK_ENTRIES-1:0];
   logic [(`M_WIDTH-1):0]   r_arch_return_stack [RETURN_STACK_ENTRIES-1:0];
   logic [`LG_RET_STACK_ENTRIES-1:0] n_arch_rs_tos, r_arch_rs_tos;
   logic [`LG_RET_STACK_ENTRIES-1:0] n_spec_rs_tos, r_spec_rs_tos, t_next_spec_rs_tos;   
   
   logic [`GBL_HIST_LEN-1:0] 	     n_arch_gbl_hist, r_arch_gbl_hist;
   logic [`GBL_HIST_LEN-1:0] 	     n_spec_gbl_hist, r_spec_gbl_hist;
   assign dbg_arch_hist = {{(64-`GBL_HIST_LEN){1'b0}}, r_arch_gbl_hist};
   assign dbg_spec_hist = {{(64-`GBL_HIST_LEN){1'b0}}, r_spec_gbl_hist};

   logic [`GBL_HIST_LEN-1:0] 	     r_last_spec_gbl_hist;
   

   logic [LG_WORDS_PER_CL-1:0] 	     t_insn_idx;
   
   logic [63:0] 			 n_cache_accesses, r_cache_accesses;
   logic [63:0] 			 n_cache_hits, r_cache_hits;
   
function logic [31:0] select_cl32(logic [L1I_CL_LEN_BITS-1:0] cl, logic[LG_WORDS_PER_CL-1:0] pos);
   logic [31:0] 			 w32;
   case(pos)
     2'd0:
       w32 = cl[31:0];
     2'd1:
       w32 = cl[63:32];
     2'd2:
       w32 = cl[95:64];
     2'd3:
       w32 = cl[127:96];
   endcase // case (pos)
   return w32;
endfunction

function logic [3:0] select_pd(logic [15:0] cl, logic[LG_WORDS_PER_CL-1:0] pos);
   logic [3:0] j;
   case(pos)
     2'd0:
       j = cl[3:0];
     2'd1:
       j = cl[7:4];
     2'd2:
       j = cl[11:8];
     2'd3:
       j = cl[15:12];
   endcase // case (pos)
   return j;
endfunction

   
   typedef enum logic [3:0] {INITIALIZE = 'd0,
			     IDLE = 'd1,
                             ACTIVE = 'd2,
                             INJECT_RELOAD = 'd3,
			     RELOAD_TURNAROUND = 'd4,
                             FLUSH_CACHE = 'd5,
			     WAIT_FOR_NOT_FULL = 'd6,
			     INIT_PHT = 'd7,
			     WAIT_FOR_TLB = 'd8
			    } state_t;
   
   logic [(`M_WIDTH-1):0] r_pc, n_pc, r_miss_pc, n_miss_pc;
   logic [(`M_WIDTH-1):0] r_cache_pc, n_cache_pc;
   logic [(`M_WIDTH-1):0] r_btb_pc;

   wire [`M_WIDTH-1:0]		  w_la_pc;
   logic [`M_WIDTH-1:0]		  r_la_pc, r_tlb_pc;
   wire [`PA_WIDTH-1:0] w_tlb_pc;
   wire [1:0]		  w_seg;
   
   
   wire	       w_cached, w_mapped;
   wire	       w_bad_perms;   /* mipsseg i-side AdEL (access-level / VA out-of-range) */
   reg	       r_cached, r_mapped;
   reg	       r_bad_va;      /* registered w_bad_perms, aligned with r_mapped/r_cache_pc */
   
   
   
   state_t n_state, r_state;
   assign state = r_state;
   
   logic 		  r_restart_req, n_restart_req;
   logic 		  r_restart_ack, n_restart_ack;
   logic 		  r_req, n_req;
   logic 		  r_valid_out0, r_valid_out1;
   /* L1I way select / replacement: r_lru_out = the set's LRU way (read with the arrays),
    * r_fill_way = the way the outstanding reload writes */
   logic 		  r_lru_out, r_fill_way, n_fill_way;
   logic 		  t_lru_wr, t_lru_val;
   logic [`LG_L1I_NUM_SETS-1:0] t_lru_idx;
   logic 		  t_miss, t_hit;
   logic 		  t_push_insn, t_push_insn2;
   
   logic 		  t_clear_fq;
   logic 		  r_flush_req, n_flush_req;
   logic 		  r_flush_complete, n_flush_complete;
   logic 		  n_delay_slot, r_delay_slot;
   logic 		  t_take_br, t_is_cflow;
   logic 		  t_update_spec_hist;
   
   logic [31:0] 	  t_insn_data, t_insn_data2;
   logic [`M_WIDTH-1:0]   t_simm;
   logic 		  t_is_call, t_is_ret;
   logic [2:0] 		  t_branch_cnt;
   logic [4:0] 		  t_branch_marker, t_spec_branch_marker;
   logic [2:0] 		  t_first_branch;
   /* branch pair: a predicted-taken direct branch in slot 1 of the fetch group is
    * pushed together with the insn before it; its delay slot is fetched next */
   logic [3:0] 		  t_gb_pd1;
   logic 		  t_gb_ok1;
   logic 		  t_gb_take1;
   logic [`M_WIDTH-1:0]   t_gb_pc1, t_gb_target1;
   logic [`M_WIDTH-1:0]   t_gb_simm1;

   logic 		  t_init_pht;
   logic [`LG_PHT_SZ-1:0] r_init_pht_idx, n_init_pht_idx;
   

   
   //always_ff@(negedge clk)
   //begin
   //$display("r_cache_pc = %x, t_branch_locs = %b, t_insn_idx = %d, t_branch_marker = %b, first_branch = %d",
   //r_cache_pc,t_branch_locs, t_insn_idx, t_branch_marker, t_first_branch);
   //end
   
   
   localparam SEXT = `M_WIDTH-16;
   insn_fetch_t t_insn, t_insn2;
   logic [3:0] t_pd, r_pd;

   
   logic [63:0] 	  r_cycle;
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : r_cycle + 'd1;
     end


   assign flush_complete = r_flush_complete;
   
   assign insn_valid = !fq_empty;
   assign insn_valid_two = !(fq_next_empty || fq_empty);

   
   assign restart_ack = r_restart_ack;

   assign mem_req_valid = r_mem_req_valid;
   assign mem_req_addr = r_mem_req_addr;
   assign mem_req_opcode = MEM_LW;
   assign mem_req_cacheable = r_mem_req_cacheable;
   assign mem_req_mask = 16'hffff;
   
   assign cache_hits = r_cache_hits;
   assign cache_accesses = r_cache_accesses;
   
   always_comb
     begin
	n_fq_tail_ptr = r_fq_tail_ptr;
	n_fq_head_ptr = r_fq_head_ptr;
	n_fq_next_head_ptr = r_fq_next_head_ptr;
	n_fq_next_tail_ptr = r_fq_next_tail_ptr;
	
	fq_empty = (r_fq_head_ptr == r_fq_tail_ptr);
	fq_next_empty = (r_fq_next_head_ptr == r_fq_tail_ptr);
	
	fq_full = (r_fq_head_ptr != r_fq_tail_ptr) &&
		  (r_fq_head_ptr[`LG_FQ_ENTRIES-1:0] == r_fq_tail_ptr[`LG_FQ_ENTRIES-1:0]);
	
	fq_full2 = (r_fq_head_ptr != r_fq_next_tail_ptr) &&
		   (r_fq_head_ptr[`LG_FQ_ENTRIES-1:0] == r_fq_next_tail_ptr[`LG_FQ_ENTRIES-1:0]) || fq_full;
	
	/* head and next_head are consecutive entries, so they sit in opposite banks */
	insn = r_fq_head_ptr[0] ? r_fq_b1[r_fq_head_ptr[`LG_FQ_ENTRIES-1:1]] :
	       r_fq_b0[r_fq_head_ptr[`LG_FQ_ENTRIES-1:1]];
	insn_two = r_fq_next_head_ptr[0] ? r_fq_b1[r_fq_next_head_ptr[`LG_FQ_ENTRIES-1:1]] :
		   r_fq_b0[r_fq_next_head_ptr[`LG_FQ_ENTRIES-1:1]];

	if(t_push_insn2)
	  begin
	     n_fq_tail_ptr = r_fq_tail_ptr + 'd2;
	     n_fq_next_tail_ptr = r_fq_next_tail_ptr + 'd2;
	  end
	else if(t_push_insn)
	  begin
	     n_fq_tail_ptr = r_fq_tail_ptr + 'd1;
	     n_fq_next_tail_ptr = r_fq_next_tail_ptr + 'd1;
	  end
	
	if(insn_ack && !insn_ack_two)
	  begin
	     n_fq_head_ptr = r_fq_head_ptr + 'd1;
	     n_fq_next_head_ptr = r_fq_next_head_ptr + 'd1;
	  end
	else if(insn_ack && insn_ack_two)
	  begin
	     n_fq_head_ptr = r_fq_head_ptr + 'd2;
	     n_fq_next_head_ptr = r_fq_next_head_ptr + 'd2;
	  end
     end // always_comb

   /* bank write port: the tail entry goes to bank tail[0]; a second push goes to
    * the other bank at next_tail's row */
   logic 		  t_fq_wr0, t_fq_wr1;
   logic [`LG_FQ_ENTRIES-2:0] t_fq_wr_row0, t_fq_wr_row1;
   insn_fetch_t t_fq_wr_data0, t_fq_wr_data1;
   always_comb
     begin
	t_fq_wr0 = 1'b0;
	t_fq_wr1 = 1'b0;
	t_fq_wr_row0 = r_fq_tail_ptr[`LG_FQ_ENTRIES-1:1];
	t_fq_wr_row1 = r_fq_tail_ptr[`LG_FQ_ENTRIES-1:1];
	t_fq_wr_data0 = t_insn;
	t_fq_wr_data1 = t_insn;
	if(t_push_insn | t_push_insn2)
	  begin
	     if(r_fq_tail_ptr[0])
	       begin
		  t_fq_wr1 = 1'b1;
		  t_fq_wr_row1 = r_fq_tail_ptr[`LG_FQ_ENTRIES-1:1];
		  t_fq_wr_data1 = t_insn;
		  t_fq_wr0 = t_push_insn2;
		  t_fq_wr_row0 = r_fq_next_tail_ptr[`LG_FQ_ENTRIES-1:1];
		  t_fq_wr_data0 = t_insn2;
	       end
	     else
	       begin
		  t_fq_wr0 = 1'b1;
		  t_fq_wr_row0 = r_fq_tail_ptr[`LG_FQ_ENTRIES-1:1];
		  t_fq_wr_data0 = t_insn;
		  t_fq_wr1 = t_push_insn2;
		  t_fq_wr_row1 = r_fq_next_tail_ptr[`LG_FQ_ENTRIES-1:1];
		  t_fq_wr_data1 = t_insn2;
	       end
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(t_fq_wr0)
	  begin
	     r_fq_b0[t_fq_wr_row0] <= t_fq_wr_data0;
	  end
	if(t_fq_wr1)
	  begin
	     r_fq_b1[t_fq_wr_row1] <= t_fq_wr_data1;
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	if(reset) 
	  begin
	     r_btb_valid <= 'd0;
	  end
	else if(restart_valid && restart_src_is_indirect)
	  begin
	     r_btb_valid[restart_src_pc[(`LG_BTB_SZ+1):2]] <= 1'b1;
	  end
     end // always_ff@ (posedge clk)

   
   always_ff@(posedge clk)
     begin
	if(restart_valid && restart_src_is_indirect)
	  begin
	     r_btb[restart_src_pc[(`LG_BTB_SZ+1):2]] <= restart_pc;
	  end	
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	/* cold/invalid entry -> POISON, not zero: see BTB_POISON_PC in machine.vh */
	r_btb_pc <= reset ? `BTB_POISON_PC : 
		    r_btb_valid[n_cache_pc[(`LG_BTB_SZ+1):2]] ? r_btb[n_cache_pc[(`LG_BTB_SZ+1):2]] : `BTB_POISON_PC;
	
     end


   mipsseg seg0 (
		 .v_addr(n_cache_pc),
		 .l_addr(w_la_pc),
		 .cache(w_cached),
		 .mapped(w_mapped),
		 .seg(w_seg),
		 .bad_perms(w_bad_perms),    /* i-side AdEL: harvested below into r_bad_va */
		 .in_kernel_mode(in_kernel_mode),
		 .in_supervisor_mode(in_supervisor_mode),
		 .in_user_mode(in_user_mode),
		 .in_64b_kernel_mode(in_64b_kernel_mode),
		 .in_64b_supervisor_mode(in_64b_supervisor_mode),
		 .in_64b_user_mode(in_64b_user_mode)
		 );

   /* I-side TLB: translates kuseg/kseg2 fetch addresses */
   wire [`PA_WIDTH-1:0] w_itlb_pa;
   wire 		w_itlb_hit;
   wire 		w_itlb_valid;   /* V bit of matched page */

   /* micro-ITLB fast path: combinational lookup (w_ufast_*, aligned to w_la_pc =
    * seg(n_cache_pc)), registered to r_ufast_* to line up with r_cache_pc/r_mapped
    * one stage later.  install_en re-loads the micro-TLB from the 48-way when a
    * prime lands a hit (r_itlb_ready & w_itlb_hit). */
   wire 		w_ufast_hit, w_ufast_valid;
   wire [`PA_WIDTH-1:0] w_ufast_pa;
   logic 		r_ufast_hit, r_ufast_valid;
   logic [`PA_WIDTH-1:0] r_ufast_pa;
   wire 		w_itlb_install = r_itlb_ready & w_itlb_hit;

   itlb u_itlb (
		       .clk(clk),
		       .reset(reset),
		       .asid(asid),
		       .active(w_mapped),
		       .req(1'b1),
		       .va(w_la_pc),
		       .pa(w_itlb_pa),
		       .hit(w_itlb_hit),
		       .hit_index(),
		       .dirty(),
		       .valid(w_itlb_valid),
		       .cache_attr(),     /* i-side cacheability unused (i-fetch cached) */
		       .out_of_range(),   /* i-side address-error: TODO (d-side first) */
		       .tlb_entry_in_valid(tlb_entry_in_valid),
		       .tlb_entry_in(tlb_entry_in),
		       .install_en(w_itlb_install),
		       .ufast_hit(w_ufast_hit),
		       .ufast_pa(w_ufast_pa),
		       .ufast_valid(w_ufast_valid)
		       );

   always@(posedge clk)
     begin
	r_tlb_pc <= reset ? 'd0 : w_la_pc;
	r_la_pc <= reset ? 'd0 : w_la_pc;
	r_cached <= reset ? 1'b0 : w_cached;
	r_mapped <= reset ? 1'b0 : w_mapped;
	r_bad_va <= reset ? 1'b0 : w_bad_perms;
     end

   /* register the micro-TLB lookup one stage so it aligns with r_cache_pc/r_mapped */
   always_ff@(posedge clk)
     begin
	r_ufast_hit   <= reset ? 1'b0 : w_ufast_hit;
	r_ufast_valid <= reset ? 1'b0 : w_ufast_valid;
	r_ufast_pa    <= reset ? 'd0  : w_ufast_pa;
     end

   /* effective (source-agnostic) itlb result: a micro-TLB hit short-circuits the
    * 48-way so the consume/fault logic below is oblivious to which supplied the PA. */
   wire 		w_eff_hit   = w_itlb_hit | r_ufast_hit;
   wire 		w_eff_valid = r_ufast_hit ? r_ufast_valid : w_itlb_valid;
   wire [`PA_WIDTH-1:0] w_eff_pa = r_ufast_hit ? r_ufast_pa : w_itlb_pa;

   /* For mapped (kuseg) addresses use TLB-translated PA; unmapped uses mipsseg output directly */
   assign w_tlb_pc = (r_mapped && w_eff_hit) ? w_eff_pa : r_la_pc[`PA_WIDTH-1:0];
   
   wire w_hit0 = r_valid_out0 & (r_tag_out0 == w_tlb_pc[(`PA_WIDTH-1):TAG_LSB]);
   wire w_hit1 = r_valid_out1 & (r_tag_out1 == w_tlb_pc[(`PA_WIDTH-1):TAG_LSB]);
   always_comb
     begin
	t_array_out = w_hit1 ? r_array_out1 : r_array_out0;
	t_jump_out = w_hit1 ? r_jump_out1 : r_jump_out0;
     end
   //always@(negedge clk)
   //begin
   //if(r_req)
   //begin
   //$display("w_tlb_pc %x, hit %b, r_cache_tag %x",
   //w_tlb_pc[31:IDX_STOP], w_hit, r_cache_tag);
   //
   //
   //end
   //end
   always_comb
     begin
	n_pc = r_pc;
	n_miss_pc = r_miss_pc;
	n_fill_way = r_fill_way;
	n_cache_pc = 'd0;
	n_state = r_state;
	n_restart_ack = 1'b0;
	n_flush_req = r_flush_req | flush_req;
	n_flush_complete = 1'b0;
	n_delay_slot = r_delay_slot;
	t_cache_idx = 'd0;
	t_cache_tag = 'd0;
	n_req = 1'b0;
	n_mem_req_valid = 1'b0;
	n_mem_req_addr = r_mem_req_addr;
	n_mem_req_cacheable = r_mem_req_cacheable;
	
	n_resteer_bubble = 1'b0;
	n_itlb_ready = 1'b0;   /* 1 only for the cycle after WAIT_FOR_TLB primes */
	n_tlb_wait = r_tlb_wait;
	t_next_spec_rs_tos = r_spec_rs_tos+'d1;
	n_restart_req = restart_valid | r_restart_req;

	/* I-TLB fault: mapped address with no TLB entry (refill) or V=0 (invalid).
	 * In these cases suppress normal cache hit/miss — the pipeline will take
	 * an ITLB exception instead of trying to fetch from memory. */
	if(r_mapped && !(w_eff_hit && w_eff_valid))
	  begin
	     t_miss = 1'b0;
	     t_hit  = 1'b0;
	  end
	else
	  begin
	     t_miss = r_req & !(w_hit0 | w_hit1);
	     t_hit  = r_req & (w_hit0 | w_hit1);
	  end

	t_insn_idx = r_cache_pc[WORD_STOP-1:WORD_START];
	
	t_pd = select_pd(t_jump_out, t_insn_idx);

	t_insn_data  = select_cl32(t_array_out, t_insn_idx);
	t_insn_data2 = select_cl32(t_array_out, t_insn_idx + 2'd1);


	t_branch_marker = {1'b1,
			   select_pd(t_jump_out, 'd3) != 4'd0,
                           select_pd(t_jump_out, 'd2) != 4'd0,
                           select_pd(t_jump_out, 'd1) != 4'd0,
                           select_pd(t_jump_out, 'd0) != 4'd0
                           } >> t_insn_idx;

	/* the 2-bit counter for the instruction actually being fetched */
	/* only the MSB (the direction) is consumed; the LSB stays the bimodal's */
	t_pht_out = (t_insn_idx == 2'd0) ? {t_pred_vec[0], r_pht_out_vec[0]} :
		    (t_insn_idx == 2'd1) ? {t_pred_vec[1], r_pht_out_vec[2]} :
		    (t_insn_idx == 2'd2) ? {t_pred_vec[2], r_pht_out_vec[4]} :
		    {t_pred_vec[3], r_pht_out_vec[6]};

	/* Predicted-TAKEN per slot: a conditional branch (pd==1) predicted not-taken
	 * does NOT end the fetch group, and neither does a non-branch.  This is the
	 * whole point -- the old marker used (pd != 0), so ~7-8% of instructions
	 * (not-taken conditional branches) truncated a group for no reason. */
	t_tcb0 = ~((((select_pd(t_jump_out, 'd0) == 4'd1) & ~t_pred_vec[0]) |
		    (select_pd(t_jump_out, 'd0) == 4'd0)));
	t_tcb1 = ~((((select_pd(t_jump_out, 'd1) == 4'd1) & ~t_pred_vec[1]) |
		    (select_pd(t_jump_out, 'd1) == 4'd0)));
	t_tcb2 = ~((((select_pd(t_jump_out, 'd2) == 4'd1) & ~t_pred_vec[2]) |
		    (select_pd(t_jump_out, 'd2) == 4'd0)));
	t_tcb3 = ~((((select_pd(t_jump_out, 'd3) == 4'd1) & ~t_pred_vec[3]) |
		    (select_pd(t_jump_out, 'd3) == 4'd0)));

	t_spec_branch_marker = ({1'b1, t_tcb3, t_tcb2, t_tcb1, t_tcb0} >> t_insn_idx);

	
	t_first_branch = 'd7;
	casez(t_spec_branch_marker)
	  5'b????1:
	    t_first_branch = 'd0;
	  5'b???10:
	    t_first_branch = 'd1;
	  5'b??100:
	    t_first_branch = 'd2;
	  5'b?1000:
	    t_first_branch = 'd3;
	  5'b10000:
	    t_first_branch = 'd4;
	  default:
	    t_first_branch = 'd7;
	endcase

	/* branch pair: the first predicted-taken insn is slot 1 (relative to
	 * t_insn_idx) and is a direct branch -- conditional (1, predicted taken by
	 * the same counter t_tcb* used), likely (2), j (3), b (8).  Calls (5/9)
	 * push the return stack with their own pc and BTB/return targets (4/6/7)
	 * are looked up for the head slot, so those keep the branch-alone path.
	 * [slot 0, branch] are pushed together; the delay slot (next 16B line when
	 * idx == 2) is fetched sequentially next cycle, then the target. */
	t_gb_pd1 = select_pd(t_jump_out, t_insn_idx + 2'd1);
	t_gb_pc1 = r_cache_pc + 'd4;
	t_gb_simm1 = {{SEXT{t_insn_data2[15]}},t_insn_data2[15:0]};
	t_gb_target1 = (t_gb_pd1 == 4'd3) ? {t_gb_pc1[`M_WIDTH-1:28], t_insn_data2[25:0], 2'd0} :
		       ((t_gb_pc1 + 'd4) + {t_gb_simm1[`M_WIDTH-3:0], 2'd0});
	t_gb_ok1 = (t_first_branch == 'd1) && (t_insn_idx <= 2'd2) && !fq_full2 &&
		   ((t_gb_pd1 == 4'd1) || (t_gb_pd1 == 4'd2) || (t_gb_pd1 == 4'd3) || (t_gb_pd1 == 4'd8));

	t_branch_cnt = {2'd0, select_pd(t_jump_out, 'd0) != 4'd0} +
		       {2'd0, select_pd(t_jump_out, 'd1) != 4'd0} +
		       {2'd0, select_pd(t_jump_out, 'd2) != 4'd0} +
		       {2'd0, select_pd(t_jump_out, 'd3) != 4'd0};
	
		
	t_simm = {{SEXT{t_insn_data[15]}},t_insn_data[15:0]};
	t_clear_fq = 1'b0;
	t_push_insn = 1'b0;
	t_push_insn2 = 1'b0;
	t_take_br = 1'b0;
	t_is_cflow = 1'b0;
	t_gb_take1 = 1'b0;
	t_update_spec_hist = 1'b0;
	t_is_call = 1'b0;
	t_is_ret = 1'b0;
	t_init_pht = 1'b0;
	n_init_pht_idx = r_init_pht_idx;
	
	case(r_state)
	  INITIALIZE:
	    begin
	       n_state = INIT_PHT;
	    end
	  INIT_PHT:
	    begin
	       t_init_pht = 1'b1;
	       n_init_pht_idx = r_init_pht_idx + 'd1;
	       if(r_init_pht_idx == (PHT_ENTRIES-1))
		 begin
		    n_state = FLUSH_CACHE;	       
		    t_cache_idx = 0;
		 end
	    end
	  IDLE:
	    begin
	       if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_pc = restart_pc;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		 end
	    end	  
	  ACTIVE:
	    begin
	       t_cache_idx = r_pc[IDX_STOP-1:IDX_START];
	       t_cache_tag = r_pc[(`PA_WIDTH-1):TAG_LSB];
	       /* accessed with this address */
	       n_cache_pc = r_pc;
	       n_req = 1'b1;
	       n_pc = r_pc + 'd4;
	       if(r_resteer_bubble)
		 begin
		    //do nothing?
		 end
	       else if(n_flush_req)
		 begin
		    n_flush_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = 0;
		 end
	       else if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_delay_slot = 1'b0;
		    n_pc = restart_pc;
		    n_req = 1'b0;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		 end // if (n_restart_req)
	       else if(r_req && r_mapped && !r_itlb_ready && !r_ufast_hit)
		 begin
		    /* MICRO-ITLB always-miss: this mapped fetch's translation is not yet
		     * primed.  Go prime the (2-cycle) JTLB in WAIT_FOR_TLB, holding
		     * va = r_cache_pc's translation.  r_pc (may be a branch target for a
		     * delay-slot fetch) is preserved so the fetch stream resumes correctly.
		     * On return r_itlb_ready=1 and the normal consume runs with the now-
		     * valid registered itlb outputs. */
		    n_pc = r_pc;
		    n_miss_pc = r_cache_pc;
		    n_tlb_wait = 2'd0;
		    n_state = WAIT_FOR_TLB;
		 end
	       else if(r_req && r_cache_pc[1:0] != 2'b00 && !fq_full)
		 begin
		    t_push_insn = 1'b1;
		    n_pc = r_cache_pc + 'd4;
		 end
	       else if(r_req && r_cache_pc[1:0] != 2'b00 && fq_full)
		 begin
		    n_pc = r_pc;
		    n_miss_pc = r_cache_pc;
		    n_state = WAIT_FOR_NOT_FULL;
		 end
	       else if(r_req && r_mapped && !(w_eff_hit && w_eff_valid) && !fq_full)
		 begin
		    t_push_insn = 1'b1;
		    n_pc = r_cache_pc + 'd4;
		 end
	       else if(r_req && r_mapped && !(w_eff_hit && w_eff_valid) && fq_full)
		 begin
		    n_pc = r_pc;
		    n_miss_pc = r_cache_pc;
		    n_state = WAIT_FOR_NOT_FULL;
		 end
	       else if(t_miss)
		 begin
		    n_state = INJECT_RELOAD;
		    n_mem_req_addr = {w_tlb_pc[`PA_WIDTH-1:`LG_L1D_CL_LEN],
				      {`LG_L1D_CL_LEN{1'b0}}};
		    n_mem_req_cacheable = r_cached;
		    n_mem_req_valid = 1'b1;
		    n_miss_pc = r_cache_pc;
		    n_pc = r_pc;
		    /* victim: an invalid way first, else the set's LRU way */
		    n_fill_way = !r_valid_out0 ? 1'b0 : !r_valid_out1 ? 1'b1 : r_lru_out;
		 end
	       else if(t_hit && !fq_full)
		 begin
		    t_update_spec_hist = (t_pd != 4'd0);
		    if(t_pd == 4'd5 || t_pd == 4'd3)
		      begin
			 t_is_cflow = 1'b1;
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 t_is_call = (t_pd == 4'd5);
			 //if(t_is_call) $display("predict jal at %x will return to %x",
			 //r_cache_pc, r_cache_pc+'d8);
			 n_pc = {r_cache_pc[`M_WIDTH-1:28], t_insn_data[25:0], 2'd0};
		      end
		    else if(t_pd == 4'd8)
		      begin
			 t_is_cflow = 1'b1;			 
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 n_pc = ((r_cache_pc + 'd4) + {t_simm[`M_WIDTH-3:0], 2'd0});
		      end
		    else if(t_pd == 4'd2)
		      begin
			 //$display("decoded likely branch @ %x", r_cache_pc);
			 //treat as always taken for simplicity
			 t_is_cflow = 1'b1;			 
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 n_pc = ((r_cache_pc + 'd4) + {t_simm[`M_WIDTH-3:0], 2'd0});
		      end
		    else if(t_pd == 4'd9)
		      begin
			 /* REGIMM branch-and-link: rt 16 BLTZAL / 17 BGEZAL / 18 BLTZALL /
			  * 19 BGEZALL.  The rs==$zero shortcut below means "this is the
			  * unconditional-call idiom, always taken" -- but that is only true
			  * for the BGEZ-flavours (rs>=0).  For the BLTZ-flavours rs<0 is
			  * NEVER true when rs==$zero, so predicting them taken would be
			  * exactly backwards.  rt bit0 (insn[16]) selects: 1 = BGEZ-type,
			  * 0 = BLTZ-type. */
			 if(t_pht_out[1] || (t_insn_data[16] && t_insn_data[25:21] == 5'd0))
			   begin
			      t_is_cflow = 1'b1;
			      n_delay_slot = 1'b1;			      
			      n_pc = ((r_cache_pc + 'd4) + {t_simm[`M_WIDTH-3:0], 2'd0});
			      t_is_call = 1'b1;
			      t_take_br = 1'b1;
			      //$display("some flavor of branch and link, predicting target %x", n_pc);
			   end
		      end
		    else if(t_pd == 4'd1 && t_pht_out[1])
		      begin
			 t_is_cflow = 1'b1;			 
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 n_pc = ((r_cache_pc + 'd4) + {t_simm[`M_WIDTH-3:0], 2'd0});
			 //if(t_insn_idx != 'd3 && !fq_full2)
			 //begin
			 //t_push_insn2 = 1'b1;
			 //n_resteer_bubble = 1'b1;
			 //n_delay_slot = 1'b0;
			 // end
		      end
		    else if(t_pd == 4'd7)
		      begin
			 t_is_cflow = 1'b1;
			 t_is_ret = 1'b1;
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 n_pc = r_spec_return_stack[t_next_spec_rs_tos];
		      end // if (t_pd == 4'd7)
		    else if(t_pd == 4'd4 || t_pd == 4'd6)
		      begin
			 t_is_cflow = 1'b1;			 
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 t_is_call = (t_pd == 4'd6);
			 n_pc = r_btb_pc;
			 //$display("predicted target for %x is %x", r_cache_pc, n_pc);			 
		      end
		    
		    if(r_delay_slot)
		      begin
			 n_delay_slot = 1'b0;
		      end
		    
		    //initial push multiple logic
		    if(!(t_is_cflow || r_delay_slot))
		      begin
			 /* the array was read sequentially this cycle, so the target
			  * costs one resteer bubble (vs. two single-insn cycles for
			  * the branch and its delay slot on the branch-alone path) */
			 if(t_gb_ok1)
			   begin
			      /* [slot 0, taken branch]: fetch the delay slot next, then the
			       * target (r_pc), exactly as the branch-alone path does */
			      t_push_insn2 = 1'b1;
			      t_gb_take1 = 1'b1;
			      t_update_spec_hist = 1'b1;
			      n_delay_slot = 1'b1;
			      n_cache_pc = r_cache_pc + 'd8;
			      t_cache_tag = n_cache_pc[(`PA_WIDTH-1):TAG_LSB];
			      n_pc = t_gb_target1;
			      if(t_insn_idx == 2'd2)
				begin
				   t_cache_idx = r_cache_idx + 'd1;
				end
			   end
			 else if(t_first_branch >= 'd2 && !fq_full2)
			   begin
			      /* two sequential insns (no predicted-taken cflow among them);
			       * idx <= 2 here since the 16B line end bounds t_first_branch */
			      t_push_insn2 = 1'b1;
			      n_cache_pc = r_cache_pc + 'd8;
			      t_cache_tag = n_cache_pc[(`PA_WIDTH-1):TAG_LSB];
			      n_pc = r_cache_pc + 'd12;
			      if(t_insn_idx == 2'd2)
				begin
				   t_cache_idx = r_cache_idx + 'd1;
				end
			   end
			 else
			   begin
			      t_push_insn = 1'b1;
			   end
		      end // if (!(t_is_cflow || r_delay_slot))
		    //else if(t_is_cflow && !r_delay_slot && t_insn_idx != 'd3 && !fq_full2)
		    //begin
		    //branch delay slot is on the same cacheline
		    //end
		    else
		      begin
			 t_push_insn = 1'b1;
		      end
		 end // if (t_hit && !fq_full)
	       else if(t_hit && fq_full)
		 begin
		    //$display("full insn queue at cycle %d", r_cycle);
		    n_pc = r_pc;
		    n_miss_pc = r_cache_pc;
		    n_state = WAIT_FOR_NOT_FULL;
		 end
	    end
	  INJECT_RELOAD:
	    begin
	       if(mem_rsp_valid)
		 begin
		    n_state = RELOAD_TURNAROUND;
		 end
	    end
	  RELOAD_TURNAROUND:
	    begin
	       t_cache_idx = r_miss_pc[IDX_STOP-1:IDX_START];
	       t_cache_tag = r_miss_pc[(`PA_WIDTH-1):TAG_LSB];
	       if(n_flush_req)
		 begin
		    n_flush_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = 0;
		 end
	       else if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_delay_slot = 1'b0;
		    n_pc = restart_pc;
		    n_req = 1'b0;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		 end // if (n_restart_req)
	       else if(!fq_full)
		 begin
		    /* accessed with this address */
		    n_cache_pc = r_miss_pc;
		    n_req = 1'b1;
		    n_state = ACTIVE;
		 end
	    end
	  FLUSH_CACHE:
	    begin
	       if(r_cache_idx == (L1I_NUM_SETS-1))
		 begin
		    //$display("REQ FLUSHING COMPLETE at %d", r_cycle);
		    n_flush_complete = 1'b1;
		    n_state = IDLE;
		 end
	       t_cache_idx = r_cache_idx + 'd1;
	    end
	  WAIT_FOR_NOT_FULL:
	    begin
	       t_cache_idx = r_miss_pc[IDX_STOP-1:IDX_START];
	       t_cache_tag = r_miss_pc[(`PA_WIDTH-1):TAG_LSB];
	       n_cache_pc = r_miss_pc;
	       if(!fq_full)
		 begin
		    n_req = 1'b1;
		    n_state = ACTIVE;
		 end
	       else if(n_flush_req)
		 begin
		    n_flush_req = 1'b0;
		    //n_flush_complete = 1'b1;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = 0;		    
		 end
	       else if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_delay_slot = 1'b0;
		    n_pc = restart_pc;
		    n_req = 1'b0;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		 end // if (n_restart_req)
	    end
	  WAIT_FOR_TLB:
	    begin
	       /* MICRO-ITLB always-miss prime: re-present r_miss_pc so the itlb holds
	        * va = its translation for the 2 cycles the JTLB CAM needs; hold r_pc
	        * (the post-fetch PC / branch target).  When the JTLB has settled
	        * (!w_itlb_busy) return to ACTIVE with r_itlb_ready=1 so the normal
	        * consume runs against the now-valid registered itlb outputs. */
	       t_cache_idx = r_miss_pc[IDX_STOP-1:IDX_START];
	       t_cache_tag = r_miss_pc[(`PA_WIDTH-1):TAG_LSB];
	       n_cache_pc = r_miss_pc;
	       n_pc = r_pc;
	       n_req = 1'b1;
	       if(n_flush_req)
		 begin
		    n_flush_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = 0;
		 end
	       else if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_delay_slot = 1'b0;
		    n_pc = restart_pc;
		    n_req = 1'b0;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		 end
	       else if(r_tlb_wait == 2'd2)
		 begin
		    /* JTLB has had its 2 settle cycles with va held -> pa/hit valid for
		     * r_miss_pc; hand back to ACTIVE with r_itlb_ready=1 to consume it. */
		    n_itlb_ready = 1'b1;
		    n_state = ACTIVE;
		 end
	       else
		 begin
		    n_tlb_wait = r_tlb_wait + 2'd1;
		 end
	    end
	  default:
	    begin
	    end
	endcase // case (r_state)
     end // always_comb

   always_comb
     begin
	n_cache_accesses = r_cache_accesses;
	n_cache_hits = r_cache_hits;	
	if(t_hit)
	  begin
	     n_cache_hits = r_cache_hits + 'd1;
	  end
	if(r_req)
	  begin
	     n_cache_accesses = r_cache_accesses + 'd1;
	  end
     end
   
   always_comb
     begin
	t_insn.data = t_insn_data;
	t_insn.misaligned  = r_req & (r_cache_pc[1:0] != 2'b00);
	t_insn.tlb_miss    = r_mapped & r_req & !w_eff_hit & (r_cache_pc[1:0] == 2'b00);
	t_insn.tlb_invalid = r_mapped & r_req &  w_eff_hit & !w_eff_valid;
	t_insn.bad_va      = r_req & r_bad_va;   /* AdEL; decode prioritizes over tlb_miss */
	t_insn.pc = r_cache_pc;
	t_insn.pred_target = n_pc;
	t_insn.pred = t_take_br;
	t_insn.bpu_idx = r_bpu_idx;
	t_insn.is_branch = (t_pd != 4'd0);
`ifdef	ENABLE_CYCLE_ACCOUNTING
	t_insn.fetch_cycle = r_cycle;
`endif
	t_insn2.data = t_insn_data2;
	t_insn2.misaligned = 1'b0;
	t_insn2.tlb_miss = 1'b0;
	t_insn2.tlb_invalid = 1'b0;
	t_insn2.bad_va = 1'b0;
	t_insn2.pc = r_cache_pc + 'd4;
	t_insn2.pred_target = t_gb_take1 ? n_pc : 'd0;
	t_insn2.pred = t_gb_take1;
	/* same 16B line as slot 0 -> SAME PHT entry (the slot is disambiguated at
	 * retire by branch_pc[3:2]).  Was 'd0: harmless while the fetch group
	 * truncated at any branch (slots 2-4 could never BE branches), but with
	 * predicted-taken grouping they can, and they then trained entry 0 -- 2.85
	 * -> 18.8 mispredicts/kiloinsn. */
	t_insn2.bpu_idx = r_bpu_idx;
	t_insn2.is_branch = (select_pd(t_jump_out, t_insn_idx + 2'd1) != 4'd0);
`ifdef	ENABLE_CYCLE_ACCOUNTING
	t_insn2.fetch_cycle = r_cycle;
`endif
     end // always_comb
   
   logic t_wr_valid_ram_en0, t_wr_valid_ram_en1, t_valid_ram_value;
   logic [`LG_L1I_NUM_SETS-1:0] t_valid_ram_idx;

   
   compute_pht_idx cpi0 (.pc(n_cache_pc), .idx(n_pht_idx));

   always_comb
     begin
	t_pred_vec = {r_pht_out_vec[7], r_pht_out_vec[5], r_pht_out_vec[3], r_pht_out_vec[1]};
	/* tagged table: index/tag from the same pc + history the PHT index uses, so the
	 * registered read lines up with r_cache_pc.  Fold is written for 16b history,
	 * 10b index, 9b tag. */
	t_t1_n_idx = n_cache_pc[`LG_TAGE_SZ+3:4] ^ r_spec_gbl_hist[9:0] ^ {4'd0, r_spec_gbl_hist[15:10]};
	t_t1_n_tag = n_cache_pc[`LG_TAGE_SZ+`TAGE_TAG_W+3:`LG_TAGE_SZ+4] ^ r_spec_gbl_hist[15:7] ^
		     {r_spec_gbl_hist[6:0], 2'd0};
	/* T2 folds all 48 history bits (5 index chunks, 6 tag chunks, offset) */
	t_t2_n_idx = n_cache_pc[`LG_TAGE_SZ+3:4] ^ r_spec_gbl_hist[9:0] ^ r_spec_gbl_hist[19:10] ^
		     r_spec_gbl_hist[29:20] ^ r_spec_gbl_hist[39:30] ^ {2'd0, r_spec_gbl_hist[47:40]};
	t_t2_n_tag = n_cache_pc[`LG_TAGE_SZ+`TAGE_TAG_W+3:`LG_TAGE_SZ+4] ^ r_spec_gbl_hist[47:39] ^
		     r_spec_gbl_hist[38:30] ^ r_spec_gbl_hist[29:21] ^ r_spec_gbl_hist[20:12] ^
		     r_spec_gbl_hist[11:3] ^ {r_spec_gbl_hist[2:0], 6'd0};
	t_t1_hit = r_t1_out[16] && (r_t1_out[15:7] == r_t1_tag);
	t_t2_hit = r_t2_out[16] && (r_t2_out[15:7] == r_t2_tag);
	if(t_t1_hit)
	  begin
	     t_pred_vec[r_t1_out[6:5]] = r_t1_out[4];
	  end
	/* longest matching history wins its slot */
	if(t_t2_hit)
	  begin
	     t_pred_vec[r_t2_out[6:5]] = r_t2_out[4];
	  end
     end

   

   always_comb
     begin
	t_retire_pht_idx = r_bpu_tbl[branch_bpu_idx];
     end

   
   always_comb
     begin
	t_wr_valid_ram_en0 = (mem_rsp_valid && !r_fill_way) || r_state == FLUSH_CACHE;
	t_wr_valid_ram_en1 = (mem_rsp_valid && r_fill_way) || r_state == FLUSH_CACHE;
	t_valid_ram_value = (r_state != FLUSH_CACHE);
	t_valid_ram_idx = mem_rsp_valid ? r_miss_pc[IDX_STOP-1:IDX_START] : r_cache_idx;
     end

      
     // always_ff@(negedge clk)
     //   begin
     // 	  if((t_push_insn | t_push_insn2 | t_push_insn3 | t_push_insn4) && (t_pd != 'd0))
     // 	    begin
     // 	       $display("spec %x : cycle %d n_pht_idx = %d, hist = %b, pred = %b",
     // 			t_insn.pc, r_cycle, t_insn.pht_idx, r_last_spec_gbl_hist, t_insn.pred);
     // 	    end
     // 	  if(branch_pc_valid)
     // 	    begin
     // 	       $display("arch %x : cycle %d n_pht_idx = %d, hist = %b, took branch %b, mispred %b, comp_pht %d", 
     // 			branch_pc, r_cycle, branch_pht_idx, n_arch_gbl_hist, took_branch, branch_fault, t_retire_pht_idx);
     // 	    end
     //   end
   
   always_comb
     begin
	/* read-modify-write: the retiring branch updates only ITS 2-bit field and the
	 * other three counters in the entry are written back unchanged. */
	t_pht_old = (r_pht_update_slot == 2'd0) ? r_pht_update_out[1:0] :
		    (r_pht_update_slot == 2'd1) ? r_pht_update_out[3:2] :
		    (r_pht_update_slot == 2'd2) ? r_pht_update_out[5:4] :
		    r_pht_update_out[7:6];
	t_pht_val = t_pht_old;
	t_do_pht_wr = r_pht_update;

	case(t_pht_old)
	  2'd0:
	    begin
	       if(r_take_br)
		 begin
		    t_pht_val =  2'd1;
		 end
	       else
		 begin
		    t_do_pht_wr = 1'b0;
		 end
	    end
	  2'd1:
	    begin
	       t_pht_val = r_take_br ? 2'd2 : 2'd0;
	    end
	  2'd2:
	    begin
	       t_pht_val = r_take_br ? 2'd3 : 2'd1;
	    end
	  2'd3:
	    begin
	       if(!r_take_br)
		 begin
		    t_pht_val = 2'd2;
		 end
	       else
		 begin
		    t_do_pht_wr = 1'b0;
		 end
	    end
	endcase // case (t_pht_old)

	/* splice the updated counter back into its slot, leaving the other three */
	t_pht_val_vec = (r_pht_update_slot == 2'd0) ? {r_pht_update_out[7:2], t_pht_val} :
			(r_pht_update_slot == 2'd1) ? {r_pht_update_out[7:4], t_pht_val, r_pht_update_out[1:0]} :
			(r_pht_update_slot == 2'd2) ? {r_pht_update_out[7:6], t_pht_val, r_pht_update_out[3:0]} :
			{t_pht_val, r_pht_update_out[5:0]};
	/* tagged-table update, from the fetch-time copies of the entries (blind writes:
	 * no read at retire).  Provider = the longest table that hit for this branch's
	 * slot (T2, then T1), else the bimodal; alt = the next shorter one.  Only the
	 * provider trains.  A provider mispredict allocates in the first longer table
	 * whose entry is free (!valid || u == 0), else ages every longer candidate. */
	t_t2_provider = r_t2u_hit && (r_t2u_ent[6:5] == r_pht_update_slot);
	t_t1_provider = !t_t2_provider && r_t1u_hit && (r_t1u_ent[6:5] == r_pht_update_slot);
	t_t1_free = !r_t1u_ent[16] || (r_t1u_ent[1:0] == 2'd0);
	t_t2_free = !r_t2u_ent[16] || (r_t2u_ent[1:0] == 2'd0);
	t_prov_pred = t_t2_provider ? r_t2u_ent[4] : t_t1_provider ? r_t1u_ent[4] : t_pht_old[1];
	t_alt_pred = (t_t2_provider && r_t1u_hit && (r_t1u_ent[6:5] == r_pht_update_slot)) ? r_t1u_ent[4] :
		     t_pht_old[1];
	t_t1_ctr = r_t1u_ent[4:2];
	t_t1_u = r_t1u_ent[1:0];
	t_t2_ctr = r_t2u_ent[4:2];
	t_t2_u = r_t2u_ent[1:0];
	t_t1_wr = 1'b0;
	t_t2_wr = 1'b0;
	t_t1_wr_data = r_t1u_ent;
	t_t2_wr_data = r_t2u_ent;
	if(t_init_pht)
	  begin
	     t_t1_wr = 1'b1;
	     t_t1_wr_data = 'd0;
	     t_t2_wr = 1'b1;
	     t_t2_wr_data = 'd0;
	  end
	else if(r_pht_update)
	  begin
	     /* train the provider */
	     if(t_t2_provider)
	       begin
		  t_do_pht_wr = 1'b0;
		  t_t2_ctr = r_take_br ? ((t_t2_ctr == 3'd7) ? 3'd7 : t_t2_ctr + 3'd1) :
			     ((t_t2_ctr == 3'd0) ? 3'd0 : t_t2_ctr - 3'd1);
		  if((t_prov_pred == r_take_br) && (t_prov_pred != t_alt_pred) && (t_t2_u != 2'd3))
		    begin
		       t_t2_u = t_t2_u + 2'd1;
		    end
		  t_t2_wr = 1'b1;
		  t_t2_wr_data = {1'b1, r_t2u_ent[15:7], r_t2u_ent[6:5], t_t2_ctr, t_t2_u};
	       end
	     else if(t_t1_provider)
	       begin
		  t_do_pht_wr = 1'b0;
		  t_t1_ctr = r_take_br ? ((t_t1_ctr == 3'd7) ? 3'd7 : t_t1_ctr + 3'd1) :
			     ((t_t1_ctr == 3'd0) ? 3'd0 : t_t1_ctr - 3'd1);
		  if((t_prov_pred == r_take_br) && (t_prov_pred != t_alt_pred) && (t_t1_u != 2'd3))
		    begin
		       t_t1_u = t_t1_u + 2'd1;
		    end
		  t_t1_wr = 1'b1;
		  t_t1_wr_data = {1'b1, r_t1u_ent[15:7], r_t1u_ent[6:5], t_t1_ctr, t_t1_u};
	       end
	     /* provider mispredicted: allocate in a longer table */
	     if(t_prov_pred != r_take_br)
	       begin
		  if(!t_t2_provider && !t_t1_provider)
		    begin
		       /* bimodal provided: candidates T1 then T2 */
		       if(t_t1_free)
			 begin
			    t_t1_wr = 1'b1;
			    t_t1_wr_data = {1'b1, r_t1u_tag, r_pht_update_slot, r_take_br ? 3'd4 : 3'd3, 2'd0};
			 end
		       else if(t_t2_free)
			 begin
			    t_t2_wr = 1'b1;
			    t_t2_wr_data = {1'b1, r_t2u_tag, r_pht_update_slot, r_take_br ? 3'd4 : 3'd3, 2'd0};
			 end
		       else
			 begin
			    t_t1_wr = 1'b1;
			    t_t1_wr_data = {r_t1u_ent[16:2], r_t1u_ent[1:0] - 2'd1};
			    t_t2_wr = 1'b1;
			    t_t2_wr_data = {r_t2u_ent[16:2], r_t2u_ent[1:0] - 2'd1};
			 end
		    end
		  else if(t_t1_provider)
		    begin
		       /* T1 provided: the only longer candidate is T2 */
		       t_t2_wr = 1'b1;
		       if(t_t2_free)
			 begin
			    t_t2_wr_data = {1'b1, r_t2u_tag, r_pht_update_slot, r_take_br ? 3'd4 : 3'd3, 2'd0};
			 end
		       else
			 begin
			    t_t2_wr_data = {r_t2u_ent[16:2], r_t2u_ent[1:0] - 2'd1};
			 end
		    end
	       end
	  end
     end
   
   always_comb
     begin
	t_bpu_alloc = t_push_insn | t_push_insn2;
     end

   always_ff@(posedge clk)
     begin
	if(t_bpu_alloc)
	  begin
	     r_bpu_tbl[r_bpu_idx] <= r_pht_idx;
	     r_bpu_t1_idx[r_bpu_idx] <= r_t1_idx;
	     r_bpu_t1_tag[r_bpu_idx] <= r_t1_tag;
	     r_bpu_t1_hit[r_bpu_idx] <= t_t1_hit;
	     r_bpu_t1_ent[r_bpu_idx] <= r_t1_out;
	     r_bpu_t2_idx[r_bpu_idx] <= r_t2_idx;
	     r_bpu_t2_tag[r_bpu_idx] <= r_t2_tag;
	     r_bpu_t2_hit[r_bpu_idx] <= t_t2_hit;
	     r_bpu_t2_ent[r_bpu_idx] <= r_t2_out;
	  end
     end

   always_ff@(posedge clk)
     begin
	r_t1_idx <= t_t1_n_idx;
	r_t1_tag <= t_t1_n_tag;
	r_t1u_idx <= r_bpu_t1_idx[branch_bpu_idx];
	r_t1u_tag <= r_bpu_t1_tag[branch_bpu_idx];
	r_t1u_hit <= r_bpu_t1_hit[branch_bpu_idx];
	r_t1u_ent <= r_bpu_t1_ent[branch_bpu_idx];
	r_t2_idx <= t_t2_n_idx;
	r_t2_tag <= t_t2_n_tag;
	r_t2u_idx <= r_bpu_t2_idx[branch_bpu_idx];
	r_t2u_tag <= r_bpu_t2_tag[branch_bpu_idx];
	r_t2u_hit <= r_bpu_t2_hit[branch_bpu_idx];
	r_t2u_ent <= r_bpu_t2_ent[branch_bpu_idx];
     end

   ram1r1w #(.WIDTH(T1_W), .LG_DEPTH(`LG_TAGE_SZ)) t1
     (
      .clk(clk),
      .rd_addr(t_t1_n_idx),
      .wr_addr(t_init_pht ? r_init_pht_idx[`LG_TAGE_SZ-1:0] : r_t1u_idx),
      .wr_data(t_t1_wr_data),
      .wr_en(t_t1_wr),
      .rd_data(r_t1_out)
      );

   ram1r1w #(.WIDTH(T1_W), .LG_DEPTH(`LG_TAGE_SZ)) t2
     (
      .clk(clk),
      .rd_addr(t_t2_n_idx),
      .wr_addr(t_init_pht ? r_init_pht_idx[`LG_TAGE_SZ-1:0] : r_t2u_idx),
      .wr_data(t_t2_wr_data),
      .wr_en(t_t2_wr),
      .rd_data(r_t2_out)
      );

   always_ff@(posedge clk)
     begin
	r_bpu_idx <= reset ? 'd0 : (t_bpu_alloc ? r_bpu_idx + 'd1 : r_bpu_idx);
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_pht_idx <= 'd0;
	     r_last_spec_gbl_hist <= 'd0;
	     r_pht_update <= 1'b0;
	     r_pht_update_idx <= 'd0;
	     r_pht_update_slot <= 2'd0;
	     r_take_br <= 1'b0;
	     r_pd <= 'd0;
	  end
	else
	  begin
	     r_pht_idx <= n_pht_idx;
	     r_last_spec_gbl_hist <= r_spec_gbl_hist;
	     r_pht_update <= branch_pc_valid;
	     r_pht_update_idx <= t_retire_pht_idx;
	     /* which of the 4 packed counters this retiring branch owns */
	     r_pht_update_slot <= branch_pc[3:2];
	     r_take_br <= took_branch;
	     r_pd <= t_pd;
	  end
     end // always_ff@

`ifdef TOPDOWN
   /* per-cycle fetch group size and why the group ended (top.cc topdown_fetch):
    * 0 full 2, 1 cut at the 16B line end, 2 cut before a predicted-taken cflow,
    * 3 the cflow insn alone, 4 its delay slot alone, 5 fetch queue full,
    * 6 resteer bubble, 7 miss/tlb/other state, 8 restart/flush redirect,
    * 9 branch pair: [insn, predicted-taken direct branch] */
   import "DPI-C" function void topdown_fetch(input int npush, input int why, input int fq_cnt);
   logic [3:0] t_td_why;
   logic [2:0] t_td_n;
   always_comb
     begin
	t_td_n = t_push_insn2 ? 3'd2 : t_push_insn ? 3'd1 : 3'd0;
	t_td_why = 4'd7;
	if(r_state != ACTIVE)
	  begin
	     t_td_why = 4'd7;
	  end
	else if(r_resteer_bubble)
	  begin
	     t_td_why = 4'd6;
	  end
	else if(t_clear_fq)
	  begin
	     t_td_why = 4'd8;
	  end
	else if(!t_hit)
	  begin
	     t_td_why = 4'd7;
	  end
	else if(fq_full)
	  begin
	     t_td_why = 4'd5;
	  end
	else if(r_delay_slot)
	  begin
	     t_td_why = 4'd4;
	  end
	else if(t_is_cflow)
	  begin
	     t_td_why = 4'd3;
	  end
	else if(t_gb_take1)
	  begin
	     t_td_why = 4'd9;
	  end
	else if(t_td_n == 3'd2)
	  begin
	     t_td_why = 4'd0;
	  end
	else if({1'b0, t_td_n} < {1'b0, t_first_branch})
	  begin
	     t_td_why = 4'd5;
	  end
	else if(({1'b0, t_first_branch} + {2'b0, t_insn_idx}) == 4'd4)
	  begin
	     t_td_why = 4'd1;
	  end
	else
	  begin
	     t_td_why = 4'd2;
	  end
     end // always_comb
   always_ff@(negedge clk)
     begin
	if(!reset)
	  begin
	     topdown_fetch({29'd0, t_td_n}, {28'd0, t_td_why},
			   {{(31-`LG_FQ_ENTRIES){1'b0}}, r_fq_tail_ptr - r_fq_head_ptr});
	  end
     end
`endif

`ifdef VERILATOR
   localparam ZP = (64-`M_WIDTH);   
   always_ff@(negedge clk)
     begin
	//$display("%b %b %b %b", t_push_insn, t_push_insn2, t_push_insn3, t_push_insn4);
	record_fetch(t_push_insn ? 32'd1 : 32'd0,
		     t_push_insn2 ? 32'd1 : 32'd0,
		     32'd0,
		     32'd0,
		     {{ZP{1'b0}}, t_insn.pc},
		     {{ZP{1'b0}}, t_insn2.pc},
		     64'd0,
		     64'd0,
		     r_resteer_bubble ? 32'd1 : 32'd0,
		     fq_full ? 32'd1 : 32'd0);
	
	
     end
`endif
	  

   ram2r1w #(.WIDTH(8), .LG_DEPTH(`LG_PHT_SZ) ) pht
     (
      .clk(clk),
      .rd_addr0(n_pht_idx),
      .rd_addr1(t_retire_pht_idx),
      .wr_addr(t_init_pht ? r_init_pht_idx : r_pht_update_idx),
      .wr_data(t_init_pht ? 8'b01010101 : t_pht_val_vec),
      .wr_en(t_init_pht || t_do_pht_wr),
      .rd_data0(r_pht_out_vec),
      .rd_data1(r_pht_update_out)
      );
         
   wire [3:0] w_pd0, w_pd1, w_pd2, w_pd3;
   predecode pd0 (.insn_(mem_rsp_load_data[31:0]),   .pd(w_pd0));
   predecode pd1 (.insn_(mem_rsp_load_data[63:32]),  .pd(w_pd1));
   predecode pd2 (.insn_(mem_rsp_load_data[95:64]),  .pd(w_pd2));
   predecode pd3 (.insn_(mem_rsp_load_data[127:96]), .pd(w_pd3));   
   
   
   ram1r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1I_NUM_SETS))
   valid_array0 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(t_valid_ram_idx),
	   .wr_data(t_valid_ram_value),
	   .wr_en(t_wr_valid_ram_en0),
	   .rd_data(r_valid_out0)
	   );

   
   ram1r1w #(.WIDTH(N_TAG_BITS), .LG_DEPTH(`LG_L1I_NUM_SETS))
   tag_array0 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	   .wr_data(r_mem_req_addr[`PA_WIDTH-1:TAG_LSB]),
	   .wr_en(mem_rsp_valid && !r_fill_way),
	   .rd_data(r_tag_out0)
	   );
   
   ram1r1w #(.WIDTH(L1I_CL_LEN_BITS), .LG_DEPTH(`LG_L1I_NUM_SETS)) 
   insn_array0 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	   .wr_data({bswap32(mem_rsp_load_data[127:96]),
		     bswap32(mem_rsp_load_data[95:64]),
		     bswap32(mem_rsp_load_data[63:32]), 
		     bswap32(mem_rsp_load_data[31:0])}),
	   .wr_en(mem_rsp_valid && !r_fill_way),
	   .rd_data(r_array_out0)
	   );

   ram1r1w #(.WIDTH(4*WORDS_PER_CL), .LG_DEPTH(`LG_L1I_NUM_SETS))
   pd_data0 (
	    .clk(clk),
	    .rd_addr(t_cache_idx),
	    .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	    .wr_data({w_pd3,w_pd2,w_pd1,w_pd0}),
	    .wr_en(mem_rsp_valid && !r_fill_way),
	    .rd_data(r_jump_out0)
	    );

   ram1r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1I_NUM_SETS))
   valid_array1 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(t_valid_ram_idx),
	   .wr_data(t_valid_ram_value),
	   .wr_en(t_wr_valid_ram_en1),
	   .rd_data(r_valid_out1)
	   );

   
   ram1r1w #(.WIDTH(N_TAG_BITS), .LG_DEPTH(`LG_L1I_NUM_SETS))
   tag_array1 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	   .wr_data(r_mem_req_addr[`PA_WIDTH-1:TAG_LSB]),
	   .wr_en(mem_rsp_valid && r_fill_way),
	   .rd_data(r_tag_out1)
	   );
   
   ram1r1w #(.WIDTH(L1I_CL_LEN_BITS), .LG_DEPTH(`LG_L1I_NUM_SETS)) 
   insn_array1 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	   .wr_data({bswap32(mem_rsp_load_data[127:96]),
		     bswap32(mem_rsp_load_data[95:64]),
		     bswap32(mem_rsp_load_data[63:32]), 
		     bswap32(mem_rsp_load_data[31:0])}),
	   .wr_en(mem_rsp_valid && r_fill_way),
	   .rd_data(r_array_out1)
	   );

   ram1r1w #(.WIDTH(4*WORDS_PER_CL), .LG_DEPTH(`LG_L1I_NUM_SETS))
   pd_data1 (
	    .clk(clk),
	    .rd_addr(t_cache_idx),
	    .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	    .wr_data({w_pd3,w_pd2,w_pd1,w_pd0}),
	    .wr_en(mem_rsp_valid && r_fill_way),
	    .rd_data(r_jump_out1)
	    );

   /* 1 bit/set LRU: the way NOT used most recently; a hit marks the other way, a fill
    * marks the way that was not filled */
   always_comb
     begin
	t_lru_wr = 1'b0;
	t_lru_val = 1'b0;
	t_lru_idx = r_cache_idx;
	if(mem_rsp_valid)
	  begin
	     t_lru_wr = 1'b1;
	     t_lru_val = !r_fill_way;
	     t_lru_idx = r_miss_pc[IDX_STOP-1:IDX_START];
	  end
	else if(t_hit)
	  begin
	     t_lru_wr = 1'b1;
	     t_lru_val = w_hit0;
	     t_lru_idx = r_cache_idx;
	  end
     end

   ram1r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1I_NUM_SETS))
   lru_array (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(t_lru_idx),
	   .wr_data(t_lru_val),
	   .wr_en(t_lru_wr),
	   .rd_data(r_lru_out)
	   );
	    
	     
   always_comb
     begin
	n_spec_rs_tos = r_spec_rs_tos;
	if(n_restart_ack)
	  begin
	     /* n_arch, not r_arch: the retire of the mispredicted branch itself
	      * (retired_call/ret, flopped in core) arrives the same cycle as
	      * restart_valid, so r_arch_* is one push/pop stale here.  Mirrors
	      * the n_arch_gbl_hist restore below. */
	     n_spec_rs_tos = n_arch_rs_tos;
	  end
	else if(t_is_call)
	  begin
	     n_spec_rs_tos = r_spec_rs_tos - 'd1;
	  end
	else if(t_is_ret)
	  begin
	     n_spec_rs_tos = r_spec_rs_tos + 'd1;
	  end
     end

   always_ff@(posedge clk)
     begin
	if(t_is_call)
	  begin
	     r_spec_return_stack[r_spec_rs_tos] <= r_cache_pc + 'd8;
	  end
	else if(n_restart_ack)
	  begin
	     r_spec_return_stack <= r_arch_return_stack;
	     /* the mispredicted call's own arch push lands this same cycle */
	     if(retire_reg_valid && retire_valid && retired_call)
	       begin
		  r_spec_return_stack[r_arch_rs_tos] <= retire_reg_data;
	       end
	  end
     end // always_ff@ (posedge clk)
   
   always_ff@(posedge clk)
     begin
	if(retire_reg_valid && retire_valid && retired_call)
	  begin
	     r_arch_return_stack[r_arch_rs_tos] <= retire_reg_data;
	  end
     end
   always_comb
     begin
	n_arch_rs_tos = r_arch_rs_tos;
	if(retire_valid && retired_call)
	  begin
	     n_arch_rs_tos = r_arch_rs_tos - 'd1;
	  end
	else if(retire_valid && retired_ret)
	  begin
	     n_arch_rs_tos = r_arch_rs_tos + 'd1;
	  end
     end

   always_comb
     begin
	n_spec_gbl_hist = r_spec_gbl_hist;
	if(n_restart_ack)
	  begin
	     n_spec_gbl_hist = n_arch_gbl_hist;
	  end
	else if(t_update_spec_hist)
	  begin
	     n_spec_gbl_hist = {r_spec_gbl_hist[`GBL_HIST_LEN-2:0], t_take_br | t_gb_take1};
	  end
     end // always_comb

   // always_ff@(negedge clk)
   //   begin
   // 	if(n_restart_ack)
   // 	  begin
   // 	     $display("fix = %b, r_cycle %d", n_spec_gbl_hist, r_cycle);
   // 	  end
	
   // 	if(t_update_spec_hist)
   // 	  begin
   // 	     $display("take_br = %b, cycle %d", t_take_br, r_cycle);
   // 	     $display("old = %b", r_spec_gbl_hist);
   // 	     $display("new = %b", n_spec_gbl_hist);
	     
   // 	  end
   //   end
      


   always_comb
     begin
	n_arch_gbl_hist = r_arch_gbl_hist;
	if(branch_pc_valid)
	  begin
	     n_arch_gbl_hist = {r_arch_gbl_hist[`GBL_HIST_LEN-2:0], took_branch};
	  end
     end
   
   

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= INITIALIZE;
	     r_init_pht_idx <= 'd0;
	     r_pc <= 'd0;
	     r_miss_pc <= 'd0;
	     r_fill_way <= 1'b0;
	     r_cache_pc <= 'd0;
	     r_restart_ack <= 1'b0;
	     r_cache_idx <= 'd0;
	     r_cache_tag <= 'd0;
	     r_req <= 1'b0;
	     r_mem_req_valid <= 1'b0;
	     r_mem_req_addr <= 'd0;
	     r_mem_req_cacheable <= 1'b0;	     
	     r_fq_head_ptr <= 'd0;
	     r_fq_next_head_ptr <= 'd1;
	     r_fq_next_tail_ptr <= 'd1;
	     r_fq_tail_ptr <= 'd0;
	     r_restart_req <= 1'b0;
	     r_flush_req <= 1'b0;
	     r_flush_complete <= 1'b0;
	     r_delay_slot <= 1'b0;
	     r_spec_rs_tos <= RETURN_STACK_ENTRIES-1;
	     r_arch_rs_tos <= RETURN_STACK_ENTRIES-1;
	     r_arch_gbl_hist <= 'd0;
	     r_spec_gbl_hist <= 'd0;
	     r_cache_hits <= 'd0;
	     r_cache_accesses <= 'd0;
	     r_resteer_bubble <= 1'b0;
	     r_itlb_ready <= 1'b0;
	     r_tlb_wait <= 2'd0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_init_pht_idx <= n_init_pht_idx;
	     r_pc <= n_pc;
	     r_miss_pc <= n_miss_pc;
	     r_fill_way <= n_fill_way;
	     r_cache_pc <= n_cache_pc;
	     r_restart_ack <= n_restart_ack;
	     r_cache_idx <= t_cache_idx;
	     r_cache_tag <= t_cache_tag;	     
	     r_req <= n_req;
	     r_mem_req_valid <= n_mem_req_valid;
	     r_mem_req_addr <= n_mem_req_addr;
	     r_mem_req_cacheable <= n_mem_req_cacheable;
	     r_fq_head_ptr <= t_clear_fq ? 'd0 : n_fq_head_ptr;
	     r_fq_next_head_ptr <= t_clear_fq ? 'd1 : n_fq_next_head_ptr;
	     r_fq_next_tail_ptr <= t_clear_fq ? 'd1 : n_fq_next_tail_ptr;
	     r_fq_tail_ptr <= t_clear_fq ? 'd0 : n_fq_tail_ptr;
	     r_restart_req <= n_restart_req;
	     r_flush_req <= n_flush_req;
	     r_flush_complete <= n_flush_complete;
	     r_delay_slot <= n_delay_slot;
	     r_spec_rs_tos <= n_spec_rs_tos;
	     r_arch_rs_tos <= n_arch_rs_tos;
	     r_arch_gbl_hist <= n_arch_gbl_hist;
	     r_spec_gbl_hist <= n_spec_gbl_hist;
	     r_cache_hits <= n_cache_hits;
	     r_cache_accesses <= n_cache_accesses;
	     r_resteer_bubble <= n_resteer_bubble;
	     r_itlb_ready <= n_itlb_ready;
	     r_tlb_wait <= n_tlb_wait;	     
	  end
     end
   
endmodule
