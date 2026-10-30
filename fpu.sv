`include "uop.vh"
`include "fp_compare.vh"

module fpu(clk,
	   reset,
	   pc,
	   opcode,
	   start,
	   src_a,
	   src_b,
	   src_c,
	   src_fcr,
	   rm,
	   rob_ptr_in,
	   dst_ptr_in,
	   fcr_ptr_in,
	   fcr_sel,
	   cmp_cond,
	   val,
	   cmp_val,
	   y,
	   fflags,
	   denorm,
	   rob_ptr_out,
	   dst_ptr_out,
	   fcr_ptr_out
	   );

   parameter LG_PRF_WIDTH = 4;
   parameter LG_ROB_WIDTH = 4;
   parameter LG_FCR_WIDTH = 4;
   parameter FPU_LAT = 2;
   
   input logic clk;
   input logic reset;
   input logic [63:0] pc;
   input opcode_t opcode;
   input logic start;
   
   input logic [63:0] src_a;
   input logic [63:0] src_b;
   input logic [63:0] src_c;
   input logic [7:0]  src_fcr;
   input logic [1:0]  rm;          // FCSR.RM (0=RN 1=RZ 2=RP 3=RM)

   input logic [LG_ROB_WIDTH-1:0] rob_ptr_in;
   input logic [LG_PRF_WIDTH-1:0] dst_ptr_in;
   input logic [LG_FCR_WIDTH-1:0] fcr_ptr_in;
   input logic [2:0] 		  fcr_sel;
   input logic [3:0] 		  cmp_cond;   // C.cond predicate (insn[3:0])

   output logic 		  val;
   output logic 		  cmp_val;
   
   output logic [63:0] 		  y;
   output logic [4:0] 		  fflags;   /* {V,Z,O,U,I} of the emerging result */
   output logic 		  denorm;   /* denormal operand/result -> Unimplemented (E) */
   output logic [LG_ROB_WIDTH-1:0] rob_ptr_out;
   output logic [LG_PRF_WIDTH-1:0] dst_ptr_out;
   output logic [LG_FCR_WIDTH-1:0] fcr_ptr_out;
   
   /* one unified single/double adder + multiplier (fpu_add / fpu_mul): y is
    * already format-correct (single result zero-extended into the low 32 bits),
    * so no SP/DP split. */
   logic [63:0] 		   t_adder_result;
   logic [63:0] 		   t_mult_result;
   /* per-unit IEEE flags + denorm (aligned with each unit's result) */
   wire [4:0] 		   w_add_fflags, w_mul_fflags, w_cmp_fflags;
   wire 			   w_add_denorm, w_mul_denorm;
      
   logic [FPU_LAT-1:0] 		   r_val;
   logic [LG_PRF_WIDTH-1:0] 	   r_ptr [FPU_LAT-1:0];
   logic [LG_ROB_WIDTH-1:0] 	   r_rob [FPU_LAT-1:0];
   logic [LG_FCR_WIDTH-1:0] 	   r_fcr[FPU_LAT-1:0];
   logic [2:0] 			   r_fcr_sel[FPU_LAT-1:0];
   logic [7:0] 			   r_fcr_reg[FPU_LAT-1:0];
   logic [7:0] 			   fcr_reg;
   opcode_t r_opcode[FPU_LAT-1:0];

   /* MIPS IV madd/msub/nmadd/nmsub (ENABLE_MIPS4 decodes them): NOT fused.  The mul
    * pass runs the multiplier; when it reaches the end of the pipe its rounded product
    * goes back into the head as the adder's A operand, with fr (src_c, delayed FPU_LAT
    * alongside) as B -- exec.sv reserves that start slot and the writeback slot
    * 2*FPU_LAT+1 out.  r_pass2 marks the add pass; the mul flags ride with it. */
   function automatic logic is_madd(input opcode_t op);
      begin
	 is_madd = (op == SP_MADD) || (op == DP_MADD) || (op == SP_MSUB) || (op == DP_MSUB) ||
		   (op == SP_NMADD) || (op == DP_NMADD) || (op == SP_NMSUB) || (op == DP_NMSUB);
      end
   endfunction
   function automatic logic madd_dbl(input opcode_t op);
      begin
	 madd_dbl = (op == DP_MADD) || (op == DP_MSUB) || (op == DP_NMADD) || (op == DP_NMSUB);
      end
   endfunction
   logic 			   r_pass2[FPU_LAT-1:0];
   logic [63:0] 		   r_srcc[FPU_LAT-1:0];
   logic [5:0] 			   r_mflags[FPU_LAT-1:0];   /* {denorm, fflags} of the product */
   /* the mul pass of a madd is leaving the pipe: start its add pass this cycle */
   wire 			   w_restart = r_val[0] & is_madd(r_opcode[0]) & ~r_pass2[0];
   wire 			   w_madd_neg = (r_opcode[0] == SP_NMADD) || (r_opcode[0] == DP_NMADD) ||
						(r_opcode[0] == SP_NMSUB) || (r_opcode[0] == DP_NMSUB);
   wire 			   w_madd_dbl = madd_dbl(r_opcode[0]);

   
   assign dst_ptr_out = r_ptr[0];
   assign rob_ptr_out = r_rob[0];
   assign fcr_ptr_out = r_fcr[0];
   assign fcr_reg = r_fcr_reg[0];

   /* one unified single/double comparator (fmt selects format).  All 16 C.cond
    * predicates handled in-unit via cmp_cond; fmt picks the operand width. */
   wire 			   w_cmp;
   wire 			   w_is_cmp = (opcode == SP_CMP) || (opcode == DP_CMP);
   wire 			   w_cmp_fmt = (opcode == DP_CMP);

   fpu_compare #(.D(FPU_LAT))
   scmp(.clk(clk),
	.a(src_a),
	.b(src_b),
	.start(start && w_is_cmp),
	.cond(cmp_cond),
	.fmt(w_cmp_fmt),
	.y(w_cmp),
	.fflags(w_cmp_fflags));

   
   /* fcr_in / t_hf are deliberately NOT named fcr_reg / y: a function-local that
    * shadows a module-level signal trips sv2v's Scoper (henry SoC sv2v flow). */
   function logic [63:0] handle_fcr(logic b, logic [2:0] sel, logic [7:0] fcr_in);
      logic [63:0] 		   t_hf;
      case(sel)
	3'd0:
	  begin
	     t_hf = {56'd0, fcr_in[7:1], b};
	  end
	3'd1:
	  begin
	     t_hf = {56'd0, fcr_in[7:2], b, fcr_in[0]};
	  end
	3'd2:
	  begin
	     t_hf = {56'd0, fcr_in[7:3], b, fcr_in[1:0]};
	  end
	3'd3:
	  begin
	     t_hf = {56'd0, fcr_in[7:4], b, fcr_in[2:0]};
	  end
	3'd4:
	  begin
	     t_hf = {56'd0, fcr_in[7:5], b, fcr_in[3:0]};
	  end
	3'd5:
	  begin
	     t_hf = {56'd0, fcr_in[7:6], b, fcr_in[4:0]};
	  end
	3'd6:
	  begin
	     t_hf = {56'd0, fcr_in[7], b, fcr_in[5:0]};
	  end
	3'd7:
	  begin
	     t_hf = {56'd0, b, fcr_in[6:0]};
	  end
      endcase // case (sel)
      return t_hf;
   endfunction // handle_fcr
   
   always_comb
     begin
	y = 'd0;
	val = 1'b0;
	cmp_val = 1'b0;
	case(r_opcode[0])
	  SP_ADD:
	    begin
	       y = t_adder_result;
	       val = r_val[0];
	    end
	  SP_SUB:
	    begin
	       y = t_adder_result;
	       val = r_val[0];
	    end
	  DP_ADD:
	    begin
	       y = t_adder_result;
	       val = r_val[0];
	    end
	  DP_SUB:
	    begin
	       y = t_adder_result;
	       val = r_val[0];
	    end
	  SP_MUL:
	    begin
	       y = t_mult_result;
	       val = r_val[0];
	    end
	  DP_MUL:
	    begin
	       y = t_mult_result;
	       val = r_val[0];
	    end
	  /* DIV / SQRT: no datapath -- complete with a dummy result (y=0) and raise
	   * the Unimplemented-Op (E) bit (see the denorm mux) so they fault to the
	   * OS soft-float emulator. */
	  SP_DIV, DP_DIV, SP_SQRT, DP_SQRT, FP_UNIMPL:
	    begin
	       y = 'd0;
	       val = r_val[0];
	    end
	  SP_CMP, DP_CMP:
	    begin
	       cmp_val = r_val[0];
	       y = handle_fcr(w_cmp, r_fcr_sel[0], fcr_reg);
	    end
	  SP_MADD, DP_MADD, SP_MSUB, DP_MSUB, SP_NMADD, DP_NMADD, SP_NMSUB, DP_NMSUB:
	    begin
	       /* the add pass completes; the mul pass leaving the pipe is not a result */
	       val = r_val[0] & r_pass2[0];
	       y = t_adder_result;
	       if(w_madd_neg)
		 begin
		    y = w_madd_dbl ? {~t_adder_result[63], t_adder_result[62:0]}
				   : {32'd0, ~t_adder_result[31], t_adder_result[30:0]};
		 end
	    end

	  default:
	    begin
	    end
	endcase // case (r_opcode[0])
     end // always_comb

   /* IEEE flags + denorm of the emerging result, muxed by the same r_opcode[0].
    * Compares only raise V (no denorm). Consumed by exec only when val/cmp_val. */
   always_comb
     begin
	fflags = 5'd0;
	denorm = 1'b0;
	case(r_opcode[0])
	  SP_ADD, SP_SUB, DP_ADD, DP_SUB:
	    begin fflags = w_add_fflags; denorm = w_add_denorm; end
	  SP_MUL, DP_MUL:
	    begin fflags = w_mul_fflags; denorm = w_mul_denorm; end
	  SP_MADD, DP_MADD, SP_MSUB, DP_MSUB, SP_NMADD, DP_NMADD, SP_NMSUB, DP_NMSUB:
	    begin
	       fflags = w_add_fflags | r_mflags[0][4:0];
	       denorm = w_add_denorm | r_mflags[0][5];
	    end
	  SP_CMP, DP_CMP:
	    fflags = w_cmp_fflags;
	  /* DIV/SQRT + any unimplemented COP1: raise E (denorm) -> FPE at retirement,
	   * OS soft-float emulates */
	  SP_DIV, DP_DIV, SP_SQRT, DP_SQRT, FP_UNIMPL:
	    denorm = 1'b1;
	  default: ;
	endcase
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_val <= 'd0;	     
	  end
	else
	  begin
	     r_val[FPU_LAT-1] <= start | w_restart;
	     for(integer i = (FPU_LAT-1); i > 0; i=i-1)
	       begin
		  r_val[i-1] <= r_val[i];
	       end
	  end
     end
   
   always_ff@(posedge clk)
     begin
	r_opcode[FPU_LAT-1] <= w_restart ? r_opcode[0] : opcode;
	r_ptr[FPU_LAT-1] <= w_restart ? r_ptr[0] : dst_ptr_in;
	r_fcr[FPU_LAT-1] <= fcr_ptr_in;
	r_rob[FPU_LAT-1] <= w_restart ? r_rob[0] : rob_ptr_in;
	r_fcr_sel[FPU_LAT-1] <= fcr_sel;
	r_fcr_reg[FPU_LAT-1] <= src_fcr;
	r_pass2[FPU_LAT-1] <= w_restart;
	r_srcc[FPU_LAT-1] <= src_c;
	r_mflags[FPU_LAT-1] <= {w_mul_denorm, w_mul_fflags};
	for(integer i = (FPU_LAT-1); i > 0; i=i-1)
	  begin
	     r_opcode[i-1] <= r_opcode[i];
	     r_ptr[i-1] <= r_ptr[i];
	     r_fcr[i-1] <= r_fcr[i];
	     r_rob[i-1] <= r_rob[i];
	     r_fcr_sel[i-1] <= r_fcr_sel[i];
	     r_fcr_reg[i-1] <= r_fcr_reg[i];
	     r_pass2[i-1] <= r_pass2[i];
	     r_srcc[i-1] <= r_srcc[i];
	     r_mflags[i-1] <= r_mflags[i];
	  end
     end // always_ff@ (posedge clk)

   /* one unified single/double adder: fmt selects format, sub selects subtract.
    * Single operands ride the low 32 bits of src_a/src_b (MIPS layout); the unit
    * extracts/packs per fmt and rounds once at the target precision.
    * Rounding mode comes from FCSR.RM (the rm port). */
   wire w_add_is_double = w_restart ? w_madd_dbl : ((opcode == DP_ADD) || (opcode == DP_SUB));
   /* msub = p - fr, nmsub = -(p - fr) */
   wire w_add_is_sub    = w_restart ? ((r_opcode[0] == SP_MSUB) || (r_opcode[0] == DP_MSUB) ||
				       (r_opcode[0] == SP_NMSUB) || (r_opcode[0] == DP_NMSUB))
				    : ((opcode == SP_SUB) || (opcode == DP_SUB));
   wire w_add_en        = w_restart | (opcode == SP_ADD) || (opcode == SP_SUB) ||
			  (opcode == DP_ADD) || (opcode == DP_SUB);
   fpu_add #(.ADD_LAT(FPU_LAT))
   sadd (.clk(clk),
	 .sub(w_add_is_sub),
	 .a(w_restart ? t_mult_result : src_a),   /* madd add pass: the rounded product */
	 .b(w_restart ? r_srcc[0] : src_b),       /* ... and fr */
	 .en(w_add_en),
	 .rm(rm),
	 .fmt(w_add_is_double),
	 .y(t_adder_result),
	 .denorm(w_add_denorm),
	 .fflags(w_add_fflags)
	 );
   
   /* one unified single/double multiplier: fmt selects format.
    * Rounding mode comes from FCSR.RM (the rm port). */
   wire w_mul_is_double = (opcode == DP_MUL) || madd_dbl(opcode);
   wire w_mul_en        = (opcode == SP_MUL) || (opcode == DP_MUL) || is_madd(opcode);
   fpu_mul #(.MUL_LAT(FPU_LAT))
   smul (.clk(clk),
	 .a(src_a),
	 .b(src_b),
	 .en(w_mul_en),
	 .rm(rm),
	 .fmt(w_mul_is_double),
	 .y(t_mult_result),
	 .denorm(w_mul_denorm),
	 .fflags(w_mul_fflags)
	 );

   
`ifdef VERILATOR
   always_ff@(negedge clk)
     begin
	if(!reset & start & w_restart)
	  begin
	     $display("fpu: an op started in the slot a madd's add pass needs (pc %x)", pc);
	     $stop();
	  end
     end
`endif
endmodule // fpu
