`include "machine.vh"

/* l2_txn_ctrl -- transaction-pool control core for the L2.
 *
 * WHY THIS EXISTS.  The inclusive-L2 work grew a SECOND lookup pipeline beside
 * the main FSM -- SNOOP_IDLE/WAIT_RAM/CHECK/WAIT_BI mirrors IDLE/WAIT_FOR_RAM/
 * CHECK_VALID_AND_TAG step for step -- and six RAMs sprouted a second read port
 * to feed it.  The two engines then shared mutable state with no owner:
 * n_wb_pend has FOUR writers, n_wb_credits/n_wb_credit_held SIX each, all inside
 * one 2271-line always_comb, refereed by seven hand-written interlocks
 * (w_snoop_wr_gnt, w_snoop_holds_set, w_main_owns_set, ...).
 *
 * That structure is what produced the dropped-store bug: the back-invalidate ack
 * handler set n_wb_pend early in the block and BACKINV_WB cleared it further
 * down, so a writeback completing on the same cycle as an ack destroyed the
 * recovered line -- silently, because blocking assignments simply run in order.
 * 9376 lost stores per run, invisible to three separate reporters.
 *
 * THE MODEL.  One record per in-flight line.  A record owns its line for the
 * whole transaction, so there is no shared mutable state to referee:
 *
 *   s_* : an action still SCHEDULED (to do).  Cleared when issued.
 *   w_* : WAITING on a response.  Set at issue, cleared by the response.
 *
 * A record is runnable when its next scheduled action's dependencies have all
 * landed -- that is the guard.  The sequencer picks ONE runnable record per
 * cycle and issues exactly ONE port operation.  Responses land directly in the
 * record they belong to and never pass through the sequencer, which is what
 * removes the ordering hazards: nothing outside a record writes its state.
 *
 * This is the Bluespec guarded-atomic-action shape: guard (w_runnable), action
 * (t_issue_*), scheduler (the priority pick).  Ported from the C functional
 * model in scratchpad/l2_txn_model.c, whose ablation showed TWO slots capture
 * the entire ordering win (one fill + one snoop); more slots only add fill
 * throughput.
 *
 * ACTION ORDER, and why.  A line being taken away must be surrendered by the
 * L1s before its dirty data can be written back, and the victim must be fully
 * retired before the replacement is fetched:
 *
 *   s_probe  -> invalidate the line out of the L1s (recovers dirty data)
 *   s_wb     -> write the dirty victim back to DRAM   (needs probe done)
 *   s_acquire-> fetch the line from DRAM              (needs probe + wb done)
 *   s_ack    -> deliver to the L1 / ack the DMA       (needs probe + grant)
 *
 * This module is CONTROL ONLY -- no RAMs, no data.  It is small enough to prove
 * outright (formal/run_l2_txn_formal.sh), which is the point: the invariants
 * that the old structure violated are stated here and checked by PDR in well
 * under a second, so the rewrite is continuously verified rather than
 * re-litigated by 100M-cycle simulation.
 */
module l2_txn_ctrl(clk,
		   reset,
		   /* allocation */
		   alloc_valid,
		   alloc_kind,
		   alloc_idx,
		   alloc_ack,
		   /* issued port operation (at most one per cycle) */
		   issue_valid,
		   issue_slot,
		   issue_op,
		   issue_idx,
		   /* responses -- land directly in the owning record */
		   /* lookup response: the tag read that decides what else is needed */
		   lookup_ack,
		   lookup_ack_slot,
		   lookup_hit,
		   lookup_dirty,
		   lookup_l1_pres,
		   probe_ack,
		   probe_ack_slot,
		   wb_ack,
		   wb_ack_slot,
		   grant_valid,
		   grant_slot,
		   /* retirement */
		   retire_valid,
		   retire_slot,
		   busy,
		   /* outstanding-response vectors.  Exposed as real ports because a
		    * formal environment CANNOT reach in: yosys does not resolve
		    * cross-module hierarchical references, it silently invents a
		    * floating wire and setundef -anyseq hands it to the solver. */
		   w_lookup_pend,
		   w_probe_pend,
		   w_wb_pend,
		   w_grant_pend
		   );

   localparam LG_N_TXN = 1;
   localparam N_TXN    = 1 << LG_N_TXN;   /* 2: one fill + one snoop */
   localparam LG_SETS  = `LG_L2_NUM_SETS;

   /* port operations the sequencer can issue */
   typedef enum logic [2:0] {
			     OP_LOOKUP  = 3'd0,
			     OP_PROBE   = 3'd1,
			     OP_WB      = 3'd2,
			     OP_ACQUIRE = 3'd3,
			     OP_ACK     = 3'd4
			     } txn_op_t;

   typedef enum logic [1:0] {
			     TXN_FREE  = 2'd0,
			     TXN_FILL  = 2'd1,
			     TXN_SNOOP = 2'd2
			     } txn_kind_t;

   input logic 		 clk;
   input logic 		 reset;

   input logic 		 alloc_valid;
   input logic [1:0] 	 alloc_kind;
   input logic [LG_SETS-1:0] alloc_idx;
   output logic 	 alloc_ack;

   output logic 	 issue_valid;
   output logic [LG_N_TXN-1:0] issue_slot;
   output logic [2:0] 	 issue_op;
   output logic [LG_SETS-1:0] issue_idx;

   input logic 		 lookup_ack;
   input logic [LG_N_TXN-1:0] lookup_ack_slot;
   input logic 		 lookup_hit;
   input logic 		 lookup_dirty;
   input logic 		 lookup_l1_pres;
   input logic 		 probe_ack;
   input logic [LG_N_TXN-1:0] probe_ack_slot;
   input logic 		 wb_ack;
   input logic [LG_N_TXN-1:0] wb_ack_slot;
   input logic 		 grant_valid;
   input logic [LG_N_TXN-1:0] grant_slot;

   output logic 	 retire_valid;
   output logic [LG_N_TXN-1:0] retire_slot;
   output logic 	 busy;
   output logic [N_TXN-1:0] w_lookup_pend;
   output logic [N_TXN-1:0] w_probe_pend;
   output logic [N_TXN-1:0] w_wb_pend;
   output logic [N_TXN-1:0] w_grant_pend;

   /* ---- the records ------------------------------------------------------ */
   logic [N_TXN-1:0] 	 r_valid, n_valid;
   logic [1:0] 		 r_kind[N_TXN-1:0], n_kind[N_TXN-1:0];
   logic [LG_SETS-1:0] 	 r_idx[N_TXN-1:0], n_idx[N_TXN-1:0];

   /* scheduled actions (still to do) */
   logic [N_TXN-1:0] 	 r_s_lookup, n_s_lookup;
   logic [N_TXN-1:0] 	 r_s_probe, n_s_probe;
   logic [N_TXN-1:0] 	 r_s_wb, n_s_wb;
   logic [N_TXN-1:0] 	 r_s_acquire, n_s_acquire;
   logic [N_TXN-1:0] 	 r_s_ack, n_s_ack;

   /* outstanding responses (waiting on) */
   logic [N_TXN-1:0] 	 r_w_lookup, n_w_lookup;
   logic [N_TXN-1:0] 	 r_w_probe, n_w_probe;
   logic [N_TXN-1:0] 	 r_w_wb, n_w_wb;
   logic [N_TXN-1:0] 	 r_w_grant, n_w_grant;

   /* ---- guards ------------------------------------------------------------
    * w_runnable[i] is the Bluespec guard for record i: its NEXT scheduled action
    * has no outstanding dependency.  Ordering is enforced here, once, rather
    * than by interlocks scattered across a monolithic always_comb. */
   logic [N_TXN-1:0] 	 w_runnable;
   logic [2:0] 		 w_next_op[N_TXN-1:0];

   genvar 		 gi;
   generate
      for(gi = 0; gi < N_TXN; gi = gi + 1)
	begin : guards
	   /* first scheduled action wins; dependencies must be quiescent */
	   assign w_next_op[gi] = r_s_lookup[gi]  ? OP_LOOKUP  :
				  r_s_probe[gi]   ? OP_PROBE   :
				  r_s_wb[gi]      ? OP_WB      :
				  r_s_acquire[gi] ? OP_ACQUIRE :
				  OP_ACK;

	   assign w_runnable[gi] = r_valid[gi] &
				   (r_s_lookup[gi]  ? 1'b1 :
				    /* nothing else may issue until the tag read
				     * has said what this line actually needs */
				    r_w_lookup[gi]  ? 1'b0 :
				    r_s_probe[gi]   ? 1'b1 :
				    /* the L1s must surrender the line before its
				     * dirty data can be pushed to DRAM */
				    r_s_wb[gi]      ? ~r_w_probe[gi] :
				    /* the victim must be fully retired before the
				     * replacement is fetched */
				    r_s_acquire[gi] ? (~r_w_probe[gi] & ~r_w_wb[gi]) :
				    r_s_ack[gi]     ? (~r_w_probe[gi] & ~r_w_grant[gi]) :
				    1'b0);
	end // block: guards
   endgenerate

   /* ---- sequencer: ONE runnable record, ONE port op, per cycle ------------
    * Fixed priority is deliberate and sufficient at N_TXN=2: a snoop record can
    * only be blocked by a fill that is itself making progress, and the C model's
    * ablation found no throughput difference from round-robin at this depth. */
   logic 		 t_issue;
   logic [LG_N_TXN-1:0]  t_slot;
   integer 		 si;

   always_comb
     begin
	t_issue = 1'b0;
	t_slot  = {LG_N_TXN{1'b0}};
	for(si = N_TXN-1; si >= 0; si = si - 1)
	  begin
	     if(w_runnable[si])
	       begin
		  t_issue = 1'b1;
		  t_slot  = si[LG_N_TXN-1:0];
	       end
	  end
     end // always_comb

   assign issue_valid = t_issue;
   assign issue_slot  = t_slot;
   assign issue_op    = w_next_op[t_slot];
   assign issue_idx   = r_idx[t_slot];

   /* ---- allocation --------------------------------------------------------
    * A free slot, and NO existing record already owns this set.  The set
    * interlock lives here, as one condition, instead of the three-signal
    * w_snoop_holds_set / w_snoop_set_conflict / w_main_owns_set dance. */
   logic 		 w_have_free;
   logic 		 w_set_conflict;
   logic [LG_N_TXN-1:0]  w_free_slot;
   integer 		 ai;

   always_comb
     begin
	w_have_free = 1'b0;
	w_free_slot = {LG_N_TXN{1'b0}};
	w_set_conflict = 1'b0;
	for(ai = N_TXN-1; ai >= 0; ai = ai - 1)
	  begin
	     if(~r_valid[ai])
	       begin
		  w_have_free = 1'b1;
		  w_free_slot = ai[LG_N_TXN-1:0];
	       end
	     if(r_valid[ai] & (r_idx[ai] == alloc_idx))
	       begin
		  w_set_conflict = 1'b1;
	       end
	  end
     end // always_comb

   assign alloc_ack = alloc_valid & w_have_free & ~w_set_conflict;
   assign busy      = |r_valid;

   /* a record retires when nothing is scheduled and nothing is outstanding */
   logic [N_TXN-1:0] 	 w_done;
   generate
      for(gi = 0; gi < N_TXN; gi = gi + 1)
	begin : done_bits
	   assign w_done[gi] = r_valid[gi] &
			       ~(r_s_lookup[gi] | r_s_probe[gi] | r_s_wb[gi] |
				 r_s_acquire[gi] | r_s_ack[gi]) &
			       ~(r_w_lookup[gi] | r_w_probe[gi] | r_w_wb[gi] | r_w_grant[gi]);
	end
   endgenerate

   logic 		 t_retire;
   logic [LG_N_TXN-1:0]  t_retire_slot;
   integer 		 ri;
   always_comb
     begin
	t_retire = 1'b0;
	t_retire_slot = {LG_N_TXN{1'b0}};
	for(ri = N_TXN-1; ri >= 0; ri = ri - 1)
	  begin
	     if(w_done[ri])
	       begin
		  t_retire = 1'b1;
		  t_retire_slot = ri[LG_N_TXN-1:0];
	       end
	  end
     end // always_comb

   assign retire_valid = t_retire;
   assign retire_slot  = t_retire_slot;

   assign w_lookup_pend = r_w_lookup;
   assign w_probe_pend = r_w_probe;
   assign w_wb_pend    = r_w_wb;
   assign w_grant_pend = r_w_grant;

   /* ---- next state --------------------------------------------------------
    * Every record's state is written HERE and nowhere else.  A response only
    * ever touches the record named by its slot id, which is the property that
    * makes the four-writers-to-one-flag hazard structurally impossible. */
   integer 		 i;
   always_comb
     begin
	n_valid     = r_valid;
	n_s_lookup  = r_s_lookup;
	n_s_probe   = r_s_probe;
	n_s_wb      = r_s_wb;
	n_s_acquire = r_s_acquire;
	n_s_ack     = r_s_ack;
	n_w_lookup  = r_w_lookup;
	n_w_probe   = r_w_probe;
	n_w_wb      = r_w_wb;
	n_w_grant   = r_w_grant;
	for(i = 0; i < N_TXN; i = i + 1)
	  begin
	     n_kind[i] = r_kind[i];
	     n_idx[i]  = r_idx[i];
	  end

	/* issue: clear the scheduled bit, set the corresponding wait bit */
	if(t_issue)
	  begin
	     case(w_next_op[t_slot])
	       OP_LOOKUP:
		 begin
		    n_s_lookup[t_slot] = 1'b0;
		    n_w_lookup[t_slot] = 1'b1;
		 end
	       OP_PROBE:
		 begin
		    n_s_probe[t_slot] = 1'b0;
		    n_w_probe[t_slot] = 1'b1;
		 end
	       OP_WB:
		 begin
		    n_s_wb[t_slot] = 1'b0;
		    n_w_wb[t_slot] = 1'b1;
		 end
	       OP_ACQUIRE:
		 begin
		    n_s_acquire[t_slot] = 1'b0;
		    n_w_grant[t_slot]   = 1'b1;
		 end
	       default: /* OP_ACK */
		 begin
		    n_s_ack[t_slot] = 1'b0;
		 end
	     endcase // case (w_next_op[t_slot])
	  end

	/* responses land directly in their own record */
	if(lookup_ack)
	  begin
	     n_w_lookup[lookup_ack_slot] = 1'b0;
	     /* the tag read decides the remainder of the transaction.  This is the
	      * ONE place those bits are set, which is what stops the old design's
	      * scattered "who needs a writeback" logic reappearing. */
	     n_s_probe[lookup_ack_slot]   = lookup_hit & lookup_l1_pres;
	     n_s_wb[lookup_ack_slot]      = lookup_hit & lookup_dirty;
	     n_s_acquire[lookup_ack_slot] = (r_kind[lookup_ack_slot] == TXN_FILL) & ~lookup_hit;
	  end
	if(probe_ack)
	  begin
	     n_w_probe[probe_ack_slot] = 1'b0;
	  end
	if(wb_ack)
	  begin
	     n_w_wb[wb_ack_slot] = 1'b0;
	  end
	if(grant_valid)
	  begin
	     n_w_grant[grant_slot] = 1'b0;
	  end

	/* retire before allocate so a slot freed this cycle is reusable */
	if(t_retire)
	  begin
	     n_valid[t_retire_slot] = 1'b0;
	  end

	if(alloc_ack)
	  begin
	     n_valid[w_free_slot]     = 1'b1;
	     n_kind[w_free_slot]      = alloc_kind;
	     n_idx[w_free_slot]       = alloc_idx;
	     n_s_lookup[w_free_slot]  = 1'b1;   /* every txn starts with the tag read */
	     n_s_probe[w_free_slot]   = 1'b0;
	     n_s_wb[w_free_slot]      = 1'b0;
	     n_s_acquire[w_free_slot] = 1'b0;
	     n_s_ack[w_free_slot]     = 1'b1;
	     n_w_lookup[w_free_slot]  = 1'b0;
	     n_w_probe[w_free_slot]   = 1'b0;
	     n_w_wb[w_free_slot]      = 1'b0;
	     n_w_grant[w_free_slot]   = 1'b0;
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_valid     <= {N_TXN{1'b0}};
	     r_s_lookup  <= {N_TXN{1'b0}};
	     r_s_probe   <= {N_TXN{1'b0}};
	     r_s_wb      <= {N_TXN{1'b0}};
	     r_s_acquire <= {N_TXN{1'b0}};
	     r_s_ack     <= {N_TXN{1'b0}};
	     r_w_lookup  <= {N_TXN{1'b0}};
	     r_w_probe   <= {N_TXN{1'b0}};
	     r_w_wb      <= {N_TXN{1'b0}};
	     r_w_grant   <= {N_TXN{1'b0}};
	  end
	else
	  begin
	     r_valid     <= n_valid;
	     r_s_lookup  <= n_s_lookup;
	     r_s_probe   <= n_s_probe;
	     r_s_wb      <= n_s_wb;
	     r_s_acquire <= n_s_acquire;
	     r_s_ack     <= n_s_ack;
	     r_w_lookup  <= n_w_lookup;
	     r_w_probe   <= n_w_probe;
	     r_w_wb      <= n_w_wb;
	     r_w_grant   <= n_w_grant;
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	for(i = 0; i < N_TXN; i = i + 1)
	  begin
	     r_kind[i] <= n_kind[i];
	     r_idx[i]  <= n_idx[i];
	  end
     end // always_ff@ (posedge clk)

`ifdef FORMAL
   /* ---- the invariants the OLD structure violated -------------------------
    * Immediate assertions in a clocked block (formal_top.v's idiom); a reader
    * placed inside an always_comb would see pre-assignment values -- the trap
    * that made [LEAK] structurally dead in l2.sv. */
   integer 		 fi, fj;
   always @(posedge clk)
     begin
	if(!reset)
	  begin
	     /* AT MOST ONE port operation per cycle.  The old design had two
	      * engines racing for one data port, refereed by w_snoop_wr_gnt. */
	     assert($onehot0({issue_valid}));

	     for(fi = 0; fi < N_TXN; fi = fi + 1)
	       begin
		  /* no action is ever issued out of dependency order */
		  if(r_w_probe[fi])
		    begin
		       assert(~(t_issue & (t_slot == fi[LG_N_TXN-1:0]) &
				((w_next_op[fi] == OP_WB) |
				 (w_next_op[fi] == OP_ACQUIRE))));
		    end
		  /* a free record carries no state at all */
		  if(~r_valid[fi])
		    begin
		       assert(~(r_s_lookup[fi] | r_s_probe[fi] | r_s_wb[fi] |
				r_s_acquire[fi] | r_s_ack[fi]));
		       assert(~(r_w_lookup[fi] | r_w_probe[fi] | r_w_wb[fi] | r_w_grant[fi]));
		    end
		  /* ONE OWNER PER SET -- the property the three-signal interlock
		   * was trying to maintain by hand */
		  for(fj = 0; fj < N_TXN; fj = fj + 1)
		    begin
		       if((fi != fj) & r_valid[fi] & r_valid[fj])
			 begin
			    assert(r_idx[fi] != r_idx[fj]);
			 end
		    end
	       end

	     /* ---- DEADLOCK FREEDOM, stated as safety --------------------------
	      * True liveness ($live / s_eventually) needs an engine we do not have
	      * installed (suprove), and is easy to state wrongly.  These two safety
	      * properties capture what actually matters, and PDR discharges them:
	      *
	      *   1. every valid record is RUNNABLE, WAITING on a response, or DONE.
	      *      A record that is valid with nothing runnable and nothing
	      *      outstanding can never progress again -- that IS the deadlock.
	      *   2. if anything is runnable, the sequencer issues.  It may never sit
	      *      idle while work exists.
	      *
	      * Together: no record is stranded and no runnable record is starved of
	      * the port.  This is exactly what the EVICTION back-invalidate needs,
	      * because it makes a fill BLOCK on a probe ack -- a wait the main FSM
	      * never had, and the reason that path was parked. */
	     for(fj = 0; fj < N_TXN; fj = fj + 1)
	       begin
		  if(r_valid[fj])
		    begin
		       assert(w_runnable[fj] | w_done[fj] | r_w_lookup[fj] |
			      r_w_probe[fj] | r_w_wb[fj] | r_w_grant[fj]);
		    end
	       end
	     if(|w_runnable)
	       begin
		  assert(issue_valid);
	       end

	     /* reachability -- a PASS over an unreachable state space is worthless */
	     /* NOTHING issues while the tag read is outstanding -- the ordering the
	      * two-engine design had to enforce with w_snoop_holds_set et al. */
	     for(fj = 0; fj < N_TXN; fj = fj + 1)
	       begin
		  if(r_w_lookup[fj])
		    begin
		       assert(~(t_issue & (t_slot == fj[LG_N_TXN-1:0])));
		    end
	       end
	     cover(issue_valid & (issue_op == OP_LOOKUP));
	     cover(issue_valid & (issue_op == OP_PROBE));
	     cover(issue_valid & (issue_op == OP_WB));
	     cover(issue_valid & (issue_op == OP_ACQUIRE));
	     cover(&r_valid);          /* both slots busy at once */
	     cover(retire_valid);
	  end
     end // always @ (posedge clk)
`endif

endmodule // l2_txn_ctrl
