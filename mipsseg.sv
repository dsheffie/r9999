`include "machine.vh"

module mipsseg(v_addr, l_addr, cache, mapped, seg);
   input logic [`M_WIDTH-1:0] v_addr;
   output logic [`M_WIDTH-1:0] l_addr;
   output logic		       cache;
   output logic	       mapped;
   output logic [1:0]  seg;
   
   wire [3:0]	       w_seg = v_addr[31:28];

   localparam	       ZP = `M_WIDTH-29;
   
   always_comb
     begin
	cache = 1'b0;
	mapped = 1'b0;
	seg = 'd0;
	
	if(w_seg[3] == 1'b0)
	  begin /* kuseg */
	     cache = 1'b1;
	     mapped = 1'b1;
	     l_addr = v_addr;
	     seg = 'd3;
	  end
	else if(w_seg[3:1] == 3'b100)
	  begin /* kseg0 */
	     mapped = 1'b0;
	     cache = 1'b1;
	     l_addr = {{ZP{1'b0}}, v_addr[28:0]};
	     seg = 'd0;	     
	  end
	else if(w_seg[3:1] == 3'b101)
	  begin /* kseg1 */
	     mapped = 1'b0;
	     cache = 1'b0;
	     l_addr = {{ZP{1'b0}}, v_addr[28:0]};
	     seg = 'd1;	     
	  end
	else 
	  begin /* kseg2 */
	     mapped = 1'b1;
	     cache = 1'b0;
	     l_addr = v_addr;
	     seg = 'd2;
	  end
     end // always_comb

endmodule
