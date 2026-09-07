/* fpu_stub.sv -- FORMAL ONLY.  Same ports as fpu.sv, all outputs tied off.
 * Lets the formal model drop the entire FP datapath (fpu + fpu_mul/add/f2f/i2f/f2i
 * + count_leading_zeros) without touching the real RTL: yosys resolves `fpu` to
 * this instead.  Sound for integer properties because the FP unit only feeds the
 * FP regfile / FCR path -- it does not source the integer PRF or the srcA mux. */
module fpu(clk, reset, pc, opcode, start, src_a, src_b, src_c, src_fcr, rm,
	   rob_ptr_in, dst_ptr_in, fcr_ptr_in, fcr_sel, cmp_cond,
	   val, cmp_val, y, fflags, denorm, rob_ptr_out, dst_ptr_out, fcr_ptr_out);
   parameter LG_ROB_WIDTH = 4;
   parameter FPU_LAT = 4;
   parameter LG_PRF_WIDTH = 4;
   parameter LG_FCR_WIDTH = 4;
   input logic clk, reset;
   input logic [63:0] pc;
   input logic [6:0]  opcode;
   input logic start;
   input logic [63:0] src_a, src_b, src_c;
   input logic [7:0]  src_fcr;
   input logic [1:0]  rm;
   input logic [LG_ROB_WIDTH-1:0] rob_ptr_in;
   input logic [LG_PRF_WIDTH-1:0] dst_ptr_in;
   input logic [LG_FCR_WIDTH-1:0] fcr_ptr_in;
   input logic [2:0] fcr_sel;
   input logic [3:0] cmp_cond;
   output logic val, cmp_val, denorm;
   output logic [63:0] y;
   output logic [4:0]  fflags;
   output logic [LG_ROB_WIDTH-1:0] rob_ptr_out;
   output logic [LG_PRF_WIDTH-1:0] dst_ptr_out;
   output logic [LG_FCR_WIDTH-1:0] fcr_ptr_out;
   assign val = 1'b0; assign cmp_val = 1'b0; assign denorm = 1'b0;
   assign y = 64'd0; assign fflags = 5'd0;
   assign rob_ptr_out = '0; assign dst_ptr_out = '0; assign fcr_ptr_out = '0;
endmodule
