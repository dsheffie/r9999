`ifndef __uop_hdr__
`define __uop_hdr__

`include "machine.vh"

typedef enum logic [7:0]
  {
   SLL = 'd0, //0
   SRL = 'd1, //1
   SRA = 'd2, //2
   SLLV = 'd3, //3
   SRLV = 'd4,
   SRAV = 'd5, //6
   JR = 'd6, //7
   JALR = 'd7,
   MFHI = 'd8,
   MTHI = 'd9,
   MULT = 'd10,
   MULTU = 'd11,
   DIV = 'd12,
   DIVU = 'd13,
   ADD = 'd14,
   ADDU = 'd15,
   SUB = 'd16,
   SUBU = 'd17,
   AND = 'd18,
   OR = 'd19,
   XOR = 'd20,
   NOR = 'd21,
   SLT = 'd22,
   SLTU = 'd23,
   MFLO = 'd24,
   MTLO = 'd25,
   BEQ  = 'd26,
   BNE  = 'd27,
   BLEZ = 'd28,
   BGTZ = 'd29,
   ADDI = 'd30,
   ADDIU = 'd31,
   SLTI = 'd32,
   SLTIU = 'd33,
   ANDI = 'd34,
   ORI = 'd35,
   XORI = 'd36,
   LUI = 'd37,
   J = 'd38, 
   JAL = 'd39,
   MFC0 = 'd40,
   MTC0 = 'd41,
   MFC1 = 'd42,
   MTC1 = 'd43,
   LW = 'd44,
   LB = 'd45,
   LBU = 'd46,
   LH = 'd47,
   LHU = 'd48,
   SB = 'd49,
   SH = 'd50,
   SW = 'd51,
   BEQL = 'd52,
   BNEL = 'd53, 
   BLTZ = 'd54, 
   BGEZ = 'd55,
   BLTZL = 'd56,
   BGEZL = 'd57,
   BGTZL = 'd58,
   BLEZL = 'd59,
   TEQ = 'd60,
   LWL = 'd61,
   LWR = 'd62,
   SWL = 'd63,
   SWR = 'd64,
   BAL = 'd65,
   BGEZAL = 'd66,
   BGEZALL = 'd67,
   SC = 'd68,
   BREAK = 'd69,
   MTC1_MERGE = 'd70,
   MFC1_MERGE = 'd71,
   MOVI = 'd72,
   MOV = 'd73,
   NOP = 'd75,
   ERET = 'd76,
   SYSCALL = 'd77,
   TLBR = 'd78,
   TLBWI = 'd79,
   TLBWR = 'd80,
   TLBP = 'd81,
   DADD = 'd82,
   DADDU = 'd83,
   DSUB = 'd84,
   DSUBU = 'd85,
   DADDIU = 'd86,
   DADDI = 'd87,
   LD = 'd88,
   SD = 'd89,
   DSLL   = 'd90,
   DSRL   = 'd91,
   DSRA   = 'd92,
   DSLL32 = 'd93,
   DSRL32 = 'd94,
   DSRA32 = 'd95,
   DSLLV  = 'd96,
   DSRLV  = 'd97,
   DSRAV  = 'd98,
   DMFC0  = 'd99,
   DMTC0  = 'd100,
   LWU    = 'd101,
   DMULT,
   DMULTU,
   DDIV,
   DDIVU,
   LDL,
   LDR,
   SDL,
   SDR,
   LL,
   LLD,
   SCD,
   TNE,
   FETCH_MISALIGNED,
   FETCH_ADDR_ERROR,   /* i-side AdEL: access-level / VA-range violation (BadVAddr=PC, ExcCode 4) */
   FETCH_TLB_MISS,
   FETCH_TLB_INVALID,
   II,
   IRQ,
   CPU,
   CACHE_OP,  /* MIPS CACHE: completes benignly in the ALU, then serializes to flush */
   /* branch-and-link REGIMM variants (BGEZAL/BGEZALL already above) */
   BLTZAL,
   BLTZALL,
   /* register/immediate traps (the immediate forms reuse these ops with
    * srcB_valid=0 and compare against the sign-extended imm; TEQ/TNE reused) */
   TGE,
   TGEU,
   TLT,
   TLTU,
   /* FP loads/stores */
   LWC1,
   SWC1,
   LDC1,
   SDC1,
   CFC1,  /* move from FP control reg (FCR0=FIR / FCR31=FCSR) -> GPR */
   CTC1,  /* move GPR -> FP control reg (FCR31=FCSR) */
   DMTC1, /* 64-bit GPR -> FPR move (full reg, no sign-ext) */
   DMFC1, /* 64-bit FPR -> GPR move (full reg) */
   /* FP arithmetic (COP1) -- routed to the FP issue queue / fpu unit.
    * Names match mipscore's fpu.sv (which fpu.sv references). */
   SP_ADD,
   DP_ADD,
   SP_SUB,
   DP_SUB,
   SP_MUL,
   DP_MUL,
   /* FP compares: write the FCR condition-code bit */
   SP_CMP_LT,
   DP_CMP_LT,
   SP_CMP_EQ,
   DP_CMP_EQ,
   SP_CMP_LE,
   DP_CMP_LE,
   /* FP branches (read the FCR condition-code bit; run in the int pipe) */
   BC1T,
   BC1F,
   BC1TL,
   BC1FL
   } opcode_t;

function logic is_mult(opcode_t op);
   logic     x;
   case(op)
     MULT:
       x = 1'b1;
     MULTU:
       x = 1'b1;
     DMULT:
       x = 1'b1;
     DMULTU:
       x = 1'b1;
     default:
       x = 1'b0;
   endcase
   return x;
endfunction // is_mult

function logic is_div(opcode_t op);
   logic     x;
   case(op)
     DIV:
       x = 1'b1;
     DIVU:
       x = 1'b1;
     DDIV:
       x = 1'b1;
     DDIVU:
       x = 1'b1;
     default:
       x = 1'b0;
   endcase
   return x;
endfunction // is_div

function logic is_store(opcode_t op);
   logic     x;
   case(op)
     SB:
       x = 1'b1;
     SH:
       x = 1'b1;
     SW:
       x = 1'b1;
     SC:
       x = 1'b1;
     SWR:
       x = 1'b1;
     SWL:
       x = 1'b1;
     SD:
       x = 1'b1;
     SDL:
       x = 1'b1;
     SDR:
       x = 1'b1;
     SCD:
       x = 1'b1;
     default:
       x = 1'b0;
   endcase // case (op)
   return x;
endfunction // is_store



typedef struct packed {
   opcode_t op;
   
   logic [`LG_PRF_ENTRIES-1:0] srcA;
   logic 		       srcA_valid;
   logic 		       fp_srcA_valid;
   logic [`LG_PRF_ENTRIES-1:0] srcB;
   logic 		       srcB_valid;
   logic 		       fp_srcB_valid;
   logic [`LG_PRF_ENTRIES-1:0] srcC;
   logic 		       srcC_valid;
   logic 		       fp_srcC_valid;
   logic [`LG_PRF_ENTRIES-1:0] dst;
   logic 		       dst_valid;
   logic 		       fp_dst_valid;
   logic 		       fcr_dst_valid;

   logic 		       hilo_dst_valid;
   logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_dst;

   logic 			    hilo_src_valid;
   logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_src;
   logic 			    fcr_src_valid;
     
   logic 		       has_delay_slot;
   logic 		       has_nullifying_delay_slot;
   logic [15:0] 	       imm;
   logic [`M_WIDTH-17:0]       jmp_imm;
   logic [`M_WIDTH-1:0]        pc;
   logic [`M_WIDTH-1:0]        pred_target;
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic 		       serializing_op;
   logic 		       must_restart;
   logic 		       oldest_first;
   logic 		       br_pred;
   logic 		       is_int;
   logic 		       is_br;
   logic 		       is_mem;
   logic 		       is_store;
   logic 		       is_cache;   /* MIPS CACHE op (serializing flush) */
   logic 		       cache_is_d; /* CACHE targets D-cache (per-line WB) vs I-cache (whole nuke) */
   logic 		       cache_inval; /* CACHE Hit-Invalidate: drop the line WITHOUT writeback (DMA-in) */
   logic 		       is_fp;   /* compute FP op (routes to the FP issue queue) */
   logic [`LG_PHT_SZ-1:0]      pht_idx;
   logic		       mode_when_fetched;
`ifdef VERILATOR
   logic [31:0] 	       clear_id;
`endif
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] 	    fetch_cycle;
`endif   
} uop_t;



`endif
