`include "machine.vh"
`ifndef INCL_PERIOD
 `define INCL_PERIOD 20000000
`endif

module l2(clk,
	  reset,
	  state,
	  rsp_state,
	  l1i_flush_req,
	  l1d_flush_req,

	  l1i_flush_complete,
	  l1d_flush_complete,
	  
	  flush_complete,

	  //l1 -> l2
	  l1_mem_req_valid,
	  l1_mem_req_ack,
	  l1_mem_req_addr,
	  l1_mem_req_cacheable,
	  l1_mem_req_from_l1i,
	  l1_mem_req_mask,
	  l1_mem_req_store_data,
	  l1_mem_req_opcode,

	  //l2 -> l1
	  l1_mem_rsp_valid,
	  l1_mem_load_data,

	  //l2 -> mem
	  mem_req_ack,
	  mem_req_valid, 
	  mem_req_addr, 
	  mem_req_store_data, 
	  mem_req_opcode,
	  mem_req_mask,
	  
	  //mem -> l2
	  mem_rsp_valid,
	  mem_rsp_bad,
	  mem_rsp_load_data,

	  cache_hits,
	  cache_accesses,

	  // DMA-coherence snoop (from henry's snoop FIFO): invalidate one L2 line per request.
	  snoop_req_valid,
	  snoop_req_addr,
	  snoop_req_ack,
	  // INCLUSIVE-L2 back-invalidate to the L1s (design C: dirty data rides the ack)
	  backinv_addr,
	  backinv_stall,
	  backinv_d_req,
	  backinv_d_ack,
	  backinv_d_dirty,
	  backinv_d_data,
	  backinv_i_req,
	  backinv_i_ack
	  );

   input logic clk;
   input logic reset;
   output logic [3:0] state;
   output logic [3:0] rsp_state;
   
   input logic l1i_flush_req;
   input logic l1d_flush_req;
   input logic l1i_flush_complete;
   input logic l1d_flush_complete;
   
   output logic flush_complete;

   input logic 	l1_mem_req_valid;
   output logic l1_mem_req_ack;
   input logic [`PA_WIDTH-1:0] l1_mem_req_addr;
   /* INCLUSIVE L2: which L1 this request came from, so the L2 can record WHICH primary
    * cache it handed a copy to and later back-invalidate only that one.  Same role as
    * the R10000 SCTag PIdx field ("locate subset lines in the primary caches"), except
    * our 4KB direct-mapped L1s need no index bits -- only the D-vs-I selector. */
   input logic 	l1_mem_req_from_l1i;
   input logic	      l1_mem_req_cacheable;
`ifdef ENABLE_L2_NOCACHE
   /* EXPERIMENT: entirely disable the L2 as a cache.  Route cacheable DATA ops
    * (loads/stores/line-fills, opcode < MEM_INVL=24) down the uncached
    * pass-through-to-DRAM path so the L2 NEVER fills a line -> holds nothing ->
    * no stale reservoir AND no inclusivity vs the L1D.  Keep CACHE-management ops
    * (MEM_INVL=24, MEM_WB=26, ... >= 24) on the normal cacheable path so their
    * handlers still run (they find an empty L2 and just ack / write through). */
   wire w_l2_cacheable = l1_mem_req_cacheable & (l1_mem_req_opcode >= 5'd24);
`else
   wire w_l2_cacheable = l1_mem_req_cacheable;
`endif
   input logic [15:0] l1_mem_req_mask;
   
   input logic [127:0] l1_mem_req_store_data;
   input logic [4:0] l1_mem_req_opcode;

   output logic        l1_mem_rsp_valid;
   output logic [127:0] l1_mem_load_data;
   
   input logic 	mem_req_ack;
   output logic mem_req_valid;
   output logic [`PA_WIDTH-1:0] mem_req_addr;
   output logic [127:0] mem_req_store_data;
   output logic [4:0] 	mem_req_opcode;
   output logic [15:0]	mem_req_mask;
   
   input logic 		mem_rsp_valid;
   input logic		mem_rsp_bad;
   
   input logic [127:0] 	mem_rsp_load_data;

   output logic [63:0] cache_hits;
   output logic [63:0] cache_accesses;
   input logic 	       snoop_req_valid;
   input logic [`PA_WIDTH-1:0] snoop_req_addr;
   output logic        snoop_req_ack;
   /* Back-invalidate the primary caches so the L2 is INCLUSIVE: a snoop that hits
    * here must also drop any L1 copy, otherwise the 17.5% of stale reads that are
    * L1D-resident (measured) survive.  The L1s return dirty data ON THE ACK and
    * issue no request, so no loop can form with this pending eviction. */
   output logic [`PA_WIDTH-1:0] backinv_addr;
   output logic        backinv_stall;    /* bq near full: hold off new core requests */
   output logic        backinv_d_req;
   input logic 	       backinv_d_ack;
   input logic 	       backinv_d_dirty;
   input logic [127:0] backinv_d_data;
   output logic        backinv_i_req;
   input logic 	       backinv_i_ack;
   logic 	       r_snoop_ack, n_snoop_ack;
   logic 	       t_snoop_backinv;   /* snoop wants a back-invalidate enqueued */
   logic 	       r_backinv_d, n_backinv_d, r_backinv_i, n_backinv_i;
   logic [`PA_WIDTH-1:0] r_backinv_addr, n_backinv_addr;
   logic [63:0]        r_backinv_clobber, n_backinv_clobber;
   assign backinv_d_req = r_backinv_d;
   assign backinv_i_req = r_backinv_i;
   assign backinv_addr = r_backinv_addr;
   assign snoop_req_ack = r_snoop_ack;
`ifdef VERILATOR
   logic [63:0]        r_snoop_hit, n_snoop_hit, r_snoop_dirty, n_snoop_dirty;
   logic [63:0]        r_snoop_vld, n_snoop_vld;
`endif
   
   
   localparam LG_L2_LINES = `LG_L2_NUM_SETS;
   localparam L2_LINES = 1<<LG_L2_LINES;
   
   localparam TAG_BITS = `PA_WIDTH - (LG_L2_LINES + 4);

   logic 		t_wr_dirty, t_wr_valid;
   logic 		t_wr_d0, t_wr_tag;
   
   logic 		t_valid, t_dirty;
   logic [LG_L2_LINES-1:0] t_idx, r_idx;
   logic [TAG_BITS-1:0]	   n_tag, r_tag;
   logic [`PA_WIDTH-1:0]	   n_addr, r_addr;
   logic [`PA_WIDTH-1:0]	   n_saveaddr, r_saveaddr;
   
   logic [4:0] 		   n_opcode, r_opcode;
   logic 		   n_from_l1i, r_from_l1i;

   logic 		   r_mem_req, n_mem_req;
   logic [4:0] 		   r_mem_opcode, n_mem_opcode;
   logic 		   r_req_ack, n_req_ack;
   
   logic 		   r_rsp_valid, n_rsp_valid;
   logic [127:0] 	   r_rsp_data, n_rsp_data;
   logic [127:0] 	   r_store_data, n_store_data;
   logic [15:0]		   r_store_mask, n_store_mask;
   logic			   n_is_uncache, r_is_uncache;
   logic [15:0]		   n_uncache_mask, r_uncache_mask;
   
   
   logic 		   r_reload, n_reload;
   
   typedef enum logic  {
			     WAIT_FOR_FLUSH,
			     WAIT_FOR_L1_FLUSH_DONE
			     } flush_state_t;

   logic 	r_need_l1i,n_need_l1i,r_need_l1d,n_need_l1d;
   /* An L1I-only flush (the I-side CACHE op) must NOT walk every L2 line -- the
    * I-cache is read-only and the D-side already writes its lines through to DRAM,
    * so the O(L2_size) writeback walk was pure waste (dominated the boot on a large
    * L2; TIP charged 95% of cycles to the cache-op PC). r_had_l1d = did THIS flush
    * sequence involve an L1D flush (-> a real L2 writeback is needed); r_flush_skip =
    * the pending flush should complete WITHOUT the walk. */
   logic 	r_had_l1d, n_had_l1d;
   logic 	t_l2_skip_walk;
   logic 	r_flush_skip, n_flush_skip;
   logic 	t_l2_flush_req;
   
   flush_state_t n_flush_state, r_flush_state;
   
   
   /* widened 4->5 bits: BACKINV_WAIT='d16 does not fit in 4 bits (it silently
    * aliased INITIALIZE='d0, which verilator caught as an overlapping enum). */
   typedef enum 	logic [4:0] {
				     INITIALIZE = 'd0,
				     IDLE = 'd1,
				     WAIT_FOR_RAM = 'd2,
				     CHECK_VALID_AND_TAG = 'd3,
				     CLEAN_RELOAD = 'd4,
				     DIRTY_STORE = 'd5,
				     STORE_TURNAROUND = 'd6,
				     WAIT_CLEAN_RELOAD = 'd7,
				     WAIT_STORE_IDLE = 'd8,
				     FLUSH_STORE = 'd9,
				     FLUSH_WAIT = 'd10,
				     FLUSH_TRIAGE = 'd11,
				     UNCACHE_STORE = 'd12,
				     UNCACHE_LOAD = 'd13,
				     UNCACHE_WB_TURNAROUND = 'd14,   /* was GAMEOVER (dead): mem_req gap after WB drain */
				     UNCACHE_WB_DRAIN = 'd15,
				     BACKINV_WAIT = 'd16,
				     BACKINV_WB = 'd17
				     } state_t;

   state_t n_state, r_state;


   logic 		n_flush_complete, r_flush_complete;
   logic 		r_flush_req, n_flush_req;
   logic [127:0] 	r_mem_req_store_data, n_mem_req_store_data;
   logic [63:0] 	r_cache_hits, n_cache_hits, r_cache_accesses, n_cache_accesses;

   logic		n_got_mem_rsp_valid,r_got_mem_rsp_valid;

   state_t r_rsp_state;
   assign state = r_state;
   assign rsp_state = r_rsp_state;
   
   always@(posedge clk)
     begin
	if(n_got_mem_rsp_valid & (r_got_mem_rsp_valid==1'b0))
	  begin
	     r_rsp_state <= r_state;
	  end
     end

   
   
   assign flush_complete = r_flush_complete;
   assign mem_req_addr = r_addr;
   assign mem_req_valid = r_mem_req;
   assign mem_req_opcode = r_mem_opcode;
   assign mem_req_store_data = r_mem_req_store_data;
   assign mem_req_mask = r_store_mask;
   
   assign l1_mem_rsp_valid = r_rsp_valid;
   assign l1_mem_load_data = r_rsp_data;
   assign l1_mem_req_ack = r_req_ack;
   
   assign cache_hits = r_cache_hits;
   assign cache_accesses = r_cache_accesses;
   
     
   logic [127:0] 	t_d0;
      
   wire [127:0] 	w_d0;
   wire [TAG_BITS-1:0] 	w_tag;
   wire 		w_valid, w_dirty;

   
   reg_ram1rw #(.WIDTH(128), .LG_DEPTH(LG_L2_LINES)) data_ram0
     (.clk(clk), .addr(t_idx), .wr_data(t_d0), .wr_en(t_wr_d0), .rd_data(w_d0));
      
   reg_ram1rw #(.WIDTH(TAG_BITS), .LG_DEPTH(LG_L2_LINES)) tag_ram
     (.clk(clk), .addr(t_idx), .wr_data(r_tag), .wr_en(t_wr_tag), .rd_data(w_tag));   
   
   reg_ram1rw #(.WIDTH(1), .LG_DEPTH(LG_L2_LINES)) valid_ram
     (.clk(clk), .addr(t_idx), .wr_data(t_valid), .wr_en(t_wr_valid), .rd_data(w_valid));   

   reg_ram1rw #(.WIDTH(1), .LG_DEPTH(LG_L2_LINES)) dirty_ram
     (.clk(clk), .addr(t_idx), .wr_data(t_dirty), .wr_en(t_wr_dirty), .rd_data(w_dirty));   

   /* ---- INCLUSION: per-line record of which L1 holds a copy ----------------------
    * Set when the L2 DELIVERS a cacheable line to an L1 (a hit forwarded to an L1
    * creates a copy just as a DRAM fill does, so this keys off the RESPONSE, not the
    * fill).  Cleared whenever the line is invalidated or evicted.  Two independent
    * 1-bit RAMs rather than a 2-bit read-modify-write: each write has a known value,
    * so there is no hazard against the registered (one-cycle-late) RAM reads.
    * Over-approximation is SAFE -- a stale set bit costs one redundant
    * back-invalidate, never a missed one -- which is why L1 evictions are deliberately
    * NOT reported back to the L2. */
   logic 		t_wr_l1d_pres, t_wr_l1i_pres;
   /* Measured OUTSIDE the state machine: an in-case probe previously split the
    * else chain and made the writeback unconditional, so the thing being measured
    * stopped happening.  restart_wb << restart => the merged line's dirty bit did
    * not survive the restart and the recovered data was dropped. */
   wire 		w_restart_seen = (r_state == CHECK_VALID_AND_TAG) & r_bi_done;
   wire 		w_restart_wb = w_restart_seen & w_need_wb;
   integer 		r_n_restart, r_n_restart_wb;
   logic 		t_pres_clr;      /* drop both presence bits at back-invalidate completion */
   logic 		r_bi_done, n_bi_done;   /* loop guard: this victim already back-invalidated */
   logic 		t_l1d_pres_val, t_l1i_pres_val;
   wire 		w_l1d_pres, w_l1i_pres;

   reg_ram1rw #(.WIDTH(1), .LG_DEPTH(LG_L2_LINES)) l1d_pres_ram
     (.clk(clk), .addr(t_idx), .wr_data(t_l1d_pres_val), .wr_en(t_wr_l1d_pres), .rd_data(w_l1d_pres));

   reg_ram1rw #(.WIDTH(1), .LG_DEPTH(LG_L2_LINES)) l1i_pres_ram
     (.clk(clk), .addr(t_idx), .wr_data(t_l1i_pres_val), .wr_en(t_wr_l1i_pres), .rd_data(w_l1i_pres));

   /* a cacheable READ response (opcode 4) is exactly the event that hands a line to an
    * L1; an invalidate/evict is t_wr_valid with t_valid low. */
   wire 		w_l1_copy_made = n_rsp_valid & (r_opcode == 5'd4);
   wire 		w_line_dropped = t_wr_valid & ~t_valid;

   always_comb
     begin
	t_wr_l1d_pres  = (w_l1_copy_made & ~r_from_l1i) | w_line_dropped | t_pres_clr;
	t_l1d_pres_val = (w_l1_copy_made & ~r_from_l1i);
	t_wr_l1i_pres  = (w_l1_copy_made &  r_from_l1i) | w_line_dropped | t_pres_clr;
	t_l1i_pres_val = (w_l1_copy_made &  r_from_l1i);
     end // always_comb

`ifdef ENABLE_L2_INCLUSION
   /* ---- back-invalidate queue -------------------------------------------------
    * The snoop path could issue directly, because IDLE can simply refuse a new
    * snoop while one is outstanding.  An EVICTION cannot: it happens on the fill
    * path that the L1D is itself waiting on, so stalling the L2 until the L1D
    * acks deadlocks (the L1D cannot reach a state where it would ack while its
    * fill is blocked).  Queue instead, and drain independently of the main FSM.
    *
    * Overflow would DROP an invalidate, which is precisely the corruption this
    * exists to prevent, so it is counted and reported loudly rather than
    * silently tolerated.  If it never trips, the depth is adequate; if it does,
    * the L1s need a dedicated snoop port on their tag arrays. */
   localparam LG_BQ = 3;                       /* 8 entries */
   reg [`PA_WIDTH-1:0] r_bq_addr [(1<<LG_BQ)-1:0];
   reg [(1<<LG_BQ)-1:0] r_bq_d, r_bq_i;
   reg [(1<<LG_BQ)-1:0] r_bq_ev;   /* 1 = eviction: a dirty L1D line is the ONLY copy */
   reg [LG_BQ:0]       r_bq_head, n_bq_head, r_bq_tail, n_bq_tail;
   wire                w_bq_empty = (r_bq_head == r_bq_tail);
   wire                w_bq_full  = (r_bq_head[LG_BQ-1:0] == r_bq_tail[LG_BQ-1:0]) &
                                    (r_bq_head[LG_BQ] != r_bq_tail[LG_BQ]);
   /* An eviction/invalidate of a line an L1 still holds.  The victim's address is
    * rebuilt from the RAM's own tag output and the index being written -- NOT from
    * r_saveaddr, which names the INCOMING line on a fill, not the one leaving. */
   /* The whole-cache flush walk drops every line in turn -- thousands of enqueues
    * at ~1/cycle against a drain of 1 per L1D ack, which is what produced
    * bq_ovf=10488 and (dropped invalidates -> stale data) an init SIGSEGV.
    * Suppressed rather than absorbed, and that is CORRECT, not a heuristic: the
    * L2 flush is only ever driven by flush_req_l1i/flush_req_l1d, i.e. the core's
    * CACHE_FLUSH, which empties the L1s in the same operation -- so every
    * back-invalidate the walk would enqueue is redundant by construction. */
   wire                w_in_flush_walk = (r_state == FLUSH_WAIT) | (r_state == FLUSH_STORE) |
                                         (r_state == FLUSH_TRIAGE);
   /* Eviction back-invalidate is OFF by default: proven (bisect, 2026-08) to
    * corrupt memory -> IRIX "init died" SIGSEGV, because the L1D's recovered
    * dirty line goes out-of-band to DRAM while the L2 -- the coherence point --
    * has already dropped its copy, leaving a window where a reader misses both
    * caches and gets stale DRAM.  Correct ordering (back-invalidate -> merge into
    * the L2 line -> normal L2 writeback) needs the eviction to BLOCK on the ack,
    * which needs the L1D snoop port.  Enable together with that. */
   /* Evictions are back-invalidated INLINE and synchronously in the miss path
    * (BACKINV_WAIT below), so they never enter the queue.  The queue serves
    * snoops only. */
   wire                w_evict_backinv = 1'b0;
   wire [`PA_WIDTH-1:0] w_evict_addr = {w_tag, t_idx, 4'd0};
   /* High-water backpressure to the CORE side (not the L1->L2 port: an L1 holding
    * a request sits in a wait state and can never ack, so stalling there
    * deadlocks).  Draining then depends only on already-accepted transactions,
    * which nothing blocks.  Headroom of 2 covers the at-most-one L1D and one L1I
    * fill that can still evict while the stall takes effect. */
   assign backinv_stall = ((r_bq_tail - r_bq_head) >= ((1<<LG_BQ) - 3)) | r_wb_pend;
   /* A dirty line returned by an EVICTION back-invalidate is the only up-to-date
    * copy in the machine -- discarding it (which is right for a snoop, where DRAM
    * already holds newer DMA data) silently loses the write.  Latch it and push it
    * to DRAM from IDLE. */
   logic               r_backinv_ev, n_backinv_ev;
   logic               r_wb_pend, n_wb_pend;
   logic [`PA_WIDTH-1:0] r_wb_addr, n_wb_addr;
   logic [127:0]       r_wb_data, n_wb_data;
   integer             r_n_wb;
   logic               t_bq_push;
   logic [`PA_WIDTH-1:0] t_bq_addr;
   logic               t_bq_d, t_bq_i, t_bq_ev;
   integer             r_n_bq_ovf, r_n_evict_bi;
   integer             r_n_inline_bi, r_n_merge;   /* inline eviction back-invalidates, and dirty merges */

   always_comb
     begin
	/* the snoop path enqueues from CHECK_VALID_AND_TAG via t_snoop_backinv */
	t_bq_push = w_evict_backinv | t_snoop_backinv;
	t_bq_addr = t_snoop_backinv ? {r_saveaddr[`PA_WIDTH-1:4], 4'd0} : w_evict_addr;
	t_bq_d    = t_snoop_backinv ? w_l1d_pres : w_l1d_pres;
	t_bq_i    = t_snoop_backinv ? w_l1i_pres : w_l1i_pres;
	t_bq_ev   = 1'b0;   /* queue holds snoops only; r_wb_pend/BACKINV_WB now dead */
	n_bq_tail = r_bq_tail + ((t_bq_push & ~w_bq_full) ? 1 : 0);
	/* pop only when the request register is free */
	n_bq_head = r_bq_head + ((~w_bq_empty & ~r_backinv_d & ~r_backinv_i & ~r_wb_pend) ? 1 : 0);
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_bi_done <= 1'b0;
	     r_bq_head <= 'd0;
	     r_bq_tail <= 'd0;
	     r_n_bq_ovf <= 0;
	     r_n_inline_bi <= 0;
	     r_n_restart <= 0;
	     r_n_restart_wb <= 0;
	     r_n_merge <= 0;
	     r_n_evict_bi <= 0;
	  end
	else
	  begin
	     r_bi_done <= n_bi_done;
	     r_bq_head <= n_bq_head;
	     r_bq_tail <= n_bq_tail;
	     r_n_bq_ovf <= r_n_bq_ovf + ((t_bq_push & w_bq_full) ? 1 : 0);
	     /* zero here would be indistinguishable from "path not reached" -- the exact
	      * blindness that cost most of a day earlier. */
	     r_n_inline_bi <= r_n_inline_bi + (((n_state == BACKINV_WAIT) & (r_state != BACKINV_WAIT)) ? 1 : 0);
	     r_n_restart <= r_n_restart + (w_restart_seen ? 1 : 0);
	     r_n_restart_wb <= r_n_restart_wb + (w_restart_wb ? 1 : 0);
	     r_n_merge <= r_n_merge + (((r_state == BACKINV_WAIT) & backinv_d_ack & backinv_d_dirty) ? 1 : 0);
	     r_n_evict_bi <= r_n_evict_bi + ((w_evict_backinv & ~w_bq_full) ? 1 : 0);
	  end
     end // always_ff

   always_ff@(posedge clk)
     begin
	if(t_bq_push & ~w_bq_full)
	  begin
	     r_bq_addr[r_bq_tail[LG_BQ-1:0]] <= t_bq_addr;
	     r_bq_d[r_bq_tail[LG_BQ-1:0]] <= t_bq_d;
	     r_bq_i[r_bq_tail[LG_BQ-1:0]] <= t_bq_i;
	     r_bq_ev[r_bq_tail[LG_BQ-1:0]] <= t_bq_ev;
	  end
     end // always_ff
`endif

`ifdef VERILATOR
   /* Is the inclusion path actually REACHED?  Counts, not guesses: presence-bit sets,
    * snoop hits, and back-invalidate entries.  A zero here says the mechanism never
    * runs, which is indistinguishable from "it runs and does nothing" in the counters. */
   integer r_n_pres_d, r_n_pres_i, r_n_backinv, r_n_snoop_req;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_n_pres_d <= 0;
	     r_n_pres_i <= 0;
	     r_n_backinv <= 0;
	     r_n_snoop_req <= 0;
	  end
	else
	  begin
	     r_n_pres_d <= r_n_pres_d + ((t_wr_l1d_pres & t_l1d_pres_val) ? 1 : 0);
	     r_n_pres_i <= r_n_pres_i + ((t_wr_l1i_pres & t_l1i_pres_val) ? 1 : 0);
	     r_n_backinv <= r_n_backinv + (((n_backinv_d | n_backinv_i) & ~(r_backinv_d | r_backinv_i)) ? 1 : 0);
	     /* snoops actually ACCEPTED by the L2.  Zero here means the FIFO in henry_soc
	      * never pushed (w_dma_store never true) -- i.e. the problem is upstream of
	      * the L2 entirely, not the snoop address. */
	     r_n_snoop_req <= r_n_snoop_req + (n_snoop_ack ? 1 : 0);
	     /* every 20M: DMA does not start until ~120M cycles, so a 100M-period
	      * readout samples the machine before any snoop can possibly have fired. */
	     if((r_cycle % `INCL_PERIOD) == (`INCL_PERIOD-1))
	       begin
		  /* snoop_hit distinguishes "the snoop never finds the line" (address-form
		   * mismatch between the DMA master's view and the L2's) from "it finds it
		   * but no L1 holds a copy".  backinv_entries=0 with hits>0 means the
		   * presence test is wrong; hits=0 means the snoop address is wrong. */
		  $display("[incl] cyc=%0d pres_set_d=%0d pres_set_i=%0d backinv_entries=%0d snoop_req=%0d snoop_hit=%0d snoop_vld=%0d snoop_dirty=%0d evict_bi=%0d bq_ovf=%0d wb=%0d inline_bi=%0d merges=%0d restart=%0d restart_wb=%0d",
			   r_cycle, r_n_pres_d, r_n_pres_i, r_n_backinv, r_n_snoop_req, r_snoop_hit, r_snoop_vld, r_snoop_dirty, r_n_evict_bi, r_n_bq_ovf, r_n_wb, r_n_inline_bi, r_n_merge, r_n_restart, r_n_restart_wb);
	       end
	  end
     end // always_ff
`endif

   wire 		w_hit = w_valid ? (r_tag == w_tag) : 1'b0;
   wire 		w_need_wb = w_valid ? w_dirty : 1'b0;
      
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= INITIALIZE;
	     r_flush_state <= WAIT_FOR_FLUSH;
	     r_flush_complete <= 1'b0;
	     r_idx <= 'd0;
	     r_tag <= 'd0;
	     r_opcode <= 5'd0;
	     r_from_l1i <= 1'b0;
	     r_addr <= 'd0;
	     r_saveaddr <= 'd0;
	     r_mem_req <= 1'b0;
	     r_mem_opcode <= 5'd0;
	     r_rsp_data <= 'd0;
	     r_rsp_valid <= 1'b0;
	     r_reload <= 1'b0;
	     r_req_ack <= 1'b0;
	     r_snoop_ack <= 1'b0;
	     r_backinv_d <= 1'b0;
	     r_backinv_i <= 1'b0;
	     r_backinv_addr <= 'd0;
	     r_backinv_ev <= 1'b0;
	     r_wb_pend <= 1'b0;
	     r_wb_addr <= 'd0;
	     r_wb_data <= 'd0;
	     r_n_wb <= 0;
	     r_backinv_clobber <= 64'd0;
`ifdef VERILATOR
	     r_snoop_hit <= 64'd0;
	     r_snoop_dirty <= 64'd0;
	     r_snoop_vld <= 64'd0;
`endif
	     r_store_data <= 'd0;
	     r_store_mask <= 'd0;	     
	     r_is_uncache <= 1'b0;
	     r_uncache_mask <= 'd0;
	     r_flush_req <= 1'b0;
	     r_need_l1d <= 1'b0;
	     r_need_l1i <= 1'b0;
	     r_had_l1d <= 1'b0;
	     r_flush_skip <= 1'b0;
	     r_got_mem_rsp_valid <= 1'b0;
	     r_cache_hits <= 'd0;
	     r_cache_accesses <= 'd0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_flush_state <= n_flush_state;
	     r_flush_complete <= n_flush_complete;
	     r_idx <= t_idx;
	     r_tag <= n_tag;
	     r_opcode <= n_opcode;
	     r_from_l1i <= n_from_l1i;
	     r_addr <= n_addr;
	     r_saveaddr <= n_saveaddr;
	     /* back-invalidate request flops.  These were assigned ONLY in the reset
	      * branch, so backinv_d_req/backinv_i_req sat at 0 forever: the L1s never
	      * saw a request, BACKINV_WAIT's "everything acked" test was vacuously
	      * true so it never stalled, and the entry counter still incremented --
	      * the machinery reported success while doing nothing. */
	     r_backinv_d <= n_backinv_d;
	     r_backinv_i <= n_backinv_i;
	     r_backinv_addr <= n_backinv_addr;
	     r_backinv_ev <= n_backinv_ev;
	     r_wb_pend <= n_wb_pend;
	     r_wb_addr <= n_wb_addr;
	     r_wb_data <= n_wb_data;
	     r_n_wb <= r_n_wb + ((n_wb_pend & ~r_wb_pend) ? 1 : 0);
	     r_mem_req <= n_mem_req;
	     r_mem_opcode <= n_mem_opcode;
	     r_rsp_data <= n_rsp_data;
	     r_rsp_valid <= n_rsp_valid;
	     r_reload <= n_reload;
	     r_req_ack <= n_req_ack;
	     r_snoop_ack <= n_snoop_ack;
`ifdef VERILATOR
	     r_snoop_hit <= n_snoop_hit;
	     r_snoop_dirty <= n_snoop_dirty;
	     r_snoop_vld <= n_snoop_vld;
	     if((r_cycle[23:0] == 24'd0) & ((r_snoop_hit != 64'd0) | (r_snoop_dirty != 64'd0)))
	       $display("[snoopstat] cyc=%0d snoop_hits=%0d dirty=%0d", r_cycle, r_snoop_hit, r_snoop_dirty);
`endif
	     r_store_data <= n_store_data;
	     r_store_mask <= n_store_mask;
	     r_is_uncache <= n_is_uncache;
	     r_uncache_mask <= n_uncache_mask;
	     r_flush_req <= n_flush_req;
	     r_need_l1i <= n_need_l1i;
	     r_need_l1d <= n_need_l1d;
	     r_had_l1d <= n_had_l1d;
	     r_flush_skip <= n_flush_skip;
	     r_got_mem_rsp_valid <= n_got_mem_rsp_valid;
	     r_cache_hits <= n_cache_hits;
	     r_cache_accesses <= n_cache_accesses;	     
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	r_mem_req_store_data <= n_mem_req_store_data;
     end
   
   //always_ff@(negedge clk)
   //begin
	//$display("l1i_flush_req = %b", l1i_flush_req);
	//$display("l1d_flush_req = %b", l1d_flush_req);
	
   //if((l1d_flush_complete||l1i_flush_complete) && (r_flush_state == WAIT_FOR_FLUSH)) 
   //$stop();
   //end
   
   always_comb
     begin
	n_flush_state = r_flush_state;
	n_need_l1d = r_need_l1d | l1d_flush_req;
	n_need_l1i = r_need_l1i | l1i_flush_req;
	n_had_l1d = r_had_l1d | l1d_flush_req;   /* sticky over the sequence */
	t_l2_flush_req = 1'b0;
	t_l2_skip_walk = 1'b0;
	case(r_flush_state)
	  WAIT_FOR_FLUSH:
	    begin
	       if(n_need_l1i | n_need_l1d)
		 begin
		    n_flush_state = WAIT_FOR_L1_FLUSH_DONE;
		    //$display("-> got flush req at cycle %d, n_need_l1d = %b, n_need_l1i = %b", r_cycle, n_need_l1d, n_need_l1i);
		 end
	    end
	  WAIT_FOR_L1_FLUSH_DONE:
	    begin
	       if(r_need_l1d && l1d_flush_complete)
		 begin
		    //$display("-> l1d flush complete at cycle %d", r_cycle);
		    n_need_l1d = 1'b0;
		 end
	       if(r_need_l1i && l1i_flush_complete)
		 begin
		    //$display("-> l1i flush complete at cycle %d", r_cycle);
		    n_need_l1i = 1'b0;
		 end
	       
	       if((n_need_l1d==1'b0) && (n_need_l1i==1'b0))
		 begin
		    //$display("-> firing l2 flush at cycle %d", r_cycle);
		    n_flush_state = WAIT_FOR_FLUSH;
		    t_l2_flush_req = 1'b1;
		    t_l2_skip_walk = ~n_had_l1d;   /* L1I-only -> skip the O(L2_size) walk */
		    n_had_l1d = 1'b0;              /* reset for the next sequence */
		 end
	    end
	endcase
     end // always_comb


   logic [31:0] r_cycle;
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : (r_cycle + 'd1);
     end

`ifdef VERILATOR
   // L2 line tracer (L2DBG): watch every boundary of the SCSI-descriptor cache
   // line 0x083e4000 -- L1D->L2 stores/writebacks in (side 0), L2 fills from DRAM
   // (side 2), and L2->DRAM evictions out (side 1).  Lets us see whether the L2
   // faithfully passes the line or corrupts it between in and out.
   import "DPI-C" function void l2_line_log(input int side,
					    input longint unsigned pa,
					    input longint unsigned d0,
					    input longint unsigned d1,
					    input int op,
					    input int mask);
   // decision log at CHECK_VALID_AND_TAG for the descriptor line: shows whether the
   // op hit, whether the held line is dirty, and its current content w_d0.
   /* every snoop lookup, with its verdict -- lets the C++ side answer "was this
    * stale line ever snooped, and did the lookup hit?" by table lookup instead
    * of inference from aggregate counters. */
   import "DPI-C" function void snoop_log(input longint unsigned pa, input int hit);
   import "DPI-C" function void l2_chk_log(input longint unsigned pa,
					   input int whit, input int wvalid, input int wdirty,
					   input int op,
					   input longint unsigned d0lo, input longint unsigned d0hi);
   reg r_l2wb_prev;
   always_ff@(posedge clk)
     begin
	r_l2wb_prev <= reset ? 1'b0 : r_mem_req;
     end
   always_ff@(negedge clk)
     begin
	if(l1_mem_req_valid & r_req_ack & (l1_mem_req_addr[31:4] == 28'h083e400))
	  begin
	     l2_line_log(0, {{(64-`PA_WIDTH){1'b0}}, l1_mem_req_addr},
			 l1_mem_req_store_data[63:0], l1_mem_req_store_data[127:64],
			 {27'd0, l1_mem_req_opcode}, {16'd0, l1_mem_req_mask});
	  end
	if(r_mem_req & ~r_l2wb_prev & (r_addr[31:4] == 28'h083e400))
	  begin
	     l2_line_log(1, {{(64-`PA_WIDTH){1'b0}}, r_addr},
			 r_mem_req_store_data[63:0], r_mem_req_store_data[127:64],
			 {27'd0, r_mem_opcode}, {16'd0, r_store_mask});
	  end
	if(mem_rsp_valid & (r_addr[31:4] == 28'h083e400))
	  begin
	     l2_line_log(2, {{(64-`PA_WIDTH){1'b0}}, r_addr},
			 mem_rsp_load_data[63:0], mem_rsp_load_data[127:64], 32'd0, 32'd0);
	  end
	/* DMA stale-read detector wants EVERY tag check, not just the one descriptor
	 * line this probe was originally written for; filter C++-side instead. */
	if((r_state == CHECK_VALID_AND_TAG)
`ifndef ENABLE_DMA_STALE_CHK
	   & (r_saveaddr[31:4] == 28'h083e400)   /* legacy: descriptor-line watch only */
`endif
	   )
	  begin
	     l2_chk_log({{(64-`PA_WIDTH){1'b0}}, r_saveaddr},
			{31'd0, w_hit}, {31'd0, w_valid}, {31'd0, w_dirty},
			{27'd0, r_opcode}, w_d0[63:0], w_d0[127:64]);
	  end
     end // always_ff
`endif

   state_t r_last_state;
   always_ff@(posedge clk)
     begin
	r_last_state <= r_state;
     end
   always_ff@(negedge clk)
     begin
	if((r_state == IDLE) & (r_mem_req))
	  begin
	     $display("l2 protocol busted, last state %d", r_last_state);
	     `ifdef VERILATOR $stop(); `endif
	  end
     end
   

   always_comb
     begin
	n_state = r_state;
	n_flush_complete = 1'b0;
	t_wr_valid = 1'b0;
	t_wr_dirty = 1'b0;
	t_wr_d0 = 1'b0;
	t_wr_tag = 1'b0;
	
	t_idx = r_idx;
	n_tag = r_tag;
	n_opcode = r_opcode;
	n_from_l1i = r_from_l1i;
	n_addr = r_addr;
	n_saveaddr = r_saveaddr;
	
	n_req_ack = 1'b0;
	n_snoop_ack = 1'b0;
	t_snoop_backinv = 1'b0;
	t_pres_clr = 1'b0;
	n_bi_done = r_bi_done;
	n_backinv_d = r_backinv_d;
	n_backinv_i = r_backinv_i;
	n_backinv_addr = r_backinv_addr;
	n_backinv_ev = r_backinv_ev;
	n_wb_pend = r_wb_pend;
	n_wb_addr = r_wb_addr;
	n_wb_data = r_wb_data;
`ifdef ENABLE_L2_INCLUSION
	/* An ack can arrive in ANY state now that the request is fire-and-forget,
	 * so clear it here rather than inside a wait state.  Placed BEFORE the case
	 * so a snoop issuing a new request this cycle overrides it. */
	/* drain: load the next queued back-invalidate whenever the request
	 * registers are free.  Independent of the main FSM, so a queued eviction
	 * still reaches the L1s while the L2 is busy serving the fill that caused
	 * it. */
	if(~w_bq_empty & ~r_backinv_d & ~r_backinv_i & ~r_wb_pend)
	  begin
	     n_backinv_addr = r_bq_addr[r_bq_head[LG_BQ-1:0]];
	     n_backinv_d = r_bq_d[r_bq_head[LG_BQ-1:0]];
	     n_backinv_i = r_bq_i[r_bq_head[LG_BQ-1:0]];
	     n_backinv_ev = r_bq_ev[r_bq_head[LG_BQ-1:0]];
	  end
	if(backinv_d_ack)
	  begin
	     n_backinv_d = 1'b0;
	     /* DRAM already holds the fresh DMA data, so a dirty L1D line here is a
	      * genuine CPU-store-vs-DMA-write race, NOT something to merge back
	      * (that would clobber the DMA data).  Count it. */
	     if(backinv_d_dirty)
	       begin
		  if(r_backinv_ev)
		    begin
		       n_wb_pend = 1'b1;
		       n_wb_addr = r_backinv_addr;
		       n_wb_data = backinv_d_data;
		    end
		  else
		    begin
		       n_backinv_clobber = r_backinv_clobber + 64'd1;
		    end
	       end
	  end
	if(backinv_i_ack)
	  begin
	     n_backinv_i = 1'b0;
	  end
`endif
	n_backinv_clobber = r_backinv_clobber;
`ifdef VERILATOR
	n_snoop_hit = r_snoop_hit;
	n_snoop_dirty = r_snoop_dirty;
	n_snoop_vld = r_snoop_vld;
`endif
	n_mem_req = r_mem_req;
	n_mem_opcode = r_mem_opcode;
		
	t_valid = 1'b0;
	t_dirty = 1'b0;

	t_d0 = mem_rsp_load_data[127:0];

	n_rsp_data = r_rsp_data;
	n_rsp_valid = 1'b0;

	n_reload = r_reload;
	n_store_data = r_store_data;
	n_store_mask = r_store_mask;
	n_is_uncache = r_is_uncache;
	n_uncache_mask = r_uncache_mask;
	n_flush_req = r_flush_req | t_l2_flush_req;
	n_flush_skip = r_flush_skip | (t_l2_flush_req & t_l2_skip_walk);
	n_mem_req_store_data = r_mem_req_store_data;

	n_cache_hits = r_cache_hits;
	n_cache_accesses = r_cache_accesses;

	n_got_mem_rsp_valid = r_got_mem_rsp_valid | mem_rsp_valid;
	
	
	case(r_state)
	  INITIALIZE:
	    begin
	       t_valid = 1'b0;
	       t_dirty = 1'b0;
	       
	       t_wr_valid = 1'b1;
	       t_wr_dirty = 1'b1;
	       
	       t_idx = r_idx + 'd1;
	       if(r_idx == (L2_LINES-1))
		 begin
		    n_state = IDLE;
		    n_flush_complete = 1'b1;
		 end
	    end // case: INITIALIZE
	  IDLE:
	    begin
	       t_idx = l1_mem_req_addr[LG_L2_LINES+3:4];
	       n_tag = l1_mem_req_addr[`PA_WIDTH-1:LG_L2_LINES+4];
	       n_addr = {l1_mem_req_addr[`PA_WIDTH-1:4], 4'd0};
	       n_saveaddr = {l1_mem_req_addr[`PA_WIDTH-1:4], 4'd0};
	       n_from_l1i = l1_mem_req_from_l1i;
	       n_opcode = l1_mem_req_opcode;
	       n_store_data = l1_mem_req_store_data;
	       n_store_mask = 16'h0;

	       //if(r_mem_req)
	       ///begin
	       //    $stop();
	       //end
	       
	       if(n_flush_req & n_flush_skip)
		 begin
		    /* L1I-only flush: nothing to write back from L2 (I-cache read-only;
		     * the D-side already wrote its lines through to DRAM). Complete the
		     * handshake WITHOUT walking every L2 line. */
		    n_flush_complete = 1'b1;
		    n_flush_req = 1'b0;
		    n_flush_skip = 1'b0;
		 end
	       else if(n_flush_req)
		 begin
		    t_idx = 'd0;
		    n_state = FLUSH_WAIT;
		    n_store_mask = 16'hffff;
		    //$display("GOT FLUSH REQUEST at cycle %d", r_cycle);
		 end
`ifdef ENABLE_L2_INCLUSION
`ifdef ENABLE_L2_INCLUSION
	       else if(r_wb_pend)
		 begin
		    /* push the recovered dirty line to DRAM.  Ordered AFTER the L2's own
		     * writeback of the line it evicted, so the L1D's newer data wins. */
		    n_mem_req = 1'b1;
		    n_addr = r_wb_addr;
		    n_mem_opcode = 5'd7;
		    n_mem_req_store_data = r_wb_data;
		    n_state = BACKINV_WB;
		 end
`endif
	       else if(snoop_req_valid & ~w_bq_full)
`else
	       else if(snoop_req_valid)
`endif
		 begin
		    /* DMA-coherence snoop: the SCSI DMA engine wrote this line to DRAM
		     * behind the CPU caches, and IRIX can't invalidate r9999's (hidden)
		     * L2.  Synthesize a MEM_INVL so CHECK_VALID_AND_TAG drops the now-
		     * stale L2 copy (a subsequent L1 miss then refetches fresh DRAM).
		     * Priority above the L1 request; the L1 holds its req one more cycle. */
		    t_idx = snoop_req_addr[LG_L2_LINES+3:4];
		    n_tag = snoop_req_addr[`PA_WIDTH-1:LG_L2_LINES+4];
		    n_addr = {snoop_req_addr[`PA_WIDTH-1:4], 4'd0};
		    n_saveaddr = {snoop_req_addr[`PA_WIDTH-1:4], 4'd0};
		    n_opcode = MEM_SNOOP_INVL;
		    n_snoop_ack = 1'b1;
		    /* IDLE presents t_idx to the SYNCHRONOUS tag/valid/dirty RAMs; their
		     * output is valid only NEXT cycle.  Go through WAIT_FOR_RAM (as the
		     * CPU path does) so CHECK_VALID_AND_TAG sees w_hit/w_dirty for THIS
		     * line -- skipping it reads the prior index and invalidates the wrong
		     * line (the boot wedge). */
		    n_state = WAIT_FOR_RAM;
		 end
	       else if(l1_mem_req_valid)
		 begin
		    if(w_l2_cacheable == 1'b0)
		      begin
			 /* L2 inclusive of L1: always look the line up first; on an
			  * uncached hit, evict (write back if dirty) + invalidate before
			  * the uncached op so s->mem is authoritative. */
			 n_uncache_mask = l1_mem_req_mask;
			 n_store_mask = l1_mem_req_mask;
			 n_mem_opcode = l1_mem_req_opcode;
			 n_mem_req_store_data = l1_mem_req_store_data;
			 n_req_ack = 1'b1;
			 n_is_uncache = 1'b1;
			 n_state = WAIT_FOR_RAM;
		      end
		    else
		      begin
			 n_req_ack = 1'b1;
			 n_state = WAIT_FOR_RAM;
			 n_rsp_valid = (l1_mem_req_opcode == 5'd7);
			 n_is_uncache = 1'b0;
			 n_cache_accesses = r_cache_accesses + 64'd1;
			 n_cache_hits = r_cache_hits + 64'd1;
		      end
		 end
	    end
	  WAIT_FOR_RAM:
	    begin
	       n_state = CHECK_VALID_AND_TAG;
	    end
	
	  CHECK_VALID_AND_TAG:
	    begin
	       //load hit
	       if(r_is_uncache)
		 begin
		    n_is_uncache = 1'b0;
		    if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
			 t_wr_dirty = 1'b1; t_dirty = 1'b0;
			 if(w_dirty)
			   begin
			      n_mem_req_store_data = w_d0;
			      n_addr = {w_tag, t_idx, 4'd0};
			      n_mem_opcode = 5'd7;
			      n_store_mask = 16'hffff;
			      n_mem_req = 1'b1;
			      n_got_mem_rsp_valid = 1'b0;
			      n_state = UNCACHE_WB_DRAIN;
			   end
			 else
			   begin
			      n_addr = r_saveaddr;
			      n_mem_opcode = r_opcode;
			      n_store_mask = r_uncache_mask;
			      n_mem_req_store_data = r_store_data;
			      n_mem_req = 1'b1;
			      n_got_mem_rsp_valid = 1'b0;
			      n_state = (r_opcode == 5'd7) ? UNCACHE_STORE : UNCACHE_LOAD;
			   end
		      end
		    else
		      begin
			 n_addr = r_saveaddr;
			 n_mem_opcode = r_opcode;
			 n_store_mask = r_uncache_mask;
			 n_mem_req_store_data = r_store_data;
			 n_mem_req = 1'b1;
			 n_got_mem_rsp_valid = 1'b0;
			 n_state = (r_opcode == 5'd7) ? UNCACHE_STORE : UNCACHE_LOAD;
		      end
		 end
	       else if(r_opcode == MEM_INVL)
		 begin
		    /* CACHE-Invalidate: drop the L2 line if present, then ack.
		     * FIX (a): if the L2 line is DIRTY, WRITE IT BACK TO DRAM FIRST.
		     * A dirty L2 line means an L1D eviction (MEM_SW) landed valid data
		     * here that never reached DRAM; a bare drop loses it (copy_page's
		     * VIPT same-set eviction + a coherence CHWBINV whose L1D line was
		     * already evicted -> plain INVL -> init SIGSEGV).  Flush w_d0 to
		     * DRAM, then ack.  Route the writeback through UNCACHE_WB_DRAIN
		     * (NOT straight to a store) so the mem_req turnaround gap runs --
		     * without it the AXI master's WAIT can't fall to IDLE and the bus
		     * DEADLOCKS on silicon (the wirepda class; henry_tb DRAM acks
		     * instantly so sim missed it).  UNCACHE_WB_TURNAROUND acks when
		     * r_opcode==MEM_INVL. */
		    if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
			 t_wr_dirty = 1'b1; t_dirty = 1'b0;
			 if(w_dirty)
			   begin
			      n_mem_req_store_data = w_d0;
			      n_addr = {w_tag, t_idx, 4'd0};
			      n_mem_opcode = 5'd7;
			      n_store_mask = 16'hffff;
			      n_mem_req = 1'b1;
			      n_got_mem_rsp_valid = 1'b0;
			      n_state = UNCACHE_WB_DRAIN;   /* drain+turnaround, then ack */
			   end
			 else
			   begin
			      n_state = IDLE;
			      n_rsp_valid = 1'b1;
			   end
		      end
		    else
		      begin
			 n_state = IDLE;
			 n_rsp_valid = 1'b1;
		      end
		 end
	       else if(r_opcode == MEM_SNOOP_INVL)
		 begin
		    /* DMA-coherence snoop discard: the SCSI DMA overwrote DRAM for this
		     * line behind the caches, and IRIX (in-order R4x00 model) never issues
		     * a CACHE op for a buffer it didn't touch -- so a speculatively-cached
		     * stale L2 copy would survive.  Drop it WITHOUT a writeback: DRAM now
		     * holds the fresh DMA data, so writing a stale L2 copy back (as MEM_INVL
		     * does) would clobber it.  A dirty stale copy is a recycled prior-owner
		     * page, never live data.  No L1 response (FIFO acked in IDLE). */
		    if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
		      end
		    n_state = IDLE;
`ifdef ENABLE_L2_INCLUSION
		    /* INCLUSION: dropping the L2 copy is not enough -- an L1 can hold this
		     * line too, and 17.5% of the measured stale reads were exactly that
		     * (an L1D hit with no preceding stale fill).  Back-invalidate the L1s
		     * the presence bits name.
		     *
		     * FIRE-AND-FORGET: raise the request and go straight back to IDLE
		     * rather than blocking until the L1s ack.  Blocking deadlocks: the
		     * L1D can have a request already outstanding at THIS L2 (e.g. an
		     * uncached MMIO poll), so it cannot reach a state where it would ack
		     * while we refuse to serve it.  Not waiting is safe because the L2
		     * has ALREADY dropped its own copy above -- any refill of this line
		     * now comes from DRAM and is fresh, so a back-invalidate that lands
		     * late costs one refetch and nothing else.  Ordering against a NEW
		     * snoop is kept by the accept gate in IDLE, which refuses to start
		     * another snoop while a request is still outstanding. */
		    if(w_hit & (w_l1d_pres | w_l1i_pres))
		      begin
			 t_snoop_backinv = 1'b1;
		      end
`endif
`ifdef VERILATOR
		    /* w_valid without w_hit = line present but tag mismatch (index/tag
		     * bug).  w_valid low = the line simply is not in the L2, which is
		     * the expected common case since IRIX's own dma_cache_inv forwards
		     * MEM_INVL to the L2 before most DMA. */
		    n_snoop_vld = r_snoop_vld + (w_valid ? 64'd1 : 64'd0);
		    snoop_log({{(64-`PA_WIDTH){1'b0}}, r_saveaddr}, w_hit ? 32'd1 : 32'd0);
		    if(w_hit)
		      begin
			 n_snoop_hit  = r_snoop_hit  + 64'd1;
			 n_snoop_dirty = r_snoop_dirty + (w_dirty ? 64'd1 : 64'd0);
			 if(w_dirty & (r_snoop_dirty < 64'd40))
			   $display("[snoopdirty] cyc=%0d snoop_pa=%x tag=%x idx=%x d0=%x",
				    r_cycle, r_saveaddr, w_tag, t_idx, w_d0[31:0]);
		      end
`endif
		 end
	       else if(r_opcode == MEM_WB)
		 begin
		    /* CACHE writeback-through: r_store_data is the latest (L1D dirty)
		     * line. Write it straight to DRAM; if L2 also holds the line, drop
		     * the now-stale L2 copy. Reuse UNCACHE_STORE to wait for the DRAM
		     * ack, then ack the L1. */
		    n_mem_req_store_data = r_store_data;
		    n_addr = r_saveaddr;
		    n_mem_opcode = 5'd7;
		    n_store_mask = 16'hffff;
		    n_mem_req = 1'b1;
		    if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
		      end
		    n_state = UNCACHE_STORE;
		 end
	       else if(w_hit)
		 begin
		    n_reload = 1'b0;
		    if(r_opcode == 5'd4)
		      begin
			 n_rsp_data =  w_d0;
			 n_state = IDLE;
			 n_rsp_valid = 1'b1;
			 //n_cache_hits = r_cache_hits + 64'd1;			 
		      end
		    else if(r_opcode == 5'd7)
		      begin
			 t_wr_dirty = 1'b1;
			 t_dirty = 1'b1;
			 n_state = WAIT_STORE_IDLE;
			 //n_cache_hits = r_cache_hits + 64'd1;			 
			 t_d0 = r_store_data;
			 t_wr_d0 = 1'b1;
		      end
		 end
	       else
		 begin
		    n_cache_hits = r_cache_hits - 64'd1;
		    /* Evict the resident line only if it is BOTH valid and dirty
		     * (w_need_wb). A bare w_dirty test wrote back lines that a prior
		     * MEM_WB left valid=0/dirty=1 (MEM_WB clears valid but not dirty,
		     * unlike MEM_INVL) -> a stale copy clobbered the SCSI-DMA descriptor
		     * in DRAM (armed {08398f80,0x40} regressed to {883e4800,0}) -> IRIX
		     * XFS panic. The CLEAN_RELOAD fill site already defends the same leak. */
`ifdef ENABLE_L2_EVICT_BACKINV
		    /* PARKED 2026-08-10: derails IRIX to PC 0 @127M cycles, BEFORE any
		     * DMA, so it is not a coherence issue -- back-invalidating on
		     * eviction alone corrupts.  Disproven so far: out-of-band DRAM write
		     * (fixed by merge, still fails), store mask (RAM has no byte enable),
		     * write-ordering vs in-flight ops (quiescence gate -> bit-identical
		     * failure).  UNCHECKED: whether the merged line's dirty bit survives
		     * the restart -- if not, the eviction skips the writeback and drops
		     * the recovered data.  Also pathological here: ~1 back-invalidate per
		     * 55 cycles because the L1D index bits are a strict subset of a
		     * direct-mapped L2's, so nearly every L2 miss evicts a line an L1
		     * holds.  Revisit with a larger/set-associative L2. */
		    if(w_valid & (w_l1d_pres | w_l1i_pres) & ~r_bi_done)
		      begin
			 /* INCLUSION: an L1 still holds the line we are about to evict.
			  * Recover it BEFORE the eviction rather than after, so a dirty
			  * L1D copy is merged into the L2 -- the coherence point -- and
			  * leaves on the normal writeback below.  Blocking here is safe
			  * now that the L1D snoop engine can ack from any state. */
			 n_backinv_addr = {w_tag, t_idx, 4'd0};
			 n_backinv_d = w_l1d_pres;
			 n_backinv_i = w_l1i_pres;
			 n_state = BACKINV_WAIT;
		      end
		    else
`endif
		    if(w_need_wb)
		      begin
			 n_mem_req_store_data = w_d0;
			 n_addr = {w_tag, t_idx, 4'd0};
			 n_mem_opcode = 5'd7;
			 n_store_mask = 16'hffff;
			 
			 n_mem_req = 1'b1;
			 n_got_mem_rsp_valid = 1'b0;			 
			 n_state = DIRTY_STORE;			 
		      end
		    else //invalid or clean
		      begin
`ifdef VERILATOR
			 if(r_reload)
			   $stop();
`endif
			 n_reload = 1'b1;
			 n_state = CLEAN_RELOAD;
			 n_mem_opcode = 5'd4; //load
			 n_store_mask = 16'hffff;			 
			 n_mem_req = 1'b1;
			 n_got_mem_rsp_valid = 1'b0;			 
		      end
		 end
	       if(n_state != BACKINV_WAIT)
		 begin
		    n_bi_done = 1'b0;
		 end
	    end // case: CHECK_VALID_AND_TAG
`ifdef ENABLE_L2_INCLUSION
	  BACKINV_WAIT:
	    begin
	       if(backinv_d_ack)
		 begin
		    n_backinv_d = 1'b0;
		    if(backinv_d_dirty)
		      begin
			 /* MERGE: the L1D held the only up-to-date copy.  Write it into
			  * the L2 line and mark it dirty so the eviction writeback below
			  * carries it.  The previous design pushed this straight to DRAM
			  * while the L2 had already dropped the line, which opened a
			  * window where a reader missed both caches, read stale DRAM, and
			  * later wrote it back -- losing the update (IRIX "init died"). */
			 t_d0 = backinv_d_data;
			 t_wr_d0 = 1'b1;
			 t_wr_dirty = 1'b1;
			 t_dirty = 1'b1;
		      end
		 end
	       if(backinv_i_ack)
		 begin
		    n_backinv_i = 1'b0;
		 end
	       if((~r_backinv_d | backinv_d_ack) & (~r_backinv_i | backinv_i_ack))
		 begin
		    t_pres_clr = 1'b1;    /* no L1 holds it now */
		    n_bi_done = 1'b1;     /* and do not do this again for this victim */
		    n_state = WAIT_FOR_RAM;
		 end
	    end // case: BACKINV_WAIT
`endif
	  DIRTY_STORE:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;		    
		 end
	       if(mem_rsp_valid)
		 begin
		    n_addr = r_saveaddr;
		    n_mem_opcode = 5'd4; //load
		    n_store_mask = 16'hffff;
		    n_state = STORE_TURNAROUND;
		    n_mem_req = 1'b0;		    
		 end
	    end // case: DIRTY_STORE
	  STORE_TURNAROUND:
	    begin
	       n_state = CLEAN_RELOAD;
	       n_reload = 1'b1;
	       n_mem_req = 1'b1;
	       n_got_mem_rsp_valid = 1'b0;		       
	    end
	  CLEAN_RELOAD:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;
		 end
	       if(mem_rsp_valid)
		 begin
		    n_mem_req = 1'b0;
		    t_valid = 1'b1;
		    t_wr_valid = 1'b1;
		    /* a clean DRAM fill MUST be marked NOT-dirty: otherwise a stale
		     * dirty bit (left over from a prior invalidate/eviction that cleared
		     * valid but not dirty) rides into the reloaded line and later writes
		     * back garbage over a DMA'd buffer (the SCSI INQUIRY clobber). */
		    t_dirty = 1'b0;
		    t_wr_dirty = 1'b1;
		    t_wr_tag = 1'b1;
		    t_wr_d0 = 1'b1;
		    n_state = WAIT_CLEAN_RELOAD;
		 end
	    end // case: CLEAN_RELOAD
	  WAIT_CLEAN_RELOAD: /* need a cycle to turn around */
	    begin
	       n_state = WAIT_FOR_RAM;
	    end
	  WAIT_STORE_IDLE:
	    begin
	       n_state = IDLE;
	    end
	  FLUSH_WAIT:
	    begin
	       n_state = FLUSH_TRIAGE;
	       t_valid = 1'b0;
	       t_dirty = 1'b0;
	       t_wr_valid = 1'b1;
	       t_wr_dirty = 1'b1;
	    end
	  FLUSH_TRIAGE:
	    begin
	       //$display("r_idx = %d, w_need_wb %b", r_idx, w_need_wb);
	       
	       if(w_need_wb)
		 begin
		    n_mem_req_store_data = w_d0;
		    n_addr = {w_tag, t_idx, 4'd0};
		    n_mem_opcode = 5'd7; 
		    n_mem_req = 1'b1;
		    n_got_mem_rsp_valid = 1'b0;			 
		    n_state = FLUSH_STORE;
		 end
	       else
		 begin
		    t_idx = r_idx + 'd1;
		    if(r_idx == (L2_LINES-1))
		      begin
			 n_state = IDLE;
			 //$display("L2 flush complete at cycle %d", r_cycle);
			 n_flush_complete = 1'b1;
			 n_flush_req = 1'b0;
		      end
		    else
		      begin
			 n_state = FLUSH_WAIT;
		      end
		 end
	    end // case: FLUSH_TRIAGE
	  FLUSH_STORE:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;		    
		 end
	       
	       if(mem_rsp_valid)
		 begin
		    n_mem_req = 1'b0;
		    t_idx = r_idx + 'd1;
		    if(r_idx == (L2_LINES-1))
		      begin
			 n_state = IDLE;
			 //$display("L2 flush complete at cycle %d", r_cycle);
			 n_flush_complete = 1'b1;
			 n_flush_req = 1'b0;
		      end
		    else
		      begin
			 n_state = FLUSH_WAIT;
		      end		    
		 end
	    end // case: FLUSH_STORE
`ifdef ENABLE_L2_INCLUSION
	  BACKINV_WB:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;
		 end
	       if(mem_rsp_valid)
		 begin
		    n_mem_req = 1'b0;
		    n_wb_pend = 1'b0;
		    n_state = IDLE;
		 end
	    end // case: BACKINV_WB
`endif
	  UNCACHE_STORE:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;
		 end	       
	       if(mem_rsp_valid)
		 begin
		    n_state = IDLE;
		    n_rsp_valid = 1'b1;
		    n_mem_req = 1'b0;		    
		 end
	    end
	  UNCACHE_LOAD:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;
		 end	       
	       if(mem_rsp_valid)
		 begin
		    n_rsp_valid = 1'b1;
		    n_rsp_data = mem_rsp_load_data;
		    n_state = IDLE;
		    n_mem_req = 1'b0;
		 end
	    end

	  UNCACHE_WB_DRAIN:
	    begin
	       if(mem_req_ack)
		 n_mem_req = 1'b0;
	       if(mem_rsp_valid)
		 begin
		    /* writeback done: drop mem_req for a turnaround cycle so the AXI
		     * master's WAIT state can fall back to IDLE before we issue the
		     * uncached store/load (it gates WAIT->IDLE on mem_req dropping).
		     * Without the gap the back-to-back req deadlocks the AXI WAIT. */
		    n_mem_req = 1'b0;
		    n_got_mem_rsp_valid = 1'b0;
		    n_state = UNCACHE_WB_TURNAROUND;
		 end
	    end
	  UNCACHE_WB_TURNAROUND:
	    begin
	       /* the mem_req turnaround gap is now satisfied. */
	       if(r_opcode == MEM_INVL)
		 begin
		    /* dirty-INVL writeback drained -- just ack the L1 (no uncached op
		     * follows the invalidate). */
		    n_state = IDLE;
		    n_rsp_valid = 1'b1;
		 end
	       else
		 begin
		    /* re-issue the uncached op that the dirty-evict writeback preceded */
		    n_addr = r_saveaddr;
		    n_mem_opcode = r_opcode;
		    n_store_mask = r_uncache_mask;
		    n_mem_req_store_data = r_store_data;
		    n_mem_req = 1'b1;
		    n_state = (r_opcode == 5'd7) ? UNCACHE_STORE : UNCACHE_LOAD;
		 end
	    end
	  default:
	    begin
	    end
	endcase
     end

`ifdef DESC_TRACE
   // TEMP sim-only trace: the IRIX t1/L0 INQUIRY descriptor page (PA 0x0841d000).
   // Gated behind DESC_TRACE (was always-on under VERILATOR and spammed the boot).
   always_ff @(posedge clk) begin
      if(l1_mem_req_valid & (l1_mem_req_addr[35:12] == 24'h00841d))
        $display("[desc l1->l2] op=%2d addr=%09x data=%08x", l1_mem_req_opcode,
                 l1_mem_req_addr, l1_mem_req_store_data[31:0]);
      if(mem_req_valid & (mem_req_addr[35:12] == 24'h00841d))
        $display("[desc l2->dram] op=%2d addr=%09x data=%08x", mem_req_opcode,
                 mem_req_addr, mem_req_store_data[31:0]);
   end
`endif
endmodule
