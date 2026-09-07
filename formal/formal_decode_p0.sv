// Prove the decoder can never emit an op whose EXEC arm asserts t_wr_int_prf
// (the int-PRF write enable) while dst_valid=0.  Such a uop reaches exec with
// int_uop.dst = the raw ARCH field (0 for $zero) and poisons the operand-forward
// network for every same-cycle consumer of physreg 0 (srcB of beqz/bnez): the RF
// write port is gated (rf4r2w wrptr0!=0) but the bypass/wakeup matches are NOT.
// The INT_WRITER list below is machine-extracted from exec.sv's t_wr_int_prf=1'b1
// arms (2026-09-03; regenerate if exec.sv case arms change).
// yosys `sat -set bad 1` must be UNSAT; `-set active 1` must be SAT (non-vacuous).
module formal_decode_p0(
   input logic [31:0] 		insn,
   input logic 			in_kernel_mode, in_supervisor_mode, in_user_mode,
   input logic 			in_64b_kernel_mode, in_64b_supervisor_mode, in_64b_user_mode,
   input logic 			cu1, fr, irq, tlb_miss, tlb_invalid, misaligned, bad_va, insn_pred,
   input logic [`M_WIDTH-1:0] 	pc, insn_pred_target,
   input logic [`LG_PHT_SZ-1:0] pht_idx,
   output logic 		active, // an INT_WRITER op decoded at all (vacuity check)
   output logic 		bad,    // INT_WRITER op with dst_valid=0 (must be unreachable)
   output logic 		bad3    // INT_WRITER op with is_mem=1: alloc would hand it a MEM-bank preg
                                        // (>=64) and the exec-port write would alias r_ram_alu[preg-64] --
                                        // preg 64 lands ON p0's storage cell (must be unreachable)
);
   uop_t uop;
   decode_mips dec(
      .in_kernel_mode(in_kernel_mode), .in_supervisor_mode(in_supervisor_mode), .in_user_mode(in_user_mode),
      .in_64b_kernel_mode(in_64b_kernel_mode), .in_64b_supervisor_mode(in_64b_supervisor_mode),
      .in_64b_user_mode(in_64b_user_mode), .cu1(cu1), .fr(fr), .irq(irq), .tlb_miss(tlb_miss),
      .tlb_invalid(tlb_invalid), .misaligned(misaligned), .insn(insn), .pc(pc),
      .insn_pred(insn_pred), .pht_idx(pht_idx), .insn_pred_target(insn_pred_target), .uop(uop),
      .bad_va(bad_va)
   );
   wire w_int_writer = (uop.op == ADD) |
			   (uop.op == ADDI) |
			   (uop.op == ADDIU) |
			   (uop.op == ADDU) |
			   (uop.op == AND) |
			   (uop.op == ANDI) |
			   (uop.op == BAL) |
			   (uop.op == BGEZAL) |
			   (uop.op == BGEZALL) |
			   (uop.op == BLTZAL) |
			   (uop.op == BLTZALL) |
			   (uop.op == CFC1) |
			   (uop.op == DADD) |
			   (uop.op == DADDI) |
			   (uop.op == DADDIU) |
			   (uop.op == DADDU) |
			   (uop.op == DMFC0) |
			   (uop.op == DSLL) |
			   (uop.op == DSLL32) |
			   (uop.op == DSLLV) |
			   (uop.op == DSRA) |
			   (uop.op == DSRA32) |
			   (uop.op == DSRAV) |
			   (uop.op == DSRL) |
			   (uop.op == DSRL32) |
			   (uop.op == DSRLV) |
			   (uop.op == DSUB) |
			   (uop.op == DSUBU) |
			   (uop.op == JAL) |
			   (uop.op == JALR) |
			   (uop.op == LUI) |
			   (uop.op == MFC0) |
			   (uop.op == MFHI) |
			   (uop.op == MFLO) |
			   (uop.op == MOV) |
			   (uop.op == MOVI) |
			   (uop.op == NOR) |
			   (uop.op == NOT) |
			   (uop.op == OR) |
			   (uop.op == ORI) |
			   (uop.op == SLL) |
			   (uop.op == SLLV) |
			   (uop.op == SLT) |
			   (uop.op == SLTI) |
			   (uop.op == SLTIU) |
			   (uop.op == SLTU) |
			   (uop.op == SRA) |
			   (uop.op == SRAV) |
			   (uop.op == SRL) |
			   (uop.op == SRLV) |
			   (uop.op == SUB) |
			   (uop.op == SUBU) |
			   (uop.op == XOR) |
			   (uop.op == XORI);
   assign active = w_int_writer;
   assign bad    = w_int_writer & ~uop.dst_valid;
   assign bad3   = w_int_writer & uop.is_mem;
endmodule // formal_decode_p0
