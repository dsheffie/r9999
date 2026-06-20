`include "rob.vh"
`include "machine.vh"

module tlb(clk,
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
	   tlb_entry_in);
   
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

   input logic	       tlb_entry_in_valid;
   input 	       tlb_data_t tlb_entry_in;
   
   /* bits 39 down to 12 */

   parameter	       ISIDE = 0;
   localparam	       N = 48;
   
   localparam	       LG_N = $clog2(N);
   localparam	       NN = 1 << LG_N;
   

   
   wire [NN-1:0]	       w_hits4k, w_hits64k, w_hits2m, w_hits1g;
   wire [NN-1:0]	       w_hits;


   tlb_stored_t r_tlb[47:0];   /* stored type: no `entry` (the array index IS the entry) */
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
	     for(ri = 0; ri < N; ri = ri + 1)
	       begin
		  r_tlb[ri].v0 <= 1'b0;
		  r_tlb[ri].v1 <= 1'b0;
	       end
	  end
	else if(tlb_entry_in_valid)
	  begin
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
	   /* exclude a pair with BOTH pages invalid (v0=v1=0): reset / tlbinit-filler
	    * entries must never be picked by find_first_set.  The selected page's own
	    * v0/v1 still drives `valid` (the TLB-Invalid exception) for a matched pair. */
	   assign w_hits[i] = w_addr_space_match[i] & w_hit8k[i] & (r_tlb[i].v0 | r_tlb[i].v1);
	end
   endgenerate
   
   
   //wire [63:0] w_pa_sel = 
   //(r_pgsize[w_idx[LG_N-1:0]] == 2'd0) ? {r_pa_data[w_idx[LG_N-1:0]][51:18], va[29:0]} :
   //	       (r_pgsize[w_idx[LG_N-1:0]] == 2'd1) ? {r_pa_data[w_idx[LG_N-1:0]][51:9], va[20:0]} :
   //	       (r_pgsize[w_idx[LG_N-1:0]] == 2'd2) ? {r_pa_data[w_idx[LG_N-1:0]], va[11:0]} :
   //	       {r_pa_data[w_idx[LG_N-1:0]][51:4], va[15:0]};
	       
	       	          
   find_first_set#(.LG_N(LG_N))
   ffs(.in(w_hits),
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
	hit     <= reset ? 1'b0 : (active ? (req & |w_hits) : 1'b1);
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


   

endmodule
   
   
