`include "machine.vh"
`include "rob.vh"
`include "uop.vh"
// EXPERIMENT: fence mapped cached loads to ROB-head (non-speculative) -- read-path
// DMA coherence (stale INQUIRY-buffer reads).  Comment out to disable.
//`define ENABLE_KERNEL_LOAD_FENCE 1
// EXPERIMENT (speculation-off test): gate EVERY cached mem request (loads AND
// stores, mapped or kseg0) on being at the ROB head / its committable delay slot,
// so nothing accesses the L1D speculatively -> no speculative fill of a DMA buffer
// (the R10000-class non-coherent-DMA hazard).  Very slow (serializes memory), a
// correctness knob to prove the speculation root cause on silicon.
//`define ENABLE_MEM_HEAD_SERIALIZE 1

//`define VERBOSE_L1D 1

`ifdef VERILATOR
import "DPI-C" function void record_l1d(input int req, 
					input int ack,
					input int ack_st,
					input int block,
					input int stall_reason);
`endif

`ifdef ENABLE_STORE_CHECK
// Co-sim store-check (forward-ported from rv64core l1d.sv across the shared MIPS
// ancestor): report each committed store-write so henry_tb can compare vs the golden
// ISS store stream.  Gated by ENABLE_STORE_CHECK (henry_tb only) -- r9999's own
// ooo_core Verilator build never sees it.
import "DPI-C" function void wr_log(input longint pc, input int rob_ptr,
				    input longint unsigned addr,
				    input longint unsigned data, int is_atomic);
// L1D->L2 writeback watch: report each dirty-line writeback so henry_tb can tell whether
// the L1D hands L2 a clean or already-corrupted cache line (vs the L2->DRAM store DESCWATCH sees).
import "DPI-C" function void l1d_wb_log(input longint unsigned pa,
					input longint unsigned data_lo,
					input longint unsigned data_hi);
// IRIX o32 .data stale-load debug: fill-cycle map + bcopy-load read trace.  rd_log = a
// committed load's pc/pa/data/hit; l1d_fill_log = a line fill (pa+data) so henry_tb can
// record WHEN each line was last loaded; l1d_cacheop_log = a CACHE-op invalidate (pa).
// Together they timeline the source line: filled-before-DMA (speculative refill) vs a
// never-invalidated stale line (incomplete CACHE-inval).
import "DPI-C" function void rd_log(input longint pc, input longint unsigned addr,
				    input longint unsigned data, input int hit);
// L1D line-lifecycle trace: l1d_fill records WHICH instruction (pc) at WHICH cycle brought
// a line into the L1D (fill); l1d_cacheop records a CACHE-op invalidate/writeback hitting a
// line (pc = the CACHE-op instruction if known, else 0).  henry_tb correlates: a line filled
// (speculatively?) and never CACHE-op'd before a DMA overwrote DRAM = the stale-read bug.
import "DPI-C" function void l1d_fill(input longint unsigned cycle, input longint pc,
				      input longint unsigned pa,
				      input longint unsigned data_lo, input longint unsigned data_hi);
import "DPI-C" function void l1d_cacheop(input longint unsigned cycle, input longint pc,
					 input longint unsigned pa, input int inval);
// dirty-set-drop watch: fires when a store commit (t_wr_array, wants dirty=1) coincides with a
// dirty-CLEAR event (refill or invalidate, which win the single dc_dirty write port) -> the
// store's dirty=1 is DROPPED -> the line looks clean -> evicted with no writeback.  by_refill
// distinguishes the refill-clear (1) from the invalidate-clear (0).
import "DPI-C" function void dirtydrop(input longint unsigned cycle, input longint pc,
				      input longint unsigned pa, input int by_refill);
`endif

module l1d(clk,
	   reset,
	   asid,
	   tlb_entry_in,
	   tlb_entry_in_valid,
	   state,
	   in_kernel_mode,
	   in_supervisor_mode,
	   in_user_mode,
	   head_of_rob_ptr,
	   head_of_rob_ptr_valid,
	   head_of_rob_has_delay_slot,
	   next_head_of_rob_ptr,
	   head_of_rob_ds_committable,
	   retired_rob_ptr_valid,
	   retired_rob_ptr_two_valid,
	   retired_rob_ptr,
	   retired_rob_ptr_two,
	   restart_valid,
	   clr_link_reg,
	   memq_empty,
	   drain_ds_complete,
	   dead_rob_mask,
	   flush_req,
	   flush_complete,
	   flush_cl_req,
	   flush_cl_addr,
	   flush_cl_inval,
	   backinv_stall,
	   backinv_req,
	   backinv_addr,
	   backinv_ack,
	   backinv_dirty,
	   backinv_held,
	   backinv_data,
	   //inputs from core
	   core_mem_req_valid,
	   core_mem_req,
	   //store data (and lwl/lwr data)
	   core_store_data_valid,
	   core_store_data,
	   core_store_data_ack,
	   //outputs to core
	   core_mem_req_ack,
	   core_mem_rsp,
	   core_mem_rsp_valid,
	   //output to the memory system
	   mem_req_ack,
	   mem_req_valid, 
	   mem_req_addr, 
	   mem_req_store_data, 
	   mem_req_opcode,
	   mem_req_cacheable,
	   mem_req_mask,
	   //reply from memory system
	   mem_rsp_valid,
	   mem_rsp_load_data,
	   cache_accesses,
	   cache_hits
	   );

   localparam L1D_NUM_SETS = 1 << `LG_L1D_NUM_SETS;
   localparam L1D_CL_LEN = 1 << `LG_L1D_CL_LEN;
   localparam L1D_CL_LEN_BITS = 1 << (`LG_L1D_CL_LEN + 3);
   
   input logic clk;
   input logic reset;
   input logic [7:0] asid;
   input	     tlb_data_t tlb_entry_in;
   input logic	     tlb_entry_in_valid;
   
   output logic [3:0] state;
   input logic			in_kernel_mode;
   input logic			in_supervisor_mode;
   input logic			in_user_mode;


   input logic [`LG_ROB_ENTRIES-1:0] head_of_rob_ptr;
   input logic 			     head_of_rob_ptr_valid;
   input logic			     head_of_rob_has_delay_slot;
   input logic [`LG_ROB_ENTRIES-1:0] next_head_of_rob_ptr;
   input logic			     head_of_rob_ds_committable;
   
   input logic retired_rob_ptr_valid;
   input logic retired_rob_ptr_two_valid;
   input logic [`LG_ROB_ENTRIES-1:0] retired_rob_ptr;
   input logic [`LG_ROB_ENTRIES-1:0] retired_rob_ptr_two;
   input logic 			     restart_valid;
   input logic			     clr_link_reg;
   output logic			     memq_empty;
   input logic 			     drain_ds_complete;
   input logic [(1<<`LG_ROB_ENTRIES)-1:0] dead_rob_mask;
   
   logic [`M_WIDTH-1:0]			  r_tlb_addr, n_tlb_addr;
   
   input logic flush_cl_req;
   input logic [`M_WIDTH-1:0] flush_cl_addr;
   input logic 		      flush_cl_inval;
   /* INCLUSIVE-L2 back-invalidate (design C: DATA-CARRYING ack).  The L2 drives
    * backinv_req when it evicts / snoop-invalidates a line the presence bits say we
    * hold.  We tag-check, drop the line, and return it on the ack if it was dirty --
    * the L2 merges it into the line it is already writing to DRAM.
    * WHY NOT flush_cl_*: that path issues MEM_INVL (hit-inval) or MEM_WB (dirty)
    * back INTO the L2, which is mid-eviction waiting for this very ack -> deadlock.
    * Returning the data on the ack means this path issues NO request at all, so the
    * loop cannot exist by construction. */
   input logic 		      backinv_stall;   /* L2 bq near full: stop feeding it evictions */
   input logic 		      backinv_req;
   input logic [`PA_WIDTH-1:0] backinv_addr;
   output logic 	      backinv_ack;
   output logic 	      backinv_dirty;
   /* "I actually held this line and have now dropped it."  Without it the L2 cannot
    * tell a genuine clean-line ack from a probe that found nothing -- SNP-CLEAR on a
    * clean line and SNP-NOTHELD return identical wires (ack, dirty=0, data).  That
    * ambiguity is why the L2 never dared clear l1d_present, so presence stayed set
    * forever and the same line was probed three or four more times, right on top of
    * the merge trying to complete. */
   output logic 	      backinv_held;
   output logic [127:0]        backinv_data;
   input logic 		      flush_req;
   output logic 	      flush_complete;

   input logic core_mem_req_valid;
   input       mem_req_t core_mem_req;

   input logic core_store_data_valid;
   input       mem_data_t core_store_data;
   output logic core_store_data_ack;
   
   output logic core_mem_req_ack;
   output 	mem_rsp_t core_mem_rsp;
   output logic core_mem_rsp_valid;

   input logic 	mem_req_ack;
   
   output logic mem_req_valid;
   output logic [(`PA_WIDTH-1):0] mem_req_addr;
   output logic [L1D_CL_LEN_BITS-1:0] mem_req_store_data;
   output logic [4:0] 			  mem_req_opcode;
   output logic				  mem_req_cacheable;
   output logic [15:0]			  mem_req_mask;
   
   input logic 				  mem_rsp_valid;
   input logic [L1D_CL_LEN_BITS-1:0] 	  mem_rsp_load_data;

   
   output logic [63:0] 			 cache_accesses;
   output logic [63:0] 			 cache_hits;

         
   localparam LG_WORDS_PER_CL = `LG_L1D_CL_LEN - 2;
   localparam LG_DWORDS_PER_CL = `LG_L1D_CL_LEN - 3;
   
   localparam WORDS_PER_CL = 1<<(LG_WORDS_PER_CL);
   /* Tag is taken down to LG_PG_SZ (not IDX_STOP) so it INCLUDES the alias bits
    * -- the index bits above the page offset (VIPT synonym bits).  At <=page-size
    * (4KB: IDX_STOP==LG_PG_SZ) this is identical to the old tag.  When the L1D is
    * larger than a page (8KB: IDX_STOP>LG_PG_SZ), including PA[12..] in the tag is
    * what lets the speculatively-VA-indexed port-2 read detect an alias as a tag
    * miss; it then replays through the (already physical) miss-queue retry, which
    * re-indexes with the physical address -> no synonym/duplicate lines can form.
    * (rv64core nu_l1d scheme; see machine.vh LG_L1D_NUM_SETS.) */
   localparam IDX_START = `LG_L1D_CL_LEN;
   localparam IDX_STOP  = `LG_L1D_CL_LEN + `LG_L1D_NUM_SETS;
   /* TAG_LSB = min(LG_PG_SZ, IDX_STOP).  For cache >= page the tag is still taken down to
    * LG_PG_SZ (carries the VIPT alias bits, unchanged).  For a SUB-page cache
    * (IDX_STOP < LG_PG_SZ) it extends down to IDX_STOP so PA[IDX_STOP..LG_PG_SZ-1] stays
    * tagged (no aliasing) and {tag,idx,offset} reconstructs the full PA_WIDTH address. */
   localparam TAG_LSB = (IDX_STOP < `LG_PG_SZ) ? IDX_STOP : `LG_PG_SZ;
   localparam LG_ALIAS_BITS = IDX_STOP - TAG_LSB;   // == max(0, IDX_STOP - LG_PG_SZ)
   /* Index bits BELOW the page boundary -- untranslated, so they are the only ones
    * safe to reconstruct a physical address from.  The bits above (LG_ALIAS_BITS of
    * them, nonzero only when the cache exceeds a page) are VIRTUAL; the tag already
    * carries their physical counterparts because it runs down to TAG_LSB. */
   localparam IDX_PA_BITS = TAG_LSB - IDX_START;
   localparam N_TAG_BITS = `PA_WIDTH - TAG_LSB;
   localparam WORD_START = 2;
   localparam WORD_STOP = WORD_START+LG_WORDS_PER_CL;
   localparam DWORD_START = 3;
   localparam DWORD_STOP = DWORD_START + LG_DWORDS_PER_CL;
  
   localparam N_MQ_ENTRIES = (1<<`LG_MRQ_ENTRIES);

   function logic [15:0] make_mask(mem_req_t r);
      logic [15:0]		  t_m, m;
      logic			  b,s,w,d;
      logic			  lwl_lwr, swl_swr;
      logic [3:0]		  swl, swr;

      swr = r.addr[1:0] == 'd0 ? 4'b0001 :
	    r.addr[1:0] == 'd1 ? 4'b0011 :
	    r.addr[1:0] == 'd2 ? 4'b0111 :
	    4'b1111;

      swl = r.addr[1:0] == 'd3 ? 4'b1000 :
	    r.addr[1:0] == 'd2 ? 4'b1100 :
	    r.addr[1:0] == 'd1 ? 4'b1110 :
	    4'b1111;        // BE swl at word-aligned EA stores all 4 bytes (was 4'b0000 = no-op)
            
      
      swl_swr = (r.op == MEM_SWR | r.op == MEM_SWL);
      lwl_lwr = (r.op == MEM_LWR | r.op == MEM_LWL);
      if(r.op == MEM_LDL || r.op == MEM_LDR || r.op == MEM_SDL || r.op == MEM_SDR ||
         r.op == MEM_LLD || r.op == MEM_SCD || r.op == MEM_LD || r.op == MEM_SD)
	return 16'hff << {r.addr[DWORD_START], 3'b0};

      b = 	(r.op == MEM_SB | r.op == MEM_LB | r.op == MEM_LBU);
      s = 	(r.op == MEM_SH | r.op == MEM_LH | r.op == MEM_LHU);
      w = 	(r.op == MEM_SW | r.op == MEM_LW | r.op == MEM_LL | r.op == MEM_SC | lwl_lwr);
      
      t_m = b ? 16'h0001 :
	    s ? 16'h0003 :
	    w ? 16'h000f :
	    (r.op == MEM_SWL) ? {12'd0, swl} :
	    (r.op == MEM_SWR) ? {12'd0, swr} :
	    16'hffff;
      
      m = t_m << ((lwl_lwr | swl_swr) ? {r.addr[3:2], 2'd0} : r.addr[3:0]);      
      return m;
   endfunction
         
function logic [L1D_CL_LEN_BITS-1:0] merge_cl32(logic [L1D_CL_LEN_BITS-1:0] cl, logic [31:0] w32, logic[LG_WORDS_PER_CL-1:0] pos);
   logic [L1D_CL_LEN_BITS-1:0] 		 cl_out;
   case(pos)
     2'd0:
       cl_out = {cl[127:32], w32};
     2'd1:
       cl_out = {cl[127:64], w32, cl[31:0]};
     2'd2:
       cl_out = {cl[127:96], w32, cl[63:0]};
     2'd3:
       cl_out = {w32, cl[95:0]};
   endcase // case (pos)
   return cl_out;
endfunction

function logic [31:0] select_cl32(logic [L1D_CL_LEN_BITS-1:0] cl, logic[LG_WORDS_PER_CL-1:0] pos);
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

function logic [63:0] bswap64(logic [63:0] x);
   return {x[7:0],x[15:8],x[23:16],x[31:24],x[39:32],x[47:40],x[55:48],x[63:56]};
endfunction

function logic [L1D_CL_LEN_BITS-1:0] merge_cl64(logic [L1D_CL_LEN_BITS-1:0] cl, logic [63:0] w64, logic [LG_DWORDS_PER_CL-1:0] pos);
   logic [L1D_CL_LEN_BITS-1:0] cl_out;
   case(pos)
     1'd0:
       cl_out = {cl[127:64], w64};
     1'd1:
       cl_out = {w64, cl[63:0]};
   endcase
   return cl_out;
endfunction

function logic [63:0] select_cl64(logic [L1D_CL_LEN_BITS-1:0] cl, logic [LG_DWORDS_PER_CL-1:0] pos);
   logic [63:0] w64;
   case(pos)
     1'd0:
       w64 = cl[63:0];
     1'd1:
       w64 = cl[127:64];
   endcase
   return w64;
endfunction
   
   logic 				  r_got_req, r_last_wr, n_last_wr;
   logic 				  r_last_rd, n_last_rd;
   logic 				  r_got_req2, r_last_wr2, n_last_wr2;
   logic 				  r_last_rd2, n_last_rd2;
   
   logic 				  rr_got_req, rr_last_wr, rr_is_retry, rr_did_reload;

   logic 				  r_lock_cache, n_lock_cache;
   
   logic [`LG_MRQ_ENTRIES:0] 		  r_n_inflight;   


   
   //1st read port
   logic [`LG_L1D_NUM_SETS-1:0] 	  t_cache_idx, r_cache_idx, rr_cache_idx;
   logic [N_TAG_BITS-1:0] 		  t_cache_tag, r_cache_tag, r_tag_out;
   logic [N_TAG_BITS-1:0] 		  rr_cache_tag;
   logic 				  r_valid_out, r_dirty_out;
   logic [L1D_CL_LEN_BITS-1:0] 		  r_array_out, t_data, t_data2;
   
   //2nd read port
   logic [`LG_L1D_NUM_SETS-1:0] 	  t_cache_idx2, r_cache_idx2;
   /* Port-2 ownership.  t_p2_core marks the cycle a CORE request claims read port
    * 2; when it is low the snoop engine may borrow the port.  r_cache_idx2_val is
    * the registered qualifier: it says whether r_cache_idx2 holds a core-request
    * index, and the store-hazard compares below are gated on it so a borrowed
    * cycle can never make them mis-fire.  This is what makes borrowing provably
    * safe instead of an argument about what is in flight. */
   logic 				  t_p2_core;
   logic 				  r_cache_idx2_val, n_cache_idx2_val;
   localparam SNP_IDLE = 2'd0, SNP_RD = 2'd1, SNP_ACT = 2'd2;
   logic [1:0] 			  r_snp_state, n_snp_state;
   logic [`PA_WIDTH-1:0] 		  r_snp_addr, n_snp_addr;
   logic 				  r_snp_pend, n_snp_pend;
   logic 				  t_snp_want_p2, t_snp_clear, t_snp_won;
   logic 				  r_snp_inval_done, n_snp_inval_done;
   logic [`PA_WIDTH-1:0] 		  r_snp_inval_addr, n_snp_inval_addr;
   wire [`LG_L1D_NUM_SETS-1:0] 	  w_snp_idx = r_snp_addr[IDX_STOP-1:IDX_START];
   /* final port-2 address: the core always wins, the snoop takes what is left */
   wire [`LG_L1D_NUM_SETS-1:0] 	  w_p2_addr = t_p2_core ? t_cache_idx2 :
					  (t_snp_want_p2 ? w_snp_idx : t_cache_idx2);
   logic [N_TAG_BITS-1:0] 		  t_cache_tag2, r_cache_tag2, r_tag_out2;
   logic 				  r_valid_out2, r_dirty_out2;
   logic [L1D_CL_LEN_BITS-1:0] 		  r_array_out2;
   
   
   logic [`LG_L1D_NUM_SETS-1:0] 	  t_miss_idx, r_miss_idx;
   logic [`M_WIDTH-1:0] 		  t_miss_addr, r_miss_addr;

   //write port   
   logic [`LG_L1D_NUM_SETS-1:0] 	  t_array_wr_addr;
   logic [L1D_CL_LEN_BITS-1:0] 		  t_array_wr_data, r_array_wr_data;

   logic 				  t_array_wr_en;
		  

   logic 				  r_flush_req, n_flush_req;
   logic 				  r_flush_cl_req, n_flush_cl_req;
   /* The L2 holds backinv_req asserted until it SEES our ack, and its deassert is
    * registered -- so the request is STILL HIGH on the cycle we ack it.  Latching
    * the level re-arms the engine on the SAME request: the second pass finds the
    * line already invalidated (we just cleared it), falls into the tag-miss path,
    * and acks again with dirty=0.  The L2 consuming that second ack sees a clean
    * line, takes the discard branch instead of recovery, and the store is silently
    * dropped -- no stale data anywhere, just a lost dirty bit.
    *
    * Observed as exactly 2 acks per issue in the back-invalidate log (1,076,166
    * acks / 538,083 issues), and as tests/dma/rmw_snoop.S losing one increment:
    *   [bi-ack] cyc=10681689 addr=008300000 dirty=1 data=...01000000
    *   [bi-ack] cyc=10681691 addr=008300000 dirty=0 data=...01000000
    * Accept on the RISING EDGE only.  Safe because the L2 pops its queue into the
    * request register only when ~r_backinv_d & ~r_backinv_i, so req always returns
    * low between distinct requests. */
   logic 				  r_backinv_req_d;
   wire 				  w_backinv_req_edge = backinv_req & ~r_backinv_req_d;
   logic 				  r_backinv_ack, n_backinv_ack;
   logic 				  r_backinv_dirty, n_backinv_dirty;
   logic 				  r_backinv_held, n_backinv_held;
   logic [127:0] 			  r_backinv_data, n_backinv_data;
   logic 				  r_flush_complete, n_flush_complete;
   

   logic [31:0] 			  t_array_out_b32[WORDS_PER_CL-1:0];
   logic [31:0] 			  t_w32, t_bswap_w32;
   logic [31:0] 			  t_w32_2, t_bswap_w32_2;

   logic 				  t_got_rd_retry, t_port2_hit_cache;
      
   logic 				  t_mark_invalid;
   logic 				  t_wr_array;
   logic 				  t_hit_cache;
   logic 				  t_rsp_dst_valid;
   logic 				  t_rsp_fp_dst_valid;
   logic [63:0] 			  t_rsp_data;
   
   logic 				  t_hit_cache2;
   logic 				  t_rsp_dst_valid2;
   logic 				  t_rsp_fp_dst_valid2;
   logic [63:0] 			  t_rsp_data2;


   
   logic [L1D_CL_LEN_BITS-1:0] 		  t_array_data;
   
   logic [`M_WIDTH-1:0] 		  t_addr;
   logic 				  t_got_req, t_got_req2;
   logic 				  t_got_miss;
   logic 				  t_push_miss;
   
   logic 				  t_mh_block, t_cm_block, t_cm_block2,
					  t_cm_block_stall;

   logic 				  r_must_forward, r_must_forward2;
      
   logic 				  n_inhibit_write, r_inhibit_write;
   logic 				  t_got_non_mem, r_got_non_mem;

   logic                                  t_incr_busy,t_force_clear_busy;
   logic 				  n_stall_store, r_stall_store;
      
   logic 				  n_is_retry, r_is_retry;
   logic 				  r_q_priority, n_q_priority;
   
   logic 				  n_core_mem_rsp_valid, r_core_mem_rsp_valid;
   mem_rsp_t n_core_mem_rsp, r_core_mem_rsp;

   wire [5:0] w_tlb_index;
   wire        w_tlb_dirty;
   wire        w_tlb_valid;
   wire [2:0]  w_tlb_c;     /* dtlb: matched page cacheability (EntryLo C/CCA) */
   wire	      w_tlb_hit;
   wire	      w_tlb_oor;   /* dtlb: matched entry's PFN exceeds MAX_PA(36b) -> Addr Error */

      
   mem_req_t n_req, r_req, t_req;
   mem_req_t n_req2, r_req2;

   mem_req_t r_mem_q[N_MQ_ENTRIES-1:0];
   logic [`LG_MRQ_ENTRIES:0] r_mq_head_ptr, n_mq_head_ptr;
   logic [`LG_MRQ_ENTRIES:0] r_mq_tail_ptr, n_mq_tail_ptr;
   logic [`LG_MRQ_ENTRIES:0] t_mq_tail_ptr_plus_one;

   
   logic [N_MQ_ENTRIES-1:0] r_mq_addr_valid;
   logic [IDX_STOP-IDX_START-1:0] r_mq_addr[N_MQ_ENTRIES-1:0];
   /* per-MQ-entry byte mask (mirrors rv64core nu_l1d): only STORES carry a mask;
    * loads store 0.  Used to refine the port-2 same-set hazard from set-index-only
    * to set-index AND byte-overlap so disjoint-byte accesses no longer serialize. */
   logic [15:0] 		 r_mq_mask[N_MQ_ENTRIES-1:0];
  
   
   mem_req_t t_mem_tail, t_mem_head;
   logic 	mem_q_full, mem_q_empty, mem_q_almost_full;
   
   typedef enum logic [4:0] {INITIALIZE = 'd0, //0
			     INIT_CACHE = 'd1, //1
			     ACTIVE = 'd2, //2
                             INJECT_RELOAD = 'd3, //3
			     WAIT_INJECT_RELOAD = 'd4, //4
                             FLUSH_CACHE = 'd5, //5
                             FLUSH_CACHE_WAIT = 'd6, //6
			     FLUSH_CACHE_LAST_WAIT = 'd7, //6
                             FLUSH_CL = 'd8,
                             FLUSH_CL_WAIT = 'd9,
                             HANDLE_RELOAD = 'd10,
			     INJECT_UNCACHE_STORE = 'd11,
			     INJECT_UNCACHE_LOAD = 'd12,
			     UNCACHE_WB = 'd13,
			     /* second "beat" of a D-Hit CACHE op: after the op on the
			      * addressed 16B line completes, re-run it on the next 16B line
			      * (addr+16) so IRIX's 32B-aligned/32B-stride dma_cache_inv
			      * (built for a 32B primary line) covers BOTH 16B lines. Same
			      * page -> same tag; only the index is +1. */
			     CHOP_BEAT2 = 'd14,
			     /* 1-cycle re-index: drive t_cache_idx to (addr+16)'s set so
			      * the registered RAM outputs are valid for CHOP_BEAT2. */
			     CHOP_BEAT2_RD = 'd15,
			     /* D-Index CACHE-op (FLUSH_CL funnel) second beat: same idea as
			      * CHOP_BEAT2 but for the whole-cache-flush path -- re-index to
			      * set+1 and re-run FLUSH_CL so a 32B-stride Index_WB_Invalidate
			      * covers both 16B lines. */
			     FLUSH_CL_BEAT2_RD = 'd16,
			     /* inclusive-L2 back-invalidate: ACTIVE drives the index, this
			      * state sees the registered tag/dirty/data and acts. */
			     BACKINV = 'd17
                             } state_t;

   
   state_t r_state, n_state;
   logic 	t_pop_mq;
   logic 	n_reload_issue, r_reload_issue;
   logic 	n_did_reload, r_did_reload;
   logic 	n_uncache_wb_dirty, r_uncache_wb_dirty;

   /* debug/trace-only observability port (kept 4b to avoid rippling the width
    * up through core_l1d_l1i/henry_soc/ILA); r_state is now 5b (17 states) so
    * FLUSH_CL_BEAT2_RD=16 aliases INITIALIZE=0 in the trace -- a transient
    * 1-cycle re-index state, acceptable to lose in observability. */
   assign state = r_state[3:0];
   
   logic	r_mem_req_cacheable, n_mem_req_cacheable;
   logic [15:0]	t_mem_req_mask, r_mem_req_mask, n_mem_req_mask;
   
   logic	r_mem_req_valid, n_mem_req_valid;
   logic [(`PA_WIDTH-1):0] r_mem_req_addr, n_mem_req_addr;
   logic [L1D_CL_LEN_BITS-1:0] r_mem_req_store_data, n_mem_req_store_data;
   
   logic [4:0] 		       r_mem_req_opcode, n_mem_req_opcode;
   logic [63:0] 	       n_cache_accesses, r_cache_accesses;
   logic [63:0] 	       n_cache_hits, r_cache_hits;

   wire [`PA_WIDTH-1:0]      w_mapped_addr;
   /* port-2 tag is the TLB-TRANSLATED physical tag (w_mapped_addr), not the VA
    * tag (r_cache_tag2).  For unmapped accesses w_mapped_addr == va (1:1) so this
    * is equivalent; for mapped accesses it is the real physical tag.  Aligned
    * with r_tag_out2/r_req2 (both clocked off the same port-2 request). */
   wire [N_TAG_BITS-1:0]     w_tlb_tag2 = w_mapped_addr[`PA_WIDTH-1:TAG_LSB];
   
   
   logic [31:0] 			 r_cycle;
   assign flush_complete = r_flush_complete;
   assign backinv_ack = r_backinv_ack;
   assign backinv_dirty = r_backinv_dirty;
   assign backinv_held = r_backinv_held;
   assign backinv_data = r_backinv_data;
   assign mem_req_addr = r_mem_req_addr;
   assign mem_req_store_data = r_mem_req_store_data;
   assign mem_req_opcode = r_mem_req_opcode;
   assign mem_req_valid = r_mem_req_valid;
   assign mem_req_cacheable = r_mem_req_cacheable;
   assign mem_req_mask = r_mem_req_mask;

   assign core_mem_rsp_valid = n_core_mem_rsp_valid;
   assign core_mem_rsp = n_core_mem_rsp;
   
   assign cache_accesses = r_cache_accesses;
   assign cache_hits = r_cache_hits;

   wire					 w_cacheable_mem_rsp_valid = (r_state == INJECT_RELOAD) & 
					 mem_rsp_valid;
   
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : (r_cycle + 'd1);
     end
   
   
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_mq_head_ptr <= 'd0;
	     r_mq_tail_ptr <= 'd0;
	  end
	else
	  begin
	     r_mq_head_ptr <= n_mq_head_ptr;
	     r_mq_tail_ptr <= n_mq_tail_ptr;
	  end
     end // always_ff@ (posedge clk)

   localparam N_ROB_ENTRIES = (1<<`LG_ROB_ENTRIES);
   logic [1:0] r_graduated [N_ROB_ENTRIES-1:0];
   logic [N_ROB_ENTRIES-1:0] r_missed;
   logic [N_ROB_ENTRIES-1:0] r_rob_inflight;

   logic r_link_reg_val;
   logic [`PA_WIDTH-1:0] r_link_reg;
   wire w_match_link = r_link_reg_val &&
                       (r_link_reg == {r_req.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN],
                                       {`LG_L1D_CL_LEN{1'b0}}});
   wire w_match_link2 = r_link_reg_val &&
                        (r_link_reg == {r_req2.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN],
                                        {`LG_L1D_CL_LEN{1'b0}}});
   logic r_sc_should_write;

   logic t_reset_graduated;
   /* CACHE hit-type mem ops (MEM_CHWB/CHWBINV/CHINV): line ops with dtlb-translated
    * PAs, deferred to post-retirement via store graduation. */
   wire w_is_chop2 = (r_req2.op == MEM_CHWB) | (r_req2.op == MEM_CHWBINV) | (r_req2.op == MEM_CHINV);
   wire w_is_chop_head = (t_mem_head.op == MEM_CHWB) | (t_mem_head.op == MEM_CHWBINV) | (t_mem_head.op == MEM_CHINV);
   wire w_is_chop_r = (r_req.op == MEM_CHWB) | (r_req.op == MEM_CHWBINV) | (r_req.op == MEM_CHINV);
   /* second-beat set index = (r_req.addr + 16)'s set = this set + 1 (the CACHE op
    * is 32B-aligned, so addr[LG_L1D_CL_LEN]=0 and +16 just increments the index).
    * From r_req.addr (stable) -- NOT r_cache_idx, which the FLUSH_CL_WAIT default
    * t_cache_idx='d0 clobbers to 0 during the mem-rsp wait. */
   wire [`LG_L1D_NUM_SETS-1:0] w_beat2_idx = r_req.addr[IDX_STOP-1:IDX_START] + 1'b1;
   /* D-Index (FLUSH_CL funnel) second-beat set: flush_cl_addr's set + 1. */
   wire [`LG_L1D_NUM_SETS-1:0] w_flush_cl_idx1 = flush_cl_addr[IDX_STOP-1:IDX_START] + 1'b1;
   logic r_chop_wait, n_chop_wait;
   logic r_chop_beat, n_chop_beat;
   logic r_flush_cl_beat, n_flush_cl_beat;
`ifdef CHOP_DEBUG
   always_ff@(negedge clk)
     begin
	if(t_push_miss)
	  $display("[push] cyc=%d op=%d pa=%x st=%b rob=%d", r_cycle, r_req2.op, t_remapped_req2.addr, r_req2.is_store, r_req2.rob_ptr);
	if(t_pop_mq & t_mem_head.is_store & !w_is_chop_head)
	  $display("[st-fire] cyc=%d pa=%x", r_cycle, t_mem_head.addr);
	if(t_pop_mq & w_is_chop_head)
	  $display("[chop-fire] cyc=%d op=%d pa=%x", r_cycle, t_mem_head.op, t_mem_head.addr);
	if(r_got_req & w_is_chop_r)
	  $display("[chop-retry] cyc=%d op=%d pa=%x v=%b tagm=%b d=%b -> st=%d wb=%b", r_cycle, r_req.op, r_req.addr,
		   r_valid_out, (r_tag_out == r_cache_tag), r_dirty_out, n_state, n_mem_req_valid);
	if(r_state == FLUSH_CL)
	  $display("[funnel-flcl] cyc=%d pa=%x inval=%b v=%b tagm=%b d=%b -> st=%d", r_cycle, flush_cl_addr, flush_cl_inval,
		   r_valid_out, (r_tag_out == flush_cl_addr[`PA_WIDTH-1:TAG_LSB]), r_dirty_out, n_state);
	if(n_mem_req_valid & ((n_mem_req_opcode == MEM_WB) | (n_mem_req_opcode == MEM_INVL)) & (r_state != FLUSH_CACHE))
	  $display("[l2op] cyc=%d op=%s pa=%x data=%x", r_cycle, (n_mem_req_opcode == MEM_WB) ? "WB" : "INVL", n_mem_req_addr, n_mem_req_store_data[31:0]);
     end
`endif

   always_ff@(posedge clk)
     begin
	if(reset /*|| restart_valid*/)
	  begin
	     for(integer i = 0; i < N_ROB_ENTRIES; i = i+1)
	       begin
		  r_graduated[i] <= 2'b00;
	       end
	  end
	else
	  begin
	     if(retired_rob_ptr_valid && r_graduated[retired_rob_ptr] == 2'b01)
	       begin
		  r_graduated[retired_rob_ptr] <= 2'b10;
	       end
	     if(retired_rob_ptr_two_valid && r_graduated[retired_rob_ptr_two] == 2'b01) 
	       begin
		  r_graduated[retired_rob_ptr_two] <= 2'b10;
	       end
	     if(t_incr_busy)
	       begin
		  //$display("cycle %d : incr busy for ptr %d", r_cycle, r_req2.rob_ptr);
		  r_graduated[r_req2.rob_ptr] <= 2'b01;
	       end
	     if(t_reset_graduated)
               begin
		  r_graduated[r_req.rob_ptr] <= 2'b00;
	       end
	     if(t_force_clear_busy)
	       begin
		  r_graduated[t_mem_head.rob_ptr] <= 2'b00;
	       end
	  end
     end // always_ff@ (posedge clk)

   wire w_req2_is_store = (r_req2.op == MEM_SB)  || (r_req2.op == MEM_SH)  ||
                          (r_req2.op == MEM_SW)  || (r_req2.op == MEM_SWL) ||
                          (r_req2.op == MEM_SWR) || (r_req2.op == MEM_SD)  ||
                          (r_req2.op == MEM_SDL) || (r_req2.op == MEM_SDR);
   /* What breaks the LL/SC link on the in-order first pass (LLSC model, machine.vh).
    * NOT MEM_LL/LLD (set it), NOT MEM_SC/SCD (clear at response after w_match_link2). */
`ifdef LLSC_BREAK_ON_LOAD
   /* R10000 (p.27): ANY intervening normal load/store breaks the link. */
   wire w_req2_breaks_link = (r_req2.op != MEM_LL)   && (r_req2.op != MEM_LLD) &&
                             (r_req2.op != MEM_SC)    && (r_req2.op != MEM_SCD) &&
                             (r_req2.op != MEM_TLBP)  && (r_req2.op != MEM_INVL) &&
                             (r_req2.op != MEM_MOV);
`else
   /* BERI/CHERI (default): only a STORE to the linked line breaks the link. */
   wire w_req2_breaks_link = w_req2_is_store && w_match_link2;
`endif
   always_ff@(posedge clk)
     begin
	if(reset || clr_link_reg)
	  begin
	     r_link_reg_val <= 1'b0;
	     r_link_reg <= 'd0;
	  end
	/* Track the link at the IN-ORDER first pass (port2 = core_mem_req ingress);
	 * misses replay via port1, which is OOO and must NOT touch the link. */
	else if(r_got_req2 && (r_req2.op == MEM_LL || r_req2.op == MEM_LLD))
	  begin
	     r_link_reg_val <= 1'b1;
	     r_link_reg <= {r_req2.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN], {`LG_L1D_CL_LEN{1'b0}}};
	  end
	else if(n_core_mem_rsp_valid && r_got_req2 && (r_req2.op == MEM_SC || r_req2.op == MEM_SCD))
	  begin
	     /* SC/SCD: clear at its response, after the w_match_link2 check below */
	     r_link_reg_val <= 1'b0;
	  end
	else if(r_got_req2 && w_req2_breaks_link)
	  begin
	     /* in-order first pass breaks the link (model selected above) */
	     r_link_reg_val <= 1'b0;
	  end
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  r_sc_should_write <= 1'b0;
	else if(n_core_mem_rsp_valid && r_got_req2 && (r_req2.op == MEM_SC || r_req2.op == MEM_SCD))
	  /* SC succeeds on the reservation (link); the data write is deferred to the
	   * port1 graduated-store path, which waits for the hit after a reload.  (Do
	   * NOT require a cache hit here, else a conflict-displaced line livelocks the
	   * SC even with a valid reservation -- matches rv64core MEM_SCD.) */
	  r_sc_should_write <= w_match_link2;
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_n_inflight <= 'd0;
	  end
	else if(core_mem_req_valid && core_mem_req_ack && !core_mem_rsp_valid)
	  begin
	     r_n_inflight <= r_n_inflight + 'd1;
	     //$display("inflight increment at cycle %d to %d, rob ptr %d", r_cycle, r_n_inflight + 'd1, core_mem_req.rob_ptr);
	  end
	else if(!(core_mem_req_valid && core_mem_req_ack) && core_mem_rsp_valid)
	  begin
	     r_n_inflight <= r_n_inflight - 'd1;
	     //$display("inflight decrement at cycle %d to %d", r_cycle, r_n_inflight - 'd1);
	  end
     end // always_ff@ (posedge clk)

   

   
   
   always_comb
     begin
	n_mq_head_ptr = r_mq_head_ptr;
	n_mq_tail_ptr = r_mq_tail_ptr;
	t_mq_tail_ptr_plus_one = r_mq_tail_ptr + 'd1;
	
	if(t_push_miss)
	  begin
	     n_mq_tail_ptr = r_mq_tail_ptr + 'd1;
	  end
	
	if(t_pop_mq)
	  begin
	     n_mq_head_ptr = r_mq_head_ptr + 'd1;
	  end
	
	t_mem_head = r_mem_q[r_mq_head_ptr[`LG_MRQ_ENTRIES-1:0]];
	
	mem_q_empty = (r_mq_head_ptr == r_mq_tail_ptr);
	
	mem_q_full = (r_mq_head_ptr != r_mq_tail_ptr) &&
		     (r_mq_head_ptr[`LG_MRQ_ENTRIES-1:0] == r_mq_tail_ptr[`LG_MRQ_ENTRIES-1:0]);
	
	mem_q_almost_full = (r_mq_head_ptr != t_mq_tail_ptr_plus_one) &&
			    (r_mq_head_ptr[`LG_MRQ_ENTRIES-1:0] == t_mq_tail_ptr_plus_one[`LG_MRQ_ENTRIES-1:0]);
	
	
     end // always_comb


   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_missed <= 'd0;
	  end
	else
	  begin
	     if(t_push_miss)
	       begin
		  r_missed[r_req2.rob_ptr] <= !t_port2_hit_cache;
	       end
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_rob_inflight <= 'd0;
	  end
	else
	  begin
	     if(r_got_req2 && !drain_ds_complete && t_push_miss)
	       begin
		  //$display("rob entry %d enters at cycle %d", r_req2.rob_ptr, r_cycle);
		  
		  if(r_rob_inflight[r_req2.rob_ptr] == 1'b1)
		    $display("entry %d should not be inflight\n", r_req2.rob_ptr);
		  
		  r_rob_inflight[r_req2.rob_ptr] <= 1'b1;
	       end
	     if(r_got_req && r_valid_out && (r_tag_out == r_cache_tag))
	       begin
		  //$display("rob entry %d leaves at cycle %d", r_req.rob_ptr, r_cycle);
		  //if(r_rob_inflight[r_req.rob_ptr] == 1'b0) 
		  //$display("huh %d should be inflight....\n", r_req.rob_ptr);
		  
		  r_rob_inflight[r_req.rob_ptr] <= 1'b0;
	       end
	     else if((r_state == INJECT_UNCACHE_STORE | r_state == INJECT_UNCACHE_LOAD) & mem_rsp_valid)
	       begin
		  //if(r_rob_inflight[r_req.rob_ptr] == 1'b0) 
		  //$display("huh %d should be inflight....\n", r_req.rob_ptr);
		  
		  r_rob_inflight[r_req.rob_ptr] <= 1'b0;
	       end
	     if(t_force_clear_busy)
	       begin
		  r_rob_inflight[t_mem_head.rob_ptr] <= 1'b0;
	       end
	     /* a CACHE hit-op retry completes the op on THIS pass whether it hits,
	      * misses, or tag-mismatches (the line op / L2 scrub is issued either
	      * way) -- clear its inflight bit unconditionally, else a miss/mismatch
	      * chop leaves rob_inflight stuck and the next op reusing that rob_ptr
	      * can never be accepted (l1d wedge, MQ empty). */
	     if(r_got_req & w_is_chop_r)
	       begin
		  r_rob_inflight[r_req.rob_ptr] <= 1'b0;
	       end
	  end
     end

   mem_req_t t_remapped_req2;
   always_comb
     begin
	t_remapped_req2 = r_req2;
	t_remapped_req2.addr = {{(`M_WIDTH-`PA_WIDTH){1'b0}}, w_mapped_addr};
	/* For a TLB-MAPPED access, cacheability comes from the matched page's C
	 * field (CCA==3 -> cached) rather than mipsseg's segment default; for an
	 * unmapped (direct) access keep the segment decision in r_req2.cached.
	 * w_tlb_c is registered in lockstep with w_mapped_addr, so it lines up
	 * with r_req2 here. (This is the proper fix the L2 UNCACHE_WB_TURNAROUND
	 * worked around: a cacheable mapped store was being routed uncached.) */
`ifdef FORCE_UNCACHED
	t_remapped_req2.cached = 1'b0;   /* SCIENCE: force ALL data traffic uncached */
`else
	t_remapped_req2.cached = r_req2.mapped ? (w_tlb_c == 3'd3) : r_req2.cached;
`endif
	/* the queued/replayed req now carries the TLB-translated PHYSICAL address;
	 * mark it unmapped so the replay refills from / re-tags with the PA and
	 * does NOT translate it a second time. */
	t_remapped_req2.mapped = 1'b0;
     end

`ifdef SCSI_CLOBBER_TRACE
   // SCSI INQUIRY-clobber debug (address-hardwired to 0x0841d / 0x083dcb). Was under
   // `ifdef VERILATOR, so it fired on EVERY sim run and floods when a kernel happens
   // to touch 0x083dcb (e.g. IRIX's boot memory-clear). Gated behind its own define.
   // TEMP: log the segment/cacheability of accesses to the IRIX descriptor page.
   always_ff @(posedge clk)
     if(r_got_req2 & (w_mapped_addr[35:12] == 24'h00841d))
       $display("[desc-acc] va=%x pa=%x mapped=%b cca=%0d cached=%b store=%b op=%0d",
		r_req2.addr, w_mapped_addr, r_req2.mapped, w_tlb_c,
		(r_req2.mapped ? (w_tlb_c==3'd3) : r_req2.cached), r_req2.is_store, r_req2.op);
   // TEMP: CPU reads of the INQUIRY buffer (BP=0x083dcb00).  hit=1 -> served from
   // L1D (STALE if it predates the DMA write); hit=0 -> miss/refill (FRESH from DRAM).
   always_ff @(posedge clk)
     if(r_got_req2 & ~r_req2.is_store & (w_mapped_addr[31:8] == 24'h083dcb))
       $display("[bufrd] cyc=%0d pa=%09x pc=%x hit=%b op=%0d data=%016x", r_cycle, w_mapped_addr,
		r_req2.pc, t_hit_cache2, r_req2.op, t_rsp_data2);
   // CPU STORE accepted to the buffer line (cached OR uncached): pc + cached flag +
   // cycle settle the store-vs-dma_cache_inv program/drain order (the clobber source).
   always_ff @(posedge clk)
     if(r_got_req2 & r_req2.is_store & (w_mapped_addr[31:8] == 24'h083dcb))
       $display("[bufwr] cyc=%0d pa=%09x va=%x pc=%x op=%0d data=%016x cached=%b",
		r_cycle, w_mapped_addr, r_req2.addr, r_req2.pc, r_req2.op,
		r_req2.data, (r_req2.mapped ? (w_tlb_c==3'd3) : r_req2.cached));
   // L1D FILL of the buffer line: what data lands (fresh INQUIRY or stale DRAM)?
   always_ff @(posedge clk)
     if(w_cacheable_mem_rsp_valid & (r_mem_req_addr[35:8] == 28'h0083dcb))
       $display("[L1Dfill] pa=%09x data=%08x", r_mem_req_addr, mem_rsp_load_data[31:0]);
   // CPU CACHE op on the buffer line (driver's dma_cache_inv / wback)?
   always_ff @(posedge clk)
     if((r_state == FLUSH_CL) & (flush_cl_addr[35:8] == 28'h0083dcb))
       $display("[L1Dcacheop] cyc=%0d pa=%09x inval=%b", r_cycle, flush_cl_addr, flush_cl_inval);
   // CPU STORE writing the buffer line in L1D (the clobber?).  pc identifies which
   // driver store; cross-ref the interp_mips stream for program order vs dma_cache_inv.
   always_ff @(posedge clk)
     if(t_wr_array & (r_req.addr[31:8] == 24'h883dcb))
       $display("[bufst] cyc=%0d va=%x pc=%x op=%0d data=%x rob_ptr=%0d retry=%b",
		r_cycle, r_req.addr, r_req.pc, r_req.op, t_array_data, r_req.rob_ptr, r_is_retry);
`endif
`ifdef ENABLE_STORE_CHECK
   // Fill-cycle map + bcopy-load read trace for the IRIX o32 .data stale-load bug (henry_tb
   // only; FPGA path unaffected).  Record every line fill (from ~reconfigure on) so the read
   // trace can report when the source line was last loaded; trace the kernel bcopy loads
   // (0x88018f2c..0x88018f48, near the crash) with hit/data.
   always_ff @(posedge clk)
     begin
	if(w_cacheable_mem_rsp_valid)
	  begin
	     /* a line fill: t_mem_head is the miss being serviced -> its pc is the
	      * instruction that brought the line in (speculative if wrong-path). */
	     l1d_fill({32'd0, r_cycle}, t_mem_head.pc, r_mem_req_addr,
		      mem_rsp_load_data[63:0], mem_rsp_load_data[127:64]);
	  end
	if(r_state == FLUSH_CL)
	  begin
	     /* CACHE-op (Index/Hit) invalidate/writeback on this line (funnel path). */
	     l1d_cacheop({32'd0, r_cycle}, 64'd0, flush_cl_addr, flush_cl_inval ? 32'd1 : 32'd0);
	  end
	if(r_snp_inval_done)
	  begin
	     /* Inclusive-L2 back-invalidate drops the line just as a CACHE-op invalidate
	      * does, so the testbench MUST be told -- otherwise its DMA stale-read
	      * detector keeps the line in its suspect set forever and every later touch
	      * is reported as staleness that no longer exists (measured: enabling the
	      * snoop appeared to make every counter WORSE purely from this omission). */
	     l1d_cacheop({32'd0, r_cycle}, r_snp_inval_addr, r_snp_inval_addr, 32'd1);
	  end
	/* mem-pipe CACHE ops (Hit-Invalidate 0x11 -> CHINV etc.) — these carry the op's pc. */
	if(r_got_req & w_is_chop_r)
	  begin
	     l1d_cacheop({32'd0, r_cycle}, r_req.pc, {r_req.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN], {`LG_L1D_CL_LEN{1'b0}}},
			 (r_req.op == MEM_CHINV) ? 32'd1 : 32'd0);
	  end
	if(r_got_req2 & ~r_req2.is_store & (r_req2.pc[31:0] >= 32'h88018f2c)
	   & (r_req2.pc[31:0] <= 32'h88018f48))
	  begin
	     rd_log(r_req2.pc, w_mapped_addr, t_rsp_data2, t_hit_cache2 ? 32'd1 : 32'd0);
	  end
	/* config_cache epilogue stack reloads (small-L1D derail): ld ra/s2/s1/s0,(sp)
	 * at 0x8800f89c-a8 -- probe hit/miss + returned data to pin the stale reload. */
	if(r_got_req2 & ~r_req2.is_store & (r_req2.pc[31:0] >= 32'h8800f89c)
	   & (r_req2.pc[31:0] <= 32'h8800f8a8))
	  begin
	     rd_log(r_req2.pc, w_mapped_addr, t_rsp_data2, t_hit_cache2 ? 32'd1 : 32'd0);
	  end
`ifdef VERBOSE_L1D
	/* SUCCESS side of the trace.  VERBOSE_L1D otherwise only reports what goes
	 * WRONG -- accepts, invalid misses, reloads, replays -- so a run shows one
	 * architectural load being accepted twenty times with no record of which
	 * attempt actually completed or what value it returned.  Pair each
	 * "accepting new op" with a COMPLETE here to read the sequence. */
	if(r_got_req2 & ~r_req2.is_store)
	  begin
	     $display("cycle %d : COMPLETE p2 %s addr %x data %x uuid %d rob ptr %d pc %x",
		      r_cycle, t_hit_cache2 ? "HIT " : "miss", w_mapped_addr, t_rsp_data2,
		      r_req2.uuid, r_req2.rob_ptr, r_req2.pc);
	  end
	if(r_got_req & ~r_req.is_store)
	  begin
	     $display("cycle %d : COMPLETE p1 %s addr %x data %x uuid %d rob ptr %d pc %x",
		      r_cycle, t_hit_cache ? "HIT " : "miss", r_req.addr, t_rsp_data,
		      r_req.uuid, r_req.rob_ptr, r_req.pc);
	  end
	/* and the store side: which store actually reached the array.
	 *
	 * CACHE ops must be split out.  MEM_CHWB/CHWBINV/CHINV ride the store
	 * GRADUATION path (decode_mips sets is_mem, not is_store, and defers the side
	 * effect to post-retirement), so r_req.is_store is set for them and they
	 * printed as "COMPLETE st" with r_req.data -- an uninitialised field for an
	 * instruction that has no data and no destination register.  A cache op read
	 * as a phantom store of zero cost a wrong conclusion about a line being
	 * clobbered; IRIX issues these constantly via dma_cache_inv, so this is not
	 * micro-only. */
	if(r_got_req & r_req.is_store & t_hit_cache & ~w_is_chop_r)
	  begin
	     $display("cycle %d : COMPLETE st addr %x data %x uuid %d rob ptr %d pc %x",
		      r_cycle, r_req.addr, r_req.data, r_req.uuid, r_req.rob_ptr, r_req.pc);
	  end
	if(r_got_req & w_is_chop_r)
	  begin
	     $display("cycle %d : COMPLETE cop %s addr %x uuid %d rob ptr %d pc %x",
		      r_cycle,
		      (r_req.op == MEM_CHINV) ? "hit-inval  " :
		      (r_req.op == MEM_CHWBINV) ? "hit-wb-inval" : "hit-wb     ",
		      r_req.addr, r_req.uuid, r_req.rob_ptr, r_req.pc);
	  end
`endif
`ifdef ENABLE_DMA_STALE_CHK
	/* DMA stale-read detector: EVERY committed L1D read, BOTH ports.  The two
	 * rd_log sites above are gated to a couple of leftover debug PC windows, so
	 * they cannot see general traffic -- and port 1 (the retry / miss-queue /
	 * graduated-store replay path) was never instrumented at all, which is the
	 * blind spot that made "no stale hits" meaningless. */
	if(r_got_req2 & ~r_req2.is_store)
	  begin
	     rd_log(r_req2.pc, w_mapped_addr, t_rsp_data2, t_hit_cache2 ? 32'd1 : 32'd0);
	  end
	if(r_got_req & ~r_req.is_store)
	  begin
	     rd_log(r_req.pc, r_req.addr, t_rsp_data, t_hit_cache ? 32'd1 : 32'd0);
	  end
`endif
     end // always_ff
`endif

   /* incoming byte masks for the port-2 same-set hazard refinement.
    * t_mq_mask  = the request being PUSHED to the miss-queue (registered port2 = r_req2).
    * t_req_mask = the INCOMING port-2 request tested against the MQ (core_mem_req,
    *              the one whose set index feeds t_cache_idx2).  Mirrors nu_l1d. */
   logic [15:0] t_mq_mask, t_req_mask;
   always_comb
     begin
	t_mq_mask = make_mask(r_req2);
	t_req_mask = make_mask(core_mem_req);
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(integer i = 0; i < N_MQ_ENTRIES; i = i + 1)
	       begin
		  r_mq_mask[i] <= 16'd0;
	       end
	  end
	else if(t_push_miss)
	  begin
	     r_mem_q[r_mq_tail_ptr[`LG_MRQ_ENTRIES-1:0] ] <= t_remapped_req2;
	     r_mq_addr[r_mq_tail_ptr[`LG_MRQ_ENTRIES-1:0]] <= t_remapped_req2.addr[IDX_STOP-1:IDX_START];
	     /* only stores carry a mask; loads store 0 (mirror nu_l1d:924) */
	     r_mq_mask[r_mq_tail_ptr[`LG_MRQ_ENTRIES-1:0]] <= t_mq_mask & {16{r_req2.is_store}};
	  end
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_mq_addr_valid <= 'd0;
	  end
	else 
	  begin
	     if(t_push_miss)
	       begin
		  r_mq_addr_valid[r_mq_tail_ptr[`LG_MRQ_ENTRIES-1:0]] <= 1'b1;
	       end
	     if(t_pop_mq)
	       begin
		  r_mq_addr_valid[r_mq_head_ptr[`LG_MRQ_ENTRIES-1:0]] <= 1'b0;		  
	       end
	  end
     end // always_ff@ (posedge clk)

   wire [N_MQ_ENTRIES-1:0] w_hit_busy_addrs;
   logic [N_MQ_ENTRIES-1:0] r_hit_busy_addrs;
   logic 		   r_hit_busy_addr;
   
   wire [N_MQ_ENTRIES-1:0] w_hit_busy_addrs2;
   wire [N_MQ_ENTRIES-1:0] w_addr_intersect;
   logic [N_MQ_ENTRIES-1:0] r_hit_busy_addrs2;
   logic 		   r_hit_busy_addr2;

   generate
      for(genvar i = 0; i < N_MQ_ENTRIES; i=i+1)
	begin
	   assign w_hit_busy_addrs[i] = (t_pop_mq && r_mq_head_ptr[`LG_MRQ_ENTRIES-1:0] == i) ? 1'b0 :
					r_mq_addr_valid[i] ? r_mq_addr[i] == t_cache_idx :
					1'b0;
	   /* byte-overlap between an in-flight (store) MQ entry and the incoming port-2
	    * request.  Loads in the MQ carry mask 0 -> no intersect.  A load overlapping
	    * an in-flight store's bytes still intersects (stays a hazard); only genuinely
	    * disjoint-byte accesses to the same set are released to hit.  Mirrors nu_l1d. */
	   assign w_addr_intersect[i] = (|(r_mq_mask[i] & t_req_mask));
	   assign w_hit_busy_addrs2[i] = //(t_pop_mq && r_mq_head_ptr[`LG_MRQ_ENTRIES-1:0] == i) ? 1'b0 :
					 r_mq_addr_valid[i] ? ((r_mq_addr[i] == t_cache_idx2) & w_addr_intersect[i]) : 1'b0;
	end
   endgenerate
   

   always_ff@(posedge clk)
     begin
	r_hit_busy_addr <= reset ? 1'b0 : |w_hit_busy_addrs;
	r_hit_busy_addrs <= t_got_req ? w_hit_busy_addrs : {{N_MQ_ENTRIES{1'b1}}};
	
	r_hit_busy_addr2 <= reset ? 1'b0 : |w_hit_busy_addrs2;
	r_hit_busy_addrs2 <= t_got_req2 ? w_hit_busy_addrs2 : {{N_MQ_ENTRIES{1'b1}}};
     end


   
   
`ifdef VERBOSE_L1D
   always_ff@(negedge clk)
   begin
      if(t_push_miss)
   	begin
	   $display("pushing uuid %d rob ptr %d at cycle %d", 
		    r_req2.uuid, r_req2.rob_ptr, r_cycle);  
	end
      if(t_pop_mq)
	begin
	   $display("popping uuid %d rob ptr %d at cycle %d", 
		     t_mem_head.uuid, t_mem_head.rob_ptr, r_cycle);
	end
   end
`endif


   always_ff@(posedge clk)
     begin
	r_array_wr_data <= t_array_wr_data;
     end
  
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin

	     r_reload_issue <= 1'b0;
	     r_did_reload <= 1'b0;
	     
	     r_stall_store <= 1'b0;
	     r_is_retry <= 1'b0;
	     r_flush_complete <= 1'b0;
	     r_flush_req <= 1'b0;
	     r_flush_cl_req <= 1'b0;
	     r_chop_wait <= 1'b0;
	     r_chop_beat <= 1'b0;
	     r_flush_cl_beat <= 1'b0;
	     r_tlb_addr <= 'd0;
	     r_cache_idx <= 'd0;
	     r_cache_tag <= 'd0;
	     r_cache_idx2 <= 'd0;
	     r_cache_tag2 <= 'd0;
	     rr_cache_idx <= 'd0;
	     rr_cache_tag <= 'd0;
	     r_miss_addr <= 'd0;
	     r_miss_idx <= 'd0;
	     r_got_req <= 1'b0;
	     r_got_req2 <= 1'b0;
	     
	     rr_got_req <= 1'b0;
	     r_lock_cache <= 1'b0;
	     rr_is_retry <= 1'b0;
	     rr_did_reload <= 1'b0;
	     
	     rr_last_wr <= 1'b0;
	     r_got_non_mem <= 1'b0;
	     r_last_wr <= 1'b0;
	     r_last_rd <= 1'b0;
	     r_last_wr2 <= 1'b0;
	     r_last_rd2 <= 1'b0;	     
	     r_state <= INITIALIZE;
	     r_mem_req_valid <= 1'b0;
	     r_mem_req_cacheable <= 1'b0;
	     r_mem_req_mask <= 'd0;
	     
	     r_mem_req_addr <= 'd0;
	     r_mem_req_store_data <= 'd0;
	     r_mem_req_opcode <= 'd0;
	     r_core_mem_rsp_valid <= 1'b0;
	     r_cache_hits <= 'd0;
	     r_cache_accesses <= 'd0;
	     r_inhibit_write <= 1'b0;
	     r_uncache_wb_dirty <= 1'b0;
	     memq_empty <= 1'b1;
	     r_q_priority <= 1'b0;
	     r_must_forward <= 1'b0;
	     r_must_forward2 <= 1'b0;
	  end
	else
	  begin
	     r_reload_issue <= n_reload_issue;
	     r_did_reload <= n_did_reload;
	     r_uncache_wb_dirty <= n_uncache_wb_dirty;
	     r_stall_store <= n_stall_store;
	     r_is_retry <= n_is_retry;
	     r_flush_complete <= n_flush_complete;
	     r_flush_req <= n_flush_req;
	     r_flush_cl_req <= n_flush_cl_req;
	     r_backinv_ack <= n_backinv_ack;
	     r_backinv_dirty <= n_backinv_dirty;
	     r_backinv_held <= n_backinv_held;
	     r_backinv_data <= n_backinv_data;
	     r_chop_wait <= n_chop_wait;
	     r_chop_beat <= n_chop_beat;
	     r_flush_cl_beat <= n_flush_cl_beat;
	     r_cache_idx <= t_cache_idx;
	     r_tlb_addr <= n_tlb_addr;
	     r_cache_tag <= t_cache_tag;
	     
	     r_cache_idx2 <= t_cache_idx2;
	     r_cache_tag2 <= t_cache_tag2;
	     rr_cache_idx <= r_cache_idx;
	     rr_cache_tag <= r_cache_tag;
	     
	     r_miss_idx <= t_miss_idx;
	     r_miss_addr <= t_miss_addr;
	     r_got_req <= t_got_req;
	     r_got_req2 <= t_got_req2;
	     
	     rr_got_req <= r_got_req;
	     r_lock_cache <= n_lock_cache;
	     rr_is_retry <= r_is_retry;
	     rr_did_reload <= r_did_reload;
	     
	     rr_last_wr <= r_last_wr;
	     r_got_non_mem <= t_got_non_mem;
	     r_last_wr <= n_last_wr;
	     r_last_rd <= n_last_rd;
	     r_last_wr2 <= n_last_wr2;
	     r_last_rd2 <= n_last_rd2;	     
	     r_state <= n_state;
	     r_mem_req_valid <= n_mem_req_valid;
	     r_mem_req_cacheable <= n_mem_req_cacheable;
	     r_mem_req_mask <= n_mem_req_mask;
	     r_mem_req_addr <= n_mem_req_addr;
	     r_mem_req_store_data <= n_mem_req_store_data;
	     r_mem_req_opcode <= n_mem_req_opcode;
	     r_core_mem_rsp_valid <= n_core_mem_rsp_valid;
	     r_cache_hits <= n_cache_hits;
	     r_cache_accesses <= n_cache_accesses;
	     r_inhibit_write <= n_inhibit_write;
	     memq_empty <= mem_q_empty 
			   && drain_ds_complete 
			   && !core_mem_req_valid 
			   && !t_got_req && !t_got_req2 
			   && !t_push_miss
			   && (r_n_inflight == 'd0);
	     
	     r_q_priority <= n_q_priority;
	     r_must_forward  <= t_mh_block & t_pop_mq;
	     r_must_forward2 <= t_cm_block & core_mem_req_ack;
	  end
     end // always_ff@ (posedge clk)

`ifdef VERBOSE_L1D
   always_ff@(negedge clk)
     begin
	if(memq_empty)
	  begin
	     $display("MEMQ EMTPY AT CYCLE %d", r_cycle);
	  end
     end
`endif
   
   always_ff@(posedge clk)
     begin
	r_req <= n_req;
	r_req2 <= n_req2;
	r_core_mem_rsp <= n_core_mem_rsp;
     end

   always_comb
     begin
	t_array_wr_addr = mem_rsp_valid ? r_mem_req_addr[IDX_STOP-1:IDX_START] : r_cache_idx;
	t_array_wr_data = mem_rsp_valid ? mem_rsp_load_data : t_array_data;
	t_array_wr_en = w_cacheable_mem_rsp_valid || t_wr_array;
     end

`ifdef L1D_WATCH_PA
   /* Single-line end-to-end trace.  rmw_snoop.S now stores SELF-DESCRIBING data
    * (value = (line_PA | version) ^ MAGIC), so the version of every copy is readable
    * straight out of the data -- which turns "a store went missing somewhere in the
    * memory system" into a question about WHICH stage last held the new version.
    * VERBOSE_L1D logs the same events unfiltered and produces ~184 MB in 10M cycles;
    * this watches ONE line so the whole life of a failing address is greppable.
    *
    * Compared on bits [27:4] so the same constant matches whether the address in
    * hand is the kseg0 VA (0x883...) or the PA (0x083...). */
   always_ff@(negedge clk)
     begin
	if(t_wr_array & (r_req.addr[27:4] == (`L1D_WATCH_PA >> 4)))
	  begin
	     $display("[l1dwr]   cyc=%0d pa=%x data=%x op=%0d", r_cycle, r_req.addr, t_array_data, r_req.op);
	  end
	if(w_cacheable_mem_rsp_valid & (r_mem_req_addr[27:4] == (`L1D_WATCH_PA >> 4)))
	  begin
	     $display("[l1dfill] cyc=%0d pa=%x data=%x", r_cycle, r_mem_req_addr, mem_rsp_load_data);
	  end
	if(t_snp_won & (r_snp_addr[27:4] == (`L1D_WATCH_PA >> 4)))
	  begin
	     $display("[l1dsnp]  cyc=%0d pa=%x dirty=%b data=%x", r_cycle, r_snp_addr, w_snp_dirty, w_snp_data);
	  end
     end // always_ff@ (negedge clk)
`endif

`ifdef VERBOSE_L1D
   always_ff@(negedge clk)
     begin
   	if(t_wr_array)
   	  begin
   	     $display("cycle %d : WRITING set %d WITH data %x, addr %x, op %d ptr %d, retry %b, uuid %d", 
   		      r_cycle, r_cache_idx, t_array_data, r_req.addr, r_req.op, r_req.rob_ptr, r_is_retry, r_req.uuid);
   	  end	
     end // always_ff@ (negedge clk)
   
   always_comb
     begin
   	if(w_cacheable_mem_rsp_valid)
   	  begin
   	     $display("cycle %d : CACHERELOAD from addr %x -> set %d data %x", 
   		      r_cycle, r_mem_req_addr, r_mem_req_addr[IDX_STOP-1:IDX_START], t_array_wr_data);
   	  end

     end
`endif

   /* ------------------------------------------------------------------------
    * L1D snoop engine.  Services a back-invalidate off read port 2 plus the
    * arbitrated write port, touching NO main-FSM state (r_state, r_cache_idx, or
    * the miss path's held writeback address).  That independence is the point:
    * the main FSM is parked in a wait state on the very fill whose eviction
    * raised the back-invalidate, so anything needing the main FSM to move
    * deadlocks.  Because this cannot, the L2 is free to BLOCK on the ack and keep
    * the correct ordering (back-invalidate -> merge dirty into the L2 line ->
    * normal L2 writeback) instead of the out-of-band DRAM write that corrupted
    * memory.
    * ---------------------------------------------------------------------- */
   always_comb
     begin
	n_snp_state = r_snp_state;
	n_snp_addr = r_snp_addr;
	n_snp_pend = r_snp_pend | w_backinv_req_edge;
	n_backinv_ack = 1'b0;
	n_backinv_dirty = r_backinv_dirty;
	n_backinv_held = 1'b0;
	n_backinv_data = r_backinv_data;
	n_snp_inval_done = 1'b0;
	n_snp_inval_addr = r_snp_inval_addr;
	t_snp_want_p2 = 1'b0;
	t_snp_clear = 1'b0;
	t_snp_won = 1'b0;
	if(w_backinv_req_edge & ~r_snp_pend)
	  begin
	     n_snp_addr = backinv_addr;
	  end
	case(r_snp_state)
	  SNP_IDLE:
	    begin
	       if(r_snp_pend)
		 begin
		    /* shadow arrays are addressed by w_snp_idx continuously, so the
		     * result is simply valid next cycle -- nothing to arbitrate. */
		    n_snp_state = SNP_RD;
		 end
	    end
	  SNP_RD:
	    begin
	       if(w_snp_valid && (w_snp_tag == r_snp_addr[`PA_WIDTH-1:TAG_LSB]))
		 begin
		    /* Only retire the invalidate on a cycle with NO request in flight.
		     * The engine may READ any time, but clearing a valid bit under a
		     * store that hit and is about to write its data loses that store --
		     * silent corruption needing no DMA at all, which is what derailed the
		     * kernel to PC 0.  This is the quiescence the old BACKINV entry guard
		     * provided; dropping it entirely went too far.  Costs nothing in
		     * progress: r_got_req is low while the main FSM waits on a fill, which
		     * is exactly when the L2 is blocked on our ack. */
		    /* A store's array write lands a CYCLE AFTER its request (via the
		     * r_last_wr/rr_last_wr path), so gating on r_got_req alone was one
		     * cycle too narrow: the engine could sample the line, invalidate it,
		     * and then have the in-flight store write into a line that no longer
		     * exists.  Retire-trace proof: `sd ra,0(sp)` dirties the stack line,
		     * the back-invalidate loses it, and the matching `ld ra,0(sp)` /
		     * `jr ra` in kmem_heapzone_index_get jumps to PC 0. */
		    t_snp_won = ~(t_mark_invalid | w_cacheable_mem_rsp_valid | r_got_req |
				  t_wr_array | r_last_wr | rr_last_wr);
		    /* Assigned AFTER t_snp_won, not before: blocking assignments run in
		     * order, so the old placement read the 1'b0 default and the valid bit
		     * was never actually cleared -- the engine acked an invalidate it had
		     * not performed. */
		    t_snp_clear = t_snp_won;
		    if(t_snp_won)
		      begin
			 n_backinv_dirty = w_snp_dirty;
			 n_backinv_data = w_snp_data;
			 n_backinv_held = 1'b1;   /* we had it; it is gone now */
			 n_backinv_ack = 1'b1;
			 n_snp_inval_done = 1'b1;
			 n_snp_inval_addr = r_snp_addr;
			 n_snp_pend = w_backinv_req_edge;
			 n_snp_state = SNP_IDLE;
`ifdef VERBOSE_L1D
			 /* The invalidate ACTUALLY HAPPENING is the one event that was
			  * never logged -- and de6ec6e on this branch was precisely
			  * "snoop engine acked back-invalidates it never performed", so
			  * inferring it from a later probe's behaviour is not good enough. */
			 $display("cycle %d : SNP-CLEAR addr %x idx %d dirty %b data %x -> line dropped",
				  r_cycle, r_snp_addr, w_snp_idx, w_snp_dirty, w_snp_data);
`endif
		      end
`ifdef VERBOSE_L1D
		    else
		      begin
			 /* tag+valid matched but the engine could not take the line this
			  * cycle: acks nothing, stays in SNP_RD and retries. */
			 $display("cycle %d : SNP-BLOCKED addr %x idx %d (mark_inval %b memrsp %b got_req %b wr_array %b last_wr %b rr_last_wr %b)",
				  r_cycle, r_snp_addr, w_snp_idx, t_mark_invalid,
				  w_cacheable_mem_rsp_valid, r_got_req, t_wr_array,
				  r_last_wr, rr_last_wr);
		      end
`endif
		 end
	       else
		 begin
		    n_backinv_dirty = 1'b0;    /* not held here: ack, nothing to write back */
		    n_backinv_ack = 1'b1;
		    n_snp_pend = w_backinv_req_edge;
		    n_snp_state = SNP_IDLE;
`ifdef VERBOSE_L1D
		    /* no tag/valid match: we do NOT hold this line, so acking is correct
		     * and there is nothing to invalidate.  Distinguishes "already gone"
		     * from "cleared it just now". */
		    $display("cycle %d : SNP-NOTHELD addr %x idx %d (snp_valid %b snp_tag %x)",
			     r_cycle, r_snp_addr, w_snp_idx, w_snp_valid, w_snp_tag);
`endif
		 end
	    end
	  default:
	    begin
	       n_snp_state = SNP_IDLE;
	    end
	endcase // case (r_snp_state)
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_backinv_req_d <= 1'b0;
	     r_snp_state <= SNP_IDLE;
	     r_snp_addr <= 'd0;
	     r_snp_pend <= 1'b0;
	     r_snp_inval_done <= 1'b0;
	     r_snp_inval_addr <= 'd0;
	     r_cache_idx2_val <= 1'b0;
	  end
	else
	  begin
	     r_backinv_req_d <= backinv_req;
	     r_snp_state <= n_snp_state;
	     r_snp_addr <= n_snp_addr;
	     r_snp_pend <= n_snp_pend;
	     r_snp_inval_done <= n_snp_inval_done;
	     r_snp_inval_addr <= n_snp_inval_addr;
	     r_cache_idx2_val <= t_p2_core;
	  end
     end // always_ff

`ifdef VERILATOR
   /* Snoop-engine stall watchdog.  Counts while the L2 is ASKING (backinv_req), NOT
    * while our engine is busy: the wedge was this engine sitting IDLE with req held
    * high, so a counter gated on the engine being busy prints nothing at exactly the
    * moment of interest.  req/req_d/edge/pend together separate "never saw the
    * request" from "saw it and dropped it". */
   logic [31:0] r_snp_stall_cnt;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_snp_stall_cnt <= 32'd0;
	  end
	else if(~backinv_req)
	  begin
	     r_snp_stall_cnt <= 32'd0;
	  end
	else
	  begin
	     r_snp_stall_cnt <= r_snp_stall_cnt + 32'd1;
	     if(r_snp_stall_cnt == 32'd10000)
	       begin
		  $display("[snp-stall] cyc=%0d state=%0d addr=%x req=%b req_d=%b edge=%b pend=%b snp_vld=%b tagmatch=%b mark_inval=%b memrsp=%b got_req=%b wr_array=%b last_wr=%b rr_last_wr=%b",
			   r_cycle, r_snp_state, r_snp_addr, backinv_req,
			   r_backinv_req_d, w_backinv_req_edge, r_snp_pend,
			   w_snp_valid,
			   (w_snp_tag == r_snp_addr[`PA_WIDTH-1:TAG_LSB]),
			   t_mark_invalid, w_cacheable_mem_rsp_valid, r_got_req,
			   t_wr_array, r_last_wr, rr_last_wr);
	       end
	  end
     end // always_ff
`endif

`ifdef VERILATOR
   /* ---- SNP-STALE detector (sim only) ----------------------------------------
    * The snoop reads its shadow through a REGISTERED port, so w_snp_data reflects
    * the array as of an earlier cycle, while the quiescence guard
    * (t_wr_array | r_last_wr | rr_last_wr) assumes a particular alignment between
    * that lag and a store's write.  Rather than argue about cycle alignment, keep
    * a golden mirror written from the same signals but read combinationally, and
    * shout the moment the engine hands the L2 data that is not what the array
    * actually holds.  A hit here IS the lost store: the L2 merges this value over
    * a good line, which is how a read-modify-write (bset) loses a single bit. */
   logic [L1D_CL_LEN_BITS-1:0] r_gold_data[(1<<`LG_L1D_NUM_SETS)-1:0];
   integer 		       r_n_snp_stale;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_n_snp_stale <= 0;
	  end
	else
	  begin
	     if(t_snp_won & w_snp_dirty & (w_snp_data !== r_gold_data[w_snp_idx]))
	       begin
		  r_n_snp_stale <= r_n_snp_stale + 1;
		  if(r_n_snp_stale < 20)
		    begin
		       $display("[SNP-STALE] cyc=%0d idx=%0d handed=%x actual=%x",
				r_cycle, w_snp_idx, w_snp_data, r_gold_data[w_snp_idx]);
		    end
	       end
	     if(t_array_wr_en)
	       begin
		  r_gold_data[t_array_wr_addr] <= t_array_wr_data;
	       end
	     if((r_cycle % 64'd10000000) == 64'd9999999)
	       begin
		  $display("[snpstale] cyc=%0d stale_handoffs=%0d", r_cycle, r_n_snp_stale);
	       end
	  end
     end // always_ff
`endif

   /* ---- snoop shadow arrays (option B: full duplication) --------------------
    * Mirror images of dc_tag/dc_valid/dc_dirty/dc_data, written from the SAME
    * write signals so they track cycle-for-cycle, and read at the snoop engine's
    * own index.  This gives the engine a completely independent read path: no
    * port borrowing, no contention with the core, no dependence on the main FSM.
    * NOTE what this does NOT solve: the engine must still clear the valid bit in
    * the REAL array, so write-side ordering against in-flight operations is
    * unchanged by duplication.  Cost ~32Kb BRAM for the data mirror.
    * ------------------------------------------------------------------------ */
   wire [N_TAG_BITS-1:0]     w_snp_tag;
   wire 		     w_snp_valid, w_snp_dirty;
   wire [L1D_CL_LEN_BITS-1:0] w_snp_data;

   ram2r1w #(.WIDTH(N_TAG_BITS), .LG_DEPTH(`LG_L1D_NUM_SETS)) snp_tag
     (
      .clk(clk),
      .rd_addr0(w_snp_idx),
      .rd_addr1(w_snp_idx),
      .wr_addr(r_mem_req_addr[IDX_STOP-1:IDX_START]),
      .wr_data(r_mem_req_addr[`PA_WIDTH-1:TAG_LSB]),
      .wr_en(w_cacheable_mem_rsp_valid),
      .rd_data0(w_snp_tag),
      .rd_data1()
      );

   ram2r1w #(.WIDTH(L1D_CL_LEN_BITS), .LG_DEPTH(`LG_L1D_NUM_SETS)) snp_data
     (
      .clk(clk),
      .rd_addr0(w_snp_idx),
      .rd_addr1(w_snp_idx),
      .wr_addr(t_array_wr_addr),
      .wr_data(t_array_wr_data),
      .wr_en(t_array_wr_en),
      .rd_data0(w_snp_data),
      .rd_data1()
      );

   ram2r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1D_NUM_SETS)) snp_dirty
     (
      .clk(clk),
      .rd_addr0(w_snp_idx),
      .rd_addr1(w_snp_idx),
      .wr_addr(t_dirty_wr_addr),
      .wr_data(t_dirty_value),
      .wr_en(t_write_dirty_en),
      .rd_data0(w_snp_dirty),
      .rd_data1()
      );

   ram2r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1D_NUM_SETS)) snp_valid
     (
      .clk(clk),
      .rd_addr0(w_snp_idx),
      .rd_addr1(w_snp_idx),
      .wr_addr(t_valid_wr_addr),
      .wr_data(t_valid_value),
      .wr_en(t_write_valid_en),
      .rd_data0(w_snp_valid),
      .rd_data1()
      );

 ram2r1w #(.WIDTH(N_TAG_BITS), .LG_DEPTH(`LG_L1D_NUM_SETS)) dc_tag
     (
      .clk(clk),
      .rd_addr0(t_cache_idx),
      .rd_addr1(w_p2_addr),
      .wr_addr(r_mem_req_addr[IDX_STOP-1:IDX_START]),
      .wr_data(r_mem_req_addr[`PA_WIDTH-1:TAG_LSB]),
      .wr_en(w_cacheable_mem_rsp_valid),
      .rd_data0(r_tag_out),
      .rd_data1(r_tag_out2)
      );
     

   ram2r1w #(.WIDTH(L1D_CL_LEN_BITS), .LG_DEPTH(`LG_L1D_NUM_SETS)) dc_data
     (
      .clk(clk),
      .rd_addr0(t_cache_idx),
      .rd_addr1(w_p2_addr),
      .wr_addr(t_array_wr_addr),
      .wr_data(t_array_wr_data),
      .wr_en(t_array_wr_en),
      .rd_data0(r_array_out),
      .rd_data1(r_array_out2)
      );

   logic t_dirty_value;
   logic t_write_dirty_en;
   logic [`LG_L1D_NUM_SETS-1:0] t_dirty_wr_addr;
   
   always_comb
     begin
	t_dirty_value = 1'b0;
	t_write_dirty_en = 1'b0;
	t_dirty_wr_addr = r_cache_idx;
	if(t_mark_invalid)
	  begin
	     t_write_dirty_en = 1'b1;	     
	  end
	else if(w_cacheable_mem_rsp_valid)
	  begin
	     t_dirty_wr_addr = r_mem_req_addr[IDX_STOP-1:IDX_START];
	     t_write_dirty_en = 1'b1;
	  end
	else if(t_wr_array)
	  begin
	     t_dirty_value = 1'b1;
	     t_write_dirty_en = 1'b1;
	  end	
     end
   
   ram2r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1D_NUM_SETS)) dc_dirty
     (
      .clk(clk),
      .rd_addr0(t_cache_idx),
      .rd_addr1(w_p2_addr),
      .wr_addr(t_dirty_wr_addr),
      .wr_data(t_dirty_value),
      .wr_en(t_write_dirty_en),
      .rd_data0(r_dirty_out),
      .rd_data1(r_dirty_out2)
      );


   logic t_valid_value;
   logic t_write_valid_en;
   logic [`LG_L1D_NUM_SETS-1:0] t_valid_wr_addr;

   always_comb
     begin
	t_valid_value = 1'b0;
	t_write_valid_en = 1'b0;
	t_valid_wr_addr = r_cache_idx;
	if(t_mark_invalid)
	  begin
	     t_write_valid_en = 1'b1;
	  end
	else if(w_cacheable_mem_rsp_valid)
	  begin
	     t_valid_wr_addr = r_mem_req_addr[IDX_STOP-1:IDX_START];
	     t_valid_value = !r_inhibit_write;
	     t_write_valid_en = 1'b1;
	  end
	else if(t_snp_clear)
	  begin
	     /* lowest priority -- the snoop engine simply retries next cycle if the
	      * fill or the main pipeline wanted the single write port. */
	     t_valid_wr_addr = w_snp_idx;
	     t_valid_value = 1'b0;
	     t_write_valid_en = 1'b1;
	  end
     end // always_comb
      
   ram2r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1D_NUM_SETS)) dc_valid
     (
      .clk(clk),
      .rd_addr0(t_cache_idx),
      .rd_addr1(w_p2_addr),
      .wr_addr(t_valid_wr_addr),
      .wr_data(t_valid_value),
      .wr_en(t_write_valid_en),
      .rd_data0(r_valid_out),
      .rd_data1(r_valid_out2)
      );

   generate
      for(genvar i = 0; i < WORDS_PER_CL; i=i+1)
	begin
	   assign t_array_out_b32[i] = bswap32(t_data[((i+1)*32)-1:i*32]);
	end
   endgenerate


   always_comb
     begin
	t_data2 = r_got_req2 && r_must_forward2 ? r_array_wr_data : r_array_out2;
	t_w32_2 = (select_cl32(t_data2, r_req2.addr[WORD_STOP-1:WORD_START]));
	t_bswap_w32_2 = bswap32(t_w32_2);

	t_hit_cache2 = r_valid_out2 && (r_tag_out2 == w_tlb_tag2) && r_got_req2 && 
		      (r_state == ACTIVE);
	t_rsp_dst_valid2 = 1'b0;
	t_rsp_fp_dst_valid2 = 1'b0;
	t_rsp_data2 = 'd0;
	
	case(r_req2.op)
	  MEM_LB:
	    begin
	       case(r_req2.addr[1:0])
		 2'd0:
		   begin
		      t_rsp_data2 = {{56{t_w32_2[7]}}, t_w32_2[7:0]};
		   end
		 2'd1:
		   begin
		      t_rsp_data2 = {{56{t_w32_2[15]}}, t_w32_2[15:8]};
		   end
		 2'd2:
		   begin
		      t_rsp_data2 = {{56{t_w32_2[23]}}, t_w32_2[23:16]};
		   end
		 2'd3:
		   begin
		      t_rsp_data2 = {{56{t_w32_2[31]}}, t_w32_2[31:24]};
		   end
	       endcase
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end
	  MEM_LBU:
	    begin
	       case(r_req2.addr[1:0])
		 2'd0:
		   begin
		      t_rsp_data2 = {56'd0, t_w32_2[7:0]};
		   end
		 2'd1:
		   begin
		      t_rsp_data2 = {56'd0, t_w32_2[15:8]};
		   end
		 2'd2:
		   begin
		      t_rsp_data2 = {56'd0, t_w32_2[23:16]};
		   end
		 2'd3:
		   begin
		      t_rsp_data2 = {56'd0, t_w32_2[31:24]};
		   end
	       endcase 
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;	       
	    end
	  MEM_LH:
	    begin
	       case(r_req2.addr[1])
		 1'b0:
		   begin
		      t_rsp_data2 = {{48{sext16(t_w32_2[15:0])}}, bswap16(t_w32_2[15:0])};
		   end
		 1'b1:
		   begin
		      t_rsp_data2 = {{48{sext16(t_w32_2[31:16])}}, bswap16(t_w32_2[31:16])};	     
		   end
	       endcase 
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end
	  MEM_LHU:
	    begin
	       t_rsp_data2 = {48'd0, bswap16(r_req2.addr[1] ? t_w32_2[31:16] : t_w32_2[15:0])};
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;	       
	    end
	  MEM_LW:
	    begin
	       t_rsp_data2 = {{32{t_bswap_w32_2[31]}}, t_bswap_w32_2};
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end
	  MEM_LWU:
	    begin
	       t_rsp_data2 = {32'd0, t_bswap_w32_2};
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end
	  MEM_LL:
	    begin
	       t_rsp_data2 = {{32{t_bswap_w32_2[31]}}, t_bswap_w32_2};
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end
	  MEM_LLD:
	    begin
	       t_rsp_data2 = bswap64(select_cl64(t_data2, r_req2.addr[DWORD_START]));
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end
	  MEM_LD:
	    begin
	       t_rsp_data2 = bswap64(select_cl64(t_data2, r_req2.addr[DWORD_START]));
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end
	  MEM_LWR:
	    begin
	       case(r_req2.addr[1:0])
		 2'd0:
		   begin
		      t_rsp_data2 = {{32{r_req2.data[31]}}, r_req2.data[31:8], t_bswap_w32_2[31:24]};
		   end
		 2'd1:
		   begin
		      t_rsp_data2 = {{32{r_req2.data[31]}}, r_req2.data[31:16], t_bswap_w32_2[31:16]};
		   end
		 2'd2:
		   begin
		      t_rsp_data2 = {{32{r_req2.data[31]}}, r_req2.data[31:24], t_bswap_w32_2[31:8]};				       
		   end
		 2'd3:
		   begin
		      t_rsp_data2 = {{32{t_bswap_w32_2[31]}}, t_bswap_w32_2};
		   end
	       endcase // case (r_req.addr[1:0])
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end
	  MEM_LWL:
	    begin
	       case(r_req2.addr[1:0])
		 2'd0:
		   begin
		      t_rsp_data2 = {{32{t_bswap_w32_2[31]}}, t_bswap_w32_2};
		   end
		 2'd1:
		   begin
		      t_rsp_data2 = {{32{t_bswap_w32_2[23]}}, t_bswap_w32_2[23:0], r_req2.data[7:0]};
		   end
		 2'd2:
		   begin
		      t_rsp_data2 = {{32{t_bswap_w32_2[15]}}, t_bswap_w32_2[15:0], r_req2.data[15:0]};
		   end
		 2'd3:
		   begin
		      t_rsp_data2 = {{32{t_bswap_w32_2[7]}}, t_bswap_w32_2[7:0], r_req2.data[23:0]};
		   end
	       endcase // case (r_req.addr[1:0])
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;	       
	    end // case: MEM_LWL
	  default:
	    begin
	    end
	endcase
     end
   
   always_comb
     begin
	t_data = (r_state == INJECT_UNCACHE_LOAD) ? mem_rsp_load_data : (r_got_req & r_must_forward ? r_array_wr_data : r_array_out);
	
	t_w32 = (select_cl32(t_data, r_req.addr[WORD_STOP-1:WORD_START]));
	t_bswap_w32 = bswap32(t_w32);
	t_hit_cache = r_valid_out && (r_tag_out == r_cache_tag) && r_got_req && 
		      (r_state == ACTIVE || r_state == INJECT_RELOAD);
	t_array_data = 'd0;
	t_wr_array = 1'b0;
	t_rsp_dst_valid = 1'b0;
	t_rsp_fp_dst_valid = 1'b0;
	t_rsp_data = 'd0;
	
	case(r_req.op)
	  MEM_LB:
	    begin
	       case(r_req.addr[1:0])
		 2'd0:
		   begin
		      t_rsp_data = {{56{t_w32[7]}}, t_w32[7:0]};
		   end
		 2'd1:
		   begin
		      t_rsp_data = {{56{t_w32[15]}}, t_w32[15:8]};
		   end
		 2'd2:
		   begin
		      t_rsp_data = {{56{t_w32[23]}}, t_w32[23:16]};
		   end
		 2'd3:
		   begin
		      t_rsp_data = {{56{t_w32[31]}}, t_w32[31:24]};
		   end
	       endcase
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end
	  MEM_LBU:
	    begin
	       case(r_req.addr[1:0])
		 2'd0:
		   begin
		      t_rsp_data = {56'd0, t_w32[7:0]};
		   end
		 2'd1:
		   begin
		      t_rsp_data = {56'd0, t_w32[15:8]};
		   end
		 2'd2:
		   begin
		      t_rsp_data = {56'd0, t_w32[23:16]};
		   end
		 2'd3:
		   begin
		      t_rsp_data = {56'd0, t_w32[31:24]};
		   end
	       endcase // case (r_req.addr[1:0])
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;	       
	    end
	  MEM_LH:
	    begin
	       case(r_req.addr[1])
		 1'b0:
		   begin
		      t_rsp_data = {{48{sext16(t_w32[15:0])}}, bswap16(t_w32[15:0])};
		   end
		 1'b1:
		   begin
		      t_rsp_data = {{48{sext16(t_w32[31:16])}}, bswap16(t_w32[31:16])};	     
		   end
	       endcase // case (r_req.addr[1])
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end
	  MEM_LHU:
	    begin
	       t_rsp_data = {48'd0, bswap16(r_req.addr[1] ? t_w32[31:16] : t_w32[15:0])};
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;	       
	    end
	  MEM_LW:
	    begin
	       t_rsp_data = {{32{t_bswap_w32[31]}}, t_bswap_w32};
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end
	  MEM_LWU:
	    begin
	       t_rsp_data = {32'd0, t_bswap_w32};
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end
	  MEM_LL:
	    begin
	       t_rsp_data = {{32{t_bswap_w32[31]}}, t_bswap_w32};
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end
	  MEM_LLD:
	    begin
	       t_rsp_data = bswap64(select_cl64(t_data, r_req.addr[DWORD_START]));
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end
	  MEM_LD:
	    begin
	       /* High word at addr, low word at addr+4 (big-endian doubleword). */
	       t_rsp_data = bswap64(select_cl64(t_data, r_req.addr[DWORD_START]));
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end
	  MEM_LWR:
	    begin
	       case(r_req.addr[1:0])
		 2'd0:
		   begin
		      t_rsp_data = {{32{r_req.data[31]}}, r_req.data[31:8], t_bswap_w32[31:24]};
		   end
		 2'd1:
		   begin
		      t_rsp_data = {{32{r_req.data[31]}}, r_req.data[31:16], t_bswap_w32[31:16]};
		   end
		 2'd2:
		   begin
		      t_rsp_data = {{32{r_req.data[31]}}, r_req.data[31:24], t_bswap_w32[31:8]};				       
		   end
		 2'd3:
		   begin
		      t_rsp_data = {{32{t_bswap_w32[31]}}, t_bswap_w32};
		   end
	       endcase // case (r_req.addr[1:0])
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end
	  MEM_LWL:
	    begin
	       case(r_req.addr[1:0])
		 2'd0:
		   begin
		      t_rsp_data = {{32{t_bswap_w32[31]}}, t_bswap_w32};
		   end
		 2'd1:
		   begin
		      t_rsp_data = {{32{t_bswap_w32[23]}}, t_bswap_w32[23:0], r_req.data[7:0]};
		   end
		 2'd2:
		   begin
		      t_rsp_data = {{32{t_bswap_w32[15]}}, t_bswap_w32[15:0], r_req.data[15:0]};
		   end
		 2'd3:
		   begin
		      t_rsp_data = {{32{t_bswap_w32[7]}}, t_bswap_w32[7:0], r_req.data[23:0]};
		   end
	       endcase // case (r_req.addr[1:0])
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;	       
	    end // case: MEM_LWL
	  MEM_LDL:
	    begin
	       /* Doubleword-aligned base: high word (MSW, lower addr) at dw_hi_idx,
		* low word (LSW, higher addr) at dw_hi_idx+1.
		* t_dword[63:56]=byte0(lowest addr) .. t_dword[7:0]=byte7(highest addr). */
	       begin
		  logic [63:0] 		       t_dword;
		  t_dword = bswap64(select_cl64(t_data, r_req.addr[DWORD_START]));
		  case(r_req.addr[2:0])
		    3'd0: t_rsp_data = t_dword;
		    3'd1: t_rsp_data = {t_dword[55:0], r_req.data[7:0]};
		    3'd2: t_rsp_data = {t_dword[47:0], r_req.data[15:0]};
		    3'd3: t_rsp_data = {t_dword[39:0], r_req.data[23:0]};
		    3'd4: t_rsp_data = {t_dword[31:0], r_req.data[31:0]};
		    3'd5: t_rsp_data = {t_dword[23:0], r_req.data[39:0]};
		    3'd6: t_rsp_data = {t_dword[15:0], r_req.data[47:0]};
		    3'd7: t_rsp_data = {t_dword[7:0],  r_req.data[55:0]};
		  endcase
	       end
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end // case: MEM_LDL
	  MEM_LDR:
	    begin
	       begin
		  logic [63:0] 		       t_dword;
		  t_dword = bswap64(select_cl64(t_data, r_req.addr[DWORD_START]));
		  case(r_req.addr[2:0])
		    3'd0: t_rsp_data = {r_req.data[63:8],  t_dword[63:56]};
		    3'd1: t_rsp_data = {r_req.data[63:16], t_dword[63:48]};
		    3'd2: t_rsp_data = {r_req.data[63:24], t_dword[63:40]};
		    3'd3: t_rsp_data = {r_req.data[63:32], t_dword[63:32]};
		    3'd4: t_rsp_data = {r_req.data[63:40], t_dword[63:24]};
		    3'd5: t_rsp_data = {r_req.data[63:48], t_dword[63:16]};
		    3'd6: t_rsp_data = {r_req.data[63:56], t_dword[63:8]};
		    3'd7: t_rsp_data = t_dword;
		  endcase
	       end
	       t_rsp_dst_valid = r_req.dst_valid & t_hit_cache;
	    end // case: MEM_LDR
	  MEM_SDL:
	    begin
	       begin
		  logic [63:0] 		       t_dword, t_sdl_merged;
		  t_dword = bswap64(select_cl64(t_data, r_req.addr[DWORD_START]));
		  /* SDL: store rt's high bytes at positions [ma..7]; preserve mem [0..ma-1].
		   * For ma=k: merged = {t_dword[63:64-k*8], data[63:k*8]}
		   * (top k bytes from memory, bottom (8-k) bytes = data shifted right k bytes). */
		  case(r_req.addr[2:0])
		    3'd0: t_sdl_merged = r_req.data;
		    3'd1: t_sdl_merged = {t_dword[63:56], r_req.data[63:8]};
		    3'd2: t_sdl_merged = {t_dword[63:48], r_req.data[63:16]};
		    3'd3: t_sdl_merged = {t_dword[63:40], r_req.data[63:24]};
		    3'd4: t_sdl_merged = {t_dword[63:32], r_req.data[63:32]};
		    3'd5: t_sdl_merged = {t_dword[63:24], r_req.data[63:40]};
		    3'd6: t_sdl_merged = {t_dword[63:16], r_req.data[63:48]};
		    3'd7: t_sdl_merged = {t_dword[63:8],  r_req.data[63:56]};
		  endcase
		  t_array_data = merge_cl64(t_data, bswap64(t_sdl_merged), r_req.addr[DWORD_START]);
	       end
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
	    end // case: MEM_SDL
	  MEM_SDR:
	    begin
	       begin
		  logic [63:0] 		       t_dword, t_sdr_merged;
		  t_dword = bswap64(select_cl64(t_data, r_req.addr[DWORD_START]));
		  /* SDR: store rt's low bytes at positions [0..ma]; preserve mem [ma+1..7] */
		  case(r_req.addr[2:0])
		    3'd0: t_sdr_merged = {r_req.data[7:0],  t_dword[55:0]};
		    3'd1: t_sdr_merged = {r_req.data[15:0], t_dword[47:0]};
		    3'd2: t_sdr_merged = {r_req.data[23:0], t_dword[39:0]};
		    3'd3: t_sdr_merged = {r_req.data[31:0], t_dword[31:0]};
		    3'd4: t_sdr_merged = {r_req.data[39:0], t_dword[23:0]};
		    3'd5: t_sdr_merged = {r_req.data[47:0], t_dword[15:0]};
		    3'd6: t_sdr_merged = {r_req.data[55:0], t_dword[7:0]};
		    3'd7: t_sdr_merged = r_req.data;
		  endcase
		  t_array_data = merge_cl64(t_data, bswap64(t_sdr_merged), r_req.addr[DWORD_START]);
	       end
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
	    end // case: MEM_SDR
	  MEM_SB:
	    begin
	       case(r_req.addr[1:0])
		 2'd0:
		   begin
		      t_array_data = merge_cl32(t_data, {t_w32[31:8], r_req.data[7:0]}, r_req.addr[WORD_STOP-1:WORD_START]);
		   end
		 2'd1:
		   begin
		      t_array_data = merge_cl32(t_data, {t_w32[31:16], r_req.data[7:0], t_w32[7:0]}, r_req.addr[WORD_STOP-1:WORD_START]);				     				     
		   end
		 2'd2:
		   begin
		      t_array_data = merge_cl32(t_data, {t_w32[31:24], r_req.data[7:0], t_w32[15:0]}, r_req.addr[WORD_STOP-1:WORD_START]);				     
		   end
		 2'd3:
		   begin
		      t_array_data = merge_cl32(t_data, {r_req.data[7:0], t_w32[23:0]}, r_req.addr[WORD_STOP-1:WORD_START]);
		   end
	       endcase // case (r_req.addr[1:0])
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
	    end
	  MEM_SH:
	    begin
	       case(r_req.addr[1])
		 1'b0:
		   begin
		      t_array_data = merge_cl32(t_data, {t_w32[31:16], bswap16(r_req.data[15:0])}, r_req.addr[WORD_STOP-1:WORD_START]);
		   end
		 1'b1:
		   begin
		      t_array_data = merge_cl32(t_data, {bswap16(r_req.data[15:0]), t_w32[15:0]}, r_req.addr[WORD_STOP-1:WORD_START]);				     
		   end
	       endcase
	       //t_wr_array = t_hit_cache && t_can_release_store;
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
	    end
	  MEM_SW:
	    begin
	       t_array_data = merge_cl32(t_data, bswap32(r_req.data[31:0]), r_req.addr[WORD_STOP-1:WORD_START]);
	       //t_wr_array = t_hit_cache && t_can_release_store;
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
	    end
	  MEM_SD:
	    begin
	       /* High word at addr, low word at addr+4 (big-endian doubleword). */
	       t_array_data = merge_cl64(t_data, bswap64(r_req.data[63:0]), r_req.addr[DWORD_START]);
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
	    end
	  MEM_SC:
	    begin
	       /* A FAILED SC must not merge its store data into t_array_data: that data
		* is forwarded to a same-line load via r_array_wr_data (store->load
		* forwarding, see r_must_forward) even though the array write is gated
		* off.  Keep the line unchanged so a failed SC is invisible to a later load. */
	       t_array_data = r_sc_should_write ? merge_cl32(t_data, bswap32(r_req.data[31:0]), r_req.addr[WORD_STOP-1:WORD_START]) : t_data;
	       t_rsp_data = 'd0;
	       t_rsp_dst_valid = 1'b0;
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload) && r_sc_should_write;
	    end
	  MEM_SCD:
	    begin
	       t_array_data = r_sc_should_write ? merge_cl64(t_data, bswap64(r_req.data[63:0]), r_req.addr[DWORD_START]) : t_data;
	       t_rsp_data = 'd0;
	       t_rsp_dst_valid = 1'b0;
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload) && r_sc_should_write;
	    end
	  MEM_SWR:
	    begin
	       case(r_req.addr[1:0])
		 2'd0:
		   begin
		      t_array_data = merge_cl32(t_data, bswap32({r_req.data[7:0], t_bswap_w32[23:0]}), r_req.addr[WORD_STOP-1:WORD_START]);
		   end
		 2'd1:
		   begin
		      t_array_data = merge_cl32(t_data, bswap32({r_req.data[15:0], t_bswap_w32[15:0]}), r_req.addr[WORD_STOP-1:WORD_START]);
		   end
		 2'd2:
		   begin
		      t_array_data = merge_cl32(t_data, bswap32({r_req.data[23:0], t_bswap_w32[7:0]}), r_req.addr[WORD_STOP-1:WORD_START]);
		   end
		 2'd3:
		   begin
		      t_array_data = merge_cl32(t_data, bswap32(r_req.data[31:0]), r_req.addr[WORD_STOP-1:WORD_START]);
		   end
	       endcase // case (r_req.addr[1:0])
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
	    end
	  MEM_SWL:
	    begin
	       case(r_req.addr[1:0])
		 2'd0:
		   begin
		      t_array_data = merge_cl32(t_data, bswap32(r_req.data[31:0]), r_req.addr[WORD_STOP-1:WORD_START]);
		   end
		 2'd1:
		   begin
		      t_array_data = merge_cl32(t_data, bswap32({t_bswap_w32[31:24], r_req.data[31:8]}), r_req.addr[WORD_STOP-1:WORD_START]);
		   end
		 2'd2:
		   begin
		      t_array_data = merge_cl32(t_data, bswap32({t_bswap_w32[31:16], r_req.data[31:16]}), r_req.addr[WORD_STOP-1:WORD_START]);
		   end
		 2'd3:
		   begin
		      t_array_data = merge_cl32(t_data, bswap32({t_bswap_w32[31:8], r_req.data[31:24]}), r_req.addr[WORD_STOP-1:WORD_START]);
		   end
	       endcase // case (r_req.addr[1:0])
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
	    end
	  default:
	    begin
	    end
	endcase // case r_req.op
     end



   
   logic [31:0] r_fwd_cnt;
   always_ff@(posedge clk)
     begin
	r_fwd_cnt <= reset ? 'd0 : (r_got_req && r_must_forward ? r_fwd_cnt + 'd1 : r_fwd_cnt);
	//$display("at cycle %d, state = %d", r_cycle, r_state);
     end

   /* memory system should be idle before dealing with an uncachable req */
   wire w_memq_empty = mem_q_empty & (r_n_inflight == 'd0) & (r_state == ACTIVE);
   // EXPERIMENT: fence mapped cached LOADS to ROB-head too (non-speculative), so a
   // speculative refill can't re-cache a stale DMA-target buffer line ahead of the
   // driver's dma_cache_inv (the R10000 read-path hazard).  DMA buffers are mapped
   // CCA=3 pages, so this targets them while leaving unmapped kseg0 at full speed.
`ifdef ENABLE_KERNEL_LOAD_FENCE
   wire w_fence_load = core_mem_req_valid & ~core_mem_req.is_store &
                       core_mem_req.mapped & core_mem_req.cached;
`else
   wire w_fence_load = 1'b0;
`endif
   /* Fix A: an uncached op that is the REGULAR delay slot of a complete, faulted
    * branch at the ROB head is non-speculative (the delay slot is guaranteed to
    * commit), so let it issue even though it is not itself at the head and the
    * branch has not retired into DRAIN yet.  Without this, a mispredicted `jr ra`
    * with an uncached-store delay slot (ip22_eeprom_read) deadlocks: the branch's
    * retire gate waits for the delay slot to complete, but the delay slot's uncached
    * issue waits for at-head/drain_ds_complete, which needs the branch to retire. */
   wire w_uncached_ds_ok = head_of_rob_ds_committable &
			   (next_head_of_rob_ptr == core_mem_req.rob_ptr);
`ifdef ENABLE_MEM_HEAD_SERIALIZE
   wire w_serialize_all = core_mem_req_valid;   /* fence EVERY mem op to ROB head */
`else
   wire w_serialize_all = 1'b0;
`endif
   wire	w_uncachable_req = (core_mem_req_valid & ((core_mem_req.cached==1'b0) | w_fence_load | w_serialize_all)) ?
	(((head_of_rob_ptr_valid ? (head_of_rob_ptr == core_mem_req.rob_ptr) : 1'b0) | drain_ds_complete | w_uncached_ds_ok)): 1'b1;

   //always@(negedge clk)
   //begin
   //if(core_mem_req_valid & (core_mem_req.cached==1'b0))
   //begin
   //$display("uncachable with rob ptr %d, head of rob %d, drain_ds_complete = %b", 
   //core_mem_req.rob_ptr, head_of_rob_ptr, drain_ds_complete);
   //end
   //end
   
   // always_ff@(negedge clk)
   //   begin
   // 	if(core_mem_req_valid & core_mem_req.is_atomic)
   // 	  begin
   // 	     $display("cycle %d, w_uncachable_req = %b, addr = %x, rob_ptr = %x, is_store = %b, pc = %x, cached = %b, mem_q_empty = %b, inflight %d", 
   // 		      r_cycle,
   // 		      w_uncachable_req, 
   // 		      core_mem_req.addr,
   // 		      core_mem_req.rob_ptr,
   // 		      core_mem_req.is_store,
   // 		      core_mem_req.pc, 
   // 		      core_mem_req.cached,
   // 		      mem_q_empty,
   // 		      r_n_inflight);
   // 	  end
   //   end


   
   tlb dtlb (
	     .clk(clk),
	     .reset(reset),
	     .asid(asid),
	     .active(core_mem_req.mapped),
	     .req(t_got_req2),
	     .va(n_tlb_addr),
	     .pa(w_mapped_addr),
	     .hit(w_tlb_hit),
	     .hit_index(w_tlb_index),
	     .dirty(w_tlb_dirty),
	     .valid(w_tlb_valid),
	     .cache_attr(w_tlb_c),
	     .out_of_range(w_tlb_oor),
	     .tlb_entry_in_valid(tlb_entry_in_valid),
	     .tlb_entry_in(tlb_entry_in)
	     );
   


   //always@(negedge clk)
   //begin
   //if(r_cycle > 'd23594309)
   //begin
   //	     $display("memory queue empty %b", mem_q_empty);
   //	  end
   //  end
   
   
   always_comb
     begin
	t_got_rd_retry = 1'b0;
	t_port2_hit_cache = r_valid_out2 && (r_tag_out2 == w_tlb_tag2);
	t_mem_req_mask = make_mask(r_req);
	n_state = r_state;
	t_miss_idx = r_miss_idx;
	t_miss_addr = r_miss_addr;
	t_cache_idx = 'd0;
	t_cache_tag = 'd0;
	
	t_cache_idx2 = 'd0;
	t_p2_core = 1'b0;
	t_cache_tag2 = 'd0;	

	n_tlb_addr = r_tlb_addr;
	
	t_got_req = 1'b0;
	t_got_req2 = 1'b0;
	
	t_got_non_mem = 1'b0;
	n_last_wr = 1'b0;
	n_last_rd = 1'b0;
	n_last_wr2 = 1'b0;
	n_last_rd2 = 1'b0;
	
	t_got_miss = 1'b0;
	t_push_miss = 1'b0;
	
	n_req = r_req;
	n_req2 = r_req2;
	
	core_mem_req_ack = 1'b0;
	core_store_data_ack = 1'b0;
	
	n_mem_req_valid = 1'b0;
	n_mem_req_cacheable = r_mem_req_cacheable;
	n_mem_req_mask = r_mem_req_mask;
	n_mem_req_addr = r_mem_req_addr;
	n_mem_req_store_data = r_mem_req_store_data;
	n_mem_req_opcode = r_mem_req_opcode;
	t_pop_mq = 1'b0;
	n_core_mem_rsp_valid = 1'b0;
	
	n_core_mem_rsp.data = r_req.addr;
	n_core_mem_rsp.rob_ptr = r_req.rob_ptr;
	n_core_mem_rsp.dst_ptr = r_req.dst_ptr;
	n_core_mem_rsp.dst_valid = 1'b0;
	n_core_mem_rsp.fp_dst = r_req.fp_dst;
	n_core_mem_rsp.fp_merge = r_req.fp_merge;   /* FR=0 lwc1 merge (carried to writeback) */
	n_core_mem_rsp.fp_hi = r_req.fp_hi;
	n_core_mem_rsp.fp_pres = r_req.fp_pres;
	n_core_mem_rsp.bad_addr = 1'b0;
	
	n_core_mem_rsp.tlb_refill = 1'b0;
	n_core_mem_rsp.tlb_invalid = 1'b0;
	n_core_mem_rsp.tlb_modified = 1'b0;
	n_core_mem_rsp.tlb_hit = 1'b0;
	n_core_mem_rsp.tlb_index = 6'd0;
	
	n_cache_accesses = r_cache_accesses;
	n_cache_hits = r_cache_hits;
	
	n_flush_req = r_flush_req | flush_req;
	n_flush_cl_req = r_flush_cl_req | flush_cl_req;
	/* latch, never sample a pulse: single-cycle requests have been LOST on this
	 * interface before (hence the sticky latches in core_l1d_l1i). */
	n_flush_complete = 1'b0;
	t_addr = 'd0;
	
	n_inhibit_write = r_inhibit_write;
	
	t_mark_invalid = 1'b0;
	n_is_retry = 1'b0;
	t_reset_graduated = 1'b0;
	n_chop_wait = r_chop_wait;
	n_chop_beat = r_chop_beat;
	n_flush_cl_beat = r_flush_cl_beat;
	t_force_clear_busy = 1'b0;
	
	t_incr_busy = 1'b0;

	n_stall_store = 1'b0;
	n_q_priority = !r_q_priority;
	
	n_reload_issue = r_reload_issue;
	n_did_reload = 1'b0;
	n_uncache_wb_dirty = r_uncache_wb_dirty;
	n_lock_cache = r_lock_cache;
	
	t_mh_block = r_got_req && r_last_wr && 
		     (r_cache_idx == t_mem_head.addr[IDX_STOP-1:IDX_START] );
	
	/* store->load forward match is INDEX-ONLY (matches rv64core nu_l1d). The
	 * incoming load's PHYSICAL tag is not available here: the dtlb pa output is
	 * registered (tlb.sv), so w_mapped_addr/w_tlb_tag2 still hold the PREVIOUS
	 * request's translation this cycle -- any tag compare here is wrong. The old
	 * code compared core_mem_req.addr's high bits (the untranslated VA tag), which
	 * for a MAPPED access (VA != PA) wrongly fails -> no forward -> the load reads
	 * stale array data -> every mapped store->load round-trip silently corrupted
	 * (unmapped kseg0 has w_mapped_addr==va so it happened to match -> kernel boots).
	 * The index is within the page offset (VA index == PA index); the physical tag
	 * is enforced one cycle later by the hit-test (r_tag_out2 == w_tlb_tag2), which
	 * gates whether the forwarded data is actually used. */
	t_cm_block = r_got_req && r_last_wr &&
		     (r_cache_idx == core_mem_req.addr[IDX_STOP-1:IDX_START]);


	t_cm_block_stall = t_cm_block && !(r_did_reload||r_is_retry);//1'b0;
	
	case(r_state)
	  INITIALIZE:
	    begin
	       n_state = INIT_CACHE;
	       t_cache_idx = 'd0;	       
	    end
	  INIT_CACHE:
	    begin
	       t_cache_idx = r_cache_idx + 'd1;
	       if(r_cache_idx == (L1D_NUM_SETS-1))
		 begin
		    //$display("flush done at cycle %d", r_cycle);
		    n_state = ACTIVE;
		    n_flush_complete = 1'b1;
		 end
	       else
		 begin
		    t_mark_invalid = 1'b1;
		    t_cache_idx = r_cache_idx + 'd1;		    
		 end
	    end
	  ACTIVE:
	    begin
	       if(r_got_req2)
		 begin
		    n_core_mem_rsp.data = r_req2.addr;
		    n_core_mem_rsp.rob_ptr = r_req2.rob_ptr;
		    n_core_mem_rsp.dst_ptr = r_req2.dst_ptr;
		    /* port2 response routes to FP-vs-int by THIS port's req (the
		     * default at the top uses r_req = port1, wrong for a port2 rsp) */
		    n_core_mem_rsp.fp_dst = r_req2.fp_dst;
		    n_core_mem_rsp.fp_merge = r_req2.fp_merge;
		    n_core_mem_rsp.fp_hi = r_req2.fp_hi;
		    n_core_mem_rsp.fp_pres = r_req2.fp_pres;
		    if(drain_ds_complete)
		      begin
			 n_core_mem_rsp.dst_valid = r_req2.dst_valid;
			 n_core_mem_rsp.bad_addr = r_req2.bad_addr;
			 n_core_mem_rsp_valid = 1'b1;
		      end
		    else if(r_req2.op == MEM_MOV)
		      begin
			 /* GPR<->FPR move: no memory access; echo the
			  * carried data (r_req2.addr) to the dst PRF */
			 n_core_mem_rsp.fp_dst = r_req2.fp_dst;
			 n_core_mem_rsp.fp_merge = r_req2.fp_merge;   /* =0 for moves (override port1 default) */
			 n_core_mem_rsp.fp_hi = r_req2.fp_hi;
			 n_core_mem_rsp.fp_pres = r_req2.fp_pres;
			 n_core_mem_rsp.dst_valid = r_req2.dst_valid;
			 n_core_mem_rsp_valid = 1'b1;
		      end
		    else if(r_req2.op == MEM_TLBP)
		      begin
			 n_core_mem_rsp.dst_valid = 1'b0;
			 n_core_mem_rsp.tlb_hit = w_tlb_hit;
			 n_core_mem_rsp.tlb_index = w_tlb_index;
			 n_core_mem_rsp_valid = 1'b1;			 
		      end
		    else if(r_req2.bad_addr)
		      begin
			 n_core_mem_rsp.data = r_req2.addr;
			 n_core_mem_rsp.dst_valid = r_req2.dst_valid;
			 n_core_mem_rsp.bad_addr = r_req2.bad_addr;
			 n_core_mem_rsp_valid = 1'b1;			 
		      end
		    else if(w_tlb_hit==1'b0)
		       begin
			  /* BadVAddr = the faulting VIRTUAL address (r_req2.addr), NOT the
		   * translated PA: on a TLB miss w_mapped_addr is garbage, and
		   * zero-extending it to PA_WIDTH drops the high 64-bit VA bits.  The
		   * R4000 refill/kmiss reads BadVAddr (+Context) to find the PTE, so it
		   * must be the full VA (e.g. kseg2 0xffffffffc0000000). */
		  n_core_mem_rsp.data = r_req2.addr;
			  n_core_mem_rsp.dst_valid = 1'b0;
			  n_core_mem_rsp.bad_addr = 1'b0;
			  n_core_mem_rsp.tlb_refill = 1'b1;
			  n_core_mem_rsp_valid = 1'b1;
		       end
		    else if(w_tlb_valid == 1'b0)
		       begin
			  /* R4400: matching entry, V=0 -> TLB Invalid (TLBL/TLBS), common vector */
			  /* BadVAddr = the faulting VIRTUAL address (r_req2.addr), NOT the
		   * translated PA: on a TLB miss w_mapped_addr is garbage, and
		   * zero-extending it to PA_WIDTH drops the high 64-bit VA bits.  The
		   * R4000 refill/kmiss reads BadVAddr (+Context) to find the PTE, so it
		   * must be the full VA (e.g. kseg2 0xffffffffc0000000). */
		  n_core_mem_rsp.data = r_req2.addr;
			  n_core_mem_rsp.dst_valid = 1'b0;
			  n_core_mem_rsp.bad_addr = 1'b0;
			  n_core_mem_rsp.tlb_invalid = 1'b1;
			  n_core_mem_rsp.tlb_hit = w_tlb_hit;
			  n_core_mem_rsp.tlb_index = w_tlb_index;
			  n_core_mem_rsp_valid = 1'b1;
		       end
		    else if(r_req2.is_store && (w_tlb_dirty == 1'b0) && !w_is_chop2)   /* CACHE ops don't write the page: no TLB-Mod */
		       begin
			  /* R4400: store to valid-but-not-dirty page -> TLB Modified (Mod), common vector; no write */
			  /* BadVAddr = the faulting VIRTUAL address (r_req2.addr), NOT the
		   * translated PA: on a TLB miss w_mapped_addr is garbage, and
		   * zero-extending it to PA_WIDTH drops the high 64-bit VA bits.  The
		   * R4000 refill/kmiss reads BadVAddr (+Context) to find the PTE, so it
		   * must be the full VA (e.g. kseg2 0xffffffffc0000000). */
		  n_core_mem_rsp.data = r_req2.addr;
			  n_core_mem_rsp.dst_valid = 1'b0;
			  n_core_mem_rsp.bad_addr = 1'b0;
			  n_core_mem_rsp.tlb_modified = 1'b1;
			  n_core_mem_rsp.tlb_hit = w_tlb_hit;
			  n_core_mem_rsp.tlb_index = w_tlb_index;
			  n_core_mem_rsp_valid = 1'b1;
		       end
		    else if(w_tlb_oor)
		       begin
			  /* Sail TLBTranslateC: valid+dirty entry whose PFN maps beyond
			   * MAX_PA(36b) -> Address Error (AdEL/AdES); BadVAddr = the VA. */
			  n_core_mem_rsp.data = r_req2.addr;
			  n_core_mem_rsp.dst_valid = 1'b0;
			  n_core_mem_rsp.bad_addr = 1'b1;
			  n_core_mem_rsp_valid = 1'b1;
		       end
		    else if(r_req2.is_store)
		      begin
			 t_push_miss = 1'b1;
			 t_incr_busy = 1'b1;
			 n_stall_store = 1'b1;
			 if(r_req2.op != MEM_SC && r_req2.op != MEM_SCD)
			   begin
			      //ack early
			      n_core_mem_rsp.dst_valid = 1'b0;
			      n_core_mem_rsp.tlb_hit = w_tlb_hit;
			      n_core_mem_rsp.tlb_index = w_tlb_index;
			      if(t_port2_hit_cache)
				begin
				   n_cache_hits = r_cache_hits + 'd1;
				end
			      n_core_mem_rsp_valid = 1'b1;
			      n_core_mem_rsp.bad_addr = r_req2.bad_addr;
			   end
			 else
			   begin
			      /* SC/SCD: early ack with the reservation result (link); cache write
			       * deferred to the graduated-store port1 path. */
			      n_core_mem_rsp.data = {{(`M_WIDTH-1){1'b0}}, w_match_link2};
			      n_core_mem_rsp.dst_valid = r_req2.dst_valid;
			      n_core_mem_rsp.bad_addr = r_req2.bad_addr;
			      if(t_port2_hit_cache)
				begin
				   n_cache_hits = r_cache_hits + 'd1;
				end
			      n_core_mem_rsp_valid = 1'b1;
			   end
		      end // if (r_req2.is_store)
		    else if(r_req2.op == MEM_LWL || r_req2.op == MEM_LWR ||
			    r_req2.op == MEM_LDL || r_req2.op == MEM_LDR)
		      begin
			 t_push_miss = 1'b1;
			 n_core_mem_rsp.bad_addr = r_req2.bad_addr;
			 n_core_mem_rsp.tlb_hit = w_tlb_hit;
			 n_core_mem_rsp.tlb_index = w_tlb_index;
		      end
		    else if(t_port2_hit_cache && !r_hit_busy_addr2)
		      begin
`ifdef VERBOSE_L1D
			 $display("cycle %d port2 hit for uuid %d, addr %x, data %x", 
				  r_cycle, r_req2.uuid, r_req2.addr, t_rsp_data2);
`endif
			 n_core_mem_rsp.data = t_rsp_data2[`M_WIDTH-1:0];
                         n_core_mem_rsp.dst_valid = t_rsp_dst_valid2;
			 n_core_mem_rsp.fp_dst = r_req2.fp_dst;   /* port2: route FP loads to the FP PRF */
			 n_core_mem_rsp.fp_merge = r_req2.fp_merge;   /* FR=0 lwc1 merge */
			 n_core_mem_rsp.fp_hi = r_req2.fp_hi;
			 n_core_mem_rsp.fp_pres = r_req2.fp_pres;
                         n_cache_hits = r_cache_hits + 'd1;
                         n_core_mem_rsp_valid = 1'b1;
			 n_core_mem_rsp.bad_addr = r_req2.bad_addr;
			 n_core_mem_rsp.tlb_hit = w_tlb_hit;
			 n_core_mem_rsp.tlb_index = w_tlb_index;			 
		      end
		    else
		      begin
			 t_push_miss = 1'b1;
			 if(t_port2_hit_cache)
			   begin
			      n_cache_hits = r_cache_hits + 'd1;
			   end
		      end
		 end // if (r_got_req2)
	       

	       if(r_got_req)
		 begin
		    if(w_is_chop_r)
		      begin
			 /* retried CACHE hit-op: perform the line op on the translated
			  * PA (mirrors the FLUSH_CL funnel semantics).  Already early-
			  * acked at translate time -- no rsp here, just clear the
			  * graduation entry.  CHWB is conservatively treated as
			  * WB-Invalidate (no clear-dirty-keep-valid path; a refill
			  * costs a miss, never correctness). */
			 /* double-beat: graduation DEFERRED to beat 2 (addr+16) -- see CHWB tail / FLUSH_CL_WAIT / CHOP_BEAT2 */
			 if(r_valid_out && (r_tag_out == r_cache_tag) && r_dirty_out && (r_req.op != MEM_CHINV))
			   begin
			      /* dirty hit, WB variant: write the line through to DRAM.
			       * t_got_miss blocks a same-cycle MQ head fire (we're leaving
			       * ACTIVE; a store fired this cycle would be dropped). */
			      t_got_miss = 1'b1;
			      t_mark_invalid = 1'b1;
			      n_mem_req_addr = {r_tag_out,r_cache_idx[IDX_PA_BITS-1:0],{`LG_L1D_CL_LEN{1'b0}}};
			      n_mem_req_opcode = MEM_WB;
			      n_mem_req_store_data = t_data;
			      n_mem_req_cacheable = 1'b1;
			      n_mem_req_mask = 16'hffff;
			      n_mem_req_valid = 1'b1;
			      n_inhibit_write = 1'b1;
			      n_chop_wait = 1'b1;
			      n_state = FLUSH_CL_WAIT;
			   end
			 else if(r_req.op != MEM_CHWB)
			   begin
			      /* INV variants (clean hit or L1D miss): drop any L1D copy,
			       * scrub the L2 copy (MEM_INVL, no WB -- DMA-in drop).
			       * t_got_miss: see WB arm. */
			      t_got_miss = 1'b1;
			      if(r_valid_out && (r_tag_out == r_cache_tag))
				t_mark_invalid = 1'b1;
			      n_mem_req_addr = {r_req.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN],{`LG_L1D_CL_LEN{1'b0}}};
			      n_mem_req_opcode = MEM_INVL;
			      n_mem_req_cacheable = 1'b1;
			      n_mem_req_mask = 16'hffff;
			      n_mem_req_valid = 1'b1;
			      n_chop_wait = 1'b1;
			      n_state = FLUSH_CL_WAIT;
			   end
			 else if(r_valid_out && (r_tag_out == r_cache_tag))
			   begin
			      /* CHWB clean hit: nothing dirty to push; drop the copy
			       * (conservative WB-inval semantics, see above) */
			      t_mark_invalid = 1'b1;
			   end
			 /* double-beat: if beat 0 issued NO flush (CHWB clean-hit or a
			  * full miss), FLUSH_CL_WAIT never runs -- go straight to beat 2.
			  * The WB/INV arms set n_chop_wait=1 and reach beat 2 via the
			  * wait.  (t_mark_invalid above hit r_cache_idx = beat-0's set.) */
			 if(!n_chop_wait)
			   begin
			      n_chop_beat = 1'b1;
			      n_state = CHOP_BEAT2_RD;
			   end
		      end
		    else if(r_req.cached == 1'b0)
		      begin
			 if(r_valid_out && (r_tag_out == r_cache_tag))
			   begin
			      /* uncached access aliases a resident cache line: invalidate
			       * it (write back first if dirty) so DRAM is authoritative,
			       * then re-issue the uncached request (no longer aliasing). */
			      t_got_miss = 1'b1;
			      t_mark_invalid = 1'b1;
			      n_uncache_wb_dirty = r_dirty_out;
			      n_state = UNCACHE_WB;
			      if(r_dirty_out)
				begin
				   n_mem_req_addr = {r_tag_out, r_cache_idx[IDX_PA_BITS-1:0], {`LG_L1D_CL_LEN{1'b0}}};
				   n_mem_req_cacheable = 1'b1;
				   n_mem_req_opcode = MEM_SW;
				   n_mem_req_store_data = t_data;
				   n_mem_req_mask = 16'hffff;
				   n_mem_req_valid = 1'b1;
				   n_inhibit_write = 1'b1;
				end
			   end
			 else
			   begin
			      n_mem_req_cacheable = 1'b0;
			      n_mem_req_mask = t_mem_req_mask;
			      if(r_req.op == MEM_SWR)
				begin
				   $display("SWR addr[3:0] = %x, {addr[3:2],2'd0} = %x, bits %x, mask = %b", 
					    r_req.addr[3:0],
					    {r_req.addr[3:2], 2'd0},
					    r_req.addr[1:0],
					    n_mem_req_mask);
				   //$stop();
				   
				end
			 if(r_req.op == MEM_SWL)
			   begin
			      $display("SWL addr[3:0] = %x, {addr[3:2],2'd0} = %x, bits %x, mask = %b", 
				       r_req.addr[3:0],
				       {r_req.addr[3:2], 2'd0},
				       r_req.addr[1:0],
				       n_mem_req_mask);
			      //$stop();
			      
			   end			 
			 n_state = r_req.is_store ? INJECT_UNCACHE_STORE : INJECT_UNCACHE_LOAD;
			 n_mem_req_valid = 1'b1;
			 n_mem_req_opcode = r_req.is_store ? MEM_SW : MEM_LW;
			 n_mem_req_addr = {r_req.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN], {`LG_L1D_CL_LEN{1'b0}}};
			 n_mem_req_store_data = t_array_data;
			 t_got_miss = 1'b1;
			 if(r_req.is_store)
			   begin
			      t_reset_graduated = 1'b1;				   
			   end
			 
			 //$display("uncachable req at pc %x to addr %x, is store %b, data %x, mask %b, rob ptr %x\n", 
			 //r_req.pc, {r_req.addr[31:4], 4'd0}, r_req.is_store, r_req.data,
			 //t_mem_req_mask, r_req.rob_ptr);
			 
			   end
		      end // if (r_req.cached == 1'b0)
		    else if(r_valid_out && (r_tag_out == r_cache_tag))
		      begin /* valid cacheline - hit in cache */
			 if(r_req.is_store)
			   begin
			      /* SC result already sent via the port2 early ack. */
			      t_reset_graduated = 1'b1;
			   end
			 else
			   begin
			      n_core_mem_rsp.data = t_rsp_data[`M_WIDTH-1:0];
			      n_core_mem_rsp.dst_valid = t_rsp_dst_valid;
			      n_core_mem_rsp_valid = 1'b1;
			      n_core_mem_rsp.bad_addr = r_req.bad_addr;
			   end
		      end // if (r_valid_out && (r_tag_out == r_cache_tag))
		    else if(r_valid_out && r_dirty_out && (r_tag_out != r_cache_tag) )
		      begin
			 
			 n_reload_issue = 1'b1; //r_is_retry;			 			 
			 t_got_miss = 1'b1;
			 n_inhibit_write = 1'b1;
			 if(r_hit_busy_addr && r_is_retry || !r_hit_busy_addr)
			   begin
			      n_reload_issue = 1'b1;
			      n_mem_req_addr = {r_tag_out,r_cache_idx[IDX_PA_BITS-1:0],{`LG_L1D_CL_LEN{1'b0}}};
			      n_mem_req_cacheable = 1'b1;
			      n_mem_req_opcode = MEM_SW;
			      n_mem_req_store_data = t_data;
			      n_mem_req_mask = 16'hffff;
			      
			      n_inhibit_write = 1'b1;
			      t_miss_idx = r_cache_idx;
			      t_miss_addr = r_req.addr;

			      n_lock_cache = 1'b1;
			      if((rr_cache_idx == r_cache_idx) && rr_last_wr)
				begin
				   //$display("inflight write to line, must wait");
				   t_cache_idx = r_cache_idx;
				   n_state = WAIT_INJECT_RELOAD;
				   n_mem_req_valid = 1'b0;				   
				end
			      else
				begin
				   //$display("no wait");
				   n_state = INJECT_RELOAD;				   
				   n_mem_req_valid = 1'b1;
				end
			   end // if (!t_stall_for_busy)
		      end
		  else
		    begin
		       
`ifdef VERBOSE_L1D
		       $display("at cycle %d : cache invalid miss for rob ptr %d, r_is_retry %b, addr %x, uuid %d, is store %b, r_cache_idx = %d, r_cache_tag = %d, valid %b",
				r_cycle, r_req.rob_ptr, r_is_retry, r_req.addr, r_req.uuid, r_req.is_store, r_cache_idx, r_cache_tag, r_valid_out);
`endif

		       t_got_miss = 1'b1;
		       n_inhibit_write = 1'b0;	

		       if(r_hit_busy_addr && r_is_retry || !r_hit_busy_addr || r_lock_cache)
			 begin
			    n_reload_issue = 1'b1; 


			    t_miss_idx = r_cache_idx;
			    t_miss_addr = r_req.addr;		       
			    n_mem_req_cacheable = 1'b1;
			    n_mem_req_mask = 16'hffff;
			    t_cache_idx = r_cache_idx;
			    
			    if((rr_cache_idx == r_cache_idx) && rr_last_wr)
			      begin
				 n_mem_req_addr = {r_tag_out,r_cache_idx[IDX_PA_BITS-1:0],{`LG_L1D_CL_LEN{1'b0}}};
			    n_lock_cache = 1'b1;
			    n_mem_req_opcode = MEM_SW;
			    n_state = WAIT_INJECT_RELOAD;
			    n_mem_req_valid = 1'b0;
			      end                                                             
			    else
			      begin
				 n_lock_cache = 1'b0;
				 n_mem_req_addr = {r_req.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN], {`LG_L1D_CL_LEN{1'b0}}};
				 n_mem_req_opcode = MEM_LW;				 
				 n_state = INJECT_RELOAD;
				 n_mem_req_valid = 1'b1;
			      end
			 end // if (!t_stall_for_busy)
		    end // else: !if(r_valid_out && r_dirty_out && (r_tag_out != r_cache_tag)...
	       end // if (r_got_req)




	       
	     if(!mem_q_empty && !t_got_miss && !r_lock_cache)
	       begin
		  if(!t_mh_block)
		    begin
		       if(w_is_chop_head)
			 begin
			    /* CACHE hit-op at MQ head: release on graduation alone (no
			     * store data).  Re-fire through port 1 as a READ pass; the
			     * retry arm performs the line op on the TLB-translated PA
			     * the MQ entry carries. */
			    if(r_graduated[t_mem_head.rob_ptr] == 2'b10)
			      begin
				 t_pop_mq = 1'b1;
				 n_req = t_mem_head;
				 t_cache_idx = t_mem_head.addr[IDX_STOP-1:IDX_START];
				 t_cache_tag = t_mem_head.addr[`PA_WIDTH-1:TAG_LSB];
				 t_addr = t_mem_head.addr;
				 t_got_req = 1'b1;
				 n_is_retry = 1'b1;
				 n_last_rd = 1'b1;
				 t_got_rd_retry = 1'b1;
			      end
			    else if(drain_ds_complete && dead_rob_mask[t_mem_head.rob_ptr])
			      begin
				 t_pop_mq = 1'b1;
				 t_force_clear_busy = 1'b1;
			      end
			 end
		       else if(t_mem_head.is_store)
			 begin
			    if(r_graduated[t_mem_head.rob_ptr] == 2'b10 && (core_store_data_valid ? (t_mem_head.rob_ptr == core_store_data.rob_ptr) : 1'b0) )
			      begin
`ifdef VERBOSE_L1D
				 $display("firing store for %x with data %x at cycle %d for rob ptr %d, uuid %d", 
					  t_mem_head.addr, t_mem_head.data, r_cycle, t_mem_head.rob_ptr, t_mem_head.uuid);
`endif
				 t_pop_mq = 1'b1;
				 core_store_data_ack = 1'b1;
				 n_req = t_mem_head;
				 n_req.data = core_store_data.data;
				 t_cache_idx = t_mem_head.addr[IDX_STOP-1:IDX_START];
				 t_cache_tag = t_mem_head.addr[`PA_WIDTH-1:TAG_LSB];
				 t_addr = t_mem_head.addr;
				 t_got_req = 1'b1;
				 n_is_retry = 1'b1;
				 n_last_wr = 1'b1;
			      end // if (t_mem_head.rob_ptr == head_of_rob_ptr)
			    else if(drain_ds_complete && dead_rob_mask[t_mem_head.rob_ptr])
			      begin
`ifdef VERBOSE_L1D
				 $display("CLEARING EVERYTHING OUT, should clear line %d for rob ptr %d, data %x", 
					  t_mem_head.addr[IDX_STOP-1:IDX_START], t_mem_head.rob_ptr, t_mem_head.data);
`endif
				 t_pop_mq = 1'b1;
				 t_force_clear_busy = 1'b1;
			      end
			 end // if (t_mem_head.is_store)
		       else if(t_mem_head.op == MEM_LWL || t_mem_head.op == MEM_LWR ||
			       t_mem_head.op == MEM_LDL || t_mem_head.op == MEM_LDR)
			 begin
			    if((core_store_data_valid ? (t_mem_head.rob_ptr == core_store_data.rob_ptr) : 1'b0) || drain_ds_complete)
			      begin
				 t_pop_mq = 1'b1;
				 n_req = t_mem_head;
				 n_req.data = core_store_data.data;
				 core_store_data_ack = 1'b1;
				 t_cache_idx = t_mem_head.addr[IDX_STOP-1:IDX_START];
				 t_cache_tag = t_mem_head.addr[`PA_WIDTH-1:TAG_LSB];
				 t_addr = t_mem_head.addr;
				 t_got_req = 1'b1;
				 n_is_retry = 1'b1;
				 n_last_rd = 1'b1;
				 t_got_rd_retry = 1'b1;
			      end
			 end
		       else
			 begin
			    t_pop_mq = 1'b1;
			    n_req = t_mem_head;
			    t_cache_idx = t_mem_head.addr[IDX_STOP-1:IDX_START];
			    t_cache_tag = t_mem_head.addr[`PA_WIDTH-1:TAG_LSB];
			    t_addr = t_mem_head.addr;
			    t_got_req = 1'b1;
			    n_is_retry = 1'b1;
			    n_last_rd = 1'b1;
			    t_got_rd_retry = 1'b1;
			    
`ifdef VERBOSE_L1D			    
			    $display("firing load for %x at cycle %d for rob ptr %d, uuid %d", 
				     t_mem_head.addr, r_cycle, t_mem_head.rob_ptr, t_mem_head.uuid);
`endif
			 end
		    end
	       end

	       
	       if(core_mem_req_valid &&
		  !t_got_miss && 
		  !(mem_q_almost_full||mem_q_full) && 
		  !t_got_rd_retry &&
		  !(r_cache_idx2_val && r_last_wr2 && (r_cache_idx2 == core_mem_req.addr[IDX_STOP-1:IDX_START]) && !core_mem_req.is_store) && 
		  !t_cm_block_stall &&
		  w_uncachable_req &&
		  (core_mem_req.is_atomic ? mem_q_empty : 1'b1) && 
		  /*(r_graduated[core_mem_req.rob_ptr] == 2'b00) && */
		  (!r_rob_inflight[core_mem_req.rob_ptr]) &&
		  /* back-invalidate queue near full: refuse NEW core requests so no
		   * further evictions are produced.  Draining then needs only the
		   * already-accepted fill to finish, after which this cache returns to
		   * ACTIVE and can ack -- so this can throttle but never deadlock. */
		  (!backinv_stall)
		  )
	       begin
		  //use 2nd read port
		  t_cache_idx2 = core_mem_req.addr[IDX_STOP-1:IDX_START];
		  t_p2_core = 1'b1;
		  t_cache_tag2 = core_mem_req.addr[`PA_WIDTH-1:TAG_LSB];
		  n_tlb_addr = core_mem_req.addr;
		  n_req2 = core_mem_req;
		  core_mem_req_ack = 1'b1;
		  t_got_req2 = 1'b1;

		  //if(core_mem_req.op == MEM_LW && core_mem_req.addr[1:0] != 'd0)
		  //begin
		  //$display("unaligned load!!!! from pc %x", core_mem_req.pc);
		  //end
		  
`ifdef VERBOSE_L1D		       
		  $display("accepting new op %d, pc %x, addr %x for rob ptr %d at cycle %d, mem_q_empty %b", 
			   core_mem_req.op, core_mem_req.pc, core_mem_req.addr,
			   core_mem_req.rob_ptr, r_cycle, mem_q_empty);
`endif
		  
		  n_last_wr2 = core_mem_req.is_store;
		  n_last_rd2 = !core_mem_req.is_store;
		  
		  n_cache_accesses =  r_cache_accesses + 'd1;
	       end // if (core_mem_req_valid &&...
	       else if(r_flush_req && mem_q_empty && !(r_got_req && (r_last_wr | w_is_chop_r)))
		 begin
		    n_state = FLUSH_CACHE;
		    n_mem_req_mask = 16'hffff;
		    n_mem_req_cacheable = 1'b1;
`ifdef VERILATOR
		    if(!mem_q_empty) $stop();
		    if(r_got_req && r_last_wr) $stop();
`endif
		    //$display("flush begins at cycle %d, mem_q_empty = %b", 
		    //r_cycle, mem_q_empty);
		    t_cache_idx = 'd0;
		    n_flush_req = 1'b0;
		 end
	       else if(r_flush_cl_req && mem_q_empty && !(r_got_req && (r_last_wr | w_is_chop_r)))   /* a chop retry transitions n_state too */
		 begin
`ifdef VERILATOR
		    if(!mem_q_empty) $stop();
		    if(r_got_req && r_last_wr) $stop();
`endif
		    t_cache_idx = flush_cl_addr[IDX_STOP-1:IDX_START];
		    //$display("flush addr %x, maps to cl %d at cycle", flush_cl_addr, t_cache_idx, r_cycle);
		    n_flush_cl_req = 1'b0;
		    n_state = FLUSH_CL;
		 end
	    end // case: ACTIVE
	  WAIT_INJECT_RELOAD:
	    begin
	       n_mem_req_valid = 1'b1;
	       n_state = INJECT_RELOAD;
	       n_mem_req_store_data = t_data;
	    end
	  INJECT_RELOAD:
	    begin
	       //$display("waiting reload for addr %x at cycle %d", r_req.addr, r_cycle);
	       	if(mem_rsp_valid)
		  begin
		     n_state = r_reload_issue ? HANDLE_RELOAD : ACTIVE;
		     n_inhibit_write = 1'b0;
		     n_reload_issue = 1'b0;
		  end
	    end
	  INJECT_UNCACHE_STORE:
	    begin
	       //$display("cycle %d, waiting for rsp %b", r_cycle, mem_rsp_valid);
	       if(mem_rsp_valid)
		 begin
		    //$display("rsp complete, going to active");
		    n_state = ACTIVE;		    
		 end
	    end
	  INJECT_UNCACHE_LOAD:
	    begin
	       if(mem_rsp_valid)
		 begin
		    //$display("data returns for uncached load");
		    n_core_mem_rsp.data = t_rsp_data[`M_WIDTH-1:0];
                    n_core_mem_rsp.dst_valid = r_req.dst_valid;
		    n_core_mem_rsp.bad_addr = r_req.bad_addr;		    
                    n_core_mem_rsp_valid = 1'b1;
		    n_state = ACTIVE;		    
		 end
	       
	    end
	  UNCACHE_WB:
	    begin
	       /* aliasing line invalidated (+ written back if dirty); re-issue
		* the uncached request now that it no longer aliases. */
	       if(!r_uncache_wb_dirty || mem_rsp_valid)
		 begin
		    n_inhibit_write = 1'b0;
		    n_uncache_wb_dirty = 1'b0;
		    t_got_req = 1'b1;
		    t_cache_idx = r_req.addr[IDX_STOP-1:IDX_START];
		    t_cache_tag = r_req.addr[`PA_WIDTH-1:TAG_LSB];
		    t_addr = r_req.addr;
		    n_state = ACTIVE;
		 end
	    end
	  HANDLE_RELOAD:
	    begin
	       t_cache_idx = r_req.addr[IDX_STOP-1:IDX_START];
	       t_cache_tag = r_req.addr[`PA_WIDTH-1:TAG_LSB];
	       n_last_wr = n_req.is_store;
	       t_got_req = 1'b1;
	       //$display("firing got req at cycle %d, rob ptr %d from HANDLE_RELOAD for uuid %d", r_cycle, r_req.rob_ptr, r_req.uuid);
	       t_addr = r_req.addr;
	       //n_is_retry = 1'b1;
	       n_did_reload = 1'b1;
	       n_state = ACTIVE;
	    end
	  FLUSH_CL:
	    begin
	       if(flush_cl_inval)
		 begin
		    /* CACHE D-Hit-Invalidate (DMA-in): drop the line WITHOUT writeback,
		     * but only on a real hit (tag match) so we never discard a
		     * different dirty line that happens to alias this index. Then tell
		     * L2 to drop its copy too (caches are non-inclusive). */
		    if(r_valid_out && (r_tag_out == flush_cl_addr[`PA_WIDTH-1:TAG_LSB]))
		      t_mark_invalid = 1'b1;
		    n_mem_req_addr = {flush_cl_addr[`PA_WIDTH-1:`LG_L1D_CL_LEN],{`LG_L1D_CL_LEN{1'b0}}};
		    n_mem_req_opcode = MEM_INVL;
		    n_mem_req_cacheable = 1'b1;
		    n_mem_req_mask = 16'hffff;
		    n_mem_req_valid = 1'b1;
		    n_state = FLUSH_CL_WAIT;
		 end
	       else if(r_dirty_out)
		 begin
		    /* CACHE D-writeback (Hit/Index-WB-(Inval)): write the dirty line
		     * through to DRAM via MEM_WB -- L2 flushes its copy (or writes the
		     * carried data straight to DRAM on an L2 miss) so the line actually
		     * reaches memory instead of going dirty into L2 (the DMA-descriptor
		     * coherence bug). */
		    n_mem_req_addr = {r_tag_out,r_cache_idx[IDX_PA_BITS-1:0],{`LG_L1D_CL_LEN{1'b0}}};
		    n_mem_req_opcode = MEM_WB;
		    n_mem_req_cacheable = 1'b1;
		    n_mem_req_store_data = t_data;
		    n_state = FLUSH_CL_WAIT;
		    n_inhibit_write = 1'b1;
		    n_mem_req_valid = 1'b1;
		 end
	       else
		 begin
		    /* clean (or non-hit) line: nothing to write back.  Still
		     * double-beat so both 16B lines of the 32B block get invalidated. */
		    t_mark_invalid = 1'b1;
		    if(!r_flush_cl_beat)
		      begin
			 n_flush_cl_beat = 1'b1;
			 n_state = FLUSH_CL_BEAT2_RD;
		      end
		    else
		      begin
			 n_flush_cl_beat = 1'b0;
			 n_flush_complete = 1'b1;
			 n_state = ACTIVE;
		      end
		 end
	    end // case: FLUSH_CL
	  FLUSH_CL_WAIT:
	    begin
	       	if(mem_rsp_valid)
		  begin
		     n_inhibit_write = 1'b0;
		     n_chop_wait = 1'b0;
		     /* mem-pipe CACHE hit-ops were early-acked; do NOT pulse the
		      * core's funnel flush handshake (it latches and would falsely
		      * satisfy a later CACHE_FLUSH wait). */
		     if(r_chop_wait && !r_chop_beat)
		       begin
			  /* beat 0 of a Hit-op chop done -> beat 1 on (addr+16) */
			  n_chop_beat = 1'b1;
			  n_state = CHOP_BEAT2_RD;
		       end
		     else if(r_chop_wait && r_chop_beat)
		       begin
			  /* beat 1 done -> both 16B lines covered; graduate the chop */
			  t_reset_graduated = 1'b1;
			  n_chop_beat = 1'b0;
			  n_state = ACTIVE;
		       end
		     else if(!r_flush_cl_beat)
		       begin
			  /* Index / whole-line FLUSH_CL writeback beat 0 done ->
			   * re-run on set+1 so 32B-stride Index_WB_Invalidate covers
			   * both 16B lines. */
			  n_flush_cl_beat = 1'b1;
			  n_state = FLUSH_CL_BEAT2_RD;
		       end
		     else
		       begin
			  /* beat 1 done -> both 16B lines covered; complete the funnel */
			  n_flush_cl_beat = 1'b0;
			  n_flush_complete = 1'b1;
			  n_state = ACTIVE;
		       end
		  end
	    end
	  FLUSH_CL_BEAT2_RD:
	    begin
	       /* re-index the tag/data RAM to (flush_cl_addr+16)'s set (this set + 1);
		* its registered outputs are valid next cycle in FLUSH_CL, which then
		* writes that line back by its OWN cached tag (r_tag_out/r_cache_idx).
		* r_flush_cl_beat is already 1. */
	       t_cache_idx = w_flush_cl_idx1;
	       n_state = FLUSH_CL;
	    end
	  CHOP_BEAT2_RD:
	    begin
	       /* re-index the tag/data RAM to (addr+16)'s set (this set + 1); its
		* registered outputs are valid next cycle in CHOP_BEAT2. r_chop_beat
		* is already 1. */
	       t_cache_idx = w_beat2_idx;
	       t_cache_tag = r_req.addr[`PA_WIDTH-1:TAG_LSB];
	       n_state = CHOP_BEAT2;
	    end
	  CHOP_BEAT2:
	    begin
	       /* beat 2: the same D-Hit CACHE op on the next 16B line (addr+16).
		* Same page => same tag (r_cache_tag). r_cache_idx and the RAM outputs
		* are now (addr+16)'s set. WB/INV wait via FLUSH_CL_WAIT (it graduates
		* since r_chop_beat==1); CHWB clean/miss graduates here. */
	       if(r_valid_out && (r_tag_out == r_cache_tag) && r_dirty_out && (r_req.op != MEM_CHINV))
		 begin
		    t_got_miss = 1'b1;
		    t_mark_invalid = 1'b1;
		    n_mem_req_addr = {r_tag_out,r_cache_idx[IDX_PA_BITS-1:0],{`LG_L1D_CL_LEN{1'b0}}};
		    n_mem_req_opcode = MEM_WB;
		    n_mem_req_store_data = t_data;
		    n_mem_req_cacheable = 1'b1;
		    n_mem_req_mask = 16'hffff;
		    n_mem_req_valid = 1'b1;
		    n_inhibit_write = 1'b1;
		    n_chop_wait = 1'b1;
		    n_state = FLUSH_CL_WAIT;
		 end
	       else if(r_req.op != MEM_CHWB)
		 begin
		    t_got_miss = 1'b1;
		    if(r_valid_out && (r_tag_out == r_cache_tag))
		      t_mark_invalid = 1'b1;
		    n_mem_req_addr = {(r_req.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN] + 1'b1),{`LG_L1D_CL_LEN{1'b0}}};
		    n_mem_req_opcode = MEM_INVL;
		    n_mem_req_cacheable = 1'b1;
		    n_mem_req_mask = 16'hffff;
		    n_mem_req_valid = 1'b1;
		    n_chop_wait = 1'b1;
		    n_state = FLUSH_CL_WAIT;
		 end
	       else
		 begin
		    if(r_valid_out && (r_tag_out == r_cache_tag))
		      t_mark_invalid = 1'b1;
		    t_reset_graduated = 1'b1;
		    n_chop_beat = 1'b0;
		    n_state = ACTIVE;
		 end
	    end
	  FLUSH_CACHE:
	    begin
	       t_cache_idx = r_cache_idx + 'd1;
	       if(!r_dirty_out)
		 begin
		    t_mark_invalid = 1'b1;
		    t_cache_idx = r_cache_idx + 'd1;
		    if(r_cache_idx == (L1D_NUM_SETS-1))
		      begin
			 n_state = ACTIVE;
			 n_flush_complete = 1'b1;
		      end
		 end
	       else
		 begin
		    n_mem_req_addr = {r_tag_out,r_cache_idx[IDX_PA_BITS-1:0],{`LG_L1D_CL_LEN{1'b0}}};
	       n_mem_req_opcode = MEM_SW;
	       n_mem_req_store_data = t_data;
	       n_state = (r_cache_idx == (L1D_NUM_SETS-1)) ? FLUSH_CACHE_LAST_WAIT : FLUSH_CACHE_WAIT;
	       n_inhibit_write = 1'b1;
	       n_mem_req_valid = 1'b1;
	    end // else: !if(r_valid_out && !r_dirty_out)
	    end // case: FLUSH_CACHE
	  FLUSH_CACHE_LAST_WAIT:
	    begin
	       t_cache_idx = r_cache_idx;
	       //$display("stuck in flush cache at cycle %d", r_cycle);
	       	if(mem_rsp_valid)
		  begin
		     n_state = ACTIVE;
		     n_inhibit_write = 1'b0;
		     n_flush_complete = 1'b1;
		  end
	    end	  
	  FLUSH_CACHE_WAIT:
	    begin
	       t_cache_idx = r_cache_idx;
	       //$display("stuck in flush cache at cycle %d", r_cycle);
	       	if(mem_rsp_valid)
		  begin
		     n_state = FLUSH_CACHE;
		     n_inhibit_write = 1'b0;
		  end
	    end
	  default:
	    begin
	    end
	endcase // case r_state
     end // always_comb

`ifdef VERILATOR
   always_ff@(negedge clk)
     begin
      if(t_push_miss && mem_q_full)
	begin
	   $display("attempting to push to a full memory queue");
	   `ifdef VERILATOR $stop(); `endif
	end
	if(t_pop_mq && mem_q_empty)
	  begin
	   $display("attempting to pop an empty memory queue");
	   `ifdef VERILATOR $stop(); `endif
	  end
     end


   logic [31:0] t_stall_reason;
   always_comb
     begin
	t_stall_reason = 'd0;
	if(core_mem_req_valid && !core_mem_req_ack)
	  begin
	     if(t_got_miss) 
	       begin
		  //$display("miss prevents ack at cycle %d", r_cycle);
		  t_stall_reason = 'd1;
	       end
	     else if(mem_q_almost_full||mem_q_full) 
	       begin
		  //$display("full prevents ack at cycle %d", r_cycle);
		  t_stall_reason = 'd2;
	       end
	     else if(t_got_rd_retry)
	       begin
		  //$display("retried load prevents ack at cycle %d", r_cycle);
		  t_stall_reason = 'd4;
	       end
	     else if(r_cache_idx2_val && r_last_wr2 && (r_cache_idx2 == core_mem_req.addr[IDX_STOP-1:IDX_START]) && !core_mem_req.is_store) 
	       begin
		  //$display("previous write to the same set prevents ack at cycle %d", r_cycle);
		  t_stall_reason = 'd5;
	       end
	     else if(t_cm_block_stall) 
	       begin
		  //$display("retried store prevents ack at cycle %d", r_cycle);
		  t_stall_reason = 'd6;
	       end
	     else if(r_graduated[core_mem_req.rob_ptr] != 2'b00) 
	       begin
		  //$display("rob pointer in flight prevents ack at cycle %d", r_cycle);
		  t_stall_reason = 'd7;		  
	       end
	  end // if (core_mem_req_valid && !core_mem_req_ack)
     end // always_comb
   
   always_ff@(negedge clk)
     begin
	record_l1d(core_mem_req_valid ? 32'd1 : 32'd0,
		   core_mem_req_ack & core_mem_req_valid ? 32'd1 : 32'd0,
		   core_mem_req_ack & core_mem_req_valid & core_mem_req.is_store ? 32'd1 : 32'd0,		   
		   {{32-N_MQ_ENTRIES{1'b0}},r_hit_busy_addrs},
		   t_stall_reason);
     end
`endif
    
`ifdef ENABLE_STORE_CHECK
   // forward-ported store-check hook: report each committed store cache-array write
   // (t_wr_array) so henry_tb can diff it against the golden ISS store stream.
   always_ff @(negedge clk)
     if(t_wr_array & ((r_req.op == MEM_SB) | (r_req.op == MEM_SH) |
		      (r_req.op == MEM_SW) | (r_req.op == MEM_SD)))
       wr_log(r_req.pc, {27'd0, r_req.rob_ptr}, r_req.addr,
	      (r_req.op == MEM_SB) ? {56'd0, r_req.data[7:0]}  :
	      (r_req.op == MEM_SH) ? {48'd0, r_req.data[15:0]} :
	      (r_req.op == MEM_SW) ? {32'd0, r_req.data[31:0]} : r_req.data,
	      r_req.is_atomic ? 32'd1 : 32'd0);
   // dirty-set-drop watch: a store's dirty=1 (t_wr_array) is suppressed when a dirty-clear
   // (refill w_cacheable_mem_rsp_valid, or invalidate t_mark_invalid) wins the dc_dirty port.
   always_ff @(negedge clk)
     if(t_wr_array & (t_mark_invalid | w_cacheable_mem_rsp_valid))
       dirtydrop({32'd0, r_cycle}, r_req.pc, r_req.addr,
		 w_cacheable_mem_rsp_valid ? 32'd1 : 32'd0);
   // L1D->L2 store/writeback watch: fire on each accepted store-type request to the L2
   // (MEM_SW carries dirty-line writebacks too; MEM_WB = explicit CACHE writeback).
   reg r_wbwatch_prev;
   always_ff @(posedge clk) r_wbwatch_prev <= reset ? 1'b0 : r_mem_req_valid;
   always_ff @(negedge clk)
     if(r_mem_req_valid & ~r_wbwatch_prev &          // rising edge of a new L1D->L2 request
	((r_mem_req_opcode == MEM_WB)  | (r_mem_req_opcode == MEM_INVL) |
	 (r_mem_req_opcode == MEM_SW)  | (r_mem_req_opcode == MEM_SD)))
       l1d_wb_log({{(64-`PA_WIDTH){1'b0}}, r_mem_req_addr},
		  r_mem_req_store_data[63:0], r_mem_req_store_data[127:64]);
`endif

endmodule // l1d

