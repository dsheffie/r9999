/* muldiv_stub.sv -- FORMAL ONLY.  Port-compatible stubs for mul and nu_divider so
 * the model can drop both datapaths.  Sound for operand-delivery / rename properties:
 * these units write the HI/LO PRF, not the integer PRF the srcA path reads, and their
 * results reach nothing the jr/load property observes.  `ready` is held high so the
 * scheduler is never blocked waiting on a divider that no longer exists. */
module mul(clk, reset, is_signed, go, src_A, src_B, is_32b, rob_ptr_in, hilo_prf_ptr_in,
	   y, complete, rob_ptr_out, hilo_prf_ptr_val_out, hilo_prf_ptr_out);
   parameter W = 32;
   input logic clk, reset, is_signed, go, is_32b;
   input logic [W-1:0] src_A, src_B;
   input logic [`LG_ROB_ENTRIES-1:0] rob_ptr_in;
   input logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_in;
   output logic [(2*W)-1:0] y;
   output logic complete, hilo_prf_ptr_val_out;
   output logic [`LG_ROB_ENTRIES-1:0] rob_ptr_out;
   output logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_out;
   assign y = '0; assign complete = 1'b0; assign hilo_prf_ptr_val_out = 1'b0;
   assign rob_ptr_out = '0; assign hilo_prf_ptr_out = '0;
endmodule

module nu_divider(clk, reset, wb_slot_used, srcA, srcB, is_32b, rob_ptr_in,
		  hilo_prf_ptr_in, is_signed_div, start_div,
		  y, rob_ptr_out, hilo_prf_ptr_out, ready, complete);
   parameter LG_W = 5;
   localparam W  = 1 << LG_W;
   localparam W2 = 2*W;
   input logic clk, reset, wb_slot_used, is_32b, is_signed_div, start_div;
   input logic [W-1:0] srcA, srcB;
   input logic [`LG_ROB_ENTRIES-1:0] rob_ptr_in;
   input logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_in;
   output logic [W2-1:0] y;
   output logic [`LG_ROB_ENTRIES-1:0] rob_ptr_out;
   output logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_out;
   output logic ready, complete;
   assign y = '0; assign rob_ptr_out = '0; assign hilo_prf_ptr_out = '0;
   assign ready = 1'b1;   /* never block the scheduler */
   assign complete = 1'b0;
endmodule
