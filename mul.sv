`include "machine.vh"

module ff(q,d,clk);
   parameter N = 1;
   input logic [N-1:0] d;
   input logic 	       clk;
   output logic [N-1:0] q;
   always_ff@(posedge clk)
     begin
	q <= d;
     end // always_ff@ (posedge clk)
endmodule // dff

module mul(clk,
	   reset,
	   is_signed,
	   go,
	   src_A,
	   src_B,
	   is_32b,
	   rob_ptr_in,
	   hilo_prf_ptr_in,
	   y,
	   complete,
	   rob_ptr_out,
	   hilo_prf_ptr_val_out,
	   hilo_prf_ptr_out);
   
   parameter W = 32;   
   input logic clk;
   input logic reset;
   input logic is_signed;
   input logic go;
   
   input logic [W-1:0] src_A;
   input logic [W-1:0] src_B;
   input logic	       is_32b;
   input logic [`LG_ROB_ENTRIES-1:0] rob_ptr_in;
   input logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_in;
   
   
   output logic [(2*W)-1:0]		  y;
   output logic 			  complete;
   output logic [`LG_ROB_ENTRIES-1:0] 	  rob_ptr_out;
   output logic 			  hilo_prf_ptr_val_out;
   output logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_out;
   
   logic [`MUL_LAT:0] 			   r_complete;
   logic [`MUL_LAT:0]			   r_is_32b;
   logic [`MUL_LAT:0] 			   r_hilo_val;
   logic [`LG_HILO_PRF_ENTRIES-1:0] 	   r_hilo_ptr[`MUL_LAT:0];
   logic [`LG_ROB_ENTRIES-1:0] 		   r_rob_ptr[`MUL_LAT:0];
  

   assign complete = r_complete[`MUL_LAT];
   assign rob_ptr_out = r_rob_ptr[`MUL_LAT];
   
   assign hilo_prf_ptr_val_out = r_hilo_val[`MUL_LAT];
   assign hilo_prf_ptr_out = r_hilo_ptr[`MUL_LAT];

   logic [(2*W)-1:0] 			   t_mul;
   logic [(2*W)-1:0]			   r_mul[`MUL_LAT:0];

   wire [63:0]				   w_mul32b_lo = {{32{r_mul[`MUL_LAT][31]}}, r_mul[`MUL_LAT][31:0]};
   wire [63:0]				   w_mul32b_hi = {{32{r_mul[`MUL_LAT][63]}}, r_mul[`MUL_LAT][63:32]};

   wire [`M_WIDTH-1:0]			   w_src_A, w_src_B;
   generate
      if(`M_WIDTH == 64)
	begin
	   assign   w_src_A = is_32b ? {32'd0, src_A[31:0]} : src_A;
	   assign   w_src_B = is_32b ? {32'd0, src_B[31:0]} : src_B;
	end
      else
	begin
	   assign w_src_A = src_A;
	   assign w_src_B = src_B;
	end
   endgenerate

   /* Sign/zero-extend inputs to 2W bits so the product is a full 2W-bit result.
    * Without this, SV truncates the W*W multiply to W bits and the HI half is wrong. */
   wire signed [(2*W)-1:0] w_signed_A = {{W{src_A[W-1]}}, src_A};
   wire signed [(2*W)-1:0] w_signed_B = {{W{src_B[W-1]}}, src_B};
   wire        [(2*W)-1:0] w_unsigned_A = {{W{1'b0}}, w_src_A};
   wire        [(2*W)-1:0] w_unsigned_B = {{W{1'b0}}, w_src_B};

   wire [127:0]				   w_mul32b = {w_mul32b_hi, w_mul32b_lo};
   always_comb
     begin
	t_mul = is_signed ? (w_signed_A * w_signed_B) : (w_unsigned_A * w_unsigned_B);
     end

   // always_ff@(negedge clk)
   //   begin
   // 	if(go)
   // 	  begin
   // 	     $display("%x : %x * %x", t_mul, src_A, src_B);
   // 	  end
   // 	if(complete)
   // 	  begin
   // 	     $display("w_mul32b_lo = %x, w_mul32b_hi = %x, w_mul64 = %x", w_mul32b_lo, w_mul32b_hi, r_mul[`MUL_LAT][63:0]);
   // 	  end
   //   end

   generate
      if(`M_WIDTH == 64)
	begin
	   assign y = r_is_32b[`MUL_LAT] ? w_mul32b : r_mul[`MUL_LAT];
	end
      else
	begin
	   assign y = r_mul[`MUL_LAT];
	end
   endgenerate
   

   always_ff@(posedge clk)
     begin
	r_mul[0] <= t_mul;
	for(integer i = 1; i <= `MUL_LAT; i=i+1)
	  begin
	     r_mul[i] <= r_mul[i-1];
	  end
     end
   
   // always_ff@(negedge clk)
   //   begin
   // 	if(go) $display("multiplying %d by %d, t_mul %d\n", 
   // 			src_A, src_B, t_mul);
   // 	if(r_complete[`MUL_LAT]) $display("result is %d", y);
   //   end
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(integer i = 0; i <= `MUL_LAT; i=i+1)
	       begin
		  r_rob_ptr[i] <= 'd0;
		  r_hilo_ptr[i] <= 'd0;

	       end
	     r_complete <= 'd0;
	     r_hilo_val <= 'd0;
	     r_is_32b <= 'd0;
	  end
	else
	  begin
	     for(integer i = 0; i <= `MUL_LAT; i=i+1)
	       begin
		  if(i == 0)
		    begin
		       r_complete[0] <= go;
		       r_rob_ptr[0] <= rob_ptr_in;
		       r_hilo_val[0] <= go;
		       r_hilo_ptr[0] <= hilo_prf_ptr_in;
		       r_is_32b[0] <= is_32b;
		    end
		  else
		    begin
		       r_complete[i] <= r_complete[i-1];
		       r_rob_ptr[i] <= r_rob_ptr[i-1];
		       r_hilo_val[i] <= r_hilo_val[i-1];
		       r_hilo_ptr[i] <= r_hilo_ptr[i-1];
		       r_is_32b[i] <= r_is_32b[i-1];
		    end
	       end
	  end
     end // always_ff@ (posedge clk)

   
endmodule
