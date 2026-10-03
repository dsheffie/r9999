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
`ifdef FORMAL_DPRELOAD
	   fml_pre_tag,
	   fml_pre_data,
`endif
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
	   dbg_rob_inflight,
	   drain_ds_complete,
	   dead_rob_mask,
	   flush_req,
	   flush_complete,
	   flush_cl_req,
	   flush_cl_addr,
	   flush_cl_inval,
	   dma_inval_req,
	   dma_inval_addr,
	   dma_inval_ack,
	   probe_req,
	   probe_addr,
	   probe_ack,
	   probe_dirty,
	   probe_data,
	   flush_pg_req,
	   pg_drop_dirty_cnt,
	   //inputs from core
	   core_mem_req_valid,
	   core_mem_req,
	   //store data (and lwl/lwr data)
	   //outputs to core
	   core_mem_req_ack,
	   core_mem_rsp,
	   core_mem_rsp_valid,
	   core_mem_blk_valid,
	   core_mem_wake_valid,
	   core_mem_st_done_valid,
	   core_mem_st_done_idx,
	   lsu_sb,
	   restart_color,
	   mem_color_busy,
	   mem_quiet,
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
   output logic [N_ROB_ENTRIES-1:0] dbg_rob_inflight;
   input logic 			     drain_ds_complete;
   input logic [(1<<`LG_ROB_ENTRIES)-1:0] dead_rob_mask;
   
   
   input logic flush_cl_req;
   input logic [`M_WIDTH-1:0] flush_cl_addr;
   input logic 		      flush_cl_inval;
   /* DMA-completion invalidate: a SECOND requester into the same per-line
    * invalidate machinery, independent of the CPU's CACHE-op handshake so the
    * core never stalls on it.  One 16B line per request; the SoC-side walker
    * steps the range and holds dma_inval_addr stable until dma_inval_ack.
    * Always drop-without-writeback (software already invalidated pre-DMA, so a
    * line present here is a clean speculative refill -- writing it back would
    * stomp the DMA'd data). */
   input logic 		      dma_inval_req;
   input logic [`PA_WIDTH-1:0] dma_inval_addr;
   output logic 	      dma_inval_ack;
   /* inclusive-l2-v2 stage B: back-invalidate probe from the L2, which is evicting a line
    * the L1D may hold on behalf of an L1I miss.  The L2 holds probe_req/probe_addr until
    * probe_ack (a 1-cycle pulse); r_prb_seen keeps one held request from being answered
    * twice and clears when probe_req drops.  The probe is taken from ACTIVE or from any
    * state that is only waiting on the L2 -- never dependent on the L1D's own request
    * (rule R2 of INCLUSIVE_L2_PROTOCOL.md).  Hit: the line is invalidated and returned
    * (probe_dirty, probe_data) if dirty. */
   input logic 		      probe_req;
   input logic [`PA_WIDTH-1:0] probe_addr;
   output logic 	      probe_ack;
   output logic 	      probe_dirty;
   output logic [127:0]       probe_data;
   /* injected page op (XPG_WBINV / XPG_INV): walk the page's lines at flush_cl_addr
    * (page-aligned PA, held by the core like the CACHE-op address), flush_cl_inval =
    * drop (XPG_INV).  Per line, L1D then L2 -- the core is drained at the ROB head, so
    * the order is free (~/code/murphi/r9999_pagewalk.m):
    *   WBINV: L1D dirty hit -> MEM_WB (to DRAM, L2 copy dropped); otherwise invalidate
    *          an L1D hit and MEM_INVL (L2 writes back if dirty, then drops).
    *   INV:   invalidate an L1D hit, MEM_PGDROP (L2 drops without writeback).
    * One flush_complete pulse at the end of the page. */
   input logic 		      flush_pg_req;
   /* dirty lines found by XPG_INV walks (L1D + L2): a correctly cleaned page has none,
    * so any nonzero count is a coherence bug (saturating). */
   output logic [15:0] 	      pg_drop_dirty_cnt;
   input logic 		      flush_req;
   output logic 	      flush_complete;

   input logic core_mem_req_valid;
   input       mem_req_t core_mem_req;

   
   output logic core_mem_req_ack;
   output 	mem_rsp_t core_mem_rsp;
   output logic core_mem_rsp_valid;
   /* LSU replay: a simple load (lsu_hold) that cannot complete on its port-2 pass
    * returns a block code (core_mem_rsp.blk) instead of waiting in the l1d; its
    * miss-queue entry still reloads the line, and the port-1 pass then sends a
    * wakeup (core_mem_rsp.lsu_idx) instead of the data.  The LSU re-issues it. */
   output logic core_mem_blk_valid;
   output logic core_mem_wake_valid;
   /* a plain-store commit has been written (cache or device): free its LSU slot */
   output logic core_mem_st_done_valid;
   output logic [`LG_MEM_SCHED_ENTRIES-1:0] core_mem_st_done_idx;
   input 	lsu_sb_t lsu_sb;
   /* restart color: a request / queued op / response of the other color belongs
    * to a flushed era (commits exempt) -- dropped instead of drained */
   input logic	restart_color;
   /* an op of color c is still in flight here (the core's flip-back guard) */
   output logic [1:0] mem_color_busy;
   output logic       mem_quiet;       /* nothing accepted is still being worked on */

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
   localparam N_TAG_BITS = `PA_WIDTH - TAG_LSB;
`ifdef FORMAL_DPRELOAD
   /* FORMAL PRELOAD (d-side).  The flush walk normally writes valid=0 to every
    * set; here it writes valid=1 and fills tag/data from these FREE inputs, so a
    * load HITS immediately instead of needing a DRAM round trip.  Two payoffs:
    *  (1) REACHABILITY -- no fill latency, so interesting states arrive in a
    *      handful of cycles instead of the ~30 the DIVA controls needed.
    *  (2) It makes `dst_valid` LIVE.  The response only carries dst_valid on a
    *      CACHE-HIT reply (t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2),
    *      and a harness that cannot manufacture a hit leaves every response-field
    *      control CONSTANT-0 -- which is exactly why formal_l1d_rsp's c_dstv /
    *      c_ptr / c_rob / c_dat are all dead and its bad_p0 "proof" is vacuous.
    * These MUST be real ports, not undriven nets: the build does `setundef -zero`,
    * which would silently tie them to 0 (the phantom mem_req_ack trap).
    * OVER-APPROXIMATION: a free tag lets a line claim any address, so this admits
    * cache states no real fill sequence produces.  UNSAT is therefore sound; a SAT
    * counterexample must be checked for realizability before it is believed. */
   input logic [N_TAG_BITS-1:0]      fml_pre_tag;
   input logic [L1D_CL_LEN_BITS-1:0] fml_pre_data;
   /* INIT_CACHE is the RESET walk (INITIALIZE -> INIT_CACHE -> ACTIVE) and needs no
    * flush_req, so the preload happens automatically out of reset.  FLUSH_CACHE is
    * included so an explicit flush re-preloads rather than emptying the cache. */
   wire w_dpreload = ((r_state == INIT_CACHE) | (r_state == FLUSH_CACHE)) & t_mark_invalid;
`endif
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
   logic 				  r_dma_inval_req, n_dma_inval_req;
   logic 				  r_dma_inval_ack, n_dma_inval_ack;
   logic 				  r_cl_is_dma, n_cl_is_dma;   /* owner of the in-flight FLUSH_CL */
   logic 				  r_flush_pg_req, n_flush_pg_req;
   localparam LG_PG_LINES = `LG_PG_SZ - `LG_L1D_CL_LEN;
   logic [LG_PG_LINES-1:0] 		  r_pg_off, n_pg_off;
   logic [15:0] 			  r_pg_dirty_cnt, n_pg_dirty_cnt;
   assign pg_drop_dirty_cnt = r_pg_dirty_cnt;
   wire [`PA_WIDTH-1:0] 		  w_pg_line = {flush_cl_addr[`PA_WIDTH-1:`LG_PG_SZ], r_pg_off, {`LG_L1D_CL_LEN{1'b0}}};
   wire [`PA_WIDTH-1:0] 		  w_pg_line_nxt = {flush_cl_addr[`PA_WIDTH-1:`LG_PG_SZ], r_pg_off + 1'b1, {`LG_L1D_CL_LEN{1'b0}}};
   wire [`PA_WIDTH-1:0] 		  w_pg_line0 = {flush_cl_addr[`PA_WIDTH-1:`LG_PG_SZ], {`LG_PG_SZ{1'b0}}};
   wire 				  w_pg_hit = r_valid_out & (r_tag_out == w_pg_line[`PA_WIDTH-1:TAG_LSB]);
   assign dma_inval_ack = r_dma_inval_ack;
   /* arbitrated line address/op: the CPU CACHE-op wins; DMA is always invalidate */
   wire [`M_WIDTH-1:0] 			  w_cl_addr  = r_cl_is_dma ? {{(`M_WIDTH-`PA_WIDTH){1'b0}}, dma_inval_addr} : flush_cl_addr;
   wire 				  w_cl_inval = r_cl_is_dma ? 1'b1 : flush_cl_inval;
   logic 				  r_flush_complete, n_flush_complete;
   

   logic [31:0] 			  t_array_out_b32[WORDS_PER_CL-1:0];
   logic [31:0] 			  t_w32, t_bswap_w32;
   logic [31:0] 			  t_w32_2, t_bswap_w32_2;

   logic 				  t_got_rd_retry, t_port2_hit_cache;
`ifdef L1D_PORT2_ALWAYS_MISS
   wire 				  w_p2_force_miss = 1'b1;
`else
   wire 				  w_p2_force_miss = 1'b0;
`endif
      
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

   logic 				  t_ucld_dead_drop;
      
   logic 				  n_is_retry, r_is_retry;
   logic 				  r_q_priority, n_q_priority;
   
   logic 				  n_core_mem_rsp_valid, r_core_mem_rsp_valid;
   logic 				  n_core_mem_blk_valid, r_core_mem_blk_valid;
   logic 				  n_core_mem_wake_valid, r_core_mem_wake_valid;
   logic 				  n_core_mem_st_done_valid, r_core_mem_st_done_valid;
   logic [`LG_MEM_SCHED_ENTRIES-1:0] 	  n_core_mem_st_done_idx, r_core_mem_st_done_idx;
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
			     /* injected page op: one line of the page per visit (RAM
			      * outputs are for w_pg_line), then wait for the L2 ack */
			     FLUSH_PG = 'd17,
			     FLUSH_PG_WAIT = 'd18,
			     PROBE_CHK = 'd19
                             } state_t;

   
   state_t r_state, n_state;
   /* stage B probe state */
   logic 		      r_prb_seen, n_prb_seen;
   logic 		      r_prb_ack, n_prb_ack;
   logic 		      r_prb_dirty, n_prb_dirty;
   logic [127:0] 	      r_prb_data, n_prb_data;
   state_t 		      r_prb_ret, n_prb_ret;
   logic [`LG_L1D_NUM_SETS-1:0] r_prb_save, n_prb_save;
   logic [`PA_WIDTH-1:TAG_LSB] r_prb_tag, n_prb_tag;
   logic 		      t_prb_pend, t_prb_ok_state, t_prb_hit;
`ifdef VERILATOR
   /* stage B probe statistics (sim only) */
   logic [63:0] r_dbg_prb, r_dbg_prb_hit, r_dbg_prb_dirty;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_dbg_prb <= 'd0;
	     r_dbg_prb_hit <= 'd0;
	     r_dbg_prb_dirty <= 'd0;
	  end
	else if(r_state == PROBE_CHK)
	  begin
	     r_dbg_prb <= r_dbg_prb + 'd1;
	     r_dbg_prb_hit <= r_dbg_prb_hit + (t_prb_hit ? 'd1 : 'd0);
	     r_dbg_prb_dirty <= r_dbg_prb_dirty + ((t_prb_hit && r_dirty_out) ? 'd1 : 'd0);
	  end
     end
   final
     begin
	$display("[PROBE] L1D probes %0d, hit %0d, dirty %0d", r_dbg_prb, r_dbg_prb_hit, r_dbg_prb_dirty);
     end
`endif
   assign probe_ack = r_prb_ack;
   assign probe_dirty = r_prb_dirty;
   assign probe_data = r_prb_data;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_prb_seen <= 1'b0;
	     r_prb_ack <= 1'b0;
	     r_prb_dirty <= 1'b0;
	     r_prb_data <= 'd0;
	     r_prb_ret <= ACTIVE;
	     r_prb_save <= 'd0;
	     r_prb_tag <= 'd0;
	  end
	else
	  begin
	     r_prb_seen <= n_prb_seen;
	     r_prb_ack <= n_prb_ack;
	     r_prb_dirty <= n_prb_dirty;
	     r_prb_data <= n_prb_data;
	     r_prb_ret <= n_prb_ret;
	     r_prb_save <= n_prb_save;
	     r_prb_tag <= n_prb_tag;
	  end
     end
   logic 	t_pop_mq;
   logic 	n_reload_issue, r_reload_issue;
   logic 	n_did_reload, r_did_reload;
   logic 	n_uncache_wb_dirty, r_uncache_wb_dirty;

   /* debug/trace-only observability port (kept 4b to avoid rippling the width
    * up through core_l1d_l1i/henry_soc/ILA); r_state is now 5b (17 states) so
    * FLUSH_CL_BEAT2_RD=16 aliases INITIALIZE=0 in the trace -- a transient
    * 1-cycle re-index state, acceptable to lose in observability. */
   assign state = r_state[3:0];
   /* both restart colors folded: "this rob slot has an l1d op in flight" */
   assign dbg_rob_inflight = r_rob_inflight[N_ROB_ENTRIES-1:0] | r_rob_inflight[2*N_ROB_ENTRIES-1:N_ROB_ENTRIES];
   
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
   assign mem_req_addr = r_mem_req_addr;
   assign mem_req_store_data = r_mem_req_store_data;
   assign mem_req_opcode = r_mem_req_opcode;
   assign mem_req_valid = r_mem_req_valid;
   assign mem_req_cacheable = r_mem_req_cacheable;
   assign mem_req_mask = r_mem_req_mask;

   /* w_* = the l1d's own view of what it answered (counts every answer);
    * core_mem_* = the same, minus answers for a flushed era (restart color) */
   logic w_rsp_v, w_blk_v, w_wake_v;
   mem_rsp_t w_rsp;
   logic t_req_stale, t_mq_stale_drop, t_mq_stale_owed;
`ifdef REG_L1D_RSP
   /* registered response -- matches rv64core; see REG_L1D_RSP in machine.vh */
   assign w_rsp_v = r_core_mem_rsp_valid;
   assign w_blk_v = r_core_mem_blk_valid;
   assign w_wake_v = r_core_mem_wake_valid;
   assign w_rsp = r_core_mem_rsp;
   assign core_mem_st_done_valid = r_core_mem_st_done_valid;
   assign core_mem_st_done_idx = r_core_mem_st_done_idx;
`else
   assign w_rsp_v = n_core_mem_rsp_valid;
   assign w_blk_v = n_core_mem_blk_valid;
   assign w_wake_v = n_core_mem_wake_valid;
   assign w_rsp = n_core_mem_rsp;
   assign core_mem_st_done_valid = n_core_mem_st_done_valid;
   assign core_mem_st_done_idx = n_core_mem_st_done_idx;
`endif
   wire w_rsp_stale = (w_rsp.restart_id != restart_color);
   assign core_mem_rsp_valid = w_rsp_v & !w_rsp_stale;
   assign core_mem_blk_valid = w_blk_v & !w_rsp_stale;
   assign core_mem_wake_valid = w_wake_v & !w_rsp_stale;
   always_comb
     begin
	core_mem_rsp = w_rsp;
	core_mem_rsp.dst_valid = w_rsp.dst_valid & !w_rsp_stale;   /* no PRF write / forward */
     end
   
   assign cache_accesses = r_cache_accesses;
   assign cache_hits = r_cache_hits;

   wire					 w_cacheable_mem_rsp_valid = (r_state == INJECT_RELOAD) & 
					 mem_rsp_valid;
   /* fill -> load bypass: the simple load that owns this fill takes its data from
    * the fill itself (no array write + port-1 re-lookup + registered hit).  Its
    * ordering checks were all made on its first pass (an overlapping older LSU store
    * blocks it BLK_SB_*, an MQ store is ahead of it), and the L1D held no copy, so
    * the fill is current.  If a port-2 op answers this cycle (they share the
    * response), the bypass response goes out next cycle from r_fill_rsp: no
    * port-2 request is accepted on the fill cycle and the MQ's next pop answers a
    * cycle later, so that slot is always free. */
   wire					 w_fill_bypass = w_cacheable_mem_rsp_valid &
					 (r_mem_req_opcode == MEM_LW) &
					 r_req.lsu_hold & !r_req.is_store;
   mem_rsp_t				 t_fill_rsp, r_fill_rsp;
   /* start the fill straight from the port-2 miss (no MQ pop + port-1 re-lookup) */
   logic				 t_direct_fill_ok, t_direct_fill;
   logic				 n_fill_rsp_pend, r_fill_rsp_pend;
   
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
   logic [N_ROB_ENTRIES-1:0] r_missed;
   logic [2*N_ROB_ENTRIES-1:0] r_rob_inflight;   /* indexed {restart color, rob_ptr} */

   logic r_link_reg_val;
   logic [`PA_WIDTH-1:0] r_link_reg;
   wire w_match_link = r_link_reg_val &&
                       (r_link_reg == {r_req.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN],
                                       {`LG_L1D_CL_LEN{1'b0}}});
   wire w_match_link2 = r_link_reg_val &&
                        (r_link_reg == {r_req2.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN],
                                        {`LG_L1D_CL_LEN{1'b0}}});

`ifdef VERILATOR
   logic r_pg_wait2;
   always_ff@(posedge clk)
     begin
	r_pg_wait2 <= reset ? 1'b0 : (r_state == FLUSH_PG_WAIT) & (n_state == FLUSH_PG_WAIT);
     end
   /* XPG_INV found a dirty line: the page was not cleaned before its DMA deposit */
   always_ff@(negedge clk)
     begin
	if((r_state == FLUSH_PG) & flush_cl_inval & w_pg_hit & r_dirty_out)
	  begin
	     $display("[pgdrop-dirty] L1D cyc=%d pa=%x", r_cycle, w_pg_line);
	  end
	/* the walk held the index, so from the 2nd wait cycle on the RAM output is the
	 * post-invalidate line: a page op must never leave a page line valid */
	if((r_state == FLUSH_PG_WAIT) & r_pg_wait2 & w_pg_hit)
	  begin
	     $display("[pgwalk] LINE STILL VALID after page op: cyc=%d pa=%x", r_cycle, w_pg_line);
	     $stop();
	  end
	if((r_state == FLUSH_PG_WAIT) & mem_rsp_valid & flush_cl_inval & mem_rsp_load_data[0])
	  begin
	     $display("[pgdrop-dirty] L2 cyc=%d pa=%x", r_cycle, w_pg_line);
	  end
     end // always_ff
`endif
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
	else if(r_got_req2 && w_req2_breaks_link && !r_req2.commit)
	  begin
	     /* in-order first pass breaks the link (model selected above) */
	     r_link_reg_val <= 1'b0;
	  end
     end


   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_n_inflight <= 'd0;
	  end
	else
	  begin
	     /* a cache-owned block (MISS / ST_CONFLICT) stays counted until its wakeup,
	      * so memq_empty (the drain condition) cannot assert while one is owed */
	     r_n_inflight <= r_n_inflight + {{`LG_MRQ_ENTRIES{1'b0}}, t_got_req2}
			     - {{`LG_MRQ_ENTRIES{1'b0}}, (w_rsp_v | w_wake_v | (w_blk_v & w_rsp.blk[2]))}
			     - {{`LG_MRQ_ENTRIES{1'b0}}, core_mem_st_done_valid}
			     - {{`LG_MRQ_ENTRIES{1'b0}}, t_mq_stale_owed};
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
	     if(t_push_miss && !r_req2.commit)
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
	     if(t_direct_fill)
	       begin
		  r_rob_inflight[{r_req2.restart_id, r_req2.rob_ptr}] <= 1'b1;
	       end
	     if(r_got_req2 && !drain_ds_complete && t_push_miss && !r_req2.commit)
	       begin
		  //$display("rob entry %d enters at cycle %d", r_req2.rob_ptr, r_cycle);
		  
		  if(r_rob_inflight[{r_req2.restart_id, r_req2.rob_ptr}] == 1'b1)
		    $display("entry %d should not be inflight\n", r_req2.rob_ptr);
		  
		  r_rob_inflight[{r_req2.restart_id, r_req2.rob_ptr}] <= 1'b1;
	       end
	     if(r_got_req && r_valid_out && (r_tag_out == r_cache_tag) && !r_req.commit)
	       begin
		  //$display("rob entry %d leaves at cycle %d", r_req.rob_ptr, r_cycle);
		  //if(r_rob_inflight[{r_req.restart_id, r_req.rob_ptr}] == 1'b0) 
		  //$display("huh %d should be inflight....\n", r_req.rob_ptr);
		  
		  r_rob_inflight[{r_req.restart_id, r_req.rob_ptr}] <= 1'b0;
	       end
	     else if(w_fill_bypass)
	       begin
		  r_rob_inflight[{r_req.restart_id, r_req.rob_ptr}] <= 1'b0;
	       end
	     else if((r_state == INJECT_UNCACHE_STORE | r_state == INJECT_UNCACHE_LOAD) & mem_rsp_valid & !r_req.commit)
	       begin
		  //if(r_rob_inflight[{r_req.restart_id, r_req.rob_ptr}] == 1'b0) 
		  //$display("huh %d should be inflight....\n", r_req.rob_ptr);
		  
		  r_rob_inflight[{r_req.restart_id, r_req.rob_ptr}] <= 1'b0;
	       end
	     if(t_mq_stale_drop)
	       begin
		  r_rob_inflight[{t_mem_head.restart_id, t_mem_head.rob_ptr}] <= 1'b0;
	       end
	     if(t_ucld_dead_drop)
	       begin
		  r_rob_inflight[{r_req.restart_id, r_req.rob_ptr}] <= 1'b0;
	       end
	     /* a CACHE hit-op retry completes the op on THIS pass whether it hits,
	      * misses, or tag-mismatches (the line op / L2 scrub is issued either
	      * way) -- clear its inflight bit unconditionally, else a miss/mismatch
	      * chop leaves rob_inflight stuck and the next op reusing that rob_ptr
	      * can never be accepted (l1d wedge, MQ empty). */
	     if(r_got_req & w_is_chop_r)
	       begin
		  r_rob_inflight[{r_req.restart_id, r_req.rob_ptr}] <= 1'b0;
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
	/* merge loads (LWL/LWR/LDL/LDR) take their register merge value from
	 * their LSU slot; MQ entries and direct fills carry it in .data */
	if(r_req2.op == MEM_LWL || r_req2.op == MEM_LWR ||
	   r_req2.op == MEM_LDL || r_req2.op == MEM_LDR)
	  begin
	     t_remapped_req2.data = r_sb_data[r_req2.lsu_idx];
	  end
     end

   /* ---------------- LSU store buffer (payload only) ----------------
    * One slot per LSU entry.  A plain store's port-2 pass (translation, fault
    * check, early ack) writes its PA/mask/op/cacheability here; its data arrives
    * separately from the LSU (lsu_sb.data_*).  The LSU owns liveness, age,
    * retirement and drain; a load compares against the slots its LSU entry saw as
    * older stores at issue (lsu_older_st), still holding the same store (epoch). */
   localparam N_LSU = 1 << `LG_MEM_SCHED_ENTRIES;
   logic [`PA_WIDTH-1:0] r_sb_pa[N_LSU-1:0];
   logic [15:0] 	 r_sb_mask[N_LSU-1:0];
   mem_op_t		 r_sb_op[N_LSU-1:0];
   logic [N_LSU-1:0] 	 r_sb_cached;
   logic [N_LSU-1:0] 	 r_sb_scok;       /* SC/SCD: link held at the address pass */
   logic [63:0] 	 r_sb_data[N_LSU-1:0];
   logic 		 t_sb_wr;
   /* pipetrace: the port-2 / port-1 outcome for this cycle's op (0 = none) */
   logic [7:0] 		 t_pt2, t_pt1;
   logic 		 t_p2_ok, t_p2_accept;
   /* hit-under-miss: the port-2 request was read from the set being filled */
   logic 		 r_fill_conflict2;

   always_ff@(posedge clk)
     begin
	if(t_sb_wr)
	  begin
	     r_sb_pa[r_req2.lsu_idx] <= w_mapped_addr;
	     r_sb_mask[r_req2.lsu_idx] <= make_mask(r_req2);
	     r_sb_op[r_req2.lsu_idx] <= r_req2.op;
	     r_sb_cached[r_req2.lsu_idx] <= t_remapped_req2.cached;
	     r_sb_scok[r_req2.lsu_idx] <= w_match_link2;
	  end
	if(lsu_sb.data_valid)
	  begin
	     r_sb_data[lsu_sb.data_idx] <= lsu_sb.data;
	  end
     end // always_ff@ (posedge clk)

   /* a store's bytes placed in a 16B line (byte k at bits 8k+7:8k), as the port-1
    * merge writes them: SB raw, SH/SW/SD byte-swapped */
   function logic [L1D_CL_LEN_BITS-1:0] sb_line(mem_op_t op, logic [3:0] off, logic [63:0] d);
      logic [L1D_CL_LEN_BITS-1:0] l;
      l = (op == MEM_SB) ? {120'd0, d[7:0]} :
	  (op == MEM_SH) ? {112'd0, bswap16(d[15:0])} :
	  (op == MEM_SW) ? {96'd0, bswap32(d[31:0])} :
	  {64'd0, bswap64(d)};
      return l << {off, 3'd0};
   endfunction

   function logic [L1D_CL_LEN_BITS-1:0] expand_mask(logic [15:0] m);
      logic [L1D_CL_LEN_BITS-1:0] e;
      for(integer b = 0; b < 16; b = b + 1)
	begin
	   e[b*8 +: 8] = {8{m[b]}};
	end
      return e;
   endfunction

   logic [N_LSU-1:0] t_sb_older, t_sb_match, t_sb_youngest;
   logic [15:0] 	 t_ld_mask2;
   logic [`LG_MEM_SCHED_ENTRIES-1:0] t_sb_y;
   logic 				   t_sb_fwd, t_sb_blk;
   blk_code_t				   t_sb_code;
   logic [N_LSU-1:0] 			   t_sb_blk_st;
   logic [L1D_CL_LEN_BITS-1:0] 		   t_sb_line, t_sb_bytes;
   logic 				   w_sb_fwd_op;

   always_comb
     begin
	t_ld_mask2 = make_mask(r_req2);
	t_sb_y = 'd0;
	for(integer j = 0; j < N_LSU; j = j + 1)
	  begin
	     t_sb_older[j] = r_req2.lsu_older_st[j] & lsu_sb.live[j] & (lsu_sb.epoch[j] == r_req2.lsu_older_ep[j]);
	     t_sb_match[j] = t_sb_older[j] &
			     (r_sb_pa[j][`PA_WIDTH-1:`LG_L1D_CL_LEN] == w_mapped_addr[`PA_WIDTH-1:`LG_L1D_CL_LEN]) &
			     (|(r_sb_mask[j] & t_ld_mask2));
	  end
	/* the youngest overlapping older store: no other match is younger than it */
	for(integer j = 0; j < N_LSU; j = j + 1)
	  begin
	     t_sb_youngest[j] = t_sb_match[j] &
				((t_sb_match & ~lsu_sb.matrix[j*N_LSU +: N_LSU] & ~(1 << j)) == 'd0);
	     if(t_sb_youngest[j])
	       begin
		  t_sb_y = j[`LG_MEM_SCHED_ENTRIES-1:0];
	       end
	  end
	/* the youngest overlapping store is a whole-access store sb_line can place
	 * (partial stores and SC never forward: the load waits for their drain) */
	w_sb_fwd_op = (r_sb_op[t_sb_y] == MEM_SB) | (r_sb_op[t_sb_y] == MEM_SH) |
		      (r_sb_op[t_sb_y] == MEM_SW) | (r_sb_op[t_sb_y] == MEM_SD);
	t_sb_line = sb_line(r_sb_op[t_sb_y], r_sb_pa[t_sb_y][3:0], r_sb_data[t_sb_y]);
	t_sb_bytes = expand_mask(r_sb_mask[t_sb_y]);
	/* forward when the youngest overlapping older store covers every load byte */
	t_sb_fwd = (|t_sb_match) & lsu_sb.data_ok[t_sb_y] & r_sb_cached[t_sb_y] & t_remapped_req2.cached &
		   w_sb_fwd_op &
		   ((t_ld_mask2 & ~r_sb_mask[t_sb_y]) == 16'd0);
	/* an uncached load waits for EVERY older store (device ordering); a cached
	 * one only for overlapping stores it cannot forward from */
	t_sb_blk = r_req2.lsu_hold & !r_req2.is_store &
		   (t_remapped_req2.cached ? ((|t_sb_match) & !t_sb_fwd) : (|t_sb_older));
	t_sb_code = BLK_SB_CONFLICT;
	t_sb_blk_st = t_remapped_req2.cached ? t_sb_match : t_sb_older;
	if(t_remapped_req2.cached && !lsu_sb.data_ok[t_sb_y] && r_sb_cached[t_sb_y] && w_sb_fwd_op &&
	   ((t_ld_mask2 & ~r_sb_mask[t_sb_y]) == 16'd0))
	  begin
	     /* only the data is missing: wait for it, not for the drain */
	     t_sb_code = BLK_SB_DATA;
	     t_sb_blk_st = t_sb_youngest;
	  end
     end // always_comb

   /* commit: the MQ entry is rebuilt from the store buffer (already physical,
    * already retired -- it fires at the MQ head with no graduation wait) */
   mem_req_t t_mq_push_req;
   always_comb
     begin
	t_mq_push_req = t_remapped_req2;
	if(r_req2.commit)
	  begin
	     t_mq_push_req = r_req2;
	     t_mq_push_req.addr = {{(`M_WIDTH-`PA_WIDTH){1'b0}}, r_sb_pa[r_req2.lsu_idx]};
	     t_mq_push_req.op = r_sb_op[r_req2.lsu_idx];
	     t_mq_push_req.data = r_sb_data[r_req2.lsu_idx];
	     t_mq_push_req.cached = r_sb_cached[r_req2.lsu_idx];
	     t_mq_push_req.sc_ok = r_sb_scok[r_req2.lsu_idx];
	     t_mq_push_req.mapped = 1'b0;
	     t_mq_push_req.is_store = 1'b1;
	     t_mq_push_req.bad_addr = 1'b0;
	  end
     end

`ifdef LSU_TRACE
   always_ff@(negedge clk)
     begin
	if(!reset && t_p2_accept && (r_state == INJECT_RELOAD))
	  begin
	     $display("[L1D] cyc=%0d hum-accept op=%0d", r_cycle, core_mem_req.op);
	  end
	if(!reset && r_got_req2 && (r_state == INJECT_RELOAD) && (n_core_mem_rsp_valid && n_core_mem_rsp.dst_valid))
	  begin
	     $display("[L1D] cyc=%0d hum-hit", r_cycle);
	  end
     end // always_ff@ (negedge clk)
`endif

   /* per-color accounting for the core's flip-back guard: ops accepted and not yet
    * answered (a cache-owned block stays owed until its wakeup/data), plus queued
    * MQ entries (an early-acked old-path store still sits in the MQ) */
   logic [`LG_MRQ_ENTRIES+1:0] r_color_cnt [1:0];
   logic [1:0] 		       t_mq_color;
   always_ff@(posedge clk)
     begin
	for(integer c = 0; c < 2; c = c + 1)
	  begin
	     if(reset)
	       begin
		  r_color_cnt[c] <= 'd0;
	       end
	     else
	       begin
		  r_color_cnt[c] <= r_color_cnt[c]
				    + {{(`LG_MRQ_ENTRIES+1){1'b0}}, (t_got_req2 && !core_mem_req.commit && (core_mem_req.restart_id == c[0]))}
				    - {{(`LG_MRQ_ENTRIES+1){1'b0}}, ((w_rsp_v | w_wake_v | (w_blk_v & w_rsp.blk[2])) && (w_rsp.restart_id == c[0]))}
				    - {{(`LG_MRQ_ENTRIES+1){1'b0}}, (t_mq_stale_owed && (t_mem_head.restart_id == c[0]))};
	       end
	  end
     end // always_ff@ (posedge clk)
`ifdef VERILATOR
   /* debug only: exact shadow of the per-color accounting, keyed {color, rob_ptr}.
    * Catches the leak/double-answer the moment it happens, not at the next flip. */
   logic [N_ROB_ENTRIES-1:0] r_dbg_out [1:0];
   logic [7:0] r_dbg_mm_cnt;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_dbg_out[0] <= '0;
	     r_dbg_out[1] <= '0;
	  end
	else
	  begin
	     logic [N_ROB_ENTRIES-1:0] t_o0, t_o1;
	     t_o0 = r_dbg_out[0];
	     t_o1 = r_dbg_out[1];
	     if(t_got_req2 && !core_mem_req.commit)
	       begin
		  if(core_mem_req.restart_id ? t_o1[core_mem_req.rob_ptr] : t_o0[core_mem_req.rob_ptr])
		    begin
		       $display("[COLORSHADOW] cyc=%0d double accept color=%0d rob=%0d op=%0d", r_cycle, core_mem_req.restart_id, core_mem_req.rob_ptr, core_mem_req.op);
		    end
		  if(core_mem_req.restart_id) t_o1[core_mem_req.rob_ptr] = 1'b1; else t_o0[core_mem_req.rob_ptr] = 1'b1;
	       end
	     if((w_rsp_v | w_wake_v | (w_blk_v & w_rsp.blk[2])))
	       begin
		  if(!(w_rsp.restart_id ? r_dbg_out[1][w_rsp.rob_ptr] : r_dbg_out[0][w_rsp.rob_ptr]))
		    begin
		       $display("[COLORSHADOW] cyc=%0d answer to non-outstanding color=%0d rob=%0d rsp=%b blk=%b(%0d) wake=%b st_commit_op=%0d",
				r_cycle, w_rsp.restart_id, w_rsp.rob_ptr, w_rsp_v, w_blk_v, w_rsp.blk, w_wake_v, r_req.op);
		    end
		  if(w_rsp.restart_id) t_o1[w_rsp.rob_ptr] = 1'b0; else t_o0[w_rsp.rob_ptr] = 1'b0;
	       end
	     if(t_mq_stale_owed)
	       begin
		  if(t_mem_head.restart_id) t_o1[t_mem_head.rob_ptr] = 1'b0; else t_o0[t_mem_head.rob_ptr] = 1'b0;
	       end
	     r_dbg_out[0] <= t_o0;
	     r_dbg_out[1] <= t_o1;
	  end
     end
   always_ff@(negedge clk)
     begin
	if(reset)
	  begin
	     r_dbg_mm_cnt <= 8'd0;
	  end
	else if((($countones(r_dbg_out[0]) != r_color_cnt[0]) || ($countones(r_dbg_out[1]) != r_color_cnt[1])) && (r_dbg_mm_cnt < 8'd20))
	  begin
	     r_dbg_mm_cnt <= r_dbg_mm_cnt + 8'd1;
	     $display("[COLORSHADOW] cyc=%0d count mismatch shadow=%0d/%0d cnt=%0d/%0d", r_cycle,
		      $countones(r_dbg_out[0]), $countones(r_dbg_out[1]), r_color_cnt[0], r_color_cnt[1]);
	  end
     end
`endif
`ifdef VERILATOR
   /* debug only: a color counter must never underflow or run away */
   always_ff@(negedge clk)
     begin
	for(integer c = 0; c < 2; c = c + 1)
	  begin
	     if(!reset && (r_color_cnt[c] > (N_MQ_ENTRIES + 8)))
	       begin
		  $display("[COLORCNT] cyc=%0d color %0d count %0d runaway/underflow", r_cycle, c, r_color_cnt[c]);
	       end
	  end
     end
`endif
   always_comb
     begin
	t_mq_color = 2'd0;
	for(integer i = 0; i < N_MQ_ENTRIES; i = i + 1)
	  begin
	     if(r_mq_addr_valid[i] && !r_mem_q[i].commit)
	       begin
		  t_mq_color[r_mem_q[i].restart_id] = 1'b1;
	       end
	  end
	mem_color_busy[0] = (r_color_cnt[0] != 'd0) | t_mq_color[0];
	mem_color_busy[1] = (r_color_cnt[1] != 'd0) | t_mq_color[1];
	/* independent of the color counters: the queue is empty, no pass or fill is
	 * in progress and no answer is on its way out */
	mem_quiet = mem_q_empty && (r_state == ACTIVE) && !r_got_req && !r_got_req2 &&
		    !r_fill_rsp_pend && !w_rsp_v && !w_blk_v && !w_wake_v;
     end // always_comb

`ifdef VERILATOR
   /* rv64core's restart_id check: nothing of a flushed era may be accepted */
   always_ff@(negedge clk)
     begin
	if(!reset && t_got_req2 && !core_mem_req.commit && (core_mem_req.restart_id != restart_color))
	  begin
	     $display("cycle %0d : current restart color is %0d but ingesting %0d", r_cycle, restart_color, core_mem_req.restart_id);
	     $stop();
	  end
     end // always_ff@ (negedge clk)
`endif

`ifdef PIPETRACE
   import "DPI-C" function void pt_event(input int rob_ptr, input int letter, input longint cycle);
   always_ff@(negedge clk)
     begin
	if(!reset && (t_pt2 != 8'd0))
	  begin
	     pt_event({{(32-`LG_ROB_ENTRIES){1'b0}}, r_req2.rob_ptr}, {24'd0, t_pt2}, {32'd0, r_cycle});
	  end
	if(!reset && (t_pt1 != 8'd0))
	  begin
	     pt_event({{(32-`LG_ROB_ENTRIES){1'b0}}, r_req.rob_ptr}, {24'd0, t_pt1}, {32'd0, r_cycle});
	  end
	/* L1D-miss path of a load (the owner is r_req; stores/commits are skipped --
	 * a commit's rob_ptr is stale) */
	if(!reset && t_pop_mq && !t_mem_head.is_store && !t_mem_head.commit)
	  begin
	     pt_event({{(32-`LG_ROB_ENTRIES){1'b0}}, t_mem_head.rob_ptr}, "O", {32'd0, r_cycle});
	  end
	if(!reset && t_direct_fill)
	  begin
	     pt_event({{(32-`LG_ROB_ENTRIES){1'b0}}, r_req2.rob_ptr}, "E", {32'd0, r_cycle});
	  end
	if(!reset && n_mem_req_valid && !r_mem_req_valid && !r_req.is_store && !t_direct_fill)
	  begin
	     pt_event({{(32-`LG_ROB_ENTRIES){1'b0}}, r_req.rob_ptr}, (n_mem_req_opcode == MEM_LW) ? "E" : "Y", {32'd0, r_cycle});
	  end
	if(!reset && (r_state == HANDLE_RELOAD) && !r_req.is_store)
	  begin
	     pt_event({{(32-`LG_ROB_ENTRIES){1'b0}}, r_req.rob_ptr}, "J", {32'd0, r_cycle});
	  end
     end // always_ff@ (negedge clk)
`endif

   /* the deferred fill response: FUNCTIONAL state, so it must not live under
    * `ifdef VERILATOR (it once did -- synthesis dropped the register, the FPGA
    * delivered a zero response and the waiting load wedged; sim never saw it) */
   always_ff@(posedge clk)
     begin
	if(n_fill_rsp_pend)
	  begin
	     r_fill_rsp <= t_fill_rsp;
	  end
     end

`ifdef VERILATOR
   always_ff@(posedge clk)
     begin
	if(!reset && r_fill_rsp_pend && (r_got_req2 || r_got_req))
	  begin
	     $display("[LSU] cyc=%0d deferred fill rsp collides with a port pass", r_cycle);
	     $stop();
	  end
     end // always_ff@ (posedge clk)

   /* rsp / block / wakeup share core_mem_rsp: port 1 and port 2 never answer in
    * the same cycle (a port-1 read retry holds off the port-2 accept) */
   always_ff@(posedge clk)
     begin
	if(!reset && ((n_core_mem_rsp_valid + n_core_mem_blk_valid + n_core_mem_wake_valid) > 2'd1))
	  begin
	     $display("[LSU] cyc=%0d l1d rsp/blk/wake collide %b%b%b", r_cycle,
		      n_core_mem_rsp_valid, n_core_mem_blk_valid, n_core_mem_wake_valid);
	     $stop();
	  end
     end // always_ff@ (posedge clk)

   /* an uncached LOAD must reach memory only when non-speculative (at the ROB
    * head, the head's committable delay slot, or draining dead ops, which the
    * t_ucld_dead_drop arm answers without an access) */
   always_ff@(posedge clk)
     begin
	if(!reset && (r_state == ACTIVE) && (n_state == INJECT_UNCACHE_LOAD) &&
	   !(head_of_rob_ptr_valid && (head_of_rob_ptr == r_req.rob_ptr)) &&
	   !(head_of_rob_ds_committable && (next_head_of_rob_ptr == r_req.rob_ptr)))
	  begin
	     $display("[UCSPEC] cyc=%0d speculative uncached load pa=%x rob_ptr=%0d head=%0d",
		      r_cycle, r_req.addr, r_req.rob_ptr, head_of_rob_ptr);
	  end
     end // always_ff@ (posedge clk)
`endif

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
     end // always_ff
`endif

   /* incoming byte masks for the port-2 same-set hazard refinement.
    * t_mq_mask  = the request being PUSHED to the miss-queue (registered port2 = r_req2).
    * t_req_mask = the INCOMING port-2 request tested against the MQ (core_mem_req,
    *              the one whose set index feeds t_cache_idx2).  Mirrors nu_l1d. */
   logic [15:0] t_mq_mask, t_req_mask;
   always_comb
     begin
	t_mq_mask = make_mask(t_mq_push_req);
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
	     r_mem_q[r_mq_tail_ptr[`LG_MRQ_ENTRIES-1:0] ] <= t_mq_push_req;
	     r_mq_addr[r_mq_tail_ptr[`LG_MRQ_ENTRIES-1:0]] <= t_mq_push_req.addr[IDX_STOP-1:IDX_START];
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
	/* hit-under-miss: the port-2 read raced the outstanding fill (or the dirty
	 * victim writeback) of its set -- its RAM output is not trustworthy */
	r_fill_conflict2 <= reset ? 1'b0 : (t_got_req2 && (r_state == INJECT_RELOAD) &&
					    (t_cache_idx2 == r_mem_req_addr[IDX_STOP-1:IDX_START]));
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
	     
	     r_is_retry <= 1'b0;
	     r_flush_complete <= 1'b0;
	     r_flush_req <= 1'b0;
	     r_flush_cl_req <= 1'b0;
	     r_dma_inval_req <= 1'b0;
	     r_dma_inval_ack <= 1'b0;
	     r_cl_is_dma <= 1'b0;
	     r_flush_pg_req <= 1'b0;
	     r_pg_off <= 'd0;
	     r_pg_dirty_cnt <= 16'd0;
	     r_chop_wait <= 1'b0;
	     r_chop_beat <= 1'b0;
	     r_flush_cl_beat <= 1'b0;
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
	     r_core_mem_blk_valid <= 1'b0;
	     r_core_mem_wake_valid <= 1'b0;
	     r_core_mem_st_done_valid <= 1'b0;
	     r_fill_rsp_pend <= 1'b0;
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
	     r_is_retry <= n_is_retry;
	     r_flush_complete <= n_flush_complete;
	     r_flush_req <= n_flush_req;
	     r_flush_cl_req <= n_flush_cl_req;
	     r_dma_inval_req <= n_dma_inval_req;
	     r_dma_inval_ack <= n_dma_inval_ack;
	     r_cl_is_dma <= n_cl_is_dma;
	     r_flush_pg_req <= n_flush_pg_req;
	     r_pg_off <= n_pg_off;
	     r_pg_dirty_cnt <= n_pg_dirty_cnt;
	     r_chop_wait <= n_chop_wait;
	     r_chop_beat <= n_chop_beat;
	     r_flush_cl_beat <= n_flush_cl_beat;
	     r_cache_idx <= t_cache_idx;
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
	     r_core_mem_blk_valid <= n_core_mem_blk_valid;
	     r_core_mem_wake_valid <= n_core_mem_wake_valid;
	     r_core_mem_st_done_valid <= n_core_mem_st_done_valid;
	     r_fill_rsp_pend <= n_fill_rsp_pend;
	     r_core_mem_st_done_idx <= n_core_mem_st_done_idx;
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

 ram2r1w #(.WIDTH(N_TAG_BITS), .LG_DEPTH(`LG_L1D_NUM_SETS)) dc_tag
     (
      .clk(clk),
      .rd_addr0(t_cache_idx),
      .rd_addr1(t_cache_idx2),
`ifdef FORMAL_DPRELOAD
      .wr_addr(w_dpreload ? r_cache_idx : r_mem_req_addr[IDX_STOP-1:IDX_START]),
      .wr_data(w_dpreload ? fml_pre_tag : r_mem_req_addr[`PA_WIDTH-1:TAG_LSB]),
      .wr_en(w_cacheable_mem_rsp_valid | w_dpreload),
`else
      .wr_addr(r_mem_req_addr[IDX_STOP-1:IDX_START]),
      .wr_data(r_mem_req_addr[`PA_WIDTH-1:TAG_LSB]),
      .wr_en(w_cacheable_mem_rsp_valid),
`endif
      .rd_data0(r_tag_out),
      .rd_data1(r_tag_out2)
      );
     

   ram2r1w #(.WIDTH(L1D_CL_LEN_BITS), .LG_DEPTH(`LG_L1D_NUM_SETS)) dc_data
     (
      .clk(clk),
      .rd_addr0(t_cache_idx),
      .rd_addr1(t_cache_idx2),
`ifdef FORMAL_DPRELOAD
      .wr_addr(w_dpreload ? r_cache_idx : t_array_wr_addr),
      .wr_data(w_dpreload ? fml_pre_data : t_array_wr_data),
      .wr_en(t_array_wr_en | w_dpreload),
`else
      .wr_addr(t_array_wr_addr),
      .wr_data(t_array_wr_data),
      .wr_en(t_array_wr_en),
`endif
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
      .rd_addr1(t_cache_idx2),
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
`ifdef FORMAL_DPRELOAD
	     /* mark VALID instead of invalid, so the line is live after the walk */
	     if(w_dpreload) begin t_valid_value = 1'b1; end
`endif
	  end
	else if(w_cacheable_mem_rsp_valid)
	  begin
	     t_valid_wr_addr = r_mem_req_addr[IDX_STOP-1:IDX_START];
	     t_valid_value = !r_inhibit_write;
	     t_write_valid_en = 1'b1;
	  end
     end // always_comb
      
   ram2r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1D_NUM_SETS)) dc_valid
     (
      .clk(clk),
      .rd_addr0(t_cache_idx),
      .rd_addr1(t_cache_idx2),
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
	if(t_sb_fwd)
	  begin
	     t_data2 = (t_data2 & ~t_sb_bytes) | (t_sb_line & t_sb_bytes);
	  end
	t_w32_2 = (select_cl32(t_data2, r_req2.addr[WORD_STOP-1:WORD_START]));
	t_bswap_w32_2 = bswap32(t_w32_2);

	t_hit_cache2 = r_valid_out2 && (r_tag_out2 == w_tlb_tag2) && r_got_req2 && !r_fill_conflict2 &&
		      ((r_state == ACTIVE) || (r_state == INJECT_RELOAD));
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
		      t_rsp_data2 = {{32{t_remapped_req2.data[31]}}, t_remapped_req2.data[31:8], t_bswap_w32_2[31:24]};
		   end
		 2'd1:
		   begin
		      t_rsp_data2 = {{32{t_remapped_req2.data[31]}}, t_remapped_req2.data[31:16], t_bswap_w32_2[31:16]};
		   end
		 2'd2:
		   begin
		      t_rsp_data2 = {{32{t_remapped_req2.data[31]}}, t_remapped_req2.data[31:24], t_bswap_w32_2[31:8]};				       
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
		      t_rsp_data2 = {{32{t_bswap_w32_2[23]}}, t_bswap_w32_2[23:0], t_remapped_req2.data[7:0]};
		   end
		 2'd2:
		   begin
		      t_rsp_data2 = {{32{t_bswap_w32_2[15]}}, t_bswap_w32_2[15:0], t_remapped_req2.data[15:0]};
		   end
		 2'd3:
		   begin
		      t_rsp_data2 = {{32{t_bswap_w32_2[7]}}, t_bswap_w32_2[7:0], t_remapped_req2.data[23:0]};
		   end
	       endcase // case (r_req.addr[1:0])
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;	       
	    end // case: MEM_LWL
	  MEM_LDL:
	    begin
	       /* Doubleword-aligned base: high word (MSW, lower addr) at dw_hi_idx,
		* low word (LSW, higher addr) at dw_hi_idx+1.
		* t_dword[63:56]=byte0(lowest addr) .. t_dword[7:0]=byte7(highest addr). */
	       begin
		  logic [63:0] 		       t_dword;
		  t_dword = bswap64(select_cl64(t_data2, r_req2.addr[DWORD_START]));
		  case(r_req2.addr[2:0])
		    3'd0: t_rsp_data2 = t_dword;
		    3'd1: t_rsp_data2 = {t_dword[55:0], t_remapped_req2.data[7:0]};
		    3'd2: t_rsp_data2 = {t_dword[47:0], t_remapped_req2.data[15:0]};
		    3'd3: t_rsp_data2 = {t_dword[39:0], t_remapped_req2.data[23:0]};
		    3'd4: t_rsp_data2 = {t_dword[31:0], t_remapped_req2.data[31:0]};
		    3'd5: t_rsp_data2 = {t_dword[23:0], t_remapped_req2.data[39:0]};
		    3'd6: t_rsp_data2 = {t_dword[15:0], t_remapped_req2.data[47:0]};
		    3'd7: t_rsp_data2 = {t_dword[7:0],  t_remapped_req2.data[55:0]};
		  endcase
	       end
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end // case: MEM_LDL
	  MEM_LDR:
	    begin
	       begin
		  logic [63:0] 		       t_dword;
		  t_dword = bswap64(select_cl64(t_data2, r_req2.addr[DWORD_START]));
		  case(r_req2.addr[2:0])
		    3'd0: t_rsp_data2 = {t_remapped_req2.data[63:8],  t_dword[63:56]};
		    3'd1: t_rsp_data2 = {t_remapped_req2.data[63:16], t_dword[63:48]};
		    3'd2: t_rsp_data2 = {t_remapped_req2.data[63:24], t_dword[63:40]};
		    3'd3: t_rsp_data2 = {t_remapped_req2.data[63:32], t_dword[63:32]};
		    3'd4: t_rsp_data2 = {t_remapped_req2.data[63:40], t_dword[63:24]};
		    3'd5: t_rsp_data2 = {t_remapped_req2.data[63:48], t_dword[63:16]};
		    3'd6: t_rsp_data2 = {t_remapped_req2.data[63:56], t_dword[63:8]};
		    3'd7: t_rsp_data2 = t_dword;
		  endcase
	       end
	       t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2;
	    end // case: MEM_LDR
	  default:
	    begin
	    end
	endcase
     end
   
   always_comb
     begin
	t_data = ((r_state == INJECT_UNCACHE_LOAD) | w_fill_bypass) ? mem_rsp_load_data :
		 (r_got_req & r_must_forward ? r_array_wr_data : r_array_out);
	
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
	       t_array_data = r_req.sc_ok ? merge_cl32(t_data, bswap32(r_req.data[31:0]), r_req.addr[WORD_STOP-1:WORD_START]) : t_data;
	       t_rsp_data = 'd0;
	       t_rsp_dst_valid = 1'b0;
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload) && r_req.sc_ok;
	    end
	  MEM_SCD:
	    begin
	       t_array_data = r_req.sc_ok ? merge_cl64(t_data, bswap64(r_req.data[63:0]), r_req.addr[DWORD_START]) : t_data;
	       t_rsp_data = 'd0;
	       t_rsp_dst_valid = 1'b0;
	       t_wr_array = t_hit_cache && (r_is_retry || r_did_reload) && r_req.sc_ok;
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

`ifdef L1D_ONE_MEMOP
   /* DIAGNOSTIC (opt-in via SV2V_DEFINES=L1D_ONE_MEMOP): accept a new core memory op
    * ONLY when the L1D is fully idle -- nothing in either pipe stage (r_got_req/req2),
    * no outstanding miss (r_n_inflight==0), and the store queue drained (mem_q_empty).
    * This removes ALL inter-memop overlap/forwarding, to test whether the long-lived
    * pointer corruption is a concurrent-memop (store-forward / bypass) race.  Slow. */
   wire w_one_memop_ok = mem_q_empty & (r_n_inflight == 'd0) & !r_got_req & !r_got_req2;
`else
   wire w_one_memop_ok = 1'b1;
`endif
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
   /* the queued head op is non-speculative: at the ROB head, a committable delay
    * slot of the head, or everything left is dead (drain) */
   wire	w_mq_head_nonspec = (head_of_rob_ptr_valid ? (head_of_rob_ptr == t_mem_head.rob_ptr) : 1'b0) |
			    drain_ds_complete |
			    (head_of_rob_ds_committable & (next_head_of_rob_ptr == t_mem_head.rob_ptr));
   /* the port-2 op is non-speculative (same test as w_uncachable_req) */
   wire	w_req2_nonspec = (head_of_rob_ptr_valid ? (head_of_rob_ptr == r_req2.rob_ptr) : 1'b0) |
			 drain_ds_complete |
			 (head_of_rob_ds_committable & (next_head_of_rob_ptr == r_req2.rob_ptr));
   /* CACHE hit ops are serializing (the LSU issues one only when it is the oldest
    * memory op and holds everything younger): admit it only when non-speculative,
    * then perform it with no graduation wait and answer when it is done */
   wire	w_chop_req = (core_mem_req.op == MEM_CHWB) | (core_mem_req.op == MEM_CHWBINV) | (core_mem_req.op == MEM_CHINV);
   /* NB: never hold an LSU-held op (lsu_hold) here waiting for the ROB head: the
    * exec request FIFO is in order, and an OLDER op re-issued after a block may be
    * queued behind it -> deadlock.  An uncached simple load answers BLK_UNCACHEABLE
    * at port 2 instead; a plain store's address pass touches no memory (the device
    * write is its post-retire commit).  CACHE ops (also lsu_hold) are serializing,
    * so nothing older can be queued behind them. */
   wire	w_uncachable_req = (core_mem_req_valid & (((core_mem_req.cached==1'b0) & !core_mem_req.lsu_hold) |
						   w_fence_load | w_serialize_all | w_chop_req)) ?
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
	     /* translate whatever is presented, NOT only an accepted request: the
	      * registered outputs are read only in the cycle after an accept, when
	      * this is that request's address anyway.  Keeps the port-2 accept
	      * decision (store-buffer compare, fill start, ...) off the CAM path. */
	     .req(core_mem_req_valid),
	     .va(core_mem_req.addr),
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
`ifdef L1D_PORT2_ALWAYS_MISS
	/* DIAGNOSTIC: force every core access to MISS the speculative VA-indexed port-2 read,
	 * so it serializes through the in-order miss queue (the same path LWL/LWR always take).
	 * Removes the speculative VIPT hit + TLB-physical-tag race entirely -> memory system is
	 * fully in-order.  If the IRIX be/chkdev corruption disappears, port-2 speculation (fed
	 * by the timing-critical TLB) is the culprit.  Very slow (every load refills from L2). */
	t_port2_hit_cache = 1'b0;
`else
	t_port2_hit_cache = r_valid_out2 && (r_tag_out2 == w_tlb_tag2);
`endif
	t_mem_req_mask = make_mask(r_req);
	n_state = r_state;
	n_prb_seen = r_prb_seen & probe_req;
	n_prb_ack = 1'b0;
	n_prb_dirty = r_prb_dirty;
	n_prb_data = r_prb_data;
	n_prb_ret = r_prb_ret;
	n_prb_save = r_prb_save;
	n_prb_tag = r_prb_tag;
	t_prb_hit = 1'b0;
	/* a probe the L1D has not answered yet: stop taking new port-1/port-2 work so the
	 * pipes drain and it can be taken (a steady request stream must not starve it) */
	t_prb_pend = probe_req & !r_prb_seen;
	t_prb_ok_state = (r_state == ACTIVE) || (r_state == INJECT_RELOAD) ||
			 (r_state == INJECT_UNCACHE_STORE) || (r_state == INJECT_UNCACHE_LOAD) ||
			 (r_state == FLUSH_CL_WAIT) || (r_state == FLUSH_CACHE_WAIT) ||
			 (r_state == FLUSH_CACHE_LAST_WAIT) || (r_state == FLUSH_PG_WAIT) ||
			 ((r_state == UNCACHE_WB) && r_uncache_wb_dirty);
	t_miss_idx = r_miss_idx;
	t_miss_addr = r_miss_addr;
	t_cache_idx = 'd0;
	t_cache_tag = 'd0;
	
	t_cache_idx2 = 'd0;
	t_cache_tag2 = 'd0;	

	
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
	
	n_mem_req_valid = 1'b0;
	n_mem_req_cacheable = r_mem_req_cacheable;
	n_mem_req_mask = r_mem_req_mask;
	n_mem_req_addr = r_mem_req_addr;
	n_mem_req_store_data = r_mem_req_store_data;
	n_mem_req_opcode = r_mem_req_opcode;
	t_pop_mq = 1'b0;
	n_core_mem_rsp_valid = 1'b0;
	n_core_mem_blk_valid = 1'b0;
	n_core_mem_wake_valid = 1'b0;
	n_core_mem_st_done_valid = 1'b0;
	n_core_mem_st_done_idx = r_req.lsu_idx;
	t_sb_wr = 1'b0;
	t_pt2 = 8'd0;
	t_pt1 = 8'd0;
	t_p2_accept = 1'b0;
	/* port-2 accept conditions shared by ACTIVE and hit-under-miss */
	t_req_stale = core_mem_req_valid && !core_mem_req.commit && (core_mem_req.restart_id != restart_color);
	t_mq_stale_drop = 1'b0;
	t_mq_stale_owed = 1'b0;
	t_p2_ok = core_mem_req_valid && !t_req_stale &&
		  !(mem_q_almost_full||mem_q_full) &&
		  !(r_last_wr2 && (r_cache_idx2 == core_mem_req.addr[IDX_STOP-1:IDX_START]) && !core_mem_req.is_store) &&
		  w_uncachable_req &&
		  (core_mem_req.is_atomic ? mem_q_empty : 1'b1) &&
		  w_one_memop_ok &&
		  (core_mem_req.commit || !r_rob_inflight[{core_mem_req.restart_id, core_mem_req.rob_ptr}]);
	
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
	n_core_mem_rsp.lsu_hold = r_req.lsu_hold;
	n_core_mem_rsp.lsu_idx = r_req.lsu_idx;
	n_core_mem_rsp.blk = BLK_NONE;
	n_core_mem_rsp.blk_st = 'd0;
	n_core_mem_rsp.restart_id = r_req.restart_id;
	
	n_cache_accesses = r_cache_accesses;
	n_cache_hits = r_cache_hits;
	
	n_flush_req = r_flush_req | flush_req;
	n_flush_cl_req = r_flush_cl_req | flush_cl_req;
	n_dma_inval_req = r_dma_inval_req | dma_inval_req;
	n_dma_inval_ack = 1'b0;
	n_cl_is_dma = r_cl_is_dma;
	n_flush_pg_req = r_flush_pg_req | flush_pg_req;
	n_pg_off = r_pg_off;
	n_pg_dirty_cnt = r_pg_dirty_cnt;
	n_flush_complete = 1'b0;
	t_addr = 'd0;
	
	n_inhibit_write = r_inhibit_write;
	
	t_mark_invalid = 1'b0;
	n_is_retry = 1'b0;
	n_chop_wait = r_chop_wait;
	n_chop_beat = r_chop_beat;
	n_flush_cl_beat = r_flush_cl_beat;
	t_ucld_dead_drop = 1'b0;
	

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
	
	/* direct fill: a cacheable simple load that misses on port 2 while the l1d is
	 * otherwise idle (ACTIVE, MQ empty, port 1 idle, no flush) and whose victim is
	 * clean and not just written by port 1 (rr_last_wr: the port-2 read could predate
	 * that write) starts its fill here.  Anything else takes the MQ path. */
	t_direct_fill = 1'b0;
	t_direct_fill_ok = (r_state == ACTIVE) && r_got_req2 && !drain_ds_complete &&
			   r_req2.lsu_hold && !r_req2.is_store && t_remapped_req2.cached &&
			   !t_port2_hit_cache && !r_hit_busy_addr2 &&
			   mem_q_empty && !r_got_req && !rr_last_wr && !r_lock_cache &&
			   !n_flush_req && !n_flush_cl_req && !r_fill_rsp_pend &&
			   !(r_valid_out2 && r_dirty_out2) &&
			   /* the victim port 2 read (VA index) must be the set the fill
			    * replaces (PA index): differs only when the L1D exceeds a page */
			   (r_cache_idx2 == t_remapped_req2.addr[IDX_STOP-1:IDX_START]);

	/* fill -> load bypass response (w_fill_bypass): built from the port-1 defaults
	 * above; a deferred one (r_fill_rsp_pend) goes out in the always-free next slot */
	n_fill_rsp_pend = 1'b0;
	t_fill_rsp = n_core_mem_rsp;
	t_fill_rsp.data = t_rsp_data[`M_WIDTH-1:0];
	t_fill_rsp.dst_valid = r_req.dst_valid;
	t_fill_rsp.bad_addr = r_req.bad_addr;
	if(r_fill_rsp_pend)
	  begin
	     n_core_mem_rsp = r_fill_rsp;
	     n_core_mem_rsp_valid = 1'b1;
	  end

	/* port 2 (first pass) -- processed in ACTIVE and, for hit-under-miss, while a
	 * fill is outstanding (INJECT_RELOAD): port 2 only READS the arrays and the
	 * fill is the only writer, so the two never collide.  A request to the set
	 * being filled is treated as a miss (r_fill_conflict2). */
	if(r_got_req2 && ((r_state == ACTIVE) || (r_state == INJECT_RELOAD)))
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
		    n_core_mem_rsp.lsu_hold = r_req2.lsu_hold;
		    n_core_mem_rsp.lsu_idx = r_req2.lsu_idx;
		    n_core_mem_rsp.restart_id = r_req2.restart_id;
		    if(r_req2.commit)
		      begin
			 /* retired plain store: queue its write (fires at the MQ head) */
			 t_push_miss = 1'b1;
		      end
		    else if(drain_ds_complete)
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
		    else if(r_req2.is_store && r_req2.lsu_hold && !w_is_chop2)
		      begin
			 /* plain store address pass: record PA/mask in the store buffer and
			  * ack (the ROB entry completes); the LSU holds the store until it
			  * retires, then commits it */
			 t_sb_wr = 1'b1;
			 n_core_mem_rsp.dst_valid = 1'b0;
			 if(r_req2.op == MEM_SC || r_req2.op == MEM_SCD)
			   begin
			      /* SC/SCD: answer the reservation (link) now; the commit writes
			       * only if it held (sc_ok). Do NOT require a cache hit, else a
			       * conflict-displaced line livelocks the SC (rv64core MEM_SCD). */
			      n_core_mem_rsp.data = {{(`M_WIDTH-1){1'b0}}, w_match_link2};
			      n_core_mem_rsp.dst_valid = r_req2.dst_valid;
			   end
			 n_core_mem_rsp.tlb_hit = w_tlb_hit;
			 n_core_mem_rsp.tlb_index = w_tlb_index;
			 n_core_mem_rsp.bad_addr = r_req2.bad_addr;
			 n_core_mem_rsp_valid = 1'b1;
		      end
		    else if(r_req2.lsu_hold && !r_req2.is_store && !t_remapped_req2.cached && !w_req2_nonspec)
		      begin
			 /* uncached simple load, still speculative: back to the LSU */
			 t_pt2 = "U";
			 n_core_mem_blk_valid = 1'b1;
			 n_core_mem_rsp.blk = BLK_UNCACHEABLE;
		      end
		    else if(t_sb_blk)
		      begin
			 n_core_mem_blk_valid = 1'b1;
			 n_core_mem_rsp.blk = t_sb_code;
			 n_core_mem_rsp.blk_st = t_sb_blk_st;
		      end
		    else if(t_sb_fwd && r_req2.lsu_hold)
		      begin
			 /* store->load forward (t_data2 already merged) */
			 t_pt2 = "V";
			 n_core_mem_rsp.data = t_rsp_data2[`M_WIDTH-1:0];
			 n_core_mem_rsp.dst_valid = r_req2.dst_valid;
			 n_core_mem_rsp.bad_addr = r_req2.bad_addr;
			 n_core_mem_rsp.tlb_hit = w_tlb_hit;
			 n_core_mem_rsp.tlb_index = w_tlb_index;
			 n_core_mem_rsp_valid = 1'b1;
		      end
		    else if(w_is_chop2)
		      begin
			 /* CACHE hit op (non-speculative, see w_chop_req): queue it; it
			  * fires at the MQ head and answers when both beats are done */
			 t_push_miss = 1'b1;
		      end
		    /* L1D_PORT2_ALWAYS_MISS: force port-2 ops off the FAST-HIT reply path
		     * and down the miss queue instead.  Diagnostic for whether the
		     * port-2 fast-hit reply is the source of the stale-register
		     * load-use failure captured 2026-08-29/30.
		     * Deliberately gates only the REPLY, not t_port2_hit_cache itself,
		     * so hit counters and r_missed[] stay truthful.  The else branch
		     * below already services present-but-busy lines via the MQ, so this
		     * reuses an exercised path rather than a new one -- and unlike
		     * L1D_ONE_MEMOP it never REFUSES a request, which is what wedged
		     * retirement on silicon in the 2026-07-26 attempt. */
		    /* An access the TLB maps UNCACHED (t_remapped_req2.cached, the page's C
		     * field) must not fast-hit: w_uncachable_req only saw the segment's
		     * cacheability, and user segments (kuseg/xkuseg) are "cached" there.
		     * It falls to the miss queue, where it waits for the ROB head. */
		    else if(t_port2_hit_cache && !r_hit_busy_addr2 && !w_p2_force_miss && !r_fill_conflict2 && t_remapped_req2.cached)
		      begin
`ifdef P2_FASTHIT_PROBE
			 $display("[P2FH] port2 fast-hit reply");
`endif
`ifdef VERBOSE_L1D
			 $display("cycle %d port2 hit for uuid %d, addr %x, data %x", 
				  r_cycle, r_req2.uuid, r_req2.addr, t_rsp_data2);
`endif
			 t_pt2 = "H";
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
			 if(t_direct_fill_ok)
			   begin
			      /* same request the port-1 clean-miss arm would make, one pass
			       * earlier; r_req becomes the fill's owner (w_fill_bypass) */
			      t_direct_fill = 1'b1;
			      n_req = t_remapped_req2;
			      n_reload_issue = 1'b1;
			      t_miss_idx = t_remapped_req2.addr[IDX_STOP-1:IDX_START];
			      t_miss_addr = t_remapped_req2.addr;
			      n_inhibit_write = 1'b0;
			      n_lock_cache = 1'b0;
			      n_mem_req_cacheable = 1'b1;
			      n_mem_req_mask = 16'hffff;
			      n_mem_req_addr = {t_remapped_req2.addr[`PA_WIDTH-1:`LG_L1D_CL_LEN], {`LG_L1D_CL_LEN{1'b0}}};
			      n_mem_req_opcode = MEM_LW;
			      n_mem_req_valid = 1'b1;
			      n_state = INJECT_RELOAD;
			   end
			 else
			   begin
			      t_push_miss = 1'b1;
			   end
			 if(t_port2_hit_cache)
			   begin
			      n_cache_hits = r_cache_hits + 'd1;
			   end
			 t_pt2 = r_req2.is_store ? 8'd0 : "M";
			 /* cacheable simple load: hand it back to the LSU with a block
			  * code; the MQ entry only fetches the line and sends the wakeup */
			 if(r_req2.lsu_hold && t_remapped_req2.cached)
			   begin
			      n_core_mem_blk_valid = 1'b1;
			      n_core_mem_rsp.blk = (t_port2_hit_cache && !r_fill_conflict2) ? BLK_ST_CONFLICT : BLK_MISS;
			   end
		      end
		 end // if (r_got_req2)

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
			      n_mem_req_addr = {r_tag_out[N_TAG_BITS-1:LG_ALIAS_BITS],r_cache_idx,{`LG_L1D_CL_LEN{1'b0}}};
			      n_mem_req_opcode = MEM_WB;
			      n_mem_req_store_data = t_data;
			      n_mem_req_cacheable = 1'b1;
			      n_mem_req_mask = 16'hffff;
			      n_mem_req_valid = 1'b1;
			      n_inhibit_write = 1'b1;
			      n_chop_wait = 1'b1;
			      n_state = FLUSH_CL_WAIT;
			   end
			 else
			   begin
			      /* INV variants AND CHWB (clean hit or L1D miss): drop any L1D copy,
			       * CHWB was excluded here and fell into arms that issued NO memory
			       * request -- on a MISS, literally nothing -- so the op never
			       * completed and the core wedged with it at the ROB head (silicon:
			       * IRIX hung in cacheops_refill_1's `cache 0x19` loop).  CHINV and
			       * CHWBINV take this arm for every non-dirty-hit case and work
			       * (tests/cache/test_chop_ops.S), so CHWB now follows the identical
			       * flow -- which is what the WB arm above already claims: "CHWB is
			       * conservatively treated as WB-Invalidate".
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
		    else if((r_req.cached == 1'b0) && !r_req.is_store && drain_ds_complete && dead_rob_mask[r_req.rob_ptr])
		      begin
			 /* dead uncached load (younger than a mispredict/fault, parked in the
			  * queue waiting for a ROB head it will never reach): complete it with
			  * no memory access so the inflight counts drain */
			 t_ucld_dead_drop = 1'b1;
			 n_core_mem_rsp.dst_valid = r_req.dst_valid;
			 n_core_mem_rsp.bad_addr = r_req.bad_addr;
			 n_core_mem_rsp_valid = 1'b1;
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
				   n_mem_req_addr = {r_tag_out[N_TAG_BITS-1:LG_ALIAS_BITS], r_cache_idx, {`LG_L1D_CL_LEN{1'b0}}};
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
			 
			 //$display("uncachable req at pc %x to addr %x, is store %b, data %x, mask %b, rob ptr %x\n", 
			 //r_req.pc, {r_req.addr[31:4], 4'd0}, r_req.is_store, r_req.data,
			 //t_mem_req_mask, r_req.rob_ptr);
			 
			   end
		      end // if (r_req.cached == 1'b0)
		    else if(r_valid_out && (r_tag_out == r_cache_tag))
		      begin /* valid cacheline - hit in cache */
			 if(r_req.commit)
			   begin
			      /* plain store written: free its LSU slot */
			      n_core_mem_st_done_valid = 1'b1;
			   end
			 else if(r_req.is_store)
			   begin
			      /* unreachable: every store but a CACHE op (own arm) is a commit */
			   end
			 else
			   begin
			      t_pt1 = "P";
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
			      n_mem_req_addr = {r_tag_out[N_TAG_BITS-1:LG_ALIAS_BITS],r_cache_idx,{`LG_L1D_CL_LEN{1'b0}}};
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
				 n_mem_req_addr = {r_tag_out[N_TAG_BITS-1:LG_ALIAS_BITS],r_cache_idx,{`LG_L1D_CL_LEN{1'b0}}};
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




	       
	     if(!mem_q_empty && !t_got_miss && !r_lock_cache && !t_prb_pend)
	       begin
		  if(!t_mh_block)
		    begin
		       if(!t_mem_head.commit && (t_mem_head.restart_id != restart_color))
			 begin
			    /* queued op of a flushed era: drop it (a dead store never
			     * writes, a dead uncached load never touches the device).
			     * (store-buffer and LSU state belong to the new era) */
			    t_pop_mq = 1'b1;
			    t_mq_stale_drop = 1'b1;
			    t_mq_stale_owed = !t_mem_head.is_store;
			 end
		       else if(t_mem_head.commit)
			 begin
			    /* retired plain store: data is in the entry, no graduation wait */
			    t_pop_mq = 1'b1;
			    n_req = t_mem_head;
			    t_cache_idx = t_mem_head.addr[IDX_STOP-1:IDX_START];
			    t_cache_tag = t_mem_head.addr[`PA_WIDTH-1:TAG_LSB];
			    t_addr = t_mem_head.addr;
			    t_got_req = 1'b1;
			    n_is_retry = 1'b1;
			    n_last_wr = 1'b1;
			 end
		       else if(w_is_chop_head)
			 begin
			    /* CACHE hit-op at MQ head: it was admitted non-speculative,
			     * so fire at once.  Re-fire through port 1 as a READ pass;
			     * the retry arm performs the line op on the TLB-translated PA
			     * the MQ entry carries. */
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
		       else if(t_mem_head.cached || w_mq_head_nonspec)
			 begin
			    /* an uncached load (TLB C bit, carried in the queued req) is
			     * released only when non-speculative, like w_uncachable_req at
			     * admission; a dead one reaching drain is answered without the
			     * device access by the port-1 uncached arm */
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

	       
	       if(t_prb_pend)
		 begin
		    /* stage B: a probe is waiting for the port-1/port-2 pipes to drain */
		 end
	       else if(core_mem_req_valid &&
		  /* port2 is a 2-stage pipe: the request is ACKed here in ACTIVE but
		   * PROCESSED next cycle under `ACTIVE:`.  If this cycle's logic already
		   * decided to leave ACTIVE (a chop's double beat -> CHOP_BEAT2_RD, a
		   * flush -> FLUSH_CL_WAIT, ...), the accepted request lands in a state
		   * with no port2 handling and is SILENTLY DROPPED -- no ack, no MQ push,
		   * no fault.  The op then never completes and, being older, blocks retire
		   * forever (IRIX wedged in cacheops_refill_1's `cache 0x19` loop).  Don't
		   * take it: core_mem_req_valid stays asserted and we accept once back in
		   * ACTIVE. */
		  (n_state == ACTIVE) &&
		  !t_got_miss && 
		  !t_got_rd_retry &&
		  !t_cm_block_stall &&
		  t_p2_ok
		  )
	       begin
		  t_p2_accept = 1'b1;
	       end // if (core_mem_req_valid &&...
	       else if(r_flush_req && mem_q_empty && !lsu_sb.retired_pending && !(r_got_req && (r_last_wr | w_is_chop_r)))
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
	       else if(r_flush_cl_req && mem_q_empty && !lsu_sb.retired_pending && !(r_got_req && (r_last_wr | w_is_chop_r)))   /* a chop retry transitions n_state too */
		 begin
`ifdef VERILATOR
		    if(!mem_q_empty) $stop();
		    if(r_got_req && r_last_wr) $stop();
`endif
		    t_cache_idx = flush_cl_addr[IDX_STOP-1:IDX_START];
		    //$display("flush addr %x, maps to cl %d at cycle", flush_cl_addr, t_cache_idx, r_cycle);
		    n_flush_cl_req = 1'b0;
		    n_cl_is_dma = 1'b0;
		    n_state = FLUSH_CL;
		 end
	       else if(r_flush_pg_req && mem_q_empty && !(r_got_req && (r_last_wr | w_is_chop_r)))
		 begin
		    t_cache_idx = w_pg_line0[IDX_STOP-1:IDX_START];
		    n_flush_pg_req = 1'b0;
		    n_pg_off = 'd0;
		    n_state = FLUSH_PG;
		 end
	       else if(r_dma_inval_req && mem_q_empty && !(r_got_req && (r_last_wr | w_is_chop_r)))
		 begin
		    /* DMA-completion invalidate of one line.  Lower priority than the
		     * CPU's CACHE op above, and only when the mem pipe is quiet -- the
		     * same guard the CPU path uses. */
		    t_cache_idx = dma_inval_addr[IDX_STOP-1:IDX_START];
		    n_dma_inval_req = 1'b0;
		    n_cl_is_dma = 1'b1;
		    n_state = FLUSH_CL;
		 end
	    end // case: ACTIVE
	  PROBE_CHK:
	    begin
	       /* r_*_out are the probed line (read in the entry cycle; r_cache_idx is its
		* index, so t_mark_invalid writes valid/dirty there) */
	       t_prb_hit = r_valid_out && (r_tag_out == r_prb_tag);
	       if(t_prb_hit)
		 begin
		    t_mark_invalid = 1'b1;
		 end
	       n_prb_ack = 1'b1;
	       n_prb_dirty = t_prb_hit && r_dirty_out;
	       n_prb_data = r_array_out;
	       n_prb_seen = 1'b1;
	       t_cache_idx = r_prb_save;
	       n_state = r_prb_ret;
	    end
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
		     if(w_fill_bypass)
		       begin
			  t_pt1 = "P";
			  if(r_got_req2)
			    begin
			       n_fill_rsp_pend = 1'b1;
			    end
			  else
			    begin
			       n_core_mem_rsp = t_fill_rsp;
			       n_core_mem_rsp_valid = 1'b1;
			    end
			  n_state = ACTIVE;
		       end
		     else
		       begin
			  n_state = r_reload_issue ? HANDLE_RELOAD : ACTIVE;
		       end
		     n_inhibit_write = 1'b0;
		     n_reload_issue = 1'b0;
		  end
		else if(t_p2_ok && !core_mem_req.is_atomic && !t_prb_pend)
		  begin
		     /* hit-under-miss: keep taking port-2 requests while the fill is out */
		     t_p2_accept = 1'b1;
		  end
	    end
	  INJECT_UNCACHE_STORE:
	    begin
	       //$display("cycle %d, waiting for rsp %b", r_cycle, mem_rsp_valid);
	       if(mem_rsp_valid)
		 begin
		    //$display("rsp complete, going to active");
		    n_state = ACTIVE;
		    n_core_mem_st_done_valid = r_req.commit;
		 end
	    end
	  INJECT_UNCACHE_LOAD:
	    begin
	       if(mem_rsp_valid)
		 begin
		    //$display("data returns for uncached load");
		    t_pt1 = "P";
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
	       if(w_cl_inval)
		 begin
		    /* CACHE D-Hit-Invalidate (DMA-in): drop the line WITHOUT writeback,
		     * but only on a real hit (tag match) so we never discard a
		     * different dirty line that happens to alias this index. Then tell
		     * L2 to drop its copy too (caches are non-inclusive).
		     * w_cl_* is the arbitrated address/op: CPU CACHE-op or the
		     * DMA-completion invalidate (see r_cl_is_dma). */
		    if(r_valid_out && (r_tag_out == w_cl_addr[`PA_WIDTH-1:TAG_LSB]))
		      t_mark_invalid = 1'b1;
		    n_mem_req_addr = {w_cl_addr[`PA_WIDTH-1:`LG_L1D_CL_LEN],{`LG_L1D_CL_LEN{1'b0}}};
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
		     * coherence bug).  Invalidate the line too: Index_WB_Inv_D must
		     * not leave it VALID+DIRTY, or a later DMA-in to that line is
		     * shadowed by the stale copy (read hits it, eviction writes it
		     * over the DMA data) -- ~/code/murphi/r9999_caches.m. */
		    t_mark_invalid = 1'b1;
		    n_mem_req_addr = {r_tag_out[N_TAG_BITS-1:LG_ALIAS_BITS],r_cache_idx,{`LG_L1D_CL_LEN{1'b0}}};
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
		     if(r_cl_is_dma)
		       begin
			  /* DMA-completion invalidate: exactly ONE 16B line -- the
			   * SoC-side walker steps the range itself, so do NOT run the
			   * 32B-stride second beat the Index CACHE ops need. */
			  n_dma_inval_ack = 1'b1;
			  n_cl_is_dma = 1'b0;
			  n_state = ACTIVE;
		       end
		     else
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
			  /* beat 1 done -> both 16B lines covered: the chop is done */
			  n_core_mem_rsp_valid = 1'b1;
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
		    n_mem_req_addr = {r_tag_out[N_TAG_BITS-1:LG_ALIAS_BITS],r_cache_idx,{`LG_L1D_CL_LEN{1'b0}}};
		    n_mem_req_opcode = MEM_WB;
		    n_mem_req_store_data = t_data;
		    n_mem_req_cacheable = 1'b1;
		    n_mem_req_mask = 16'hffff;
		    n_mem_req_valid = 1'b1;
		    n_inhibit_write = 1'b1;
		    n_chop_wait = 1'b1;
		    n_state = FLUSH_CL_WAIT;
		 end
	       else
		 begin
		    /* beat 2: same as beat 0 -- CHWB follows the INV flow rather than
		     * an arm that issues nothing. */
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
	    end
	  FLUSH_PG:
	    begin
	       t_cache_idx = r_cache_idx;
	       n_mem_req_addr = w_pg_line;
	       n_mem_req_cacheable = 1'b1;
	       n_mem_req_mask = 16'hffff;
	       n_mem_req_valid = 1'b1;
	       n_state = FLUSH_PG_WAIT;
	       if(w_pg_hit)
		 begin
		    t_mark_invalid = 1'b1;
		 end
	       if(!flush_cl_inval & w_pg_hit & r_dirty_out)
		 begin
		    n_mem_req_opcode = MEM_WB;
		    n_mem_req_store_data = t_data;
		    n_inhibit_write = 1'b1;
		 end
	       else
		 begin
		    n_mem_req_opcode = flush_cl_inval ? MEM_PGDROP : MEM_INVL;
		 end
	       if(flush_cl_inval & w_pg_hit & r_dirty_out & (r_pg_dirty_cnt != 16'hffff))
		 begin
		    n_pg_dirty_cnt = r_pg_dirty_cnt + 16'd1;
		 end
	    end
	  FLUSH_PG_WAIT:
	    begin
	       t_cache_idx = r_cache_idx;
	       if(mem_rsp_valid)
		 begin
		    n_inhibit_write = 1'b0;
		    if(flush_cl_inval & mem_rsp_load_data[0] & (n_pg_dirty_cnt != 16'hffff))
		      begin
			 n_pg_dirty_cnt = n_pg_dirty_cnt + 16'd1;
		      end
		    if(r_pg_off == {LG_PG_LINES{1'b1}})
		      begin
			 n_flush_complete = 1'b1;
			 n_state = ACTIVE;
		      end
		    else
		      begin
			 n_pg_off = r_pg_off + 'd1;
			 t_cache_idx = w_pg_line_nxt[IDX_STOP-1:IDX_START];
			 n_state = FLUSH_PG;
		      end
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
		    n_mem_req_addr = {r_tag_out[N_TAG_BITS-1:LG_ALIAS_BITS],r_cache_idx,{`LG_L1D_CL_LEN{1'b0}}};
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
	/* stage B: take a pending probe when neither port pipe holds a request, no response
	 * is arriving, and the current state is ACTIVE or only waiting on the L2 (and is not
	 * leaving this cycle).  The read this state wanted (t_cache_idx) is saved and
	 * re-issued when the probe is done, so the state resumes with its RAM outputs. */
	if(t_prb_pend && !r_got_req && !r_got_req2 && !mem_rsp_valid &&
	   (n_state == r_state) && t_prb_ok_state)
	  begin
	     n_prb_save = t_cache_idx;
	     n_prb_ret = r_state;
	     n_prb_tag = probe_addr[`PA_WIDTH-1:TAG_LSB];
	     t_cache_idx = probe_addr[IDX_STOP-1:IDX_START];
	     n_state = PROBE_CHK;
	  end
	/* a request from a flushed era (rv64core restart_id): ack and drop it */
	if(t_req_stale && ((r_state == ACTIVE) || (r_state == INJECT_RELOAD)))
	  begin
	     core_mem_req_ack = 1'b1;
	  end
	if(t_p2_accept)
	  begin
		  //use 2nd read port
		  t_cache_idx2 = core_mem_req.addr[IDX_STOP-1:IDX_START];
		  t_cache_tag2 = core_mem_req.addr[`PA_WIDTH-1:TAG_LSB];
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
		  
		  n_last_wr2 = core_mem_req.is_store && !core_mem_req.commit;
		  n_last_rd2 = !core_mem_req.is_store;
		  
		  n_cache_accesses =  r_cache_accesses + 'd1;
	  end
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
	     else if(r_last_wr2 && (r_cache_idx2 == core_mem_req.addr[IDX_STOP-1:IDX_START]) && !core_mem_req.is_store) 
	       begin
		  //$display("previous write to the same set prevents ack at cycle %d", r_cycle);
		  t_stall_reason = 'd5;
	       end
	     else if(t_cm_block_stall) 
	       begin
		  //$display("retried store prevents ack at cycle %d", r_cycle);
		  t_stall_reason = 'd6;
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

`ifdef L1D_STATE_PROFILE
   /* WHERE DO THE CYCLES GO -- per-state occupancy of the L1D FSM.
    *
    * membw showed cyc/elem = 48.5 + 2.49*mem_latency: ~2.5 SERIALIZED memory round
    * trips per element plus ~48 cycles of latency-INDEPENDENT overhead.  Occupancy
    * counters localise both without per-load tagging, which r9999 can do because it
    * is blocking -- exactly one miss is ever in flight.
    *
    * INJECT_RELOAD is split by r_reload_issue: a DIRTY miss issues MEM_SW and waits
    * here for the writeback, THEN re-enters to wait for the fill.  Two sequential
    * trips through one state is the serialization we are trying to price, so lumping
    * them would hide the very thing being measured. */
   integer r_p_active, r_p_inject_wb, r_p_inject_fill, r_p_wait_inject;
   integer r_p_handle, r_p_uncache, r_p_flush, r_p_other, r_p_total;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_p_active <= 0; r_p_inject_wb <= 0; r_p_inject_fill <= 0;
	     r_p_wait_inject <= 0; r_p_handle <= 0; r_p_uncache <= 0;
	     r_p_flush <= 0; r_p_other <= 0; r_p_total <= 0;
	  end
	else
	  begin
	     r_p_total <= r_p_total + 1;
	     case(r_state)
	       ACTIVE:
		 begin
		    r_p_active <= r_p_active + 1;
		 end
	       INJECT_RELOAD:
		 begin
		    /* r_reload_issue set => HANDLE_RELOAD follows, i.e. a line is being
		     * INSTALLED: this wait is the FILL leg.  Clear => the response
		     * completes a writeback-only trip and we return straight to ACTIVE.
		     * (Named the other way round on first cut -- the transition
		     * `n_state = r_reload_issue ? HANDLE_RELOAD : ACTIVE` is what settles
		     * it.) */
		    if(r_reload_issue)
		      begin
			 r_p_inject_fill <= r_p_inject_fill + 1;
		      end
		    else
		      begin
			 r_p_inject_wb <= r_p_inject_wb + 1;
		      end
		 end
	       WAIT_INJECT_RELOAD:
		 begin
		    r_p_wait_inject <= r_p_wait_inject + 1;
		 end
	       HANDLE_RELOAD:
		 begin
		    r_p_handle <= r_p_handle + 1;
		 end
	       INJECT_UNCACHE_STORE, INJECT_UNCACHE_LOAD, UNCACHE_WB:
		 begin
		    r_p_uncache <= r_p_uncache + 1;
		 end
	       FLUSH_CACHE, FLUSH_CACHE_WAIT, FLUSH_CACHE_LAST_WAIT, FLUSH_CL, FLUSH_CL_WAIT:
		 begin
		    r_p_flush <= r_p_flush + 1;
		 end
	       default:
		 begin
		    r_p_other <= r_p_other + 1;
		 end
	     endcase // case (r_state)
	     if((r_p_total % `L1D_PROFILE_PERIOD) == (`L1D_PROFILE_PERIOD-1))
	       begin
		  $display("[l1dprof] total=%0d active=%0d inject_wb=%0d inject_fill=%0d wait_inject=%0d handle=%0d uncache=%0d flush=%0d other=%0d",
			   r_p_total, r_p_active, r_p_inject_wb, r_p_inject_fill,
			   r_p_wait_inject, r_p_handle, r_p_uncache, r_p_flush, r_p_other);
	       end
	  end
     end // always_ff
`endif


`ifdef SPEC_FILL_CHK
   /* SPECULATIVE-FILL DETECTOR (stage 1: UNGATED).
    *
    * IRIX invalidates DMA buffers correctly -- measured in interp_mips: op 0x15
    * (primary-D Hit-WB-Invalidate) on a 16B stride, exactly the L1D line size, on
    * kseg0 addresses.  Coverage is complete.  Yet DMA'd blocks read back stale, so
    * something REFILLS the line after the invalidate.
    *
    * r9999 is OOO and loads are NOT gated on graduation (stores are: see the
    * r_graduated test at the mem-queue pop).  So a load on a mispredicted path can
    * miss and refill a line from DRAM with pre-DMA contents.  Software has already
    * done its invalidate and has no reason to repeat it.  An in-order R4400 cannot
    * do this, which is why the Indy docs can specify non-coherent DMA and be right.
    *
    * Stage 1 counts EVERY fill whose requesting ROB entry is later squashed, with no
    * gating on what was filled.  Later stages narrow it (fill into a line a recent
    * CACHE op invalidated, then into a live DMA buffer).
    *
    * A bit is set when a cacheable fill installs for r_req's ROB entry, and cleared
    * on that entry going dead (counted) or retiring normally (not counted).  The
    * clear-on-retire matters: ROB slots are reused, so a stale bit would attribute a
    * later squash to a fill that had already committed. */
   /* STAGE 2 GATE: was the filled line one that a CACHE op just invalidated?
    *
    * IRIX's DMA invalidate is provably complete (interp_mips: op 0x15, 16B stride ==
    * the L1D line size, kseg0), so a stale DMA'd block means something REFILLED a
    * line after software cleaned it.  Counting all squashed-load fills is too broad
    * (909/boot, mostly harmless lines); what matters is a squashed load refilling a
    * line that was just invalidated -- that is the DMA-buffer signature.
    *
    * 256-entry direct-mapped table of the most recently CACHE-invalidated line
    * address, indexed by PA[11:4].  Approximate by construction (a later invalidate
    * to the same index evicts an earlier one), so the count is a LOWER bound. */
   localparam CINV_TAB_SZ = 256;
   logic [`PA_WIDTH-1:4] r_cinv_pa [CINV_TAB_SZ-1:0];
   logic [CINV_TAB_SZ-1:0] r_cinv_vld;

   /* Gate on ANY invalidate, not just the CACHE-hit-op path: cinv_ops read 0 when
    * this required (t_mark_invalid & w_is_chop_r), because the chop arms only set
    * t_mark_invalid on a TAG HIT and IRIX also invalidates via the FLUSH_CL funnel.
    * Recording every invalidate is strictly more inclusive and needs no assumption
    * about which path software used.  The line being invalidated is the one
    * currently indexed, so reconstruct its PA the same way the writeback arm does. */
   wire [`PA_WIDTH-1:0] w_cinv_pa_full =
	{r_tag_out[N_TAG_BITS-1:LG_ALIAS_BITS], r_cache_idx, {`LG_L1D_CL_LEN{1'b0}}};
   wire [7:0] w_cinv_wr_idx = w_cinv_pa_full[11:4];
   wire       w_cinv_wr_en  = t_mark_invalid;

   wire [`PA_WIDTH-1:4] w_fill_pa  = r_mem_req_addr[`PA_WIDTH-1:4];
   wire [7:0] 	        w_fill_idx8 = r_mem_req_addr[11:4];
   wire w_fill_hits_cinv = r_cinv_vld[w_fill_idx8] &
			   (r_cinv_pa[w_fill_idx8] == w_fill_pa);

   /* POISONED-LINE TRACKING.
    * A fill is only known to be speculative at the squash, so remember which SET each
    * in-flight fill installed into; on restart_valid every still-tracked fill belonged
    * to an instruction that never committed, so mark its set POISONED.  The poison is
    * cleared when software invalidates that line again or a committed fill replaces it.
    * Consumption = an architectural LOAD hitting a poisoned line: that is the read of
    * data from a region software had already invalidated. */
   logic [`LG_L1D_NUM_SETS-1:0] r_fill_set [N_ROB_ENTRIES-1:0];
   logic [L1D_NUM_SETS-1:0]     r_poison;
   /* Poison must be qualified by TAG: the bit alone is per-SET, so any later load
    * aliasing to that set would count as consumption even with a different line. */
   logic [N_TAG_BITS-1:0]       r_poison_tag [L1D_NUM_SETS-1:0];
   logic [N_TAG_BITS-1:0]       r_fill_tag [N_ROB_ENTRIES-1:0];
   logic [31:0] 		r_n_poison_set;
   logic [31:0] 		r_n_poison_hit;   /* stale data actually consumed */
   logic [N_ROB_ENTRIES-1:0] r_fill_cinv;   /* fill landed on a just-invalidated line */
   logic [31:0] r_n_spec_cinv;              /* AND squashed => the smoking gun */
   logic [31:0] r_n_cinv_ops;
   logic [N_ROB_ENTRIES-1:0] r_fill_rob;
   logic [31:0] 	     r_n_spec_fill;   /* fills whose load was squashed */
   logic [31:0] 	     r_n_fill_total;  /* all cacheable fills */

   wire [N_ROB_ENTRIES-1:0] w_fill_set  = w_cacheable_mem_rsp_valid ?
			    ({{(N_ROB_ENTRIES-1){1'b0}}, 1'b1} << r_req.rob_ptr) :
			    {N_ROB_ENTRIES{1'b0}};
   wire [N_ROB_ENTRIES-1:0] w_ret_clr =
	(retired_rob_ptr_valid ?
	 ({{(N_ROB_ENTRIES-1){1'b0}}, 1'b1} << retired_rob_ptr) : {N_ROB_ENTRIES{1'b0}}) |
	(retired_rob_ptr_two_valid ?
	 ({{(N_ROB_ENTRIES-1){1'b0}}, 1'b1} << retired_rob_ptr_two) : {N_ROB_ENTRIES{1'b0}});

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_fill_rob <= {N_ROB_ENTRIES{1'b0}};
	     r_n_spec_fill <= 32'd0;
	     r_n_fill_total <= 32'd0;
	     r_fill_cinv <= {N_ROB_ENTRIES{1'b0}};
	     r_cinv_vld <= {CINV_TAB_SZ{1'b0}};
	     r_poison <= {L1D_NUM_SETS{1'b0}};
	     r_n_poison_set <= 32'd0;
	     r_n_poison_hit <= 32'd0;
	     r_n_spec_cinv <= 32'd0;
	     r_n_cinv_ops <= 32'd0;
	  end
	else
	  begin
	     /* dead_rob_mask is NOT "squashed" -- core.sv sets it on ALLOCATION and
	      * clears it on RETIRE, i.e. it means "in flight".  Keying on it counted
	      * essentially every fill.  A squash is restart_valid, which drives
	      * t_clr_rob and wipes the whole ROB, so every fill still tracked at that
	      * moment belonged to an instruction that never committed. */
	     if(w_cinv_wr_en)
	       begin
		  r_cinv_pa[w_cinv_wr_idx] <= w_cinv_pa_full[`PA_WIDTH-1:4];
		  r_cinv_vld[w_cinv_wr_idx] <= 1'b1;
		  r_n_cinv_ops <= r_n_cinv_ops + 32'd1;
	       end
	     if(w_cacheable_mem_rsp_valid)
	       begin
		  r_fill_set[r_req.rob_ptr] <= r_cache_idx;
		  r_fill_tag[r_req.rob_ptr] <= r_cache_tag;
	       end
	     /* consumption: an architectural load hits a line a squashed load resurrected */
	     if(t_hit_cache & ~r_req.is_store & r_poison[r_cache_idx] &
		(r_poison_tag[r_cache_idx] == r_cache_tag))
	       begin
		  r_n_poison_hit <= r_n_poison_hit + 32'd1;
		  if(r_n_poison_hit < 32'd64)   /* cap: the count is the signal, not the spam */
		    begin
		       $display("[poisonhit] cyc=%0d set=%0d rob=%0d addr=%x",
				r_cycle, r_cache_idx, r_req.rob_ptr, r_req.addr);
		    end
	       end
	     /* software invalidating the line clears the poison */
	     if(t_mark_invalid)
	       begin
		  r_poison[r_cache_idx] <= 1'b0;
	       end
	     else if(restart_valid)
	       begin
		  for(integer pi = 0; pi < N_ROB_ENTRIES; pi = pi + 1)
		    begin
		       if(r_fill_rob[pi])
			 begin
			    r_poison[r_fill_set[pi]] <= 1'b1;
			    r_poison_tag[r_fill_set[pi]] <= r_fill_tag[pi];
			 end
		    end
	       end
	     if(restart_valid)
	       begin
		  r_n_poison_set <= r_n_poison_set + $countones(r_fill_rob);
		  r_fill_rob <= w_fill_set;
		  r_fill_cinv <= (w_cacheable_mem_rsp_valid & w_fill_hits_cinv) ?
				 w_fill_set : {N_ROB_ENTRIES{1'b0}};
		  r_n_spec_fill <= r_n_spec_fill + $countones(r_fill_rob);
		  r_n_spec_cinv <= r_n_spec_cinv + $countones(r_fill_rob & r_fill_cinv);
	       end
	     else
	       begin
		  r_fill_rob <= (r_fill_rob & ~w_ret_clr) | w_fill_set;
		  r_fill_cinv <= (r_fill_cinv & ~w_ret_clr) |
				 ((w_cacheable_mem_rsp_valid & w_fill_hits_cinv) ?
				  w_fill_set : {N_ROB_ENTRIES{1'b0}});
	       end
	     if(w_cacheable_mem_rsp_valid)
	       begin
		  r_n_fill_total <= r_n_fill_total + 32'd1;
	       end
	     if(r_cycle[22:0] == 23'h7fffff)
	       begin
		  $display("[specfill] cyc=%0d spec_fills=%0d SPEC_ON_INVALIDATED=%0d POISON_CONSUMED=%0d cinv_ops=%0d total_fills=%0d",
			   r_cycle, r_n_spec_fill, r_n_spec_cinv, r_n_poison_hit, r_n_cinv_ops, r_n_fill_total);
	       end
	  end
     end // always_ff
`endif

endmodule // l1d

