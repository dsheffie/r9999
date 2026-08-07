`include "machine.vh"

module predecode(insn_, pd);
   input logic [31:0] insn_;
   output logic [3:0] pd;

   logic [31:0]       insn;
   
   always_comb
     begin
	pd = 4'd0;
	insn = bswap32(insn_);
	case(insn[31:26])
	  6'd0: /* rtype */
	    begin
	       if(insn[5:0] == 6'd8) /* pdr */
		 begin
		    pd = (insn[25:21] == 5'd31) ? 4'd7 : 4'd4;
		 end
	       else if(insn[5:0] == 6'd9)
		 begin
		    pd = 4'd6;
		 end
	    end
	  6'd1:
	    begin
	       case(insn[20:16])
		 'd0:
		   begin
		      pd = 4'd1;
		   end
		 'd1:
		   begin
		      pd = 4'd1;
		   end
		 'd2:
		   begin
		      pd = 4'd2;
		   end
		 'd3:
		   begin
		      pd = 4'd2;
		   end
		 'd17:
		   begin
		      pd = 4'd9;
		   end
		 /* REGIMM branch-and-link family.  rt 16/18/19 were falling to `default`
		  * => pd=0, which l1i treats as "NOT control flow" (t_update_spec_hist =
		  * (t_pd != 4'd0); the cflow if-chain never matches 0).  So t_is_cflow,
		  * n_delay_slot and t_take_br all stayed 0 and the front end ran straight
		  * through a real branch, mispredicting it every time and never marking its
		  * delay slot -- while decode_mips.sv DID decode all four.  Measured on IRIX
		  * `be` (2026-08-06) via bgezall: the target's `addiu sp,sp,-112` prologue
		  * committed BEFORE the delay slot retired, the restart re-ran it, and sp
		  * ended one 112-byte frame low -> wrong stack slot -> wild deref.
		  *   rt 16 BLTZAL   rt 17 BGEZAL   rt 18 BLTZALL   rt 19 BGEZALL
		  * All four share pd=9.  The pd9 arm's "predict taken" shortcut keys on
		  * rs==$zero, which is only valid for the BGEZ-flavours (rs>=0 is always
		  * true); for the BLTZ-flavours rs<0 is never true when rs==$zero, so l1i
		  * gates that shortcut on rt bit0 (insn[16]: 1 = BGEZ-type, 0 = BLTZ-type). */
		 'd16:
		   begin
		      pd = 4'd9;
		   end
		 'd18:
		   begin
		      pd = 4'd9;
		   end
		 'd19:
		   begin
		      pd = 4'd9;
		   end
		 default:
		   begin
		   end
	       endcase // case (rt)	  
	    end
	  6'd2:
	    begin
	       pd = 4'd3;
	    end   
	  6'd3:
	    begin
	       pd = 4'd5;
	    end
	  6'd4:
	    begin
	       pd = ((insn[25:21] == 'd0) && (insn[20:16] == 'd0)) ? 4'd8 : 4'd1;
	    end
	  6'd5:
	    begin
	       pd = 4'd1;
	    end
	  6'd6:
	    begin
	       pd = 4'd1;
	    end
	  6'd7:
	    begin
	       pd = 4'd1;
	    end
	  6'd17:
	    begin
	       if(insn[25:21]==5'd8)
		 begin
		    case(insn[17:16])
		      2'b00: //bc1f
			begin
			   pd = 4'd1;
			end
		      2'b01: //bc1t
			begin
			   pd = 4'd1;
			end
		      2'b10: //bc1fl;
			begin
			   pd = 4'd2;
			end
		      2'b11: //bc1tl
			begin
			   pd = 4'd2;
			end	       
		    endcase // case (insn[17:16])
		 end // if (insn[25:21]==5'd8)
	    end
	  6'd20:
	    begin
	       pd = 4'd2;
	    end
	  6'd21:
	    begin
	       pd = 4'd2;
	    end
	  6'd22:
	    begin
	       pd = 4'd2;
	    end
	  6'd23:
	    begin
	       pd = 4'd2;
	    end     
	  default:
	    begin
	       pd = 4'd0;
	    end
	endcase // case (opcode)   
     end // always_comb
endmodule // predecode
