module mipsseg(v_addr, l_addr, cache, mapped);
   input logic [31:0] v_addr;
   output logic [31:0] l_addr;
   output logic	       cache;
   output logic	       mapped;

   wire [3:0]	       w_seg = v_addr[31:28];
   
   always_comb
     begin
	cache = 1'b0;
	mapped = 1'b0;
	if(w_seg[3] == 1'b0)
	  begin /* kuseg */
	     cache = 1'b1;
	     mapped = 1'b1;
	     l_addr = v_addr;	     
	  end
	else if(w_seg[3:1] == 3'b100)
	  begin /* kseg0 */
	     mapped = 1'b0;
	     cache = 1'b1;
	     l_addr = {3'd0, v_addr[28:0]};
	  end
	else if(w_seg[3:1] == 3'b101)
	  begin /* kseg1 */
	     mapped = 1'b0;
	     cache = 1'b0;
	     l_addr = {3'd0, v_addr[28:0]};
	  end
	else 
	  begin /* kseg2 */
	     mapped = 1'b1;
	     cache = 1'b0;
	     l_addr = v_addr;
	  end
     end // always_comb

endmodule
