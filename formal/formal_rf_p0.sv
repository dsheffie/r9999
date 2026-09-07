/* smtbmc harness for P2d: physreg 0 reads as 0 in rf4r2w.
 * Assumes (discharged elsewhere): port0 writes carry a NONZERO ALU-bank pointer
 * (decode proofs INT_WRITER=>dst_valid + INT_WRITER=>~is_mem, plus the free-list
 * never containing p0); port1 writes carry a MEM-bank pointer (banked allocator).
 * Compile the control with -DRFP0_NO_ASSUME: BMC must then find the p0-cell
 * corruption (wen0 @ ptr HALF aliases r_ram_alu[0]). */
module formal_rf_p0_smt(clk, wen0, wen1, wrptr0, wrptr1, wr0, wr1);
   parameter LG = 3;
   parameter W  = 8;
   input clk;
   input wen0, wen1;
   input [LG-1:0] wrptr0, wrptr1;
   input [W-1:0]  wr0, wr1;

   reg [3:0] r_cnt = 4'd0;
   always @(posedge clk) if(r_cnt != 4'hf) r_cnt <= r_cnt + 4'd1;
   wire reset = (r_cnt == 4'd0);

`ifndef RFP0_NO_ASSUME
   always @* begin
      assume(wrptr0 != {LG{1'b0}});
      assume(wrptr0[LG-1] == 1'b0);   /* port0 = ALU bank */
      assume(wrptr1[LG-1] == 1'b1);   /* port1 = MEM bank */
   end
`endif

   wire [W-1:0] rd0, rd1, rd2, rd3;
   rf4r2w #(.WIDTH(W), .LG_DEPTH(LG)) dut
     (.clk(clk), .reset(reset),
      .rdptr0({LG{1'b0}}), .rdptr1({LG{1'b0}}), .rdptr2({LG{1'b0}}), .rdptr3({LG{1'b0}}),
      .wrptr0(wrptr0), .wrptr1(wrptr1), .wen0(wen0), .wen1(wen1),
      .wr0(wr0), .wr1(wr1), .rd0(rd0), .rd1(rd1), .rd2(rd2), .rd3(rd3));

   /* the user-visible property: a read of physreg 0 returns 0 */
   reg r_valid_d = 1'b0;
   always @(posedge clk) r_valid_d <= reset ? 1'b0 : 1'b1;
   always @(posedge clk) if(r_valid_d) assert(rd0 == {W{1'b0}});
endmodule
