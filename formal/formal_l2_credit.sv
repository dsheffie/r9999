/* formal_l2_credit.sv -- prove the L2's recovered-dirty-data CREDIT is conserved.
 *
 * WHY FORMAL AND NOT SIMULATION.  The bug being chased is a store that reaches the
 * L2 and never reaches DRAM.  It is a safety violation on a single-entry shared
 * resource (r_wb_pend / r_wb_addr / r_wb_data), and simulation found it only as a
 * kernel panic ~90M cycles downstream.  Three targeted simulation probes -- a
 * WAIT_BI leak reporter, a slot-overwrite reporter, and a per-transaction log --
 * each came back clean while the credit demonstrably went missing within 230
 * merges.  A counting invariant is exactly what bounded model checking settles in
 * tens of cycles, and k-induction settles for all time.
 *
 * STYLE.  Immediate assert/assume/cover inside a clocked block, and reset driven by
 * a cycle counter -- copied from formal_top.v, which is the flow in this repo that
 * is known to work.  An earlier version of this file used concurrent SVA
 * (`assert property (@(posedge clk) a |-> b)`, $past, $changed); that is the corner
 * of SystemVerilog yosys supports least well, and it is not needed for any of these
 * properties.
 *
 * THE INVARIANTS
 *   no_overflow : credits never exceed the number of holding slots.  A violation
 *                 means a double return -- a credit handed back twice.
 *   held_implies : credit_held is set iff a credit is outstanding.  These are two
 *                 registers encoding one fact, and today they are updated from
 *                 decoupled blocks (the bq pop takes, the merge returns), which is
 *                 the prime suspect for the leak.
 *   slot_excl   : r_wb_pend is never overwritten while already set -- the recovered
 *                 line would be destroyed.
 *
 * ENVIRONMENT.  The L1D and DRAM are left FREE (arbitrary ack latency, arbitrary
 * dirty, arbitrary response timing); that freedom is the point of the method.  Only
 * minimal well-formedness is assumed, because over-constraining is how a formal run
 * proves something vacuously.  Each assumption below is a claim about the RTL's
 * environment and is listed so it can be argued with.
 *
 * VACUITY.  The cover targets must be reachable or the proof is meaningless, exactly
 * like the `active` signal in formal_l1d_fwd.sv.  Check them before believing a PASS.
 *
 *   build: run_l2_credit_formal.sh
 */
`include "machine.vh"

module formal_l2_credit
  (
   input logic 		       clk,
   /* free environment inputs -- the solver picks these */
   input logic 		       l1_mem_req_valid,
   input logic [`PA_WIDTH-1:0] l1_mem_req_addr,
   input logic [4:0] 	       l1_mem_req_opcode,
   input logic 		       mem_rsp_valid,
   input logic 		       backinv_d_ack,
   input logic 		       backinv_d_dirty,
   input logic 		       backinv_d_held,
   input logic [127:0] 	       backinv_d_data,
   input logic 		       backinv_i_ack,
   input logic 		       snoop_req_valid,
   input logic [`PA_WIDTH-1:0] snoop_req_addr,
   input logic 		       snoop_req_ev
   );

   /* ---- reset sequencing (formal_top.v's idiom) ---------------------------- */
   logic [7:0] 		       r_cycle;
   logic 		       reset;
   initial
     begin
	r_cycle = 8'd0;
     end
   always@(posedge clk)
     begin
	r_cycle <= (&r_cycle) ? 8'd255 : (r_cycle + 8'd1);
     end
   assign reset = (r_cycle < 8'd2);

   /* ---- the DUT, at FORMAL geometry (small L2) ----------------------------- */
   wire 		       w_backinv_d_req, w_backinv_i_req, w_snoop_req_ack;
   wire [`PA_WIDTH-1:0]        w_backinv_addr;
   wire 		       w_mem_req_valid, w_backinv_stall;
   wire [`PA_WIDTH-1:0]        w_mem_req_addr;

   l2 dut
     (
      .clk(clk), .reset(reset),
      .l1_mem_req_valid(l1_mem_req_valid),
      .l1_mem_req_addr(l1_mem_req_addr),
      .l1_mem_req_opcode(l1_mem_req_opcode),
      .mem_rsp_valid(mem_rsp_valid),
      .snoop_req_valid(snoop_req_valid),
      .snoop_req_addr(snoop_req_addr),
      .snoop_req_ev(snoop_req_ev),
      .snoop_req_ack(w_snoop_req_ack),
      .backinv_addr(w_backinv_addr),
      .backinv_stall(w_backinv_stall),
      .backinv_d_req(w_backinv_d_req),
      .backinv_d_ack(backinv_d_ack),
      .backinv_d_dirty(backinv_d_dirty),
      .backinv_d_held(backinv_d_held),
      .backinv_d_data(backinv_d_data),
      .backinv_i_req(w_backinv_i_req),
      .backinv_i_ack(backinv_i_ack),
      .mem_req_valid(w_mem_req_valid),
      .mem_req_addr(w_mem_req_addr)
      );

   /* one-cycle history, in place of $past */
   logic 		       r_mem_req_valid;
   always@(posedge clk)
     begin
	r_mem_req_valid <= w_mem_req_valid;
     end

   /* ---- environment well-formedness ------------------------------------------
    * Each of these is a CLAIM about how the L1D and DRAM behave.  If one is wrong,
    * the proof is about a machine that does not exist. */
   always@(*)
     begin
	/* an ack only in response to an outstanding request -- the L1D cannot ack
	 * something it was never asked to do */
	if(backinv_d_ack)
	  begin
	     assume(w_backinv_d_req);
	  end
	if(backinv_i_ack)
	  begin
	     assume(w_backinv_i_req);
	  end
	/* dirty data only accompanies an ack from a line the L1D actually held */
	if(backinv_d_dirty)
	  begin
	     assume(backinv_d_ack);
	     assume(backinv_d_held);
	  end
	/* a memory response only after a request */
	if(mem_rsp_valid)
	  begin
	     assume(r_mem_req_valid);
	  end
     end // always@ (*)

   /* ---- the invariants live INSIDE l2.sv, under `ifdef FORMAL ----------------
    * They are NOT here.  Yosys's Verilog frontend does not resolve cross-module
    * hierarchical references: writing `dut.r_wb_credits` in this file does not reach
    * into the instance, it silently declares a floating wire whose name happens to
    * contain a dot, and `setundef -anyseq` then makes it a free solver input.  The
    * assertions constrain nothing, no counterexample is possible, and the run reports
    * a confident PASS.  The only warning is an easily-missed
    *   "Wire formal_l2_credit.\dut.r_wb_credits is used but has no driver".
    * This file therefore supplies only the ENVIRONMENT; the properties sit beside the
    * registers they talk about. */

endmodule // formal_l2_credit
