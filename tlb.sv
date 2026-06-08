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
	   writable,
	   tlb_entry_in_valid,
	   tlb_entry_in);
   
   input logic clk;
   input logic reset;
   input [7:0] asid;
   

   input logic active;
   input logic req;
   
   input logic [`M_WIDTH-1:0] va;
   output logic [`M_WIDTH-1:0] pa;
   
   output logic	       hit;
   output logic [5:0]  hit_index;
   
   output logic	       dirty;
   output logic	       writable;
        
   input logic	       tlb_entry_in_valid;
   input 	       tlb_data_t tlb_entry_in;
   
   /* bits 39 down to 12 */

   parameter	       ISIDE = 0;
   localparam	       N = 48;
   
   localparam	       LG_N = $clog2(N);
   localparam	       NN = 1 << LG_N;
   

   
   wire [NN-1:0]	       w_hits4k, w_hits64k, w_hits2m, w_hits1g;
   wire [NN-1:0]	       w_hits;


   tlb_data_t r_tlb[47:0];

   wire [NN-1:0]	       w_addr_space_match;
   wire [NN-1:0]	       w_hit8k;
   
   always_ff@(posedge clk)
     begin
	if(tlb_entry_in_valid)
	  begin
	     r_tlb[tlb_entry_in.entry] <= tlb_entry_in;
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
	   assign w_hit8k[i] = (r_tlb[i].vpn == va[39:13]) && (r_tlb[i].r == va[63:62]);
	   assign w_hits[i] = w_addr_space_match[i] & w_hit8k[i];
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
   wire [27:0]         w_pfn     = w_odd ? r_tlb[w_hit_idx].pfn1 : r_tlb[w_hit_idx].pfn0;
   wire                w_dirty   = w_odd ? r_tlb[w_hit_idx].d1   : r_tlb[w_hit_idx].d0;
   wire                w_valid   = w_odd ? r_tlb[w_hit_idx].v1   : r_tlb[w_hit_idx].v0;
   /* 4KB page only (pagemask=0): PA[39:12]=pfn[27:0], PA[11:0]=va[11:0] */
   wire [`PA_WIDTH-1:0] w_pa4k   = {w_pfn, va[11:0]};

   always_ff@(posedge clk)
     begin
	hit     <= reset ? 1'b0 : (active ? (req & |w_hits) : 1'b1);
	hit_index <= reset ? 'd0 : w_hit_idx;
	dirty   <= reset ? 1'b0 : w_dirty;
	writable <= reset ? 1'b0 : w_valid;
	pa      <= active ? {{(`M_WIDTH-`PA_WIDTH){1'b0}}, w_pa4k} : va;
     end


   

endmodule
   
   
