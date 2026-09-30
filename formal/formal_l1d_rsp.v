/* formal_l1d_rsp.v -- THE l1d response-integrity property, at -top l1d:
 *   bad0: a core response fires for a rob_ptr with no outstanding accepted
 *         request (covers BOTH spurious and double responses).
 * Env: cacheable unmapped loads only (mapped=0 => no TLB), requests held until
 * ack, never reusing an outstanding rob_ptr (mirrors the core's one-op-per-slot
 * invariant); mem side = single-outstanding scoreboarded free responses (the
 * exhaustive version of randomized DRAM latency).
 *   bad_p0: a response carries dst_valid with dst_ptr == 0 (physreg-0 closure
 *         through the L1D -- rf4r2w gates the WRITE of p0, nothing gates the
 *         forward).
 *   bad_dp: a response's dst_ptr differs from the one its request carried (the
 *         L3b round trip -- a mis-steered result is indistinguishable at the
 *         consumer from "this reader disagrees with its producer").
 * Controls, ALL of which must be SAT or the properties above are vacuous:
 *   c_ack (a request accepted), c_rsp (a response delivered), c_missrsp (a
 *   response after a memory round trip = the miss path is live), c_dstv (a
 *   response actually carried dst_valid), c_dpchk (a round-trip compare actually
 *   happened), c_two_dp (two slots outstanding with DIFFERENT dst_ptrs, so a swap
 *   is expressible and bad_dp is not true merely for lack of an alternative).
 * c_fpd is legitimately constant -- see its declaration. */
module formal_l1d_rsp(clk,
	go, rp_free, ad_free, mem_ack_free, mem_go, op_free, dp_free,
	pre_tag_free, pre_data_free,
	bad0, bad_p0, c_ack, c_rsp, c_missrsp, c_dstv, c_ptr, c_fpd, c_rob, c_dat, c_any,
	bad_dp, c_dpchk, c_two_dp);
   input clk;
   input go;
   input [1:0] rp_free;
   input [9:0] ad_free;
   input mem_ack_free, mem_go;
   input op_free;          /* pick MEM_LW vs MEM_MOV */
   input [5:0] dp_free;    /* low bits of dst_ptr; bit6 forced 1 so it is NEVER 0 */
   /* FORMAL_DPRELOAD: contents the reset walk stamps into every d-cache line, so a
    * load HITS with no DRAM round trip.  Free, because the point is to let the
    * solver choose a line that the request address matches. */
   input [35:0]  pre_tag_free;
   input [127:0] pre_data_free;
   output bad0, bad_p0, c_ack, c_rsp, c_missrsp, c_dstv, c_ptr, c_fpd, c_rob, c_dat, c_any;
   /* NEW OUTPUTS GO AT THE END: abc cone indices follow this port order, so
    * inserting in the middle silently renumbers every index the runner names.
    * That is exactly how bad_p0 (added at index 1) made the old control loop
    * BMC a violation property as if it were a control. */
   output bad_dp, c_dpchk, c_two_dp;

   reg [3:0] r_cnt = 4'd0;
   always @(posedge clk) if(r_cnt != 4'hf) r_cnt <= r_cnt + 4'd1;
   wire reset = (r_cnt == 4'd0);

   /* ---- request construction (LW, unmapped, cacheable, word-aligned) ---- */
   reg 	      r_pend = 1'b0;
   reg [1:0]  r_rp = 2'd0;
   reg [9:0]  r_ad = 10'd0;
   reg [4:0]  r_op = 5'd4;
   reg [6:0]  r_dp = 7'h41;
   wire [1:0] w_rp = r_pend ? r_rp : rp_free;
   wire [9:0] w_ad = r_pend ? r_ad : ad_free;
   wire [63:0] w_addr = 64'hFFFFFFFF80000000 | {52'd0, w_ad, 2'b00};
   /* ENVIRONMENT (2026-09-07): the original harness pinned op=MEM_LW and
    * dst_ptr=7'h21.  Two problems.  (a) The response only carries dst_valid on a
    * CACHE-HIT reply (t_rsp_dst_valid2 = r_req2.dst_valid & t_hit_cache2), and
    * this harness ties every ROB-side input to 0 so the miss queue never
    * graduates -- no fill, no hit, no dst_valid, and the physreg-0 property was
    * VACUOUS (c_dstv was CONSTANT-0 in the AIG).  MEM_MOV echoes dst_valid
    * straight from request to response with no memory access (l1d.sv ~2019), so
    * admitting it makes the property live.  (b) A pinned dst_ptr cannot detect
    * CORRUPTION -- the real question is whether a NON-ZERO pointer can come back
    * as 0, so drive it freely with bit6 forced high (64 distinct non-zero values,
    * and 0 excluded by construction rather than by an assume). */
   /* HELD with the rest of the request: r_pend keeps a request stable until ack,
    * so op/dst_ptr must be latched too -- a request whose fields mutate mid-flight
    * is not something the core can produce, and would invite a bogus CEX. */
   wire [4:0] w_op = r_pend ? r_op : (op_free ? 5'd25 : 5'd4);   /* MEM_MOV : MEM_LW */
   wire [6:0] w_dp = r_pend ? r_dp : {1'b1, dp_free};            /* always non-zero */
   wire [246:0] w_req = { w_addr,              /* [246:183] addr        */
			  1'b0,                /* [182] is_store        */
			  1'b0,                /* [181] is_atomic       */
			  w_op,                /* [180:176] op: LW or MOV */
			  1'b0,                /* [175] bad_addr        */
			  1'b0,                /* [174] mapped          */
			  1'b1,                /* [173] cached          */
			  w_rp,                /* [172:171] rob_ptr     */
			  w_dp,                /* [170:164] dst_ptr (free, non-zero) */
			  1'b1,                /* [163] dst_valid       */
			  4'b0000,             /* fp_dst/merge/hi + pad0*/
			  31'd0,               /* rest of fp_pres       */
			  64'd0,               /* data                  */
			  64'd0 };             /* pc -- ADDED 2026-09-07 */
   /* STALE-LAYOUT BUG, found by the c_dstv vacuity cover: mem_req_t gained a 64-bit
    * `pc' field (the store-tracer PC watchpoint) after this harness was written, so
    * l1d's core_mem_req port is 247 bits while this built 183.  Every field was
    * misaligned by 64 bits: dst_valid landed in the wrong bit, so NO response ever
    * carried dst_valid -- which silently made the physreg-0 property vacuous AND
    * means the pre-existing bad0 proof was running against a malformed request
    * stream (its rob_ptr was misaligned too).  If mem_req_t changes again, this
    * literal must change with it; the width is checked by the assertion below. */
   reg r_c_any = 1'b0;   /* diag: ANY bit of the response bus ever set */
   reg r_c_rob = 1'b0;   /* diag: response echoed a non-zero rob_ptr */
   reg r_c_dat = 1'b0;   /* diag: response carried non-zero data */
   reg r_c_ptr = 1'b0;   /* diag: response echoed a non-zero dst_ptr (offsets sane?) */
   /* diag: response set fp_dst (bit 45).  LEGITIMATELY CONSTANT-0 here -- w_req
    * pins the fp_dst/fp_merge/fp_hi field to 4'b0000, so no response can carry
    * fp_dst.  It is a control for an FP environment this harness does not build.
    * Do NOT "fix" it; the vacuity that matters is c_dstv, which IS live. */
   reg r_c_fpd = 1'b0;
   reg r_bad_p0 = 1'b0;   /* sticky: a response carried dst_valid with dst_ptr==0 */
   reg r_c_dstv = 1'b0;   /* sticky: some response carried dst_valid (non-vacuity) */
   reg [3:0]  r_out = 4'd0;      /* core-side outstanding, by rob_ptr */
   wire w_req_valid = (go | r_pend) & ~r_out[w_rp] & ~reset;

   wire w_ack;
   wire w_rsp_valid;
   wire [119:0] w_rsp;
   wire [1:0] w_rsp_ptr = w_rsp[55:54];
   /* mem_rsp_t is packed MSB-first in declaration order:
    *   data[119:56] rob_ptr[55:54] dst_ptr[53:47] dst_valid[46] fp_dst[45] ... */
   wire [6:0] w_rsp_dst_ptr   = w_rsp[53:47];
   wire       w_rsp_dst_valid = w_rsp[46];
   /* PHYSREG-0 CLOSURE THROUGH THE L1D.  Decode is already proven never to emit a
    * writer targeting $zero (run_decode_formal.sh: dst_valid |-> dst != 0), and
    * every request this harness issues carries dst_ptr = 7'h21.  The open question
    * is whether the L1D itself can FABRICATE or CORRUPT a response into
    * dst_valid & dst_ptr == 0, which would bypass onto physreg 0 at the consumer
    * (rf4r2w gates the WRITE of p0, nothing gates the forward). */
   wire w_rsp_p0 = w_rsp_valid & w_rsp_dst_valid & (w_rsp_dst_ptr == 7'd0);

   /* ---- dst_ptr ROUND TRIP (the L3b property) -----------------------------
    * bad_p0 only says the returned pointer is not ZERO.  The stronger question is
    * whether it is the SAME pointer the request carried: a corrupted dst_ptr
    * delivers a load result to the wrong physreg, which is indistinguishable at
    * the consumer from "this reader disagrees with its producer".  dst_ptr is
    * driven freely here (bit6 forced high => 64 distinct non-zero values), so a
    * swap between two in-flight slots is expressible and would be caught.
    *
    * Scoreboarded BY rob_ptr because responses may return out of order.  The
    * write lives in the request-side always block with r_out -- NOT in the
    * properties block -- so every reg keeps exactly one driver. */
   reg [6:0] r_dp_sb [3:0];
   /* r_out[w_rsp_ptr] qualifies the compare to a response that belongs to a LIVE
    * request, so this property stays same-transaction and does not re-detect the
    * spurious-response case that bad0 already owns.  Without that gate an
    * unmatched response would trip BOTH and conflate two distinct failures. */
   wire w_dp_live     = w_rsp_valid & w_rsp_dst_valid & r_out[w_rsp_ptr];
   wire w_dp_mismatch = w_dp_live & (w_rsp_dst_ptr != r_dp_sb[w_rsp_ptr]);
   /* STRENGTH CONTROL for bad_dp.  A round-trip proof is only as strong as the
    * environment's ability to EXPRESS a swap: if the harness could never hold two
    * different dst_ptrs at once, bad_dp would be true for an uninteresting reason.
    * c_two_dp must be SAT -- two slots outstanding with DIFFERENT recorded
    * pointers, which is the state a mis-steered response would corrupt. */
   wire w_two_dp = (r_out[0] & r_out[1] & (r_dp_sb[0] != r_dp_sb[1]))
		 | (r_out[0] & r_out[2] & (r_dp_sb[0] != r_dp_sb[2]))
		 | (r_out[0] & r_out[3] & (r_dp_sb[0] != r_dp_sb[3]))
		 | (r_out[1] & r_out[2] & (r_dp_sb[1] != r_dp_sb[2]))
		 | (r_out[1] & r_out[3] & (r_dp_sb[1] != r_dp_sb[3]))
		 | (r_out[2] & r_out[3] & (r_dp_sb[2] != r_dp_sb[3]));

   /* ---- mem-side scoreboard (single outstanding) ---- */
   wire w_mem_req_valid;
   reg 	r_mem_out = 1'b0;
   wire w_mem_ack = mem_ack_free & w_mem_req_valid & ~r_mem_out;
   wire w_mem_rsp_valid = mem_go & r_mem_out;
   reg 	r_saw_mem = 1'b0;

   always @(posedge clk)
     begin
	if(reset)
	  begin
	     r_pend <= 1'b0; r_out <= 4'd0; r_mem_out <= 1'b0; r_saw_mem <= 1'b0;
	     /* MULTI-DRIVER BUG, fixed 2026-09-12: r_bad_p0/r_c_dstv/r_c_ptr/r_c_fpd/
	      * r_c_rob/r_c_dat/r_c_any used to be reset HERE while being updated in the
	      * properties block below -- two always blocks driving one reg.  yosys
	      * reported "Driver-driver conflict ... Resolved using constant" for each
	      * and tied all seven to 0, so bad_p0 was CONSTANT-0 and the physreg-0
	      * property was VACUOUS (cone: lat=0 and=0) while bad0/c_ack/c_rsp/
	      * c_missrsp -- single-driven -- stayed live at 535 latches.  Every one of
	      * these regs is now reset in its own block, below. */
	  end
	else
	  begin
	     if(w_req_valid & ~w_ack) begin r_pend <= 1'b1; r_rp <= w_rp; r_ad <= w_ad; r_op <= w_op; r_dp <= w_dp; end
	     else if(w_ack) r_pend <= 1'b0;
	     if(w_req_valid & w_ack) begin r_out[w_rp] <= 1'b1; r_dp_sb[w_rp] <= w_dp; end
	     if(w_rsp_valid) r_out[w_rsp_ptr] <= 1'b0;
	     if(w_mem_req_valid & w_mem_ack) begin r_mem_out <= 1'b1; r_saw_mem <= 1'b1; end
	     if(w_mem_rsp_valid) r_mem_out <= 1'b0;
	  end
     end

   /* ---- properties (sticky) ---- */
   reg r_bad0 = 1'b0, r_c_ack = 1'b0, r_c_rsp = 1'b0, r_c_missrsp = 1'b0;
   reg r_bad_dp = 1'b0, r_c_dpchk = 1'b0, r_c_two_dp = 1'b0;
   always @(posedge clk)
     begin
	if(reset)
	  begin
	     r_bad0 <= 1'b0; r_bad_p0 <= 1'b0;
	     r_c_ack <= 1'b0; r_c_rsp <= 1'b0; r_c_missrsp <= 1'b0;
	     r_c_dstv <= 1'b0; r_c_ptr <= 1'b0; r_c_fpd <= 1'b0;
	     r_c_rob <= 1'b0; r_c_dat <= 1'b0; r_c_any <= 1'b0;
	     r_bad_dp <= 1'b0; r_c_dpchk <= 1'b0; r_c_two_dp <= 1'b0;
	  end
	else
	  begin
	     r_bad0 <= r_bad0 | (w_rsp_valid & ~r_out[w_rsp_ptr]);
	     r_bad_p0 <= r_bad_p0 | w_rsp_p0;
	     r_c_dstv <= r_c_dstv | (w_rsp_valid & w_rsp_dst_valid);
	     r_c_ptr  <= r_c_ptr  | (w_rsp_valid & (w_rsp_dst_ptr != 7'd0));
	     r_c_fpd  <= r_c_fpd  | (w_rsp_valid & w_rsp[45]);
	     r_c_rob  <= r_c_rob  | (w_rsp_valid & (w_rsp_ptr != 2'd0));
	     r_c_dat  <= r_c_dat  | (w_rsp_valid & (w_rsp[119:56] != 64'd0));
	     r_c_any  <= r_c_any  | (w_rsp != 120'd0);
	     r_c_ack <= r_c_ack | (w_req_valid & w_ack);
	     r_c_rsp <= r_c_rsp | w_rsp_valid;
	     r_c_missrsp <= r_c_missrsp | (w_rsp_valid & r_saw_mem);
	     r_bad_dp  <= r_bad_dp  | w_dp_mismatch;
	     r_c_dpchk <= r_c_dpchk | w_dp_live;
	     r_c_two_dp <= r_c_two_dp | w_two_dp;
	  end
     end
   assign bad0 = r_bad0;
   assign bad_p0 = r_bad_p0;
   assign c_dstv = r_c_dstv;
   assign c_ptr = r_c_ptr;
   assign c_fpd = r_c_fpd;
   assign c_rob = r_c_rob;
   assign c_dat = r_c_dat;
   assign c_any = r_c_any;
   assign c_ack = r_c_ack;
   assign c_rsp = r_c_rsp;
   assign c_missrsp = r_c_missrsp;
   assign bad_dp = r_bad_dp;
   assign c_dpchk = r_c_dpchk;
   assign c_two_dp = r_c_two_dp;

   l1d dut(
     .clk(clk), .reset(reset),
     .fml_pre_tag(pre_tag_free), .fml_pre_data(pre_data_free),
     .asid(8'd0), .tlb_entry_in(115'd0), .tlb_entry_in_valid(1'b0),
     .state(), .in_kernel_mode(1'b1), .in_supervisor_mode(1'b0), .in_user_mode(1'b0),
     .head_of_rob_ptr(2'd0), .head_of_rob_ptr_valid(1'b0),
     .head_of_rob_has_delay_slot(1'b0), .next_head_of_rob_ptr(2'd0),
     .head_of_rob_ds_committable(1'b0),
     .retired_rob_ptr_valid(1'b0), .retired_rob_ptr_two_valid(1'b0),
     .retired_rob_ptr(2'd0), .retired_rob_ptr_two(2'd0),
     .restart_valid(1'b0), .clr_link_reg(1'b0), .memq_empty(),
     .drain_ds_complete(1'b0), .dead_rob_mask(4'd0),
     .flush_req(1'b0), .flush_complete(), .flush_cl_req(1'b0),
     .flush_cl_addr(64'd0), .flush_cl_inval(1'b0),
     .dma_inval_req(1'b0), .dma_inval_addr(36'd0), .dma_inval_ack(),
     .core_mem_req_valid(w_req_valid), .core_mem_req(w_req),
     .core_store_data_valid(1'b0), .core_store_data(66'd0), .core_store_data_ack(),
     .core_mem_req_ack(w_ack), .core_mem_rsp(w_rsp), .core_mem_rsp_valid(w_rsp_valid),
     .mem_req_ack(w_mem_ack), .mem_req_valid(w_mem_req_valid),
     .mem_req_addr(), .mem_req_store_data(), .mem_req_opcode(), .mem_req_cacheable(),
     .mem_req_mask(),
     .mem_rsp_valid(w_mem_rsp_valid), .mem_rsp_load_data({126'd0, ad_free[1:0]}),
     .cache_accesses(), .cache_hits()
   );
endmodule
