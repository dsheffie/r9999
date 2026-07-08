// Prove the decoder never emits a valid integer dest of logical reg 0.
// Expose the violation as an output; yosys `sat -set bad 1` must be UNSAT.
module formal_decode(
   input logic [31:0] 		insn,
   input logic 			in_kernel_mode, in_supervisor_mode, in_user_mode,
   input logic 			in_64b_kernel_mode, in_64b_supervisor_mode, in_64b_user_mode,
   input logic 			cu1, fr, irq, tlb_miss, tlb_invalid, misaligned, bad_va, insn_pred,
   input logic [`M_WIDTH-1:0] 	pc, insn_pred_target,
   input logic [`LG_PHT_SZ-1:0] pht_idx,
   output logic 		dv,     // dst_valid  (sanity: must be reachable =1)
   output logic 		bad     // dst_valid & (dst==0)  (invariant: must be unreachable =1)
);
   uop_t uop;
   decode_mips dec(
      .in_kernel_mode(in_kernel_mode), .in_supervisor_mode(in_supervisor_mode), .in_user_mode(in_user_mode),
      .in_64b_kernel_mode(in_64b_kernel_mode), .in_64b_supervisor_mode(in_64b_supervisor_mode),
      .in_64b_user_mode(in_64b_user_mode), .cu1(cu1), .fr(fr), .irq(irq), .tlb_miss(tlb_miss),
      .tlb_invalid(tlb_invalid), .misaligned(misaligned), .bad_va(bad_va), .insn(insn), .pc(pc),
      .insn_pred(insn_pred), .pht_idx(pht_idx), .insn_pred_target(insn_pred_target), .uop(uop)
   );
   assign dv  = uop.dst_valid;
   assign bad = uop.dst_valid & (uop.dst == 'd0);
endmodule
