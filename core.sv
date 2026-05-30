`include "machine.vh"
`include "rob.vh"
`include "uop.vh"

`ifdef VERILATOR
import "DPI-C" function void record_faults(input int n_faults);
import "DPI-C" function void record_branches(input int n_branches);


import "DPI-C" function void record_alloc(input int rob_full,
					  input int alloc_one, 
					  input int alloc_two,
					  input int dq_empty,
					  input int uq_full,
					  input int uq_next_full,
					  input int one_insn_avail,
					  input int two_insn_avail,
					  input int active);

import "DPI-C" function void record_retirement(input longint pc,
					       input longint fetch_cycle,
					       input longint alloc_cycle,
					       input longint complete_cycle,
					       input longint retire_cycle,
					       input int     fault,
					       input int     is_mem,
					       input int     is_fp,
					       input int     missed_l1d);

import "DPI-C" function void record_restart(input int restart_cycles);
import "DPI-C" function void record_ds_restart(input int delay_cycles);
import "DPI-C" function int check_insn_bytes(input longint pc, input int data);


`endif

module core(clk, 
	    reset,
	    in_kernel_mode,
	    in_supervisor_mode,
	    in_user_mode,	    
	    putchar_fifo_out,
	    putchar_fifo_empty,
	    putchar_fifo_pop,
	    putchar_fifo_wptr,
	    putchar_fifo_rptr,
	    extern_irq,
	    head_of_rob_ptr_valid,
	    head_of_rob_ptr,
	    head_of_rob_has_delay_slot,
	    resume,
	    memq_empty,
	    drain_ds_complete,
	    dead_rob_mask,
	    resume_pc,
	    ready_for_resume,
	    flush_req_l1d,
	    flush_req_l1i,
	    flush_cl_req,
	    flush_cl_addr,
	    l1d_flush_complete,
	    l1i_flush_complete,
	    l2_flush_complete,
	    insn, 
	    insn_valid,
	    insn_ack,
	    insn_two, 
	    insn_valid_two,
	    insn_ack_two,	    
	    branch_pc,
	    branch_pc_valid,
	    branch_fault,
	    took_branch,
	    branch_pht_idx,
	    restart_pc,
	    restart_src_pc,
	    restart_src_is_indirect,
	    restart_valid,
	    restart_ack,	    
	    core_mem_req_ack,
	    core_mem_req,
	    core_mem_req_valid,

	    core_store_data_valid,
	    core_store_data,
	    core_store_data_ack,
	    
	    core_mem_rsp,
	    core_mem_rsp_valid,
	    
	    retire_reg_ptr,
	    retire_reg_data,
	    retire_reg_valid,
	    
	    retire_reg_two_ptr,
	    retire_reg_two_data,
	    retire_reg_two_valid,
	    retire_valid,
	    retire_two_valid,
	    retire_delay_slot,
	    retire_pc,
	    retire_two_pc,
	    retire_op,
	    retire_two_op,
	    retired_call,
	    retired_ret,
	    retired_rob_ptr_valid,
	    retired_rob_ptr_two_valid,
	    retired_rob_ptr,
	    retired_rob_ptr_two,
	    
	    got_break,
	    got_ud,
	    got_bad_addr,
	    core_state,
	    inflight,
	    epc,
	    cause,
	    asid,
	    tlb_entry_out,
	    tlb_entry_out_valid,
	    
	    l1i_flush_done,
	    l1d_flush_done,
	    l2_flush_done);
   
   input logic clk;
   input logic reset;
   output logic	in_kernel_mode;
   output logic	in_supervisor_mode;
   output logic	in_user_mode;
    
   output logic [7:0] putchar_fifo_out;
   output logic       putchar_fifo_empty;
   input logic 	      putchar_fifo_pop;
   output logic [3:0] putchar_fifo_wptr;
   output logic [3:0] putchar_fifo_rptr;
   
   input logic extern_irq;
   output logic head_of_rob_ptr_valid;
   output logic [`LG_ROB_ENTRIES-1:0] head_of_rob_ptr;
   output logic			      head_of_rob_has_delay_slot;
   input logic resume;
   input logic memq_empty;
   output logic drain_ds_complete;
   output logic [(1<<`LG_ROB_ENTRIES)-1:0] dead_rob_mask;
   
   input logic [(`M_WIDTH-1):0] resume_pc;
   output logic 		ready_for_resume;
   output logic 		flush_req_l1d;
   output logic 		flush_req_l1i;
   
   output logic flush_cl_req;
   output logic [(`M_WIDTH-1):0] flush_cl_addr;

   input logic			 l1d_flush_complete;
   input logic			 l1i_flush_complete;
   input logic			 l2_flush_complete;
   
	
   input 	insn_fetch_t insn;
   input logic 	insn_valid;
   output logic insn_ack;

   input 	insn_fetch_t insn_two;
   input logic 	insn_valid_two;
   output logic insn_ack_two;
   
   
   output logic [(`M_WIDTH-1):0] restart_pc;
   output logic [(`M_WIDTH-1):0] restart_src_pc;
   output logic 		 restart_src_is_indirect;
   output logic 		 restart_valid;
   input logic 			 restart_ack;
   
   output logic [(`M_WIDTH-1):0] branch_pc;
   output logic 		 branch_pc_valid;
   output logic 		 branch_fault;
   output logic 		 took_branch;
   output logic [`LG_PHT_SZ-1:0] branch_pht_idx;
   
   /* mem port */
   input logic 	 core_mem_req_ack;
   
   output logic  core_mem_req_valid;
   output 	 mem_req_t core_mem_req;

   output logic  core_store_data_valid;
   output 	 mem_data_t core_store_data;
   input logic 	 core_store_data_ack;
  
   input 	 mem_rsp_t core_mem_rsp;
   input logic 	 core_mem_rsp_valid;

   output logic [4:0] 			  retire_reg_ptr;
   output logic [`M_WIDTH-1:0]		  retire_reg_data;
   output logic 			  retire_reg_valid;

   output logic [4:0] 			  retire_reg_two_ptr;
   output logic [`M_WIDTH-1:0]		  retire_reg_two_data;
   output logic 			  retire_reg_two_valid;
   
   output logic 			  retire_valid;
   output logic 			  retire_two_valid;
   
   output logic 			  retire_delay_slot;
   
   output logic [(`M_WIDTH-1):0] 	  retire_pc;
   output logic [(`M_WIDTH-1):0] 	  retire_two_pc;

   output logic [6:0]			  retire_op;
   output logic [6:0]			  retire_two_op;
      
   output logic 			  retired_call;
   output logic 			  retired_ret;

   output logic 			  retired_rob_ptr_valid;

   output logic retired_rob_ptr_two_valid;
   output logic [`LG_ROB_ENTRIES-1:0] retired_rob_ptr;
   output logic [`LG_ROB_ENTRIES-1:0] retired_rob_ptr_two;
   
   
   output logic 			  got_break;
   output logic 			  got_ud;
   output logic 			  got_bad_addr;
   output logic [`LG_ROB_ENTRIES:0] 	  inflight;
   output logic [4:0]			  core_state;
   
   output logic [`M_WIDTH-1:0]		  epc;
   output logic [4:0]			  cause;
   output logic [7:0]			  asid;
   output tlb_data_t		          tlb_entry_out;
   output logic				  tlb_entry_out_valid;
   
   
   output logic				  l1i_flush_done;
   output logic				  l1d_flush_done;
   output logic				  l2_flush_done;
   
   
   
   logic [`M_WIDTH-1:0]			  r_epc, n_epc;
   logic [`M_WIDTH-1:0]			  r_badvaddr, n_badvaddr;   
   wire [`M_WIDTH-1:0]			  w_exec_epc;
   
   wire					  w_sr_bev;
   
   
   logic				  r_exc_in_delay, n_exc_in_delay;
   
   
   localparam N_PRF_ENTRIES = (1<<`LG_PRF_ENTRIES);
   localparam N_ROB_ENTRIES = (1<<`LG_ROB_ENTRIES);
   localparam N_UQ_ENTRIES = (1<<`LG_UQ_ENTRIES);
   localparam N_HILO_ENTRIES = (1<<`LG_HILO_PRF_ENTRIES);
   
   localparam N_DQ_ENTRIES = (1<<`LG_DQ_ENTRIES);
   localparam HI_EBITS = `M_WIDTH-32;

   logic 				  t_push_dq_one, t_push_dq_two;
   
   uop_t r_dq[N_DQ_ENTRIES-1:0];

   
   logic [`LG_DQ_ENTRIES:0] 		  r_dq_head_ptr, n_dq_head_ptr;
   logic [`LG_DQ_ENTRIES:0] 		  r_dq_next_head_ptr, n_dq_next_head_ptr;
   logic [`LG_DQ_ENTRIES:0] 		  r_dq_next_tail_ptr, n_dq_next_tail_ptr;
   
   logic [`LG_DQ_ENTRIES:0] 		  r_dq_cnt, n_dq_cnt;
   
   logic [`LG_DQ_ENTRIES:0] 		  r_dq_tail_ptr, n_dq_tail_ptr;
   logic 				  t_dq_empty, t_dq_full, t_dq_next_empty, t_dq_next_full;
   
   logic 				  r_got_restart_ack, n_got_restart_ack;
   
   rob_entry_t r_rob[N_ROB_ENTRIES-1:0];
   logic [`M_WIDTH-1:0 ] r_addrs[N_ROB_ENTRIES-1:0];
   
   
   logic [N_ROB_ENTRIES-1:0] 		  r_rob_complete;
   logic [N_ROB_ENTRIES-1:0] 		  r_rob_sd_complete;

   logic 				  t_core_store_data_ptr_valid;
   logic [`LG_ROB_ENTRIES-1:0] 		  t_core_store_data_ptr;
 		  
   logic 				  t_rob_head_complete, t_rob_next_head_complete;
   
   
   logic [N_ROB_ENTRIES-1:0] 		  r_rob_inflight, r_rob_dead_insns;
   logic [N_ROB_ENTRIES-1:0] 		  t_clr_mask;
   
   rob_entry_t t_rob_head, t_rob_next_head, t_rob_tail, t_rob_next_tail;

   logic [N_PRF_ENTRIES-1:0] n_prf_free, r_prf_free;
   wire [N_PRF_ENTRIES-1:0]  w_prf_free_even, w_prf_free_odd;
   wire  w_prf_free_even_full, w_prf_free_odd_full;
   logic r_bank_sel;
   
   
   logic [N_PRF_ENTRIES-1:0] n_retire_prf_free, r_retire_prf_free;
      
   logic [N_HILO_ENTRIES-1:0] n_hilo_prf_free,r_hilo_prf_free;
   logic [N_HILO_ENTRIES-1:0] n_retire_hilo_prf_free, r_retire_hilo_prf_free;
   logic [`LG_HILO_PRF_ENTRIES-1:0] n_hilo_prf_entry;
   logic [`LG_HILO_PRF_ENTRIES:0]   t_hilo_prf_idx;
   
   logic [`LG_PRF_ENTRIES-1:0]  n_prf_entry, n_prf_entry2;

   //rob
   logic [`LG_ROB_ENTRIES:0] r_rob_head_ptr, n_rob_head_ptr;
   logic [`LG_ROB_ENTRIES:0] r_rob_next_head_ptr, n_rob_next_head_ptr;
   logic [`LG_ROB_ENTRIES:0] r_rob_tail_ptr, n_rob_tail_ptr;
   logic [`LG_ROB_ENTRIES:0] r_rob_next_tail_ptr, n_rob_next_tail_ptr;
   logic 		     t_rob_empty, t_rob_full, t_rob_next_full, t_rob_next_empty;
   
      
         
   logic [`LG_PRF_ENTRIES-1:0] r_alloc_rat[31:0];
   logic [`LG_PRF_ENTRIES-1:0] n_alloc_rat[31:0];
   logic [`LG_PRF_ENTRIES-1:0] r_retire_rat[31:0];
   logic [`LG_PRF_ENTRIES-1:0] n_retire_rat[31:0];
   
   logic [`LG_HILO_PRF_ENTRIES-1:0] r_hilo_alloc_rat;
   logic [`LG_HILO_PRF_ENTRIES-1:0] n_hilo_alloc_rat;
   logic [`LG_HILO_PRF_ENTRIES-1:0] r_hilo_retire_rat;
   logic [`LG_HILO_PRF_ENTRIES-1:0] n_hilo_retire_rat;

   logic [N_ROB_ENTRIES-1:0] 	    uq_wait, mq_wait;
   

   
   
   logic 		     t_alloc, t_alloc_two, t_retire, t_retire_two,
			     t_rat_copy, t_clr_rob;

   logic 		     t_possible_to_alloc;
   
   
   logic 		     t_fold_uop, t_fold_uop2;
   
   logic 		     n_in_delay_slot, r_in_delay_slot;
   
   logic 		     t_clr_dq;
   logic 		     t_enough_iprfs, t_enough_hlprfs;
   logic 		     t_enough_next_iprfs, t_enough_next_hlprfs;
   

   
   
   logic 		     t_bump_rob_head;
   
   logic [(`M_WIDTH-1):0]    n_restart_pc, r_restart_pc;
   logic [(`M_WIDTH-1):0]    n_restart_src_pc, r_restart_src_pc;
   logic 		     n_restart_src_is_indirect, r_restart_src_is_indirect;
   
   logic [(`M_WIDTH-1):0]    n_branch_pc, r_branch_pc;
   logic 		     n_took_branch, r_took_branch;
   logic 		     n_branch_valid, r_branch_valid;
   logic 		     n_branch_fault,r_branch_fault;
   logic [`LG_PHT_SZ-1:0]    n_branch_pht_idx, r_branch_pht_idx;
         
   logic 		     n_restart_valid,r_restart_valid;
   logic 		     n_has_delay_slot, r_has_delay_slot;
   logic 		     n_has_nullifying_delay_slot,r_has_nullifying_delay_slot;
   logic 		     n_take_br, r_take_br;

   logic 		     n_got_break, r_got_break;
   logic 		     n_pending_break, r_pending_break;
   logic 		     n_pending_ud, r_pending_ud;
   logic 		     n_pending_bad_addr, r_pending_bad_addr;
   logic 		     n_got_ud, r_got_ud;
   logic 		     n_got_bad_addr, r_got_bad_addr;
   

   logic 		     n_l1i_flush_complete, r_l1i_flush_complete;
   logic 		     n_l1d_flush_complete, r_l1d_flush_complete;
   logic 		     n_l2_flush_complete, r_l2_flush_complete;
   
   logic [31:0]    t_cpr0_status_reg;
   
   logic [31:0] 	     r_arch_a0;

   logic [4:0] 		     n_cause, r_cause;
   logic		     r_tlb_refill, n_tlb_refill;
   logic		     n_save_to_tlb_regs, r_save_to_tlb_regs;   
   logic		     n_has_badvaddr,r_has_badvaddr;
   
   
   
   complete_t t_complete_bundle_1;
   logic 		     t_complete_valid_1;
   
   logic 		     t_any_complete;
   

   logic 		     t_free_reg;
   logic [`LG_PRF_ENTRIES-1:0] t_free_reg_ptr;
   
   logic 		       t_free_reg_two;
   logic [`LG_PRF_ENTRIES-1:0] t_free_reg_two_ptr;
   
   logic 			   t_free_hilo;
   logic [`LG_HILO_PRF_ENTRIES-1:0] t_free_hilo_ptr;
   

   logic [`LG_HILO_PRF_ENTRIES:0]   t_hilo_ffs;

   
   logic [`LG_PRF_ENTRIES:0] 	    t_gpr_ffs, t_gpr_ffs2;
   logic 			    t_gpr_ffs_full, t_gpr_ffs2_full;
   wire [`LG_PRF_ENTRIES:0] 	    w_gpr_ffs_even, w_gpr_ffs_odd;
   
   logic 		     t_uq_full, t_uq_next_full;
   
   logic 		     t_uq_read;
   logic 		     n_ready_for_resume, r_ready_for_resume;
   
   
   mem_req_t t_mem_req;
   logic 		     t_mem_req_valid;

   logic 		     n_machine_clr, r_machine_clr;
   logic 		     n_flush_req_l1d, r_flush_req_l1d;
   logic 		     n_flush_req_l1i, r_flush_req_l1i;
   
   logic 		     n_flush_cl_req, r_flush_cl_req;
   logic [(`M_WIDTH-1):0]    n_flush_cl_addr, r_flush_cl_addr;
   logic 		     r_ds_done, n_ds_done;
   
   logic 		     t_can_retire_rob_head;
   logic 		     t_faulted_head_and_serializing_delay;
   logic 		     t_arch_fault;
   
   typedef enum logic [4:0] {
			     FLUSH_FOR_HALT = 'd0, //0			     
			     HALT = 'd1, //1
			     ACTIVE = 'd2 , //2
			     DRAIN = 'd3, //3
			     RAT = 'd4, //4
			     DELAY_SLOT = 'd5, //5
			     ALLOC_FOR_SERIALIZE = 'd6, //6
			     HALT_WAIT_FOR_RESTART = 'd7, //11
			     WAIT_FOR_SERIALIZE_AND_RESTART = 'd8, //12
			     ARCH_FAULT = 'd9,
			     WRITE_EPC = 'd10,
			     EXCEPTION_DRAIN = 'd11,
			     SERIALIZE_IN_FAULTED_DELAY_SLOT = 'd12,
			     WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT = 'd13,
			     DEAD = 'd15
			     } state_t;
   
   state_t r_state, n_state;
   logic 	r_pending_fault, n_pending_fault;
   logic [31:0] r_restart_cycles, n_restart_cycles;
   logic t_divide_ready;
   
   
   always_comb
     begin
	core_mem_req_valid = t_mem_req_valid;
	core_mem_req = t_mem_req;
	core_state = r_state;
     end // always_comb
   

   assign ready_for_resume = r_ready_for_resume;
   assign head_of_rob_ptr_valid = (r_state == ACTIVE) | ( (r_state==DRAIN) && !r_ds_done);
   assign head_of_rob_ptr = r_rob_head_ptr[`LG_ROB_ENTRIES-1:0];
   assign head_of_rob_has_delay_slot = t_rob_head.has_delay_slot | t_rob_head.has_nullifying_delay_slot;
				      
   assign flush_req_l1d = r_flush_req_l1d;
   assign flush_req_l1i = r_flush_req_l1i;
   assign flush_cl_req = r_flush_cl_req;
   assign flush_cl_addr = r_flush_cl_addr;

   
   assign got_break = r_got_break;
   assign got_ud = r_got_ud;
   assign got_bad_addr = r_got_bad_addr;
   assign epc = r_epc;
   assign cause = r_cause;
   assign l1i_flush_done = n_l1i_flush_complete;
   assign l1d_flush_done = n_l1d_flush_complete;
   assign l2_flush_done = n_l2_flush_complete;
   
   popcount #(`LG_ROB_ENTRIES) inflight0 (.in(r_rob_inflight), 
					  .out(inflight));

   
   uop_t t_uop, t_dec_uop, t_alloc_uop;
   uop_t t_uop2, t_dec_uop2, t_alloc_uop2;
      
   assign insn_ack = !t_dq_full && insn_valid && (r_state == ACTIVE);
   assign insn_ack_two = !t_dq_full && 
			 insn_valid && 
			 !t_dq_next_full && 
			 insn_valid_two && (r_state == ACTIVE);
   
   assign restart_pc = r_restart_pc;
   assign restart_src_pc = r_restart_src_pc;
   assign restart_src_is_indirect = r_restart_src_is_indirect;

   assign dead_rob_mask = r_rob_dead_insns;   
   assign restart_valid = r_restart_valid;

   
   assign branch_pc = r_branch_pc;
   assign branch_pc_valid = r_branch_valid;
   assign branch_fault = r_branch_fault;
   assign branch_pht_idx = r_branch_pht_idx;
   
   assign took_branch = r_took_branch;
   
   
   logic [63:0] r_cycle;
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : r_cycle + 'd1;

     end


`ifdef VERILATOR
   logic [31:0] r_clear_cnt;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_clear_cnt <= 'd0;
	  end
	else if(n_ds_done)
	  begin
	     r_clear_cnt <=  r_clear_cnt + 'd1;
	  end
     end
`endif


   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_flush_req_l1i <= 1'b0;
	     r_flush_req_l1d <= 1'b0;
	     r_flush_cl_req <= 1'b0;
	     r_flush_cl_addr <= 'd0;
	     r_restart_pc <= 'd0;
	     r_restart_src_pc <= 'd0;
	     r_restart_src_is_indirect <= 1'b0;
	     r_branch_pc <= 'd0;
	     r_took_branch <= 1'b0;
	     r_branch_valid <= 1'b0;
	     r_branch_fault <= 1'b0;
	     r_branch_pht_idx <= 'd0;
	     r_in_delay_slot <= 1'b0;
	     r_restart_valid <= 1'b0;
	     r_has_delay_slot <= 1'b0;
	     r_has_nullifying_delay_slot <= 1'b0;
	     r_take_br <= 1'b0;
	     r_got_break <= 1'b0;
	     r_pending_break <= 1'b0;
	     r_pending_ud <= 1'b0;
	     r_pending_bad_addr <= 1'b0;	     	     
	     r_got_ud <= 1'b0;
	     r_got_bad_addr <= 1'b0;
	     r_ready_for_resume <= 1'b0;
	     r_l1i_flush_complete <= 1'b0;
	     r_l1d_flush_complete <= 1'b0;
	     r_l2_flush_complete <= 1'b0;
	     r_ds_done <= 1'b0;
	     drain_ds_complete <= 1'b0;
	     r_epc <= 'd0;
	     r_badvaddr <= 'd0;
	     r_exc_in_delay <= 1'b0;	     
	  end
	else
	  begin
	     r_flush_req_l1d <= n_flush_req_l1d;
	     r_flush_req_l1i <= n_flush_req_l1i;
	     r_flush_cl_req <= n_flush_cl_req;
	     r_flush_cl_addr <= n_flush_cl_addr;
	     r_restart_pc <= n_restart_pc;
	     r_restart_src_pc <= n_restart_src_pc;
	     r_restart_src_is_indirect <= n_restart_src_is_indirect;
	     r_branch_pc <= n_branch_pc;
	     r_took_branch <= n_took_branch;
	     r_branch_valid <= n_branch_valid;
	     r_branch_fault <= n_branch_fault;
	     r_branch_pht_idx <= n_branch_pht_idx;
	     r_in_delay_slot <= n_in_delay_slot;
	     r_restart_valid <= n_restart_valid;
	     r_has_delay_slot <= n_has_delay_slot;
	     r_has_nullifying_delay_slot <= n_has_nullifying_delay_slot;
	     r_take_br <= n_take_br;
	     r_got_break <= n_got_break;
	     r_pending_break <= n_pending_break;
	     r_pending_ud <= n_pending_ud;
	     r_pending_bad_addr <= n_pending_bad_addr;	     	     
	     r_got_ud <= n_got_ud;
	     r_got_bad_addr <= n_got_bad_addr;
	     r_ready_for_resume <= n_ready_for_resume;
	     r_l1i_flush_complete <= n_l1i_flush_complete;
	     r_l1d_flush_complete <= n_l1d_flush_complete;
	     r_l2_flush_complete <= n_l2_flush_complete;
	     r_ds_done <= n_ds_done;
	     drain_ds_complete <= r_ds_done;
	     r_epc <= n_epc;
	     r_badvaddr <= n_badvaddr;	     
	     r_exc_in_delay <= n_exc_in_delay;
	  end
     end // always_ff@ (posedge clk)

   
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= FLUSH_FOR_HALT;
	     r_restart_cycles <= 'd0;
	     r_machine_clr <= 1'b0;
	     r_got_restart_ack <= 1'b0;
	     r_cause <= 5'd0;
	     r_tlb_refill <= 1'b0;
	     r_save_to_tlb_regs <= 1'b0;
	     r_has_badvaddr <= 1'b0;
	     r_pending_fault <= 1'b0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_restart_cycles <= n_restart_cycles;
	     r_machine_clr <= n_machine_clr;
	     r_got_restart_ack <= n_got_restart_ack;
	     r_cause <= n_cause;
	     r_tlb_refill <= n_tlb_refill;
	     r_save_to_tlb_regs <= n_save_to_tlb_regs;
	     r_has_badvaddr <= n_has_badvaddr;
	     r_pending_fault <= n_pending_fault;
	  end
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_arch_a0 <= 'd0;
	  end
	else if(t_rob_head.valid_dst && t_retire && t_rob_head.ldst == 'd4)
	  begin
	     r_arch_a0 <= t_rob_head.data[31:0];
	  end
     end
   
   always_ff@(posedge clk)
     begin
   	if(reset)
   	  begin
   	     retire_reg_ptr <= 'd0;
   	     retire_reg_data <= 'd0;
   	     retire_reg_valid <= 1'b0;
   	     retire_reg_two_ptr <= 'd0;
   	     retire_reg_two_data <= 'd0;
   	     retire_reg_two_valid <= 1'b0;
   	     retire_valid <= 1'b0;
	     retire_two_valid <= 1'b0;
	     
   	     retire_pc <= 'd0;
	     retire_two_pc <= 'd0;
	     retire_op <= 'd0;
	     retire_two_op <= 'd0;
	     
	     retire_delay_slot <= 1'b0;
	     retired_call <= 1'b0;
	     retired_ret <= 1'b0;
	     retired_rob_ptr_valid <= 1'b0;
	     
	     retired_rob_ptr_two_valid <= 1'b0;
	     retired_rob_ptr <= 'd0;
	     retired_rob_ptr_two <= 'd0;
   	  end
   	else
   	  begin
   	     retire_reg_ptr <= t_rob_head.ldst;
   	     retire_reg_data <= t_rob_head.data;
   	     retire_reg_valid <= t_rob_head.valid_dst && t_retire;
   	     retire_reg_two_ptr <= t_rob_next_head.ldst;
   	     retire_reg_two_data <= t_rob_next_head.data;
   	     retire_reg_two_valid <= t_rob_next_head.valid_dst && t_retire_two;
	     
   	     retire_valid <= t_retire;
	     retire_two_valid <= t_retire_two;
   	     retire_pc <= t_rob_head.pc;
	     retire_two_pc <= t_rob_next_head.pc;
	     retire_delay_slot <= t_rob_head.in_delay_slot && t_retire;
	     retired_ret <= t_rob_head.is_ret && t_retire;
	     retired_call <= t_rob_head.is_call && t_retire;

	     retire_op <= t_rob_head.opcode;
	     retire_two_op <= t_rob_next_head.opcode;
	     
	     retired_rob_ptr_valid <= t_retire;
	     
	     retired_rob_ptr_two_valid <= t_retire_two;
	     retired_rob_ptr <= r_rob_head_ptr[`LG_ROB_ENTRIES-1:0];
	     retired_rob_ptr_two <= r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0];
   	  end
     end
`ifdef ENABLE_CYCLE_ACCOUNTING
   always_ff@(negedge clk)
     begin
	localparam ZP = (64-`M_WIDTH);	
	record_alloc(t_rob_full ? 32'd1 : 32'd0,
		     t_alloc ? 32'd1 : 32'd0,
		     t_alloc_two ? 32'd1 : 32'd0,
		     t_dq_empty ? 32'd1 : 32'd0,
		     
		     t_uq_full ? 32'd1 : 32'd0,
		     t_uq_next_full ? 32'd1 : 32'd0,
		     
		     t_dq_empty ? 32'd0 : 32'd1,
		     !t_dq_next_empty && !t_dq_empty ? 32'd1 : 32'd0,
		     t_possible_to_alloc ? 32'd1 : 32'd0);
			    
   	if(t_retire)
   	  begin
	     record_retirement({{ZP{1'b0}},t_rob_head.pc}, 
   			       t_rob_head.fetch_cycle,
   			       t_rob_head.alloc_cycle,
   			       t_rob_head.complete_cycle,
   			       r_cycle,
			       t_rob_head.faulted ? 32'd1 : 32'd0,
			       32'd0,
			       32'd0,
			       32'd0);
   	  end
   	if(t_retire_two)
   	  begin
	     record_retirement({{ZP{1'b0}},t_rob_next_head.pc},
   			       t_rob_next_head.fetch_cycle,
   			       t_rob_next_head.alloc_cycle,
   			       t_rob_next_head.complete_cycle,
   			       r_cycle,
			       t_rob_next_head.faulted ? 32'd1 : 32'd0,
			       32'd0,
			       32'd0,
			       32'd0);	     
   	  end // if (t_retire_two)
	if(r_state == RAT && n_state == ACTIVE)
	  begin
	     record_restart(r_restart_cycles);
	  end
	if(r_state == DRAIN && n_state == RAT)
	  begin
	     record_ds_restart(r_restart_cycles);
	  end
	    
     end // always_ff@ (negedge clk)
`endif
   
   
//`define DEBUG
`ifdef VERILATOR
   logic [31:0] t_faults, t_branches;
   always_comb
     begin
	t_faults = 'd0;
	t_branches = 'd0;
	for(logic [`LG_ROB_ENTRIES:0] i = r_rob_head_ptr; i != (r_rob_tail_ptr); i=i+1)
	  begin
	     if(r_rob_complete[i[`LG_ROB_ENTRIES-1:0]]  && r_rob[i[`LG_ROB_ENTRIES-1:0]].faulted)
	       begin
		  t_faults = t_faults + 'd1;
	       end
	     if(r_rob[i[`LG_ROB_ENTRIES-1:0]].is_br && r_rob_complete[i[`LG_ROB_ENTRIES-1:0]])
	       begin
		  t_branches = t_branches + 'd1;
	       end
	  end
     end // always_comb
   
   always_ff@(negedge clk)
     begin
	record_faults(t_faults);
	record_branches(t_branches);
     end
`endif
   
//`define DUMP_ROB
`ifdef DUMP_ROB
   always_ff@(negedge clk)
     begin
 	if(1)
	  begin
	     $display("cycle %d : state = %d, alu complete %b, mem complete %b,head_ptr %d, inflight %d, complete %b,  can_retire_rob_head %b, t_faulted_head_and_serializing_delay %b, head pc %x, empty %b, full %b", 
		      r_cycle,
		      r_state,
		      t_complete_valid_1,
		      core_mem_rsp_valid,
		      r_rob_head_ptr,
		      r_rob_inflight,
		      t_rob_head_complete && !t_rob_empty, 
		      t_can_retire_rob_head,
		      t_faulted_head_and_serializing_delay,
		      t_rob_head.pc,
		      t_rob_empty, 
		      t_rob_full);
	     
	     for(logic [`LG_ROB_ENTRIES:0] i = r_rob_head_ptr; i != (r_rob_tail_ptr); i=i+1)
	       begin
		  $display("\trob entry %d, pc %x, complete %b, is br %b, faulted %b",
			   i[`LG_ROB_ENTRIES-1:0], 
			   r_rob[i[`LG_ROB_ENTRIES-1:0]].pc, 
			   r_rob_complete[i[`LG_ROB_ENTRIES-1:0]],
			   r_rob[i[`LG_ROB_ENTRIES-1:0]].is_br,
			   r_rob[i[`LG_ROB_ENTRIES-1:0]].faulted,
			   );
	       end
	  end
     end // always_ff@ (negedge clk)
`endif
   logic t_wr_epc, t_wr_cause, t_wr_badvaddr;
   
   logic t_restart_complete;
   logic t_clr_extern_irq;
   logic r_extern_irq;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_extern_irq <= 1'b0;
	  end
	else
	  begin
	     if(t_clr_extern_irq)
	       begin
		  r_extern_irq <= 1'b0;
	       end 
	     else if(extern_irq)
	       begin
		  r_extern_irq <= 1'b1;
	       end
	  end // else: !if(reset)
     end // always_ff@ (posedge clk)
   
   always_comb
     begin
	t_wr_epc = 1'b0;
	t_wr_cause = 1'b0;
	t_wr_badvaddr = 1'b0;
	n_has_badvaddr = r_has_badvaddr;
	
	t_clr_extern_irq = 1'b0;
	t_restart_complete = 1'b0;
	
	n_cause = r_cause;
	n_tlb_refill = r_tlb_refill;
       
	n_machine_clr = r_machine_clr;
	t_alloc = 1'b0;
	t_alloc_two = 1'b0;
	t_possible_to_alloc = 1'b0;
	n_save_to_tlb_regs = r_save_to_tlb_regs;
	
	n_in_delay_slot = r_in_delay_slot;
	t_retire = 1'b0;
	t_retire_two = 1'b0;
	t_rat_copy = 1'b0;
	t_clr_rob = 1'b0;
	t_clr_dq = 1'b0;
	n_state = r_state;
	n_restart_cycles = r_restart_cycles + 'd1;
	n_restart_pc = r_restart_pc;
	n_restart_src_pc = r_restart_src_pc;
	n_restart_src_is_indirect = r_restart_src_is_indirect;
	n_restart_valid = 1'b0;
	n_has_delay_slot = r_has_delay_slot;
	n_has_nullifying_delay_slot = r_has_nullifying_delay_slot;
	n_take_br = r_take_br;	
	t_bump_rob_head = 1'b0;

	n_pending_fault = r_pending_fault;
	n_epc = r_epc;
	n_badvaddr = r_badvaddr;
	n_exc_in_delay = r_exc_in_delay;
	
	
	t_enough_iprfs = !((t_uop.dst_valid) && t_gpr_ffs_full);
	t_enough_hlprfs = !((t_uop.hilo_dst_valid) && (r_hilo_prf_free == 'd0));

	
	t_enough_next_iprfs = !((t_uop2.dst_valid) && t_gpr_ffs2_full);
	t_enough_next_hlprfs = !((t_uop2.hilo_dst_valid) /*&& (r_hilo_prf_free == 'd0)*/);



	
	t_fold_uop = (t_uop.op == NOP | 
		      t_uop.op == J  |
		      t_uop.op == IRQ |
		      t_uop.op == II);

	t_fold_uop2 = (t_uop2.op == NOP | 
		       t_uop2.op == J  |
		       t_uop2.op == IRQ |
		       t_uop2.op == II);
	
	n_ds_done = r_ds_done;
	n_flush_req_l1d = 1'b0;
	n_flush_req_l1i = 1'b0;
	n_flush_cl_req = 1'b0;
	n_flush_cl_addr = r_flush_cl_addr;
	n_got_break = r_got_break;
	n_pending_break = r_pending_break;
	n_pending_ud = r_pending_ud;
	n_pending_bad_addr = r_pending_bad_addr;
	n_got_ud = r_got_ud;
	n_got_bad_addr = r_got_bad_addr;
	n_got_restart_ack = r_got_restart_ack;
	n_ready_for_resume = 1'b0;
	n_l1i_flush_complete = r_l1i_flush_complete || l1i_flush_complete;
	n_l1d_flush_complete = r_l1d_flush_complete || l1d_flush_complete;
	n_l2_flush_complete = r_l2_flush_complete || l2_flush_complete;
	
	
	if(r_state == ACTIVE)
	  begin
	     n_got_restart_ack = 1'b0;
	  end
	else if(!r_got_restart_ack)
	  begin
	     n_got_restart_ack = restart_ack;
	  end	
	
	t_can_retire_rob_head = 1'b0;
	t_faulted_head_and_serializing_delay = 1'b0;
	
	if(t_rob_head_complete && !t_rob_empty)
	  begin
	     t_can_retire_rob_head = (t_rob_head.has_delay_slot || t_rob_head.has_nullifying_delay_slot) && t_rob_head.faulted ? !t_rob_next_empty : 1'b1;
	     t_faulted_head_and_serializing_delay = (t_rob_head.has_delay_slot || t_rob_head.has_nullifying_delay_slot) && t_rob_head.faulted && !t_dq_empty 
						    && t_rob_next_empty && t_uop.serializing_op;
	  end

	if(t_complete_valid_1)
	  begin
	     n_pending_fault = r_pending_fault | t_complete_bundle_1.faulted;
	  end
	
	t_arch_fault = t_rob_head.faulted & 
		       (t_rob_head.is_break | t_rob_head.is_syscall | t_rob_head.is_ii | t_rob_head.is_bad_addr | 
			t_rob_head.overflow | t_rob_head.trap | t_rob_head.is_irq | t_rob_head.tlb_refill |
			t_rob_head.tlb_invalid | t_rob_head.tlb_modified);
	
	
	unique case (r_state)
	  ACTIVE:
	    begin
	       if(t_faulted_head_and_serializing_delay)
		 begin
		    n_state = SERIALIZE_IN_FAULTED_DELAY_SLOT;
		 end
	       else if(t_can_retire_rob_head)
		 begin
		    //if(t_rob_head.pc == 32'hbfc00094)
		    //begin
		    //$display("t_rob_head.faulted = %b", t_rob_head.faulted);
		    //$stop();
		    //end
		    if(t_rob_head.faulted)
		      begin
			 if(t_arch_fault)
			   begin
			      n_state = ARCH_FAULT;
			   end
			 else
			   begin
			      n_ds_done = !t_rob_head.has_delay_slot;
			      n_state = DRAIN;
			      n_restart_cycles = 'd1;
			      n_restart_valid = 1'b1;
			      t_bump_rob_head = 1'b1;			      
			   end // else: !if(t_rob_head.is_ii)
			 n_machine_clr = 1'b1;
			 n_restart_pc = t_rob_head.target_pc;
			 n_restart_src_pc = t_rob_head.pc;
			 n_restart_src_is_indirect = t_rob_head.is_indirect && !t_rob_head.is_ret;
			 
			 n_has_delay_slot = t_rob_head.has_delay_slot;
			 n_has_nullifying_delay_slot = t_rob_head.has_nullifying_delay_slot;
			 n_take_br = t_rob_head.take_br;
		      end // if (t_rob_head.faulted)
		    else if(!t_dq_empty)
		      begin
			// if(t_faulted_head_and_serializing_delay)
			 //begin
			 //$display("situation where we need to allocate after fault due to serializing insn");
			 //end
			 
			 if(t_uop.serializing_op)
			   begin
			      if(/*r_inflight*/t_rob_empty)
				begin
				   n_state = ALLOC_FOR_SERIALIZE;
				end
			   end
			 else
			   begin
			      t_possible_to_alloc = !t_rob_full
						    && !t_uq_full
						    && !t_dq_empty;

			      t_alloc = !t_rob_full
					&& !t_uq_full
					&& !t_dq_empty					
					&& t_enough_iprfs
					&& t_enough_hlprfs
					&& (r_pending_fault ? r_in_delay_slot : 1'b1);

			      
			      t_alloc_two = t_alloc
					    && !t_uop.is_br
					    && !t_uop2.serializing_op
					    && !t_dq_next_empty 
					    && !t_rob_next_full
					    && !t_uq_next_full
					    && t_enough_next_iprfs
					    && t_enough_next_hlprfs;

			      //&& (t_uop2.op == NOP || t_uop2.op == J);
			   end // else: !if(t_uop.serializing_op && !t_dq_empty)
		      end // if (!t_dq_empty)
		    t_retire = t_rob_head_complete & !t_arch_fault;
		    t_retire_two = !t_rob_next_empty
		    		   & !t_rob_head.faulted
		    		   & !t_rob_next_head.faulted 				    
		    		   & t_rob_head_complete
		    		   & t_rob_next_head_complete				    
				   & !t_rob_head.is_br
				   & !t_rob_next_head.is_ret
				   & !t_rob_next_head.is_call
		    		   & !t_rob_next_head.valid_hilo_dst;
		 end // if (t_can_retire_rob_head)
	       else if(!t_dq_empty)
		 begin
		    if(t_uop.serializing_op && t_rob_empty)
		      begin
			 n_state =  ALLOC_FOR_SERIALIZE;
		      end // if (t_uop.serializing_op)
		    else if(!t_uop.serializing_op)
		      begin
			 t_possible_to_alloc = !t_rob_full
					       && !t_uq_full
					       && !t_dq_empty;
			 
			 t_alloc = !t_rob_full
				   && !t_uop.serializing_op
				   && !t_uq_full
				   && !t_dq_empty
				   && t_enough_iprfs
				   && t_enough_hlprfs
				   && (r_pending_fault ? r_in_delay_slot : 1'b1);

			 //$display("r_cycle = %d, can alloc %b, r_pending %b, delay %b", r_cycle, t_alloc, r_pending_fault, r_in_delay_slot);
			 
			 t_alloc_two = t_alloc
				       && !t_uop.is_br
				       && !t_uop2.serializing_op
				       && !t_dq_next_empty 
				       && !t_rob_next_full
				       && !t_uq_next_full
				       && t_enough_next_iprfs
				       && t_enough_next_hlprfs;

		      end
		 end
	    end // case: ACTIVE
	  DRAIN:	    
	    begin
	       //$display("cycle %d : r_rob_inflight = %b, r_ds_done = %b, t_rob_head_complete = %b, has delay slot", 
	       //r_cycle, r_rob_inflight, r_ds_done, t_rob_head_complete, r_has_delay_slot);

	       
	       if(r_has_nullifying_delay_slot && t_rob_head_complete && !r_ds_done)
		 begin
		    if(r_take_br)
		      begin
			 if(t_arch_fault)
			   begin
			      n_state = ARCH_FAULT;
			   end
			 else
			   begin
			      t_retire = 1'b1;
			   end
		      end
		    else
		      begin
			 t_retire = 1'b0;
		      end
		    n_ds_done = 1'b1;
		 end
	       else if(r_has_delay_slot && t_rob_head_complete && !r_ds_done)
		 begin
		    n_ds_done = 1'b1;
		    if(t_arch_fault)
		      begin
			 n_state = ARCH_FAULT;
		      end
		    else
		      begin
			 t_retire = 1'b1;			 
		      end
		 end // if (r_has_delay_slot && t_rob_head_complete && !r_ds_done)
	       if(r_rob_inflight == 'd0 && r_ds_done && memq_empty && t_divide_ready)
		 begin
		    //$display("%d : wait for drain and memq_empty  took  %d cycles",r_cycle, r_restart_cycles);		    
		    n_state = RAT;
`ifdef REPORT_FAULTS		    
		    $display(">>> restarting after fault at cycle %d", r_cycle);
`endif
		 end // if (r_rob_inflight == 'd0 && r_ds_done && memq_empty)


	    end // case: DRAIN
	  EXCEPTION_DRAIN:
	    begin
	       //$display("memq_empty = %b, r_rob_inflight = %d",
	       //memq_empty, r_rob_inflight);
	       if(r_rob_inflight == 'd0 && memq_empty && t_divide_ready)
		 begin
		    n_state = RAT;
		 end
	    end
	  RAT:
	    begin
	       t_rat_copy = 1'b1;
	       t_clr_rob = 1'b1;
	       t_clr_dq = 1'b1;
	       n_machine_clr = 1'b0;
	       
	       if(n_got_restart_ack)
		 begin
		    n_state = ACTIVE;
		    n_pending_fault = 1'b0;
		    n_ds_done = 1'b0;
		    t_restart_complete = 1'b1;
		 end
	    end
	  ALLOC_FOR_SERIALIZE:
	    begin
	       t_alloc = !t_rob_full && !t_uq_full 
			 && (r_prf_free != 'd0) 
			   && !t_dq_empty;
	       n_state = t_alloc ? WAIT_FOR_SERIALIZE_AND_RESTART : ALLOC_FOR_SERIALIZE;
	    end
	  WAIT_FOR_SERIALIZE_AND_RESTART:
	    begin
	       if(t_rob_head_complete)
		 begin
		    t_clr_dq = 1'b1;
		    n_restart_pc = t_rob_head.target_pc;
		    n_restart_src_pc = t_rob_head.pc;
		    n_restart_src_is_indirect = 1'b0;
		    n_restart_valid = 1'b1;
		    n_pending_fault = 1'b0;		    
		    if(n_got_restart_ack)
		      begin
			 //$display("RESTART PIPELINE AT %d, pc %x", 
			 //r_cycle, n_restart_pc);
			 n_state = ACTIVE;			 
		      end
		 end
	    end
	  FLUSH_FOR_HALT:
	    begin
	       //$display("%d : %b %b %b", r_cycle, n_l1i_flush_complete, n_l1d_flush_complete, n_l2_flush_complete);
	       if(n_l1i_flush_complete && n_l1d_flush_complete && n_l2_flush_complete)
		 begin
		    n_state = HALT;
		    n_got_break = r_pending_break;
		    n_got_bad_addr = r_pending_bad_addr;
		    n_got_ud = r_pending_ud;
		    n_pending_break = 1'b0;
		    n_pending_ud = 1'b0;
		    n_pending_bad_addr = 1'b0;
		    n_ready_for_resume = 1'b1;		    		    
		    n_l1i_flush_complete = 1'b0;
		    n_l1d_flush_complete = 1'b0;
		    n_l2_flush_complete = 1'b0;
		 end	       
	    end
	  HALT:
	    begin
	       if(resume)
		 begin
		    n_restart_pc = resume_pc;
		    n_restart_src_pc = t_rob_head.pc;
		    n_restart_src_is_indirect = 1'b0;
		    n_restart_valid = 1'b1;
		    n_state = HALT_WAIT_FOR_RESTART;
		    n_got_break = 1'b0;
		    n_got_ud = 1'b0;
		    t_clr_dq = 1'b1;			    
		 end
	       else
		 begin
		    n_ready_for_resume = 1'b1;		    
		 end
	    end // case: HALT
	  HALT_WAIT_FOR_RESTART:
	    begin
	       n_pending_fault = 1'b0;
	       if(n_got_restart_ack)
		 begin
		    n_state = ACTIVE;
		 end
	    end
	  ARCH_FAULT:
	    begin
	       n_tlb_refill = 1'b0;
	       n_has_badvaddr = 1'b0;
	       n_save_to_tlb_regs = 1'b0;
	       n_badvaddr = r_addrs[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]];
	       if(t_rob_head.is_break)
		 begin
		    n_pending_break = 1'b1;
		    n_cause = 5'd9;
		 end
	       else if(t_rob_head.is_syscall)
		 begin
		    n_cause = 5'd8;		    
		 end
	       else if(t_rob_head.is_ii)
		 begin
		    n_pending_ud = 1'b1;
		    //$display("bad pc %x", t_rob_head.in_delay_slot ? (t_rob_head.pc - 'd4) : t_rob_head.pc);	     
		    n_cause = 5'd10;
		 end
	       else if(t_rob_head.is_bad_addr)
		 begin
		    n_pending_bad_addr = 1'b1;
		    n_has_badvaddr = 1'b1;
		    n_cause = t_rob_head.is_store ? 5'd5 : 5'd4;
		 end
	       else if(t_rob_head.is_irq)
		 begin
		    n_cause = 5'd0;
		 end
	       else if(t_rob_head.overflow)
		 begin
		    n_cause = 5'd12;
		 end
	       else if(t_rob_head.trap)
		 begin
		    //$display("taking trap exception");
		    n_cause = 5'd13;
		 end
	       else if(t_rob_head.tlb_refill | t_rob_head.tlb_invalid)
		 begin
		    n_tlb_refill = (t_rob_head.tlb_refill);
		    n_save_to_tlb_regs = 1'b1;
		    n_cause = t_rob_head.is_store ? 5'd3 : 5'd2;
		    n_pending_bad_addr = 1'b1;
		    n_has_badvaddr = 1'b1;
		 end
	       else if(t_rob_head.tlb_modified)
		 begin
		    n_cause = 5'd1;
		    n_save_to_tlb_regs = 1'b1;		    
		    n_pending_bad_addr = 1'b1;
		    n_has_badvaddr = 1'b1;		    
		 end
	       t_bump_rob_head = 1'b1;	       
	       n_state = WRITE_EPC;
	       n_epc = (t_rob_head.in_delay_slot ? (t_rob_head.pc - 'd4) : t_rob_head.pc);
	       n_exc_in_delay = t_rob_head.in_delay_slot;
	    end
	  WRITE_EPC:
	    begin
	       t_wr_epc = 1'b1;
	       t_wr_cause = 1'b1;
	       t_wr_badvaddr = r_has_badvaddr;
	       
	       n_machine_clr = 1'b1;
	       
	       n_restart_pc = sign_extend32((w_sr_bev ? 32'hbfc00000 : 32'h80000000) | (r_tlb_refill ? 32'h0 : 32'h180));
	       n_restart_src_pc = 'd0;
	       n_restart_src_is_indirect = 1'b0;
	       n_restart_valid = 1'b1;

	       n_got_break = 1'b0;
	       n_got_ud = 1'b0;
	       t_clr_dq = 1'b1;
	       n_ds_done = 1'b1;	       
	       n_state = EXCEPTION_DRAIN;
	    end
	  SERIALIZE_IN_FAULTED_DELAY_SLOT:
	    begin
	       t_alloc = !t_rob_full && !t_uq_full 
			 && (r_prf_free != 'd0) 
			   && !t_dq_empty;
	       n_state = t_alloc ? WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT : 
			 SERIALIZE_IN_FAULTED_DELAY_SLOT;
	    end
	 WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT:
	   begin
	      if(t_rob_next_head_complete)
		begin
		   if(t_rob_next_head.faulted)
		     begin
			$display("hello???");
			 if(t_rob_next_head.is_break)
			   begin
			      n_cause = 5'd9;
			      n_state = WRITE_EPC;
			   end
			 else if(t_rob_head.is_syscall)
			   begin
			      n_cause = 5'd8;	
			      n_state = WRITE_EPC;	    
			   end
			 else if(t_rob_head.trap)
			   begin
			      n_cause = 5'd13;
			      n_state = WRITE_EPC; 
			   end
			 else
			   begin
`ifdef VERILATOR
			      $stop();
`endif
			   end			
		     end
		   else
		     begin
			n_pending_fault = 1'b0;
			n_state = ACTIVE;
		     end
		end
	   end // case: WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT
	  default:
	    begin
	    end
	endcase // unique case (r_state)

	if(t_alloc)
	  begin
	     n_in_delay_slot = t_alloc_two ? t_uop2.has_delay_slot
			       : t_uop.has_delay_slot;
	  end
	
	else if(t_clr_dq || t_clr_rob)
	  begin
	     n_in_delay_slot = 1'b0;
	  end
	
     end // always_comb
   
      
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_rob_head_ptr <= 'd0;
	     r_rob_tail_ptr <= 'd0;
	     r_rob_next_head_ptr <= 'd1;
	     r_rob_next_tail_ptr <= 'd1;
	  end
	else
	  begin
	     r_rob_head_ptr <= n_rob_head_ptr;
	     r_rob_tail_ptr <= n_rob_tail_ptr;
	     r_rob_next_head_ptr <= n_rob_next_head_ptr;
	     r_rob_next_tail_ptr <= n_rob_next_tail_ptr;
	  end
     end // always_ff@ (posedge clk)


   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_hilo_alloc_rat <= 'd0;
	     r_hilo_retire_rat <= 'd0;
	  end
	else
	  begin
	     r_hilo_alloc_rat <= t_rat_copy ? r_hilo_retire_rat : n_hilo_alloc_rat;
	     r_hilo_retire_rat <= n_hilo_retire_rat;
	  end
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(logic [`LG_PRF_ENTRIES-1:0] i_rat = 'd0; i_rat < 'd32; i_rat = i_rat + 'd1)
	       begin
		  r_alloc_rat[i_rat[4:0]] <= i_rat;
		  r_retire_rat[i_rat[4:0]] <= i_rat;
	       end
	  end
	else
	  begin
	     r_alloc_rat <= t_rat_copy ? r_retire_rat : n_alloc_rat;
	     r_retire_rat <= n_retire_rat;
	  end
     end // always_ff@ (posedge clk)

   // always_ff@(negedge clk)
   //   begin
   // 	if(t_alloc) $display("alloc1 %x at cycle %d of type %d, monitor=%b", t_uop.pc, r_cycle, t_uop.op, t_uop.op == MONITOR);
   // 	if(t_alloc_two) $display("alloc2 %x at cycle %d of type %d, monitor=%b", t_uop2.pc, r_cycle, t_uop2.op, t_uop2.op == MONITOR);
   //   end
   // 	if(n_state == ACTIVE && r_state == RAT)
   // 	  begin
   // 	     $display("RESTART COMPLETE at cycle %d", r_cycle);
   // 	  end
   // 	if(t_uop.pc == 'h20d2c && t_uop.srcA_valid)
   // 	  begin
   // 	     $display("at %d, pc %x SLL with lsrcA = %d, psrcA = %d, uuid = %d", 
   // 		      r_cycle, t_alloc_uop.pc, t_uop.srcA, t_alloc_uop.srcA, t_alloc_uop.fetch_cycle);
   // 	  end
   // 	if(t_uop2.pc == 'h20d2c && t_uop2.srcA_valid)
   // 	  begin
   // 	     $display("at %d, pc %x SLL with lsrcA = %d, psrcA = %d, uuid = %d", 
   // 		      r_cycle, t_alloc_uop2.pc, t_uop2.srcA, t_alloc_uop2.srcA, t_alloc_uop.fetch_cycle);
   // 	  end
   // 	if(t_uop.pc == 'h20d28 && t_uop.srcA_valid)
   // 	  begin
   // 	     $display("at %d, pc %x dst %d with lsrcA = %d, psrcA = %d, uuid = %d", 
   // 		      r_cycle, t_alloc_uop.pc, t_alloc_uop.dst, t_uop.srcA, t_alloc_uop.srcA, t_alloc_uop.fetch_cycle);
   // 	  end
   // 	if(t_uop2.pc == 'h20d28 && t_uop2.srcA_valid)
   // 	  begin
   // 	     $display("at %d, pc %x dst %d with lsrcA = %d, psrcA = %d, uuid = %d", 
   // 		      r_cycle, t_alloc_uop2.pc, t_alloc_uop2.dst, t_uop2.srcA, t_alloc_uop2.srcA, t_alloc_uop.fetch_cycle);
   // 	  end
	
   //   end

   
   always_comb
     begin
	n_alloc_rat = r_alloc_rat;
	n_hilo_alloc_rat = r_hilo_alloc_rat;
	
	t_alloc_uop = t_uop;
	t_alloc_uop2 = t_uop2;
`ifdef VERILATOR
	t_alloc_uop.clear_id = r_clear_cnt;
	t_alloc_uop2.clear_id = r_clear_cnt;
`endif
	
	if(t_uop.srcA_valid)
	  begin
	     t_alloc_uop.srcA = r_alloc_rat[t_uop.srcA[4:0]];	     
	  end
	if(t_uop.srcB_valid)
	  begin
	     t_alloc_uop.srcB = r_alloc_rat[t_uop.srcB[4:0]];
	  end
	     
	if(t_uop.hilo_src_valid)
	  begin
	     t_alloc_uop.hilo_src = r_hilo_alloc_rat;
	  end
	
	//2nd uop begins here
	if(t_uop2.srcA_valid)
	  begin
	     t_alloc_uop2.srcA =  (t_uop.dst_valid && (t_uop2.srcA[4:0] == t_uop.dst[4:0]) ?
				  n_prf_entry :  r_alloc_rat[t_uop2.srcA[4:0]]);	     
	  end
	if(t_uop2.srcB_valid )
	  begin
	     t_alloc_uop2.srcB = (t_uop.dst_valid && (t_uop2.srcB[4:0] == t_uop.dst[4:0]) ?
				  n_prf_entry :  r_alloc_rat[t_uop2.srcB[4:0]]);	     	     
	  end
	
	if(t_uop2.hilo_src_valid)
	  begin
	     t_alloc_uop2.hilo_src = t_uop.hilo_dst_valid ? n_hilo_prf_entry : 
				     r_hilo_alloc_rat;
	  end
	

	if(t_alloc)
	  begin
	     if(t_uop.dst_valid)
	       begin
		  n_alloc_rat[t_uop.dst[4:0]] = n_prf_entry;
		  t_alloc_uop.dst = n_prf_entry;
	       end
	     else if(t_uop.hilo_dst_valid)
	       begin
		  n_hilo_alloc_rat = n_hilo_prf_entry;
		  t_alloc_uop.hilo_dst = n_hilo_prf_entry;
	       end
	     
	     t_alloc_uop.rob_ptr = r_rob_tail_ptr[`LG_ROB_ENTRIES-1:0];
	  end // if (t_alloc)

	if(t_alloc_two)
	  begin
	     if(t_uop2.dst_valid)
	       begin
		  n_alloc_rat[t_uop2.dst[4:0]] = n_prf_entry2;
		  t_alloc_uop2.dst = n_prf_entry2;
	       end
	     t_alloc_uop2.rob_ptr = r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:0];
	  end
	
     end // always_comb


   //always_ff@(negedge clk)
   //begin
   //$display("r_cycle %d : $v1 -> %d", r_cycle, n_alloc_rat['d3]);
   //end
  
   always_comb
     begin
	n_retire_rat = r_retire_rat;
	n_hilo_retire_rat = r_hilo_retire_rat;
	
	t_free_reg = 1'b0;
	t_free_reg_ptr = 'd0;
	t_free_reg_two = 1'b0;
	t_free_reg_two_ptr = 'd0;
	
	
	t_free_hilo = 1'b0;
	t_free_hilo_ptr = 'd0;
	
	n_retire_prf_free = r_retire_prf_free;
	n_retire_hilo_prf_free = r_retire_hilo_prf_free;
	
	n_branch_pc = {{HI_EBITS{1'b0}}, 32'd0};
	n_took_branch = 1'b0;
	n_branch_valid = 1'b0;
	n_branch_fault = 1'b0;
	n_branch_pht_idx = 'd0;
	
	if(t_retire)
	  begin
	     if(t_rob_head.valid_dst)
	       begin
		  t_free_reg = 1'b1;
		  t_free_reg_ptr = t_rob_head.old_pdst;
		  n_retire_rat[t_rob_head.ldst] = t_rob_head.pdst;
		  n_retire_prf_free[t_rob_head.pdst] = 1'b0;
		  n_retire_prf_free[t_rob_head.old_pdst] = 1'b1;
	       end
	     else if(t_rob_head.valid_hilo_dst)
	       begin
		  t_free_hilo = 1'b1;
		  t_free_hilo_ptr = t_rob_head.old_pdst[`LG_HILO_PRF_ENTRIES-1:0];
		  n_hilo_retire_rat = t_rob_head.pdst[`LG_HILO_PRF_ENTRIES-1:0];
		  n_retire_hilo_prf_free[t_rob_head.pdst[`LG_HILO_PRF_ENTRIES-1:0]] = 1'b0;
		  n_retire_hilo_prf_free[t_rob_head.old_pdst[`LG_HILO_PRF_ENTRIES-1:0]] = 1'b1;
	       end

	     if(t_retire_two && t_rob_next_head.valid_dst)
	       begin
		  t_free_reg_two = 1'b1;
		  t_free_reg_two_ptr = t_rob_next_head.old_pdst;
		  n_retire_rat[t_rob_next_head.ldst] = t_rob_next_head.pdst;
		  n_retire_prf_free[t_rob_next_head.pdst] = 1'b0;
		  n_retire_prf_free[t_rob_next_head.old_pdst] = 1'b1;
	       end
	     
	     n_branch_pc = t_retire_two ? t_rob_next_head.pc : t_rob_head.pc;
	     n_took_branch = t_retire_two ? t_rob_next_head.take_br : t_rob_head.take_br;
	     n_branch_valid = t_retire_two ? t_rob_next_head.is_br :  t_rob_head.is_br;
	     n_branch_fault = t_rob_head.faulted;
	     n_branch_pht_idx = t_retire_two ? t_rob_next_head.pht_idx : t_rob_head.pht_idx;
	  end // if (t_retire)
	
     end // always_comb
   
   
   always_comb
     begin
	t_rob_tail.faulted  = 1'b0;
	t_rob_tail.valid_dst  = 1'b0;
	t_rob_tail.valid_hilo_dst = 1'b0;
	t_rob_tail.ldst  = 'd0;
	t_rob_tail.pdst  = 'd0;
	t_rob_tail.old_pdst  = 'd0;
	t_rob_tail.pc = t_alloc_uop.pc;
	t_rob_tail.target_pc = 'd0;
	
	t_rob_tail.is_call = t_alloc_uop.op == JAL || t_alloc_uop.op == JALR || t_alloc_uop.op == BAL;
	t_rob_tail.is_irq = t_alloc_uop.op == IRQ;
	t_rob_tail.is_ret = (t_alloc_uop.op == JR) && (t_uop.srcA == 'd31);
	t_rob_tail.is_break  = (t_alloc_uop.op == BREAK);
	t_rob_tail.is_syscall  = (t_alloc_uop.op == SYSCALL);	
	t_rob_tail.is_indirect = t_alloc_uop.op == JALR || t_alloc_uop.op == JR;
	t_rob_tail.is_tlbp = (t_alloc_uop.op == TLBP);
	
	t_rob_tail.is_ii = 1'b0;
	t_rob_tail.overflow = 1'b0;
	t_rob_tail.trap = 1'b0;
	t_rob_tail.tlb_refill = 1'b0;
	t_rob_tail.tlb_invalid = 1'b0;
	t_rob_tail.tlb_modified = 1'b0;
	t_rob_tail.tlb_hit = 1'b0;
	t_rob_tail.tlb_index = 6'd0;
	
	t_rob_tail.is_bad_addr = 1'b0;
	t_rob_tail.take_br = 1'b0;
	t_rob_tail.is_br = t_alloc_uop.is_br;
	t_rob_tail.is_store = is_store(t_alloc_uop.op);

	
	t_rob_tail.in_delay_slot = r_in_delay_slot;
	t_rob_tail.data = 'd0;
	t_rob_tail.opcode = t_alloc_uop.op;
	t_rob_tail.pht_idx = t_alloc_uop.pht_idx;
	
	t_rob_next_tail.faulted  = 1'b0;
	t_rob_next_tail.valid_dst  = 1'b0;
	t_rob_next_tail.valid_hilo_dst = 1'b0;
	t_rob_next_tail.ldst  = 'd0;
	t_rob_next_tail.pdst  = 'd0;
	t_rob_next_tail.old_pdst  = 'd0;
	t_rob_next_tail.pc = t_alloc_uop2.pc;
	t_rob_next_tail.target_pc = 'd0;
	t_rob_next_tail.opcode = t_alloc_uop2.op;
	t_rob_next_tail.is_call = t_alloc_uop2.op == JAL || t_alloc_uop2.op == JALR || t_alloc_uop2.op == BAL;
	t_rob_next_tail.is_irq = t_alloc_uop2.op == IRQ;
	
	t_rob_next_tail.is_ret = (t_alloc_uop2.op == JR) && (t_uop.srcA == 'd31);
	t_rob_next_tail.is_break = (t_alloc_uop2.op == BREAK);
	t_rob_next_tail.is_syscall = (t_alloc_uop2.op == SYSCALL);
	t_rob_next_tail.is_tlbp = (t_alloc_uop2.op == TLBP);
	t_rob_next_tail.is_indirect = t_alloc_uop2.op == JALR || t_alloc_uop2.op == JR;
	t_rob_next_tail.overflow = 1'b0;
	t_rob_next_tail.trap = 1'b0;
	t_rob_next_tail.tlb_refill = 1'b0;
	t_rob_next_tail.tlb_invalid = 1'b0;
	t_rob_next_tail.tlb_modified = 1'b0;
	t_rob_next_tail.tlb_hit = 1'b0;
	t_rob_next_tail.tlb_index = 6'd0;
	
	t_rob_next_tail.is_ii = 1'b0;
	t_rob_next_tail.is_bad_addr = 1'b0;
	t_rob_next_tail.take_br = 1'b0;
	t_rob_next_tail.is_br = t_alloc_uop2.is_br;	
	t_rob_next_tail.is_store = is_store(t_alloc_uop2.op);
	
	t_rob_next_tail.in_delay_slot = r_in_delay_slot;
	t_rob_next_tail.data = 'd0;
	t_rob_next_tail.pht_idx = t_alloc_uop2.pht_idx;
	
	t_rob_tail.has_delay_slot = t_alloc_uop.has_delay_slot;
	t_rob_tail.has_nullifying_delay_slot = t_alloc_uop.has_nullifying_delay_slot;

	t_rob_next_tail.has_delay_slot = t_uop2.has_delay_slot;
	t_rob_next_tail.has_nullifying_delay_slot = t_uop2.has_nullifying_delay_slot;	
	
	if(t_alloc)
	  begin	     
`ifdef ENABLE_CYCLE_ACCOUNTING
	     t_rob_tail.fetch_cycle = t_alloc_uop.fetch_cycle;
	     t_rob_tail.alloc_cycle = r_cycle;
	     t_rob_tail.complete_cycle = 'd0;
`endif	     
	     if(t_uop.dst_valid)
	       begin
		  t_rob_tail.valid_dst = 1'b1;
		  /* this is correct, we do not want the renamed version */
		  t_rob_tail.ldst = t_uop.dst[4:0];
		  t_rob_tail.pdst = n_prf_entry;
		  t_rob_tail.old_pdst = r_alloc_rat[t_uop.dst[4:0]];
	       end
	     else if(t_uop.hilo_dst_valid)
	       begin
		  t_rob_tail.valid_hilo_dst = 1'b1;
		  t_rob_tail.pdst = {{(`LG_PRF_ENTRIES-`LG_HILO_PRF_ENTRIES){1'b0}}, n_hilo_prf_entry};
		  t_rob_tail.old_pdst = {{(`LG_PRF_ENTRIES-`LG_HILO_PRF_ENTRIES){1'b0}}, r_hilo_alloc_rat};
	       end
	     
	     if(t_fold_uop)
	       begin
`ifdef ENABLE_CYCLE_ACCOUNTING
		  t_rob_tail.complete_cycle = r_cycle;
`endif		  
		  if(t_uop.op == II)
		    begin
		       t_rob_tail.faulted = 1'b1;
		       t_rob_tail.is_ii = 1'b1;
		    end
		  else if(t_uop.op == IRQ)
		    begin
		       t_rob_tail.faulted = 1'b1;
		    end
		  else if(t_uop.op == J)
		    begin
		       t_rob_tail.take_br = 1'b1;
		    end
	       end
	     
	  end // if (t_alloc)


	if(t_alloc_two)
	  begin

	     
`ifdef ENABLE_CYCLE_ACCOUNTING
	     t_rob_next_tail.fetch_cycle = t_alloc_uop2.fetch_cycle;
	     t_rob_next_tail.alloc_cycle = r_cycle;
	     t_rob_next_tail.complete_cycle = 'd0;
`endif
	     //t_uop.has_delay_slot
	     t_rob_next_tail.in_delay_slot = t_uop.has_delay_slot;

	     if(t_uop2.dst_valid)
	       begin
		  t_rob_next_tail.valid_dst = 1'b1;
		  /* this is correct, we do not want the renamed version */
		  t_rob_next_tail.ldst = t_uop2.dst[4:0];
		  t_rob_next_tail.pdst = n_prf_entry2;
		  t_rob_next_tail.old_pdst = (t_uop.dst_valid && (t_uop.dst == t_uop2.dst)) ? t_rob_tail.pdst : r_alloc_rat[t_uop2.dst[4:0]];
	       end




	     if(t_fold_uop2)
	       begin
`ifdef ENABLE_CYCLE_ACCOUNTING
		  t_rob_next_tail.complete_cycle = r_cycle;
`endif		  
		  if(t_uop2.op == II)
		    begin
		       t_rob_next_tail.faulted = 1'b1;
		       t_rob_next_tail.is_ii = 1'b1;
		    end
		  else if(t_uop2.op == IRQ)
		    begin
		       t_rob_next_tail.faulted = 1'b1;
		    end
		  else if(t_uop2.op == J)
		    begin
		       t_rob_next_tail.take_br = 1'b1;
		    end
	       end // if (t_fold_uop2)
	  end // if (t_alloc_two)
	
	

	

     end // always_comb
   


   always_ff@(posedge clk)
     begin
	if(reset || t_clr_rob)
	  begin
	     r_rob_complete <= 'd0;
	     r_rob_sd_complete <= 'd0;
	  end
	else
	  begin
	     if(t_alloc)
	       begin
		  r_rob_complete[r_rob_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= t_fold_uop;
		  r_rob_sd_complete[r_rob_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= !(t_uop.is_mem & t_uop.srcB_valid);
	       end
	     if(t_alloc_two)
	       begin
		  r_rob_complete[r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= t_fold_uop2;
		  r_rob_sd_complete[r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= !(t_uop2.is_mem & t_uop2.srcB_valid);				    
	       end
	     if(t_complete_valid_1)
	       begin
		  //$display("rob entry %d marked complete by port 1", t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]);
		  r_rob_complete[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]] <= t_complete_bundle_1.complete;
	       end

	     if(core_mem_rsp_valid)
	       begin
		  //$display("rob entry %d marked complete by mem port", core_mem_rsp.rob_ptr);
		  r_rob_complete[core_mem_rsp.rob_ptr] <= 1'b1;
	       end

	     if(t_core_store_data_ptr_valid)
	       begin
		  r_rob_sd_complete[t_core_store_data_ptr] <= 1'b1;
	       end
	  end
     end // always_ff@ (posedge clk)
   
   always_ff@(posedge clk)
     begin
	if(reset || t_clr_rob)
	  begin
	     for(integer i = 0; i < N_ROB_ENTRIES; i=i+1)
	       begin
		  r_rob[i].faulted <= 1'b0;
	       end
	  end
	else
	  begin
	     if(t_alloc)
	       begin
		  r_rob[r_rob_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= t_rob_tail;
	       end
	     if(t_alloc_two)
	       begin
		  r_rob[r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= t_rob_next_tail;
	       end
	     if(t_complete_valid_1)
	       begin
		  r_rob[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]].faulted <= t_complete_bundle_1.faulted;
		  r_rob[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]].target_pc <= t_complete_bundle_1.restart_pc;
		  r_rob[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]].is_ii <= t_complete_bundle_1.is_ii;
		  r_rob[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]].take_br <= t_complete_bundle_1.take_br;
		  r_rob[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]].data <= t_complete_bundle_1.data;
		  r_rob[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]].overflow <= t_complete_bundle_1.overflow;
		  r_rob[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]].trap <= t_complete_bundle_1.trap;		  
`ifdef ENABLE_CYCLE_ACCOUNTING
		  r_rob[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0]].complete_cycle <= r_cycle;
`endif	    
	       end
	     if(core_mem_rsp_valid)
	       begin
		  r_rob[core_mem_rsp.rob_ptr].data <= core_mem_rsp.data;
		  r_rob[core_mem_rsp.rob_ptr].faulted <= core_mem_rsp.bad_addr | core_mem_rsp.tlb_refill | core_mem_rsp.tlb_invalid | core_mem_rsp.tlb_modified;
		  
		  r_rob[core_mem_rsp.rob_ptr].tlb_refill <= core_mem_rsp.tlb_refill;
		  r_rob[core_mem_rsp.rob_ptr].tlb_invalid <= core_mem_rsp.tlb_invalid;
		  r_rob[core_mem_rsp.rob_ptr].tlb_modified <= core_mem_rsp.tlb_modified;		  

		  r_rob[core_mem_rsp.rob_ptr].tlb_hit <= core_mem_rsp.tlb_hit;
		  r_rob[core_mem_rsp.rob_ptr].tlb_index <= core_mem_rsp.tlb_index;
		  
		  r_rob[core_mem_rsp.rob_ptr].is_bad_addr <= core_mem_rsp.bad_addr;
		  r_addrs[core_mem_rsp.rob_ptr] <= core_mem_rsp.data[`M_WIDTH-1:0];

`ifdef ENABLE_CYCLE_ACCOUNTING
		  r_rob[core_mem_rsp.rob_ptr].complete_cycle <= r_cycle;
`endif	    	     	     
	       end
	  end
     end // always_ff@ (posedge clk)


   
   always_ff@(posedge clk)
     begin
	if(reset || t_clr_rob)
	  begin 
	     r_rob_dead_insns <= 'd0;
	  end
	else
	  begin
	     if(t_retire)
	       begin
		  r_rob_dead_insns[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]] <= 1'b0;		  
	       end
	     if(t_retire_two)
	       begin
		  r_rob_dead_insns[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0]] <= 1'b0;
	       end
	     if(t_alloc)
	       begin
		  r_rob_dead_insns[r_rob_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= 1'b1;		  
	       end
	     if(t_alloc_two)
	       begin
		  r_rob_dead_insns[r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= 1'b1;		  
	       end
	  end // else: !if(reset || t_clr_rob)
     end // always_ff@ (posedge clk)


   always_comb
     begin
	t_clr_mask = uq_wait|mq_wait;
	if(t_complete_valid_1)
	  begin
	     t_clr_mask[t_complete_bundle_1.rob_ptr] = 1'b1;
	  end
	if(core_mem_rsp_valid)
	  begin
	     t_clr_mask[core_mem_rsp.rob_ptr] = 1'b1;
	  end
     end
    
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_rob_inflight <= 'd0;
	  end
	else
	  begin
	     if(r_ds_done)
	       begin
		  r_rob_inflight <= r_rob_inflight & (~t_clr_mask);
	       end
	     else
	       begin
		  if(t_complete_valid_1)
		    begin
		       //$display("cycle %d, 1 rob ptr %d complete\n", r_cycle, t_complete_bundle_1.rob_ptr);		  
		       r_rob_inflight[t_complete_bundle_1.rob_ptr] <= 1'b0;		  
		    end
		  if(core_mem_rsp_valid)
		    begin
		       //$display("cycle %d, M rob ptr %d complete\n", r_cycle, core_mem_rsp.rob_ptr);
		       r_rob_inflight[core_mem_rsp.rob_ptr] <= 1'b0;
		    end
		  if(t_alloc && !t_fold_uop)
		    begin
		       r_rob_inflight[r_rob_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= 1'b1;		  
		    end
		  if(t_alloc_two && !t_fold_uop2)
		    begin
		       r_rob_inflight[r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= 1'b1;
		    end
	       end
	  end // else: !if(reset)
     end // always_ff@ (posedge clk)
	          
   
   always_comb
     begin
	n_rob_head_ptr = r_rob_head_ptr;
	n_rob_tail_ptr = r_rob_tail_ptr;
	n_rob_next_head_ptr = r_rob_next_head_ptr;
	n_rob_next_tail_ptr = r_rob_next_tail_ptr;
	
	//rob control 
	if(t_clr_rob)
	  begin
	     n_rob_head_ptr = 'd0;
	     n_rob_tail_ptr = 'd0;
	     n_rob_next_head_ptr = 'd1;
	     n_rob_next_tail_ptr = 'd1;
	  end
	else
	  begin
	     if(t_alloc && !t_alloc_two)
	       begin
		  n_rob_tail_ptr = r_rob_tail_ptr + 'd1;
		  n_rob_next_tail_ptr = r_rob_next_tail_ptr + 'd1;
	       end
	     else if(t_alloc && t_alloc_two)
	       begin
		  n_rob_tail_ptr = r_rob_tail_ptr + 'd2;
		  n_rob_next_tail_ptr = r_rob_next_tail_ptr + 'd2;
	       end

	     
	     if(t_retire || t_bump_rob_head)
	       begin
		  n_rob_head_ptr = t_retire_two ? r_rob_head_ptr + 'd2 : 
				   r_rob_head_ptr + 'd1;
		  n_rob_next_head_ptr = t_retire_two ? r_rob_next_head_ptr + 'd2 : 
					r_rob_next_head_ptr + 'd1;
	       end
	  end // else: !if(t_clr_rob)


	
	
	
	t_rob_empty = (r_rob_head_ptr == r_rob_tail_ptr);
	t_rob_next_empty = (r_rob_next_head_ptr == r_rob_tail_ptr);
	t_rob_full = (r_rob_head_ptr[`LG_ROB_ENTRIES-1:0] == r_rob_tail_ptr[`LG_ROB_ENTRIES-1:0]) && (r_rob_head_ptr != r_rob_tail_ptr);
	t_rob_next_full = (r_rob_head_ptr[`LG_ROB_ENTRIES-1:0] == r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:0]) && (r_rob_head_ptr != r_rob_next_tail_ptr);



	
     end // always_comb


   always_comb
     begin
	t_rob_head = r_rob[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]];
	t_rob_next_head = r_rob[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0]];
	
	t_rob_head_complete = r_rob_sd_complete[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]] &
			      r_rob_complete[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]];
	
	t_rob_next_head_complete = r_rob_sd_complete[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0]] &
				   r_rob_complete[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0]];
     end // always_comb

   

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(integer i = 0; i < N_HILO_ENTRIES; i = i + 1)
	       begin
		  r_hilo_prf_free[i] <= (i==0) ? 1'b0 : 1'b1;
		  r_retire_hilo_prf_free[i] <= (i==0) ? 1'b0 : 1'b1;
	       end
	  end
	else
	  begin
	     r_hilo_prf_free <= t_rat_copy ? r_retire_hilo_prf_free : n_hilo_prf_free;
	     r_retire_hilo_prf_free <= n_retire_hilo_prf_free;
	  end
     end // always_ff@ (posedge clk)
   
   
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(integer i = 0; i < N_PRF_ENTRIES; i = i + 1)
	       begin
		  r_prf_free[i] <= (i < 32) ? 1'b0 : 1'b1;
		  r_retire_prf_free[i] <= (i < 32) ? 1'b0 : 1'b1;
	       end
	  end
	else
	  begin
	     r_prf_free <= t_rat_copy ? r_retire_prf_free : n_prf_free;
	     r_retire_prf_free <= n_retire_prf_free;
	  end
     end // always_ff@ (posedge clk)



   
   find_first_set#(`LG_HILO_PRF_ENTRIES) ffs_hilo(.in(r_hilo_prf_free),
						 .y(t_hilo_ffs));

   always_comb
     begin
	n_hilo_prf_free = r_hilo_prf_free;
	n_hilo_prf_entry = t_hilo_ffs[`LG_HILO_PRF_ENTRIES-1:0];
	
	if(t_alloc & t_uop.hilo_dst_valid)
	  begin
	     n_hilo_prf_free[n_hilo_prf_entry] = 1'b0;
	  end
	if(t_free_hilo)
	  begin
	     n_hilo_prf_free[t_free_hilo_ptr] = 1'b1;
	  end
	
     end // always_comb

   generate
      for(genvar i = 0; i < N_PRF_ENTRIES; i=i+2)
	begin
	   assign w_prf_free_even[i] = r_prf_free[i];
	   assign w_prf_free_even[i+1] = 1'b0;
	   assign w_prf_free_odd[i] = 1'b0;	   
	   assign w_prf_free_odd[i+1] = r_prf_free[i+1];
	end
   endgenerate


   assign w_prf_free_even_full = (|w_prf_free_even) == 1'b0;
   assign w_prf_free_odd_full = (|w_prf_free_odd) == 1'b0;
   
   
   find_first_set#(`LG_PRF_ENTRIES) ffs_gpr(.in(w_prf_free_even),
					    .y(w_gpr_ffs_even));

   find_first_set#(`LG_PRF_ENTRIES) ffs_gpr2(.in(w_prf_free_odd),
					     .y(w_gpr_ffs_odd));
   always_ff@(posedge clk)
     begin
	r_bank_sel <= reset ? 1'b0 : ~r_bank_sel;
     end
   
   always_comb
     begin
	t_gpr_ffs  = r_bank_sel ? w_gpr_ffs_even : w_gpr_ffs_odd;
	t_gpr_ffs2 = r_bank_sel ? w_gpr_ffs_odd : w_gpr_ffs_even;
	t_gpr_ffs_full = r_bank_sel ? w_prf_free_even_full : w_prf_free_odd_full;
	t_gpr_ffs2_full = r_bank_sel ? w_prf_free_odd_full : w_prf_free_even_full;
     end
   
   always_comb
     begin
	n_prf_free = r_prf_free;
	n_prf_entry = t_gpr_ffs[`LG_PRF_ENTRIES-1:0];
	n_prf_entry2 = t_gpr_ffs2[`LG_PRF_ENTRIES-1:0];
	
	if(t_alloc & t_uop.dst_valid)
	  begin
	     n_prf_free[n_prf_entry] = 1'b0;
	  end
	if(t_alloc_two && t_uop2.dst_valid)
	  begin
	     n_prf_free[n_prf_entry2] = 1'b0;
	  end
	if(t_free_reg)
	  begin
	     n_prf_free[t_free_reg_ptr] = 1'b1;
	  end
	if(t_free_reg_two)
	  begin
	     n_prf_free[t_free_reg_two_ptr] = 1'b1;
	  end
     end // always_comb

   
   decode_mips32 dec0 (.insn(insn.data), 
		      .pc(insn.pc), 
		      .insn_pred(insn.pred), 
		      .pht_idx(insn.pht_idx),
		      .insn_pred_target(insn.pred_target),
`ifdef ENABLE_CYCLE_ACCOUNTING
		      .fetch_cycle(insn.fetch_cycle),
`endif		      
		      .uop(t_dec_uop));

   decode_mips32 dec1 (.insn(insn_two.data), 
		      .pc(insn_two.pc), 
		      .insn_pred(insn_two.pred), 
		      .pht_idx(insn_two.pht_idx),
		      .insn_pred_target(insn_two.pred_target),
`ifdef ENABLE_CYCLE_ACCOUNTING
		      .fetch_cycle(insn_two.fetch_cycle),
`endif		      
		      .uop(t_dec_uop2));


   
   logic t_push_1, t_push_2;
   
   always_comb
     begin
	t_any_complete = t_complete_valid_1 | core_mem_rsp_valid;
	t_push_1 = t_alloc && !t_fold_uop;
	t_push_2 = t_alloc_two && !t_fold_uop2;
     end

   logic t_wr_tlbp;
   logic t_tlbp_hit;
   logic [5:0] t_tlbp_index;

   always_comb
     begin
	t_wr_tlbp = 1'b0;
	t_tlbp_hit = 1'b0;
	t_tlbp_index = 6'd0;
	if(t_retire_two & t_rob_next_head.is_tlbp)
	  begin
	     t_wr_tlbp = 1'b1;
	     t_tlbp_hit = t_rob_next_head.tlb_hit;
	     t_tlbp_index = t_rob_next_head.tlb_index;	     
	  end
	else if (t_retire & t_rob_head.is_tlbp)
	  begin
	     t_wr_tlbp = 1'b1;	     
	     t_tlbp_hit = t_rob_head.tlb_hit;
	     t_tlbp_index = t_rob_head.tlb_index;
	  end
     end // always_comb
   
   
   exec e (
	   .clk(clk), 
	   .reset(reset),
	   .retire(t_retire),
	   .retire_two(t_retire_two),
	   .core_epc(r_epc),
	   .core_wr_epc(t_wr_epc),
	   .core_cause(r_cause),
	   .exec_epc(w_exec_epc),
	   .core_wr_tlbp(t_wr_tlbp),
	   .core_tlbp_hit(t_tlbp_hit),
	   .core_tlbp_index(t_tlbp_index),
	   .asid(asid),
	   .tlb_entry_out_valid(tlb_entry_out_valid),
	   .tlb_entry_out(tlb_entry_out),	   
	   .sr_bev(w_sr_bev),	   
	   .core_wr_cause(t_wr_cause),
	   .core_wr_badvaddr(t_wr_badvaddr),
	   .core_badvaddr(r_badvaddr),
	   .save_to_tlb_regs(r_save_to_tlb_regs),
	   .exc_in_delay(r_exc_in_delay),
	   .in_kernel_mode(in_kernel_mode),
	   .in_supervisor_mode(in_supervisor_mode),
	   .in_user_mode(in_user_mode),
	   .putchar_fifo_out(putchar_fifo_out),
	   .putchar_fifo_empty(putchar_fifo_empty),
	   .putchar_fifo_pop(putchar_fifo_pop),
	   .putchar_fifo_wptr(putchar_fifo_wptr),
	   .putchar_fifo_rptr(putchar_fifo_rptr),
	   .divide_ready(t_divide_ready),
`ifdef VERILATOR
	   .clear_cnt(r_clear_cnt),
`endif
	   .ds_done(r_ds_done),
	   .mem_dq_clr(t_clr_rob),
	   .restart_complete(t_restart_complete),
	   .cpr0_status_reg(t_cpr0_status_reg),
	   .mq_wait(mq_wait),
	   .uq_wait(uq_wait),
	   .uq_full(t_uq_full),
	   .uq_next_full(t_uq_next_full),
	   .uq_uop(t_push_1 ? t_alloc_uop : t_alloc_uop2),
	   .uq_uop_two(t_alloc_uop2),	   
	   .uq_push(t_push_1 || (!t_push_1 && t_push_2)),
	   .uq_push_two(t_push_2 && t_push_1),
	   	   
	   .complete_bundle_1(t_complete_bundle_1),
	   .complete_valid_1(t_complete_valid_1),

	   .mem_req(t_mem_req),
	   .mem_req_valid(t_mem_req_valid),
	   .mem_req_ack(core_mem_req_ack),
	   .core_store_data_valid(core_store_data_valid),
	   .core_store_data(core_store_data),
	   .core_store_data_ack(core_store_data_ack),
	   .core_store_data_ptr_valid(t_core_store_data_ptr_valid),
	   .core_store_data_ptr(t_core_store_data_ptr),
	   .mem_rsp_dst_ptr(core_mem_rsp.dst_ptr),
	   .mem_rsp_dst_valid(core_mem_rsp.dst_valid),
	   .mem_rsp_load_data(core_mem_rsp.data),
	   .mem_rsp_rob_ptr(core_mem_rsp.rob_ptr)
	   );


   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_dq_head_ptr <= 'd0;
	     r_dq_next_head_ptr <= 'd1;
	     r_dq_next_tail_ptr <= 'd1;
	     r_dq_tail_ptr <= 'd0;
	     r_dq_cnt <= 'd0;
	  end
	else
	  begin
	     r_dq_head_ptr <= t_clr_rob ? 'd0 :n_dq_head_ptr;
	     r_dq_tail_ptr <= t_clr_rob ? 'd0 :n_dq_tail_ptr;	     
	     r_dq_next_head_ptr <= t_clr_rob ? 'd1 : n_dq_next_head_ptr;
	     r_dq_next_tail_ptr <= t_clr_rob ? 'd1 : n_dq_next_tail_ptr;
	     r_dq_cnt <= t_clr_rob ? 'd0 : n_dq_cnt;
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	if(t_push_dq_one)
	  r_dq[r_dq_tail_ptr[`LG_DQ_ENTRIES-1:0]] <= t_dec_uop;
	if(t_push_dq_two)
	  r_dq[r_dq_next_tail_ptr[`LG_DQ_ENTRIES-1:0]] <= t_dec_uop2;
     end

   always_ff@(negedge clk)
     begin
	//if(t_push_dq_one)
	//$display("decoded %x to uop %d", t_dec_uop.pc, t_dec_uop.op);
	//if(t_push_dq_two)
	//$display("decoded %x to uop %d", t_dec_uop2.pc, t_dec_uop2.op);	

    	if(insn_ack && insn_ack_two && 1'b0)
    	  begin
    	     $display("ack two insns in cycle %d, valid %b, %b, pc %x %x", 
    		      r_cycle, insn_valid, insn_valid_two,
   		      insn.pc, insn_two.pc);
    	  end
    	else if(insn_ack && !insn_ack_two && 1'b0)
    	  begin
    	     $display("ack one insn in cycle %d, valid %b, pc %x ", 
    		      r_cycle, insn_valid, 
    		      insn.pc);
    	  end
     end
   
   always_comb
     begin
	t_push_dq_one = 1'b0;
	t_push_dq_two = 1'b0;
	n_dq_tail_ptr = r_dq_tail_ptr;
	n_dq_head_ptr = r_dq_head_ptr;
	n_dq_next_head_ptr = r_dq_next_head_ptr;
	n_dq_next_tail_ptr = r_dq_next_tail_ptr;
	
	t_dq_empty = (r_dq_tail_ptr == r_dq_head_ptr);
	t_dq_next_empty = (r_dq_tail_ptr == r_dq_next_head_ptr);
	
	t_dq_full = (r_dq_tail_ptr[`LG_DQ_ENTRIES-1:0] == r_dq_head_ptr[`LG_DQ_ENTRIES-1:0]) && (r_dq_tail_ptr != r_dq_head_ptr);

	t_dq_next_full = (r_dq_next_tail_ptr[`LG_DQ_ENTRIES-1:0] == r_dq_head_ptr[`LG_DQ_ENTRIES-1:0]) && (r_dq_next_tail_ptr != r_dq_head_ptr);
	
	n_dq_cnt = r_dq_cnt;
		
	t_uop = r_dq[r_dq_head_ptr[`LG_DQ_ENTRIES-1:0]];
	t_uop2 = r_dq[r_dq_next_head_ptr[`LG_DQ_ENTRIES-1:0]];
	
	if(t_clr_dq)
	  begin
	     n_dq_tail_ptr = 'd0;
	     n_dq_head_ptr = 'd0;
	     n_dq_next_head_ptr = 'd1;
	     n_dq_next_tail_ptr = 'd1;
	     n_dq_cnt = 'd0;
	  end
	else
	  begin
	     if(insn_valid && !t_dq_full && !(!t_dq_next_full && insn_valid_two))
	       begin
		  //push one instruction
		  t_push_dq_one = 1'b1;
		  n_dq_tail_ptr = r_dq_tail_ptr + 'd1;
		  n_dq_next_tail_ptr = r_dq_next_tail_ptr + 'd1;
		  n_dq_cnt = n_dq_cnt + 'd1;
	       end
	     else if(insn_valid && !t_dq_full && !t_dq_next_full && insn_valid_two)
	       begin
		  //push two instructions
		  t_push_dq_one = 1'b1;
		  t_push_dq_two = 1'b1;		  
		  n_dq_tail_ptr = r_dq_tail_ptr + 'd2;
		  n_dq_next_tail_ptr = r_dq_next_tail_ptr + 'd2;
		  n_dq_cnt = n_dq_cnt + 'd2;
	       end
	     
	     if(t_alloc && !t_alloc_two)
	       begin
		  n_dq_head_ptr = r_dq_head_ptr + 'd1;
		  n_dq_next_head_ptr = r_dq_next_head_ptr + 'd1;
		  n_dq_cnt = n_dq_cnt - 'd1;
	       end
	     else if(t_alloc && t_alloc_two)
	       begin
		  n_dq_head_ptr = r_dq_head_ptr + 'd2;
		  n_dq_next_head_ptr = r_dq_next_head_ptr + 'd2;
		  n_dq_cnt = n_dq_cnt - 'd2;
	       end
	  end
     end // always_comb
   
endmodule
