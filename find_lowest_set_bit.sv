// find_lowest_set_bit -- priority encoder returning the index of the LOWEST
// set bit of `in` (bit 0 = highest priority), or N (== 1<<LG_N) when `in` is 0.
//
// History: this was `find_first_set`, which -- despite the name -- scanned MSB
// -> LSB and returned the HIGHEST set bit (both the LG_N==2 base case and the
// recursive tree preferred the high half).  "first" was ambiguous; every real
// consumer (free-list allocators, scheduler select, and critically the TLB
// match) wants a deterministic LOWEST-index result.  A duplicate TLB entry is
// the one case where highest-vs-lowest is observable: the old high-priority
// pick disagreed with the golden ISS (and IRIX's software), which select the
// lowest matching entry -- the IRIX o32 TLB-Modify loop / SIGSEGV.  Renamed and
// flipped to true LSB priority; see tests/tlbmod/test_tlb_dup.S.
module find_lowest_set_bit#(parameter LG_N = 2)(in, y);
   localparam N = 1<<LG_N;
   localparam N2 = 1<<(LG_N-1);
   input logic [N-1:0] in;
   output logic [LG_N:0] y;

   logic [LG_N-1:0] 	 t0, t1;
   wire 		 lo_z = in[N2-1:0]=='d0;
   wire 		 hi_z = in[N-1:N2]=='d0;

   generate
      if(LG_N == 2)
	begin
	   always_comb
	     begin
		y = 3'b111;
		casez(in)
		  4'b???1:
		    y = 3'd0;
		  4'b??10:
		    y = 3'd1;
		  4'b?100:
		    y = 3'd2;
		  4'b1000:
		    y = 3'd3;
		  default:
		    y = 3'b111;
		endcase // casez (in)
	     end // always_comb
	end // if (LG_N == 2)
      else
	begin
	   find_lowest_set_bit#(LG_N-1) f0(.in(in[N2-1:0]), .y(t0));
	   find_lowest_set_bit#(LG_N-1) f1(.in(in[N-1:N2]), .y(t1));
	   always_comb
	     begin
		y = N;
		if(lo_z && hi_z)
		  y = N;
		else if(!lo_z)
		  y = {1'b0, t0};
		else
		  y = N2 + t1;
	     end
	end
   endgenerate
endmodule // find_lowest_set_bit
