/* formal_rf.sv -- BMC the register-file read/write visibility contract that the
 * operand-delivery argument depends on.
 *
 * CLAIM UNDER TEST: a value written to physreg P at cycle N is returned by a read
 * of P *issued* at cycle N+1.  If this fails, a consumer can be correctly woken and
 * still read stale data -- which is the surviving explanation for the captured
 * jr->NULL fault (producer completed first, ROB held the right value, consumer got 0).
 *
 * Scaled-down params (8 entries x 8 bits) keep the SAT instance small; the logic
 * under test is the addressing/banking/timing, which is width- and depth-agnostic.
 * BANK RULE: writes pick the bank by PORT (0=alu,1=mem) and ignore the pointer MSB,
 * reads pick it by the MSB -- so the harness only drives bank-legal writes, which is
 * the invariant core.sv's free-list steering is supposed to guarantee.
 */
module formal_rf(clk, wen0, wen1, wrptr0, wrptr1, wr0, wr1, rdptr0, bad, active);
   parameter LG = 3;
   parameter W  = 8;
   input logic clk;
   /* reset is NOT a free input: left symbolic the solver toggles it mid-trace, and
    * since sv2v strips rf4r2w's `ifdef VERILATOR reset branch the DUT's RAMs ignore
    * it while the shadow would clear -- a guaranteed spurious counterexample.  Drive
    * it from a counter instead: high for cycle 0 only. */
   logic [3:0] r_cnt = '0;
   always_ff @(posedge clk) if(r_cnt != 4'hf) r_cnt <= r_cnt + 4'd1;
   wire reset = (r_cnt == 4'd0);
   input logic wen0, wen1;
   input logic [LG-1:0] wrptr0, wrptr1;
   input logic [W-1:0]  wr0, wr1;
   input logic [LG-1:0] rdptr0;
   output logic bad, active;

   logic [W-1:0] rd0, rd1, rd2, rd3;
   /* bank-legal writes only: port0 -> MSB=0, port1 -> MSB=1 */
   wire [LG-1:0] w_p0 = {1'b0, wrptr0[LG-2:0]};
   wire [LG-1:0] w_p1 = {1'b1, wrptr1[LG-2:0]};

   rf4r2w #(.WIDTH(W), .LG_DEPTH(LG)) dut
     (.clk(clk), .reset(reset),
      .rdptr0(rdptr0), .rdptr1(rdptr0), .rdptr2(rdptr0), .rdptr3(rdptr0),
      .wrptr0(w_p0), .wrptr1(w_p1), .wen0(wen0), .wen1(wen1),
      .wr0(wr0), .wr1(wr1), .rd0(rd0), .rd1(rd1), .rd2(rd2), .rd3(rd3));

   /* shadow: golden last-written value, same write rules, no bypass */
   logic [W-1:0] shadow [(1<<LG)-1:0];
   /* STATE QUALIFIER: rf4r2w's RAMs have no synthesis-path reset, so before a
    * pointer has been written its contents are undefined and comparing against a
    * zero-initialised shadow proves nothing.  Only assert on pointers written at
    * least once since reset. */
   logic [(1<<LG)-1:0] written;
   logic [LG-1:0] r_rdptr_d;
   logic          r_valid_d, r_written_d;
   logic [W-1:0]  r_shadow_d;
   integer i;
   always_ff @(posedge clk) begin
      if(reset) begin
         for(i = 0; i < (1<<LG); i = i + 1) shadow[i] <= '0;
         written   <= '0;
         r_valid_d <= 1'b0;
      end
      else begin
         if(wen0 & (w_p0 != '0)) begin shadow[w_p0] <= wr0; written[w_p0] <= 1'b1; end
         if(wen1)                begin shadow[w_p1] <= wr1; written[w_p1] <= 1'b1; end
         /* the read issued THIS cycle returns at the next edge; capture what the
          * golden model says it should be, sampled BEFORE this cycle's writes */
         r_rdptr_d  <= rdptr0;
         r_shadow_d  <= shadow[rdptr0];
         r_written_d <= written[rdptr0];
         r_valid_d   <= 1'b1;
      end
   end
   assign active = r_valid_d & r_written_d & (r_rdptr_d != '0);
   assign bad    = active & (rd0 != r_shadow_d);
endmodule
