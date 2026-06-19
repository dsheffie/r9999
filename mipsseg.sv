`include "machine.vh"

module mipsseg(v_addr, l_addr, cache, mapped, seg, bad_perms,
	       in_kernel_mode,
	       in_supervisor_mode,
	       in_user_mode,
	       in_64b_kernel_mode,
	       in_64b_supervisor_mode,
	       in_64b_user_mode);
   input  logic [`M_WIDTH-1:0] v_addr;
   output logic [`M_WIDTH-1:0] l_addr;
   output logic		       cache;
   output logic	       mapped;
   output logic [1:0]  seg;
   /* access-level violation -> AdEL/AdES: the current mode may not touch this
    * segment.  kernel: all OK; user: useg only; supervisor: useg + sseg. */
   output logic	       bad_perms;
   input logic			in_kernel_mode;
   input logic			in_supervisor_mode;
   input logic			in_user_mode;
   input logic			in_64b_kernel_mode;
   input logic			in_64b_supervisor_mode;
   input logic			in_64b_user_mode;

   wire [3:0]	       w_seg = v_addr[31:28];

   localparam	       ZP = `M_WIDTH-29;

   wire w_in_64b_mode;
   generate
      if(`M_WIDTH==64)
	begin
	   assign w_in_64b_mode = in_64b_kernel_mode |
				  in_64b_supervisor_mode |
				  in_64b_user_mode;
	end
      else
	begin
	   assign w_in_64b_mode = 1'b0;
	end
   endgenerate

   /* supervisor segment (sseg): 32b/compat 0xC0000000-0xDFFFFFFF (cksseg),
    * 64b xsseg VA[63:62]==01.  Used only for the supervisor access-level check. */
   wire w_compat32 = (`M_WIDTH < 64) || !w_in_64b_mode || (v_addr[63:32] == 32'hFFFF_FFFF);
   wire w_is_sseg  = w_compat32 ? (v_addr[31:29] == 3'b110)
				: ((`M_WIDTH == 64) && (v_addr[63:62] == 2'b01));

   always_comb
     begin
	cache  = 1'b0;
	mapped = 1'b0;
	seg    = 2'd0;
	l_addr = v_addr;

	if(`M_WIDTH == 64 && w_in_64b_mode && v_addr[63:62] == 2'b10)
	  begin /* xkphys: unmapped, PA = v_addr[58:0], cached iff CCA==3 */
	     mapped = 1'b0;
	     cache  = (v_addr[61:59] == 3'b011);
	     l_addr = {5'b0, v_addr[58:0]};
	     seg    = 2'd0;
	  end
	else if(`M_WIDTH < 64 || !w_in_64b_mode || v_addr[63:32] == 32'hFFFF_FFFF)
	  begin
	     /* 32-bit compat (or 32-bit mode, or sign-extended 64b address) */
	     if(w_seg[3] == 1'b0)
	       begin /* kuseg */
		  cache = 1'b1;
		  mapped = 1'b1;
		  l_addr = v_addr;
		  seg = 'd3;
	       end
	     else if(w_seg[3:1] == 3'b100)
	       begin /* kseg0 */
		  mapped = 1'b0;
		  cache = 1'b1;
		  l_addr = {{ZP{1'b0}}, v_addr[28:0]};
		  seg = 'd0;
	       end
	     else if(w_seg[3:1] == 3'b101)
	       begin /* kseg1 */
		  mapped = 1'b0;
		  cache = 1'b0;
		  l_addr = {{ZP{1'b0}}, v_addr[28:0]};
		  seg = 'd1;
	       end
	     else
	       begin /* kseg2 */
		  mapped = 1'b1;
		  cache = 1'b0;
		  l_addr = v_addr;
		  seg = 'd2;
	       end
	  end
	else if(`M_WIDTH == 64 && v_addr[63:62] == 2'b00)
	  begin /* xkuseg: TLB mapped, cached */
	     cache  = 1'b1;
	     mapped = 1'b1;
	     l_addr = v_addr;
	     seg    = 2'd3;
	  end
	else
	  begin /* xkseg: TLB mapped, uncached */
	     mapped = 1'b1;
	     cache  = 1'b0;
	     l_addr = v_addr;
	     seg    = 2'd2;
	  end

	/* access-level AdEL/AdES: seg==3 is the user segment (useg/xkuseg).
	 * kernel may touch anything; user only useg; supervisor useg + sseg. */
	bad_perms = 1'b0;
	if(in_user_mode)
	  bad_perms = (seg != 2'd3);
	else if(in_supervisor_mode)
	  bad_perms = ~((seg == 2'd3) | w_is_sseg);
     end // always_comb

endmodule
