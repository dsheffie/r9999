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
		   cu1,
		   fr,
		   irq,
		   tlb_miss,
		   tlb_invalid,
		   misaligned,
		   bad_va,
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
   input logic			cu1;   /* Status.CU1 (coprocessor-1 / FPU enable) */
   input logic			fr;    /* Status.FR (FP register mode: 1=32x64b, 0=16 even/odd pairs) */
   input logic			irq;
   input logic			tlb_miss;
   input logic			tlb_invalid;
   input logic			misaligned;
   input logic			bad_va;
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
	   /* 64-bit OPERATIONS are always valid in Kernel mode (independent of KX --
	    * KX gates 64-bit addressing + XTLB-vector selection, not op availability).
	    * Supervisor/User require SX/UX.  (Gating kernel ops on KX was the root
	    * cause of the kernel_entry daddiu RI / 64b-mode silicon hazard.) */
	   assign w_in_64b_mode = in_kernel_mode |
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
	uop.srcC = 'd0;
	uop.srcC_valid = 1'b0;
	uop.fp_srcC_valid = 1'b0;
	uop.fcr_src_valid = 1'b0;
	uop.hilo_dst_valid = 1'b0;
	uop.hilo_src_valid = 1'b0;
	uop.hilo_dst = 'd0;
	uop.hilo_src = 'd0;

	uop.dst_valid = 1'b0;
	uop.fp_dst_valid = 1'b0;
	uop.fcr_dst_valid = 1'b0;
	uop.is_fp = 1'b0;
	uop.cpu_ce1 = 1'b0;
	
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
	uop.cache_inval = 1'b0;
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
	else if(bad_va)
	  begin
	     /* AdEL: access-level / VA out-of-range -- must beat tlb_miss (an OOR
	      * mapped VA also misses the ITLB; Address Error outranks TLB refill). */
	     uop.op = FETCH_ADDR_ERROR;
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
		      6'd48: /* tge  */
			begin
			   uop.op = TGE;
			   uop.srcA = rs; uop.srcA_valid = 1'b1;
			   uop.srcB = rt; uop.srcB_valid = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd49: /* tgeu */
			begin
			   uop.op = TGEU;
			   uop.srcA = rs; uop.srcA_valid = 1'b1;
			   uop.srcB = rt; uop.srcB_valid = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd50: /* tlt  */
			begin
			   uop.op = TLT;
			   uop.srcA = rs; uop.srcA_valid = 1'b1;
			   uop.srcB = rt; uop.srcB_valid = 1'b1;
			   uop.is_int = 1'b1;
			end
		      6'd51: /* tltu */
			begin
			   uop.op = TLTU;
			   uop.srcA = rs; uop.srcA_valid = 1'b1;
			   uop.srcB = rt; uop.srcB_valid = 1'b1;
			   uop.is_int = 1'b1;
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
		      'd16:
			begin /* BLTZAL */
			   uop.op = BLTZAL;
			   uop.dst_valid = 1'b1;
			   uop.dst = 'd31;
			   uop.srcB = 'd31;
			   uop.srcB_valid = 1'b1;
			end
		      'd18:
			begin /* BLTZALL (likely) */
			   uop.op = BLTZALL;
			   uop.has_nullifying_delay_slot = 1'b1;
			   uop.dst_valid = 1'b1;
			   uop.dst = 'd31;
			   uop.srcB = 'd31;
			   uop.srcB_valid = 1'b1;
			end
		      'd19:
			begin /* BGEZALL (likely) */
			   uop.op = BGEZALL;
			   uop.has_nullifying_delay_slot = 1'b1;
			   uop.dst_valid = 1'b1;
			   uop.dst = 'd31;
			   uop.srcB = 'd31;
			   uop.srcB_valid = 1'b1;
			end
		      /* trap-immediates: srcA=rs (set above), compare vs sign-ext imm;
		       * reuse the register-trap ops with srcB_valid=0.  These are NOT
		       * branches -> undo the branch fields the common block set. */
		      'd8:  begin uop.op = TGE;  uop.has_delay_slot=1'b0; uop.is_br=1'b0; end /* tgei  */
		      'd9:  begin uop.op = TGEU; uop.has_delay_slot=1'b0; uop.is_br=1'b0; end /* tgeiu */
		      'd10: begin uop.op = TLT;  uop.has_delay_slot=1'b0; uop.is_br=1'b0; end /* tlti  */
		      'd11: begin uop.op = TLTU; uop.has_delay_slot=1'b0; uop.is_br=1'b0; end /* tltiu */
		      'd12: begin uop.op = TEQ;  uop.has_delay_slot=1'b0; uop.is_br=1'b0; end /* teqi  */
		      'd14: begin uop.op = TNE;  uop.has_delay_slot=1'b0; uop.is_br=1'b0; end /* tnei  */
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
		    else if((insn[25]==1'b1) & (insn[24:6] == 19'd0) & (insn[5:0] == 6'd32))
		      begin
			 /* WAIT: r9999 has no low-power halt -- treat as NOP so the kernel
			  * idle loop (r4k_wait) spins with interrupts enabled instead of
			  * RI-faulting (same approach as CACHE->NOP). */
			 uop.op = NOP;
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
		    if(!cu1)
		      begin /* CP1 with FPU disabled -> Coprocessor Unusable, CE=1 */
			 uop.op = CPU;
			 uop.cpu_ce1 = 1'b1;
		      end
		    else
		    if((insn[25:21]==5'd0) && (insn[10:0] == 11'd0))
		      begin /* mfc1: GPR[rt] <- FPR[fs] */
			 uop.dst = rt;
			 uop.dst_valid = 1'b1;
			 uop.op = MFC1;
			 /* FR=0: read the EVEN reg of the pair; jmp_imm[0]=fs[0] picks the
			  * 32b half to extract (low=even, high=odd).  FR=1: whole reg, low32. */
			 if(!fr)
			   begin
			      uop.srcB = {fs[`LG_PRF_ENTRIES-1:1], 1'b0};
			      uop.jmp_imm[0] = fs[0];
			   end
			 else
			   uop.srcB = fs;
			 uop.fp_srcB_valid = 1'b1;
			 uop.is_mem = 1'b1;
		      end
		    else if((insn[25:21]==5'd4) && (insn[10:0] == 11'd0))
		      begin /* mtc1: FPR[fs] <- GPR[rt] */
			 uop.srcA = rt;
			 uop.srcA_valid = 1'b1;
			 uop.op = MTC1;
			 /* FR=0: write the EVEN reg; read it too (srcB) as the merge old-value;
			  * jmp_imm[0]=fs[0] picks the half to overwrite.  FR=1: whole reg. */
			 if(!fr)
			   begin
			      uop.dst = {fs[`LG_PRF_ENTRIES-1:1], 1'b0};
			      uop.srcB = {fs[`LG_PRF_ENTRIES-1:1], 1'b0};
			      uop.fp_srcB_valid = 1'b1;
			      uop.jmp_imm[0] = fs[0];
			   end
			 else
			   uop.dst = fs;
			 uop.fp_dst_valid = 1'b1;
			 uop.is_mem = 1'b1;
		      end // if ((insn[25:21]==5'd4) && (insn[10:0] == 11'd0))
		    else if((insn[25:21]==5'd2) && (insn[10:0] == 11'd0))
		      begin /* cfc1: GPR[rt] <- FCR[fs] (fs=insn[15:11]: 0=FIR, 31=FCSR) */
			 uop.op = CFC1;
			 uop.dst = rt;
			 uop.dst_valid = 1'b1;
			 uop.srcA = fs;        /* carry the FCR number (NOT a PRF read) */
			 uop.is_int = 1'b1;
			 uop.oldest_first = 1'b1;
		      end
		    else if((insn[25:21]==5'd6) && (insn[10:0] == 11'd0))
		      begin /* ctc1: FCR[fs] <- GPR[rt] (only FCR31 is writable) */
			 uop.op = CTC1;
			 uop.dst = fs;         /* carry the FCR number (NOT a PRF write) */
			 uop.srcA = rt;
			 uop.srcA_valid = 1'b1;
			 uop.is_int = 1'b1;
			 uop.serializing_op = 1'b1;
		      end
		    else if((insn[25:21]==5'd1) && (insn[10:0] == 11'd0))
		      begin /* dmfc1: GPR[rt] <- FPR[fs] (full 64b) */
			 if(w_in_64b_mode)
			   begin
			      uop.op = DMFC1;
			      uop.dst = rt;
			      uop.dst_valid = 1'b1;
			      uop.srcB = fs;
			      uop.fp_srcB_valid = 1'b1;
			      uop.is_mem = 1'b1;
			   end
		      end
		    else if((insn[25:21]==5'd5) && (insn[10:0] == 11'd0))
		      begin /* dmtc1: FPR[fs] <- GPR[rt] (full 64b) */
			 if(w_in_64b_mode)
			   begin
			      uop.srcA = rt;
			      uop.srcA_valid = 1'b1;
			      uop.op = DMTC1;
			      uop.dst = fs;
			      uop.fp_dst_valid = 1'b1;
			      uop.is_mem = 1'b1;
			   end
		      end
		    else if(insn[25:21]==5'd8)
		      begin /* BC1x: branch on FP condition code (read FCR) */
			 uop.fcr_src_valid = 1'b1;
			 uop.has_delay_slot = 1'b1;
			 uop.imm = insn[15:0];
			 uop.br_pred = insn_pred;
			 uop.is_br = 1'b1;
			 uop.is_int = 1'b1;
			 /* cc index (which condition-code bit) rides srcC, NOT renamed */
			 uop.srcC = {{(`LG_PRF_ENTRIES-3){1'b0}}, insn[20:18]};
			 case(insn[17:16])
			   2'b00: uop.op = BC1F;
			   2'b01: uop.op = BC1T;
			   2'b10:
			     begin
				uop.op = BC1FL;
				uop.has_nullifying_delay_slot = 1'b1;
			     end
			   2'b11:
			     begin
				uop.op = BC1TL;
				uop.has_nullifying_delay_slot = 1'b1;
			     end
			 endcase
		      end
		    else if((insn[25:21]==5'd16 || insn[25:21]==5'd17) &&
			    (insn[5:0]==6'd0 || insn[5:0]==6'd1 || insn[5:0]==6'd2 || insn[5:0]==6'd3))
		      begin /* ADD/SUB/MUL/DIV.[sd]: fmt 16=single,17=double; func 0=add,1=sub,2=mul,3=div */
			 uop.srcA = fs;
			 uop.fp_srcA_valid = 1'b1;
			 uop.srcB = ft;
			 uop.fp_srcB_valid = 1'b1;
			 uop.dst = fd;
			 uop.fp_dst_valid = 1'b1;
			 uop.is_fp = 1'b1;
			 if(insn[25:21]==5'd16) /* single */
			   uop.op = (insn[5:0]==6'd0) ? SP_ADD :
				    (insn[5:0]==6'd1) ? SP_SUB :
				    (insn[5:0]==6'd2) ? SP_MUL : SP_DIV;
			 else /* double */
			   uop.op = (insn[5:0]==6'd0) ? DP_ADD :
				    (insn[5:0]==6'd1) ? DP_SUB :
				    (insn[5:0]==6'd2) ? DP_MUL : DP_DIV;
		      end
		    else if((insn[25:21]==5'd16 || insn[25:21]==5'd17) && (insn[5:0]==6'd4))
		      begin /* SQRT.[sd]: single source (fs), func 4 */
			 uop.srcA = fs;
			 uop.fp_srcA_valid = 1'b1;
			 uop.dst = fd;
			 uop.fp_dst_valid = 1'b1;
			 uop.is_fp = 1'b1;
			 uop.op = (insn[25:21]==5'd16) ? SP_SQRT : DP_SQRT;
		      end
		    else if((insn[25:21]==5'd16 || insn[25:21]==5'd17) &&
			    (insn[5:0]==6'd5 || insn[5:0]==6'd6 || insn[5:0]==6'd7))
		      begin /* ABS(5)/MOV(6)/NEG(7).[sd]: single FP source, no flags */
			 uop.srcA = fs;
			 uop.fp_srcA_valid = 1'b1;
			 uop.dst = fd;
			 uop.fp_dst_valid = 1'b1;
			 uop.is_fp = 1'b1;
			 if(insn[25:21]==5'd16) /* single */
			   uop.op = (insn[5:0]==6'd5) ? SP_ABS :
				    (insn[5:0]==6'd6) ? SP_MOV : SP_NEG;
			 else /* double */
			   uop.op = (insn[5:0]==6'd5) ? DP_ABS :
				    (insn[5:0]==6'd6) ? DP_MOV : DP_NEG;
		      end
		    else if((insn[25:21]==5'd16 || insn[25:21]==5'd17) && (insn[5:4]==2'b11))
		      begin /* C.cond.fmt: all 16 predicates (func 48..63); cc = insn[10:8] */
			 uop.srcA = fs;
			 uop.fp_srcA_valid = 1'b1;
			 uop.srcB = ft;
			 uop.fp_srcB_valid = 1'b1;
			 uop.fcr_dst_valid = 1'b1; /* alloc a new FCR phys reg */
			 uop.fcr_src_valid = 1'b1; /* read old FCR to keep other CC bits */
			 uop.is_fp = 1'b1;
			 uop.imm = {9'd0, insn[3:0], insn[10:8]}; /* cond->imm[6:3], cc->imm[2:0] */
			 uop.op = (insn[25:21]==5'd16) ? SP_CMP : DP_CMP;
		      end
		    else if((insn[25:21]==5'd16 || insn[25:21]==5'd17) && (insn[5:0]==6'd13))
		      begin /* TRUNC.W.[sd]: FP->int32, round toward zero (f2i) */
			 uop.srcA = fs;
			 uop.fp_srcA_valid = 1'b1;
			 uop.dst = fd;
			 uop.fp_dst_valid = 1'b1;
			 uop.is_fp = 1'b1;
			 uop.op = (insn[25:21]==5'd16) ? TRUNC_W_S : TRUNC_W_D;
		      end
		    else if((insn[25:21]==5'd20) && (insn[5:0]==6'd32 || insn[5:0]==6'd33))
		      begin /* CVT.S.W / CVT.D.W: int32->FP (i2f), FCSR.RM */
			 uop.srcA = fs;
			 uop.fp_srcA_valid = 1'b1;
			 uop.dst = fd;
			 uop.fp_dst_valid = 1'b1;
			 uop.is_fp = 1'b1;
			 uop.op = (insn[5:0]==6'd32) ? CVT_S_W : CVT_D_W;
		      end
			    else if((insn[25:21]==5'd17 && insn[5:0]==6'd32) ||  /* CVT.S.D: D->S narrow */
				    (insn[25:21]==5'd16 && insn[5:0]==6'd33))    /* CVT.D.S: S->D widen */
			      begin /* FP<->FP convert (f2f): narrow rounds per RM, widen is exact */
				 uop.srcA = fs;
				 uop.fp_srcA_valid = 1'b1;
				 uop.dst = fd;
				 uop.fp_dst_valid = 1'b1;
				 uop.is_fp = 1'b1;
				 uop.op = (insn[5:0]==6'd32) ? CVT_S_D : CVT_D_S;
			      end
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
	       6'd24: /* daddi (traps on 64-bit overflow) */
		 begin
		    if(w_in_64b_mode)
		      begin
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.dst = rt;
			 uop.dst_valid = (rt != 'd0);
			 uop.op = DADDI;
			 uop.imm = insn[15:0];
			 uop.is_int = 1'b1;
		      end
		 end
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
		    if(in_kernel_mode)
		      begin
			 uop.op = CACHE_OP;
			 uop.is_int = 1'b1;
			 uop.serializing_op = 1'b1;
			 uop.is_cache = 1'b1;
			 uop.cache_is_d = insn[16];
			 /* operation field insn[20:18]==3'b100 = Hit-Invalidate: drop the
			  * D line WITHOUT writeback (DMA-in). Other D ops write back. */
			 uop.cache_inval = (insn[20:18] == 3'b100);
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.imm = insn[15:0];
		      end
		    else
		      begin
			 uop.op = CPU; /* CACHE outside kernel mode -> Coprocessor Unusable */
		      end
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
	       6'd49: /* LWC1: FPR[ft] <- mem[rs+off] (low 32b) */
		 begin
		    if(!cu1)
		      begin uop.op = CPU; uop.cpu_ce1 = 1'b1; end
		    else
		    begin
		    uop.op = LWC1;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    uop.fp_dst_valid = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		    /* FR=0: write the EVEN reg's jmp_imm[0]-selected 32b half, preserving
		     * the other half.  Read the even reg (srcB) at issue for the merge old
		     * value (spliced at writeback).  FR=1: whole reg ft, plain load. */
		    if(!fr)
		      begin
			 uop.dst = {ft[`LG_PRF_ENTRIES-1:1], 1'b0};
			 uop.srcB = {ft[`LG_PRF_ENTRIES-1:1], 1'b0};
			 uop.fp_srcB_valid = 1'b1;
			 uop.jmp_imm[0] = ft[0];
		      end
		    else
		      uop.dst = ft;
		    end
		 end
	       6'd53: /* LDC1: FPR[ft] <- mem[rs+off] (64b) */
		 begin
		    if(!cu1)
		      begin uop.op = CPU; uop.cpu_ce1 = 1'b1; end
		    else
		    begin
			 uop.op = LDC1;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.dst = ft;
			 uop.fp_dst_valid = 1'b1;
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
		    end
		 end
	       6'd51: /* PREF */
		 begin
		    uop.op = NOP;
		    uop.is_int = 1'b1;
		 end
	       6'd57: /* SWC1: mem[rs+off] <- FPR[ft] (low 32b) */
		 begin
		    if(!cu1)
		      begin uop.op = CPU; uop.cpu_ce1 = 1'b1; end
		    else
		    begin
		    uop.op = SWC1;
		    uop.srcA = rs;
		    uop.srcA_valid = 1'b1;
		    /* FR=0: store the half (even=low, odd=high) of the EVEN reg; jmp_imm[0]
		     * = ft[0] picks it.  FR=1: low 32 of the whole reg. */
		    if(!fr)
		      begin
			 uop.srcB = {ft[`LG_PRF_ENTRIES-1:1], 1'b0};
			 uop.jmp_imm[0] = ft[0];
		      end
		    else
		      uop.srcB = ft;
		    uop.fp_srcB_valid = 1'b1;
		    uop.imm = insn[15:0];
		    uop.is_mem = 1'b1;
		    uop.is_store = 1'b1;
		    end
		 end
	       6'd61: /* SDC1: mem[rs+off] <- FPR[ft] (64b) */
		 begin
		    if(!cu1)
		      begin uop.op = CPU; uop.cpu_ce1 = 1'b1; end
		    else
		    begin
			 uop.op = SDC1;
			 uop.srcA = rs;
			 uop.srcA_valid = 1'b1;
			 uop.srcB = ft;
			 uop.fp_srcB_valid = 1'b1;
			 uop.imm = insn[15:0];
			 uop.is_mem = 1'b1;
			 uop.is_store = 1'b1;
		    end
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

	     /* ---- FR=0 odd-register FP-compute gate (DESIGN NOTE) ----------------
	      * In FR=0 (o32 / MIPS I-II FP model) the 32 FPRs are 16 even/odd 32-bit
	      * pairs, and ARITHMETIC is defined only on even-numbered registers
	      * (R10000 UM p.307, "32- and 64-Bit Operations"; Fig 15-5).  An odd
	      * register on a compute op is architecturally UNPREDICTABLE -- MIPS is
	      * wildly underspecified here: it mandates NO specific exception, and the
	      * Sail spec (sail-cheri-mips) doesn't even model FR (mips_prelude.sail:
	      * "RP/FR/RE/MX/PX not implemented") so it gives no ruling.  The R10000
	      * silently forces the low bit to 0 (treats odd as even) -- a SILENT
	      * fault we refuse.  WE CHOOSE Reserved Instruction (ResI / ExcCode 10):
	      * loud, uses the standard RI code, and is correct as PERMANENT behavior
	      * even once FR=0 is fully supported (odd-reg compute stays malformed; the
	      * FR=0 merge work only makes the VALID cases -- even-reg arith + odd/even
	      * load halves -- work).  This per-op silent-half merge in FR=0 is exactly
	      * why mipscore sprayed MERGE variants through every FP op; we instead gate
	      * compute here and (later) do the R10000 rename-alias + load/move merge.
	      * `is_fp` is set ONLY by FP compute (add/sub/mul/div/sqrt/cmp/cvt/abs/
	      * neg/mov) -- never by moves/loads/stores -- so it selects exactly the
	      * even-only ops.  Unused reg fields are 0 in valid encodings (compares:
	      * insn[6]=0; single-src: ft=0), so the uniform fs|ft|fd low-bit test is
	      * safe and, on a malformed encoding, conservatively faults. */
	     /* (compute) is_fp ops: any odd fs/ft/fd.  (doubleword) LDC1/SDC1: odd ft
	      * (insn[20:16]) -- a 64-bit double can't be named by an odd reg in FR=0
	      * (R10000 UM p.305, "if the register selected is odd, the load/store is
	      * invalid").  Singleword lwc1/swc1/mtc1/mfc1 are NOT faulted here -- odd
	      * selects the high half (Part 2b merge/extract). */
	     if((fr == 1'b0) &&
		((uop.is_fp && (insn[11] | insn[16] | insn[6])) ||
		 ((uop.op == LDC1 || uop.op == SDC1) && insn[16])))
	       begin
		  uop.op            = II;   /* -> is_ii -> ARCH_FAULT -> cause 10 (ResI) */
		  uop.is_fp         = 1'b0;
		  uop.is_mem        = 1'b0;
		  uop.is_store      = 1'b0;
		  uop.fp_srcA_valid = 1'b0;
		  uop.fp_srcB_valid = 1'b0;
		  uop.fp_dst_valid  = 1'b0;
		  uop.fcr_src_valid = 1'b0;
		  uop.fcr_dst_valid = 1'b0;
		  uop.srcA_valid    = 1'b0;
		  uop.dst_valid     = 1'b0;
	       end
	  end // always_comb
     end   

endmodule
   
