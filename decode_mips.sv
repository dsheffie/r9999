`include "machine.vh"
`include "rob.vh"
`include "uop.vh"

module decode_mips(
		   in_kernel_mode,
		   in_supervisor_mode,
		   in_user_mode,
		   in_64b_kernel_mode,
		   in_64b_supervisor_mode,
		   in_64b_user_mode,
		   irq,
		   tlb_miss,
		   tlb_invalid,
		   misaligned,
		   insn,
		   pc,
		   insn_pred,
		   pht_idx,
		   insn_pred_target,
`ifdef ENABLE_CYCLE_ACCOUNTING
		   fetch_cycle,
`endif
		   uop);
   input logic			in_kernel_mode;
   input logic			in_supervisor_mode;
   input logic			in_user_mode;
   input logic			in_64b_kernel_mode;
   input logic			in_64b_supervisor_mode;
   input logic			in_64b_user_mode;
   input logic			irq;
   input logic			tlb_miss;
   input logic			tlb_invalid;
   input logic			misaligned;
   input logic [31:0]		insn;
   input logic [`M_WIDTH-1:0] pc;
   input logic 	      insn_pred;
   input logic [`LG_PHT_SZ-1:0] pht_idx;
   input logic [`M_WIDTH-1:0]	insn_pred_target;
`ifdef ENABLE_CYCLE_ACCOUNTING   
   input logic [63:0]		fetch_cycle;
`endif
   output			uop_t uop;

   wire [5:0]			opcode = insn[31:26];
   wire				is_nop = (insn == 32'd0);
   wire				is_ehb = (insn == 32'd192);
   
   
   /* how many zero pad bits for reg specifiers */
   localparam			ZP = (`LG_PRF_ENTRIES-5);

   wire				w_in_64b_mode;
   generate
      if(`M_WIDTH==64)
	begin
	   assign w_in_64b_mode = in_64b_kernel_mode | 
				  in_64b_user_mode | 
				  in_64b_supervisor_mode;
	end
      else
	begin
	   assign w_in_64b_mode =1'b0;
	end
   endgenerate
   
   
   wire [`LG_PRF_ENTRIES-1:0]	rs = {{ZP{1'b0}},insn[25:21]};
   wire [`LG_PRF_ENTRIES-1:0]	rt = {{ZP{1'b0}},insn[20:16]};
   wire [`LG_PRF_ENTRIES-1:0]	rd = {{ZP{1'b0}},insn[15:11]};

   wire [`LG_PRF_ENTRIES-1:0]	fs = {{ZP{1'b0}},insn[15:11]};
   wire [`LG_PRF_ENTRIES-1:0]	ft = {{ZP{1'b0}},insn[20:16]};
   wire [`LG_PRF_ENTRIES-1:0]	fd = {{ZP{1'b0}},insn[10:6]};

   
   /* shamt only feeds the 16-bit imm as {10'b0, shamt}; keep it 6 bits so it
    * does not depend on LG_PRF_ENTRIES (the shift amount is insn[10:6]). */
   wire [5:0]			shamt = {1'b0, insn[10:6]};
   
   always_comb
     begin
	uop.op = II;
	uop.srcA = 'd0;
	uop.srcB = 'd0;
	uop.dst = 'd0;
	uop.srcA_valid = 1'b0;
	uop.srcB_valid = 1'b0;
	uop.fp_srcA_valid = 1'b0;
	uop.fp_srcB_valid = 1'b0;
	uop.hilo_dst_valid = 1'b0;
	uop.hilo_src_valid = 1'b0;
	uop.hilo_dst = 'd0;
	uop.hilo_src = 'd0;
	
	uop.dst_valid = 1'b0;
	uop.fp_dst_valid = 1'b0;
	
	uop.has_delay_slot = 1'b0;
	uop.has_nullifying_delay_slot = 1'b0;
	uop.imm = 16'd0;
	uop.jmp_imm = {(`M_WIDTH-16){1'b0}};
	uop.pc = pc;
	uop.pred_target = insn_pred_target;
	uop.serializing_op = 1'b0;
	uop.must_restart = 1'b0;
	uop.oldest_first = 1'b0;
	uop.rob_ptr = 'd0;
	uop.br_pred = 1'b0;
	uop.is_br = 1'b0;
	uop.pht_idx = pht_idx;
	uop.is_mem = 1'b0;
	uop.is_int = 1'b0;
	uop.is_store = 1'b0;
	uop.is_cache = 1'b0;
	uop.cache_is_d = 1'b0;
`ifdef ENABLE_CYCLE_ACCOUNTING
	uop.fetch_cycle = fetch_cycle;
`endif
	uop.mode_when_fetched = w_in_64b_mode;
	if(irq)
	  begin
	     uop.op = IRQ;
	  end
	else if(misaligned)
	  begin
	     uop.op = FETCH_MISALIGNED;
	  end
	else if(tlb_miss)
	  begin
	     uop.op = FETCH_TLB_MISS;
	  end
	else if(tlb_invalid)
	  begin
	     uop.op = FETCH_TLB_INVALID;
	  end
	else
	  begin
	     case(opcode)
	       6'd0: /* rtype */
		 begin
		    case(insn[5:0])
		      6'd0: /* sll */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = is_nop||is_ehb ? NOP :SLL;
			   uop.is_int = 1'b1;
			   uop.imm = {10'b0, shamt};
			end
		      6'd2: /* srl */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.imm = {10'b0, shamt};			   
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : SRL;
			   uop.is_int = 1'b1;
			end
		      6'd3: /* sra */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.imm = {10'b0, shamt};
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : SRA;
			   uop.is_int = 1'b1;
			end
		      6'd4: /* sllv */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : SLLV;
			   uop.is_int = 1'b1;
			end // case: 6'd4
		      6'd6: /* srlv */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : SRLV;
			   uop.is_int = 1'b1;
			end
		      6'd7: /* srav */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : SRAV;
			   uop.is_int = 1'b1;
			end
		      6'd20: /* dsllv */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rt;
			     uop.srcA_valid = 1'b1;
			     uop.srcB = rs;
			     uop.srcB_valid = 1'b1;
			     uop.dst = rd;
			     uop.dst_valid = (rd != 'd0);
			     uop.op = (rd == 'd0) ? NOP : DSLLV;
			     uop.is_int = 1'b1;
			  end
		      6'd22: /* dsrlv */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rt;
			     uop.srcA_valid = 1'b1;
			     uop.srcB = rs;
			     uop.srcB_valid = 1'b1;
			     uop.dst = rd;
			     uop.dst_valid = (rd != 'd0);
			     uop.op = (rd == 'd0) ? NOP : DSRLV;
			     uop.is_int = 1'b1;
			  end
		      6'd23: /* dsrav */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rt;
			     uop.srcA_valid = 1'b1;
			     uop.srcB = rs;
			     uop.srcB_valid = 1'b1;
			     uop.dst = rd;
			     uop.dst_valid = (rd != 'd0);
			     uop.op = (rd == 'd0) ? NOP : DSRAV;
			     uop.is_int = 1'b1;
			  end
		      6'd56: /* dsll */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rt;
			     uop.srcA_valid = 1'b1;
			     uop.dst = rd;
			     uop.dst_valid = (rd != 'd0);
			     uop.op = (rd == 'd0) ? NOP : DSLL;
			     uop.imm = {10'b0, shamt};
			     uop.is_int = 1'b1;
			  end
		      6'd58: /* dsrl */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rt;
			     uop.srcA_valid = 1'b1;
			     uop.dst = rd;
			     uop.dst_valid = (rd != 'd0);
			     uop.op = (rd == 'd0) ? NOP : DSRL;
			     uop.imm = {10'b0, shamt};
			     uop.is_int = 1'b1;
			  end
		      6'd59: /* dsra */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rt;
			     uop.srcA_valid = 1'b1;
			     uop.dst = rd;
			     uop.dst_valid = (rd != 'd0);
			     uop.op = (rd == 'd0) ? NOP : DSRA;
			     uop.imm = {10'b0, shamt};
			     uop.is_int = 1'b1;
			  end
		      6'd60: /* dsll32: shift = sa + 32 */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rt;
			     uop.srcA_valid = 1'b1;
			     uop.dst = rd;
			     uop.dst_valid = (rd != 'd0);
			     uop.op = (rd == 'd0) ? NOP : DSLL32;
			     uop.imm = {10'b0, shamt};
			     uop.is_int = 1'b1;
			  end
		      6'd62: /* dsrl32: shift = sa + 32 */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rt;
			     uop.srcA_valid = 1'b1;
			     uop.dst = rd;
			     uop.dst_valid = (rd != 'd0);
			     uop.op = (rd == 'd0) ? NOP : DSRL32;
			     uop.imm = {10'b0, shamt};
			     uop.is_int = 1'b1;
			  end
		      6'd63: /* dsra32: shift = sa + 32 */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rt;
			     uop.srcA_valid = 1'b1;
			     uop.dst = rd;
			     uop.dst_valid = (rd != 'd0);
			     uop.op = (rd == 'd0) ? NOP : DSRA32;
			     uop.imm = {10'b0, shamt};
			     uop.is_int = 1'b1;
			  end
		      6'd8: /* jr */
			begin
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.has_delay_slot = 1'b1;
			   uop.op = JR;
			   uop.imm = insn_pred_target[15:0];
			   uop.jmp_imm = insn_pred_target[`M_WIDTH-1:16];
			   uop.is_br = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd9: /* jalr */
			begin
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.has_delay_slot = 1'b1;
			   uop.op = JALR;
			   uop.dst_valid = rd != 'd0;
			   uop.dst = rd;
			   uop.imm = insn_pred_target[15:0];
			   uop.jmp_imm = insn_pred_target[`M_WIDTH-1:16];
			   uop.is_br = 1'b1;
			   uop.is_int = 1'b1;
			end // case: 6'd9
		      6'd12:
			begin
			   uop.op = SYSCALL;
			   uop.oldest_first = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd13:
			begin
			   uop.op = BREAK;
			   uop.oldest_first = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd15: /* sync - treat as nop */
			begin
			   uop.op = NOP;
			   uop.is_int = 1'b1;
			end
		      6'd16:
			begin
			   uop.op = (rd == 'd0) ? NOP : MFHI;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.hilo_src_valid = 1'b1;
			   uop.is_int = 1'b1;		      
			end
		      6'd17:
			begin
			   uop.op = MTHI;
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.hilo_src_valid = 1'b1;		      
			   uop.hilo_dst_valid = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd18:
			begin
			   uop.op = (rd == 'd0) ? NOP : MFLO;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.hilo_src_valid = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd19:
			begin
			   uop.op = MTLO;
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.hilo_src_valid = 1'b1;		      
			   uop.hilo_dst_valid = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd24: /* mult */
			begin
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rt;
			   uop.srcB_valid = 1'b1;
			   uop.hilo_dst_valid = 1'b1;
			   uop.op = MULT;
			   uop.is_int = 1'b1;
			end
		      6'd25: /* multu */
			begin
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rt;
			   uop.srcB_valid = 1'b1;
			   uop.hilo_dst_valid = 1'b1;
			   uop.op = MULTU;
			   uop.is_int = 1'b1;
			end
		      6'd26: /* div */
			begin
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rt;
			   uop.srcB_valid = 1'b1;
			   uop.hilo_dst_valid = 1'b1;
			   uop.op = DIV;
			   uop.is_int = 1'b1;
			end
		      6'd27: /* divu */
			begin
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rt;
			   uop.srcB_valid = 1'b1;
			   uop.hilo_dst_valid = 1'b1;
			   uop.op = DIVU;
			   uop.is_int = 1'b1;
			end
		      6'd28: /* dmult */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rs;
			     uop.srcA_valid = 1'b1;
			     uop.srcB = rt;
			     uop.srcB_valid = 1'b1;
			     uop.hilo_dst_valid = 1'b1;
			     uop.op = DMULT;
			     uop.is_int = 1'b1;
			  end
		      6'd29: /* dmultu */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rs;
			     uop.srcA_valid = 1'b1;
			     uop.srcB = rt;
			     uop.srcB_valid = 1'b1;
			     uop.hilo_dst_valid = 1'b1;
			     uop.op = DMULTU;
			     uop.is_int = 1'b1;
			  end
		      6'd30: /* ddiv */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rs;
			     uop.srcA_valid = 1'b1;
			     uop.srcB = rt;
			     uop.srcB_valid = 1'b1;
			     uop.hilo_dst_valid = 1'b1;
			     uop.op = DDIV;
			     uop.is_int = 1'b1;
			  end
		      6'd31: /* ddivu */
			if(w_in_64b_mode)
			  begin
			     uop.srcA = rs;
			     uop.srcA_valid = 1'b1;
			     uop.srcB = rt;
			     uop.srcB_valid = 1'b1;
			     uop.hilo_dst_valid = 1'b1;
			     uop.op = DDIVU;
			     uop.is_int = 1'b1;
			  end
		      6'd32: /* add */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = ADD;
			   uop.is_int = 1'b1;
			end		 
		      6'd33: /* addu */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : ADDU;
			   uop.is_int = 1'b1;
			end
		      6'd34: /* sub */
			begin
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rt;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : SUB;
			   uop.is_int = 1'b1;
			end
		      6'd35: /* subu */
			begin
			   uop.srcA = rs;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rt;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : SUBU;
			   uop.is_int = 1'b1;
			end
		      6'd36: /* and */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : AND;
			   uop.is_int = 1'b1;
			end
		      6'd37: /* or */
			begin
			   if(rs == 'd0)
			     begin
				uop.srcA = rt;
				uop.srcA_valid = 1'b1;
				uop.dst = rd;
				uop.dst_valid = (rd != 'd0);
				uop.op = (rd == 'd0) ? NOP : MOV;
				uop.is_int = 1'b1;
			     end
			   else
			     begin
				uop.srcA = rt;
				uop.srcA_valid = 1'b1;
				uop.srcB = rs;
				uop.srcB_valid = 1'b1;
				uop.dst = rd;
				uop.dst_valid = (rd != 'd0);
				uop.op = (rd == 'd0) ? NOP : OR;
				uop.is_int = 1'b1;
			     end
			end
		      6'd38: /* xor */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : XOR;
			   uop.is_int = 1'b1;
			end	
		      6'd39: /* nor */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : NOR;
			   uop.is_int = 1'b1;
			end
		      6'd42: /* slt */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : SLT;
			   uop.is_int = 1'b1;
			end
		      6'd43: /* sltu */
			begin
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.dst = rd;
			   uop.dst_valid = (rd != 'd0);
			   uop.op = (rd == 'd0) ? NOP : SLTU;
			   uop.is_int = 1'b1;
			end // case: 6'd43
		      6'd44: /* dadd */
			begin
			   if(w_in_64b_mode)
			     begin		      
				uop.srcA = rt;
				uop.srcA_valid = 1'b1;
				uop.srcB = rs;
				uop.srcB_valid = 1'b1;
				uop.dst = rd;
				uop.dst_valid = (rd != 'd0);
				uop.op = (rd == 'd0) ? NOP : DADD;
				uop.is_int = 1'b1;
			     end
			end
		      6'd45: /* daddu */
			begin
			   if(w_in_64b_mode)
			     begin
				uop.srcA = rt;
				uop.srcA_valid = 1'b1;
				uop.srcB = rs;
				uop.srcB_valid = 1'b1;
				uop.dst = rd;
				uop.dst_valid = (rd != 'd0);
				uop.op = (rd == 'd0) ? NOP : DADDU;
				uop.is_int = 1'b1;
			     end
			end
		      6'd46: /* dsub */
			begin
			   if(w_in_64b_mode)
			     begin
				uop.srcA = rs;
				uop.srcA_valid = 1'b1;
				uop.srcB = rt;
				uop.srcB_valid = 1'b1;
				uop.dst = rd;
				uop.dst_valid = (rd != 'd0);
				uop.op = (rd == 'd0) ? NOP : DSUB;
				uop.is_int = 1'b1;
			     end
			end
		      6'd47: /* dsubu */
			begin
			   if(w_in_64b_mode)
			     begin
				uop.srcA = rs;
				uop.srcA_valid = 1'b1;
				uop.srcB = rt;
				uop.srcB_valid = 1'b1;
				uop.dst = rd;
				uop.dst_valid = (rd != 'd0);
				uop.op = (rd == 'd0) ? NOP : DSUBU;
				uop.is_int = 1'b1;
			     end
			end
		      6'd52: /* teq */
			begin
			   uop.op = TEQ;
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd54: /* tne */
			begin
			   uop.op = TNE;
			   uop.srcA = rt;
			   uop.srcA_valid = 1'b1;
			   uop.srcB = rs;
			   uop.srcB_valid = 1'b1;
			   uop.is_int = 1'b1;
			end
		      default:
			begin
			end
		    endcase // case (insn[5:0])
		 end // case: 6'd0
	       /* end-rtype */
	       6'd1: /* BGEZ through BLTZ */
		 begin
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_br = 1'b1;
		    uop.is_int = 1'b1;
		    uop.br_pred = insn_pred;

		    
		    case(rt[4:0])
		      'd0: /* BLTZ */
			begin
			   uop.op = BLTZ;
			end
		      'd1: /* BGEZ */
			begin
			   uop.op = BGEZ;
			end
		      'd2: /* BLTZL */
			begin
			   uop.op = BLTZL;
			   uop.has_nullifying_delay_slot = 1'b1;
			end
		      'd3:
			begin /* BGEZL */
			   uop.op = BGEZL;
			   uop.has_nullifying_delay_slot = 1'b1;
			end
		      'd17:
			begin /* BGEZAL */
			   uop.op = (rs == 'd0) ? BAL : BGEZAL;
			   uop.dst_valid = 1'b1;
			   uop.dst = 'd31;
			   uop.srcB = 'd31;
			   uop.srcB_valid = (rs == 'd0) ? 1'b0 : 1'b1;
			end
		      default:
			begin
			   uop.op = II;
			end
		    endcase // case (rt[1:0])
		 end // case: 6'd1
	       6'd2: /* J - just fold */
		 begin
		    uop.op = J;
		    uop.is_br = 1'b1;
		    uop.is_int = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    //uop.imm = insn[15:0];
		    //uop.jmp_imm = insn[25:16];
		    //uop.br_pred = 1'b1;
		 end
	       6'd3:
		 begin
		    uop.op = JAL;
		    uop.has_delay_slot = 1'b1;
		    uop.imm = insn[15:0];
		    uop.jmp_imm = {{(`M_WIDTH-26){1'b0}}, insn[25:16]};
		    uop.dst_valid = 1'b1;
		    uop.dst = 'd31;	  
		    uop.br_pred = 1'b1;
		    uop.is_br = 1'b1;
		    uop.is_int = 1'b1;	       
		 end
	       6'd4: /* BEQ */
		 begin
		    uop.op = BEQ;
		    uop.dst_valid = 1'b0;
		    uop.dst = 'd0;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.imm = insn[15:0];
		    uop.br_pred = insn_pred;
		    uop.is_br = 1'b1;
		    uop.is_int = 1'b1;
		 end // case: 6'd4
	       6'd5: /* BNE */
		 begin
		    //$display("decoded bne, rs = %d, rs = %d", rs, rt);
		    uop.op = BNE;
		    uop.dst_valid = 1'b0;
		    uop.dst = 'd0;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.imm = insn[15:0];
		    uop.br_pred = insn_pred;
		    uop.is_br = 1'b1;
		    uop.is_int = 1'b1;
		 end // case: 6'd5
	       6'd6: /* BLEZ */
		 begin	    
		    uop.op = BLEZ;
		    uop.dst_valid = 1'b0;
		    uop.dst = 'd0;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.imm = insn[15:0];
		    uop.br_pred = insn_pred;
		    uop.is_br = 1'b1;
		    uop.is_int = 1'b1;	       
		 end
	       6'd7: /* BGTZ */
		 begin
		    uop.op = BGTZ;
		    uop.dst_valid = 1'b0;
		    uop.dst = 'd0;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.imm = insn[15:0];
		    uop.br_pred = insn_pred;
		    uop.is_br = 1'b1;
		    uop.is_int = 1'b1;
		 end // case: 6'd7
	       6'd8: /* ADDI */
		 begin
		    uop.op = ADDI;
		    uop.srcA_valid = 1'b1;
		    uop.srcA = rs;
		    uop.dst_valid = (rt != 'd0);
		    uop.is_int = 1'b1;
		    uop.dst = rt;
		    uop.imm = insn[15:0];
		 end
	       6'd9: /* ADDIU */
		 begin
		    if(rs == 'd0)
		      begin
			 uop.op = (rt == 'd0) ? NOP : MOVI;
			 uop.dst_valid = (rt != 'd0);
			 uop.is_int = 1'b1;
			 uop.dst = rt;
			 uop.imm = insn[15:0];		    
		      end
		    else
		      begin
			 uop.op = (rt == 'd0) ? NOP : ADDIU;
			 uop.srcA_valid = 1'b1;
			 uop.srcA = rs;
			 uop.dst_valid = (rt != 'd0);
			 uop.is_int = 1'b1;
			 uop.dst = rt;
			 uop.imm = insn[15:0];
		      end
		 end
	       6'd10: /* SLTI */
		 begin
		    uop.op = (rt == 'd0) ? NOP : SLTI;
		    uop.srcA_valid = 1'b1;
		    uop.srcA = rs;
		    uop.dst_valid = (rt != 'd0);
		    uop.dst = rt;
		    uop.is_int = 1'b1;	       
		    uop.imm = insn[15:0];
		 end
	       6'd11: /* SLTIU */
		 begin
		    uop.op = (rt == 'd0) ? NOP : SLTIU;
		    uop.srcA_valid = 1'b1;
		    uop.srcA = rs;
		    uop.dst_valid = (rt != 'd0);
		    uop.dst = rt;
		    uop.is_int = 1'b1;	       
		    uop.imm = insn[15:0];
		 end
	       6'd12: /* ANDI */
		 begin
		    uop.op = (rt == 'd0) ? NOP : ANDI;
		    uop.srcA_valid = 1'b1;
		    uop.srcA = rs;
		    uop.dst_valid = (rt != 'd0);
		    uop.dst = rt;
		    uop.is_int = 1'b1;
		    uop.imm = insn[15:0];	       
		 end
	       6'd13: /* ORI */
		 begin
		    uop.op = (rt == 'd0) ? NOP : ORI;
		    uop.srcA_valid = 1'b1;
		    uop.srcA = rs;	       
		    uop.dst_valid = (rt != 'd0);
		    uop.dst = rt;
		    uop.is_int = 1'b1;
		    uop.imm = insn[15:0];
		    //$display("ORI : dest %d, src %d, imm = %d", uop.dst, uop.srcA, uop.imm);
		    
		 end
	       6'd14: /* XORI */
		 begin
		    uop.op = (rt == 'd0) ? NOP : XORI;
		    uop.srcA_valid = 1'b1;
		    uop.srcA = rs;	       
		    uop.dst_valid = (rt != 'd0);
		    uop.dst = rt;
		    uop.is_int = 1'b1;
		    uop.imm = insn[15:0];	       
		 end
	       6'd15: /* LUI*/
		 begin
		    uop.op = (rt == 'd0) ? NOP : LUI;
		    uop.dst_valid = (rt != 'd0);
		    uop.dst = rt;
		    uop.is_int = 1'b1;
		    uop.imm = insn[15:0];
		 end
	       6'd16: /* coproc0 */
		 begin	
		    if(in_kernel_mode)
		    begin
		    if((insn[25]==1'b1) & (insn[24:6] == 19'd0) & (insn[5:0] == 6'd1))
		      begin
			 uop.op = TLBR;
			 uop.is_int = 1'b1;
			 uop.oldest_first = 1'b1;
		      end
		    else if((insn[25]==1'b1) & (insn[24:6] == 19'd0) & (insn[5:0] == 6'd2))
		      begin
			 uop.op = TLBWI;
			 uop.is_int = 1'b1;
			 uop.oldest_first = 1'b1;
		      end
		    else if((insn[25]==1'b1) & (insn[24:6] == 19'd0) & (insn[5:0] == 6'd6))
		      begin
			 uop.op = TLBWR;
			 uop.is_int = 1'b1;
			 uop.oldest_first = 1'b1;
		      end
		    else if((insn[25]==1'b1) & (insn[24:6] == 19'd0) & (insn[5:0] == 6'd8))
		      begin
			 uop.op = TLBP;
			 uop.is_mem = 1'b1;
		      end	       
		    else if((insn[25:21] == 5'd0) & (insn[10:0] == 'd0)) /* switch on RS */
		      begin /* mfc0 */
			 uop.op = MFC0;
			 uop.dst = rt;
			 uop.dst_valid = 1'b1;
			 uop.srcA = rd;
			 uop.is_int = 1'b1;
			 uop.oldest_first = 1'b1;
		      end
		    else if((insn[25:21] == 5'd1) & (insn[10:0] == 'd0)) /* dmfc0 */
		      begin
			 if(w_in_64b_mode)
			   begin
			      uop.op = DMFC0;
			      uop.dst = rt;
			      uop.dst_valid = 1'b1;
			      uop.srcA = rd;
			      uop.is_int = 1'b1;
			      uop.oldest_first = 1'b1;
			   end
			 /* else: 64-bit op in 32-bit mode -> op stays II (RI) */
		      end
		    else if((insn[25:21] == 5'd4) & (insn[10:0] == 'd0)) /* switch on RS */
		      begin
			 uop.op = MTC0;
			 uop.dst = rd;
			 uop.srcA = rt;
			 uop.srcA_valid = 1'b1;
			 uop.has_delay_slot = 1'b0;
			 uop.is_int = 1'b1;
			 uop.serializing_op = 1'b1;
		      end // case: 5'd4
		    else if((insn[25:21] == 5'd5) & (insn[10:0] == 'd0)) /* dmtc0 */
		      begin
			 if(w_in_64b_mode)
			   begin
			      uop.op = DMTC0;
			      uop.dst = rd;
			      uop.srcA = rt;
			      uop.srcA_valid = 1'b1;
			      uop.has_delay_slot = 1'b0;
			      uop.is_int = 1'b1;
			      uop.serializing_op = 1'b1;
			   end
			 /* else: 64-bit op in 32-bit mode -> op stays II (RI) */
		      end
		    else if(insn[25:0] == 26'b10000000000000000000011000)
		      begin
			 uop.op = ERET;
			 uop.oldest_first = 1'b1;
			 uop.has_delay_slot = 1'b0;
			 uop.is_int = 1'b1;
		      end
		    end // if(in_kernel_mode)
		    else
		      begin
			 uop.op = CPU; /* CP0 instruction outside kernel mode -> Coprocessor Unusable */
		      end
		 end // case: 6'd16
	       6'd17: /* coproc1 */
		 begin
		    if((insn[25:21]==5'd0) && (insn[10:0] == 11'd0))
		      begin /* mfc1 */
			 uop.dst = rt;
			 uop.dst_valid = 1'b1;
			 uop.op = MFC1_MERGE;
			 uop.srcB = {{ZP{1'b0}}, rd[4:1], 1'b0};
			 uop.jmp_imm = { {(`M_WIDTH-17){1'b0}}, rd[0]};
			 uop.fp_srcB_valid = 1'b1;
			 uop.is_mem = 1'b1;
		      end
		    else if((insn[25:21]==5'd4) && (insn[10:0] == 11'd0))
		      begin /* mtc1 */
			 uop.srcA = rt;
			 uop.srcA_valid = 1'b1;
			 uop.op = MTC1_MERGE;
			 uop.dst = {{ZP{1'b0}}, rd[4:1], 1'b0};
			 uop.srcB = {{ZP{1'b0}}, rd[4:1], 1'b0};
			 uop.jmp_imm = { {(`M_WIDTH-17){1'b0}}, rd[0]};
			 uop.fp_srcB_valid = 1;			 
			 uop.fp_dst_valid = 1'b1;
			 uop.is_mem = 1'b1;
		      end // if ((insn[25:21]==5'd4) && (insn[10:0] == 11'd0))
		 end // case: 6'd17
	       6'd20: /* BEQL */
		 begin
		    uop.op = BEQL;
		    uop.dst_valid = 1'b0;
		    uop.dst = 'd0;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.has_nullifying_delay_slot = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_br = 1'b1;
		    uop.br_pred = insn_pred;
		    uop.is_int = 1'b1;
		 end // case: 6'd20
	       6'd21: /* BNEL */
		 begin
		    uop.op = BNEL;
		    uop.dst_valid = 1'b0;
		    uop.dst = 'd0;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.has_nullifying_delay_slot = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_br = 1'b1;
		    uop.br_pred = insn_pred;
		    uop.is_int = 1'b1;
		 end // case: 6'd21
	       6'd22: /* BLEZL */
		 begin	    
		    uop.op = BLEZL;
		    uop.dst_valid = 1'b0;
		    uop.dst = 'd0;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.has_nullifying_delay_slot = 1'b1;	       
		    uop.imm = insn[15:0];
		    uop.is_br = 1'b1;
		    uop.br_pred = insn_pred;
		    uop.is_int = 1'b1;
		 end // case: 6'd22
	       6'd23: /* BGTZL */
		 begin
		    uop.op = BGTZL;
		    uop.dst_valid = 1'b0;
		    uop.dst = 'd0;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.has_nullifying_delay_slot = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_br = 1'b1;
		    uop.br_pred = insn_pred;
		    uop.is_int = 1'b1;
		 end // case: 6'd23
	       6'd25: /* daddiu */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.dst = rt;
			 uop.dst_valid = (rt != 'd0);
			 uop.op = DADDIU;
			 uop.imm = insn[15:0];
			 uop.is_int = 1'b1;
		      end
		 end
	       6'd32: /* LB */
		 begin
		    uop.op = LB;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.dst = rt;
		    uop.dst_valid = (rt != 'd0);
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		 end
	       6'd33: /* LH */
		 begin
		    uop.op = LH;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.dst = rt;
		    uop.dst_valid = (rt != 'd0);
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		 end
	       6'd26: /* LDL */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.op = LDL;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.srcB = rt;
			 uop.srcB_valid = 1'b1;
			 uop.dst = rt;
			 uop.dst_valid = (rt != 'd0);
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
		      end
		 end
	       6'd27: /* LDR */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.op = LDR;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.srcB = rt;
			 uop.srcB_valid = 1'b1;
			 uop.dst = rt;
			 uop.dst_valid = (rt != 'd0);
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
		      end
		 end
	       6'd34: /* LWL */
		 begin
		    uop.op = LWL;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.dst = rt;
		    uop.dst_valid = (rt != 'd0);
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		 end
	       6'd35: /* LW */
		 begin
		    uop.op = LW;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.dst = rt;
		    uop.dst_valid = (rt != 'd0);
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		 end
	       6'd36: /* LBU */
		 begin
		    uop.op = LBU;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.dst = rt;
		    uop.dst_valid = (rt != 'd0);
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		 end
	       6'd37: /* LHU */
		 begin
		    uop.op = LHU;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.dst = rt;
		    uop.dst_valid = (rt != 'd0);
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		 end
	       6'd38: /* LWR */
		 begin
		    uop.op = LWR;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.dst = rt;
		    uop.dst_valid = (rt != 'd0);
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		 end
	       6'd39: /* LWU */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.op = LWU;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.dst = rt;
			 uop.dst_valid = (rt != 'd0);
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
		      end
		 end
	       6'd40: /* SB */
		 begin
		    uop.op = SB;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		    uop.is_store = 1'b1;
		 end	    
	       6'd41: /* SH */
		 begin
		    uop.op = SH;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		    uop.is_store = 1'b1;	       
		 end
	       6'd42:
		 begin
		    uop.op = SWL;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		    uop.is_store = 1'b1;
		 end
	       6'd43: /* SW */
		 begin
		    uop.op = SW;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		    uop.is_store = 1'b1;
		 end
	       6'd44: /* SDL */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.op = SDL;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.srcB = rt;
			 uop.srcB_valid = 1'b1;
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
			 uop.is_store = 1'b1;
		      end
		 end
	       6'd45: /* SDR */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.op = SDR;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.srcB = rt;
			 uop.srcB_valid = 1'b1;
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
			 uop.is_store = 1'b1;
		      end
		 end
	       6'd46: /* SWR */
		 begin
		    uop.op = SWR;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		    uop.is_store = 1'b1;
		 end
	       6'd47: /* CACHE -- serializing flush. Op subfield insn[20:16]:
		       * bit[16] selects cache (0=I, 1=D). D-ops do a per-line
		       * writeback (flush_cl at EA=base+offset, pushing the line to L2);
		       * I-ops nuke the whole L1I. Compute base+offset so the EA lands
		       * in rob.data for the per-line D flush. */
		 begin
		    uop.op = CACHE_OP;
		    uop.is_int = 1'b1;
		    uop.serializing_op = 1'b1;
		    uop.is_cache = 1'b1;
		    uop.cache_is_d = insn[16];
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.imm = insn[15:0];
		 end
	       6'd48: /* LL */
		 begin
		    uop.op = LL;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.dst = rt;
		    uop.dst_valid = (rt != 'd0);
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		    uop.oldest_first = 1'b1;
		 end
	       6'd52: /* LLD */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.op = LLD;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.dst = rt;
			 uop.dst_valid = (rt != 'd0);
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
			 uop.oldest_first = 1'b1;
		      end
		 end
	       6'd56: /* SC */
		 begin
		    uop.op = SC;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = rt;
		    uop.srcB_valid = 1'b1;
		    uop.dst = rt;
		    uop.dst_valid = (rt != 'd0);
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		    uop.is_store = 1'b1;
		    uop.oldest_first = 1'b1;
		 end
	       6'd60: /* SCD */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.op = SCD;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.srcB = rt;
			 uop.srcB_valid = 1'b1;
			 uop.dst = rt;
			 uop.dst_valid = (rt != 'd0);
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
			 uop.is_store = 1'b1;
			 uop.oldest_first = 1'b1;
		      end
		 end
	       6'd51: /* PREF */
		 begin
		    uop.op = NOP;
		    uop.is_int = 1'b1;
		 end
	       6'd55: /* LD */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.op = LD;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.dst = rt;
			 uop.dst_valid = (rt != 'd0);
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
		      end
		 end
	       6'd63: /* SD */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.op = SD;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.srcB = rt;
			 uop.srcB_valid = 1'b1;
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
			 uop.is_store = 1'b1;
		      end
		 end

	       default:
		 begin
		 end
	     endcase // case (insn[5:0])
	  end // always_comb
     end   

endmodule
   
