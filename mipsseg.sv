`include "machine.vh"

module mipsseg(v_addr, l_addr, cache, mapped, seg, bad_perms,
	       erl,
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
   /* SR.ERL: the user segment becomes a 2^31-byte unmapped, uncached window, PA = VA
    * (R4000 User's Manual, "User Mode Virtual Addressing" with ERL=1).  The IP24 PROM
    * sizes memory through it: kuseg 0x20000000 with ERL still set from reset.
    * Implemented for 32-bit addressing only (the 64-bit xkuseg case is not needed
    * by anything and would put a 33-bit compare on the AGU critical path). */
   input logic			erl;
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

   /* 32-bit addressing mode (KX/SX/UX clear for the current mode): the effective
    * address is the sign-extension of EA[31:0] (R4000 User's Manual).  The AGU adds
    * 64 bits, so a base built with lui of a bit-31-set constant plus a negative
    * offset (NT 3.1 ntdll: `lui 0x8000; lw -off` for the TEB at useg 0x7ffff4a8)
    * yields 0xffffffff_7ffff4a8 -- a useg address with hi32 set, which then missed
    * the user TLB entry (R/VPN2 compared in full, tlb.sv).  Re-sign-extending is a
    * no-op for well-formed addresses.  64-bit addressing is untouched. */
   wire [`M_WIDTH-1:0] w_va;
   generate
      if(`M_WIDTH==64)
	begin
	   assign w_va = w_in_64b_mode ? v_addr : {{32{v_addr[31]}}, v_addr[31:0]};
	end
      else
	begin
	   assign w_va = v_addr;
	end
   endgenerate

   /* supervisor segment (sseg): 32b/compat 0xC0000000-0xDFFFFFFF (cksseg),
    * 64b xsseg VA[63:62]==01.  Used only for the supervisor access-level check. */
   wire w_compat32 = (`M_WIDTH < 64) || !w_in_64b_mode || (w_va[63:32] == 32'hFFFF_FFFF);
   wire w_is_sseg  = w_compat32 ? (w_va[31:29] == 3'b110)
				: ((`M_WIDTH == 64) && (w_va[63:62] == 2'b01));

   /* VA out of range (Sail TLBTranslate MAX_VA): a MAPPED, non-compat 64b VA must
    * fit in SEGBITS, i.e. VA[61:`SEGBITS]==0, else AdEL/AdES.  compat = the sign-
    * extended 32b form (VA[61:31] all-1, e.g. ckseg/cksseg) is exempt; unmapped
    * segs skip this (they get the PA>MAX_PA check in tlb.sv). */
   wire w_va_oor = (`M_WIDTH == 64) && w_in_64b_mode &&
		   ~(&w_va[61:31]) && (|w_va[61:`SEGBITS]);

   always_comb
     begin
	cache  = 1'b0;
	mapped = 1'b0;
	seg    = 2'd0;
	l_addr = w_va;

	if(`M_WIDTH == 64 && w_in_64b_mode && w_va[63:62] == 2'b10)
	  begin /* xkphys: unmapped, PA = w_va[58:0], cached by CCA (machine.vh CCA_CACHED) */
	     mapped = 1'b0;
	     cache  = `CCA_CACHED(w_va[61:59]);
	     l_addr = {5'b0, w_va[58:0]};
	     seg    = 2'd0;
	  end
	else if(`M_WIDTH < 64 || !w_in_64b_mode || w_va[63:32] == 32'hFFFF_FFFF)
	  begin
	     /* 32-bit compat (or 32-bit mode, or sign-extended 64b address) */
	     if(w_seg[3] == 1'b0)
	       begin /* kuseg; with ERL unmapped + uncached, PA = VA.  w_va[63:31] is
		      * already 0 here, so ERL only clears the flags -- no new address
		      * mux on the AGU -> DTLB critical path. */
		  cache = ~erl;
		  mapped = ~erl;
		  l_addr = w_va;
		  seg = 'd3;
	       end
	     else if(w_seg[3:1] == 3'b100)
	       begin /* kseg0 */
		  mapped = 1'b0;
		  cache = 1'b1;
		  l_addr = {{ZP{1'b0}}, w_va[28:0]};
		  seg = 'd0;
	       end
	     else if(w_seg[3:1] == 3'b101)
	       begin /* kseg1 */
		  mapped = 1'b0;
		  cache = 1'b0;
		  l_addr = {{ZP{1'b0}}, w_va[28:0]};
		  seg = 'd1;
	       end
	     else
	       begin /* kseg2 */
		  mapped = 1'b1;
		  cache = 1'b0;
		  l_addr = w_va;
		  seg = 'd2;
	       end
	  end
	else if(`M_WIDTH == 64 && w_va[63:62] == 2'b00)
	  begin /* xkuseg: TLB mapped, cached */
	     cache  = 1'b1;
	     mapped = 1'b1;
	     l_addr = w_va;
	     seg    = 2'd3;
	  end
	else
	  begin /* xkseg: TLB mapped, uncached */
	     mapped = 1'b1;
	     cache  = 1'b0;
	     l_addr = w_va;
	     seg    = 2'd2;
	  end

	/* access-level AdEL/AdES: seg==3 is the user segment (useg/xkuseg).
	 * kernel may touch anything; user only useg; supervisor useg + sseg. */
	bad_perms = 1'b0;
	if(in_user_mode)
	  bad_perms = (seg != 2'd3);
	else if(in_supervisor_mode)
	  bad_perms = ~((seg == 2'd3) | w_is_sseg);
	/* VA-range AdEL is mode-independent (even kernel) -- applies to mapped segs. */
	bad_perms = bad_perms | (mapped & w_va_oor);
     end // always_comb

endmodule
