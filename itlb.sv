`include "rob.vh"
`include "machine.vh"

/* DPI imports (have_ckpt_t / loadtlb) are declared in tlb.sv -- same compilation
 * unit, so itlb reuses them (re-importing would be a duplicate declaration). */

module itlb(clk,
	   reset,
	   asid,	   

	   active,
	   req,
	   va,
	   pa,
	   hit,
	   hit_index,
	   dirty,
	   valid,
	   cache_attr,
	   out_of_range,
	   tlb_entry_in_valid,
	   tlb_entry_in,
	   install_en,
	   ufast_hit,
	   ufast_pa,
	   ufast_valid);
   
   input logic clk;
   input logic reset;
   input [7:0] asid;
   

   input logic active;
   input logic req;

   input logic [`M_WIDTH-1:0] va;
   output logic [`PA_WIDTH-1:0] pa;
   
   output logic	       hit;
   output logic [5:0]  hit_index;
   
   output logic	       dirty;
   output logic	       valid;
   /* matched page's cacheability (EntryLo C[5:3], MIPS CCA): the consumer treats
    * CCA==3 (cacheable noncoherent) as cached, everything else as uncached. */
   output logic [2:0]  cache_attr;
   /* PA out-of-range is now enforced BY CONSTRUCTION: pfn is PFN_WIDTH = PA_WIDTH-12
    * bits, so PA = {pfn, va[11:0]} is exactly PA_WIDTH and can never exceed MAX_PA.
    * Kept (tied 0) for the consumer's port; the l1d bad_addr-from-oor path is dead. */
   output logic	       out_of_range;
   /* MICRO-TLB v1 (ALWAYS-MISS): every lookup goes to the 48-way JTLB, which is
    * split into 2 cycles (register w_hits) so its CAM sits in its own cycle and
    * meets timing.  pa/hit therefore land ONE cycle later than the old 1-cycle
    * tlb; l1i's WAIT_FOR_TLB holds the fetch that extra cycle (via a registered
    * wait counter -- a combinational `busy` output would form a comb loop through
    * mipsseg->itlb->n_cache_pc).  Step 2 will add real micro-TLB entries so hits
    * skip the wait. */

   input logic	       tlb_entry_in_valid;
   input 	       tlb_data_t tlb_entry_in;

   /* micro-ITLB (Step 2) fast path: install_en pulses when the 48-way prime lands a
    * hit (driven by l1i); ufast_* are the combinational 1-cycle micro-TLB lookup. */
   input logic	       install_en;
   output logic	       ufast_hit;
   output logic [`PA_WIDTH-1:0] ufast_pa;
   output logic	       ufast_valid;
   
   /* bits 39 down to 12 */

   parameter	       ISIDE = 0;
   localparam	       N = `N_TLB_ENTRIES;
   
   localparam	       LG_N = $clog2(N);
   localparam	       NN = 1 << LG_N;
   

   
   wire [NN-1:0]	       w_hits4k, w_hits64k, w_hits2m, w_hits1g;
   wire [NN-1:0]	       w_hits;


   tlb_stored_t r_tlb[N-1:0];   /* stored type: no `entry` (the array index IS the entry) */
   /* per-slot "written by TLBWR/TLBWI" bit: a slot is matchable once software has
    * written it, NOT when (v0|v1).  Using v0|v1 in the match wrongly excluded a
    * refill-installed both-pages-invalid entry (page-not-present), so the retry
    * re-refilled forever instead of taking TLB-Invalid -> do_page_fault (the
    * userspace demand-paging livelock).  reset clears it so unwritten slots never
    * match; the selected page's v0/v1 still drives `valid` (the Invalid exception). */
   logic [N-1:0] r_tlb_written;
   integer ri;

   wire [NN-1:0]	       w_addr_space_match;
   wire [NN-1:0]	       w_hit8k;

   /* Reset the per-entry valid bits so a power-up/soft-reset TLB holds no
    * matchable entries (rv64core resets r_valid the same way).  Without this,
    * un-reset entries can be selected by the 19-bit VPN match below. */
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
`ifdef VERILATOR
	     if(have_ckpt_t() != 0)
	       begin : ckpt_tlb
		  logic [63:0] ehi, elo0, elo1, pm;
		  for(ri = 0; ri < N; ri = ri + 1)
		    begin
		       ehi  = loadtlb(ri, 0);  elo0 = loadtlb(ri, 1);
		       elo1 = loadtlb(ri, 2);  pm   = loadtlb(ri, 3);
		       r_tlb_written[ri] <= 1'b1;
		       r_tlb[ri].pagemask <= pm[11:0];
		       r_tlb[ri].asid     <= ehi[7:0];
		       r_tlb[ri].r        <= ehi[63:62];
		       r_tlb[ri].vpn      <= ehi[39:13];
		       r_tlb[ri].g0       <= elo0[0];  r_tlb[ri].v0 <= elo0[1];
		       r_tlb[ri].d0       <= elo0[2];  r_tlb[ri].c0 <= elo0[5:3];
		       r_tlb[ri].pfn0     <= elo0[(`PFN_WIDTH+5):6];
		       r_tlb[ri].g1       <= elo1[0];  r_tlb[ri].v1 <= elo1[1];
		       r_tlb[ri].d1       <= elo1[2];  r_tlb[ri].c1 <= elo1[5:3];
		       r_tlb[ri].pfn1     <= elo1[(`PFN_WIDTH+5):6];
		    end
	       end
	     else
	       begin
`endif
	     r_tlb_written <= '0;
	     for(ri = 0; ri < N; ri = ri + 1)
	       begin
		  r_tlb[ri].v0 <= 1'b0;
		  r_tlb[ri].v1 <= 1'b0;
	       end
`ifdef VERILATOR
	       end
`endif
	  end
	else if(tlb_entry_in_valid)
	  begin
	     r_tlb_written[tlb_entry_in.entry] <= 1'b1;
	     /* copy the stored fields (everything except the entry write-index) */
	     r_tlb[tlb_entry_in.entry].pagemask <= tlb_entry_in.pagemask;
	     r_tlb[tlb_entry_in.entry].asid     <= tlb_entry_in.asid;
	     r_tlb[tlb_entry_in.entry].r        <= tlb_entry_in.r;
	     r_tlb[tlb_entry_in.entry].vpn      <= tlb_entry_in.vpn;
	     r_tlb[tlb_entry_in.entry].pfn0     <= tlb_entry_in.pfn0;
	     r_tlb[tlb_entry_in.entry].d0       <= tlb_entry_in.d0;
	     r_tlb[tlb_entry_in.entry].v0       <= tlb_entry_in.v0;
	     r_tlb[tlb_entry_in.entry].g0       <= tlb_entry_in.g0;
	     r_tlb[tlb_entry_in.entry].c0       <= tlb_entry_in.c0;
	     r_tlb[tlb_entry_in.entry].pfn1     <= tlb_entry_in.pfn1;
	     r_tlb[tlb_entry_in.entry].d1       <= tlb_entry_in.d1;
	     r_tlb[tlb_entry_in.entry].v1       <= tlb_entry_in.v1;
	     r_tlb[tlb_entry_in.entry].g1       <= tlb_entry_in.g1;
	     r_tlb[tlb_entry_in.entry].c1       <= tlb_entry_in.c1;
	  end
     end

`ifdef ENABLE_STORE_CHECK
   /* Co-sim TLB mirror: on every runtime TLB write (TLBWI/TLBWR), hand the installed
    * entry to the golden ISS (henry_tb) already packed into the ISS's CP0 bit layout --
    * EntryHi[63:62]=R,[39:13]=VPN2,[7:0]=ASID; EntryLo[33:6]=PFN,[5:3]=C,[2]=D,[1]=V,[0]=G.
    * Keeps the ISS's 48-entry TLB bit-identical to the RTL's (see iss_apply_tlb_write). */
   import "DPI-C" function void tlb_wr_log(input int entry, input longint ehi,
					   input longint elo0, input longint elo1, input int pm);
   always_ff @(negedge clk)
     if(tlb_entry_in_valid)
       tlb_wr_log(int'(tlb_entry_in.entry),
		  (longint'(tlb_entry_in.r)  << 62) | (longint'(tlb_entry_in.vpn) << 13) | longint'(tlb_entry_in.asid),
		  (longint'(tlb_entry_in.pfn0) << 6) | (longint'(tlb_entry_in.c0) << 3) | (longint'(tlb_entry_in.d0) << 2) | (longint'(tlb_entry_in.v0) << 1) | longint'(tlb_entry_in.g0),
		  (longint'(tlb_entry_in.pfn1) << 6) | (longint'(tlb_entry_in.c1) << 3) | (longint'(tlb_entry_in.d1) << 2) | (longint'(tlb_entry_in.v1) << 1) | longint'(tlb_entry_in.g1),
		  int'(tlb_entry_in.pagemask));
`endif

   wire [LG_N:0]	       w_idx;
   generate
      for(genvar i = N; i < NN; i=i+1)
	begin
	   assign w_addr_space_match[i] = 1'b0;
	   assign w_hit8k[i] = 1'b0;
	   assign w_hits[i] = 1'b0;
	end
   endgenerate
   
   
   generate
      for(genvar i = 0; i < N; i=i+1)
	begin : hits
	   assign w_addr_space_match[i] = (r_tlb[i].asid == asid) | (r_tlb[i].g0 & r_tlb[i].g1);
	   /* Sail tlbEntryMatch / tlbSearch (sail-cheri-mips mips/mips_tlb.sail):
	    * UNCONDITIONAL full match -- r = va[63:62], vpn2 = va[39:13], and the
	    * entry hits iff (r == entryR) & (vpn2 == entryVPN).  No mode switch and R
	    * is ALWAYS compared (the spec has no 32-bit low-19 shortcut).  exec.sv
	    * writes EntryHi.R/VPN2 from the full GPR (also per Sail MTC0), so this is
	    * self-consistent.  Validated: Sail-aligned interp_mips boots IRIX clean
	    * with identical EntryHi storage.  (The old KX-gated low-19 arm aliased the
	    * kptbl walk -- which runs at KX=0 -- causing the intermittent tlbmiss panic.) */
	   assign w_hit8k[i] = (r_tlb[i].vpn[26:0] == va[39:13]) & (r_tlb[i].r == va[63:62]);
	   /* Match a slot once it has been WRITTEN by software (TLBWR/TLBWI), not when
	    * (v0|v1).  An entry whose pages are both invalid (a refill for a not-yet-
	    * present page) must still match so the access takes TLB-Invalid ->
	    * do_page_fault; the old (v0|v1) guard excluded it and the refill looped
	    * forever.  Reset clears r_tlb_written so unwritten slots never match.  The
	    * selected page's own v0/v1 still drives `valid` (the Invalid exception). */
	   assign w_hits[i] = w_addr_space_match[i] & w_hit8k[i] & r_tlb_written[i];
	end
   endgenerate
   
   
   //wire [63:0] w_pa_sel = 
   //(r_pgsize[w_idx[LG_N-1:0]] == 2'd0) ? {r_pa_data[w_idx[LG_N-1:0]][51:18], va[29:0]} :
   //	       (r_pgsize[w_idx[LG_N-1:0]] == 2'd1) ? {r_pa_data[w_idx[LG_N-1:0]][51:9], va[20:0]} :
   //	       (r_pgsize[w_idx[LG_N-1:0]] == 2'd2) ? {r_pa_data[w_idx[LG_N-1:0]], va[11:0]} :
   //	       {r_pa_data[w_idx[LG_N-1:0]][51:4], va[15:0]};
	       
	       	          
   /* --- 2-cycle split: register the 48-way match so the CAM compare is its own
    *     cycle; the FFS + PFN mux + output flop run the next cycle.  This is the
    *     timing win (isolate the fully-associative CAM cone into its own path). --- */
   logic [NN-1:0] r_hits;
   always_ff@(posedge clk) r_hits <= reset ? '0 : w_hits;

   find_first_set#(.LG_N(LG_N))
   ffs(.in(r_hits),
       .y(w_idx));

   wire [LG_N-1:0]     w_hit_idx = w_idx[LG_N-1:0];
   /* VA[12]=0 → even page (pfn0/d0/v0), VA[12]=1 → odd page (pfn1/d1/v1) */
   wire                w_odd     = va[12];
   wire [`PFN_WIDTH-1:0] w_pfn   = w_odd ? r_tlb[w_hit_idx].pfn1 : r_tlb[w_hit_idx].pfn0;
   wire                w_dirty   = w_odd ? r_tlb[w_hit_idx].d1   : r_tlb[w_hit_idx].d0;
   wire                w_valid   = w_odd ? r_tlb[w_hit_idx].v1   : r_tlb[w_hit_idx].v0;
   wire [2:0]          w_cache   = w_odd ? r_tlb[w_hit_idx].c1   : r_tlb[w_hit_idx].c0;
   /* 4KB page only (pagemask=0): PA[39:12]=pfn[27:0], PA[11:0]=va[11:0] */
   wire [`PFN_WIDTH+11:0] w_pa4k_full = {w_pfn, va[11:0]};   /* = PA_WIDTH bits exactly */
   wire [`PA_WIDTH-1:0] w_pa4k = w_pa4k_full[`PA_WIDTH-1:0];

   always_ff@(posedge clk)
     begin
	hit     <= reset ? 1'b0 : (active ? (req & |r_hits) : 1'b1);
	hit_index <= reset ? 'd0 : w_hit_idx;
	dirty   <= reset ? 1'b0 : (active ? w_dirty : 1'b1);
	valid <= reset ? 1'b0 : (active ? w_valid : 1'b1);
	/* unmapped (active=0) cacheability is decided by segment, not the TLB;
	 * default to CCA==3 (cached) -- the l1d consumer ignores it when unmapped. */
	cache_attr <= reset ? 3'd3 : (active ? w_cache : 3'd3);
	pa      <= active ? w_pa4k : va[`PA_WIDTH-1:0];
	/* PA can't exceed MAX_PA now (pfn is exactly PA_WIDTH-12 wide) -> always 0 */
	out_of_range <= 1'b0;
     end

   /* ===== micro-ITLB (Step 2): small fully-assoc cache in front of the 48-way =====
    * A NU-entry translation cache; a hit gives the PA combinationally (1 cycle) so
    * l1i skips WAIT_FOR_TLB.  A miss falls to the 2-cycle 48-way, whose result l1i
    * re-installs here (install_en) with LFSR-random replacement.  Flushed wholesale
    * on any JTLB write (tlb_entry_in_valid = TLBWR/TLBWI) or ASID change -- the same
    * events that could stale an entry (the match below uses ASID, mirroring the
    * 48-way w_addr_space_match & w_hit8k exactly). */
   localparam NU    = `N_UITLB_ENTRIES;
   localparam LG_NU = $clog2(NU);

   logic [26:0]           r_u_vpn  [NU-1:0];
   logic [1:0]            r_u_r    [NU-1:0];
   logic [7:0]            r_u_asid [NU-1:0];
   logic                  r_u_g    [NU-1:0];
   logic [`PFN_WIDTH-1:0] r_u_pfn0 [NU-1:0], r_u_pfn1 [NU-1:0];
   logic                  r_u_v0   [NU-1:0], r_u_v1   [NU-1:0];
   logic [NU-1:0]         r_u_valid;
   integer 		  uu;

   /* xorshift-8 LFSR (maximal, taps 8,6,5,4) -> pseudo-random replacement slot */
   logic [7:0] 		  r_u_lfsr;
   wire [LG_NU-1:0] 	  w_u_repl = r_u_lfsr[LG_NU-1:0];

   /* ASID-change detect -> flush (the match uses ASID) */
   logic [7:0] 		  r_u_asid_seen;
   wire 		  w_u_asid_change = (r_u_asid_seen != asid);
   wire 		  w_u_flush = tlb_entry_in_valid | w_u_asid_change;

   /* combinational match -- mirrors the 48-way (w_addr_space_match & w_hit8k) */
   wire [NU-1:0] 	  w_u_hits;
   generate
      for(genvar u = 0; u < NU; u = u + 1)
	begin : u_hits
	   assign w_u_hits[u] = r_u_valid[u]
	                        & (r_u_vpn[u] == va[39:13])
	                        & (r_u_r[u]   == va[63:62])
	                        & ((r_u_asid[u] == asid) | r_u_g[u]);
	end
   endgenerate
   wire 		  w_u_any = |w_u_hits;

   /* one-hot select the matched entry's per-page fields */
   logic [`PFN_WIDTH-1:0] t_u_pfn0, t_u_pfn1;
   logic 		  t_u_v0, t_u_v1;
   always_comb
     begin
	t_u_pfn0 = '0;
	t_u_pfn1 = '0;
	t_u_v0   = 1'b0;
	t_u_v1   = 1'b0;
	for(uu = 0; uu < NU; uu = uu + 1)
	  begin
	     if(w_u_hits[uu])
	       begin
		  t_u_pfn0 = r_u_pfn0[uu];
		  t_u_pfn1 = r_u_pfn1[uu];
		  t_u_v0   = r_u_v0[uu];
		  t_u_v1   = r_u_v1[uu];
	       end
	  end
     end // always_comb

   wire                   w_u_odd = va[12];
   wire [`PFN_WIDTH-1:0]  w_u_pfn = w_u_odd ? t_u_pfn1 : t_u_pfn0;
   wire [`PFN_WIDTH+11:0] w_u_pa_full = {w_u_pfn, va[11:0]};

   assign ufast_hit   = active & req & w_u_any;
   assign ufast_pa    = w_u_pa_full[`PA_WIDTH-1:0];
   assign ufast_valid = w_u_odd ? t_u_v1 : t_u_v0;

   always_ff@(posedge clk)
     begin
	r_u_asid_seen <= reset ? 8'd0 : asid;
	r_u_lfsr <= reset ? 8'h5a
	                  : {r_u_lfsr[6:0], r_u_lfsr[7]^r_u_lfsr[5]^r_u_lfsr[4]^r_u_lfsr[3]};
	if(reset | w_u_flush)
	  begin
	     r_u_valid <= '0;
	  end
	else if(install_en & hit)   /* 48-way prime landed a hit: cache r_tlb[hit_index] */
	  begin
	     r_u_vpn[w_u_repl]   <= r_tlb[hit_index].vpn[26:0];
	     r_u_r[w_u_repl]     <= r_tlb[hit_index].r;
	     r_u_asid[w_u_repl]  <= r_tlb[hit_index].asid;
	     r_u_g[w_u_repl]     <= r_tlb[hit_index].g0 & r_tlb[hit_index].g1;
	     r_u_pfn0[w_u_repl]  <= r_tlb[hit_index].pfn0;
	     r_u_pfn1[w_u_repl]  <= r_tlb[hit_index].pfn1;
	     r_u_v0[w_u_repl]    <= r_tlb[hit_index].v0;
	     r_u_v1[w_u_repl]    <= r_tlb[hit_index].v1;
	     r_u_valid[w_u_repl] <= 1'b1;
	  end
     end // always_ff


   

endmodule
   
   
