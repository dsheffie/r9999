`ifndef __uop_hdr__
`define __uop_hdr__

`include "machine.vh"

typedef enum logic [6:0] 
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
   II = 'd77, //illegal instruction
   IRQ = 'd78
   } opcode_t;

function logic is_mult(opcode_t op);
   logic     x;
   case(op)
     MULT:
       x = 1'b1;
     MULTU:
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
   logic [`LG_PRF_ENTRIES-1:0] dst;
   logic 		       dst_valid;
   logic 		       fp_dst_valid;

   logic 		       hilo_dst_valid;
   logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_dst;

   logic 			    hilo_src_valid;
   logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_src;
     
   logic 		       has_delay_slot;
   logic 		       has_nullifying_delay_slot;
   logic [15:0] 	       imm;
   logic [`M_WIDTH-17:0]       jmp_imm;
   logic [`M_WIDTH-1:0]        pc;
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic 		       serializing_op;
   logic 		       must_restart;
   logic 		       br_pred;
   logic 		       is_int;
   logic 		       is_br;
   logic 		       is_mem;
   logic 		       is_store;
   logic [`LG_PHT_SZ-1:0]      pht_idx;
`ifdef VERILATOR
   logic [31:0] 	       clear_id;
`endif
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] 	    fetch_cycle;
`endif   
} uop_t;



`endif
