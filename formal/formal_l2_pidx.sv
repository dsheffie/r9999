/* formal_l2_pidx.sv -- prove the R10000 PIdx SINGLE-COPY contract.
 *
 * THE PROPERTY.  A primary cache indexed by virtual address and tagged by physical
 * address can hold one line in 2^ALIAS_BITS different sets depending on which VA
 * reached it.  If the L2 hands out a second copy at a new set while the first is
 * still resident and dirty, one of the two is silently lost.  The L2 therefore
 * records WHICH set it gave each line to (PIdx) and must back-invalidate the old
 * set before granting a different one.
 *
 * WHY FORMAL.  The directed test tests/cache/test_l1_synonym.S drives exactly one
 * interleaving: store via VA_A, load via VA_B.  The real hazard is a synonym request
 * arriving concurrently with an eviction, a snoop, or an in-flight back-invalidate
 * ack -- and this session has already produced FOUR bugs whose entire cause was the
 * statement order between two such paths in one always_comb (the most recent: an
 * eviction back-invalidate issued on a snoop-ack cycle overwrote the ack's clear, so
 * req never fell and both engines waited on each other forever).  Enumerating those
 * interleavings by hand is exactly what a model checker does for free.
 *
 * GEOMETRY -- THE LOAD-BEARING PART.  A synonym exists only when the cache is LARGER
 * than a page.  The stock FORMAL geometry is a 4-line L1D against a 4KB page, which
 * has ZERO alias bits: every PIdx is 0, the compare is trivially true, and the proof
 * passes while proving nothing.  So the runner shrinks the PAGE alongside the caches
 * -- LG_PG_SZ=6 (64B pages), LG_L1D_NUM_SETS=4 (16 sets = 256B) -- which preserves
 * the cache>page relationship that creates aliasing while keeping the state small.
 * The cover points in l2.sv are what actually detect the vacuous case; check them
 * before believing a PASS.
 *
 * ENVIRONMENT.  The L1s and DRAM are left FREE -- arbitrary ack latency, arbitrary
 * dirty, arbitrary response timing, and crucially an arbitrary l1_mem_req_pidx, so
 * the solver is free to request the same line at any set.  That freedom is the whole
 * method.  Only minimal well-formedness is assumed, and each assumption is a claim
 * about the environment that can be argued with.
 *
 * PROPERTIES LIVE IN l2.sv, not here -- yosys does not resolve cross-module
 * hierarchical references, and `dut.w_l1d_pidx` in this file would silently become a
 * floating wire that setundef hands the solver as a free input, constraining nothing
 * while still reporting PASS.  This file supplies only the environment.
 *
 *   build: run_l2_pidx_formal.sh
 */
`include "machine.vh"

module formal_l2_pidx
  (
   input logic 		       clk,
   /* free environment inputs -- the solver picks these */
   input logic 		       l1_mem_req_valid,
   input logic [`PA_WIDTH-1:0] l1_mem_req_addr,
   input logic [4:0] 	       l1_mem_req_opcode,
   input logic 		       l1_mem_req_from_l1i,
   /* the requester names ANY set: this is what makes a synonym reachable */
   input logic [`PIDX_W-1:0]   l1_mem_req_pidx,
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

   /* ---- the DUT, at the ALIASING formal geometry --------------------------- */
   wire 		       w_backinv_d_req, w_backinv_i_req, w_snoop_req_ack;
   wire [`PA_WIDTH-1:0]        w_backinv_addr;
   wire [`PIDX_W-1:0] 	       w_backinv_d_pidx, w_backinv_i_pidx;
   wire 		       w_mem_req_valid, w_backinv_stall;
   wire [`PA_WIDTH-1:0]        w_mem_req_addr;

   l2 dut
     (
      .clk(clk), .reset(reset),
      .l1_mem_req_valid(l1_mem_req_valid),
      .l1_mem_req_addr(l1_mem_req_addr),
      .l1_mem_req_opcode(l1_mem_req_opcode),
      .l1_mem_req_from_l1i(l1_mem_req_from_l1i),
      .l1_mem_req_pidx(l1_mem_req_pidx),
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

   /* ---- environment well-formedness ---------------------------------------- */
   always@(*)
     begin
	/* an ack only in response to an outstanding request */
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
	/* NOTE: l1_mem_req_pidx is deliberately UNCONSTRAINED.  A real L1 derives it
	 * from the VA it is fetching for, but constraining it to agree with
	 * l1_mem_req_addr here would assume away the very case being proved. */
     end // always@ (*)

endmodule // formal_l2_pidx
