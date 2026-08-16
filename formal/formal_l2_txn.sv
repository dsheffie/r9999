/* formal_l2_txn.sv -- environment for the L2 transaction-pool control core.
 *
 * The properties live INSIDE l2_txn_ctrl.sv under `ifdef FORMAL, not here:
 * yosys does not resolve cross-module hierarchical references, so `dut.r_valid`
 * in a wrapper silently becomes a floating wire that setundef -anyseq hands the
 * solver as a free input -- the assertions would constrain nothing and still
 * report PASS.  This file supplies only the environment.
 *
 * The datapath is left FREE (arbitrary response latency, arbitrary ordering);
 * that freedom is the point of the method.  The only assumptions are that a
 * response refers to a record that actually has that operation outstanding --
 * i.e. the datapath acks what it was asked to do and nothing else.  Each is a
 * claim about the rest of the L2 and is listed so it can be argued with.
 */
`include "machine.vh"

module formal_l2_txn
  (
   input logic 	       clk,
   /* free environment inputs -- the solver picks these */
   input logic 	       alloc_valid,
   input logic [1:0]   alloc_kind,
   input logic [`LG_L2_NUM_SETS-1:0] alloc_idx,
   input logic 	       lookup_ack,
   input logic 	       lookup_ack_slot,
   input logic 	       lookup_hit,
   input logic 	       lookup_dirty,
   input logic 	       lookup_l1_pres,
   input logic 	       probe_ack,
   input logic 	       probe_ack_slot,
   input logic 	       wb_ack,
   input logic 	       wb_ack_slot,
   input logic 	       grant_valid,
   input logic 	       grant_slot
   );

   /* reset sequencing, formal_top.v's idiom */
   logic [7:0] 	       r_cycle;
   logic 	       reset;
   initial
     begin
	r_cycle = 8'd0;
     end
   always@(posedge clk)
     begin
	r_cycle <= (&r_cycle) ? 8'd255 : (r_cycle + 8'd1);
     end
   assign reset = (r_cycle < 8'd2);

   wire        w_alloc_ack, w_issue_valid, w_issue_slot, w_retire_valid;
   wire        w_retire_slot, w_busy;
   wire [1:0]  w_lookup_pend, w_probe_pend, w_wb_pend, w_grant_pend;
   wire [2:0]  w_issue_op;
   wire [`LG_L2_NUM_SETS-1:0] w_issue_idx;

   l2_txn_ctrl dut
     (
      .clk(clk),
      .reset(reset),
      .alloc_valid(alloc_valid),
      .alloc_kind(alloc_kind),
      .alloc_idx(alloc_idx),
      .alloc_ack(w_alloc_ack),
      .issue_valid(w_issue_valid),
      .issue_slot(w_issue_slot),
      .issue_op(w_issue_op),
      .issue_idx(w_issue_idx),
      .lookup_ack(lookup_ack),
      .lookup_ack_slot(lookup_ack_slot),
      .lookup_hit(lookup_hit),
      .lookup_dirty(lookup_dirty),
      .lookup_l1_pres(lookup_l1_pres),
      .probe_ack(probe_ack),
      .probe_ack_slot(probe_ack_slot),
      .wb_ack(wb_ack),
      .wb_ack_slot(wb_ack_slot),
      .grant_valid(grant_valid),
      .grant_slot(grant_slot),
      .retire_valid(w_retire_valid),
      .retire_slot(w_retire_slot),
      .busy(w_busy),
      .w_lookup_pend(w_lookup_pend),
      .w_probe_pend(w_probe_pend),
      .w_wb_pend(w_wb_pend),
      .w_grant_pend(w_grant_pend)
      );

   /* ---- environment well-formedness ---------------------------------------
    * The datapath only ever acks an operation it was actually issued.  Without
    * these the solver may retire a wait bit that was never set, which is not a
    * machine that exists. */
   always@(*)
     begin
	/* via real PORTS, not dut.* -- see the header.  I wrote that warning and
	 * then used hierarchical refs here anyway on the first attempt. */
	if(lookup_ack)
	  begin
	     assume(w_lookup_pend[lookup_ack_slot]);
	  end
	if(probe_ack)
	  begin
	     assume(w_probe_pend[probe_ack_slot]);
	  end
	if(wb_ack)
	  begin
	     assume(w_wb_pend[wb_ack_slot]);
	  end
	if(grant_valid)
	  begin
	     assume(w_grant_pend[grant_slot]);
	  end
     end // always@ (*)

endmodule // formal_l2_txn
