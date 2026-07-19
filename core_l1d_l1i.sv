`include "machine.vh"
`include "rob.vh"
`include "uop.vh"

module core_l1d_l1i(clk, 
		    reset,
		    ip6,
		    ip5,
		    ip4,
		    ip3,
		    ip2,
		    retire_allowed,
		    putchar_fifo_out,
		    putchar_fifo_empty,
		    putchar_fifo_pop,
		    putchar_fifo_wptr,
		    putchar_fifo_rptr,
		    single_step,
		    bp_enable,
		    fault_clear,
		    bp_pc,
		    bp_wp_addr,
		    bp_wp_val,
		    step,
		    in_flush_mode,
		    resume,
		    resume_pc,
		    ready_for_resume,
		    
		    mem_req_valid, 
		    mem_req_addr, 
		    mem_req_store_data,
		    mem_req_opcode,
		    mem_req_mask,
		    mem_rsp_valid,
		    mem_rsp_bad,		    
		    mem_rsp_load_data,
		    
		    retire_reg_ptr,
		    retire_reg_data,
		    retire_reg_valid,
		    retire_reg_two_ptr,
		    retire_reg_two_data,
		    retire_reg_two_valid,
		    retire_valid,
		    retire_two_valid,
		    retire_pc,
		    retire_two_pc,
		    retire_op,
		    retire_two_op,
		    branch_pc,
		    branch_pc_valid,		    
		    branch_fault,
		    l1i_cache_accesses,
		    l1i_cache_hits,
		    l1d_cache_accesses,
		    l1d_cache_hits,
		    l2_cache_accesses,
		    l2_cache_hits,
		    got_break,
		    got_ud,
		    got_bad_addr,
		    core_state,
		    l1i_state,
		    l1d_state,
		    l2_state,
		    l2_rsp_state,
		    inflight,
		    epc,
		    status_reg,
		    badvaddr,
		    cause,
		    dbg_frozen,
		    dbg_wp_data,
		    cause_ip,
		    l1i_flush_done,
		    l1d_flush_done,
		    l2_flush_done,
		    snoop_req_valid,
		    snoop_req_addr,
		    snoop_req_ack,
		    took_irq,
		    cp0_count,
		    dbg_head_pc,
		    dbg_head_status,
		    dbg_head_fetch_cycle,
		    dbg_head_alloc_cycle,
		    dbg_serialize_cycle,
		    dbg_cycle,
		    dbg_oldest_first_pending,
		    dbg_trace_index,
		    dbg_trace_data,
		    dbg_trace_wptr
		    );

   localparam L1D_CL_LEN = 1 << `LG_L1D_CL_LEN;
   localparam L1D_CL_LEN_BITS = 1 << (`LG_L1D_CL_LEN + 3);
   
   input logic clk;
   input logic reset;
   input logic retire_allowed;
   input logic ip6;
   input logic ip5;
   input logic ip4;
   input logic ip3;
   input logic ip2;
   
   output logic [7:0] putchar_fifo_out;
   output logic       putchar_fifo_empty;
   input logic 	      putchar_fifo_pop;
   output logic [3:0] putchar_fifo_wptr;
   output logic [3:0] putchar_fifo_rptr;
   
   input logic single_step;
   input logic bp_enable;
   input logic fault_clear;
   input logic [31:0] bp_pc;
   input logic [31:0] bp_wp_addr;
   input logic [31:0] bp_wp_val;
   input logic step;
   input logic resume;
   input logic [(`M_WIDTH-1):0] resume_pc;
   output logic 		in_flush_mode;
   output logic 		ready_for_resume;
   

   logic [(`M_WIDTH-1):0] 	restart_pc;
   logic [(`M_WIDTH-1):0] 	restart_src_pc;
   logic 			restart_src_is_indirect;
   logic 			restart_valid;
   logic 			clr_link_reg;
   logic 			restart_ack;
   logic [`LG_PHT_SZ-1:0] 	branch_pht_idx;
   logic 			took_branch;

   logic 			t_retire_delay_slot;
   logic [(`M_WIDTH-1):0] 	t_branch_pc;
   logic 			t_branch_pc_valid;
   logic 			t_branch_fault;

   output logic [(`M_WIDTH-1):0] branch_pc;
   output logic 		 branch_pc_valid;
   output logic 		 branch_fault;
   
   assign branch_pc = t_branch_pc;
   assign branch_pc_valid = t_branch_pc_valid;   
   assign branch_fault = t_branch_fault;

   output logic [63:0] 			l1i_cache_accesses;
   output logic [63:0] 			l1i_cache_hits;
   output logic [63:0] 			l1d_cache_accesses;
   output logic [63:0] 			l1d_cache_hits;
   output logic [63:0] 			l2_cache_accesses;
   output logic [63:0] 			l2_cache_hits;   

   
   /* mem port */
   output logic 		 mem_req_valid;
   output logic [`PA_WIDTH-1:0] 	 mem_req_addr;
   output logic [127:0] 	 mem_req_store_data;
   output logic [4:0] 		 mem_req_opcode;
   output logic [15:0]		 mem_req_mask;
   
   
   input logic  			  mem_rsp_valid;
   input logic				  mem_rsp_bad;
   
   input logic [127:0] 			  mem_rsp_load_data;

   output logic [4:0] 			  retire_reg_ptr;
   output logic [`M_WIDTH-1:0]		  retire_reg_data;
   output logic 			  retire_reg_valid;

   output logic [4:0] 			  retire_reg_two_ptr;
   output logic [`M_WIDTH-1:0]		  retire_reg_two_data;
   output logic 			  retire_reg_two_valid;
   
   output logic 			  retire_valid;
   output logic 			  retire_two_valid;
   output logic [(`M_WIDTH-1):0] 	  retire_pc;
   output logic [(`M_WIDTH-1):0] 	  retire_two_pc;

   output logic [7:0]			  retire_op;
   output logic [7:0]			  retire_two_op;   
   
   logic 				  retired_call;
   logic 				  retired_ret;

   logic 				  retired_rob_ptr_valid;
   logic 				  retired_rob_ptr_two_valid;
   logic [`LG_ROB_ENTRIES-1:0] 		  retired_rob_ptr;
   logic [`LG_ROB_ENTRIES-1:0] 		  retired_rob_ptr_two;

   
   output logic 			  got_break;
   output logic 			  got_ud;
   output logic 			  got_bad_addr;
   
   output logic [`LG_ROB_ENTRIES:0] 	  inflight;
   output logic [4:0]			  core_state; 
   output logic [3:0]			  l1i_state;
   output logic [3:0]			  l1d_state;
   output logic [3:0]			  l2_state;
   output logic [3:0]			  l2_rsp_state;
   
   output logic [`M_WIDTH-1:0]		  epc;
   output logic [31:0]			  status_reg;
   output logic [`M_WIDTH-1:0]		  badvaddr;
   output logic [4:0]			  cause;
   output logic [2:0]			  dbg_frozen;
   output logic [31:0]			  dbg_wp_data;
   output logic [7:0]			  cause_ip;

   
      
   output logic			 l1d_flush_done;
   output logic			 l1i_flush_done;
   output logic			 l2_flush_done;
   input logic 		 snoop_req_valid;
   input logic [`PA_WIDTH-1:0] snoop_req_addr;
   output logic		 snoop_req_ack;
   output logic			 took_irq;
   output logic [31:0]		 cp0_count;
   output logic [31:0]  dbg_head_pc;
   output logic [31:0]  dbg_head_status;
   output logic [31:0]  dbg_head_fetch_cycle;
   output logic [31:0]  dbg_head_alloc_cycle;
   output logic [31:0]  dbg_serialize_cycle;
   output logic [31:0]  dbg_cycle;
   output logic         dbg_oldest_first_pending;
   input  logic [11:0]  dbg_trace_index;
   output logic [31:0]  dbg_trace_data;
   output logic [8:0]   dbg_trace_wptr;
      


   logic 				  head_of_rob_ptr_valid;
   logic [`LG_ROB_ENTRIES-1:0] 		  head_of_rob_ptr;
   logic				  head_of_rob_has_delay_slot;
   logic [`LG_ROB_ENTRIES-1:0] 		  next_head_of_rob_ptr;
   logic				  head_of_rob_ds_committable;
   

   wire					  w_in_kernel_mode, w_in_supervisor_mode,
					  w_in_user_mode;
   wire					  w_in_64b_kernel_mode, w_in_64b_supervisor_mode,
					  w_in_64b_user_mode;
   wire 				  flush_req_l1i, flush_req_l1d;
   logic 				  flush_cl_req;
   logic [`M_WIDTH-1:0] 		  flush_cl_addr;
   logic 				  flush_cl_inval;
   wire 				  l1d_flush_complete;
   wire 				  l1i_flush_complete;

   
   mem_req_t core_mem_req;
   mem_rsp_t core_mem_rsp;
   mem_data_t core_store_data;
   
   logic 				  core_mem_req_valid;
   logic 				  core_mem_req_ack;
   logic 				  core_mem_rsp_valid;
   logic 				  core_store_data_valid;
   logic 				  core_store_data_ack;
   
   
   typedef enum logic [2:0] {
			     FLUSH_IDLE = 'd0,
			     WAIT_FOR_L1D_L1I = 'd1,
			     GOT_L1D = 'd2,
			     GOT_L1I = 'd3,
			     FLUSH_L2 = 'd4
   } flush_state_t;
   flush_state_t n_flush_state, r_flush_state;
   logic 	r_flush, n_flush;
   logic 	r_flush_l2, n_flush_l2;
   /* sticky latches for the flush handshake: flush_req_l1i/l1d and
    * l1i/l1d_flush_complete arrive as SINGLE-CYCLE pulses.  The old arbiter checked
    * each pulse only in one specific state, so a pulse that arrived when the arbiter
    * was elsewhere (blast_icache32 fires CACHE ops back-to-back and timing drifts --
    * e.g. ROB-16 / skid-off) was LOST -> arbiter never chained the L2 flush -> the
    * core's CACHE_FLUSH waited forever on l2_flush_complete -> boot deadlock.  Latch
    * the pulses so none is dropped; cleared at sequence end (FLUSH_L2 done). */
   logic 	r_req_l1i_l, n_req_l1i_l;
   logic 	r_req_l1d_l, n_req_l1d_l;
   logic 	r_dn_l1i, n_dn_l1i;
   logic 	r_dn_l1d, n_dn_l1d;
   wire 	w_l2_flush_complete;
   wire 	w_l1_mem_rsp_valid;   
   logic 	memq_empty;   
   assign in_flush_mode = r_flush;
   wire [7:0] w_asid;

 
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_flush_state <= FLUSH_IDLE;
	     r_flush <= 1'b0;
	     r_flush_l2 <= 1'b0;
	     r_req_l1i_l <= 1'b0;
	     r_req_l1d_l <= 1'b0;
	     r_dn_l1i <= 1'b0;
	     r_dn_l1d <= 1'b0;
	  end
	else
	  begin
	     r_flush_state <= n_flush_state;
	     r_flush <= n_flush;
	     r_flush_l2 <= n_flush_l2;
	     r_req_l1i_l <= n_req_l1i_l;
	     r_req_l1d_l <= n_req_l1d_l;
	     r_dn_l1i <= n_dn_l1i;
	     r_dn_l1d <= n_dn_l1d;
	  end
     end // always_ff@ (posedge clk)

	      
   always_comb
     begin
	n_flush_state = r_flush_state;
	n_flush = r_flush;
	n_flush_l2 = 1'b0;
	/* accumulate the single-cycle req/complete pulses so no state can miss one */
	n_req_l1i_l = r_req_l1i_l | flush_req_l1i;
	n_req_l1d_l = r_req_l1d_l | flush_req_l1d;
	n_dn_l1i    = r_dn_l1i    | l1i_flush_complete;
	n_dn_l1d    = r_dn_l1d    | l1d_flush_complete;

	case(r_flush_state)
	  FLUSH_IDLE:
	    begin
	       /* between sequences the complete-latches must read clear so a stale
		* prior-sequence pulse can't pre-satisfy this one. */
	       n_dn_l1i = 1'b0;
	       n_dn_l1d = 1'b0;
	       if(n_req_l1i_l && n_req_l1d_l)
		 begin
		    n_flush_state = WAIT_FOR_L1D_L1I;
		    n_flush = 1'b1;
		 end
	       else if(n_req_l1i_l && !n_req_l1d_l)
		 begin
		    n_flush_state = GOT_L1D;
		    n_flush = 1'b1;
		 end
	       else if(!n_req_l1i_l && n_req_l1d_l)
		 begin
		    n_flush_state = GOT_L1I;
		    n_flush = 1'b1;
		 end
	    end
	  WAIT_FOR_L1D_L1I:
	    begin
	       if(n_dn_l1d && !n_dn_l1i)
		 begin
		    n_flush_state = GOT_L1D;
		 end
	       else if(!n_dn_l1d && n_dn_l1i)
		 begin
		    n_flush_state = GOT_L1I;
		 end
	       else if(n_dn_l1d && n_dn_l1i)
		 begin
		    $display("flush l2");
		    n_flush_state = FLUSH_L2;
		    n_flush_l2 = 1'b1;
		 end
	    end
	  GOT_L1D:
	    begin
	       /* L1I-only flush (the I-side CACHE op): DONE once the L1I is
		* invalidated.  Do NOT chain an L2 flush -- the I-cache is read-only
		* and L2 is its refill source; flushing L2 here was wrong and the
		* deadlock/O(n^2) source.  Return to IDLE and clear the latches. */
	       if(n_dn_l1i)
		 begin
		    n_flush = 1'b0;
		    n_flush_state = FLUSH_IDLE;
		    n_req_l1i_l = 1'b0;
		    n_req_l1d_l = 1'b0;
		    n_dn_l1i = 1'b0;
		    n_dn_l1d = 1'b0;
		 end
	    end
	  GOT_L1I:
	    begin
	       if(n_dn_l1d)
		 begin
		    $display("flush l2");
		    n_flush_state = FLUSH_L2;
		    n_flush_l2 = 1'b1;
		 end
	    end
	  FLUSH_L2:
	    begin
	       if(w_l2_flush_complete)
		 begin
		    $display("L2 FLUSH COMPLETE");
		    n_flush = 1'b0;
		    n_flush_state = FLUSH_IDLE;
		    /* sequence done: clear all handshake latches */
		    n_req_l1i_l = 1'b0;
		    n_req_l1d_l = 1'b0;
		    n_dn_l1i = 1'b0;
		    n_dn_l1d = 1'b0;
		 end
	    end
	  default:
	    begin
	    end
	endcase // case (r_flush_state)
     end // always_comb
   
   typedef enum logic [1:0] {
      IDLE = 'd0,
      GNT_L1D = 'd1,
      GNT_L1I = 'd2			    
   } state_t;
   
   logic 				  l1d_mem_req_ack;
   logic 				  l1d_mem_req_valid;
   logic [(`PA_WIDTH-1):0] 		  l1d_mem_req_addr;
   logic [L1D_CL_LEN_BITS-1:0] 		  l1d_mem_req_store_data;
   logic [4:0] 				  l1d_mem_req_opcode;
   logic				  l1d_mem_req_cacheable;
   logic [15:0]				  l1d_mem_req_mask;
   
   logic 				  l1i_mem_req_ack;   
   logic 				  l1i_mem_req_valid;
   logic				  l1i_mem_req_cacheable;
   logic [(`PA_WIDTH-1):0]		  l1i_mem_req_addr;
   logic [15:0]				  l1i_mem_req_mask;
   
   logic [L1D_CL_LEN_BITS-1:0] 		  l1i_mem_req_store_data;
   logic [4:0] 				  l1i_mem_req_opcode;
   logic 				  l1d_mem_rsp_valid, l1i_mem_rsp_valid;
   
   state_t r_state, n_state;
   logic 				  r_l1d_req, n_l1d_req;
   logic 				  r_l1i_req, n_l1i_req;
   logic 				  r_last_gnt, n_last_gnt;
   logic 				  n_req, r_req;

   logic 				  insn_valid,insn_valid2;
   logic 				  insn_ack, insn_ack2;
   insn_fetch_t insn, insn2;


   logic [`PA_WIDTH-1:0]			  t_l2_req_addr;
   logic [4:0] 				  t_l2_req_opcode;
   logic				  t_l2_req_cacheable;
   logic [15:0]				  t_l2_req_mask;


   tlb_data_t tlb_entry_out;
   logic			    tlb_entry_out_valid;
   
   wire w_l1_mem_req_ack;
   

   always_comb
     begin
	n_state = r_state;
	n_last_gnt = r_last_gnt;
	n_l1i_req = r_l1i_req || l1i_mem_req_valid;
	n_l1d_req = r_l1d_req || l1d_mem_req_valid;
	n_req = r_req;
	
	//mem_req_valid = n_req;	
	t_l2_req_addr = (r_state == GNT_L1I) ? l1i_mem_req_addr: l1d_mem_req_addr;
	//mem_req_store_data = l1d_mem_req_store_data;
	t_l2_req_opcode = (r_state == GNT_L1I) ? l1i_mem_req_opcode : l1d_mem_req_opcode;
	t_l2_req_cacheable = (r_state == GNT_L1I) ? l1i_mem_req_cacheable : 
			     l1d_mem_req_cacheable;
	t_l2_req_mask = (r_state == GNT_L1I) ? l1i_mem_req_mask : l1d_mem_req_mask;
	
	l1d_mem_rsp_valid = 1'b0;
	l1i_mem_rsp_valid = 1'b0;

	case(r_state)
	  IDLE:
	    begin
	       if(n_l1d_req && !n_l1i_req)
		 begin
		    n_state = GNT_L1D;
		    n_req = 1'b1;
		 end
	       else if(!n_l1d_req && n_l1i_req)
		 begin
		    n_state = GNT_L1I;
		    n_req = 1'b1;
		 end
	       else if(n_l1d_req && n_l1i_req)
		 begin
		    n_state = r_last_gnt ? GNT_L1D : GNT_L1I;
		    n_req = 1'b1;
		 end
	    end
	  GNT_L1D:
	    begin
	       n_last_gnt = 1'b0;
	       n_l1d_req = 1'b0;
	       if(w_l1_mem_req_ack)
		 begin
		    n_req = 1'b0;
		 end
	       
	       if(w_l1_mem_rsp_valid)
		 begin
		    //$display("l2 cache complete for l1d");
		    n_req = 1'b0;
		    n_state = IDLE;
		    l1d_mem_rsp_valid = 1'b1;
		 end
	    end
	  GNT_L1I:
	    begin
	       n_last_gnt = 1'b1;
	       n_l1i_req = 1'b0;
	       if(w_l1_mem_req_ack)
		 begin
		    n_req = 1'b0;
		 end
	       
	       if(w_l1_mem_rsp_valid)
		 begin
		    //$display("l2 cache complete for l1i for addr %x",
		    //t_l2_req_addr);
		    n_req = 1'b0;		    
		    n_state = IDLE;
		    l1i_mem_rsp_valid = 1'b1;
		 end
	    end
	  default:
	    begin
	    end
	  endcase
     end // always_comb


   
   wire [127:0] w_l1_mem_load_data;

   
   l2 l2cache (
	       .clk(clk),
	       .reset(reset),
	       .state(l2_state),
	       .rsp_state(l2_rsp_state),
	       .l1i_flush_req(flush_req_l1i),
	       .l1d_flush_req(flush_req_l1d),
	       .l1i_flush_complete(l1i_flush_complete),
	       .l1d_flush_complete(l1d_flush_complete),
	       
	       .flush_complete(w_l2_flush_complete),
	       
	       .l1_mem_req_valid(r_req),
	       .l1_mem_req_ack(w_l1_mem_req_ack),
	       .l1_mem_req_addr(t_l2_req_addr),
	       .l1_mem_req_cacheable(t_l2_req_cacheable),
	       .l1_mem_req_mask(t_l2_req_mask),
	       .l1_mem_req_store_data(l1d_mem_req_store_data),
	       .l1_mem_req_opcode(t_l2_req_opcode),
	       
	       .l1_mem_rsp_valid(w_l1_mem_rsp_valid),
	       .l1_mem_load_data(w_l1_mem_load_data),
	       
	       .mem_req_ack(),
	       .mem_req_valid(mem_req_valid),
	       .mem_req_addr(mem_req_addr),
	       .mem_req_store_data(mem_req_store_data),
	       .mem_req_opcode(mem_req_opcode),
	       .mem_req_mask(mem_req_mask),
	       
	       .mem_rsp_valid(mem_rsp_valid),
	       .mem_rsp_bad(mem_rsp_bad),
	       .mem_rsp_load_data(mem_rsp_load_data),
	       .cache_accesses(l2_cache_accesses),
	       .cache_hits(l2_cache_hits),
		       .snoop_req_valid(1'b0)  /* task #51 DMA->L2 snoop tied off on main until the henry snoop FIFO is wired */,
		       .snoop_req_addr(snoop_req_addr),
		       .snoop_req_ack(snoop_req_ack)

	       );
   
   
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= IDLE;
	     r_last_gnt <= 1'b0;
	     r_l1d_req <= 1'b0;
	     r_l1i_req <= 1'b0;
	     r_req <= 1'b0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_last_gnt <= n_last_gnt;
	     r_l1d_req <= n_l1d_req;
	     r_l1i_req <= n_l1i_req;
	     r_req <= n_req;	     
	  end
     end

   logic 			  drain_ds_complete;
   logic [(1<<`LG_ROB_ENTRIES)-1:0] dead_rob_mask;
   
   l1d dcache (
	       .clk(clk),
	       .reset(reset),
	       .asid(w_asid),	
	       .tlb_entry_in(tlb_entry_out),
	       .tlb_entry_in_valid(tlb_entry_out_valid),
	       .state(l1d_state),
	       .in_kernel_mode(w_in_kernel_mode),
	       .in_supervisor_mode(w_in_supervisor_mode),
	       .in_user_mode(w_in_user_mode),
	       .head_of_rob_ptr_valid(head_of_rob_ptr_valid),
	       .head_of_rob_ptr(head_of_rob_ptr),
	       .head_of_rob_has_delay_slot(head_of_rob_has_delay_slot),
	       .next_head_of_rob_ptr(next_head_of_rob_ptr),
	       .head_of_rob_ds_committable(head_of_rob_ds_committable),
	       .retired_rob_ptr_valid(retired_rob_ptr_valid),
	       .retired_rob_ptr_two_valid(retired_rob_ptr_two_valid),
	       .retired_rob_ptr(retired_rob_ptr),
	       .retired_rob_ptr_two(retired_rob_ptr_two),
	       .restart_valid(restart_valid),
	       .clr_link_reg(clr_link_reg),
	       .memq_empty(memq_empty),
	       .drain_ds_complete(drain_ds_complete),
	       .dead_rob_mask(dead_rob_mask),
	       .flush_req(flush_req_l1d),
	       .flush_cl_req(flush_cl_req),
	       .flush_cl_addr(flush_cl_addr),
	       .flush_cl_inval(flush_cl_inval),
	       .flush_complete(l1d_flush_complete),
	       .core_mem_req_valid(core_mem_req_valid),
	       .core_mem_req(core_mem_req),
	       .core_mem_req_ack(core_mem_req_ack),

	       .core_store_data_valid(core_store_data_valid),
	       .core_store_data(core_store_data),
	       .core_store_data_ack(core_store_data_ack),
	       
	       .core_mem_rsp_valid(core_mem_rsp_valid),
	       .core_mem_rsp(core_mem_rsp),

	       .mem_req_ack(l1d_mem_req_ack),
	       .mem_req_valid(l1d_mem_req_valid),
	       .mem_req_addr(l1d_mem_req_addr),
	       .mem_req_store_data(l1d_mem_req_store_data),
	       .mem_req_opcode(l1d_mem_req_opcode),
	       .mem_req_cacheable(l1d_mem_req_cacheable),
	       .mem_req_mask(l1d_mem_req_mask),

	       
	       .mem_rsp_valid(l1d_mem_rsp_valid),
	       .mem_rsp_load_data(w_l1_mem_load_data),

	       .cache_accesses(l1d_cache_accesses),
	       .cache_hits(l1d_cache_hits)
	       );

   l1i icache(
	      .clk(clk),
	      .reset(reset),
	      .asid(w_asid),	      
	      .state(l1i_state),
	      .in_kernel_mode(w_in_kernel_mode),
	      .in_supervisor_mode(w_in_supervisor_mode),
	      .in_user_mode(w_in_user_mode),
	      .in_64b_kernel_mode(w_in_64b_kernel_mode),
	      .in_64b_supervisor_mode(w_in_64b_supervisor_mode),
	      .in_64b_user_mode(w_in_64b_user_mode),
	      .flush_req(flush_req_l1i),
	      .flush_complete(l1i_flush_complete),
	      .restart_pc(restart_pc),
	      .restart_src_pc(restart_src_pc),
	      .restart_src_is_indirect(restart_src_is_indirect),
	      .restart_valid(restart_valid),
	      .restart_ack(restart_ack),
	      .retire_reg_ptr(retire_reg_ptr),
	      .retire_reg_data(retire_reg_data),
	      .retire_reg_valid(retire_reg_valid),	      
	      .branch_pc_valid(t_branch_pc_valid),
	      .branch_pc(t_branch_pc),
	      .took_branch(took_branch),
	      .branch_fault(t_branch_fault),
	      .branch_pht_idx(branch_pht_idx),
	      .retire_valid(retire_valid),
	      .retired_call(retired_call),
	      .retired_ret(retired_ret),
	      .insn(insn),
	      .insn_valid(insn_valid),
	      .insn_ack(insn_ack),
	      .insn_two(insn2),
	      .insn_valid_two(insn_valid2),
	      .insn_ack_two(insn_ack2),
	      .mem_req_ack(l1i_mem_req_ack),
	      .mem_req_valid(l1i_mem_req_valid),
	      .mem_req_cacheable(l1i_mem_req_cacheable),
	      .mem_req_mask(l1i_mem_req_mask),
	      .mem_req_addr(l1i_mem_req_addr),
	      .mem_req_opcode(l1i_mem_req_opcode),
	      .mem_rsp_valid(l1i_mem_rsp_valid),
	      .mem_rsp_load_data(w_l1_mem_load_data),
	      .cache_accesses(l1i_cache_accesses),
	      .cache_hits(l1i_cache_hits),
	      .tlb_entry_in_valid(tlb_entry_out_valid),
	      .tlb_entry_in(tlb_entry_out)
	      );

   core cpu (
	     .clk(clk),
	     .reset(reset),
	     .ip6(ip6),
	     .ip5(ip5),
	     .ip4(ip4),
	     .ip3(ip3),
	     .ip2(ip2),
	     .in_kernel_mode(w_in_kernel_mode),
	     .in_supervisor_mode(w_in_supervisor_mode),
	     .in_user_mode(w_in_user_mode),
	     .in_64b_kernel_mode(w_in_64b_kernel_mode),
	     .in_64b_supervisor_mode(w_in_64b_supervisor_mode),
	     .in_64b_user_mode(w_in_64b_user_mode),
	     .putchar_fifo_out(putchar_fifo_out),
	     .putchar_fifo_empty(putchar_fifo_empty),
	     .putchar_fifo_pop(putchar_fifo_pop),
	     .putchar_fifo_wptr(putchar_fifo_wptr),
	     .putchar_fifo_rptr(putchar_fifo_rptr),
	     .single_step(single_step),
	     .bp_enable(bp_enable),
	     .fault_clear(fault_clear),
	     .bp_pc(bp_pc),
	     .bp_wp_addr(bp_wp_addr),
	     .bp_wp_val(bp_wp_val),
	     .step(step),
	     .resume(resume),
	     .memq_empty(memq_empty),
	     .drain_ds_complete(drain_ds_complete),
	     .dead_rob_mask(dead_rob_mask),	     
	     .head_of_rob_ptr_valid(head_of_rob_ptr_valid),
	     .head_of_rob_ptr(head_of_rob_ptr),
	     .head_of_rob_has_delay_slot(head_of_rob_has_delay_slot),
	     .next_head_of_rob_ptr(next_head_of_rob_ptr),
	     .head_of_rob_ds_committable(head_of_rob_ds_committable),
	     .resume_pc(resume_pc),
	     .ready_for_resume(ready_for_resume),  
	     .flush_req_l1d(flush_req_l1d),
	     .flush_req_l1i(flush_req_l1i),	     
	     .flush_cl_req(flush_cl_req),
	     .flush_cl_addr(flush_cl_addr),
	     .flush_cl_inval(flush_cl_inval),
	     .l1d_flush_complete(l1d_flush_complete),
	     .l1i_flush_complete(l1i_flush_complete),
	     .l2_flush_complete(w_l2_flush_complete),
	     .insn(insn),
	     .insn_valid(insn_valid),
	     .insn_ack(insn_ack),
	     .insn_two(insn2),
	     .insn_valid_two(insn_valid2),
	     .insn_ack_two(insn_ack2),
	     .branch_pc(t_branch_pc),
	     .branch_pc_valid(t_branch_pc_valid),
	     .branch_fault(t_branch_fault),
	     .took_branch(took_branch),
	     .branch_pht_idx(branch_pht_idx),
	     .restart_pc(restart_pc),
	     .restart_src_pc(restart_src_pc),
	     .restart_src_is_indirect(restart_src_is_indirect),
	     .restart_valid(restart_valid),
	     .clr_link_reg(clr_link_reg),
	     .restart_ack(restart_ack),

	     .core_mem_req_ack(core_mem_req_ack),
	     .core_mem_req_valid(core_mem_req_valid),
	     .core_mem_req(core_mem_req),
	     
	     .core_store_data_valid(core_store_data_valid),
	     .core_store_data(core_store_data),
	     .core_store_data_ack(core_store_data_ack),
	     
	     .core_mem_rsp_valid(core_mem_rsp_valid),
	     .core_mem_rsp(core_mem_rsp),
	     
	     .retire_reg_ptr(retire_reg_ptr),
	     .retire_reg_data(retire_reg_data),
	     .retire_reg_valid(retire_reg_valid),
	     .retire_reg_two_ptr(retire_reg_two_ptr),
	     .retire_reg_two_data(retire_reg_two_data),
	     .retire_reg_two_valid(retire_reg_two_valid),
	     .retire_valid(retire_valid),
	     .retire_two_valid(retire_two_valid),
	     .retire_delay_slot(t_retire_delay_slot),
	     .retire_pc(retire_pc),
	     .retire_two_pc(retire_two_pc),
	     .retire_op(retire_op),
	     .retire_two_op(retire_two_op),
	     .retired_call(retired_call),
	     .retired_ret(retired_ret),
	     .retired_rob_ptr_valid(retired_rob_ptr_valid),
	     .retired_rob_ptr_two_valid(retired_rob_ptr_two_valid),
	     .retired_rob_ptr(retired_rob_ptr),
	     .retired_rob_ptr_two(retired_rob_ptr_two),
	     .got_break(got_break),
	     .got_ud(got_ud),
	     .got_bad_addr(got_bad_addr),
	     .core_state(core_state),
	     .inflight(inflight),
	     .epc(epc),
	     .status_reg(status_reg),
	     .badvaddr(badvaddr),
	     .cause(cause),
	     .dbg_frozen(dbg_frozen),
	     .dbg_wp_data(dbg_wp_data),
	     .cause_ip(cause_ip),
	     .asid(w_asid),
	     .tlb_entry_out_valid(tlb_entry_out_valid),
	     .tlb_entry_out(tlb_entry_out),	   	     
	     .l1i_flush_done(l1i_flush_done),
	     .l1d_flush_done(l1d_flush_done),
	     .l2_flush_done(l2_flush_done),
	     .took_irq(took_irq),
	     .cp0_count(cp0_count),
	     .dbg_head_pc(dbg_head_pc),
	     .dbg_head_status(dbg_head_status),
	     .dbg_head_fetch_cycle(dbg_head_fetch_cycle),
	     .dbg_head_alloc_cycle(dbg_head_alloc_cycle),
	     .dbg_serialize_cycle(dbg_serialize_cycle),
	     .dbg_cycle(dbg_cycle),
	     .dbg_oldest_first_pending(dbg_oldest_first_pending),
	     .dbg_trace_index(dbg_trace_index),
	     .dbg_trace_data(w_core_trace_data),
	     .dbg_trace_wptr(w_core_trace_wptr)
	     );

   /* ---- L2<->AXI event trace ring (debug the uncached-turnaround deadlock) ----
    * Logs the L2<->AXI boundary on each AXI req-issue (mem_req_valid rising) and
    * each response (mem_rsp_valid): {dbg_cycle, l2_state, req, rsp, opcode, addr}.
    * On a freeze the last entries show the exact req->rsp sequence + the L2 state
    * at each -- e.g. a req issued with no following rsp = stuck AXI turnaround.
    * Muxed into the existing dbg_trace readback on dbg_trace_index[11] (1=L2 ring,
    * 0=core retire ring), so it reuses the driver's trace readback path. */
   logic [31:0] w_core_trace_data;
   logic [8:0]  w_core_trace_wptr;
   /* Gated debug: define ENABLE_L2_EVENT_RING (e.g. sv2v -DENABLE_L2_EVENT_RING, or
    * a Verilator +define) to synthesize the ring; a bare per-file `ifdef strips
    * cleanly through sv2v (unlike the machine.vh-scoped ENABLE_TRACE_BUFFER). When
    * off, dbg_trace_data/wptr pass through the core retire ring unchanged. */
`ifdef ENABLE_L2_EVENT_RING
   (* ram_style = "block" *) logic [3:0][31:0] r_l2trace_ram [255:0];
   logic [7:0] 	     r_l2trace_wptr;
   logic [3:0][31:0] r_l2trace_row;
   logic 	     r_mem_req_valid_d;
   wire 	     w_l2_evt = (mem_req_valid & ~r_mem_req_valid_d) | mem_rsp_valid;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_l2trace_wptr    <= 8'd0;
	     r_mem_req_valid_d <= 1'b0;
	  end
	else
	  begin
	     r_mem_req_valid_d <= mem_req_valid;
	     if(w_l2_evt)
	       begin
		  r_l2trace_ram[r_l2trace_wptr] <=
		    { {28'd0, mem_req_addr[`PA_WIDTH-1:32]},
		      mem_req_addr[31:0],
		      {l2_state, 21'd0, mem_req_valid, mem_rsp_valid, mem_req_opcode},
		      dbg_cycle };
		  r_l2trace_wptr <= r_l2trace_wptr + 8'd1;
	       end
	  end
	r_l2trace_row <= r_l2trace_ram[dbg_trace_index[9:2]];
     end // always_ff
   assign dbg_trace_data = dbg_trace_index[11] ? r_l2trace_row[dbg_trace_index[1:0]] : w_core_trace_data;
   assign dbg_trace_wptr = dbg_trace_index[11] ? {1'b0, r_l2trace_wptr}              : w_core_trace_wptr;
`else
   assign dbg_trace_data = w_core_trace_data;
   assign dbg_trace_wptr = w_core_trace_wptr;
`endif

   

endmodule // core_l1d_l1i



