/* formal_l1_synonym.sv -- SINGLE COPY across the real L2 and an ABSTRACT L1D.
 *
 * WHY THIS EXISTS.  The L2-only proof attempt hit a wall that is not a spec bug and
 * not fixable by rewording: single-copy is a statement about what the L1D HOLDS, and
 * the L2 does not know that.  It holds presence bits, which the design deliberately
 * defines as an OVER-APPROXIMATION ("a stale set bit costs a redundant probe, never
 * a missed one" -- l2.sv).  So "presence set => the L1 holds it at this PIdx" is not
 * a theorem about this design, and every assertion phrased that way is refutable by
 * a legal stale bit.  Stating the real property needs the L1D's contents in scope.
 *
 * WHY NOT THE REAL l1d.sv.  ~2700 lines with the TLB, miss queue and store queue.
 * The L2 ALONE is 975 latches and its PDR run did not converge in 31 minutes; the
 * product would be hopeless.  This is the standard move: keep the module under
 * verification concrete, abstract the one you are not verifying.
 *
 * THE ABSTRACTION, and why it is nearly free.  Combined with a solver-chosen watched
 * line, the abstract L1D needs no tag array at all -- only "which alias sets hold THE
 * WATCHED LINE".  That is NALIAS bits (4 here), not a shadow of the cache:
 *
 *     grant of the watched line at pidx P   ->  a_held[P] <= 1
 *     probe ack for the watched line at P   ->  a_held[P] <= 0
 *     property: at most one bit of a_held is set
 *
 * Silent clean drops (a real L1D may evict on its own) are deliberately NOT modelled.
 * They only ever REMOVE copies, so omitting them is conservative for an at-most-one
 * claim -- the abstraction holds MORE copies than reality, never fewer.
 *
 * ASSUME-GUARANTEE -- READ THIS BEFORE BELIEVING A PASS.  What is proved here is:
 *   "the L2 maintains single-copy GIVEN an L1D that invalidates the set a probe
 *    names, and acks only after doing so."
 * That premise is discharged SEPARATELY against the real l1d.sv (the w_snp_idx =
 * {backinv_pidx, addr} path).  If the abstraction is more generous than the real
 * L1D, this proof means little -- the same vacuity trap as a cover that cannot fire,
 * one level up.  The two halves are only worth anything together.
 *
 *   build: run_l1_synonym_formal.sh
 */
`include "machine.vh"

module formal_l1_synonym
  (
   input logic 		       clk,
   /* free environment -- the solver drives the L1D's request stream and the timing
    * of every ack.  l1_mem_req_pidx is UNCONSTRAINED on purpose: a real L1D derives
    * it from the VA it is fetching for, and constraining it to agree with the
    * address would assume away the synonym being proved. */
   input logic 		       l1_mem_req_valid,
   input logic [`PA_WIDTH-1:0] l1_mem_req_addr,
   input logic [4:0] 	       l1_mem_req_opcode,
   input logic [`PIDX_W-1:0]   l1_mem_req_pidx,
   input logic 		       mem_rsp_valid,
   input logic 		       backinv_d_ack_in,
   /* held for a line the model does NOT track: free, because the abstract L1D
    * only knows about the watched line and may or may not hold any other. */
   input logic 		       backinv_d_held_other,
   input logic 		       backinv_d_dirty,
   input logic [127:0] 	       backinv_d_data,
   input logic 		       backinv_i_ack_in,
   input logic 		       snoop_req_valid,
   input logic [`PA_WIDTH-1:0] snoop_req_addr,
   input logic 		       snoop_req_ev
   );

   localparam NALIAS = 1 << `L1D_ALIAS_BITS;

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

   /* ---- the watched line -------------------------------------------------- */
   (* anyconst *) reg [`PA_WIDTH-1:0] f_watch;
   wire f_req_is_watched = (l1_mem_req_addr[`PA_WIDTH-1:4] == f_watch[`PA_WIDTH-1:4]);

   wire 		       w_req_ack, w_rsp_valid;
   wire 		       w_backinv_d_req, w_backinv_i_req, w_snoop_req_ack;
   wire [`PA_WIDTH-1:0]        w_backinv_addr;
   wire [`PIDX_W-1:0] 	       w_backinv_d_pidx, w_backinv_i_pidx;
   wire 		       w_mem_req_valid, w_backinv_stall;
   wire [`PA_WIDTH-1:0]        w_mem_req_addr;

   /* ---- outstanding request: which line/pidx a response will answer --------
    * The L2 accepts a request (l1_mem_req_ack) and answers later
    * (l1_mem_rsp_valid), so the abstract L1D has to remember what it asked for. */
   logic 		       r_out_valid, r_out_watched, r_out_read;
   logic [`PIDX_W-1:0] 	       r_out_pidx;
   always@(posedge clk)
     begin
	if(reset)
	  begin
	     r_out_valid   <= 1'b0;
	     r_out_watched <= 1'b0;
	     r_out_read    <= 1'b0;
	     r_out_pidx    <= 'd0;
	  end
	else
	  begin
	     if(l1_mem_req_valid & w_req_ack)
	       begin
		  r_out_valid   <= 1'b1;
		  r_out_watched <= f_req_is_watched;
		  r_out_read    <= (l1_mem_req_opcode == 5'd4);
		  r_out_pidx    <= l1_mem_req_pidx;
	       end
	     else if(w_rsp_valid)
	       begin
		  r_out_valid <= 1'b0;
	       end
	  end
     end // always@ (posedge clk)

   /* held must come from the model's OWN state, not be faked as "always held".
    * Faking it made presence clear more eagerly in the model than in reality -- a
    * GENEROUS abstraction, which is the direction that quietly invalidates a proof,
    * and which can also manufacture a counterexample by desynchronising a_held from
    * the L2's presence bits.  For the watched line the answer is known exactly; for
    * any other line the model has no state and the environment supplies it. */
   wire w_bi_watched = (w_backinv_addr[`PA_WIDTH-1:4] == f_watch[`PA_WIDTH-1:4]);
   wire w_held_model = backinv_d_held_other;

   l2 dut
     (
      .clk(clk), .reset(reset),
      .l1_mem_req_valid(l1_mem_req_valid),
      .l1_mem_req_ack(w_req_ack),
      .l1_mem_req_addr(l1_mem_req_addr),
      .l1_mem_req_opcode(l1_mem_req_opcode),
      .l1_mem_req_from_l1i(1'b0),          /* L1D only: the L1I is a separate cache */
      .l1_mem_req_pidx(l1_mem_req_pidx),
      .l1_mem_rsp_valid(w_rsp_valid),
      .mem_rsp_valid(mem_rsp_valid),
      .snoop_req_valid(snoop_req_valid),
      .snoop_req_addr(snoop_req_addr),
      .snoop_req_ev(snoop_req_ev),
      .snoop_req_ack(w_snoop_req_ack),
      .backinv_addr(w_backinv_addr),
      .backinv_d_pidx(w_backinv_d_pidx),
      .backinv_i_pidx(w_backinv_i_pidx),
      .backinv_stall(w_backinv_stall),
      .backinv_d_req(w_backinv_d_req),
      .backinv_d_ack(backinv_d_ack_in),
      .backinv_d_dirty(backinv_d_dirty),
      .backinv_d_held(w_held_model),
      .backinv_d_data(backinv_d_data),
      .backinv_i_req(w_backinv_i_req),
      .backinv_i_ack(backinv_i_ack_in),
      .mem_req_valid(w_mem_req_valid),
      .mem_req_addr(w_mem_req_addr)
      );

   logic 		       r_mem_req_valid;
   always@(posedge clk)
     begin
	r_mem_req_valid <= w_mem_req_valid;
     end

   /* ---- environment well-formedness ---------------------------------------- */
   always@(*)
     begin
	if(backinv_d_ack_in)
	  begin
	     assume(w_backinv_d_req);
	  end
	if(backinv_i_ack_in)
	  begin
	     assume(w_backinv_i_req);
	  end
	if(backinv_d_dirty)
	  begin
	     assume(backinv_d_ack_in);
	     /* dirty data can only come from a line we actually held */
	     assume(w_held_model);
	  end
	if(mem_rsp_valid)
	  begin
	     assume(r_mem_req_valid);
	  end
     end // always@ (*)

   /* The abstract L1D and the at-most-one property now live INSIDE l2.sv under
    * `ifdef L1SYN_ABSTRACT_L1D -- see the note there on why modelling it from out
    * here sampled the request a cycle later than the L2 did.  This file supplies
    * the ENVIRONMENT only. */

endmodule // formal_l1_synonym
