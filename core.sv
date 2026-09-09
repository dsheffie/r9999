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
`ifdef FORMAL_ROBWR_PORTS
	    fml_robwr_badv,
	    fml_robwr_act,
`endif
`ifdef FORMAL_RETIRE_PORTS
	    fml_ret_bad,
	    fml_ret_act,
	    fml_ret_badv,
`endif
	    single_step,
	    step,
	    bp_enable,
	    fault_clear,
	    bp_pc,
	    bp_wp_addr,
	    bp_wp_val,
	    bp_fault_only,
	    reset,
	    ip6,
	    ip5,
	    ip4,
	    ip3,
	    ip2,	   
	    in_kernel_mode,
	    in_supervisor_mode,
	    in_user_mode,
	    in_64b_kernel_mode,
	    in_64b_supervisor_mode,
	    in_64b_user_mode,
	    putchar_fifo_out,
	    putchar_fifo_empty,
	    putchar_fifo_pop,
	    putchar_fifo_wptr,
	    putchar_fifo_rptr,
	    head_of_rob_ptr_valid,
	    head_of_rob_ptr,
	    head_of_rob_has_delay_slot,
	    next_head_of_rob_ptr,
	    head_of_rob_ds_committable,
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
	    flush_cl_inval,
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
	    clr_link_reg,
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
	    status_reg,
	    badvaddr,
	    cause,
	    dbg_frozen,
	    dbg_wp_data,
	    cause_ip,
	    asid,
	    tlb_entry_out,
	    tlb_entry_out_valid,
	    took_irq,
	    cp0_count,
	    
	    l1i_flush_done,
	    l1d_flush_done,
	    l2_flush_done,
	    dbg_head_pc,
	    dbg_head_status,
	    dbg_head_fetch_cycle,
	    dbg_head_alloc_cycle,
	    dbg_serialize_cycle,
	    dbg_cycle,
	    dbg_oldest_first_pending,
	    dbg_trace_index,
	    dbg_trace_data,
	    dbg_trace_wptr,
	    dbg_rdchk);

   input logic clk;
   input logic reset;
   input logic ip6;
   input logic ip5;
   input logic ip4;
   input logic ip3;
   input logic ip2;   
   output logic	in_kernel_mode;
   output logic	in_supervisor_mode;
   output logic	in_user_mode;
   output logic	in_64b_kernel_mode;
   output logic	in_64b_supervisor_mode;
   output logic	in_64b_user_mode;
    
   output logic [7:0] putchar_fifo_out;
   output logic       putchar_fifo_empty;
   input logic 	      putchar_fifo_pop;
   output logic [3:0] putchar_fifo_wptr;
   output logic [3:0] putchar_fifo_rptr;
   
   output logic head_of_rob_ptr_valid;
   output logic [`LG_ROB_ENTRIES-1:0] head_of_rob_ptr;
   output logic			      head_of_rob_has_delay_slot;
   output logic [`LG_ROB_ENTRIES-1:0] next_head_of_rob_ptr;
   output logic			      head_of_rob_ds_committable;
   input logic resume;
   input logic single_step;
   input logic step;
   input logic bp_enable;   /* debug: freeze core after retiring bp_pc (also arms the fault-trap) */
   input logic fault_clear; /* debug: clear the fault-trap latch + re-arm + un-freeze (resettable) */
   input logic [31:0] bp_pc; /* debug: driver-programmable breakpoint PC (slv_reg9) */
   input logic [31:0] bp_wp_addr; /* debug: driver-programmable store-address watchpoint VA (slv_reg10) */
   input logic [31:0] bp_wp_val;  /* debug: expected corrupt store value to freeze on (slv_reg11) */
   input logic bp_fault_only;     /* debug (ctrl bit19): freeze ONLY on a FAULT at bp_pc, suppressing
                                   * every retire-match + routine-fatal-fault net.  For a HOT bp_pc
                                   * (e.g. 0e788bc0, a load that usually succeeds) whose crash is a
                                   * rare FAULT: retire-matches would freeze on every normal pass. */
   input logic memq_empty;
   output logic drain_ds_complete;
   output logic [(1<<`LG_ROB_ENTRIES)-1:0] dead_rob_mask;
   
   input logic [(`M_WIDTH-1):0] resume_pc;
   output logic 		ready_for_resume;
   output logic 		flush_req_l1d;
   output logic 		flush_req_l1i;
   
   output logic flush_cl_req;
   output logic [(`M_WIDTH-1):0] flush_cl_addr;
   output logic flush_cl_inval; /* per-line flush is an invalidate-no-writeback (DMA-in) */

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
   output logic			 clr_link_reg;
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

   output logic [7:0]			  retire_op;
   output logic [7:0]			  retire_two_op;
      
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
   output logic [31:0]			  status_reg;
   
   output logic [`M_WIDTH-1:0]		  badvaddr;
   
   output logic [4:0]			  cause;
   output logic [7:0]			  cause_ip;
   output logic [2:0]			  dbg_frozen; /* {r_bp_hit, r_wp_hit, r_fault_hit} -- real freeze vs stall */
   output logic [31:0]			  dbg_wp_data; /* the DATA of the last store to bp_wp_addr (exact store value) */
   output logic [7:0]			  asid;
   output tlb_data_t		          tlb_entry_out;
   output logic				  tlb_entry_out_valid;
   output logic				  took_irq;
   output logic [31:0]			  cp0_count;
   
   
   output logic				  l1i_flush_done;
   output logic				  l1d_flush_done;
   output logic				  l2_flush_done;

   output logic [31:0]			  dbg_head_pc;
   output logic [31:0]			  dbg_head_status;
   output logic [31:0]			  dbg_head_fetch_cycle;
   output logic [31:0]			  dbg_head_alloc_cycle;
   output logic [31:0]			  dbg_serialize_cycle;
   output logic [31:0]			  dbg_cycle;
   output logic				  dbg_oldest_first_pending;
   input logic [19:0] dbg_trace_index;
   output logic [31:0] 			  dbg_trace_data;
   output logic [15:0] 			  dbg_trace_wptr;
   /* Reader-agreement checker status, read on AXI 0x1B.
    *   [0]    hit      -- a reader disagreed with its producer.  Needed because
    *                     w_null_target ORs EIGHT triggers into one frozen bit, so
    *                     `frozen' alone cannot say which fired.
    *   [1]    degraded -- the record FIFO overflowed, so some candidate reads went
    *                     unchecked.  Coverage is all-or-nothing by construction,
    *                     so this one bit IS the coverage story: degraded=0 means
    *                     every candidate read was checked.
    *   [31:2] checked  -- low bits of the check count; not needed for coverage,
    *                     carried as proof-of-life so a quiet board can be told
    *                     apart from a checker that never ran. */
   output logic [31:0] 			  dbg_rdchk;

   assign in_64b_kernel_mode     = w_in_64b_kernel_mode;
   assign in_64b_supervisor_mode = w_in_64b_supervisor_mode;
   assign in_64b_user_mode       = w_in_64b_user_mode;

   wire				w_in_64b_mode;
   generate
      if(`M_WIDTH==64)
	begin
	   assign w_in_64b_mode = w_in_64b_kernel_mode | 
				  w_in_64b_user_mode | 
				  w_in_64b_supervisor_mode;
	end
      else
	begin
	   assign w_in_64b_mode =1'b0;
	end
   endgenerate

   wire					  w_in_64b_kernel_mode;
   wire					  w_in_64b_supervisor_mode;
   wire					  w_in_64b_user_mode;
   wire					  w_cu1;   /* Status.CU1 (FPU enable) from exec -> decode CP1 CpU gate */
   wire					  w_fr;    /* Status.FR (FP reg mode) from exec -> decode FR=0 odd-reg gate */
   wire					  w_irq_pending;
   wire [31:0]				  w_cp0_count;
   
   
   logic [`M_WIDTH-1:0]			  r_epc, n_epc;
   logic [`M_WIDTH-1:0]			  r_badvaddr, n_badvaddr;   
   wire [`M_WIDTH-1:0]			  w_exec_epc;
   
   wire					  w_sr_bev;
   wire					  w_sr_exl;

   
   logic				  r_exc_in_delay, n_exc_in_delay;
   
   
   localparam N_PRF_ENTRIES = (1<<`LG_PRF_ENTRIES);
   localparam N_ROB_ENTRIES = (1<<`LG_ROB_ENTRIES);
   localparam N_UQ_ENTRIES = (1<<`LG_UQ_ENTRIES);
   localparam N_HILO_ENTRIES = (1<<`LG_HILO_PRF_ENTRIES);
   localparam N_FCR_ENTRIES = (1<<`LG_FCR_PRF_ENTRIES);

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
   
   /* ROB banked even/odd by rob_ptr[0] (rv64core scheme): alloc writes 2 consecutive
    * entries (tail, tail+1) which always differ in bit0 -> one to each bank, so each
    * bank sees a single alloc write (instead of 2 write ports on one wide array).
    * Retire reads head + head+1 -> one from each bank.  Bank index = rob_ptr[hi:1]. */
   rob_entry_t r_rob_even[(N_ROB_ENTRIES/2)-1:0];
   rob_entry_t r_rob_odd[(N_ROB_ENTRIES/2)-1:0];
   logic [`M_WIDTH-1:0 ] r_addrs[N_ROB_ENTRIES-1:0];
   /* FP IEEE flags side-band (1W at FP completion / 2R at retire), mirroring
    * r_addrs: {denorm(E), V,Z,O,U,I} of each completed FP op, indexed by ROB ptr.
    * Read at retire to update FCSR.Cause/Flags (gated by the fp_set_flags bit). */
   logic [5:0] 		 r_fp_flags[N_ROB_ENTRIES-1:0];

   
   logic [N_ROB_ENTRIES-1:0] 		  r_rob_complete;
   logic [N_ROB_ENTRIES-1:0] 		  r_rob_sd_complete;

   logic 				  t_core_store_data_ptr_valid;
   logic [`LG_ROB_ENTRIES-1:0] 		  t_core_store_data_ptr;
 		  
   logic 				  t_rob_head_complete, t_rob_next_head_complete;
   
   
   logic [N_ROB_ENTRIES-1:0] 		  r_rob_inflight, r_rob_dead_insns;
   logic [N_ROB_ENTRIES-1:0] 		  t_clr_mask;
   
   rob_entry_t t_rob_head, t_rob_next_head, t_rob_tail, t_rob_next_tail;

   logic [N_PRF_ENTRIES-1:0] n_prf_free, r_prf_free;
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

   /* ---- FP rename domain: mirrors the integer domain (32 arch FP regs). ----
    * FR=1 / N32 model (32 full 64-bit regs, no even/odd arch pairing yet).
    * One FP dst alloc per cycle (dual-FP-dst is serialized via t_enough_next_fprfs). */
   logic [N_PRF_ENTRIES-1:0]        n_fp_prf_free, r_fp_prf_free;
   logic [N_PRF_ENTRIES-1:0]        n_retire_fp_prf_free, r_retire_fp_prf_free;
   logic [`LG_PRF_ENTRIES-1:0]      r_fp_alloc_rat[31:0];
   logic [`LG_PRF_ENTRIES-1:0]      n_fp_alloc_rat[31:0];
   logic [`LG_PRF_ENTRIES-1:0]      r_fp_retire_rat[31:0];
   logic [`LG_PRF_ENTRIES-1:0]      n_fp_retire_rat[31:0];
   logic [`LG_PRF_ENTRIES-1:0]      n_fp_prf_entry;
   logic [`LG_PRF_ENTRIES:0]        t_fp_ffs0, t_fp_ffs1;   // bank0 (fpu) / bank1 (mem) free ptr
   logic 			   t_fp_b0_full, t_fp_b1_full;
   logic 			   w_fp_dst_is_mem;
   wire [N_PRF_ENTRIES-1:0] 	   w_fp_free_b0, w_fp_free_b1;
   logic 			   t_enough_fprfs, t_enough_next_fprfs;
   logic 			   t_free_fp_reg, t_free_fp_reg_two;
   logic [`LG_PRF_ENTRIES-1:0]      t_free_fp_reg_ptr, t_free_fp_reg_two_ptr;

   /* ---- FCR rename domain (FP condition-code byte): scalar, mirrors HI/LO. ----
    * One arch FCR; a compare RMWs it (read old via fcr_src, write new via fcr_dst).
    * The FCR phys-reg ptr is carried in the uop hilo_src/hilo_dst fields and in the
    * rob pdst/old_pdst fields (truncated to LG_FCR_PRF_ENTRIES), exactly like HI/LO. */
   logic [N_FCR_ENTRIES-1:0]        n_fcr_prf_free, r_fcr_prf_free;
   logic [N_FCR_ENTRIES-1:0]        n_retire_fcr_prf_free, r_retire_fcr_prf_free;
   logic [`LG_FCR_PRF_ENTRIES-1:0]  r_fcr_alloc_rat, n_fcr_alloc_rat;
   logic [`LG_FCR_PRF_ENTRIES-1:0]  r_fcr_retire_rat, n_fcr_retire_rat;
   logic [`LG_FCR_PRF_ENTRIES-1:0]  n_fcr_prf_entry;
   logic [`LG_FCR_PRF_ENTRIES:0]    t_fcr_ffs;
   logic 			   t_enough_fcrprfs, t_enough_next_fcrprfs;
   logic 			   t_free_fcr;
   logic [`LG_FCR_PRF_ENTRIES-1:0]  t_free_fcr_ptr;

   /* FCSR (FCR31) Cause/Flags update -> exec (internal), driven at retire/fault */
   logic			   core_fcsr_we;
   logic [5:0]			   core_fcsr_cause6;
   logic [4:0]			   core_fcsr_flags5;

   logic [N_ROB_ENTRIES-1:0] 	    uq_wait, mq_wait, fp_uq_wait;
   

   
   
   logic 		     t_alloc, t_alloc_two, t_retire, t_retire_two,
			     t_rat_copy, t_clr_rob;

   logic 		     t_possible_to_alloc;
   
   
   logic 		     t_fold_uop, t_fold_uop2;
   
   logic 		     n_in_delay_slot, r_in_delay_slot;
   
   logic 		     t_clr_dq;
   logic [`M_WIDTH-1:0]   r_last_branch_target;  /* resolved target of last retired branch (Case 2) */
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
   
   logic [31:0] 	     r_arch_a0;

   logic [4:0] 		     n_cause, r_cause;
   logic [1:0] 		     n_ce, r_ce;   /* Cause.CE for a CpU (1=CP1/FPU, else 0) */
   logic		     r_tlb_refill, n_tlb_refill;
   logic		     r_xtlb_refill, n_xtlb_refill;
   logic		     n_save_to_tlb_regs, r_save_to_tlb_regs;
   logic		     n_has_badvaddr,r_has_badvaddr;
   
   
   
   complete_t t_complete_bundle_1;
   logic 		     t_complete_valid_1;
   /* 2nd completion port: FP pipe (fpu) completes here, in parallel with port 1.
    * Ports 1 and 2 always carry distinct rob_ptrs (an insn completes on exactly
    * one port), so the banked rob writes below never collide. */
   complete_t t_complete_bundle_2;
   logic 		     t_complete_valid_2;
   
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
   wire [N_PRF_ENTRIES-1:0]  w_alu_even, w_alu_odd, w_mem_even, w_mem_odd;
   wire 		     w_alu_even_full, w_alu_odd_full, w_mem_even_full, w_mem_odd_full;
   wire [`LG_PRF_ENTRIES:0]  w_ffs_alu_even, w_ffs_alu_odd, w_ffs_mem_even, w_ffs_mem_odd;
   
   logic 		     t_uq_full, t_uq_next_full;
   
   logic 		     t_uq_read;
   logic 		     n_ready_for_resume, r_ready_for_resume;
   
   
   mem_req_t t_mem_req;
   logic 		     t_mem_req_valid;

   logic 		     n_machine_clr, r_machine_clr;
   logic r_post_restart_arm;  /* arms at RAT->ACTIVE restart edge, stamps first alloc, disarms */
   logic 		     n_flush_req_l1d, r_flush_req_l1d;
   logic 		     n_flush_req_l1i, r_flush_req_l1i;
   
   logic 		     n_flush_cl_req, r_flush_cl_req;
   logic [(`M_WIDTH-1):0]    n_flush_cl_addr, r_flush_cl_addr;
   logic 		     n_flush_cl_inval, r_flush_cl_inval;
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
			     CACHE_FLUSH = 'd14, // serializing CACHE op: nuke L1I/L1D/L2, then restart
			     DEAD = 'd15
			     } state_t;
   
   state_t r_state, n_state;
   logic 	r_pending_fault, n_pending_fault;
   logic        r_oldest_first_pending, n_oldest_first_pending;
   
   /* single-step: one architectural commit per 0->1 edge on `step` */
   logic        r_step_d, r_step_credit, n_step_credit;
   logic	r_single_step;
   wire         w_step_edge = step & ~r_step_d;

`ifdef ENABLE_DEBUG_WATCHPOINT
   // On-silicon HW breakpoint + store value+address watchpoint + fault-trap. Gated OFF
   // by default; henry binds bp_pc/bp_wp_x/fault_clear/dbg_frozen/dbg_wp_data
   // unconditionally, so when the guard is off the outputs tie to 0 (else branch) and no
   // compare logic is generated. Retiring insn matching bp_pc, or a store of bp_wp_val to
   // bp_wp_addr, latches r_bp_hit/r_wp_hit and freezes the core so GPRs/DRAM read coherent.
   // bp_pc/bp_wp_x are driver-programmable (slv_reg9-11), no re-synth.
   logic	r_bp_hit;
   /* fault_clear (ctrl bit18) doubles as bp resume: clears r_bp_hit so the core runs
    * full-speed to the NEXT bp_pc match (re-latches next hit). */
   /* bp_fault_only: freeze the pipe on a FAULT at bp_pc (the ROB head always carries the fault,
    * see t_arch_fault); else the classic retire-match.  A hot bp_pc that usually RETIRES would
    * freeze on every normal pass under retire-match -- fault-only waits for the rare crash. */
   wire		w_bp_match = bp_enable &
		(bp_fault_only
		 ? (t_arch_fault & (t_rob_head.pc[31:0] == bp_pc))
		 : ((t_retire     & (t_rob_head.pc[31:0]      == bp_pc)) |
		    (t_retire_two & (t_rob_next_head.pc[31:0] == bp_pc))));

   /* STORE value+address WATCHPOINT (rob_ptr-correlated).  The store ADDRESS (VA) rides
    * t_mem_req (with rob_ptr); the store DATA arrives later on core_store_data (same
    * rob_ptr, decoupled through the mem-data queue).  On a store whose VA==bp_wp_addr,
    * remember its rob_ptr; when that rob_ptr's data arrives and equals bp_wp_val, FREEZE
    * -- i.e. freeze on the store that writes the CORRUPT value to the watched slot,
    * whichever instruction did it. */
   logic	r_wp_hit;
   logic	r_wp_pending;
   logic [`LG_ROB_ENTRIES-1:0] r_wp_robptr;
   logic [31:0]	r_wp_data;
   assign dbg_wp_data = r_wp_data;
   /* fault-only mode wants ONLY the fault-at-bp_pc freeze: suppress the store watchpoint too
    * (else a store matching a reset/stale bp_wp_addr spuriously freezes retirement -> boot hang). */
   /* PC+THRESHOLD store watchpoint -- the IRIX `be` small-int-in-a-pointer-field BIRTH catch
    * (2026-07-26).  The corrupt struct-field ADDRESS is nondeterministic heap, so we can't preset
    * bp_wp_addr to it; instead key on the store's PC (bp_wp_addr repurposed = producer PC, e.g.
    * 0f377124 `sw r21,0x1c(r17)`) and freeze when its DATA is SMALL (< bp_wp_val, e.g. 0x01000000)
    * -- a small int where a heap pointer belongs.  mem_req_t.pc is un-guarded for synth. */
   wire		w_wp_addr_match = bp_enable & ~bp_fault_only & t_mem_req_valid & t_mem_req.is_store &
		(t_mem_req.pc[31:0] == bp_wp_addr);
   wire		w_wp_data_here  = r_wp_pending & core_store_data_valid &
		(core_store_data.rob_ptr == r_wp_robptr);
   /* freeze when the store DATA is a small int (below bp_wp_val threshold) = the corruption. */
   wire		w_wp_match      = w_wp_data_here & (core_store_data.data[31:0] < bp_wp_val);

   /* resettable fault-trap: while armed (bp_enable), the FIRST fatal USERSPACE arch-fault
    * (AdEL/AdES/IBE/DBE, EPC in useg) latches {epc,cause,badvaddr} + sets r_fault_hit,
    * which folds into w_step_ok to FREEZE so the ARM can read a coherent fault state (the
    * latched taps override the live outputs below).  fault_clear clears + re-arms. */
   logic		r_fault_hit;
   logic [`M_WIDTH-1:0] r_fault_epc, r_fault_badv;
   logic [4:0]	r_fault_cause;
   /* RI (cause 10) is deliberately NOT here: this kernel emulates RDHWR via the RI
    * handler, so userspace takes an RI on every TLS access -- ~1600 per 10M instrs
    * measured on the binutils workload.  Including it latched the trap milliseconds
    * into the run and made bp_enable unusable (arming bp_pc also arms this trap).
    * The remaining causes -- AdEL/AdES/IBE/DBE -- do not occur in healthy userspace,
    * so they are a real corruption signature. */
   wire		w_fatal_cause = (n_cause == 5'd4) | (n_cause == 5'd5) | (n_cause == 5'd6) |
		(n_cause == 5'd7) | (n_cause == 5'd10);
   /* in fault-only mode the pipe freeze comes from w_bp_match (fault AT bp_pc); suppress the
    * general fatal-fault trap so routine cause-4/5 emulation faults elsewhere don't freeze. */
   wire		w_fault_match = bp_enable & ~bp_fault_only & ~r_fault_hit & t_arch_fault & w_fatal_cause & ~n_epc[31];

   /* this gets consumed by retirement logic */
   wire		w_step_ok   = (r_single_step | r_bp_hit | r_wp_hit | r_fault_hit) ? (t_step_edge) : 1'b1;
   assign dbg_frozen = {r_bp_hit, r_wp_hit, r_fault_hit};
`else
   /* debug watchpoint/fault-trap compiled out -- ports tied off, no compare logic generated */
   wire		w_step_ok   = r_single_step ? (t_step_edge) : 1'b1;
   assign dbg_frozen  = 3'd0;
   assign dbg_wp_data = 32'd0;
`endif

   logic	n_step_last, r_step_last, t_step_edge;
   always_comb
     begin
	n_step_last = r_step_last;
	t_step_edge = 1'b0;
	if(r_step_last & (step == 1'b0))
	  begin
	     n_step_last = 1'b0;
	  end
	else if((r_step_last == 1'b0) & (step == 1'b1))
	  begin
	     n_step_last = 1'b1;
	     t_step_edge = 1'b1;
	  end
     end // always_comb


   always_ff@(posedge clk)
     begin
	r_step_last <= reset ? 1'b0 : n_step_last;
	r_single_step <= reset ? 1'b0 : single_step;
`ifdef ENABLE_DEBUG_WATCHPOINT
	r_bp_hit <= reset ? 1'b0 : (fault_clear ? 1'b0 : (r_bp_hit | w_bp_match));
	r_wp_hit <= reset ? 1'b0 : (fault_clear ? 1'b0 : (r_wp_hit | w_wp_match));
	if(reset)
	  r_wp_data <= 32'd0;
	else if(w_wp_data_here)
	  r_wp_data <= core_store_data.data[31:0];   /* exact data of the store to bp_wp_addr */
	/* single pending slot: remember the rob_ptr of a store to bp_wp_addr, cleared when
	 * its data arrives (or on fault_clear).  A newer match overwrites -- fine, since we
	 * only care about the store carrying the corrupt value bp_wp_val. */
	if(reset)
	  begin
	     r_wp_pending <= 1'b0;
	     r_wp_robptr  <= '0;
	  end
	else if(fault_clear)
	  begin
	     r_wp_pending <= 1'b0;
	  end
	else if(w_wp_addr_match)
	  begin
	     r_wp_pending <= 1'b1;
	     r_wp_robptr  <= t_mem_req.rob_ptr;
	  end
	else if(w_wp_data_here)
	  begin
	     r_wp_pending <= 1'b0;
	  end
`endif
     end

`ifdef ENABLE_DEBUG_WATCHPOINT
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_fault_hit   <= 1'b0;
	     r_fault_epc   <= 'd0;
	     r_fault_badv  <= 'd0;
	     r_fault_cause <= 5'd0;
	  end // if (reset)
	else if(fault_clear)
	  begin
	     r_fault_hit <= 1'b0;   /* clear + re-arm; latched values held until the next hit */
	  end
	else if(w_fault_match)
	  begin
	     r_fault_hit   <= 1'b1;
	     r_fault_epc   <= n_epc;
	     r_fault_badv  <= n_badvaddr;
	     r_fault_cause <= n_cause;
	  end // if (w_fault_match)
     end // always_ff@ (posedge clk)
`endif

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
   /* Fix A (uncached-delay-slot deadlock): a REGULAR (non-nullifying) delay slot
    * of a COMPLETE, FAULTED (mispredicted) branch at the ROB head is guaranteed to
    * commit -- the branch has no execute-stage exception and nothing older can
    * squash it, so the delay slot is non-speculative even though the branch has not
    * retired yet.  l1d uses this to let a delay-slot UNCACHED op (e.g. the ip22
    * eeprom store behind a mispredicted `jr ra`) issue to the device; otherwise the
    * branch's retire gate (waits for delay-slot complete) and the uncached issue
    * gate (waits for at-head/drain) deadlock.  next_head_of_rob_ptr IS the delay
    * slot (the ROB entry right after the head). */
   assign next_head_of_rob_ptr = r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0];
   assign head_of_rob_ds_committable = w_rob_head_complete
					 & t_rob_head.faulted
					 & t_rob_head.has_delay_slot
					 & ~t_rob_head.has_nullifying_delay_slot;
				      
   assign flush_req_l1d = r_flush_req_l1d;
   assign flush_req_l1i = r_flush_req_l1i;
   assign flush_cl_req = r_flush_cl_req;
   assign flush_cl_addr = r_flush_cl_addr;
   assign flush_cl_inval = r_flush_cl_inval;

   
   assign got_break = r_got_break;
   assign got_ud = r_got_ud;
   assign got_bad_addr = r_got_bad_addr;
`ifdef ENABLE_DEBUG_WATCHPOINT
   /* when the fault-trap is frozen, expose the LATCHED fault state on the live taps
    * so the ARM reads a stable {epc,cause,badvaddr} (not clobbered by the handler). */
   assign epc      = r_fault_hit ? r_fault_epc   : r_epc;
   assign badvaddr = r_fault_hit ? r_fault_badv  : r_badvaddr;
   assign cause    = r_fault_hit ? r_fault_cause : r_cause;
`else
   assign epc = r_epc;
   assign badvaddr = r_badvaddr;
   assign cause = r_cause;
`endif

   assign dbg_head_pc              = t_rob_head.pc[31:0];
   /* why is the head stuck? read-only debug packing of existing head signals.
    * [0] rob_empty (stall is upstream/fetch, not the head)
    * [1] head_complete (head done but not retiring => retire-gate blocked)
    * [2] can_retire   [3] faulted
    * [4] has_delay_slot  [5] has_nullifying_delay_slot
    * [6] next_head_complete  [7] decode-queue empty */
   assign dbg_head_status = { 24'd0,
			      t_dq_empty,
			      w_rob_next_head_complete,
			      t_rob_head.has_nullifying_delay_slot,
			      t_rob_head.has_delay_slot,
			      t_rob_head.faulted,
			      t_can_retire_rob_head,
			      w_rob_head_complete,
			      w_rob_empty };
`ifdef ENABLE_CYCLE_ACCOUNTING
   assign dbg_head_fetch_cycle     = t_rob_head.fetch_cycle[31:0];
   assign dbg_head_alloc_cycle     = t_rob_head.alloc_cycle[31:0];
`else
   assign dbg_head_fetch_cycle     = 'd0;
   assign dbg_head_alloc_cycle     = 'd0;
`endif
   assign dbg_serialize_cycle      = r_serialize_cycle;
   assign dbg_cycle                = r_cycle[31:0];
   assign dbg_oldest_first_pending = r_oldest_first_pending;
`ifdef GHOST_DEBUG
   always_ff@(negedge clk)
     begin
	if(t_retire & t_rob_head.faulted & (r_state == ACTIVE))
	  $display("[flt-retire] cyc=%d pc=%x head=%d has_ds=%b nds=%b", r_cycle, t_rob_head.pc, r_rob_head_ptr, t_rob_head.has_delay_slot, n_ds_done);
	if((r_state == DRAIN) | (r_state == RAT))
	  $display("[st] cyc=%d st=%d head=%d hv=%b ds=%b ret=%b hpc=%x", r_cycle, r_state, r_rob_head_ptr, head_of_rob_ptr_valid, r_ds_done, t_retire, t_rob_head.pc);
     end
`endif

   /* NULL-TARGET FREEZE.  A jump to VA 0 is architecturally legal but is
    * essentially never correct: the 2026-08-24 Linux oops was exactly that -- a
    * JALR that RETIRED with target 0 (epc=0, BadVA=0, ra=__split_vma+0x1a0).
    * Detecting it HERE instead of waiting for the kernel oops is what makes the
    * retire ring usable: the oops does not halt the machine, so the 256-entry
    * ring wraps in microseconds and the evidence is gone.  Freezing on the
    * event keeps the offending JALR and everything before it resident.
    *
    * Catches BOTH zero and BTB_POISON_PC, and the two mean different things:
    * poison => a COLD/INVALID BTB entry reached retire (the predictor made it);
    * zero   => a genuine NULL pointer in the program.  Without the poison split
    * these are indistinguishable, which is why the 2026-08-24 dump could not
    * say whether the predictor or the data was at fault.
    *
    * r_trace_frozen is a flop, so the triggering retire record is still written
    * this cycle and only later writes are suppressed.  Sticky until reset. */
   /* MUST check BOTH retire slots: the machine retires two per cycle, and an
    * indirect that commits in the SECOND slot (t_retire_two / t_rob_next_head)
    * would otherwise never be seen -- a detector that is structurally unable to
    * report the event it exists for. */
   /* COMMIT = either head-advance path (`if(t_retire || t_bump_rob_head)`, the
    * ROB free logic).  A MISPREDICTED branch asserts BOTH (measured: retire=1
    * bump=1 at the jalr commit), so t_retire alone was in fact sufficient for
    * the is_indirect triggers -- verified by directed test, and NOT the reason
    * the ring failed to freeze on 2026-08-27.  What t_retire cannot see is an
    * ARCH-FAULT commit: t_retire = t_rob_head_complete & !t_arch_fault, so a
    * faulting entry commits via t_bump_rob_head with t_retire LOW.  That is
    * what w_null_pc_head below needs, and it also puts the fault records --
    * the crash evidence -- into the ring instead of dropping them. */
   wire 	      w_head_commit = t_retire | t_bump_rob_head;
   wire 	      w_null_tgt_head = w_head_commit & t_rob_head.is_indirect &
				        ((t_rob_head.target_pc == 'd0) |
					 (t_rob_head.target_pc == `BTB_POISON_PC));
   wire 	      w_null_tgt_two  = t_retire_two & t_rob_next_head.is_indirect &
				        ((t_rob_next_head.target_pc == 'd0) |
					 (t_rob_next_head.target_pc == `BTB_POISON_PC));
   /* THE CRASH ITSELF, not one way of causing it.  On 2026-08-27 the board
    * took the __split_vma oops (epc=0, cause 2) and the ring did NOT freeze,
    * with the ring provably live -- so the transfer to 0 was NOT a committed
    * indirect with target 0.  The is_indirect triggers above are structurally
    * blind to an ERET into a corrupted EPC, or to any bad restart_pc.  An entry
    * FETCHED from 0 reaching commit catches all of them: the faulting entry
    * carries pc==0 and commits via t_bump_rob_head (t_retire is LOW on an arch
    * fault), which is why this needs w_head_commit and not t_retire. */
   wire 	      w_null_pc_head = w_head_commit & (t_rob_head.pc == 'd0);
   /* WILD RESTART -- the trigger that cannot be blind to the route taken.
    * Fires on ANY restart into the null page, which covers every way the core
    * can architecturally arrive at pc 0: a mispredicted branch resolving to 0
    * (target_pc), a faulted delay slot restarting through a stale
    * r_last_branch_target, and an ERET into a corrupted EPC (resume_pc).  The
    * is_indirect triggers above see only the first of those, which is why they
    * stayed silent through the 2026-08-27 oops.  This is the silicon twin of
    * the sim-only `if(n_epc < 'd1000) $stop()` in the arch-fault path: the null
    * page is never mapped, so a restart into it is always a bug.  Reading
    * n_restart_* here is safe -- w_null_target is consumed only by always_ff
    * (a comb read would form a t_bump_rob_head/t_retire UNOPTFLAT loop). */
   wire 	      w_wild_restart = n_restart_valid &
				       (n_restart_pc[(`M_WIDTH-1):12] == 'd0);
   /* KERNEL NULL-PAGE FAULT.  The four kernel-mode events (__split_vma,
    * filp_flush x2, __get_unmapped_area) all reached PC=0 yet tripped NONE of the
    * triggers above -- so whatever takes the kernel to 0 is not a committed
    * indirect resolving to 0, and w_null_pc_head did not fire either.  Rather than
    * keep guessing at the route, trigger on the CONSEQUENCE: an arch fault taken
    * in kernel mode whose BadVA is in the never-mapped null page.  A kernel-mode
    * access to page 0 is always a bug, and ordinary user demand-paging cannot trip
    * it (that faults in user mode), so this cannot fire on normal activity.
    * Consumed only by always_ff below -- reading n_* in a comb block that assigns
    * them would form an UNOPTFLAT loop. */
   wire 	      w_kernel_null_fault = t_bump_rob_head & in_kernel_mode &
					    (n_badvaddr[(`M_WIDTH-1):12] == 'd0) &
					    ((n_cause == 5'd2) | (n_cause == 5'd3));
   /* WILD EPC -- the actual silicon twin of the pre-existing sim assertion
    * `if(n_epc < 'd1000) $stop()` in the arch-fault path.
    *
    * WHY this and not the others: all FOUR kernel events (__split_vma,
    * filp_flush x2, anon_pipe_read) report epc=0, yet NO trigger that detects a
    * real path to PC 0 ever fires -- not a committed indirect with target 0, not
    * a restart into the null page, and not a ROB entry committing with pc==0
    * (which DOES fire in sim for a genuine null jump).  The consistent reading is
    * that the kernel never executes at 0 at all and the EXCEPTION STATE is what
    * is wrong -- which would also explain ra values matching no call site in the
    * faulting function.  So trigger on the EPC being written wild, regardless of
    * how control got there. */
   /* ARMING GATE: at reset the ROB arrays are uninitialised (BRAM reads 0 on
    * FPGA), so n_epc computes as 0 and this fires during boot firmware -- observed
    * on 6d1f30fc, frozen at wptr=38 with the ring still showing 0xbfc000xx.  Arm
    * only after the machine is well past reset.  Default is small enough for the
    * directed sim test (which faults at ~16.7k cycles); silicon overrides it via
    * SV2V_DEFINES with a value far past boot. */
   /* Arm the wild-EPC trigger on the first USER-mode retire, not on a cycle count.
    * The old `WILD_EPC_ARM_CYCLES 10000` arm fired during the FSBL -- which runs
    * legitimately with EPC=0 -- so the trigger tripped at boot and latched the ring
    * shut at wptr=38 before the workload started.  v5, v6 and 5004523d were all
    * blinded this way, and 5004523d soaked for hours past three real userspace
    * SIGSEGVs (one with epc=0) without recording a single retire.  Arming on the
    * first user-mode commit is workload-relative, so it cannot race the firmware. */
   logic 	      r_wild_epc_armed;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_wild_epc_armed <= 1'b0;
	  end
	else
	  begin
	     if(w_head_commit & !in_kernel_mode)
	       begin
		  r_wild_epc_armed <= 1'b1;
	       end
	  end
     end // always_ff

   wire 	      w_wild_epc = t_bump_rob_head & (n_epc[(`M_WIDTH-1):12] == 'd0) &
				   r_wild_epc_armed;
   /* USER-MODE BREAKPOINT EXCEPTION (ExcCode 09) -- the SIGFPE face of the bug.
    * A userspace `break 0x7' (the compiler's divide-by-zero guard) firing where it
    * is UNREACHABLE.  Captured TWICE on 03702fef (2026-09-06, both in `wc',
    * epc 0x40801c) with IDENTICAL operands t2=28 a3=10, and BOTH times the ring
    * did not freeze: every trigger above keys on reaching PC 0 / a null restart /
    * a wild EPC, and a break trap is none of those.  Two evidence windows lost.
    * TRADE-OFF: a break CAN fire legitimately (a real divide by zero) and the
    * freeze is sticky until the PL is reprogrammed, so a false trigger blinds the
    * board.  Accepted -- the soak workload has no legitimate div-by-zero.
    * USER mode only: the kernel's BUG()/BRK paths use break legitimately. */
   wire 	      w_user_break = t_bump_rob_head & (~in_kernel_mode) &
				     (n_cause == 5'd9);
   /* Reader-agreement violation (exec.sv, ENABLE_RDAGREE_HW): two readers of the
    * same INSTANCE of a physical register saw different values.  That is
    * impossible in a correct machine -- a physreg is written once per allocation
    * -- and it is the microarchitectural EVENT rather than its rare
    * architectural consequence, so it fires far sooner than a wild jump or a
    * break trap does.  Sticky in exec; folding it in here freezes the ring and
    * shows up on the board as frozen=1 in the existing dbg_trace_wptr readback,
    * with no new AXI register and no IP re-package. */
   wire 	      w_rdchk_hit;
   wire 	      w_rdchk_stall;

`ifdef ENABLE_RDCHK
   /* ============ RETIRE-TIME READER-AGREEMENT CHECK ============
    * Every reader of a given INSTANCE of a physical register must see the same
    * value.  Each reader is compared against the value its PRODUCER logged when
    * IT retired -- strictly stronger than reader-vs-reader (it also catches a
    * lone stale reader), and at retire it is free of every hazard the
    * execute-side version had: retire is IN ORDER, mis-speculated readers never
    * retire, and nothing here is near the operand path.
    *
    * SERIALIZED FRONT END.  Peak demand is 2 writes + 4 reads per cycle (two
    * retire slots x {srcA,srcB}) against a 2-port table -- direct issue measured
    * only 57.1% coverage (3498 checked / 2623 dropped over 8 randgen seeds).  So
    * retire records are pushed into an IN-ORDER FIFO and drained at up to 2
    * accesses/cycle: <=2 cycles per record, ~0.5 records/cycle throughput against
    * ~0.31 actual (IPC).  Full coverage, and the FIFO absorbs dual-retire bursts.
    *
    * Serializing also DELETES a hazard rather than adding one.  Draining in
    * retire order means a producer's write is always processed before any later
    * consumer's check, so the same-cycle dual-retire bypass that v1 needed (and
    * whose absence caused 6000 false positives across 24 seeds) cannot arise:
    * within a record dst is a freshly-allocated physreg and never one of its own
    * sources, and across records the write lands a cycle before the next read.
    *
    * OVERFLOW is never silently dropped -- losing a WRITE would leave a stale
    * entry and manufacture false positives later.  It sets a sticky degraded
    * flag instead, so a quiet result can be distinguished from a blind one.
    * ==================================================================== */
   logic [1:0] 	  t_ck_v;
   logic [1:0] 	  t_ck_pool [1:0];
   logic [`M_WIDTH-1:0]   t_ck_exp [1:0];

   /* ---- storage: mirror the machine's OWN four-way physreg partition ----
    * The allocator already splits the free list {alu,mem} x {even,odd} and gives
    * the two alloc slots OPPOSITE parity, rotating which slot gets which every
    * cycle (r_bank_sel <= ~r_bank_sel).  ALU vs MEM is disjoint by design -- it is
    * the same MSB split rf4r2w uses for its two write ports.  So pool =
    * {ptr[MSB], ptr[0]} costs nothing to compute and buys 4 write + 4 read ports
    * out of four 32-entry memories, which finally exceeds the 2W+4R worst case.
    * Each pool is 32 x 65: small enough for distributed RAM (~65 LUTs as
    * RAM32X1D) rather than BRAM, which matters at 82.8% LUT utilisation. */
   localparam LG_NF   = 5;
   localparam N_F     = (1<<LG_NF);
   localparam RGRPW   = 1 + `LG_PRF_ENTRIES + `M_WIDTH;
   localparam RECW    = 3*RGRPW;
   localparam PIDXW   = `LG_PRF_ENTRIES-2;          /* 5 -> 32 entries per pool */

   logic [`M_WIDTH:0] 	  r_pt0 [(1<<PIDXW)-1:0];
   logic [`M_WIDTH:0] 	  r_pt1 [(1<<PIDXW)-1:0];
   logic [`M_WIDTH:0] 	  r_pt2 [(1<<PIDXW)-1:0];
   logic [`M_WIDTH:0] 	  r_pt3 [(1<<PIDXW)-1:0];
   logic [`M_WIDTH:0] 	  r_q0, r_q1, r_q2, r_q3;

   logic [3:0] 		  t_we, t_re;
   logic [PIDXW-1:0] 	  t_wa0, t_wa1, t_wa2, t_wa3;
   logic [PIDXW-1:0] 	  t_ra0, t_ra1, t_ra2, t_ra3;
   logic [`M_WIDTH:0] 	  t_wd0, t_wd1, t_wd2, t_wd3;

   /* EVEN/ODD BANKED record FIFO.  A dual retire pushes indices ft and ft+1,
    * which have OPPOSITE parity, so banking on index[0] gives each bank exactly
    * ONE write port.  That matters: distributed RAM (RAM32X1D) is a synchronous
    * WRITE with an ASYNCHRONOUS read, so the async read below is fine -- it was
    * the second write port that made it uninferable.  Unbanked, Vivado said
    * "[Synth 8-4767] Trying to implement RAM 'r_fifo_reg' in registers ...
    * dissolved into registers" and the 32x216 array cost +9839 FF and +15370 LUT
    * (101.5% of the device -- the placer could not fit it).  Same trick the
    * allocator and the four producer-table pools already use. */
   logic [RECW-1:0] 	  r_fifo0 [(N_F/2)-1:0];
   logic [RECW-1:0] 	  r_fifo1 [(N_F/2)-1:0];
   logic 		  t_fwe0, t_fwe1;
   logic [LG_NF-2:0] 	  t_fwa0, t_fwa1;
   logic [RECW-1:0] 	  t_fwd0, t_fwd1;
   logic [LG_NF:0] 	  r_fh, r_ft;
   logic [RECW-1:0] 	  r_cur;
   logic 		  r_busy;
   logic 		  r_rdchk_hit, r_rdchk_degraded;
   logic [31:0] 	  r_rdchk_checked;
`ifdef VERILATOR
   logic [31:0] r_pushed_reads, r_recs_in, r_recs_out, r_issued;
   /* diagnosis-only shadow of the record FIFO: the retiring reader's PC, plus
    * the physreg pointer each in-flight compare is against.  Lets a [RDCHK]
    * report name the instruction instead of just two values. */
   logic [`M_WIDTH-1:0] 	  r_fifo_pc [N_F-1:0];
   logic [`M_WIDTH-1:0] 	  r_cur_pc, r_ck_pc;
   logic [`LG_PRF_ENTRIES-1:0] 	  r_ck_ptr [1:0];
   logic [31:0] 		  r_maxocc, r_drops, r_hits, r_stallc;
`endif

   /* two in-flight compares, one per read that issued */
   logic [1:0] 		  r_ck_v;
   logic [1:0] 		  r_ck_pool [1:0];
   logic [`M_WIDTH-1:0]   r_ck_exp [1:0];

   function automatic [1:0] f_pool(input [`LG_PRF_ENTRIES-1:0] p);
      begin
	 f_pool = {p[`LG_PRF_ENTRIES-1], p[0]};
      end
   endfunction
   function automatic [PIDXW-1:0] f_idx(input [`LG_PRF_ENTRIES-1:0] p);
      begin
	 f_idx = p[`LG_PRF_ENTRIES-2:1];
      end
   endfunction

   function automatic [RECW-1:0] f_rec(input rob_entry_t e);
      begin
	 f_rec = { e.valid_dst, e.pdst, e.data,
		   (e.chk_vals_valid & e.srcA_rd), e.srcA_ptr, e.chk_srcA_val,
		   (e.chk_vals_valid & e.srcB_rd), e.srcB_ptr, e.chk_srcB_val };
      end
   endfunction

   wire w_push0 = w_head_commit;
   wire w_push1 = w_head_commit & t_retire_two;
   wire [LG_NF:0] w_fcnt   = r_ft - r_fh;
   wire 	  w_ffull  = (w_fcnt >= (N_F-2));
   /* Retire back-pressure trips EARLIER than the drop guard.  The ARCH_FAULT /
    * EXCEPTION_DRAIN t_bump_rob_head paths also commit a head, and they are NOT
    * gated by w_rt_stall -- one per exception, so a few slots of headroom above
    * the stall point is enough to keep them from ever reaching w_ffull. */
   wire 	  w_fnear  = (w_fcnt >= (N_F-6));
   wire 	  w_fempty = (r_fh == r_ft);

   wire [LG_NF-1:0] w_ft0 = r_ft[LG_NF-1:0];
   wire [LG_NF-1:0] w_ft1 = r_ft[LG_NF-1:0] + 1'd1;
   wire [LG_NF-1:0] w_fh0 = r_fh[LG_NF-1:0];
   wire [RECW-1:0]  w_fifo_out = w_fh0[0] ? r_fifo1[w_fh0[LG_NF-1:1]] : r_fifo0[w_fh0[LG_NF-1:1]];

   wire [RECW-1:0] w_rec = r_busy ? r_cur : w_fifo_out;
`ifdef VERILATOR
   wire [`M_WIDTH-1:0] w_rec_pc = r_busy ? r_cur_pc : r_fifo_pc[r_fh[LG_NF-1:0]];
`endif
   wire 	   w_rw  = w_rec[RECW-1];
   wire [`LG_PRF_ENTRIES-1:0] w_rwp = w_rec[RECW-2 -: `LG_PRF_ENTRIES];
   wire [`M_WIDTH-1:0] 	      w_rwd = w_rec[2*RGRPW +: `M_WIDTH];
   wire 	   w_ra  = w_rec[2*RGRPW-1];
   wire [`LG_PRF_ENTRIES-1:0] w_rap = w_rec[2*RGRPW-2 -: `LG_PRF_ENTRIES];
   wire [`M_WIDTH-1:0] 	      w_rav = w_rec[RGRPW +: `M_WIDTH];
   wire 	   w_rb  = w_rec[RGRPW-1];
   wire [`LG_PRF_ENTRIES-1:0] w_rbp = w_rec[RGRPW-2 -: `LG_PRF_ENTRIES];
   wire [`M_WIDTH-1:0] 	      w_rbv = w_rec[0 +: `M_WIDTH];

   /* a record needs a second cycle only when BOTH its sources live in the SAME
    * pool -- with four pools that is ~25% of the ~7% two-source records */
   wire w_need2 = w_ra & w_rb & (f_pool(w_rap) == f_pool(w_rbp));

   /* Decode the (at most) two pushes into ONE write per bank, so each bank
    * infers as a single-write-port distributed RAM.  Slot 0 goes to the bank
    * named by ft's parity, slot 1 to the other one. */
   always_comb
     begin
	t_fwe0 = 1'b0; t_fwe1 = 1'b0;
	t_fwa0 = 'd0;  t_fwa1 = 'd0;
	t_fwd0 = 'd0;  t_fwd1 = 'd0;
	if(~w_ffull)
	  begin
	     if(w_ft0[0] == 1'b0)
	       begin
		  t_fwe0 = w_push0;
		  t_fwa0 = w_ft0[LG_NF-1:1];
		  t_fwd0 = f_rec(t_rob_head);
		  t_fwe1 = w_push1;
		  t_fwa1 = w_ft1[LG_NF-1:1];
		  t_fwd1 = f_rec(t_rob_next_head);
	       end
	     else
	       begin
		  t_fwe1 = w_push0;
		  t_fwa1 = w_ft0[LG_NF-1:1];
		  t_fwd1 = f_rec(t_rob_head);
		  t_fwe0 = w_push1;
		  t_fwa0 = w_ft1[LG_NF-1:1];
		  t_fwd0 = f_rec(t_rob_next_head);
	       end
	  end
     end // always_comb

   /* two independent 1W + 1 async-R memories */
   always_ff@(posedge clk)
     begin
	if(t_fwe0) begin r_fifo0[t_fwa0] <= t_fwd0; end
	if(t_fwe1) begin r_fifo1[t_fwa1] <= t_fwd1; end
     end // always_ff

   always_comb
     begin
	t_we = 4'd0; t_re = 4'd0;
	t_wa0 = 'd0; t_wa1 = 'd0; t_wa2 = 'd0; t_wa3 = 'd0;
	t_ra0 = 'd0; t_ra1 = 'd0; t_ra2 = 'd0; t_ra3 = 'd0;
	t_wd0 = 'd0; t_wd1 = 'd0; t_wd2 = 'd0; t_wd3 = 'd0;
	t_ck_v = 2'd0;
	t_ck_pool[0] = 2'd0; t_ck_pool[1] = 2'd0;
	t_ck_exp[0] = 'd0;   t_ck_exp[1] = 'd0;

	if(r_busy)
	  begin
	     /* second cycle: the srcB read that collided with srcA's pool */
	     t_re[f_pool(w_rbp)] = 1'b1;
	     t_ck_v[0] = 1'b1;
	     t_ck_pool[0] = f_pool(w_rbp);
	     t_ck_exp[0] = w_rbv;
	     case(f_pool(w_rbp))
	       2'd0: begin t_ra0 = f_idx(w_rbp); end
	       2'd1: begin t_ra1 = f_idx(w_rbp); end
	       2'd2: begin t_ra2 = f_idx(w_rbp); end
	       default: begin t_ra3 = f_idx(w_rbp); end
	     endcase
	  end
	else if(~w_fempty)
	  begin
	     if(w_rw)
	       begin
		  t_we[f_pool(w_rwp)] = 1'b1;
		  case(f_pool(w_rwp))
		    2'd0: begin t_wa0 = f_idx(w_rwp); t_wd0 = {1'b1, w_rwd}; end
		    2'd1: begin t_wa1 = f_idx(w_rwp); t_wd1 = {1'b1, w_rwd}; end
		    2'd2: begin t_wa2 = f_idx(w_rwp); t_wd2 = {1'b1, w_rwd}; end
		    default: begin t_wa3 = f_idx(w_rwp); t_wd3 = {1'b1, w_rwd}; end
		  endcase
	       end
	     if(w_ra)
	       begin
		  t_re[f_pool(w_rap)] = 1'b1;
		  t_ck_v[0] = 1'b1;
		  t_ck_pool[0] = f_pool(w_rap);
		  t_ck_exp[0] = w_rav;
		  case(f_pool(w_rap))
		    2'd0: begin t_ra0 = f_idx(w_rap); end
		    2'd1: begin t_ra1 = f_idx(w_rap); end
		    2'd2: begin t_ra2 = f_idx(w_rap); end
		    default: begin t_ra3 = f_idx(w_rap); end
		  endcase
	       end
	     /* srcB rides a DIFFERENT pool's read port in the same cycle */
	     if(w_rb & (~w_need2))
	       begin
		  t_re[f_pool(w_rbp)] = 1'b1;
		  t_ck_v[1] = 1'b1;
		  t_ck_pool[1] = f_pool(w_rbp);
		  t_ck_exp[1] = w_rbv;
		  case(f_pool(w_rbp))
		    2'd0: begin t_ra0 = f_idx(w_rbp); end
		    2'd1: begin t_ra1 = f_idx(w_rbp); end
		    2'd2: begin t_ra2 = f_idx(w_rbp); end
		    default: begin t_ra3 = f_idx(w_rbp); end
		  endcase
	       end
	  end
     end // always_comb

   /* four independent 1W+1R memories */
   always_ff@(posedge clk)
     begin
	if(t_we[0]) begin r_pt0[t_wa0] <= t_wd0; end
	if(t_we[1]) begin r_pt1[t_wa1] <= t_wd1; end
	if(t_we[2]) begin r_pt2[t_wa2] <= t_wd2; end
	if(t_we[3]) begin r_pt3[t_wa3] <= t_wd3; end
	r_q0 <= r_pt0[t_ra0];
	r_q1 <= r_pt1[t_ra1];
	r_q2 <= r_pt2[t_ra2];
	r_q3 <= r_pt3[t_ra3];
     end

   wire [`M_WIDTH:0] w_q [3:0];
   assign w_q[0] = r_q0;
   assign w_q[1] = r_q1;
   assign w_q[2] = r_q2;
   assign w_q[3] = r_q3;

   wire w_hit0 = r_ck_v[0] & w_q[r_ck_pool[0]][`M_WIDTH] &
	         (w_q[r_ck_pool[0]][`M_WIDTH-1:0] != r_ck_exp[0]);
   wire w_hit1 = r_ck_v[1] & w_q[r_ck_pool[1]][`M_WIDTH] &
	         (w_q[r_ck_pool[1]][`M_WIDTH-1:0] != r_ck_exp[1]);

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_fh <= 'd0; r_ft <= 'd0; r_busy <= 1'b0; r_cur <= 'd0;
	     r_ck_v <= 2'd0;
	     r_ck_pool[0] <= 2'd0; r_ck_pool[1] <= 2'd0;
	     r_ck_exp[0] <= 'd0;   r_ck_exp[1] <= 'd0;
	     r_rdchk_hit <= 1'b0; r_rdchk_degraded <= 1'b0; r_rdchk_checked <= 'd0;
`ifdef VERILATOR
	     r_pushed_reads <= 'd0; r_recs_in <= 'd0; r_recs_out <= 'd0; r_issued <= 'd0;
	     r_maxocc <= 'd0; r_drops <= 'd0; r_hits <= 'd0; r_stallc <= 'd0;
	     r_cur_pc <= 'd0; r_ck_pc <= 'd0;
	     r_ck_ptr[0] <= 'd0; r_ck_ptr[1] <= 'd0;
`endif
	  end
	else
	  begin
`ifdef VERILATOR
	     if({26'd0,w_fcnt} > r_maxocc) begin r_maxocc <= {26'd0, w_fcnt}; end
	     if(w_fnear) begin r_stallc <= r_stallc + 'd1; end
`endif
	     if(w_ffull & (w_push0 | w_push1))
	       begin
		  r_rdchk_degraded <= 1'b1;
`ifdef VERILATOR
		  r_drops <= r_drops + {31'd0,w_push0} + {31'd0,w_push1};
		  if(r_drops == 'd0)
		    begin
		       $display("[RDCHK-DROP] cyc=%0d FIRST record dropped (fifo full, occ=%0d) -- every later check against a dropped producer is a FALSE POSITIVE",
				r_cycle, w_fcnt);
		    end
`endif
	       end
	     else
	       begin
`ifdef VERILATOR
		  /* candidate source reads actually accepted into the FIFO */
		  if(w_push0) begin r_pushed_reads <= r_pushed_reads
		     + {31'd0, (t_rob_head.chk_vals_valid & t_rob_head.srcA_rd)}
		     + {31'd0, (t_rob_head.chk_vals_valid & t_rob_head.srcB_rd)}
		     + {31'd0, (w_push1 & t_rob_next_head.chk_vals_valid & t_rob_next_head.srcA_rd)}
		     + {31'd0, (w_push1 & t_rob_next_head.chk_vals_valid & t_rob_next_head.srcB_rd)}; end
`endif
`ifdef VERILATOR
		  r_recs_in <= r_recs_in + {31'd0,w_push0} + {31'd0,w_push1};
`endif
		  /* the record data itself is written by the banked block above;
		   * only the tail pointer moves here */
		  if(w_push0 & w_push1)
		    begin
		       r_ft <= r_ft + 'd2;
`ifdef VERILATOR
		       r_fifo_pc[r_ft[LG_NF-1:0]] <= t_rob_head.pc;
		       r_fifo_pc[r_ft[LG_NF-1:0] + 1'd1] <= t_rob_next_head.pc;
`endif
		    end
		  else if(w_push0)
		    begin
		       r_ft <= r_ft + 'd1;
`ifdef VERILATOR
		       r_fifo_pc[r_ft[LG_NF-1:0]] <= t_rob_head.pc;
`endif
		    end
	       end

	     if(r_busy)
	       begin
		  r_busy <= 1'b0;
	       end
	     else if(~w_fempty)
	       begin
		  r_fh <= r_fh + 'd1;
`ifdef VERILATOR
		  r_recs_out <= r_recs_out + 'd1;
`endif
		  if(w_need2)
		    begin
		       r_busy <= 1'b1;
		       r_cur <= w_rec;
`ifdef VERILATOR
		       r_cur_pc <= w_rec_pc;
`endif
		    end
	       end

`ifdef VERILATOR
	     r_issued <= r_issued + {31'd0,t_ck_v[0]} + {31'd0,t_ck_v[1]};
	     /* pipeline the diagnosis context alongside the compare it belongs to */
	     r_ck_pc <= w_rec_pc;
	     r_ck_ptr[0] <= r_busy ? w_rbp : w_rap;
	     r_ck_ptr[1] <= w_rbp;
`endif
	     r_ck_v <= t_ck_v;
	     r_ck_pool[0] <= t_ck_pool[0];
	     r_ck_pool[1] <= t_ck_pool[1];
	     r_ck_exp[0] <= t_ck_exp[0];
	     r_ck_exp[1] <= t_ck_exp[1];
	     /* ONE assignment: two sequential `<=` to the same reg would let the
	      * last win, undercounting every cycle where both checks fire */
	     r_rdchk_checked <= r_rdchk_checked + {31'd0, r_ck_v[0]} + {31'd0, r_ck_v[1]};
	     if(w_hit0)
	       begin
		  r_rdchk_hit <= 1'b1;
`ifdef VERILATOR
		  if(r_hits < 'd64)
		    begin
		       $display("[RDCHK] cyc=%0d srcA pc=%x preg=%0d: producer logged %x, reader saw %x (degraded=%b drops=%0d)",
				r_cycle, r_ck_pc, r_ck_ptr[0],
				w_q[r_ck_pool[0]][`M_WIDTH-1:0], r_ck_exp[0],
				r_rdchk_degraded, r_drops);
		    end
`endif
	       end
	     if(w_hit1)
	       begin
		  r_rdchk_hit <= 1'b1;
`ifdef VERILATOR
		  if(r_hits < 'd64)
		    begin
		       $display("[RDCHK] cyc=%0d srcB pc=%x preg=%0d: producer logged %x, reader saw %x (degraded=%b drops=%0d)",
				r_cycle, r_ck_pc, r_ck_ptr[1],
				w_q[r_ck_pool[1]][`M_WIDTH-1:0], r_ck_exp[1],
				r_rdchk_degraded, r_drops);
		    end
`endif
	       end
`ifdef VERILATOR
	     /* ONE assignment -- two sequential `<=` would let the last win */
	     r_hits <= r_hits + {31'd0, w_hit0} + {31'd0, w_hit1};
	     if((w_head_commit & t_rob_head.is_break) | (r_cycle[19:0] == 20'd0))
	       begin
		  $display("[RDCHK-COV] cyc=%0d checked=%0d issued=%0d pushed=%0d | recs %0d/%0d maxocc=%0d drops=%0d hits=%0d stallcyc=%0d degraded=%b",
			   r_cycle, r_rdchk_checked, r_issued, r_pushed_reads,
			   r_recs_in, r_recs_out, r_maxocc, r_drops, r_hits, r_stallc, r_rdchk_degraded);
	       end
`endif
	  end
     end // always_ff

   assign w_rdchk_hit = r_rdchk_hit;
   assign dbg_rdchk = {r_rdchk_checked[29:0], r_rdchk_degraded, r_rdchk_hit};
   /* HOLD RETIREMENT rather than drop a record.  Dropping loses the producer's
    * ptab WRITE, which leaves a stale entry that every later reader of that
    * physreg is then compared against -- a false-positive factory, not a loss of
    * coverage.  Measured on a Linux boot: first drop at cyc 840357, first (false)
    * hit 49 cycles later, 261155 hits and 2.5% of records dropped by 2M cycles.
    * Retire is 2-wide and the drain is 1 record/cycle, so a sustained dual-retire
    * burst (memcpy) outruns any finite FIFO -- depth cannot fix this, only
    * back-pressure can.  Deadlock-free: the drain never depends on retirement. */
   assign w_rdchk_stall = w_fnear;
`else
   assign w_rdchk_hit = 1'b0;
   assign dbg_rdchk = 32'd0;
   assign w_rdchk_stall = 1'b0;
`endif
   wire 	      w_null_target = w_null_tgt_head | w_null_tgt_two |
				      w_null_pc_head | w_wild_restart |
				      w_kernel_null_fault | w_wild_epc |
				      w_user_break | w_rdchk_hit;

   /* The retire ring is a flight recorder: it NEVER back-pressures retirement.
    * (debug-infra defined this alongside its own ring; the merged tree uses the
    * r_rtrace ring, whose readback encoding is the one rtdump.cc decodes.) */
   wire        w_rt_stall = w_rdchk_stall;

`ifdef ENABLE_PC_TRACE
   /* ---- retire trace ring (rich) ---------------------------------------------
    * Every field below is ALREADY unconditional in rob_entry_t, so logging costs
    * ring storage only -- no new pipeline state.  Deliberately over-collects:
    * a reproduction costs ~2.5 h, so a missing field is far more expensive than
    * an unused one.
    *
    * 256 entries x 4 words (~1 BRAM36).  Readback reuses the existing debug port:
    *   dbg_trace_index[7:0] = entry, [9:8] = word
    *   w0 = pc[31:0]         w1 = target_pc[31:0]   (RESOLVED target for branches)
    *   w2 = data[31:0]       (core_mem_rsp.data for a load == the LOADED VALUE)
    *   w3 = {flags, ldst[4:0], opcode[7:0]}
    * take_br is the resolved branch direction -- it answers directly whether the
    * guard beqz was taken, which no register dump can show.
    *
    * Frozen on a retired indirect whose target is 0 or BTB_POISON_PC. */
   /* TWO BANKS, not one array with two write ports: the machine retires two per
    * cycle, and a single array written twice in a cycle will not infer as BRAM
    * (it degrades to LUTRAM, far too costly at 256x128).  Bank E holds the head
    * slot, bank O the second retire slot, both written in the same cycle and
    * sharing one pair index.  Readback keeps the LINEAR order the driver already
    * expects: entry[0] = E[0], entry[1] = O[0], entry[2] = E[1] ...  so
    * dbg_trace_index[0] selects the bank and [7:1] the row, and the driver needs
    * no change.  WHY this matters: logging only the head hid every second
    * instruction -- both 2026-08-29 captures were missing the nop between the
    * faulting load and the branch, so the retire stream was half blind. */
   localparam LG_RT_BANK = `LG_RTRACE_ENTRIES - 1;   /* per-bank depth, log2 */
   logic [215:0]       r_rtrace_e [(1<<LG_RT_BANK)-1:0];
   logic [215:0]       r_rtrace_o [(1<<LG_RT_BANK)-1:0];
   logic [LG_RT_BANK-1:0] r_rtrace_ptr;
   logic 	       r_rtrace_frozen;
   logic [215:0]       r_rtrace_row_e, r_rtrace_row_o;

   /* Cycles since the previous committed head, saturating.  Logged with every
    * record so a long push-out (mispredict recovery, miss, replay) is visible in
    * the trace itself; the value stored with a record is the gap that PRECEDED
    * it.  The record is 144b, not 128b, because each bank is 2 RAMB36 in 512x72
    * SDP mode -- 144b is already paid for, so these bits cost no extra BRAM. */
   localparam RT_GAP_W = 8;
   logic [RT_GAP_W-1:0] r_rt_gap, n_rt_gap;
   always_comb
     begin
	n_rt_gap = w_head_commit ? 'd0 :
		   (r_rt_gap == {RT_GAP_W{1'b1}}) ? r_rt_gap : (r_rt_gap + 'd1);
     end // always_comb
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_rt_gap <= 'd0;
	  end
	else
	  begin
	     r_rt_gap <= n_rt_gap;
	  end
     end // always_ff

   wire [31:0] 	       w_rt_flags = {25'd0,
				     t_rob_head.is_store,
				     t_rob_head.valid_dst,
				     t_rob_head.take_br,
				     t_rob_head.is_br,
				     t_rob_head.is_indirect,
				     t_rob_head.in_delay_slot,
				     t_rob_head.faulted};

   wire [31:0] 	       w_rt_flags2 = {25'd0,
				      t_rob_next_head.is_store,
				      t_rob_next_head.valid_dst,
				      t_rob_next_head.take_br,
				      t_rob_next_head.is_br,
				      t_rob_next_head.is_indirect,
				      t_rob_next_head.in_delay_slot,
				      t_rob_next_head.faulted};

   wire [215:0]        w_rt_rec_head = { 3'd0,
					 t_rob_head.hi_nzB,
					 t_rob_head.hi_nzA,
					 r_rob_head_ptr[`LG_ROB_ENTRIES-1:0],
					 t_rob_head.wr_echo,
					 t_rob_head.srcB_val,
					 t_rob_head.fwd_selB,
					 t_rob_head.post_restart,
					 t_rob_head.has_nullifying_delay_slot,
					 t_rob_head.has_delay_slot,
					 t_rob_head.is_ret,
					 t_rob_head.fwd_sel,   /* {fwd_int,fwd_mem} operand-mux select at execute */
					 t_rob_head.srcA_arch,
					 t_rob_head.srcA_ptr,
					 t_rob_head.pdst,
					 t_rob_head.exec_cycle,
					 r_rt_gap,
					 t_rob_head.pht_idx[10:0],
					 t_rob_head.br_pred,
					 w_rt_flags[6:0],
					 t_rob_head.ldst,
					 t_rob_head.opcode,
					 t_rob_head.data[31:0],
					 t_rob_head.target_pc[31:0],
					 t_rob_head.pc[31:0] };

   wire [215:0]        w_rt_rec_two  = { 3'd0,
					 t_rob_next_head.hi_nzB,
					 t_rob_next_head.hi_nzA,
					 r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0],
					 t_rob_next_head.wr_echo,
					 t_rob_next_head.srcB_val,
					 t_rob_next_head.fwd_selB,
					 t_rob_next_head.post_restart,
					 t_rob_next_head.has_nullifying_delay_slot,
					 t_rob_next_head.has_delay_slot,
					 t_rob_next_head.is_ret,
					 t_rob_next_head.fwd_sel,   /* {fwd_int,fwd_mem} operand-mux select at execute */
					 t_rob_next_head.srcA_arch,
					 t_rob_next_head.srcA_ptr,
					 t_rob_next_head.pdst,
					 t_rob_next_head.exec_cycle,
					 r_rt_gap,
					 t_rob_next_head.pht_idx[10:0],
					 t_rob_next_head.br_pred,
					 w_rt_flags2[6:0],
					 t_rob_next_head.ldst,
					 t_rob_next_head.opcode,
					 t_rob_next_head.data[31:0],
					 t_rob_next_head.target_pc[31:0],
					 t_rob_next_head.pc[31:0] };

   /* Filler for a cycle that retired ONE instruction: all-ones is impossible for
    * a real record (opcode ff is not a valid uop), so the dump shows ffffffff and
    * op=ff and an odd slot is never mistaken for a retired instruction. */
   wire [215:0]        w_rt_rec_none = {216{1'b1}};

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_rtrace_ptr <= 'd0;
	     r_rtrace_frozen <= 1'b0;
	  end
	else
	  begin
	     if(w_null_target)
	       begin
		  r_rtrace_frozen <= 1'b1;
	       end
	     if(w_head_commit & !r_rtrace_frozen)
	       begin
		  r_rtrace_e[r_rtrace_ptr] <= w_rt_rec_head;
		  r_rtrace_o[r_rtrace_ptr] <= t_retire_two ? w_rt_rec_two : w_rt_rec_none;
		  r_rtrace_ptr <= r_rtrace_ptr + 'd1;
	       end
	  end
	r_rtrace_row_e <= r_rtrace_e[dbg_trace_index[LG_RT_BANK:1]];
	r_rtrace_row_o <= r_rtrace_o[dbg_trace_index[LG_RT_BANK:1]];
     end // always_ff

   /* linear next-write slot = pair index * 2, so the driver's 0..255 walk is unchanged */
   wire [215:0]        w_rtrace_row = r_rtrace_sel ? r_rtrace_row_o : r_rtrace_row_e;
   logic 	       r_rtrace_sel;
   always_ff@(posedge clk)
     begin
	r_rtrace_sel <= dbg_trace_index[0];
     end
   /* Keep the frozen flag at bit 15 regardless of ring depth so the host decode
    * (frozen=(s>>15)&1, wptr=s&0x7fff) is independent of LG_RTRACE_ENTRIES. */
   assign dbg_trace_wptr = {r_rtrace_frozen, {(14-LG_RT_BANK){1'b0}}, r_rtrace_ptr, 1'b0};
   /* 216b record = 7 words.  Word select is {index[18], index[16:15]} so index[17]
    * stays free for the GHR readback in core_l1d_l1i (w_hist_sel = index[17:15]>=4). */
   wire [2:0] w_rt_word = {dbg_trace_index[18], dbg_trace_index[16:15]};
   assign dbg_trace_data = (w_rt_word == 3'd4) ? w_rtrace_row[159:128] :
			   (w_rt_word == 3'd5) ? w_rtrace_row[191:160] :
			   (w_rt_word == 3'd6) ? {8'd0, w_rtrace_row[215:192]} :
			   (w_rt_word == 3'd7) ? 32'd0 :
			   (dbg_trace_index[16:15] == 2'd0) ? w_rtrace_row[31:0]   :
			   (dbg_trace_index[16:15] == 2'd1) ? w_rtrace_row[63:32]  :
			   (dbg_trace_index[16:15] == 2'd2) ? w_rtrace_row[95:64]  :
			                                      w_rtrace_row[127:96];
`elsif ENABLE_TRACE_BUFFER
   // ---- trace buffer: log head + next_head {pc,counters,flags} on retire OR arch-fault (incl. II) ----
   // row = 12 words = 2 records; record = {pc, fetch_cycle, alloc_cycle, complete_cycle, retire_cycle, {valid,faulted,cause}}
   // NOTE: verilator-only (see machine.vh) -- the 256x384b RAM dominates FPGA build time.
   logic [11:0][31:0] r_trace_ram [255:0];
   logic [7:0] 	      r_trace_wptr;
   logic [11:0][31:0] r_trace_row;
   logic 	      r_trace_frozen;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_trace_frozen <= 1'b0;
	  end
	else if(w_null_target)
	  begin
	     r_trace_frozen <= 1'b1;
	  end
     end // always_ff

   wire 	      w_trace_we   = (t_retire | (t_arch_fault & (|n_cause))) & (r_state != DEAD) & !r_trace_frozen;

`ifdef VERILATOR
   /* make the event loud in sim too -- on silicon it shows up by itself as
    * epc/BadVA = deadcafc in the oops, but a sim run would otherwise only
    * reveal it via the frozen-ring bit, which nobody thinks to read. */
   always_ff@(posedge clk)
     begin
	/* only the FIRST event -- w_null_target is driven by sticky sources
	 * (r_rdchk_hit among them), so an unqualified print emits every cycle
	 * for the rest of the run (8.9GB of log in two minutes of a Linux boot). */
	if(w_null_target & (~r_trace_frozen))
	  begin
	     if(w_wild_epc)
	       begin
		  $display("[WILD-EPC] cyc=%d n_epc=%x cause=%d kernel=%b head_pc=%x",
			   r_cycle, n_epc, n_cause, in_kernel_mode, t_rob_head.pc);
	       end
	     if(w_kernel_null_fault)
	       begin
		  $display("[KERN-NULL] cyc=%d badvaddr=%x cause=%d", r_cycle, n_badvaddr, n_cause);
	       end
	     if(w_user_break)
	       begin
		  $display("[USER-BREAK] cyc=%d head_pc=%x cause=%d kernel=%b",
			   r_cycle, t_rob_head.pc, n_cause, in_kernel_mode);
	       end
	     if(w_wild_restart)
	       begin
		  $display("[WILD-RESTART] cyc=%d restart_pc=%x (head pc=%x op=%d in_ds=%b)",
			   r_cycle, n_restart_pc, t_rob_head.pc, t_rob_head.opcode,
			   t_rob_head.in_delay_slot);
	       end
	     if(w_null_pc_head)
	       begin
		  $display("[NULL-PC] cyc=%d commit of an entry FETCHED from 0 (faulted=%b in_ds=%b)",
			   r_cycle, t_rob_head.faulted, t_rob_head.in_delay_slot);
	       end
	     $display("[NULL-TARGET] cyc=%d slot=%s pc=%x target=%x src=%s",
		      r_cycle, w_null_tgt_head ? "head" : "two",
		      w_null_tgt_head ? t_rob_head.pc : t_rob_next_head.pc,
		      w_null_tgt_head ? t_rob_head.target_pc : t_rob_next_head.target_pc,
		      ((w_null_tgt_head ? t_rob_head.target_pc : t_rob_next_head.target_pc)
		       == `BTB_POISON_PC) ? "COLD-BTB-POISON" : "REAL-NULL");
	  end
     end // always_ff
`endif
   wire [31:0] 	      w_head_flags = {25'd0, (t_retire | t_arch_fault), t_arch_fault, n_cause};
   wire [31:0] 	      w_next_flags = {25'd0, t_retire_two, 1'b0, 5'd0};
   always_ff@(posedge clk)
     begin
	if(reset) r_trace_wptr <= 8'd0;
	else if(w_trace_we)
	  begin
	     r_trace_ram[r_trace_wptr] <=
		{ w_next_flags, r_cycle[31:0], t_rob_next_head.complete_cycle[31:0], t_rob_next_head.alloc_cycle[31:0], t_rob_next_head.fetch_cycle[31:0], t_rob_next_head.pc[31:0],
		  w_head_flags, r_cycle[31:0], t_rob_head.complete_cycle[31:0],      t_rob_head.alloc_cycle[31:0],      t_rob_head.fetch_cycle[31:0],      t_rob_head.pc[31:0] };
	     r_trace_wptr <= r_trace_wptr + 8'd1;
	  end
	r_trace_row <= r_trace_ram[dbg_trace_index[11:4]];
     end
   /* MSB of the wptr readback = "ring is frozen on a null-target event", so the
    * host can tell a captured trace from a live wrapping one with no new reg. */
   assign dbg_trace_wptr = {7'd0, r_trace_frozen, r_trace_wptr};   /* port widened to 16b for the 32K PC-trace ring */
   assign dbg_trace_data = r_trace_row[dbg_trace_index[3:0]];
`else
   assign dbg_trace_wptr = 'd0;
   assign dbg_trace_data = 'd0;
`endif

   assign took_irq  = t_wr_epc & (r_cause == 5'd0);
   assign cp0_count = w_cp0_count;
   assign l1i_flush_done = n_l1i_flush_complete;
   assign l1d_flush_done = n_l1d_flush_complete;
   assign l2_flush_done = n_l2_flush_complete;
   
   popcount #(`LG_ROB_ENTRIES) inflight0 (.in(r_rob_inflight), 
					  .out(inflight));

   
   uop_t t_uop, t_dec_uop, t_alloc_uop;
   uop_t t_uop2, t_dec_uop2, t_alloc_uop2;
      
   assign insn_ack = !t_dq_full && insn_valid && (r_state == ACTIVE) && !r_oldest_first_pending;
   assign insn_ack_two = !t_dq_full &&
			 insn_valid &&
			 !t_dq_next_full &&
			 insn_valid_two && (r_state == ACTIVE) && !r_oldest_first_pending;
   
   assign restart_pc = r_restart_pc;
   assign restart_src_pc = r_restart_src_pc;
   assign restart_src_is_indirect = r_restart_src_is_indirect;

   assign dead_rob_mask = r_rob_dead_insns;
   assign restart_valid = r_restart_valid;

   /* clr_link_reg: pulse on exception (WRITE_EPC) or ERET retirement only.
    * Branch mispredictions must NOT clear the link register. */
   assign clr_link_reg = (r_state == WRITE_EPC) ||
                         (r_state == ACTIVE && t_can_retire_rob_head &&
                          t_rob_head.faulted && !t_arch_fault &&
                          t_rob_head.opcode == ERET);

   
   assign branch_pc = r_branch_pc;
   assign branch_pc_valid = r_branch_valid;
   assign branch_fault = r_branch_fault;
   assign branch_pht_idx = r_branch_pht_idx;
   
   assign took_branch = r_took_branch;
   
   
   logic [63:0] r_cycle;
   logic [31:0] r_serialize_cycle;
   logic [31:0] r_daddiu_decode_cycle;
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : r_cycle + 'd1;

     end

`ifdef VERILATOR
   // race probe: stamp when 64b-mode (KX) flips and when the kernel_entry
   // daddiu (0x..88300d78) allocates, to measure the decode-vs-mode margin.
   logic r_64b_prev_dbg;
   always_ff@(posedge clk) begin
      if(reset) r_64b_prev_dbg <= 1'b0;
      else begin
	 r_64b_prev_dbg <= w_in_64b_mode;
	 if(w_in_64b_mode != r_64b_prev_dbg)
	   $display("[mode] cyc=%0d 64b_mode -> %b", r_cycle, w_in_64b_mode);
	 if(t_uop.pc[31:0] == 32'h88300d78)
	   $display("[dec0] cyc=%0d op=%0d is_ii=%b mode=%b", r_cycle, t_uop.op, (t_uop.op == II), w_in_64b_mode);
	 if(t_uop2.pc[31:0] == 32'h88300d78)
	   $display("[dec1] cyc=%0d op=%0d is_ii=%b mode=%b", r_cycle, t_uop2.op, (t_uop2.op == II), w_in_64b_mode);
	 if(t_alloc && (t_alloc_uop.pc[31:0] == 32'h88300d78))
	   $display("[daddiu] cyc=%0d slot0 op=%0d is_ii=%b mode=%b", r_cycle, t_alloc_uop.op, (t_alloc_uop.op == II), w_in_64b_mode);
	 if(t_alloc_two && (t_alloc_uop2.pc[31:0] == 32'h88300d78))
	   $display("[daddiu] cyc=%0d slot1 op=%0d is_ii=%b mode=%b", r_cycle, t_alloc_uop2.op, (t_alloc_uop2.op == II), w_in_64b_mode);
      end
   end
`endif


`ifdef VERILATOR
   logic [31:0] r_clear_cnt;
   logic [31:0]	r_fault_cnt;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_fault_cnt <= 'd0;
	  end
	else
	  begin
	     /* DISABLED: net exception-vs-ERET count > 10 is not a reliable livelock
	      * signal on a long healthy boot -- IRIX's R4000 clock-calibration spin
	      * (get_r4k_counter @0x880058xx) takes a periodic timer IRQ every ~660k
	      * cycles, and the +1/-1 accounting drifts.  The no-retire watchdog in
	      * henry_tb (64k cycles with zero retirement) is the reliable hang detector. */
	     // if(r_fault_cnt > 'd10)
	     //   begin
	     //      $display("you've recursively faulted yourself to death");
	     //      $stop();
	     //   end

	     if(t_retire &( t_rob_head.opcode == ERET))
	       begin
		  if(r_fault_cnt != 32'd0)
		    begin
		       r_fault_cnt <= r_fault_cnt - 32'd1;
		    end
	       end
	     else if(t_wr_epc)
	       begin
		  r_fault_cnt <= r_fault_cnt + 'd1;
	       end
	  end
     end
   
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
	     r_flush_cl_inval <= 1'b0;
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
	     r_flush_cl_inval <= n_flush_cl_inval;
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
	     r_post_restart_arm <= 1'b0;
	     r_got_restart_ack <= 1'b0;
	     r_cause <= 5'd0;
	     r_ce <= 2'd0;
	     r_tlb_refill <= 1'b0;
	     r_xtlb_refill <= 1'b0;
	     r_save_to_tlb_regs <= 1'b0;
	     r_has_badvaddr <= 1'b0;
	     r_pending_fault <= 1'b0;
	     r_oldest_first_pending <= 1'b0;
	     r_serialize_cycle <= 32'd0;
	     r_daddiu_decode_cycle <= 32'd0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_restart_cycles <= n_restart_cycles;
	     r_machine_clr <= n_machine_clr;
	     if(r_state == RAT && n_state == ACTIVE)
	       begin
		  r_post_restart_arm <= 1'b1;
	       end
	     else if(t_alloc)
	       begin
		  r_post_restart_arm <= 1'b0;
	       end
	     r_got_restart_ack <= n_got_restart_ack;
	     r_cause <= n_cause;
	     r_ce <= n_ce;
	     r_tlb_refill <= n_tlb_refill;
	     r_xtlb_refill <= n_xtlb_refill;
	     r_save_to_tlb_regs <= n_save_to_tlb_regs;
	     r_has_badvaddr <= n_has_badvaddr;
	     r_pending_fault <= n_pending_fault;
	     r_oldest_first_pending <= n_oldest_first_pending;
	     r_serialize_cycle <= (n_oldest_first_pending && !r_oldest_first_pending) ? r_cycle[31:0] : r_serialize_cycle;
	     if((t_alloc && (t_alloc_uop.pc[31:0] == 32'h88300d78)) || (t_alloc_two && (t_alloc_uop2.pc[31:0] == 32'h88300d78)))
	       r_daddiu_decode_cycle <= r_cycle[31:0];
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
`ifdef VERILATOR
   logic [63:0] last_retire_pc;
   always_ff@(posedge clk)
     begin
	if(retire_valid)
	  begin
	     last_retire_pc <= retire_pc;
	  end
     end
   always_ff@(negedge clk)
     begin
	localparam ZP = (64-`M_WIDTH);	
	
	/* sim-only "ran off into nowhere" guard, tuned for the Linux kernel (all
	 * kseg0 @ 0x88xxxxxx).  DISABLED: it false-trips on IRIX, which legitimately
	 * executes uncached in kseg1 -- its cache-init jumps to the kseg1 alias of its
	 * own text (e.g. `or v0,0x88011734,0xa0000000; jr v0` -> 0xa8011734) to size/
	 * flush the caches uncached.  The FPGA has no such guard anyway. */
	// if(retire_valid & retire_pc[63] & (retire_pc[31:0] > 32'h89000000)
	//    & ~((retire_pc[31:0] >= 32'hbfc00000) & (retire_pc[31:0] <= 32'hbfc0ffff)))
	//   begin
	//      $display("jumped into lala land at with pc %x at cycle %d, last retire pc %x", retire_pc, r_cycle, last_retire_pc);
	//      $stop();
	//   end
	
	

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
   rob_entry_t t_dbg_rob;
   always_comb
     begin
	t_faults = 'd0;
	t_branches = 'd0;
	t_dbg_rob = '0;
	for(logic [`LG_ROB_ENTRIES:0] i = r_rob_head_ptr; i != (r_rob_tail_ptr); i=i+1)
	  begin
	     t_dbg_rob = i[0] ? r_rob_odd[i[`LG_ROB_ENTRIES-1:1]] : r_rob_even[i[`LG_ROB_ENTRIES-1:1]];
	     if(r_rob_complete[i[`LG_ROB_ENTRIES-1:0]]  && t_dbg_rob.faulted)
	       begin
		  t_faults = t_faults + 'd1;
	       end
	     if(t_dbg_rob.is_br && r_rob_complete[i[`LG_ROB_ENTRIES-1:0]])
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
   rob_entry_t t_dbg_dump;
   always_ff@(negedge clk)
     begin
 	if(r_cycle > 'd50)
	  begin
	     $display("cycle %d : oldp %b, state = %d, aluc  %b, memc %b,head_ptr %d, inflight %d, complete %b,  can_retire_rob_head %b, t_faulted_head_and_serializing_delay %b, head pc %x, empty %b, full %b", 
		      r_cycle,
		      r_oldest_first_pending,
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
		  t_dbg_dump = i[0] ? r_rob_odd[i[`LG_ROB_ENTRIES-1:1]] : r_rob_even[i[`LG_ROB_ENTRIES-1:1]];
		  $display("\trob entry %d, pc %x, complete %b, is br %b, faulted %b",
			   i[`LG_ROB_ENTRIES-1:0],
			   t_dbg_dump.pc,
			   r_rob_complete[i[`LG_ROB_ENTRIES-1:0]],
			   t_dbg_dump.is_br,
			   t_dbg_dump.faulted,
			   );
	       end
	  end
     end // always_ff@ (negedge clk)
`endif
   logic t_wr_epc, t_wr_cause, t_wr_badvaddr;
   logic t_restart_complete;
   
   wire	w_rob_next_empty = (r_rob_next_head_ptr == r_rob_tail_ptr);
   wire w_rob_empty = (r_rob_head_ptr == r_rob_tail_ptr);

   wire w_rob_head_complete = r_rob_sd_complete[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]] &
	r_rob_complete[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]];
   
   wire	w_rob_next_head_complete = r_rob_sd_complete[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0]] &
	r_rob_complete[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0]];
   
								      
   wire	w_can_retire = w_rob_empty ? 1'b0 : w_rob_head_complete;
   
								      
   always_comb
     begin
	t_wr_epc = 1'b0;
	t_wr_cause = 1'b0;
	t_wr_badvaddr = 1'b0;
	n_has_badvaddr = r_has_badvaddr;
	
	t_restart_complete = 1'b0;
	
	n_cause = r_cause;
	n_ce = r_ce;
	n_tlb_refill = r_tlb_refill;
	n_xtlb_refill = r_xtlb_refill;

	n_machine_clr = r_machine_clr;
	t_alloc = 1'b0;
	t_alloc_two = 1'b0;
	t_possible_to_alloc = 1'b0;
	n_save_to_tlb_regs = 1'b0;
	n_oldest_first_pending = r_oldest_first_pending;
	
	n_in_delay_slot = r_in_delay_slot;
	t_retire = 1'b0;
	t_retire_two = 1'b0;
	core_fcsr_we = 1'b0;
	core_fcsr_cause6 = 6'd0;
	core_fcsr_flags5 = 5'd0;
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
	t_enough_fprfs = !((t_uop.fp_dst_valid) && (t_uop.is_mem ? t_fp_b1_full : t_fp_b0_full));
	t_enough_fcrprfs = !((t_uop.fcr_dst_valid) && (r_fcr_prf_free == 'd0));


	t_enough_next_iprfs = !((t_uop2.dst_valid) && t_gpr_ffs2_full);
	t_enough_next_hlprfs = !((t_uop2.hilo_dst_valid) /*&& (r_hilo_prf_free == 'd0)*/);
	/* one FP dst alloc per cycle: slot 1 FP-dst needs a free FP reg AND slot 0 not also FP-dst */
	t_enough_next_fprfs = !((t_uop2.fp_dst_valid) && ((t_uop2.is_mem ? t_fp_b1_full : t_fp_b0_full) || t_uop.fp_dst_valid));
	/* one FCR dst alloc per cycle: slot 1 FCR-dst serialized to slot 0 next cycle */
	t_enough_next_fcrprfs = !(t_uop2.fcr_dst_valid);



	
	t_fold_uop = (t_uop.op == NOP |
		      t_uop.op == J  |
		      t_uop.op == IRQ |
		      t_uop.op == FETCH_MISALIGNED |
		      t_uop.op == FETCH_ADDR_ERROR |
		      t_uop.op == FETCH_TLB_MISS |
		      t_uop.op == FETCH_TLB_INVALID |
		      t_uop.op == CPU |
		      t_uop.op == II);

	t_fold_uop2 = (t_uop2.op == NOP |
		       t_uop2.op == J  |
		       t_uop2.op == IRQ |
		       t_uop2.op == FETCH_MISALIGNED |
		       t_uop2.op == FETCH_ADDR_ERROR |
		       t_uop2.op == FETCH_TLB_MISS |
		       t_uop2.op == FETCH_TLB_INVALID |
		       t_uop2.op == CPU |
		       t_uop2.op == II);
	
	n_ds_done = r_ds_done;
	n_flush_req_l1d = 1'b0;
	n_flush_req_l1i = 1'b0;
	n_flush_cl_req = 1'b0;
	n_flush_cl_addr = r_flush_cl_addr;
	n_flush_cl_inval = r_flush_cl_inval;
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
	
	if(w_can_retire)
	  begin
	     /* A faulted (mispredicted) branch with a REGULAR delay slot must wait for
	      * the delay slot to COMPLETE before retiring -- else the branch retires and
	      * issues its fall-through restart while the delay slot is still in flight, so
	      * if the delay slot then faults (e.g. store TLB miss) the fall-through has
	      * already been fetched/retired and corrupts a live reg (go SIGSEGV, bug #3).
	      * Nullifying (branch-likely) delay slot only needs to be present. */
	     t_can_retire_rob_head = ( t_rob_head.faulted ?
				       ( t_rob_head.has_nullifying_delay_slot ? !w_rob_next_empty :
					 t_rob_head.has_delay_slot            ? (!w_rob_next_empty & w_rob_next_head_complete) :
					 1'b1 )
				       : 1'b1 ) & w_step_ok & !w_rt_stall;
	     t_faulted_head_and_serializing_delay = (t_rob_head.has_delay_slot || t_rob_head.has_nullifying_delay_slot) && t_rob_head.faulted && !t_dq_empty 
						    && t_rob_next_empty && t_uop.serializing_op;
	  end

	if(t_complete_valid_1)
	  begin
	     n_pending_fault = r_pending_fault | t_complete_bundle_1.faulted;
	  end
	if(t_complete_valid_2)
	  begin
	     n_pending_fault = n_pending_fault | t_complete_bundle_2.faulted;
	  end

	t_arch_fault = t_rob_head.faulted & 
		       (t_rob_head.is_break | 
			t_rob_head.is_syscall | 
			t_rob_head.is_ii |
			t_rob_head.is_cpu |
			t_rob_head.is_fpe |
			t_rob_head.is_bad_addr |
			t_rob_head.overflow | 
			t_rob_head.trap | 
			t_rob_head.is_irq |
			(t_rob_head.opcode == FETCH_TLB_MISS) |
			(t_rob_head.opcode == FETCH_MISALIGNED) |
			(t_rob_head.opcode == FETCH_ADDR_ERROR) |
			t_rob_head.tlb_refill |
			t_rob_head.tlb_invalid |
			t_rob_head.tlb_modified);
	
	
	unique case (r_state)
	  ACTIVE:
	    begin
	       if(t_faulted_head_and_serializing_delay)
		 begin
		    n_state = SERIALIZE_IN_FAULTED_DELAY_SLOT;
		 end
	       else if(t_can_retire_rob_head)
		 begin
		    //$display("t_rob_head.faulted = %b, pc =%x", 
		    //t_rob_head.faulted, t_rob_head.pc);
		    
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
			 n_restart_pc = t_rob_head.in_delay_slot ? r_last_branch_target : t_rob_head.target_pc;
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
					&& t_enough_fprfs
					&& t_enough_fcrprfs
					&& !r_oldest_first_pending
					&& (r_pending_fault ? r_in_delay_slot : 1'b1);


			      t_alloc_two = t_alloc
					    && !t_uop.is_br
					    && !t_uop.oldest_first
					    && !t_uop2.serializing_op
					    && !t_uop2.oldest_first
					    && !t_dq_next_empty
					    && !t_rob_next_full
					    && !t_uq_next_full
					    && t_enough_next_iprfs
					    && t_enough_next_hlprfs
					    && t_enough_next_fprfs
					    && t_enough_next_fcrprfs;

			      //&& (t_uop2.op == NOP || t_uop2.op == J);
			   end // else: !if(t_uop.serializing_op && !t_dq_empty)
		      end // if (!t_dq_empty)
		    t_retire = t_rob_head_complete & !t_arch_fault;
`ifdef SINGLE_RETIRE
		    /* Bug-hunt knob: force single (in-order, one-per-cycle) retirement.
		     * Two purposes: it halves the retire-PC ring (one record per row,
		     * no slot-2 entry to miss), and it BISECTS the bug -- if
		     * __split_vma still reproduces with dual retire off, the entire
		     * dual-retire path is exonerated. */
		    t_retire_two = 1'b0;
`else
		    t_retire_two = !t_rob_next_empty
		    		   & !t_rob_head.faulted
		    		   & !t_rob_next_head.faulted 				    
		    		   & t_rob_head_complete
		    		   & t_rob_next_head_complete				    
				   & !t_rob_head.is_br
				   & !t_rob_next_head.is_ret
				   & !t_rob_next_head.is_call
		    		   & !t_rob_next_head.valid_hilo_dst
				   & !t_rob_next_head.valid_fcr_dst 
				   & ~single_step;
`endif
		    /* non-trapping FP ops retiring this cycle: accumulate IEEE flags
		     * into FCSR.Flags and set Cause to the youngest's exceptions. */
		    if(t_retire & t_rob_head.fp_set_flags)
		      begin
			 core_fcsr_we = 1'b1;
			 core_fcsr_cause6 = r_fp_flags[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]];
			 core_fcsr_flags5 = r_fp_flags[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]][4:0];
		      end
		    if(t_retire_two & t_rob_next_head.fp_set_flags)
		      begin
			 core_fcsr_we = 1'b1;
			 core_fcsr_cause6 = r_fp_flags[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0]];
			 core_fcsr_flags5 = core_fcsr_flags5 |
					    r_fp_flags[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:0]][4:0];
		      end
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
				   && t_enough_fprfs
				   && t_enough_fcrprfs
				   && !r_oldest_first_pending
				   && (r_pending_fault ? r_in_delay_slot : 1'b1);

			 //$display("r_cycle = %d, can alloc %b, r_pending %b, delay %b", r_cycle, t_alloc, r_pending_fault, r_in_delay_slot);

			 t_alloc_two = t_alloc
				       && !t_uop.is_br
				       && !t_uop.oldest_first
				       && !t_uop2.serializing_op
				       && !t_uop2.oldest_first
				       && !t_dq_next_empty
				       && !t_rob_next_full
				       && !t_uq_next_full
				       && t_enough_next_iprfs
				       && t_enough_next_hlprfs
				       && t_enough_next_fprfs
				       && t_enough_next_fcrprfs;

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
			 $display(">>>> real fault in nullifying delay slot -> t_rob_head.pc = %x, opcode = %d", 
				  t_rob_head.pc,
				  t_rob_head.opcode);		
			 // $stop() relaxed 2026-07-09: this is a TAKEN branch-likely whose
			 // (executed, non-nullified) delay slot takes a real fault -- fall
			 // through to the handler below (ARCH_FAULT on fault, else retire),
			 // as silicon does, instead of halting the sim.  First exercised by
			 // miniroot userspace (a normal userspace TLB miss in the slot).
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
		    if(t_rob_head.faulted)
		      begin
			 $display(">>>> real fault in delay slot -> t_rob_head.pc = %x, opcode = %d", 
				  t_rob_head.pc,
				  t_rob_head.opcode);
			 if( (is_store(t_rob_head.opcode) | is_load(t_rob_head.opcode)) == 1'b0)
			   begin
			      $display(">>>> WARNING - not a load or store fault");
			      //$stop();
			   end
		      end
		    if(t_arch_fault)
		      begin
			 /* faulted delay slot (e.g. store TLB miss) -> arch exception.
			  * MUST flush the speculatively-fetched fall-through: the ACTIVE-path
			  * faulted-head handler sets n_machine_clr + restart setup, but this
			  * DRAIN path did not -- so wrong-path insns after the delay slot
			  * (fetched past the mispredicted branch) retired and corrupted a live
			  * register before the vector was taken (go SIGSEGV, bug #3). */
			 n_state = ARCH_FAULT;
			 n_machine_clr = 1'b1;
			 n_restart_pc = t_rob_head.in_delay_slot ? r_last_branch_target : t_rob_head.target_pc;
			 n_restart_src_pc = t_rob_head.pc;
			 n_restart_src_is_indirect = t_rob_head.is_indirect && !t_rob_head.is_ret;
		      end
		    else
		      begin
			 t_retire = 1'b1;
		      end
		 end

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
		    if(t_rob_head.is_cache)
		      begin
`ifdef IRIX_CACHE_TRACE
			 $display("[cache] pc=%x is_d=%b inval=%b EA=%x",
				  t_rob_head.pc[31:0], t_rob_head.cache_is_d,
				  t_rob_head.cache_inval, t_rob_head.data[31:0] & 32'h1fffffff);
`endif
			 /* CACHE op: D-side does a surgical per-line writeback of the
			  * addressed line to L2 (flush_cl at EA = rob.data); I-side
			  * nukes the whole L1I (the arbiter chains an L2 flush). Fake
			  * the completes of the caches we don't touch so CACHE_FLUSH's
			  * uniform all-three wait still fires. Restart afterward to
			  * refetch (mandatory once L1I is gone; harmless for D). */
			 if(t_rob_head.cache_is_d)
			   begin
			      n_flush_cl_req  = 1'b1;
			      /* EA = base+offset, masked to a physical address (kseg0/kseg1
			       * unmapped: PA = VA & 0x1fffffff) so L1D can tag-match it and
			       * the L2 drop targets the right line. */
			      n_flush_cl_addr = t_rob_head.data & 64'h1fffffff;
			      n_flush_cl_inval = t_rob_head.cache_inval; /* Hit-Invalidate: drop, no WB */
			      n_l1i_flush_complete = 1'b1;          /* not flushing L1I */
			      n_l2_flush_complete  = 1'b1;          /* flush_cl bypasses the L2 flush */
			   end
			 else
			   begin
			      n_flush_req_l1i = 1'b1;
			      n_l1d_flush_complete = 1'b1;          /* not flushing L1D */
			   end
			 n_state = CACHE_FLUSH;
		      end
		    else
		      begin
			 t_clr_dq = 1'b1;
			 n_restart_pc = t_rob_head.in_delay_slot ? r_last_branch_target : t_rob_head.target_pc;
			 n_restart_src_pc = t_rob_head.pc;
			 n_restart_src_is_indirect = 1'b0;
			 n_restart_valid = 1'b1;
			 n_pending_fault = 1'b0;
			 if(n_got_restart_ack)
			   begin
			      /* restart debug removed */
			      n_state = ACTIVE;
			   end
		      end
		 end
	    end
	  CACHE_FLUSH:
	    begin
	       /* hold until L1I, L1D and L2 flushes have all completed, then
		* restart at the CACHE op's sequential target (refetch the I-stream
		* now that L1I is empty). Mirrors WAIT_FOR_SERIALIZE_AND_RESTART.
		* NB: keep the latched completes asserted until the restart is
		* acked -- clearing them early drops the condition before the ack
		* and deadlocks. */
	       if(n_l1i_flush_complete && n_l1d_flush_complete && n_l2_flush_complete)
		 begin
		    t_clr_dq = 1'b1;
		    n_restart_pc = t_rob_head.in_delay_slot ? r_last_branch_target : t_rob_head.target_pc;
		    n_restart_src_pc = t_rob_head.pc;
		    n_restart_src_is_indirect = 1'b0;
		    n_restart_valid = 1'b1;
		    n_pending_fault = 1'b0;
		    if(n_got_restart_ack)
		      begin
			 n_l1i_flush_complete = 1'b0;
			 n_l1d_flush_complete = 1'b0;
			 n_l2_flush_complete = 1'b0;
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
	       n_xtlb_refill = 1'b0;
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
`ifdef VERILATOR
		    if(t_rob_head.mode_when_fetched != w_in_64b_mode) $stop();  // P-mode-hazard ($stop in sim; formal assert below)
`endif
		    n_pending_ud = 1'b1;
		    //$display("bad pc %x", t_rob_head.in_delay_slot ? (t_rob_head.pc - 'd4) : t_rob_head.pc);
		    n_cause = 5'd10;
		 end
	       else if(t_rob_head.is_cpu)
		 begin
		    n_cause = 5'd11;  /* Coprocessor Unusable */
		    n_ce = t_rob_head.cpu_ce1 ? 2'd1 : 2'd0;  /* CP1 (FPU) -> CE=1, else CP0 -> CE=0 */
		 end
	       else if(t_rob_head.is_fpe)
		 begin
		    n_cause = 5'd15;  /* Floating-Point Exception (denorm/Unimplemented + enabled IEEE) */
		    /* set FCSR.Cause so the handler can read why it trapped; the trapped
		     * op does NOT accumulate into the sticky Flags field. */
		    core_fcsr_we = 1'b1;
		    core_fcsr_cause6 = r_fp_flags[r_rob_head_ptr[`LG_ROB_ENTRIES-1:0]];
		 end
	       else if(t_rob_head.opcode == FETCH_MISALIGNED ||
			       t_rob_head.opcode == FETCH_ADDR_ERROR)  /* both AdEL, BadVAddr=PC */
		 begin
		    n_pending_bad_addr = 1'b1;
		    n_has_badvaddr = 1'b1;
		    n_cause = 5'd4;
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
		    /* A refill uses the special refill vector only when EXL=0 at
		     * fault time; a nested refill (EXL already set) falls through
		     * to the general vector (0x180). */
		    n_tlb_refill = t_rob_head.tlb_refill & ~w_sr_exl;
		    /* XTLB refill vector (0x080) when 64-bit addressing is active
		     * for the operating mode of the faulting access; else the
		     * 32-bit TLB refill vector (0x000). */
		    n_xtlb_refill = t_rob_head.tlb_refill & ~w_sr_exl &
				    (w_in_64b_kernel_mode |
				     w_in_64b_supervisor_mode |
				     w_in_64b_user_mode);
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
	       $display(">>>>>>>> at cycle %d, taking fault for EPC %x, cause %d, store %b, load %b, badaddr %x, opcode %d, fault cnt %d", 
			r_cycle, n_epc, n_cause, is_store(t_rob_head.opcode), is_load(t_rob_head.opcode), n_badvaddr,
			t_rob_head.opcode,
			r_fault_cnt);
	       if(n_badvaddr == 'h744b)
		 begin
		    $stop();
		 end
	       if(n_epc < 'd1000)
		 begin
		    $stop();
		 end
	       
	       n_exc_in_delay = t_rob_head.in_delay_slot;
	    end
	  WRITE_EPC:
	    begin
	       t_wr_epc = 1'b1;
	       t_wr_cause = 1'b1;
	       t_wr_badvaddr = r_has_badvaddr;
	       
	       n_machine_clr = 1'b1;
	       
	       /* TLB refill -> 0x000 (32-bit) or 0x080 (64-bit XTLB);
		* all other exceptions -> 0x180 general vector. */
	       n_restart_pc = sign_extend32((w_sr_bev ? 32'hbfc00200 : 32'h80000000) |
					    (r_tlb_refill ? (r_xtlb_refill ? 32'h80 : 32'h0) : 32'h180));
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
		     begin //todo - is this correct?
			n_state = ARCH_FAULT;
			t_bump_rob_head = 1'b1;
		     end
		   else
		     begin
			n_pending_fault = 1'b0;
			n_state = ACTIVE;
		     end
		end
	   end // case: WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT
	  DEAD:
	    begin
	       n_state = DEAD;
	    end
	  default:
	    begin
	    end
	endcase // unique case (r_state)

	if(t_clr_rob)
	  n_oldest_first_pending = 1'b0;
	else if((t_retire && t_rob_head.oldest_first) ||
		(t_retire_two && t_rob_next_head.oldest_first))
	  n_oldest_first_pending = 1'b0;
	else if(t_alloc && t_uop.oldest_first)
	  n_oldest_first_pending = 1'b1;

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
	     r_fcr_alloc_rat <= 'd0;
	     r_fcr_retire_rat <= 'd0;
	  end
	else
	  begin
	     r_fcr_alloc_rat <= t_rat_copy ? r_fcr_retire_rat : n_fcr_alloc_rat;
	     r_fcr_retire_rat <= n_fcr_retire_rat;
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

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(logic [`LG_PRF_ENTRIES-1:0] i_rat = 'd0; i_rat < 'd32; i_rat = i_rat + 'd1)
	       begin
		  r_fp_alloc_rat[i_rat[4:0]] <= i_rat;
		  r_fp_retire_rat[i_rat[4:0]] <= i_rat;
	       end
	  end
	else
	  begin
	     r_fp_alloc_rat <= t_rat_copy ? r_fp_retire_rat : n_fp_alloc_rat;
	     r_fp_retire_rat <= n_fp_retire_rat;
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
	n_fcr_alloc_rat = r_fcr_alloc_rat;
	n_fp_alloc_rat = r_fp_alloc_rat;
	
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
	/* FP sources: looked up in the FP RAT (mutually exclusive with the int valids above) */
	if(t_uop.fp_srcA_valid)
	  t_alloc_uop.srcA = r_fp_alloc_rat[t_uop.srcA[4:0]];
	if(t_uop.fp_srcB_valid)
	  t_alloc_uop.srcB = r_fp_alloc_rat[t_uop.srcB[4:0]];
	if(t_uop.srcC_valid)
	  t_alloc_uop.srcC = r_alloc_rat[t_uop.srcC[4:0]];
	if(t_uop.fp_srcC_valid)
	  t_alloc_uop.srcC = r_fp_alloc_rat[t_uop.srcC[4:0]];

	if(t_uop.hilo_src_valid)
	  begin
	     t_alloc_uop.hilo_src = r_hilo_alloc_rat;
	  end
	/* FCR source overloads the hilo_src field (mutually exclusive with hilo_src_valid) */
	else if(t_uop.fcr_src_valid)
	  begin
	     t_alloc_uop.hilo_src = r_fcr_alloc_rat;
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
	/* FP sources for slot 1, with bypass from a slot-0 FP dst */
	if(t_uop2.fp_srcA_valid)
	  t_alloc_uop2.srcA = (t_uop.fp_dst_valid && (t_uop2.srcA[4:0] == t_uop.dst[4:0])) ?
			      n_fp_prf_entry : r_fp_alloc_rat[t_uop2.srcA[4:0]];
	if(t_uop2.fp_srcB_valid)
	  t_alloc_uop2.srcB = (t_uop.fp_dst_valid && (t_uop2.srcB[4:0] == t_uop.dst[4:0])) ?
			      n_fp_prf_entry : r_fp_alloc_rat[t_uop2.srcB[4:0]];
	if(t_uop2.srcC_valid)
	  t_alloc_uop2.srcC = (t_uop.dst_valid && (t_uop2.srcC[4:0] == t_uop.dst[4:0])) ?
			      n_prf_entry : r_alloc_rat[t_uop2.srcC[4:0]];
	if(t_uop2.fp_srcC_valid)
	  t_alloc_uop2.srcC = (t_uop.fp_dst_valid && (t_uop2.srcC[4:0] == t_uop.dst[4:0])) ?
			      n_fp_prf_entry : r_fp_alloc_rat[t_uop2.srcC[4:0]];

	if(t_uop2.hilo_src_valid)
	  begin
	     t_alloc_uop2.hilo_src = t_uop.hilo_dst_valid ? n_hilo_prf_entry :
				     r_hilo_alloc_rat;
	  end
	/* FCR source for slot 1, with bypass from a slot-0 FCR dst */
	else if(t_uop2.fcr_src_valid)
	  begin
	     t_alloc_uop2.hilo_src = t_uop.fcr_dst_valid ? n_fcr_prf_entry :
				     r_fcr_alloc_rat;
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
	     else if(t_uop.fcr_dst_valid)
	       begin
		  n_fcr_alloc_rat = n_fcr_prf_entry;
		  t_alloc_uop.hilo_dst = n_fcr_prf_entry;
	       end
	     else if(t_uop.fp_dst_valid)
	       begin
		  n_fp_alloc_rat[t_uop.dst[4:0]] = n_fp_prf_entry;
		  t_alloc_uop.dst = n_fp_prf_entry;
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
	     else if(t_uop2.fp_dst_valid)
	       begin
		  n_fp_alloc_rat[t_uop2.dst[4:0]] = n_fp_prf_entry;
		  t_alloc_uop2.dst = n_fp_prf_entry;
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
	n_fcr_retire_rat = r_fcr_retire_rat;
	n_fp_retire_rat = r_fp_retire_rat;
	
	t_free_reg = 1'b0;
	t_free_reg_ptr = 'd0;
	t_free_reg_two = 1'b0;
	t_free_reg_two_ptr = 'd0;
	
	
	t_free_hilo = 1'b0;
	t_free_hilo_ptr = 'd0;
	t_free_fcr = 1'b0;
	t_free_fcr_ptr = 'd0;
	t_free_fp_reg = 1'b0;
	t_free_fp_reg_ptr = 'd0;
	t_free_fp_reg_two = 1'b0;
	t_free_fp_reg_two_ptr = 'd0;

	n_retire_prf_free = r_retire_prf_free;
	n_retire_hilo_prf_free = r_retire_hilo_prf_free;
	n_retire_fcr_prf_free = r_retire_fcr_prf_free;
	n_retire_fp_prf_free = r_retire_fp_prf_free;
	
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
	     else if(t_rob_head.valid_fcr_dst)
	       begin
		  t_free_fcr = 1'b1;
		  t_free_fcr_ptr = t_rob_head.old_pdst[`LG_FCR_PRF_ENTRIES-1:0];
		  n_fcr_retire_rat = t_rob_head.pdst[`LG_FCR_PRF_ENTRIES-1:0];
		  n_retire_fcr_prf_free[t_rob_head.pdst[`LG_FCR_PRF_ENTRIES-1:0]] = 1'b0;
		  n_retire_fcr_prf_free[t_rob_head.old_pdst[`LG_FCR_PRF_ENTRIES-1:0]] = 1'b1;
	       end
	     else if(t_rob_head.valid_fp_dst)
	       begin
		  t_free_fp_reg = 1'b1;
		  t_free_fp_reg_ptr = t_rob_head.old_pdst;
		  n_fp_retire_rat[t_rob_head.ldst] = t_rob_head.pdst;
		  n_retire_fp_prf_free[t_rob_head.pdst] = 1'b0;
		  n_retire_fp_prf_free[t_rob_head.old_pdst] = 1'b1;
	       end

	     if(t_retire_two && t_rob_next_head.valid_dst)
	       begin
		  t_free_reg_two = 1'b1;
		  t_free_reg_two_ptr = t_rob_next_head.old_pdst;
		  n_retire_rat[t_rob_next_head.ldst] = t_rob_next_head.pdst;
		  n_retire_prf_free[t_rob_next_head.pdst] = 1'b0;
		  n_retire_prf_free[t_rob_next_head.old_pdst] = 1'b1;
	       end
	     else if(t_retire_two && t_rob_next_head.valid_fp_dst)
	       begin
		  t_free_fp_reg_two = 1'b1;
		  t_free_fp_reg_two_ptr = t_rob_next_head.old_pdst;
		  n_fp_retire_rat[t_rob_next_head.ldst] = t_rob_next_head.pdst;
		  n_retire_fp_prf_free[t_rob_next_head.pdst] = 1'b0;
		  n_retire_fp_prf_free[t_rob_next_head.old_pdst] = 1'b1;
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
	t_rob_tail.valid_fcr_dst = 1'b0;
	t_rob_tail.valid_fp_dst = 1'b0;
	t_rob_tail.ldst  = 'd0;
	t_rob_tail.pdst  = 'd0;
	t_rob_tail.old_pdst  = 'd0;
	/* renamed srcA + its arch name, for the retire trace's rename self-check */
	t_rob_tail.srcA_ptr  = t_alloc_uop.srcA;
	t_rob_tail.srcA_arch = t_uop.srcA[4:0];
	/* retire-time reader-agreement check: renamed srcB, and whether this uop
	 * really reads INTEGER sources (FP sources live in a different physreg
	 * namespace and must not be looked up in the integer producer table). */
	t_rob_tail.srcB_ptr  = t_alloc_uop.srcB;
	t_rob_tail.srcA_rd   = t_alloc_uop.srcA_valid & (~t_alloc_uop.fp_srcA_valid);
	t_rob_tail.srcB_rd   = t_alloc_uop.srcB_valid & (~t_alloc_uop.fp_srcB_valid);
	t_rob_tail.chk_vals_valid = 1'b0;
	t_rob_tail.chk_srcA_val = 'd0;
	t_rob_tail.chk_srcB_val = 'd0;
	t_rob_tail.post_restart = r_post_restart_arm;
	t_rob_tail.pc = t_alloc_uop.pc;
	/* carry the decode-time 64b-mode flag into the ROB (the P-mode-hazard guard at
	 * ARCH_FAULT reads t_rob_head.mode_when_fetched).  Was dropped here -> the guard
	 * compared a stale ROB-slot value, giving spurious P-mode mismatches (and could
	 * mask a real one). */
	t_rob_tail.mode_when_fetched = t_alloc_uop.mode_when_fetched;
	/* default to sequential next-PC so a serializing op restarts at pc+4;
	 * branches overwrite this with the resolved target at completion (~1963). */
	t_rob_tail.target_pc = (t_alloc_uop.op == J) ? t_alloc_uop.pred_target : (t_alloc_uop.pc + 'd4);

	t_rob_tail.is_call = t_alloc_uop.op == JAL || t_alloc_uop.op == JALR || t_alloc_uop.op == BAL;
	t_rob_tail.is_irq = t_alloc_uop.op == IRQ;
	t_rob_tail.is_ret = (t_alloc_uop.op == JR) && (t_uop.srcA == 'd31);
	t_rob_tail.is_break  = (t_alloc_uop.op == BREAK);
	t_rob_tail.is_syscall  = (t_alloc_uop.op == SYSCALL);
	t_rob_tail.is_cache  = t_alloc_uop.is_cache;
	t_rob_tail.cache_is_d = t_alloc_uop.cache_is_d;
	t_rob_tail.cache_inval = t_alloc_uop.cache_inval;
	t_rob_tail.is_indirect = t_alloc_uop.op == JALR || t_alloc_uop.op == JR;
	t_rob_tail.is_tlbp = (t_alloc_uop.op == TLBP);
	
	t_rob_tail.is_ii = 1'b0;
	t_rob_tail.is_cpu = 1'b0;
	t_rob_tail.cpu_ce1 = 1'b0;
	t_rob_tail.is_fpe = 1'b0;
	t_rob_tail.fp_set_flags = 1'b0;
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
	t_rob_tail.br_pred = t_alloc_uop.br_pred;
	t_rob_tail.oldest_first = t_uop.oldest_first;
	
	t_rob_next_tail.faulted  = 1'b0;
	t_rob_next_tail.valid_dst  = 1'b0;
	t_rob_next_tail.valid_hilo_dst = 1'b0;
	t_rob_next_tail.valid_fcr_dst = 1'b0;
	t_rob_next_tail.valid_fp_dst = 1'b0;
	t_rob_next_tail.ldst  = 'd0;
	t_rob_next_tail.pdst  = 'd0;
	t_rob_next_tail.old_pdst  = 'd0;
	t_rob_next_tail.srcA_ptr  = t_alloc_uop2.srcA;
	t_rob_next_tail.srcA_arch = t_uop2.srcA[4:0];
	t_rob_next_tail.srcB_ptr  = t_alloc_uop2.srcB;
	t_rob_next_tail.srcA_rd   = t_alloc_uop2.srcA_valid & (~t_alloc_uop2.fp_srcA_valid);
	t_rob_next_tail.srcB_rd   = t_alloc_uop2.srcB_valid & (~t_alloc_uop2.fp_srcB_valid);
	t_rob_next_tail.chk_vals_valid = 1'b0;
	t_rob_next_tail.chk_srcA_val = 'd0;
	t_rob_next_tail.chk_srcB_val = 'd0;
	t_rob_next_tail.post_restart = r_post_restart_arm & ~t_alloc;
	t_rob_next_tail.pc = t_alloc_uop2.pc;
	t_rob_next_tail.mode_when_fetched = t_alloc_uop2.mode_when_fetched;   /* see slot0 note above */
	t_rob_next_tail.target_pc = (t_alloc_uop2.op == J) ? t_alloc_uop2.pred_target : (t_alloc_uop2.pc + 'd4);
	t_rob_next_tail.opcode = t_alloc_uop2.op;
	t_rob_next_tail.is_call = t_alloc_uop2.op == JAL || t_alloc_uop2.op == JALR || t_alloc_uop2.op == BAL;
	t_rob_next_tail.is_irq = t_alloc_uop2.op == IRQ;
	
	t_rob_next_tail.is_ret = (t_alloc_uop2.op == JR) && (t_uop.srcA == 'd31);
	t_rob_next_tail.is_break = (t_alloc_uop2.op == BREAK);
	t_rob_next_tail.is_syscall = (t_alloc_uop2.op == SYSCALL);
	t_rob_next_tail.is_cache = t_alloc_uop2.is_cache;
	t_rob_next_tail.cache_is_d = t_alloc_uop2.cache_is_d;
	t_rob_next_tail.cache_inval = t_alloc_uop2.cache_inval;
	t_rob_next_tail.is_tlbp = (t_alloc_uop2.op == TLBP);
	t_rob_next_tail.is_indirect = t_alloc_uop2.op == JALR || t_alloc_uop2.op == JR;
	t_rob_next_tail.is_fpe = 1'b0;
	t_rob_next_tail.fp_set_flags = 1'b0;
	t_rob_next_tail.overflow = 1'b0;
	t_rob_next_tail.trap = 1'b0;
	t_rob_next_tail.tlb_refill = 1'b0;
	t_rob_next_tail.tlb_invalid = 1'b0;
	t_rob_next_tail.tlb_modified = 1'b0;
	t_rob_next_tail.tlb_hit = 1'b0;
	t_rob_next_tail.tlb_index = 6'd0;
	
	t_rob_next_tail.is_ii = 1'b0;
	t_rob_next_tail.is_cpu = 1'b0;
	t_rob_next_tail.cpu_ce1 = 1'b0;
	t_rob_next_tail.is_bad_addr = 1'b0;
	t_rob_next_tail.take_br = 1'b0;
	t_rob_next_tail.is_br = t_alloc_uop2.is_br;	
	t_rob_next_tail.is_store = is_store(t_alloc_uop2.op);
	
	t_rob_next_tail.in_delay_slot = r_in_delay_slot;
	t_rob_next_tail.data = 'd0;
	t_rob_next_tail.pht_idx = t_alloc_uop2.pht_idx;
	t_rob_next_tail.br_pred = t_alloc_uop2.br_pred;
	t_rob_next_tail.oldest_first = t_uop2.oldest_first;
	
	t_rob_tail.has_delay_slot = t_alloc_uop.has_delay_slot;
	t_rob_tail.has_nullifying_delay_slot = t_alloc_uop.has_nullifying_delay_slot;

	t_rob_next_tail.has_delay_slot = t_uop2.has_delay_slot;
	t_rob_next_tail.has_nullifying_delay_slot = t_uop2.has_nullifying_delay_slot;
`ifdef ENABLE_CYCLE_ACCOUNTING
	// unconditional defaults so the cycle fields never infer a latch (only assigned in if(t_alloc)/if(t_alloc_two) below)
	t_rob_tail.fetch_cycle = t_alloc_uop.fetch_cycle;
	t_rob_tail.alloc_cycle = r_cycle;
	t_rob_tail.complete_cycle = 'd0;
	t_rob_next_tail.fetch_cycle = t_alloc_uop2.fetch_cycle;
	t_rob_next_tail.alloc_cycle = r_cycle;
	t_rob_next_tail.complete_cycle = 'd0;
`endif
	
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
	     else if(t_uop.fcr_dst_valid)
	       begin
		  t_rob_tail.valid_fcr_dst = 1'b1;
		  t_rob_tail.pdst = {{(`LG_PRF_ENTRIES-`LG_FCR_PRF_ENTRIES){1'b0}}, n_fcr_prf_entry};
		  t_rob_tail.old_pdst = {{(`LG_PRF_ENTRIES-`LG_FCR_PRF_ENTRIES){1'b0}}, r_fcr_alloc_rat};
	       end
	     else if(t_uop.fp_dst_valid)
	       begin
		  t_rob_tail.valid_fp_dst = 1'b1;
		  t_rob_tail.ldst = t_uop.dst[4:0];
		  t_rob_tail.pdst = n_fp_prf_entry;
		  t_rob_tail.old_pdst = r_fp_alloc_rat[t_uop.dst[4:0]];
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
		  else if(t_uop.op == CPU)
		    begin
		       t_rob_tail.faulted = 1'b1;
		       t_rob_tail.is_cpu = 1'b1;
		       t_rob_tail.cpu_ce1 = t_uop.cpu_ce1;
		    end
		  else if(t_uop.op == FETCH_TLB_MISS)
		    begin
		       t_rob_tail.faulted = 1'b1;
		       t_rob_tail.tlb_refill = 1'b1;
		    end
		  else if(t_uop.op == FETCH_TLB_INVALID)
		    begin
		       t_rob_tail.faulted = 1'b1;
		       t_rob_tail.tlb_invalid = 1'b1;
		    end
		  else if(t_uop.op == FETCH_MISALIGNED || t_uop.op == FETCH_ADDR_ERROR)
		    begin
		       t_rob_tail.faulted = 1'b1;
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
	     else if(t_uop2.fp_dst_valid)
	       begin
		  t_rob_next_tail.valid_fp_dst = 1'b1;
		  t_rob_next_tail.ldst = t_uop2.dst[4:0];
		  t_rob_next_tail.pdst = n_fp_prf_entry;
		  t_rob_next_tail.old_pdst = (t_uop.fp_dst_valid && (t_uop.dst == t_uop2.dst)) ? t_rob_tail.pdst : r_fp_alloc_rat[t_uop2.dst[4:0]];
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
		  else if(t_uop2.op == CPU)
		    begin
		       t_rob_next_tail.faulted = 1'b1;
		       t_rob_next_tail.is_cpu = 1'b1;
		       t_rob_next_tail.cpu_ce1 = t_uop2.cpu_ce1;
		    end
		  else if(t_uop2.op == FETCH_TLB_MISS)
		    begin
		       t_rob_next_tail.faulted = 1'b1;
		       t_rob_next_tail.tlb_refill = 1'b1;
		    end
		  else if(t_uop2.op == FETCH_TLB_INVALID)
		    begin
		       t_rob_next_tail.faulted = 1'b1;
		       t_rob_next_tail.tlb_invalid = 1'b1;
		    end
		  else if(t_uop2.op == FETCH_MISALIGNED || t_uop2.op == FETCH_ADDR_ERROR)
		    begin
		       t_rob_next_tail.faulted = 1'b1;
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
	     if(t_complete_valid_2)
	       begin
		  r_rob_complete[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:0]] <= t_complete_bundle_2.complete;
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
	     for(integer i = 0; i < (N_ROB_ENTRIES/2); i=i+1)
	       begin
		  r_rob_even[i].faulted <= 1'b0;
		  r_rob_odd[i].faulted <= 1'b0;
	       end
	  end
	else
	  begin
	     if(t_alloc)
	       begin
		  if(r_rob_tail_ptr[0])
		    r_rob_odd[r_rob_tail_ptr[`LG_ROB_ENTRIES-1:1]] <= t_rob_tail;
		  else
		    r_rob_even[r_rob_tail_ptr[`LG_ROB_ENTRIES-1:1]] <= t_rob_tail;
`ifdef ENABLE_EXC_RING
		  r_fetch_insn[r_rob_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= t_alloc_uop.insn;
`endif
	       end
	     if(t_alloc_two)
	       begin
		  if(r_rob_next_tail_ptr[0])
		    r_rob_odd[r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:1]] <= t_rob_next_tail;
		  else
		    r_rob_even[r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:1]] <= t_rob_next_tail;
`ifdef ENABLE_EXC_RING
		  r_fetch_insn[r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= t_alloc_uop2.insn;
`endif
	       end
	     if(t_complete_valid_1)
	       begin
		  if(t_complete_bundle_1.rob_ptr[0]) begin
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].faulted <= t_complete_bundle_1.faulted;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].target_pc <= t_complete_bundle_1.restart_pc;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].is_ii <= t_complete_bundle_1.is_ii;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].take_br <= t_complete_bundle_1.take_br;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].data <= t_complete_bundle_1.data;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].overflow <= t_complete_bundle_1.overflow;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].trap <= t_complete_bundle_1.trap;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].exec_cycle <= r_cycle[7:0];
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].fwd_selB <= t_complete_bundle_1.fwd_selB;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].srcB_val <= t_complete_bundle_1.srcB_val;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].chk_srcA_val <= t_complete_bundle_1.chk_srcA_val;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].chk_srcB_val <= t_complete_bundle_1.chk_srcB_val;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].chk_vals_valid <= t_complete_bundle_1.chk_vals_valid;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].hi_nzA <= t_complete_bundle_1.hi_nzA;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].hi_nzB <= t_complete_bundle_1.hi_nzB;
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].wr_echo <= t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0];
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].fwd_sel <= t_complete_bundle_1.fwd_sel;
`ifdef ENABLE_CYCLE_ACCOUNTING
		     r_rob_odd[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].complete_cycle <= r_cycle;
`endif
		  end
		  else begin
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].faulted <= t_complete_bundle_1.faulted;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].target_pc <= t_complete_bundle_1.restart_pc;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].is_ii <= t_complete_bundle_1.is_ii;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].take_br <= t_complete_bundle_1.take_br;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].data <= t_complete_bundle_1.data;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].overflow <= t_complete_bundle_1.overflow;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].trap <= t_complete_bundle_1.trap;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].exec_cycle <= r_cycle[7:0];
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].fwd_selB <= t_complete_bundle_1.fwd_selB;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].srcB_val <= t_complete_bundle_1.srcB_val;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].chk_srcA_val <= t_complete_bundle_1.chk_srcA_val;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].chk_srcB_val <= t_complete_bundle_1.chk_srcB_val;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].chk_vals_valid <= t_complete_bundle_1.chk_vals_valid;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].hi_nzA <= t_complete_bundle_1.hi_nzA;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].hi_nzB <= t_complete_bundle_1.hi_nzB;
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].wr_echo <= t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0];
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].fwd_sel <= t_complete_bundle_1.fwd_sel;
`ifdef ENABLE_CYCLE_ACCOUNTING
		     r_rob_even[t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:1]].complete_cycle <= r_cycle;
`endif
		  end
	       end
	     if(t_complete_valid_2)
	       begin
		  if(t_complete_bundle_2.rob_ptr[0]) begin
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].faulted <= t_complete_bundle_2.faulted;
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].is_fpe <= t_complete_bundle_2.faulted;
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].fp_set_flags <= 1'b1;
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].target_pc <= t_complete_bundle_2.restart_pc;
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].is_ii <= t_complete_bundle_2.is_ii;
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].take_br <= t_complete_bundle_2.take_br;
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].data <= t_complete_bundle_2.data;
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].overflow <= t_complete_bundle_2.overflow;
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].trap <= t_complete_bundle_2.trap;
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].exec_cycle <= r_cycle[7:0];
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].wr_echo <= t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:0];
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].fwd_sel <= t_complete_bundle_2.fwd_sel;
`ifdef ENABLE_CYCLE_ACCOUNTING
		     r_rob_odd[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].complete_cycle <= r_cycle;
`endif
		  end
		  else begin
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].faulted <= t_complete_bundle_2.faulted;
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].is_fpe <= t_complete_bundle_2.faulted;
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].fp_set_flags <= 1'b1;
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].target_pc <= t_complete_bundle_2.restart_pc;
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].is_ii <= t_complete_bundle_2.is_ii;
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].take_br <= t_complete_bundle_2.take_br;
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].data <= t_complete_bundle_2.data;
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].overflow <= t_complete_bundle_2.overflow;
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].trap <= t_complete_bundle_2.trap;
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].exec_cycle <= r_cycle[7:0];
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].wr_echo <= t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:0];
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].fwd_sel <= t_complete_bundle_2.fwd_sel;
`ifdef ENABLE_CYCLE_ACCOUNTING
		     r_rob_even[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:1]].complete_cycle <= r_cycle;
`endif
		  end
		  /* FP IEEE flags side-band (1W), read at retire (see core_fcsr_*) */
		  r_fp_flags[t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:0]] <= t_complete_bundle_2.fp_flags;
	       end
	     if(core_mem_rsp_valid)
	       begin
		  if(core_mem_rsp.rob_ptr[0]) begin
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].data <= core_mem_rsp.data;
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].faulted <= core_mem_rsp.bad_addr | core_mem_rsp.tlb_refill | core_mem_rsp.tlb_invalid | core_mem_rsp.tlb_modified;
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_refill <= core_mem_rsp.tlb_refill;
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_invalid <= core_mem_rsp.tlb_invalid;
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_modified <= core_mem_rsp.tlb_modified;
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_hit <= core_mem_rsp.tlb_hit;
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_index <= core_mem_rsp.tlb_index;
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].is_bad_addr <= core_mem_rsp.bad_addr;
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].exec_cycle <= r_cycle[7:0];
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].wr_echo <= core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:0];
`ifdef ENABLE_CYCLE_ACCOUNTING
		     r_rob_odd[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].complete_cycle <= r_cycle;
`endif
		  end
		  else begin
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].data <= core_mem_rsp.data;
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].faulted <= core_mem_rsp.bad_addr | core_mem_rsp.tlb_refill | core_mem_rsp.tlb_invalid | core_mem_rsp.tlb_modified;
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_refill <= core_mem_rsp.tlb_refill;
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_invalid <= core_mem_rsp.tlb_invalid;
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_modified <= core_mem_rsp.tlb_modified;
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_hit <= core_mem_rsp.tlb_hit;
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].tlb_index <= core_mem_rsp.tlb_index;
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].is_bad_addr <= core_mem_rsp.bad_addr;
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].exec_cycle <= r_cycle[7:0];
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].wr_echo <= core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:0];
`ifdef ENABLE_CYCLE_ACCOUNTING
		     r_rob_even[core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:1]].complete_cycle <= r_cycle;
`endif
		  end
		  r_addrs[core_mem_rsp.rob_ptr] <= core_mem_rsp.data[`M_WIDTH-1:0];
	       end
	     /* Fetch-fault BadVAddr: latch the faulting fetch PC into r_addrs at
	      * ALLOC, UNCONDITIONALLY -- a fetch fault carries no mem op, so this
	      * must NOT be gated on core_mem_rsp_valid (ARCH_FAULT reads BadVAddr
	      * from here).  Previously nested in the mem-rsp block, which left
	      * fetch-fault BadVAddr stale unless a load happened to respond that cycle. */
	     if(t_alloc && (t_uop.op == FETCH_TLB_MISS || t_uop.op == FETCH_TLB_INVALID || t_uop.op == FETCH_MISALIGNED || t_uop.op == FETCH_ADDR_ERROR))
	       r_addrs[r_rob_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= t_alloc_uop.pc;
	     if(t_alloc_two && (t_uop2.op == FETCH_TLB_MISS || t_uop2.op == FETCH_TLB_INVALID || t_uop2.op == FETCH_MISALIGNED || t_uop2.op == FETCH_ADDR_ERROR))
	       r_addrs[r_rob_next_tail_ptr[`LG_ROB_ENTRIES-1:0]] <= t_alloc_uop2.pc;
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
	t_clr_mask = uq_wait|mq_wait|fp_uq_wait;
	if(t_complete_valid_1)
	  begin
	     t_clr_mask[t_complete_bundle_1.rob_ptr] = 1'b1;
	  end
	if(t_complete_valid_2)
	  begin
	     t_clr_mask[t_complete_bundle_2.rob_ptr] = 1'b1;
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
		  if(t_complete_valid_2)
		    begin
		       r_rob_inflight[t_complete_bundle_2.rob_ptr] <= 1'b0;
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
	t_rob_head = r_rob_head_ptr[0] ? r_rob_odd[r_rob_head_ptr[`LG_ROB_ENTRIES-1:1]] : r_rob_even[r_rob_head_ptr[`LG_ROB_ENTRIES-1:1]];
	t_rob_next_head = r_rob_next_head_ptr[0] ? r_rob_odd[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:1]] : r_rob_even[r_rob_next_head_ptr[`LG_ROB_ENTRIES-1:1]];
	
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
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(integer i = 0; i < N_FCR_ENTRIES; i = i + 1)
	       begin
		  r_fcr_prf_free[i] <= (i==0) ? 1'b0 : 1'b1;
		  r_retire_fcr_prf_free[i] <= (i==0) ? 1'b0 : 1'b1;
	       end
	  end
	else
	  begin
	     r_fcr_prf_free <= t_rat_copy ? r_retire_fcr_prf_free : n_fcr_prf_free;
	     r_retire_fcr_prf_free <= n_retire_fcr_prf_free;
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


   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(integer i = 0; i < N_PRF_ENTRIES; i = i + 1)
	       begin
		  r_fp_prf_free[i] <= (i < 32) ? 1'b0 : 1'b1;
		  r_retire_fp_prf_free[i] <= (i < 32) ? 1'b0 : 1'b1;
	       end
	  end
	else
	  begin
	     r_fp_prf_free <= t_rat_copy ? r_retire_fp_prf_free : n_fp_prf_free;
	     r_retire_fp_prf_free <= n_retire_fp_prf_free;
	  end
     end // always_ff@ (posedge clk)



   
   find_lowest_set_bit#(`LG_HILO_PRF_ENTRIES) ffs_hilo(.in(r_hilo_prf_free),
						 .y(t_hilo_ffs));

   find_lowest_set_bit#(`LG_FCR_PRF_ENTRIES) ffs_fcr(.in(r_fcr_prf_free),
						.y(t_fcr_ffs));
   always_comb
     begin
	n_fcr_prf_free = r_fcr_prf_free;
	n_fcr_prf_entry = t_fcr_ffs[`LG_FCR_PRF_ENTRIES-1:0];

	if(t_alloc & t_uop.fcr_dst_valid)
	  begin
	     n_fcr_prf_free[n_fcr_prf_entry] = 1'b0;
	  end
	if(t_free_fcr)
	  begin
	     n_fcr_prf_free[t_free_fcr_ptr] = 1'b1;
	  end
     end // always_comb

   /* FP free-list banked to match fp_regfile: bank0 = low half (ptr MSB=0) = fpu-arith
    * results; bank1 = high half (MSB=1) = mem-pipe FP results (loads + mtc1).  Allocate
    * the (single, per the gating) fp dst from the bank matching its producing write port
    * -- is_mem (load/mtc1) -> bank1, else (fpu arith) -> bank0 -- so the ptr MSB the
    * regfile reads by is meaningful.  Free/retire stay on the flat r_fp_prf_free vector. */
   generate
      for(genvar fpgi = 0; fpgi < N_PRF_ENTRIES; fpgi = fpgi + 1)
	begin : fp_free_bank_split
	   assign w_fp_free_b0[fpgi] = (fpgi <  N_PRF_ENTRIES/2) ? r_fp_prf_free[fpgi] : 1'b0;
	   assign w_fp_free_b1[fpgi] = (fpgi >= N_PRF_ENTRIES/2) ? r_fp_prf_free[fpgi] : 1'b0;
	end
   endgenerate
   find_lowest_set_bit#(`LG_PRF_ENTRIES) ffs_fp0(.in(w_fp_free_b0), .y(t_fp_ffs0));
   find_lowest_set_bit#(`LG_PRF_ENTRIES) ffs_fp1(.in(w_fp_free_b1), .y(t_fp_ffs1));
   always_comb
     begin
	n_fp_prf_free = r_fp_prf_free;
	t_fp_b0_full = t_fp_ffs0[`LG_PRF_ENTRIES];
	t_fp_b1_full = t_fp_ffs1[`LG_PRF_ENTRIES];
	w_fp_dst_is_mem = (t_alloc & t_uop.fp_dst_valid) ? t_uop.is_mem :
			  (t_alloc_two & t_uop2.fp_dst_valid) ? t_uop2.is_mem : 1'b0;
	n_fp_prf_entry = w_fp_dst_is_mem ? t_fp_ffs1[`LG_PRF_ENTRIES-1:0]
					 : t_fp_ffs0[`LG_PRF_ENTRIES-1:0];
	if(t_alloc & t_uop.fp_dst_valid)
	  n_fp_prf_free[n_fp_prf_entry] = 1'b0;
	if(t_alloc_two & t_uop2.fp_dst_valid)
	  n_fp_prf_free[n_fp_prf_entry] = 1'b0;
	if(t_free_fp_reg)
	  n_fp_prf_free[t_free_fp_reg_ptr] = 1'b1;
	if(t_free_fp_reg_two)
	  n_fp_prf_free[t_free_fp_reg_two_ptr] = 1'b1;
     end

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
      for(genvar i = 0; i < N_PRF_ENTRIES; i=i+1)
	begin : prf_pool_split
	   /* clustered RF: i[LG_PRF_ENTRIES-1] selects ALU(0)/MEM(1) bank, i[0]=parity */
	   assign w_alu_even[i] = ((i <  N_PRF_ENTRIES/2) && (i % 2 == 0)) ? r_prf_free[i] : 1'b0;
	   assign w_alu_odd[i]  = ((i <  N_PRF_ENTRIES/2) && (i % 2 == 1)) ? r_prf_free[i] : 1'b0;
	   assign w_mem_even[i] = ((i >= N_PRF_ENTRIES/2) && (i % 2 == 0)) ? r_prf_free[i] : 1'b0;
	   assign w_mem_odd[i]  = ((i >= N_PRF_ENTRIES/2) && (i % 2 == 1)) ? r_prf_free[i] : 1'b0;
	end
   endgenerate

   assign w_alu_even_full = (|w_alu_even) == 1'b0;
   assign w_alu_odd_full  = (|w_alu_odd)  == 1'b0;
   assign w_mem_even_full = (|w_mem_even) == 1'b0;
   assign w_mem_odd_full  = (|w_mem_odd)  == 1'b0;

   find_lowest_set_bit#(`LG_PRF_ENTRIES) ffs_ae(.in(w_alu_even), .y(w_ffs_alu_even));
   find_lowest_set_bit#(`LG_PRF_ENTRIES) ffs_ao(.in(w_alu_odd),  .y(w_ffs_alu_odd));
   find_lowest_set_bit#(`LG_PRF_ENTRIES) ffs_me(.in(w_mem_even), .y(w_ffs_mem_even));
   find_lowest_set_bit#(`LG_PRF_ENTRIES) ffs_mo(.in(w_mem_odd),  .y(w_ffs_mem_odd));

   always_ff@(posedge clk)
     begin
	r_bank_sel <= reset ? 1'b0 : ~r_bank_sel;
     end

   always_comb
     begin
	/* uop1 takes the bank_sel parity, uop2 the opposite (the two renamed dsts
	 * differ even within one bank); bank chosen by is_mem. */
	if(t_uop.is_mem)
	  begin
	     t_gpr_ffs      = r_bank_sel ? w_ffs_mem_even : w_ffs_mem_odd;
	     t_gpr_ffs_full = r_bank_sel ? w_mem_even_full : w_mem_odd_full;
	  end
	else
	  begin
	     t_gpr_ffs      = r_bank_sel ? w_ffs_alu_even : w_ffs_alu_odd;
	     t_gpr_ffs_full = r_bank_sel ? w_alu_even_full : w_alu_odd_full;
	  end
	if(t_uop2.is_mem)
	  begin
	     t_gpr_ffs2      = r_bank_sel ? w_ffs_mem_odd : w_ffs_mem_even;
	     t_gpr_ffs2_full = r_bank_sel ? w_mem_odd_full : w_mem_even_full;
	  end
	else
	  begin
	     t_gpr_ffs2      = r_bank_sel ? w_ffs_alu_odd : w_ffs_alu_even;
	     t_gpr_ffs2_full = r_bank_sel ? w_alu_odd_full : w_alu_even_full;
	  end
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

   logic t_dec0_in_delay_slot, t_dec1_in_delay_slot;
   logic n_dec_delay_slot, r_dec_delay_slot;
   
   always_comb
     begin
	n_dec_delay_slot = r_dec_delay_slot;
	t_dec0_in_delay_slot = 1'b0;
	t_dec1_in_delay_slot = 1'b0;
	
	if(t_push_dq_two)
	  begin
	     if(r_dec_delay_slot)
	       begin
		  t_dec0_in_delay_slot = 1'b1;
		  n_dec_delay_slot = insn_two.is_branch;
	       end
	     else
	       begin
		  if(insn.is_branch)
		    begin
		       t_dec1_in_delay_slot = 1'b1;
		    end
		  else if(insn_two.is_branch)
		    begin
		       n_dec_delay_slot = 1'b1;
		    end
	       end
	  end // if (t_push_dq_two)
	else if(t_push_dq_one)
	  begin
	     if(r_dec_delay_slot)
	       begin
		  t_dec0_in_delay_slot = 1'b1;
		  n_dec_delay_slot = 1'b0;
	       end
	     else
	       begin
		  if(insn.is_branch)
		    begin
		       n_dec_delay_slot = 1'b1;		       
		    end
	       end
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_dec_delay_slot <= 1'b0;
	  end
	else
	  begin
	     r_dec_delay_slot <= t_clr_rob ? 1'b0 : n_dec_delay_slot;
	  end
     end // always_ff@ (posedge clk)
   //t_push_dq_one
   //t_push_dq_two

   
`ifdef R4K_HAZARD_BEHAV
   /* R4400 MTC0->Status[IE] CP0 hazard (Uman Appendix F, Table F-2): a real
    * R4x00 does NOT accept a pending interrupt for 3 instructions after an mtc0
    * that writes c0_sr.  r9999 is precise (0-cycle), which breaks the ~32
    * "mtc0 c0_sr next to a stack switch" sites IRIX/Linux rely on (the IRIX
    * bad-istack panic).  Replicate it: after a decoded mtc0/dmtc0 to CP0 reg 12
    * (Status), suppress decode-side irq injection for 4 more decoded insns.
    * Detected from the raw insn (COP0=0x10, rs=MT/DMT=4/5, rd=12), so no
    * dependence on the decode output.  NB: REDUNDANT on r9999 -- mtc0 is a
    * serializing_op that drains the pipe, so a post-mtc0 interrupt already sees the
    * committed Status (R10000 "handled in hardware").  Kept for R4K-exact study. */
   wire w_dec0_wr_c0sr = t_push_dq_one & (insn.data[31:26]==6'h10) &
        ((insn.data[25:21]==5'd4)|(insn.data[25:21]==5'd5)) & (insn.data[15:11]==5'd12);
   wire w_dec1_wr_c0sr = t_push_dq_two & (insn_two.data[31:26]==6'h10) &
        ((insn_two.data[25:21]==5'd4)|(insn_two.data[25:21]==5'd5)) & (insn_two.data[15:11]==5'd12);
   logic [2:0] r_sr_haz, n_sr_haz;
   always_comb
     begin
	n_sr_haz = r_sr_haz;
	if(t_push_dq_one & t_push_dq_two)
	  n_sr_haz = (r_sr_haz > 3'd2) ? (r_sr_haz - 3'd2) : 3'd0;
	else if(t_push_dq_one | t_push_dq_two)
	  n_sr_haz = (r_sr_haz > 3'd0) ? (r_sr_haz - 3'd1) : 3'd0;
	if(w_dec0_wr_c0sr | w_dec1_wr_c0sr)
	  n_sr_haz = 3'd4;
     end
   always_ff@(posedge clk)
     r_sr_haz <= reset ? 3'd0 : n_sr_haz;
 `define R4K_IRQ_G0 & (r_sr_haz == 3'd0)
 `define R4K_IRQ_G1 & (r_sr_haz == 3'd0) & !w_dec0_wr_c0sr
`else
 `define R4K_IRQ_G0
 `define R4K_IRQ_G1
`endif

   decode_mips dec0 (
		     .in_kernel_mode(in_kernel_mode),
		     .in_supervisor_mode(in_supervisor_mode),
		     .in_user_mode(in_user_mode),
		     .in_64b_kernel_mode(w_in_64b_kernel_mode),
		     .in_64b_supervisor_mode(w_in_64b_supervisor_mode),
		     .in_64b_user_mode(w_in_64b_user_mode),
		     .cu1(w_cu1),
		     .fr(w_fr),
		     .irq(w_irq_pending & (t_dec0_in_delay_slot == 1'b0) `R4K_IRQ_G0),
		     .tlb_miss(insn.tlb_miss),
		     .tlb_invalid(insn.tlb_invalid),
		     .misaligned(insn.misaligned),
		     .bad_va(insn.bad_va),
		     .insn(insn.data),
		     .pc(insn.pc), 
		     .insn_pred(insn.pred), 
		     .pht_idx(insn.pht_idx),
		     .insn_pred_target(insn.pred_target),
`ifdef ENABLE_CYCLE_ACCOUNTING
		     .fetch_cycle(insn.fetch_cycle),
`endif		      
		     .uop(t_dec_uop));

   decode_mips dec1 (
		     .in_kernel_mode(in_kernel_mode),
		     .in_supervisor_mode(in_supervisor_mode),
		     .in_user_mode(in_user_mode),
		     .in_64b_kernel_mode(w_in_64b_kernel_mode),
		     .in_64b_supervisor_mode(w_in_64b_supervisor_mode),
		     .in_64b_user_mode(w_in_64b_user_mode),
		     .cu1(w_cu1),
		     .fr(w_fr),
		     .irq(w_irq_pending & (t_dec1_in_delay_slot == 1'b0) `R4K_IRQ_G1),
		     .tlb_miss(insn_two.tlb_miss),
		     .tlb_invalid(insn_two.tlb_invalid),
		     .misaligned(insn_two.misaligned),
		     .bad_va(insn_two.bad_va),
		     .insn(insn_two.data),
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
	t_any_complete = t_complete_valid_1 | t_complete_valid_2 | core_mem_rsp_valid;
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
	   .ip6(ip6),
	   .ip5(ip5),
	   .ip4(ip4),
	   .ip3(ip3),
	   .ip2(ip2),
	   .retire(t_retire),
	   .retire_two(t_retire_two),
	   .single_step(single_step),
	   .core_epc(r_epc),
	   .core_wr_epc(t_wr_epc),
	   .core_cause(r_cause),
	   .cause_ip(cause_ip),
	   .core_ce(r_ce),
	   .exec_epc(w_exec_epc),
	   .core_wr_tlbp(t_wr_tlbp),
	   .core_tlbp_hit(t_tlbp_hit),
	   .core_tlbp_index(t_tlbp_index),
	   .asid(asid),
	   .tlb_entry_out_valid(tlb_entry_out_valid),
	   .tlb_entry_out(tlb_entry_out),	   
	   .sr_bev(w_sr_bev),
	   .sr_exl(w_sr_exl),
	   .core_wr_cause(t_wr_cause),
	   .core_wr_badvaddr(t_wr_badvaddr),
	   .core_badvaddr(r_badvaddr),
	   .core_fcsr_we(core_fcsr_we),
	   .core_fcsr_cause6(core_fcsr_cause6),
	   .core_fcsr_flags5(core_fcsr_flags5),
	   .save_to_tlb_regs(r_save_to_tlb_regs),
	   .exc_in_delay(r_exc_in_delay),
	   .in_kernel_mode(in_kernel_mode),
	   .in_supervisor_mode(in_supervisor_mode),
	   .in_user_mode(in_user_mode),
	   .in_64b_kernel_mode(w_in_64b_kernel_mode),
	   .in_64b_supervisor_mode(w_in_64b_supervisor_mode),
	   .in_64b_user_mode(w_in_64b_user_mode),
	   .cu1(w_cu1),
	   .fr(w_fr),

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
	   .head_of_rob_ptr_valid(head_of_rob_ptr_valid),
	   .head_of_rob_ptr(head_of_rob_ptr),
	   .next_head_of_rob_ptr(next_head_of_rob_ptr),
	   .head_of_rob_ds_committable(head_of_rob_ds_committable),
	   .cpr0_status_reg(status_reg),
	   .mq_wait(mq_wait),
	   .uq_wait(uq_wait),
	   .fp_uq_wait(fp_uq_wait),
	   .uq_full(t_uq_full),
	   .uq_next_full(t_uq_next_full),
	   .uq_uop(t_push_1 ? t_alloc_uop : t_alloc_uop2),
	   .uq_uop_two(t_alloc_uop2),	   
	   .uq_push(t_push_1 || (!t_push_1 && t_push_2)),
	   .uq_push_two(t_push_2 && t_push_1),
	   	   
	   .complete_bundle_1(t_complete_bundle_1),
	   .complete_valid_1(t_complete_valid_1),
	   .complete_bundle_2(t_complete_bundle_2),
	   .complete_valid_2(t_complete_valid_2),

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
	   .mem_rsp_fp_dst(core_mem_rsp.fp_dst),
	   .mem_rsp_fp_merge(core_mem_rsp.fp_merge),
	   .mem_rsp_fp_hi(core_mem_rsp.fp_hi),
	   .mem_rsp_fp_pres(core_mem_rsp.fp_pres),
	   .mem_rsp_load_data(core_mem_rsp.data),
	   .mem_rsp_rob_ptr(core_mem_rsp.rob_ptr),
	   .irq_pending(w_irq_pending),
	   .cp0_count(w_cp0_count)
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
	  begin
	     r_dq[r_dq_tail_ptr[`LG_DQ_ENTRIES-1:0]] <= t_dec_uop;
	  end
	if(t_push_dq_two)
	  begin
	     r_dq[r_dq_next_tail_ptr[`LG_DQ_ENTRIES-1:0]] <= t_dec_uop2;
	  end
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
	     if(insn_valid && !t_dq_full && !(!t_dq_next_full && insn_valid_two) && !r_oldest_first_pending)
	       begin
		  //push one instruction
		  t_push_dq_one = 1'b1;
		  n_dq_tail_ptr = r_dq_tail_ptr + 'd1;
		  n_dq_next_tail_ptr = r_dq_next_tail_ptr + 'd1;
		  n_dq_cnt = n_dq_cnt + 'd1;
	       end
	     else if(insn_valid && !t_dq_full && !t_dq_next_full && insn_valid_two && !r_oldest_first_pending)
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
   

   /* Case 2: latch the resolved target of the most-recently-retired branch.
    * A serializing op restarts only once it is the ROB head (oldest), by which
    * point its delay-slot parent branch has retired -- so this holds that
    * branch's target, the correct restart_pc for a delay-slot serializing op. */
   always_ff@(posedge clk)
     begin
	if(reset)
	  r_last_branch_target <= 'd0;
	else if(t_retire_two && (t_rob_next_head.is_br || t_rob_next_head.is_call || t_rob_next_head.is_indirect))
	  r_last_branch_target <= t_rob_next_head.target_pc;
	else if(t_retire && (t_rob_head.is_br || t_rob_head.is_call || t_rob_head.is_indirect))
	  r_last_branch_target <= t_rob_head.target_pc;
     end






`ifdef FORMAL
   // P-rob-adjacency (PASSES @ -t20): dual-retire pair is program-order consecutive.
   wire w_fdbg_head_br = t_rob_head.is_br | t_rob_head.is_call | t_rob_head.is_indirect;
   wire w_fdbg_next_ds = t_rob_next_head.in_delay_slot;
   always_ff@(posedge clk)
     if(!reset && t_retire && t_retire_two)
       assert(w_fdbg_next_ds == w_fdbg_head_br);
   // P-restart-pc: deep trigger (WAIT state ~40+ cyc from reset). Needs a precise
   // cutpoint (not wildcard) or config-floor to exercise; see memory notes.
   wire w_frst_wait = (r_state == WAIT_FOR_SERIALIZE_AND_RESTART) && t_rob_head_complete && t_rob_head.in_delay_slot;
   always_ff@(posedge clk)
     if(!reset && w_frst_wait)
       assert(n_restart_pc == r_last_branch_target);
   // P-mode-hazard: a Reserved-Instruction fault must commit in the mode it was
   // fetched in; a mismatch is a stale-mode RI restart-on-commit should have squashed.
   always_ff@(posedge clk)
     if(!reset && (r_state == ARCH_FAULT) && t_rob_head.is_ii && !t_rob_head.is_break && !t_rob_head.is_syscall)
       assert(t_rob_head.mode_when_fetched == w_in_64b_mode);
   // cover: can the BMC reach a committed Reserved Instruction (the P-mode-hazard gate)?
   always_ff@(posedge clk)
     if(!reset)
       cover((r_state == ARCH_FAULT) && t_rob_head.is_ii && !t_rob_head.is_break && !t_rob_head.is_syscall);
`endif


`ifdef FORMAL_RETIRE_MON
   /* ------------------------------------------------------------------------
    * Retire-count monitor for the mispredicted-branch + delay-slot protocol.
    * Property (dsheffie 2026-09-04): after a mispredicted branch with a delay
    * slot enters DRAIN, EXACTLY ONE instruction retires before the restart --
    * the delay slot itself (pc+4, in_delay_slot) -- except a not-taken
    * branch-likely, whose nullified slot must contribute EXACTLY ZERO; a
    * delay slot that arch-faults ends the window at ARCH_FAULT instead.
    * This is the guard against "bug #3" (wrong-path retires after the ds).
    * The monitor latches its OWN copies of the branch state at the arming
    * cycle so a bug in the DUT's r_has_delay_slot/r_take_br latches cannot
    * blind it.
    * ---------------------------------------------------------------------- */
`ifdef FORMAL_RETIRE_PORTS
   output logic fml_ret_bad;
   output logic fml_ret_act;
   output logic [3:0] fml_ret_badv;
`endif
   logic        r_mon_armed;
   logic [1:0]  r_mon_cnt;
   logic        r_mon_expect_zero;   /* not-taken likely: nullified slot */
   logic [`M_WIDTH-1:0] r_mon_ds_pc;
   logic 	r_mon_bad, r_mon_act;
   logic [3:0] r_mon_badv;   /* {cnt-at-restart, extra/zero-retire, wrong-ds, dual-retire} */
`ifdef VERILATOR
   logic [63:0] r_mon_arm_cnt = 'd0;
   logic [63:0] r_mon_nullify_cnt = 'd0;
`endif
`ifdef VERILATOR
   logic [63:0] r_mon_drain_cnt = 'd0;
   logic [63:0] r_mon_cfault_cnt = 'd0;
   logic [63:0] r_mon_fret_cnt = 'd0;
   always_ff@(posedge clk)
     begin
	r_mon_cfault_cnt <= r_mon_cfault_cnt
			    + ((t_complete_valid_1 && t_complete_bundle_1.faulted) ? 64'd1 : 64'd0)
			    + ((t_complete_valid_2 && t_complete_bundle_2.faulted) ? 64'd1 : 64'd0);
	if(t_retire && t_rob_head.faulted)
	  begin
	     r_mon_fret_cnt <= r_mon_fret_cnt + 64'd1;
	  end
	if((r_mon_cfault_cnt & 64'h3ff) == 64'd1023)
	  begin
	     $display("[RETMON-CNT] cyc=%0d cfaults=%0d fretire=%0d drains=%0d",
		      r_cycle, r_mon_cfault_cnt, r_mon_fret_cnt, r_mon_drain_cnt);
	  end
	if((r_state == ACTIVE) && (n_state != ACTIVE) && (r_mon_drain_cnt < 64'd12))
	  begin
	     $display("[RETMON-XSTATE] cyc=%0d n_state=%0d faulted=%b hds=%b", r_cycle, n_state,
		      t_rob_head.faulted, t_rob_head.has_delay_slot);
	  end
	if((r_state == ACTIVE) && (n_state == DRAIN))
	  begin
	     r_mon_drain_cnt <= r_mon_drain_cnt + 64'd1;
	     if(r_mon_drain_cnt < 64'd6)
	       begin
		  $display("[RETMON-DRAIN] cyc=%0d faulted=%b hds=%b nds=%b pc=%x",
			   r_cycle, t_rob_head.faulted, t_rob_head.has_delay_slot,
			   t_rob_head.has_nullifying_delay_slot, t_rob_head.pc);
	       end
	  end
     end
`endif
   wire w_mon_arm = (r_state == ACTIVE) && (n_state == DRAIN) &&
		    t_rob_head.faulted &&
		    (t_rob_head.has_delay_slot | t_rob_head.has_nullifying_delay_slot);
   wire w_mon_ret = t_retire | t_retire_two;
   wire w_mon_end_ok  = t_restart_complete;
   wire w_mon_end_af  = (n_state == ARCH_FAULT);
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_mon_armed <= 1'b0;
	     r_mon_cnt <= 2'd0;
	     r_mon_expect_zero <= 1'b0;
	     r_mon_ds_pc <= 'd0;
	     r_mon_bad <= 1'b0;
	     r_mon_act <= 1'b0;
	     r_mon_badv <= 4'd0;
	  end
	else if(w_mon_arm)
	  begin
	     r_mon_armed <= 1'b1;
	     r_mon_cnt <= 2'd0;
	     r_mon_expect_zero <= t_rob_head.has_nullifying_delay_slot & ~t_rob_head.take_br;
	     r_mon_ds_pc <= t_rob_head.pc + 'd4;
	     r_mon_act <= 1'b1;
`ifdef VERILATOR
	     r_mon_arm_cnt <= r_mon_arm_cnt + 64'd1;
	     r_mon_nullify_cnt <= r_mon_nullify_cnt +
				  ((t_rob_head.has_nullifying_delay_slot & ~t_rob_head.take_br) ? 64'd1 : 64'd0);
	     if(r_mon_arm_cnt < 64'd4 || ((r_mon_arm_cnt & 64'hfffff) == 64'd0))
	       begin
		  $display("[RETMON-ARM] cyc=%0d arms=%0d nullified=%0d pc=%x nds=%b tb=%b",
			   r_cycle, r_mon_arm_cnt, r_mon_nullify_cnt, t_rob_head.pc,
			   t_rob_head.has_nullifying_delay_slot, t_rob_head.take_br);
	       end
`endif
	  end
	else if(r_mon_armed)
	  begin
	     if(w_mon_ret)
	       begin
		  r_mon_cnt <= r_mon_cnt + (t_retire ? 2'd1 : 2'd0) + (t_retire_two ? 2'd1 : 2'd0);
		  /* any retire in the window when zero are allowed, a second retire,
		   * a dual retire, or a retire that is not the delay slot = bad */
		  if(r_mon_expect_zero
		     | (r_mon_cnt != 2'd0)
		     | t_retire_two
		     | (t_rob_head.pc != r_mon_ds_pc)
		     | ~t_rob_head.in_delay_slot)
		    begin
		       r_mon_bad <= 1'b1;
		       r_mon_badv[0] <= r_mon_badv[0] | t_retire_two;
		       r_mon_badv[1] <= r_mon_badv[1] | (t_rob_head.pc != r_mon_ds_pc) | ~t_rob_head.in_delay_slot;
		       r_mon_badv[2] <= r_mon_badv[2] | r_mon_expect_zero | (r_mon_cnt != 2'd0);
`ifdef VERILATOR
		       $display("[RETMON-BAD] cyc=%0d cnt=%0d exp0=%b two=%b pc=%x want=%x ids=%b",
				r_cycle, r_mon_cnt, r_mon_expect_zero, t_retire_two,
				t_rob_head.pc, r_mon_ds_pc, t_rob_head.in_delay_slot);
`endif
		    end
	       end
	     if(w_mon_end_ok)
	       begin
		  r_mon_armed <= 1'b0;
		  /* at a clean restart the count must equal expectation */
		  if((r_mon_expect_zero ? (r_mon_cnt != 2'd0) : (r_mon_cnt != 2'd1)) & ~w_mon_ret)
		    begin
		       r_mon_bad <= 1'b1;
		       r_mon_badv[3] <= 1'b1;
`ifdef VERILATOR
		       $display("[RETMON-BADCNT] cyc=%0d cnt=%0d exp0=%b", r_cycle, r_mon_cnt, r_mon_expect_zero);
`endif
		    end
	       end
	     else if(w_mon_end_af)
	       begin
		  r_mon_armed <= 1'b0;   /* ds arch-faulted: window void */
	       end
	  end
     end // always_ff
`ifdef FORMAL_RETIRE_PORTS
   assign fml_ret_bad = r_mon_bad;
   assign fml_ret_act = r_mon_act;
   assign fml_ret_badv = r_mon_badv;
`endif
`endif //  FORMAL_RETIRE_MON


`ifdef FORMAL_ROBWR_MON
   /* ------------------------------------------------------------------------
    * ROB write-integrity monitor (2026-09-05).  Three field-writers exist
    * (bundle_1, bundle_2, core_mem_rsp) across two always_ff blocks with
    * independent pointer fanouts.  Prove, in RTL, that
    *   [0] the two exec bundles never target the same slot in one cycle,
    *   [1] bundle_1 never writes a slot already marked complete,
    *   [2] bundle_2 never writes a slot already marked complete,
    *   [3] a mem response never completes an already-complete slot,
    *   [4] a mem response never collides with an exec bundle on one slot.
    * If these PROVE, a ring row with foreign fields (wr_echo mismatch) can only
    * be a physical mis-latch, never a logical double/misdirected write.
    * ENV: core_mem_rsp is a free input at -top core; a scoreboard tracks
    * outstanding request rob_ptrs and r_fml_env_ok goes 0 forever on any
    * response to a non-outstanding slot -- all bads are gated by it, so the
    * proof quantifies only over protocol-legal environments.
    * ---------------------------------------------------------------------- */
`ifdef FORMAL_ROBWR_PORTS
   output logic [4:0] fml_robwr_badv;
   output logic [2:0] fml_robwr_act;
`endif
   logic [N_ROB_ENTRIES-1:0] r_fml_out;
   logic r_fml_env_ok;
   logic [4:0] r_fml_badv;
   logic [2:0] r_fml_act;
   wire [`LG_ROB_ENTRIES-1:0] w_fml_p1 = t_complete_bundle_1.rob_ptr[`LG_ROB_ENTRIES-1:0];
   wire [`LG_ROB_ENTRIES-1:0] w_fml_p2 = t_complete_bundle_2.rob_ptr[`LG_ROB_ENTRIES-1:0];
   wire [`LG_ROB_ENTRIES-1:0] w_fml_pm = core_mem_rsp.rob_ptr[`LG_ROB_ENTRIES-1:0];
   wire w_fml_rsp_legal = core_mem_rsp_valid & r_fml_out[w_fml_pm];
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_fml_out <= 'd0;
	     r_fml_env_ok <= 1'b1;
	     r_fml_badv <= 5'd0;
	     r_fml_act <= 3'd0;
	  end
	else
	  begin
	     if(t_clr_rob)
	       begin
		  r_fml_out <= 'd0;
	       end
	     else
	       begin
		  if(core_mem_req_valid & core_mem_req_ack)
		    begin
		       r_fml_out[core_mem_req.rob_ptr[`LG_ROB_ENTRIES-1:0]] <= 1'b1;
		    end
		  if(core_mem_rsp_valid)
		    begin
		       r_fml_out[w_fml_pm] <= 1'b0;
		    end
	       end
	     if(core_mem_rsp_valid & !r_fml_out[w_fml_pm])
	       begin
		  r_fml_env_ok <= 1'b0;
	       end
	     /* a response is only protocol-legal THIS cycle if it targets an
	      * outstanding request; the sticky env_ok covers history, the
	      * combinational term covers the violating cycle itself. */
	     if(r_fml_env_ok)
	       begin
		  r_fml_badv[0] <= r_fml_badv[0] | (t_complete_valid_1 & t_complete_valid_2 & (w_fml_p1 == w_fml_p2));
		  r_fml_badv[1] <= r_fml_badv[1] | (t_complete_valid_1 & r_rob_complete[w_fml_p1]);
		  r_fml_badv[2] <= r_fml_badv[2] | (t_complete_valid_2 & r_rob_complete[w_fml_p2]);
		  r_fml_badv[3] <= r_fml_badv[3] | (w_fml_rsp_legal & r_rob_complete[w_fml_pm]);
		  r_fml_badv[4] <= r_fml_badv[4] | (w_fml_rsp_legal &
						    ((t_complete_valid_1 & (w_fml_p1 == w_fml_pm)) |
						     (t_complete_valid_2 & (w_fml_p2 == w_fml_pm))));
	       end
	     r_fml_act[0] <= r_fml_act[0] | t_complete_valid_1;
	     r_fml_act[1] <= r_fml_act[1] | t_complete_valid_2;
	     r_fml_act[2] <= r_fml_act[2] | (core_mem_rsp_valid & r_fml_env_ok & r_fml_out[w_fml_pm]);
	  end
     end // always_ff
`ifdef FORMAL_ROBWR_PORTS
   assign fml_robwr_badv = r_fml_badv;
   assign fml_robwr_act = r_fml_act;
`endif
`ifdef VERILATOR
   always_ff@(posedge clk)
     begin
	if(|r_fml_badv)
	  begin
	     $display("[ROBWR-BAD] cyc=%0d badv=%b", r_cycle, r_fml_badv);
	     $stop();
	  end
     end
`endif
`endif //  FORMAL_ROBWR_MON

endmodule
