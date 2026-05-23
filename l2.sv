`include "machine.vh"

module l2(clk,
	  reset,
	  state,
	  l1i_flush_req,
	  l1d_flush_req,

	  l1i_flush_complete,
	  l1d_flush_complete,
	  
	  flush_complete,

	  //l1 -> l2
	  l1_mem_req_valid,
	  l1_mem_req_ack,
	  l1_mem_req_addr,
	  l1_mem_req_cacheable,
	  l1_mem_req_mask,
	  l1_mem_req_store_data,
	  l1_mem_req_opcode,

	  //l2 -> l1
	  l1_mem_rsp_valid,
	  l1_mem_load_data,

	  //l2 -> mem
	  mem_req_ack,
	  mem_req_valid, 
	  mem_req_addr, 
	  mem_req_store_data, 
	  mem_req_opcode,
	  mem_req_mask,
	  
	  //mem -> l2
	  mem_rsp_valid,
	  mem_rsp_bad,
	  mem_rsp_load_data,

	  cache_hits,
	  cache_accesses
	  
	  );

   input logic clk;
   input logic reset;
   output logic [3:0] state;
   
   input logic l1i_flush_req;
   input logic l1d_flush_req;
   input logic l1i_flush_complete;
   input logic l1d_flush_complete;
   
   output logic flush_complete;

   input logic 	l1_mem_req_valid;
   output logic l1_mem_req_ack;
   input logic [31:0] l1_mem_req_addr;
   input logic	      l1_mem_req_cacheable;
   input logic [15:0] l1_mem_req_mask;
   
   input logic [127:0] l1_mem_req_store_data;
   input logic [3:0]   l1_mem_req_opcode;

   output logic        l1_mem_rsp_valid;
   output logic [127:0] l1_mem_load_data;
   
   input logic 	mem_req_ack;
   output logic mem_req_valid;
   output logic [31:0] mem_req_addr;
   output logic [127:0] mem_req_store_data;
   output logic [3:0] 	mem_req_opcode;
   output logic [15:0]	mem_req_mask;
   
   input logic 		mem_rsp_valid;
   input logic		mem_rsp_bad;
   
   input logic [127:0] 	mem_rsp_load_data;

   output logic [63:0] cache_hits;
   output logic [63:0] cache_accesses;
   
   
   localparam LG_L2_LINES = `LG_L2_NUM_SETS;
   localparam L2_LINES = 1<<LG_L2_LINES;
   
   localparam TAG_BITS = 32 - (LG_L2_LINES + 4);

   logic 		t_wr_dirty, t_wr_valid;
   logic 		t_wr_d0, t_wr_tag;
   
   logic 		t_valid, t_dirty;
   logic [LG_L2_LINES-1:0] t_idx, r_idx;
   logic [TAG_BITS-1:0]	   n_tag, r_tag;
   logic [31:0] 	 n_addr, r_addr;
   logic [31:0] 	 n_saveaddr, r_saveaddr;
   
   logic [3:0] 		   n_opcode, r_opcode;

   logic 		   r_mem_req, n_mem_req;
   logic [3:0] 		   r_mem_opcode, n_mem_opcode;
   logic 		   r_req_ack, n_req_ack;
   
   logic 		   r_rsp_valid, n_rsp_valid;
   logic [127:0] 	   r_rsp_data, n_rsp_data;
   logic [127:0] 	   r_store_data, n_store_data;
   logic [15:0]		   r_store_mask, n_store_mask;
   
   
   logic 		   r_reload, n_reload;
   
   typedef enum logic  {
			     WAIT_FOR_FLUSH,
			     WAIT_FOR_L1_FLUSH_DONE
			     } flush_state_t;

   logic 	r_need_l1i,n_need_l1i,r_need_l1d,n_need_l1d;
   logic 	t_l2_flush_req;
   
   flush_state_t n_flush_state, r_flush_state;
   
   
   typedef enum 	logic [3:0] {
				     INITIALIZE = 'd0,
				     IDLE = 'd1,
				     WAIT_FOR_RAM = 'd2,
				     CHECK_VALID_AND_TAG = 'd3,
				     CLEAN_RELOAD = 'd4,
				     DIRTY_STORE = 'd5,
				     STORE_TURNAROUND = 'd6,
				     WAIT_CLEAN_RELOAD = 'd7,
				     WAIT_STORE_IDLE = 'd8,
				     FLUSH_STORE = 'd9,
				     FLUSH_WAIT = 'd10,
				     FLUSH_TRIAGE = 'd11,
				     UNCACHE_STORE = 'd12,
				     UNCACHE_LOAD = 'd13,
				     GAMEOVER = 'd14
				     } state_t;

   state_t n_state, r_state;

   assign state = r_state;
   logic 		n_flush_complete, r_flush_complete;
   logic 		r_flush_req, n_flush_req;
   logic [127:0] 	r_mem_req_store_data, n_mem_req_store_data;
   logic [63:0] 	r_cache_hits, n_cache_hits, r_cache_accesses, n_cache_accesses;
   
   assign flush_complete = r_flush_complete;
   assign mem_req_addr = r_addr;
   assign mem_req_valid = r_mem_req;
   assign mem_req_opcode = r_mem_opcode;
   assign mem_req_store_data = r_mem_req_store_data;
   assign mem_req_mask = r_store_mask;
   
   assign l1_mem_rsp_valid = r_rsp_valid;
   assign l1_mem_load_data = r_rsp_data;
   assign l1_mem_req_ack = r_req_ack;
   
   assign cache_hits = r_cache_hits;
   assign cache_accesses = r_cache_accesses;
   
     
   logic [127:0] 	t_d0;
      
   wire [127:0] 	w_d0;
   wire [TAG_BITS-1:0] 	w_tag;
   wire 		w_valid, w_dirty;

   
   reg_ram1rw #(.WIDTH(128), .LG_DEPTH(LG_L2_LINES)) data_ram0
     (.clk(clk), .addr(t_idx), .wr_data(t_d0), .wr_en(t_wr_d0), .rd_data(w_d0));
      
   reg_ram1rw #(.WIDTH(TAG_BITS), .LG_DEPTH(LG_L2_LINES)) tag_ram
     (.clk(clk), .addr(t_idx), .wr_data(r_tag), .wr_en(t_wr_tag), .rd_data(w_tag));   
   
   reg_ram1rw #(.WIDTH(1), .LG_DEPTH(LG_L2_LINES)) valid_ram
     (.clk(clk), .addr(t_idx), .wr_data(t_valid), .wr_en(t_wr_valid), .rd_data(w_valid));   

   reg_ram1rw #(.WIDTH(1), .LG_DEPTH(LG_L2_LINES)) dirty_ram
     (.clk(clk), .addr(t_idx), .wr_data(t_dirty), .wr_en(t_wr_dirty), .rd_data(w_dirty));   

   wire 		w_hit = w_valid ? (r_tag == w_tag) : 1'b0;
   wire 		w_need_wb = w_valid ? w_dirty : 1'b0;
      
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= INITIALIZE;
	     r_flush_state <= WAIT_FOR_FLUSH;
	     r_flush_complete <= 1'b0;
	     r_idx <= 'd0;
	     r_tag <= 'd0;
	     r_opcode <= 4'd0;
	     r_addr <= 'd0;
	     r_saveaddr <= 'd0;
	     r_mem_req <= 1'b0;
	     r_mem_opcode <= 4'd0;
	     r_rsp_data <= 'd0;
	     r_rsp_valid <= 1'b0;
	     r_reload <= 1'b0;
	     r_req_ack <= 1'b0;
	     r_store_data <= 'd0;
	     r_store_mask <= 'd0;	     
	     r_flush_req <= 1'b0;
	     r_need_l1d <= 1'b0;
	     r_need_l1i <= 1'b0;
	     r_cache_hits <= 'd0;
	     r_cache_accesses <= 'd0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_flush_state <= n_flush_state;
	     r_flush_complete <= n_flush_complete;
	     r_idx <= t_idx;
	     r_tag <= n_tag;
	     r_opcode <= n_opcode;
	     r_addr <= n_addr;
	     r_saveaddr <= n_saveaddr;
	     r_mem_req <= n_mem_req;
	     r_mem_opcode <= n_mem_opcode;
	     r_rsp_data <= n_rsp_data;
	     r_rsp_valid <= n_rsp_valid;
	     r_reload <= n_reload;
	     r_req_ack <= n_req_ack;
	     r_store_data <= n_store_data;
	     r_store_mask <= n_store_mask;
	     r_flush_req <= n_flush_req;
	     r_need_l1i <= n_need_l1i;
	     r_need_l1d <= n_need_l1d;
	     r_cache_hits <= n_cache_hits;
	     r_cache_accesses <= n_cache_accesses;	     
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	r_mem_req_store_data <= n_mem_req_store_data;
     end
   
   //always_ff@(negedge clk)
   //begin
	//$display("l1i_flush_req = %b", l1i_flush_req);
	//$display("l1d_flush_req = %b", l1d_flush_req);
	
   //if((l1d_flush_complete||l1i_flush_complete) && (r_flush_state == WAIT_FOR_FLUSH)) 
   //$stop();
   //end
   
   always_comb
     begin
	n_flush_state = r_flush_state;
	n_need_l1d = r_need_l1d | l1d_flush_req;
	n_need_l1i = r_need_l1i | l1i_flush_req;
	t_l2_flush_req = 1'b0;
	case(r_flush_state)
	  WAIT_FOR_FLUSH:
	    begin
	       if(n_need_l1i | n_need_l1d)
		 begin
		    n_flush_state = WAIT_FOR_L1_FLUSH_DONE;
		    //$display("-> got flush req at cycle %d, n_need_l1d = %b, n_need_l1i = %b", r_cycle, n_need_l1d, n_need_l1i);
		 end
	    end
	  WAIT_FOR_L1_FLUSH_DONE:
	    begin
	       if(r_need_l1d && l1d_flush_complete)
		 begin
		    //$display("-> l1d flush complete at cycle %d", r_cycle);
		    n_need_l1d = 1'b0;
		 end
	       if(r_need_l1i && l1i_flush_complete)
		 begin
		    //$display("-> l1i flush complete at cycle %d", r_cycle);
		    n_need_l1i = 1'b0;
		 end
	       
	       if((n_need_l1d==1'b0) && (n_need_l1i==1'b0))
		 begin
		    //$display("-> firing l2 flush at cycle %d", r_cycle);
		    n_flush_state = WAIT_FOR_FLUSH;
		    t_l2_flush_req = 1'b1;
		 end
	    end
	endcase
     end // always_comb


   logic [31:0] r_cycle;
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : (r_cycle + 'd1);
     end


   always_comb
     begin
	n_state = r_state;
	n_flush_complete = 1'b0;
	t_wr_valid = 1'b0;
	t_wr_dirty = 1'b0;
	t_wr_d0 = 1'b0;
	t_wr_tag = 1'b0;
	
	t_idx = r_idx;
	n_tag = r_tag;
	n_opcode = r_opcode;
	n_addr = r_addr;
	n_saveaddr = r_saveaddr;
	
	n_req_ack = 1'b0;
	n_mem_req = r_mem_req;
	n_mem_opcode = r_mem_opcode;
		
	t_valid = 1'b0;
	t_dirty = 1'b0;

	t_d0 = mem_rsp_load_data[127:0];

	n_rsp_data = r_rsp_data;
	n_rsp_valid = 1'b0;

	n_reload = r_reload;
	n_store_data = r_store_data;
	n_store_mask = r_store_mask;
	n_flush_req = r_flush_req | t_l2_flush_req;
	n_mem_req_store_data = r_mem_req_store_data;

	n_cache_hits = r_cache_hits;
	n_cache_accesses = r_cache_accesses;
	
	case(r_state)
	  INITIALIZE:
	    begin
	       t_valid = 1'b0;
	       t_dirty = 1'b0;
	       
	       t_wr_valid = 1'b1;
	       t_wr_dirty = 1'b1;
	       
	       t_idx = r_idx + 'd1;
	       if(r_idx == (L2_LINES-1))
		 begin
		    n_state = IDLE;
		    n_flush_complete = 1'b1;
		 end
	    end // case: INITIALIZE
	  IDLE:
	    begin
	       t_idx = l1_mem_req_addr[LG_L2_LINES+3:4];
	       n_tag = l1_mem_req_addr[31:LG_L2_LINES+4];
	       n_addr = {l1_mem_req_addr[31:4], 4'd0};
	       n_saveaddr = {l1_mem_req_addr[31:4], 4'd0};
	       n_opcode = l1_mem_req_opcode;
	       n_store_data = l1_mem_req_store_data;
	       n_store_mask = 16'h0;
	       
	       if(n_flush_req)
		 begin
		    t_idx = 'd0;
		    n_state = FLUSH_WAIT;
		    n_store_mask = 16'hffff;
		    //$display("GOT FLUSH REQUEST at cycle %d", r_cycle);
		 end
	       else if(l1_mem_req_valid)
		 begin
		    if(l1_mem_req_cacheable == 1'b0)
		      begin
			 //$display("uncachable req at l2 for address %x", n_addr);
			 n_store_mask = l1_mem_req_mask;
			 n_req_ack = 1'b1;
			 n_state = (l1_mem_req_opcode == 4'd7) ? UNCACHE_STORE : UNCACHE_LOAD;
			 n_mem_opcode = l1_mem_req_opcode;
			 n_mem_req_store_data = l1_mem_req_store_data;
			 if(l1_mem_req_opcode == 7 & (&n_store_mask))
			   begin
			      $stop();
			   end
			 //$display("l1_mem_req_opcode = %d", l1_mem_req_opcode);
			 n_mem_req = 1'b1;			 
		      end
		    else
		      begin
			 n_req_ack = 1'b1;
			 n_state = WAIT_FOR_RAM;
			 n_rsp_valid = (l1_mem_req_opcode == 4'd7);
			 n_cache_accesses = r_cache_accesses + 64'd1;
			 n_cache_hits = r_cache_hits + 64'd1;
		      end
		 end
	    end
	  WAIT_FOR_RAM:
	    begin
	       n_state = CHECK_VALID_AND_TAG;
	    end
	
	  CHECK_VALID_AND_TAG:
	    begin
	       //load hit
	       if(w_hit)
		 begin
		    n_reload = 1'b0;
		    if(r_opcode == 4'd4)
		      begin			 
			 n_rsp_data =  w_d0;
			 n_state = IDLE;
			 n_rsp_valid = 1'b1;
			 //n_cache_hits = r_cache_hits + 64'd1;			 
		      end
		    else if(r_opcode == 4'd7)
		      begin
			 t_wr_dirty = 1'b1;
			 t_dirty = 1'b1;
			 n_state = WAIT_STORE_IDLE;
			 //n_cache_hits = r_cache_hits + 64'd1;			 
			 t_d0 = r_store_data;
			 t_wr_d0 = 1'b1;
		      end
		 end
	       else
		 begin
		    n_cache_hits = r_cache_hits - 64'd1;			 		    
		    if(w_dirty)
		      begin
			 n_mem_req_store_data = w_d0;
			 n_addr = {w_tag, t_idx, 4'd0};
			 n_mem_opcode = 4'd7;
			 n_store_mask = 16'hffff;
			 
			 n_mem_req = 1'b1;
			 n_state = DIRTY_STORE;			 
		      end
		    else //invalid or clean
		      begin
`ifdef VERILATOR
			 if(r_reload)
			   $stop();
`endif
			 n_reload = 1'b1;
			 n_state = CLEAN_RELOAD;
			 n_mem_opcode = 4'd4; //load
			 n_store_mask = 16'hffff;			 
			 n_mem_req = 1'b1;
		      end
		 end
	    end // case: CHECK_VALID_AND_TAG
	  DIRTY_STORE:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;		    
		 end
	       if(mem_rsp_valid)
		 begin
		    n_addr = r_saveaddr;
		    n_mem_opcode = 4'd4; //load
		    n_store_mask = 16'hffff;
		    n_state = STORE_TURNAROUND;
		    n_mem_req = 1'b0;		    
		 end
	    end // case: DIRTY_STORE
	  STORE_TURNAROUND:
	    begin
	       n_state = CLEAN_RELOAD;
	       n_reload = 1'b1;
	       n_mem_req = 1'b1;		    
	    end
	  CLEAN_RELOAD:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;
		 end
	       if(mem_rsp_valid)
		 begin
		    n_mem_req = 1'b0;
		    t_valid = 1'b1;
		    t_wr_valid = 1'b1;
		    t_wr_tag = 1'b1;
		    t_wr_d0 = 1'b1;
		    n_state = WAIT_CLEAN_RELOAD;
		 end
	    end // case: CLEAN_RELOAD
	  WAIT_CLEAN_RELOAD: /* need a cycle to turn around */
	    begin
	       n_state = WAIT_FOR_RAM;
	    end
	  WAIT_STORE_IDLE:
	    begin
	       n_state = IDLE;
	    end
	  FLUSH_WAIT:
	    begin
	       n_state = FLUSH_TRIAGE;
	       t_valid = 1'b0;
	       t_dirty = 1'b0;
	       t_wr_valid = 1'b1;
	       t_wr_dirty = 1'b1;
	    end
	  FLUSH_TRIAGE:
	    begin
	       //$display("r_idx = %d, w_need_wb %b", r_idx, w_need_wb);
	       
	       if(w_need_wb)
		 begin
		    n_mem_req_store_data = w_d0;
		    n_addr = {w_tag, t_idx, 4'd0};
		    n_mem_opcode = 4'd7; 
		    n_mem_req = 1'b1;
		    n_state = FLUSH_STORE;
		 end
	       else
		 begin
		    t_idx = r_idx + 'd1;
		    if(r_idx == (L2_LINES-1))
		      begin
			 n_state = IDLE;
			 //$display("L2 flush complete at cycle %d", r_cycle);
			 n_flush_complete = 1'b1;
			 n_flush_req = 1'b0;
		      end
		    else
		      begin
			 n_state = FLUSH_WAIT;
		      end
		 end
	    end // case: FLUSH_TRIAGE
	  FLUSH_STORE:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;		    
		 end
	       
	       if(mem_rsp_valid)
		 begin
		    n_mem_req = 1'b0;
		    t_idx = r_idx + 'd1;
		    if(r_idx == (L2_LINES-1))
		      begin
			 n_state = IDLE;
			 //$display("L2 flush complete at cycle %d", r_cycle);
			 n_flush_complete = 1'b1;
			 n_flush_req = 1'b0;
		      end
		    else
		      begin
			 n_state = FLUSH_WAIT;
		      end		    
		 end
	    end // case: FLUSH_STORE
	  UNCACHE_STORE:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;
		 end	       
	       if(mem_rsp_valid)
		 begin
		    n_state = IDLE;
		    n_rsp_valid = 1'b1;		    
		 end
	    end
	  UNCACHE_LOAD:
	    begin
	       if(mem_rsp_valid)
		 begin
		    n_rsp_valid = 1'b1;
		    n_rsp_data = mem_rsp_load_data;
		    n_state = IDLE;
		 end
	    end
	  default:
	    begin
	    end
	endcase
     end
   
endmodule
