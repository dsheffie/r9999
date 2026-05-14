module formal_top(clk,reset,
		  resume,resume_pc,
		  mem_req_valid,mem_req_addr,mem_req_store_data,
		  mem_req_opcode,mem_rsp_valid,mem_rsp_load_data,
		  putchar_fifo_empty,putchar_fifo_out,putchar_fifo_pop);
   input clk;
   input reset;
   input resume;
   input [31:0]	resume_pc;
   output	mem_req_valid;
   output [31:0] mem_req_addr;
   output [127:0] mem_req_store_data;
   output [4:0]	  mem_req_opcode;
   input	  mem_rsp_valid;
   input [127:0]  mem_rsp_load_data;

   output	 putchar_fifo_empty;
   output [7:0]	 putchar_fifo_out;
   input	 putchar_fifo_pop;
   

   
   wire		w_pc_valid,w_pc2_valid;
   wire w_got_break, w_got_ud, w_got_bad_addr;
   wire w_l1i_flush_done, w_l1d_flush_done, w_l2_flush_done;
   
   wire [31:0] w_epc;
   wire [4:0]  w_cause;
   
   
   wire [4:0]					w_state; //5
   wire [3:0]					w_dstate, w_l2state; //12
   wire [2:0]					w_istate; //3

   
   core_l1d_l1i 
     mipscpu0 (
	   .clk(clk),
	   .reset(reset),
	   .extern_irq(1'b0),	     
	   .in_flush_mode(),
	   .resume(resume),
	   .resume_pc(resume_pc),
	   .ready_for_resume(),

	   .putchar_fifo_out(putchar_fifo_out),
	   .putchar_fifo_empty(putchar_fifo_empty),
	   .putchar_fifo_pop(putchar_fifo_pop),		     
	   .putchar_fifo_wptr(),
	   .putchar_fifo_rptr(),
	       
	   //.reset_out(w_reset_out),

	   
	   .mem_req_valid(mem_req_valid),
	   .mem_req_addr(mem_req_addr),
	   .mem_req_store_data(mem_req_store_data),
	   .mem_req_opcode(mem_req_opcode),
	   .mem_rsp_valid(mem_rsp_valid),
	   .mem_rsp_load_data(mem_rsp_load_data),
	       
	   .retire_reg_ptr(),
	   .retire_reg_data(),
	   .retire_reg_valid(),
	   .retire_reg_two_ptr(),
	   .retire_reg_two_data(),
	   .retire_reg_two_valid(),
	   .retire_valid(w_pc_valid),
	   .retire_two_valid(w_pc2_valid),
	   .retire_pc(),
	   .retire_two_pc(),
	   .retire_op(),
	   .retire_two_op(),
	       	       
	   .branch_pc(),
	   .branch_pc_valid(),
	   .branch_fault(),

	   .got_break(w_got_break),
	   .got_ud(w_got_ud),
	   .got_bad_addr(w_got_bad_addr),
	   .core_state(w_state),
	   .l1i_state(w_istate),
	   .l1d_state(w_dstate),
	   .l2_state(w_l2state),
	   .inflight(),
	   .epc(w_epc),
	   .cause(w_cause),
	   .l1i_flush_done(w_l1i_flush_done),
	   .l1d_flush_done(w_l1d_flush_done),
	   .l2_flush_done(w_l2_flush_done)	       
	   );

   reg [3:0]					r_cycle = 'd0;
   always@(posedge clk)
     begin
	r_cycle <= (&r_cycle) ? 'd255 : r_cycle + 'd1;
     end

   always@(*)
     begin
	if(r_cycle < 'd2)
	  begin
	     assume(reset);
	  end
	else
	  begin
	     assume(!reset);
	  end
     end // always@ (*)

   always@(posedge clk)
     begin
	if(r_cycle > 'd1)
	  begin
	     cover(w_pc_valid);
	     cover(w_pc2_valid);
	     cover(w_state != 'd0);
	     
	     if(w_pc2_valid)
	       begin
		  assert(w_pc_valid);
	       end
	     if(mem_req_valid)
	       begin
		  assert(mem_req_addr[3:0] == 'd0);
	       end
	     cover(mem_req_valid & mem_req_addr != 'd0);
	  end // if (r_cycle > 'd2)
     end // always@ (posedge clk)

endmodule   
   
