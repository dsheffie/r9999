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
   
   input logic [`LG_ROB_ENTRIES-1:0] rob_ptr_in;
   input logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_in;
   
   
   output logic [(2*W)-1:0]		  y;
   output logic 			  complete;
   output logic [`LG_ROB_ENTRIES-1:0] 	  rob_ptr_out;
   output logic 			  hilo_prf_ptr_val_out;
   output logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_out;
   
   logic [`MUL_LAT:0] 			   r_complete;
   logic [`MUL_LAT:0] 			   r_hilo_val;
   logic [`LG_HILO_PRF_ENTRIES-1:0] 	   r_hilo_ptr[`MUL_LAT:0];
   logic [`LG_ROB_ENTRIES-1:0] 		   r_rob_ptr[`MUL_LAT:0];
  

   assign complete = r_complete[`MUL_LAT];
   assign rob_ptr_out = r_rob_ptr[`MUL_LAT];
   
   assign hilo_prf_ptr_val_out = r_hilo_val[`MUL_LAT];
   assign hilo_prf_ptr_out = r_hilo_ptr[`MUL_LAT];

   logic [(2*W)-1:0] 			   t_mul;
   logic [(2*W)-1:0]			   r_mul[`MUL_LAT:0];
   always_comb
     begin
	t_mul = is_signed ? ($signed(src_A) * $signed(src_B)) 
	  : src_A * src_B;
	y = r_mul[`MUL_LAT];
     end

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
		    end
		  else
		    begin
		       r_complete[i] <= r_complete[i-1];
		       r_rob_ptr[i] <= r_rob_ptr[i-1];
		       r_hilo_val[i] <= r_hilo_val[i-1];
		       r_hilo_ptr[i] <= r_hilo_ptr[i-1];
		    end
	       end
	  end
     end // always_ff@ (posedge clk)

   
endmodule
