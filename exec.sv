`include "uop.vh"
`include "rob.vh"

`ifdef VERILATOR
import "DPI-C" function void report_exec(input int int_valid, 
					 input int int_blocked,
					 input int mem_valid, 
					 input int mem_blocked,
					 input int fp_valid, 
					 input int fp_blocked,
					 input int iq_full,
					 input int mq_full,
					 input int fq_full,
					 input int blocked_by_store,
					 input int int_ready
					 );
`endif

module exec(clk, 
	    reset,
	    ip6,
	    ip5,
	    ip4,
	    ip3,
	    ip2,
	    retire,
	    retire_two,
	    core_epc,
	    core_wr_epc,
	    core_cause,
	    core_wr_cause,
	    core_wr_badvaddr,
	    core_badvaddr,
	    exec_epc,
	    core_wr_tlbp,
	    core_tlbp_hit,
	    core_tlbp_index,
	    save_to_tlb_regs,
	    asid,
	    sr_bev,
	    sr_exl,
	    exc_in_delay,
	    in_kernel_mode,
	    in_supervisor_mode,
	    in_user_mode,
	    in_64b_user_mode,
	    in_64b_supervisor_mode,
	    in_64b_kernel_mode,
	    putchar_fifo_out,
	    putchar_fifo_empty,
	    putchar_fifo_pop,
	    putchar_fifo_wptr,
	    putchar_fifo_rptr,
`ifdef VERILATOR
	    clear_cnt,
`endif
	    divide_ready,
	    ds_done,
	    mem_dq_clr,
	    restart_complete,
	    head_of_rob_ptr_valid,
	    head_of_rob_ptr,
	    cpr0_status_reg,
	    uq_wait,
	    mq_wait,
	    uq_full,
	    uq_next_full,
	    uq_uop,
	    uq_uop_two,
	    uq_push,
	    uq_push_two,
	    complete_bundle_1,
	    complete_valid_1,
	    mem_req, 
	    mem_req_valid, 
	    mem_req_ack,
	    core_store_data_valid,
	    core_store_data,
	    core_store_data_ack,
	    //tell rob store data has been read
	    core_store_data_ptr,
	    core_store_data_ptr_valid,
	    mem_rsp_dst_ptr,
	    mem_rsp_dst_valid,
	    mem_rsp_fp_dst,
	    mem_rsp_rob_ptr,
	    mem_rsp_load_data,
	    tlb_entry_out,
	    tlb_entry_out_valid,
	    irq_pending,
	    cp0_count
	    );
   input logic clk;
   input logic reset;
   input logic ip6;
   input logic ip5;
   input logic ip4;
   input logic ip3;
   input logic ip2;
   input logic retire;
   input logic retire_two;
   input logic [`M_WIDTH-1:0] core_epc;
       
   input logic		      core_wr_epc;
   input logic [4:0]	      core_cause;
   input logic		      core_wr_cause;
   input logic		      core_wr_badvaddr;
   input logic [`M_WIDTH-1:0] core_badvaddr;
   
   output logic [`M_WIDTH-1:0] exec_epc;
   input logic		       save_to_tlb_regs;
   input logic		       core_wr_tlbp;
   input logic		       core_tlbp_hit;
   input logic [5:0]	       core_tlbp_index;
   
   output logic [7:0]	       asid;
   
   output logic		       sr_bev;
   output logic		       sr_exl;

   input logic			exc_in_delay;
   output logic			in_kernel_mode;
   output logic			in_supervisor_mode;
   output logic			in_user_mode;

   output logic			in_64b_kernel_mode;
   output logic			in_64b_supervisor_mode;
   output logic			in_64b_user_mode;
   output logic			irq_pending;
   output logic [31:0]		cp0_count;

   
   output logic [7:0]		putchar_fifo_out;
   output logic       putchar_fifo_empty;
   input logic 	      putchar_fifo_pop;
   output logic [3:0] putchar_fifo_wptr;
   output logic [3:0] putchar_fifo_rptr;   
   
`ifdef VERILATOR
   input logic [31:0] clear_cnt;
`endif
   output logic       divide_ready;
   input logic ds_done;
   input logic mem_dq_clr;
   input logic restart_complete;
   input logic head_of_rob_ptr_valid;
   input logic [`LG_ROB_ENTRIES-1:0] head_of_rob_ptr;
   output logic [31:0]     cpr0_status_reg;
      
   localparam N_ROB_ENTRIES = (1<<`LG_ROB_ENTRIES);   
   output logic [N_ROB_ENTRIES-1:0]  uq_wait;   
   output logic [N_ROB_ENTRIES-1:0]  mq_wait;
   
   output logic 			     uq_full;
   output logic 			     uq_next_full;
   
   input 				     uop_t uq_uop;
   input 				     uop_t uq_uop_two;
   
   input logic 				     uq_push;
   input logic 				     uq_push_two;
   
   output 	complete_t complete_bundle_1;
   output logic complete_valid_1;


   output 	mem_req_t mem_req;
   output 	logic mem_req_valid;
   input logic 	      mem_req_ack;

   output logic 	      core_store_data_valid;
   output 		      mem_data_t core_store_data;
   input logic 		      core_store_data_ack;
   
   output logic [`LG_ROB_ENTRIES-1:0] core_store_data_ptr;
   output logic 		      core_store_data_ptr_valid;
   
   
   input logic [`LG_PRF_ENTRIES-1:0] mem_rsp_dst_ptr;
   input logic 			     mem_rsp_dst_valid;
   input logic 			     mem_rsp_fp_dst;
   input logic [`M_WIDTH-1:0]	     mem_rsp_load_data;
   input logic [`LG_ROB_ENTRIES-1:0] mem_rsp_rob_ptr;

   /* int-domain mem writeback: an FP mem result (mem_rsp_fp_dst) writes the FP
    * PRF, not the int PRF.  int/FP physical reg numbers OVERLAP, so int-domain
    * wakeup/bypass must gate on this -- else an FP load whose FP pdst happens to
    * equal an int op's source pdst would falsely forward FP data into the int op. */
   wire w_mem_rsp_int_valid = mem_rsp_dst_valid & ~mem_rsp_fp_dst;
   

   output tlb_data_t	             tlb_entry_out;
   output logic			     tlb_entry_out_valid;

   /* The shadow TLB is the CP0 maintenance mirror (TLBR/TLBWI/TLBWR): a plain
    * indexed 48-entry RAM (registered read by r_index, write by r_tlb_index) --
    * NOT a CAM (TLBP matches on the dtlb instead). Force it into block RAM so it
    * costs ~1 BRAM instead of ~5904 FF/LUTRAM of fabric. 48-deep is too shallow
    * for Vivado to pick BRAM unprompted. */
   `TLB_SHADOW_RAM_STYLE tlb_stored_t r_shadow_tlb[47:0];
   
   
   localparam N_INT_SCHED_ENTRIES = 1<<`LG_INT_SCHED_ENTRIES;
   
   localparam N_MQ_ENTRIES = (1<<`LG_MQ_ENTRIES);
   localparam N_INT_PRF_ENTRIES = (1<<`LG_PRF_ENTRIES);
   localparam N_HILO_PRF_ENTRIES = (1<<`LG_HILO_PRF_ENTRIES);
   
   localparam N_UQ_ENTRIES = (1<<`LG_UQ_ENTRIES);
   localparam N_MEM_UQ_ENTRIES = (1<<`LG_MEM_UQ_ENTRIES);
   localparam N_MEM_DQ_ENTRIES = (1<<`LG_MEM_DQ_ENTRIES);
   
   logic [(`M_WIDTH*2)-1:0] r_hilo_prf[N_HILO_PRF_ENTRIES-1:0];
      
   logic [N_INT_PRF_ENTRIES-1:0]  r_prf_inflight, n_prf_inflight;
   logic [N_HILO_PRF_ENTRIES-1:0] r_hilo_inflight, n_hilo_inflight;

   /* FP register file (shared by the mem-pipe mover now, the FPU later).
    * 64-bit regs; FR=1/N32 model. */
   logic [`M_WIDTH-1:0] 	  r_fp_prf[N_INT_PRF_ENTRIES-1:0];
   /* registered FP read ports (rf4r2w-style synchronous read): address presented
    * from the combinational head, output aligned with mem_uq / mem_dq.  Matches the
    * int PRF's registered-read pattern so synth maps cleanly (no async-read on a
    * combinational BRAM read). srcB = mfc1 source; dq = FP store data. */
   logic [`M_WIDTH-1:0] 	  r_fp_rd_srcB, r_fp_rd_dq;
   logic [N_INT_PRF_ENTRIES-1:0]  r_fp_prf_inflight, n_fp_prf_inflight;

   logic 			  t_wr_int_prf, t_wr_cpr0, t_wr_cpr0_64;
   logic 			  t_wr_fcsr;
   logic [`M_WIDTH-1:0]		  t_csr0_val, t_csr0_64_val;
   
   logic 	t_wr_hilo;
   logic	t_overflow;
   logic	t_eret;
   logic	t_trap;
   
   logic	t_clr_erl;
   logic 	t_take_br;
   logic 	t_mispred_br;
   logic 	t_alu_valid;
      
   
   mem_req_t r_mem_q[N_MQ_ENTRIES-1:0];
   logic [`LG_MQ_ENTRIES:0] r_mq_head_ptr, n_mq_head_ptr;
   logic [`LG_MQ_ENTRIES:0] r_mq_tail_ptr, n_mq_tail_ptr;
   logic [`LG_MQ_ENTRIES:0] r_mq_next_tail_ptr, n_mq_next_tail_ptr;
   mem_req_t t_mem_tail, t_mem_head;
   logic 		    mem_q_full,mem_q_next_full, mem_q_empty;


   mem_data_t r_mdq[N_MQ_ENTRIES-1:0];
   mem_data_t t_mdq_tail, t_mdq_head;
   
   logic [`LG_MQ_ENTRIES:0] r_mdq_head_ptr, n_mdq_head_ptr;
   logic [`LG_MQ_ENTRIES:0] r_mdq_tail_ptr, n_mdq_tail_ptr;
   logic [`LG_MQ_ENTRIES:0] r_mdq_next_tail_ptr, n_mdq_next_tail_ptr;
   logic 		    mem_mdq_full,mem_mdq_next_full, mem_mdq_empty;
   

   logic [3:0]		    r_rd_pc_idx, n_rd_pc_idx;
   logic [3:0]		    r_wr_pc_idx, n_wr_pc_idx;
   logic [7:0]		    r_pc_buf [7:0];
   logic t_push_putchar;
   
   

   logic 	t_pop_uq,t_pop_mem_uq,t_pop_mem_dq;
   logic 	r_mem_ready, r_dq_ready;
   
   
   localparam E_BITS = `M_WIDTH-16;
   localparam HI_EBITS = `M_WIDTH-32;
   
   logic [`M_WIDTH-1:0] t_simm, t_mem_simm;
   logic [`M_WIDTH-1:0] t_result;
   logic [`M_WIDTH-1:0] t_cpr0_result;

   
   logic [(`M_WIDTH*2)-1:0] t_hilo_result;
   
   logic [`M_WIDTH-1:0] t_pc, t_pc4, t_pc8;
   logic [27:0] t_jaddr;
   logic 	t_srcs_rdy;

   
   wire [`M_WIDTH-1:0] w_srcA, w_srcB;
   wire [`M_WIDTH-1:0] w_mem_srcA, w_mem_srcB;
   
   logic [`M_WIDTH-1:0] r_mem_result, r_int_result;
   logic 	r_fwd_int_srcA, r_fwd_int_srcB;
   logic 	r_fwd_mem_srcA, r_fwd_mem_srcB;

   logic t_fwd_int_mem_srcA,t_fwd_int_mem_srcB,t_fwd_mem_mem_srcA,t_fwd_mem_mem_srcB;
   logic r_fwd_int_mem_srcA,r_fwd_int_mem_srcB,r_fwd_mem_mem_srcA,r_fwd_mem_mem_srcB;
   
   logic [(`M_WIDTH*2)-1:0] r_int_hilo, r_mul_hilo, r_div_hilo;
   logic [(`M_WIDTH*2)-1:0] r_src_hilo;
   logic 	r_fwd_hilo_int, r_fwd_hilo_mul, r_fwd_hilo_div;
      
   logic [`M_WIDTH-1:0] t_srcA, t_srcB;
   logic [`M_WIDTH-1:0] t_mem_srcA, t_mem_srcB;
   
   
   logic [(`M_WIDTH*2)-1:0] t_src_hilo;
   logic [`M_WIDTH-1:0] t_cpr0_srcA;
   
   
   logic 	t_unimp_op;
   logic 	t_fault;
   
   logic 	t_signed_shift;
   logic [`LG_M_WIDTH-1:0] t_shift_amt;
   
   logic [31:0] t_shift_right;

   logic 	t_start_mul;
   logic 	t_mul_complete;
   logic [(`M_WIDTH*2)-1:0] t_mul_result;
   
   logic 	t_hilo_prf_ptr_val_out;
   logic [`LG_ROB_ENTRIES-1:0] t_rob_ptr_out;

   
   logic [`LG_HILO_PRF_ENTRIES-1:0] t_hilo_prf_ptr_out;
   
   logic [`MAX_LAT:0] r_wb_bitvec, n_wb_bitvec;

   /* divider */
   logic 	t_div_ready, t_signed_div, t_start_div32, t_start_div64;
   logic [`LG_ROB_ENTRIES-1:0] t_div_rob_ptr_out;
   logic [(`M_WIDTH*2)-1:0] 	       t_div_result;
   logic [`LG_HILO_PRF_ENTRIES-1:0] t_div_hilo_prf_ptr_out;
   logic 			    t_div_complete;

   logic [N_ROB_ENTRIES-1:0] 	    r_uq_wait, r_mq_wait;
   /* non mem uop queue */
   uop_t r_uq[N_UQ_ENTRIES];
   uop_t uq, int_uop;
   logic 			    r_start_int;
   
   
   
   logic 			    t_uq_read, t_uq_empty, t_uq_full, t_uq_next_full;
   logic [`LG_UQ_ENTRIES:0] 	    r_uq_head_ptr, n_uq_head_ptr;
   logic [`LG_UQ_ENTRIES:0] 	    r_uq_tail_ptr, n_uq_tail_ptr;
   logic [`LG_UQ_ENTRIES:0] 	    r_uq_next_head_ptr, n_uq_next_head_ptr;
   logic [`LG_UQ_ENTRIES:0] 	    r_uq_next_tail_ptr, n_uq_next_tail_ptr;

   /* mem uop queue */
   uop_t r_mem_uq[N_MEM_UQ_ENTRIES];
   uop_t t_mem_uq, mem_uq;
   logic 	      t_mem_uq_read, t_mem_uq_empty, t_mem_uq_full,
		      t_mem_uq_next_full;
   
   logic [`LG_MEM_UQ_ENTRIES:0]  r_mem_uq_head_ptr, n_mem_uq_head_ptr;
   logic [`LG_MEM_UQ_ENTRIES:0]  r_mem_uq_tail_ptr, n_mem_uq_tail_ptr;
   logic [`LG_MEM_UQ_ENTRIES:0] r_mem_uq_next_head_ptr, n_mem_uq_next_head_ptr;
   logic [`LG_MEM_UQ_ENTRIES:0] r_mem_uq_next_tail_ptr, n_mem_uq_next_tail_ptr;

   /* mem data queue */
   //uop_t r_mem_uq[N_MEM_UQ_ENTRIES];
  // uop_t t_mem_uq, mem_uq;
   dq_t r_mem_dq[N_MEM_DQ_ENTRIES];
   dq_t t_dq0, t_dq1, t_mem_dq, mem_dq;
   mem_data_t t_core_store_data;
   
   logic 	      t_mem_dq_read, t_mem_dq_empty, t_mem_dq_full,
		      t_mem_dq_next_full;
   
   logic [`LG_MEM_DQ_ENTRIES:0]  r_mem_dq_head_ptr, n_mem_dq_head_ptr;
   logic [`LG_MEM_DQ_ENTRIES:0]  r_mem_dq_tail_ptr, n_mem_dq_tail_ptr;
   logic [`LG_MEM_DQ_ENTRIES:0] r_mem_dq_next_head_ptr, n_mem_dq_next_head_ptr;
   logic [`LG_MEM_DQ_ENTRIES:0] r_mem_dq_next_tail_ptr, n_mem_dq_next_tail_ptr;

   
   logic             t_push_two_mem,  t_push_two_int;
   logic             t_push_one_mem,  t_push_one_int;
   logic 	     t_push_two_dq, t_push_one_dq;
   
   logic 			t_flash_clear;
   always_comb
     begin
	t_flash_clear = ds_done;
     end

   always_comb
     begin
	uq_full = t_uq_full || t_mem_uq_full || t_mem_dq_full;
	uq_next_full = t_uq_next_full || t_mem_uq_next_full || t_mem_dq_next_full;
     end
   
   always_ff@(posedge clk)
     begin
	if(reset || t_flash_clear)
	  begin
	     r_uq_head_ptr <= 'd0;
	     r_uq_tail_ptr <= 'd0;
	     r_uq_next_head_ptr <= 'd1;
	     r_uq_next_tail_ptr <= 'd1;	     
	  end
	else
	  begin
	     r_uq_head_ptr <=  n_uq_head_ptr;
	     r_uq_tail_ptr <=  n_uq_tail_ptr;
	     r_uq_next_head_ptr <= n_uq_next_head_ptr;
	     r_uq_next_tail_ptr <= n_uq_next_tail_ptr;	     
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	if(reset  || t_flash_clear)
	  begin
	     r_mem_uq_head_ptr <= 'd0;
	     r_mem_uq_tail_ptr <= 'd0;
	     r_mem_uq_next_head_ptr <= 'd1;
	     r_mem_uq_next_tail_ptr <= 'd1;
	  end
	else
	  begin
	     r_mem_uq_head_ptr <= n_mem_uq_head_ptr;
	     r_mem_uq_tail_ptr <= n_mem_uq_tail_ptr;
	     r_mem_uq_next_head_ptr <= n_mem_uq_next_head_ptr;
	     r_mem_uq_next_tail_ptr <= n_mem_uq_next_tail_ptr;
	  end
     end // always_ff@ (posedge clk// )
   
   always_ff@(posedge clk)
     begin
	if(reset  || mem_dq_clr)
	  begin
	     r_mem_dq_head_ptr <= 'd0;
	     r_mem_dq_tail_ptr <= 'd0;
	     r_mem_dq_next_head_ptr <= 'd1;
	     r_mem_dq_next_tail_ptr <= 'd1;
	  end
	else
	  begin
	     r_mem_dq_head_ptr <= n_mem_dq_head_ptr;
	     r_mem_dq_tail_ptr <= n_mem_dq_tail_ptr;
	     r_mem_dq_next_head_ptr <= n_mem_dq_next_head_ptr;
	     r_mem_dq_next_tail_ptr <= n_mem_dq_next_tail_ptr;
	  end
     end // always_ff@ (posedge clk// )
   
   

   /* a mem uop carries store data (-> store-data queue) when it has an int srcB
    * (stores + merge-loads) or is an FP store reading the FP PRF (swc1/sdc1). */
   wire w_uop_has_sdata  = uq_uop.is_mem     && (uq_uop.srcB_valid     || (uq_uop.fp_srcB_valid     && uq_uop.is_store));
   wire w_uop2_has_sdata = uq_uop_two.is_mem && (uq_uop_two.srcB_valid || (uq_uop_two.fp_srcB_valid && uq_uop_two.is_store));

   always_comb
     begin
	n_mem_uq_head_ptr = r_mem_uq_head_ptr;
	n_mem_uq_tail_ptr = r_mem_uq_tail_ptr;
	n_mem_uq_next_head_ptr = r_mem_uq_next_head_ptr;
	n_mem_uq_next_tail_ptr = r_mem_uq_next_tail_ptr;
	
	n_mem_dq_head_ptr = r_mem_dq_head_ptr;
	n_mem_dq_tail_ptr = r_mem_dq_tail_ptr;
	n_mem_dq_next_head_ptr = r_mem_dq_next_head_ptr;
	n_mem_dq_next_tail_ptr = r_mem_dq_next_tail_ptr;


	
	t_mem_uq_empty = (r_mem_uq_head_ptr == r_mem_uq_tail_ptr);
	t_mem_uq_full = (r_mem_uq_head_ptr != r_mem_uq_tail_ptr) && (r_mem_uq_head_ptr[`LG_MEM_UQ_ENTRIES-1:0] == r_mem_uq_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]);

	t_mem_uq_next_full = (r_mem_uq_head_ptr != r_mem_uq_next_tail_ptr) && 
			     (r_mem_uq_head_ptr[`LG_MEM_UQ_ENTRIES-1:0] == r_mem_uq_next_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]);

	t_mem_dq_empty = (r_mem_dq_head_ptr == r_mem_dq_tail_ptr);
	t_mem_dq_full = (r_mem_dq_head_ptr != r_mem_dq_tail_ptr) && (r_mem_dq_head_ptr[`LG_MEM_DQ_ENTRIES-1:0] == r_mem_dq_tail_ptr[`LG_MEM_DQ_ENTRIES-1:0]);

	t_mem_dq_next_full = (r_mem_dq_head_ptr != r_mem_dq_next_tail_ptr) && 
			     (r_mem_dq_head_ptr[`LG_MEM_DQ_ENTRIES-1:0] == r_mem_dq_next_tail_ptr[`LG_MEM_DQ_ENTRIES-1:0]);
		
	t_mem_uq = r_mem_uq[r_mem_uq_head_ptr[`LG_MEM_UQ_ENTRIES-1:0]];

	t_mem_dq = r_mem_dq[r_mem_dq_head_ptr[`LG_MEM_DQ_ENTRIES-1:0]];

	t_push_two_mem = uq_push && uq_push_two && uq_uop.is_mem && uq_uop_two.is_mem;
	t_push_one_mem = ((uq_push && uq_uop.is_mem) || (uq_push_two && uq_uop_two.is_mem)) && !t_push_two_mem;

	t_push_two_dq = uq_push && uq_push_two &&
			w_uop_has_sdata && w_uop2_has_sdata;

	t_push_one_dq = (uq_push_two && w_uop2_has_sdata) ||
			(uq_push && w_uop_has_sdata);
	
	
	if(t_push_two_dq)
	  begin
	     n_mem_dq_tail_ptr = r_mem_dq_tail_ptr + 'd2;
	     n_mem_dq_next_tail_ptr = r_mem_dq_next_tail_ptr + 'd2;	     
	  end
	else if(t_push_one_dq)
	  begin
	     n_mem_dq_tail_ptr = r_mem_dq_tail_ptr + 'd1;
	     n_mem_dq_next_tail_ptr = r_mem_dq_next_tail_ptr + 'd1;
	  end
	
	/* these need work */
	if(t_push_two_mem)
	  begin
	     n_mem_uq_tail_ptr = r_mem_uq_tail_ptr + 'd2;
	     n_mem_uq_next_tail_ptr = r_mem_uq_next_tail_ptr + 'd2;

	  end
	else if(uq_push_two && uq_uop_two.is_mem || uq_push && uq_uop.is_mem)
	  begin
	     n_mem_uq_tail_ptr = r_mem_uq_tail_ptr + 'd1;
	     n_mem_uq_next_tail_ptr = r_mem_uq_next_tail_ptr + 'd1;
	  end
	
	if(t_pop_mem_uq)
	  begin
	     n_mem_uq_head_ptr = r_mem_uq_head_ptr + 'd1;
	  end
	if(t_pop_mem_dq)
	  begin
	     n_mem_dq_head_ptr = r_mem_dq_head_ptr + 'd1;
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	mem_uq <= t_mem_uq;
	mem_dq <= t_mem_dq;
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_mq_wait <= 'd0;
	     r_uq_wait <= 'd0;
	  end
	else if(restart_complete)
	  begin
	     r_mq_wait <= 'd0;
	     r_uq_wait <= 'd0;
	  end
	else
	  begin
	     //mem port
	     if(t_push_two_mem)
	       begin
		  r_mq_wait[uq_uop_two.rob_ptr] <= 1'b1;
		  r_mq_wait[uq_uop.rob_ptr] <= 1'b1;
	       end
	     else if(t_push_one_mem)
	       begin
		  r_mq_wait[uq_uop.is_mem ? uq_uop.rob_ptr : uq_uop_two.rob_ptr] <= 1'b1; 
	       end
	     if(t_pop_mem_uq)
	       begin
		  r_mq_wait[t_mem_uq.rob_ptr] <= 1'b0;		  
	       end
	     
	     //int port
	     if(t_push_two_int)
	       begin
		  r_uq_wait[uq_uop.rob_ptr] <= 1'b1;
		  r_uq_wait[uq_uop_two.rob_ptr] <= 1'b1;
	       end
	     else if(t_push_one_int)
	       begin
		  r_uq_wait[uq_uop.is_int ? uq_uop.rob_ptr : uq_uop_two.rob_ptr] <= 1'b1; 
	       end
	     
	     if(r_start_int)
	       begin
		  r_uq_wait[int_uop.rob_ptr] <= 1'b0;
	       end

	  end // else: !if(reset)
     end // always_ff@ (posedge clk)

   
   always_ff@(posedge clk)
     begin
	if(t_push_two_mem)
	  begin
	     //$display("cycle %d : pushing mem ops for rob slots %d & %d", r_cycle, uq_uop_two.rob_ptr, uq_uop.rob_ptr);
	     r_mem_uq[r_mem_uq_next_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]] <= uq_uop_two;
	     r_mem_uq[r_mem_uq_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]] <= uq_uop;
	  end
	else if(t_push_one_mem)
	  begin
	     //$display("cycle %d : pushing mem ops for rob slots %d", r_cycle, uq_uop.rob_ptr);
	     r_mem_uq[r_mem_uq_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]] <= uq_uop.is_mem ? uq_uop : uq_uop_two;
	  end	
     end // always_ff@ (posedge clk)


   always_comb     
     begin
	t_dq0.rob_ptr = uq_uop.rob_ptr;
	t_dq0.src_ptr = uq_uop.srcB;
	t_dq0.fp = uq_uop.fp_srcB_valid;
	t_dq1.rob_ptr = uq_uop_two.rob_ptr;
	t_dq1.src_ptr = uq_uop_two.srcB;
	t_dq1.fp = uq_uop_two.fp_srcB_valid;
     end

       

   
   always_ff@(posedge clk)
     begin
	if(t_push_two_dq)
	  begin
	     r_mem_dq[r_mem_dq_next_tail_ptr[`LG_MEM_DQ_ENTRIES-1:0]] <= t_dq1;
	     r_mem_dq[r_mem_dq_tail_ptr[`LG_MEM_DQ_ENTRIES-1:0]] <= t_dq0;
	  end
	else if(t_push_one_dq)
	  begin
	     r_mem_dq[r_mem_dq_tail_ptr[`LG_MEM_DQ_ENTRIES-1:0]] <= w_uop_has_sdata ? t_dq0 : t_dq1;
	  end	
     end
   
   

   
   always_comb
     begin
	n_uq_head_ptr = r_uq_head_ptr;
	n_uq_tail_ptr = r_uq_tail_ptr;
	n_uq_next_head_ptr = r_uq_next_head_ptr;
	n_uq_next_tail_ptr = r_uq_next_tail_ptr;
	
	
	t_uq_empty = (r_uq_head_ptr == r_uq_tail_ptr);
	t_uq_full = (r_uq_head_ptr != r_uq_tail_ptr) && 
		    (r_uq_head_ptr[`LG_UQ_ENTRIES-1:0] == r_uq_tail_ptr[`LG_UQ_ENTRIES-1:0]);
	
	t_uq_next_full = (r_uq_head_ptr != r_uq_next_tail_ptr) && 
			 (r_uq_head_ptr[`LG_UQ_ENTRIES-1:0] == r_uq_next_tail_ptr[`LG_UQ_ENTRIES-1:0]);

	t_push_two_int = uq_push && uq_push_two && uq_uop.is_int && uq_uop_two.is_int;
	t_push_one_int = ((uq_push && uq_uop.is_int) || (uq_push_two && uq_uop_two.is_int)) && !t_push_two_int;
	
	uq = r_uq[r_uq_head_ptr[`LG_UQ_ENTRIES-1:0]];
	
	if(t_push_two_int)
	  begin	     
	     n_uq_tail_ptr = r_uq_tail_ptr + 'd2;
	     n_uq_next_tail_ptr = r_uq_next_tail_ptr + 'd2;
	  end
	else if(uq_push_two && uq_uop_two.is_int || uq_push && uq_uop.is_int)
	  begin	     
	     n_uq_tail_ptr = r_uq_tail_ptr + 'd1;
	     n_uq_next_tail_ptr = r_uq_next_tail_ptr + 'd1;
	  end

	
	if(t_pop_uq)
	  begin
	     n_uq_head_ptr = r_uq_head_ptr + 'd1;
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(t_push_two_int)
	  begin
	     r_uq[r_uq_tail_ptr[`LG_UQ_ENTRIES-1:0]] <= uq_uop;
	     r_uq[r_uq_next_tail_ptr[`LG_UQ_ENTRIES-1:0]] <= uq_uop_two;	     
	  end
	else if(t_push_one_int)
	  begin
	     r_uq[r_uq_tail_ptr[`LG_UQ_ENTRIES-1:0]] <= uq_uop.is_int ? uq_uop : uq_uop_two;
	  end
	
     end // always_ff@ (posedge clk)
   
   logic [31:0]        r_cycle, r_retired_insns;
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : r_cycle + 'd1;
	
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_retired_insns <= 'd0;
	  end
	else if(retire_two)
	  begin
	     r_retired_insns <= r_retired_insns + 'd2;
	  end
	else if(retire) 
	  begin
	     r_retired_insns <= r_retired_insns + 'd1;
	  end
     end // always_ff@ (posedge clk)   


   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_wb_bitvec <= 'd0;
	  end
	else
	  begin
	     r_wb_bitvec <= n_wb_bitvec;
	  end
     end // always_ff@ (posedge clk)

   always_comb
     begin
	for(integer i = (`MAX_LAT-1); i > -1; i = i-1)
	  begin
	     n_wb_bitvec[i] = r_wb_bitvec[i+1];	     
	  end
	n_wb_bitvec[`DIV32_LAT] = (t_start_div32 | t_start_div64) & r_start_int;
	
	if(t_start_mul&r_start_int)
	  begin
	     n_wb_bitvec[`MUL_LAT] = 1'b1;
	  end
     end // always_comb

   
   always_comb
     begin
	t_srcA = r_fwd_int_srcA ? r_int_result :
		 r_fwd_mem_srcA ? r_mem_result :
		 w_srcA;
	
	t_srcB = r_fwd_int_srcB ? r_int_result :
		 r_fwd_mem_srcB ? r_mem_result :
		 w_srcB;

	t_mem_srcA = r_fwd_int_mem_srcA ? r_int_result :
		     r_fwd_mem_mem_srcA ? r_mem_result :
		     w_mem_srcA;

	t_mem_srcB = r_fwd_int_mem_srcB ? r_int_result :
		     r_fwd_mem_mem_srcB ? r_mem_result :
		     w_mem_srcB;
	
	t_src_hilo = r_fwd_hilo_int ? r_int_hilo :
		     r_fwd_hilo_mul ? r_mul_hilo :
		     r_fwd_hilo_div ? r_div_hilo :
		     r_src_hilo;
     end // always_comb




   //does this scheduler entry contain a valid uop?
   logic [N_INT_SCHED_ENTRIES-1:0] r_alu_sched_valid;
   logic [`LG_INT_SCHED_ENTRIES:0] t_alu_sched_alloc_ptr;
   logic 			  t_alu_sched_full;
   
   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_alloc_entry, t_alu_select_entry;

   uop_t r_alu_sched_uops[N_INT_SCHED_ENTRIES-1:0];
   uop_t t_picked_uop;

   
   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_entry_rdy;
   logic [`LG_INT_SCHED_ENTRIES:0]  t_alu_sched_select_ptr;
   
	
   logic [N_INT_SCHED_ENTRIES-1:0] r_alu_srcA_rdy, 
				   r_alu_srcB_rdy, 
				   r_alu_hilo_rdy;
   
   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_srcA_match, 
				   t_alu_srcB_match, 
				   t_alu_hilo_match;
   


   logic t_alu_alloc_srcA_match, 
	 t_alu_alloc_srcB_match, 
	 t_alu_alloc_hilo_match;
   
   wire [N_INT_SCHED_ENTRIES-1:0] w_alu_sched_oldest_ready;
   
   find_first_set#(`LG_INT_SCHED_ENTRIES) ffs_int_sched_alloc( .in(~r_alu_sched_valid),
							      .y(t_alu_sched_alloc_ptr));

   find_first_set#(`LG_INT_SCHED_ENTRIES) ffs_int_sched_select( .in(w_alu_sched_oldest_ready),
								.y(t_alu_sched_select_ptr));

   
   
   always_comb
     begin
	t_alu_alloc_entry = 'd0;
	t_alu_select_entry = 'd0;
	if(t_pop_uq)
	  begin
	     t_alu_alloc_entry[t_alu_sched_alloc_ptr[`LG_INT_SCHED_ENTRIES-1:0]] = 1'b1;
	  end
	if(t_alu_entry_rdy != 'd0)
	  begin
	     t_alu_select_entry[t_alu_sched_select_ptr[`LG_INT_SCHED_ENTRIES-1:0]] = 1'b1;
	  end
     end // always_comb




   always_comb
     begin
	t_picked_uop = r_alu_sched_uops[t_alu_sched_select_ptr[`LG_INT_SCHED_ENTRIES-1:0]];
     end
   
   always_ff@(posedge clk)
     begin
	int_uop <= t_picked_uop;
     end

   always_ff@(posedge clk)
     begin
	r_start_int <= reset ? 1'b0 : ((t_alu_entry_rdy != 'd0) & !ds_done);
     end // always_comb

   
   
   always_comb
     begin
	//allocation forwarding
	t_alu_alloc_srcA_match = uq.srcA_valid && (
						   (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == uq.srcA)) ||
						   (r_start_int && t_wr_int_prf & (int_uop.dst == uq.srcA))
						   );
	t_alu_alloc_srcB_match = uq.srcB_valid && (
						   (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == uq.srcB)) ||
						   (r_start_int && t_wr_int_prf & (int_uop.dst == uq.srcB))
						   );

	t_alu_alloc_hilo_match = uq.hilo_src_valid && (
						       (t_hilo_prf_ptr_val_out & (t_hilo_prf_ptr_out == uq.hilo_src)) ||
						       (t_div_complete && (t_div_hilo_prf_ptr_out == uq.hilo_src)) ||
						       (r_start_int && t_wr_hilo && (int_uop.hilo_dst == uq.hilo_src))
						       );
	
     end // always_comb
  

   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_sched_mask_valid;
   logic [N_INT_SCHED_ENTRIES-1:0] r_alu_sched_matrix [N_INT_SCHED_ENTRIES-1:0];

   
   always_comb
     begin
	t_alu_sched_mask_valid = r_alu_sched_valid & (~t_alu_select_entry);
     end

   generate
      for(genvar i = 0; i < N_INT_SCHED_ENTRIES; i=i+1)
	begin
	   assign w_alu_sched_oldest_ready[i] = t_alu_entry_rdy[i] & (~(|(t_alu_entry_rdy & r_alu_sched_matrix[i])));
	   always_ff@(posedge clk)
	     begin
		if(reset || t_flash_clear)
		  begin
		     r_alu_sched_matrix[i] <= 'd0;
		  end
		else if(t_alu_alloc_entry[i])
		  begin
		     r_alu_sched_matrix[i] <= t_alu_sched_mask_valid;
		  end
		else if(t_alu_entry_rdy != 'd0)
		  begin
		     r_alu_sched_matrix[i] <= r_alu_sched_matrix[i] & (~t_alu_select_entry);
		  end
	     end
	end // for (genvar i = 0; i < N_INT_SCHED_ENTRIES; i=i+1)
   endgenerate

   //always_ff@(negedge clk)
   //begin
   //if(t_alu_entry_rdy != 'd0)
   //	  $display("w_alu_sched_oldest = %b, w_alu_sched_oldest_ready = %b, t_alu_entry_rdy = %b", 
   //w_alu_sched_oldest, w_alu_sched_oldest_ready, t_alu_entry_rdy);
   //end
   
   generate
      for(genvar i = 0; i < N_INT_SCHED_ENTRIES; i=i+1)
	begin
	   always_comb
	     begin
		t_alu_srcA_match[i] = r_alu_sched_uops[i].srcA_valid && (
									 (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == r_alu_sched_uops[i].srcA)) ||
									 (r_start_int && t_wr_int_prf & (int_uop.dst == r_alu_sched_uops[i].srcA))
									 );
		t_alu_srcB_match[i] = r_alu_sched_uops[i].srcB_valid && (
									 (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == r_alu_sched_uops[i].srcB)) ||
									 (r_start_int && t_wr_int_prf & (int_uop.dst == r_alu_sched_uops[i].srcB))
									 );
		
		t_alu_hilo_match[i] = r_alu_sched_uops[i].hilo_src_valid && (
									     (t_hilo_prf_ptr_val_out & (t_hilo_prf_ptr_out == r_alu_sched_uops[i].hilo_src)) ||
									     (t_div_complete && (t_div_hilo_prf_ptr_out == r_alu_sched_uops[i].hilo_src)) ||
									     (r_start_int && t_wr_hilo && (int_uop.hilo_dst == r_alu_sched_uops[i].hilo_src))
									     );
		

		//is_mult(r_alu_sched_uops[i].op);
		
		t_alu_entry_rdy[i] = r_alu_sched_valid[i] &&
				     (is_div(r_alu_sched_uops[i].op) ?  t_div_ready :  (is_mult(r_alu_sched_uops[i].op) ?  !r_wb_bitvec[`MUL_LAT+2] : !r_wb_bitvec[1]))
				     ? (
					(t_alu_srcA_match[i] |r_alu_srcA_rdy[i]) &
					(t_alu_srcB_match[i] |r_alu_srcB_rdy[i]) &
					(t_alu_hilo_match[i] |r_alu_hilo_rdy[i]) &
					(!r_alu_sched_uops[i].oldest_first ||
					 (head_of_rob_ptr_valid &&
					  (r_alu_sched_uops[i].rob_ptr == head_of_rob_ptr))) ) : 1'b0;
	     end // always_comb
	   
	   always_ff@(posedge clk)
	     begin
		if(reset)
		  begin
		     r_alu_srcA_rdy[i] <= 1'b0;
		     r_alu_srcB_rdy[i] <= 1'b0;
		     r_alu_hilo_rdy[i] <= 1'b0;
		  end
		else
		  begin
		     if(t_alu_alloc_entry[i])
		       begin //allocating to this entry
			  r_alu_srcA_rdy[i] <= uq.srcA_valid ? (!r_prf_inflight[uq.srcA] | t_alu_alloc_srcA_match) : 1'b1;
			  r_alu_srcB_rdy[i] <= uq.srcB_valid ? (!r_prf_inflight[uq.srcB] | t_alu_alloc_srcB_match) : 1'b1;
			  r_alu_hilo_rdy[i] <= uq.hilo_src_valid ? (!r_hilo_inflight[uq.hilo_src] | t_alu_alloc_hilo_match) : 1'b1;
		       end
		     else if(t_alu_select_entry[i])
		       begin
			  r_alu_srcA_rdy[i] <= 1'b0;
			  r_alu_srcB_rdy[i] <= 1'b0;
			  r_alu_hilo_rdy[i] <= 1'b0;
		       end
		     else if(r_alu_sched_valid[i])
		       begin
			  r_alu_srcA_rdy[i] <= r_alu_srcA_rdy[i] | t_alu_srcA_match[i];
			  r_alu_srcB_rdy[i] <= r_alu_srcB_rdy[i] | t_alu_srcB_match[i];
			  r_alu_hilo_rdy[i] <= r_alu_hilo_rdy[i] | t_alu_hilo_match[i];
		       end // else: !if(t_pop_uq&&(t_alu_sched_alloc_ptr == i))
		     
		  end // else: !if(reset)
	     end // always_ff@ (posedge clk)
	end // for (genvar i = 0; i < LG_INT_SCHED_ENTRIES; i=i+1)
   endgenerate
   
   
   
   always_comb
     begin
	t_pop_uq = 1'b0;
	t_alu_sched_full = (&r_alu_sched_valid);
	t_pop_uq = !(t_flash_clear || t_uq_empty ||t_alu_sched_full);
     end
   
   always_ff@(posedge clk)
     begin
	if(reset || t_flash_clear)
	  begin
	     r_alu_sched_valid <= 'd0;
	  end
	else
	  begin
	     if(t_pop_uq)
	       begin
		  r_alu_sched_valid[t_alu_sched_alloc_ptr[`LG_INT_SCHED_ENTRIES-1:0]] <= 1'b1;
		  r_alu_sched_uops[t_alu_sched_alloc_ptr[`LG_INT_SCHED_ENTRIES-1:0]] <= uq;
	       end
	     if(t_alu_entry_rdy != 'd0)
	       begin
		  r_alu_sched_valid[t_alu_sched_select_ptr[`LG_INT_SCHED_ENTRIES-1:0]] <= 1'b0;
	       end
	  end // else: !if(reset)
     end

   logic t_32b_shift, t_shift_left;

   wire [`M_WIDTH-1:0] w_shifter_out;   
   generate
      if(`M_WIDTH == 64)
	begin
	   wire [63:0] w_shift_src = t_32b_shift ? 
				     {{32{(t_signed_shift ? t_srcA[31] : 1'b0)}}, t_srcA[31:0]} : 
				     t_srcA;   

	   shift_right #(.LG_W(6)) 
	   s0(
	      .is_left(t_shift_left),
	      .is_signed(t_signed_shift),
	      .is_circular(1'b0),
	      .data(w_shift_src), 
	      .distance(t_shift_amt),
	      .y(w_shifter_out)
	      );

	end
      else
	begin
	   shift_right #(.LG_W(5)) 
	   s0(
	      .is_left(t_shift_left),
	      .is_signed(t_signed_shift),
	      .is_circular(1'b0),
	      .data(t_srcA[31:0]), 
	      .distance(t_shift_amt),
	      .y(w_shifter_out)
	      );

	end // UNMATCHED !!
   endgenerate
   
   
   mul #(.W(`M_WIDTH)) m(
			 .clk(clk),
			 .reset(reset),
			 .is_signed(int_uop.op != MULTU && int_uop.op != DMULTU),
			 .go(t_start_mul&r_start_int),
			 .is_32b(int_uop.op == MULT || int_uop.op == MULTU),
			 .src_A(t_srcA),
			 .src_B(t_srcB),
			 .rob_ptr_in(int_uop.rob_ptr),
			 .hilo_prf_ptr_in(int_uop.hilo_dst),
			 .y(t_mul_result),
			 .complete(t_mul_complete),
			 .rob_ptr_out(t_rob_ptr_out),
			 .hilo_prf_ptr_val_out(t_hilo_prf_ptr_val_out),
			 .hilo_prf_ptr_out(t_hilo_prf_ptr_out)
	 );

   divider #(.LG_W(`LG_M_WIDTH))
   d0 (
       .clk(clk),
       .reset(reset),
       .is_32b(t_start_div32),
       .srcA(t_srcA),
       .srcB(t_srcB),
       .rob_ptr_in(int_uop.rob_ptr),
       .hilo_prf_ptr_in(int_uop.hilo_dst),
       .is_signed_div(t_signed_div),
       .start_div(t_start_div32 | t_start_div64),
       .y(t_div_result),
       .rob_ptr_out(t_div_rob_ptr_out),
       .hilo_prf_ptr_out(t_div_hilo_prf_ptr_out),
       .complete(t_div_complete),
       .ready(t_div_ready)
       );
   
   assign divide_ready = t_div_ready;




   
   always_comb
     begin
	n_mq_head_ptr = r_mq_head_ptr;
	n_mq_tail_ptr = r_mq_tail_ptr;
	n_mq_next_tail_ptr = r_mq_next_tail_ptr;
	
	if(r_mem_ready)
	  begin
	     n_mq_tail_ptr = r_mq_tail_ptr + 'd1;
	     n_mq_next_tail_ptr = r_mq_next_tail_ptr + 'd1;
	  end
	if(mem_req_ack)
	  begin
	     n_mq_head_ptr = r_mq_head_ptr + 'd1;
	  end
	
	t_mem_head = r_mem_q[r_mq_head_ptr[`LG_MQ_ENTRIES-1:0]];
	
	mem_q_empty = (r_mq_head_ptr == r_mq_tail_ptr);
	
	mem_q_full = (r_mq_head_ptr != r_mq_tail_ptr) &&
		     (r_mq_head_ptr[`LG_MQ_ENTRIES-1:0] == r_mq_tail_ptr[`LG_MQ_ENTRIES-1:0]);

	mem_q_next_full = (r_mq_head_ptr != r_mq_next_tail_ptr) &&
			  (r_mq_head_ptr[`LG_MQ_ENTRIES-1:0] == r_mq_next_tail_ptr[`LG_MQ_ENTRIES-1:0]);
	
     end // always_comb
   
   always_ff@(posedge clk)
     begin
	if(r_mem_ready)
	  begin
	     r_mem_q[r_mq_tail_ptr[`LG_MQ_ENTRIES-1:0]] <= t_mem_tail;
	  end
     end


   
   always_comb
     begin
	n_mdq_head_ptr = r_mdq_head_ptr;
	n_mdq_tail_ptr = r_mdq_tail_ptr;
	n_mdq_next_tail_ptr = r_mdq_next_tail_ptr;
	
	if(r_dq_ready)
	  begin
	     n_mdq_tail_ptr = r_mdq_tail_ptr + 'd1;
	     n_mdq_next_tail_ptr = r_mdq_next_tail_ptr + 'd1;
	  end
	
	if(core_store_data_ack)
	  begin
	     n_mdq_head_ptr = r_mdq_head_ptr + 'd1;
	  end

	core_store_data = r_mdq[r_mdq_head_ptr[`LG_MQ_ENTRIES-1:0]];
			       
	mem_mdq_empty = (r_mdq_head_ptr == r_mdq_tail_ptr);
	
	mem_mdq_full = (r_mdq_head_ptr != r_mdq_tail_ptr) &&
		     (r_mdq_head_ptr[`LG_MQ_ENTRIES-1:0] == r_mdq_tail_ptr[`LG_MQ_ENTRIES-1:0]);

	mem_mdq_next_full = (r_mdq_head_ptr != r_mdq_next_tail_ptr) &&
			    (r_mdq_head_ptr[`LG_MQ_ENTRIES-1:0] == r_mdq_next_tail_ptr[`LG_MQ_ENTRIES-1:0]);
     end // always_comb
   

   
   assign mem_req = t_mem_head;
   assign mem_req_valid = !mem_q_empty;
   assign uq_wait = r_uq_wait;
   assign mq_wait = r_mq_wait;
   assign core_store_data_valid = !mem_mdq_empty;
   
   
   always_ff@(posedge clk)
     begin
	r_mq_head_ptr <= reset ? 'd0 : n_mq_head_ptr;
	r_mq_tail_ptr <= reset ? 'd0 : n_mq_tail_ptr;
	r_mq_next_tail_ptr <= reset ? 'd1 : n_mq_next_tail_ptr;

	r_mdq_head_ptr <= (reset || mem_dq_clr) ? 'd0 : n_mdq_head_ptr;
	r_mdq_tail_ptr <= (reset || mem_dq_clr) ? 'd0 : n_mdq_tail_ptr;
	r_mdq_next_tail_ptr <= (reset || mem_dq_clr) ? 'd1 : n_mdq_next_tail_ptr;	
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_prf_inflight <= 'd0;
	     r_hilo_inflight <= 'd0;
	     r_fp_prf_inflight <= 'd0;
	  end
	else
	  begin
	     r_prf_inflight <= ds_done ? 'd0 : n_prf_inflight;
	     r_hilo_inflight <= ds_done ? 'd0 : n_hilo_inflight;
	     r_fp_prf_inflight <= ds_done ? 'd0 : n_fp_prf_inflight;
	  end
     end // always_ff@ (posedge clk)

   /* FP PRF: one write port (mem-pipe move / FP-load response; shared with the future
    * FPU) + two registered read ports (mfc1 source, FP store data).  Read address is
    * the combinational head (t_mem_uq.srcB / t_mem_dq.src_ptr) so the registered output
    * lands aligned with mem_uq / mem_dq -- exactly like the int PRF (rf4r2w).  The NBA
    * read evaluates the pre-write array => read-old on a same-cycle RW collision (which
    * the inflight pop-gating already prevents). */
   always_ff@(posedge clk)
     begin
	r_fp_rd_srcB <= r_fp_prf[t_mem_uq.srcB];
	r_fp_rd_dq   <= r_fp_prf[t_mem_dq.src_ptr];
	if(mem_rsp_dst_valid & mem_rsp_fp_dst)
	  r_fp_prf[mem_rsp_dst_ptr] <= mem_rsp_load_data;
     end

   
   always_comb
     begin
	n_prf_inflight = r_prf_inflight;
	n_fp_prf_inflight = r_fp_prf_inflight;


	if(uq_push && uq_uop.dst_valid)
	  begin
	     n_prf_inflight[uq_uop.dst] = 1'b1;
	  end
	if(uq_push_two && uq_uop_two.dst_valid)
	  begin
	     n_prf_inflight[uq_uop_two.dst] = 1'b1;
	  end
	/* FP dst allocation marks the FP physical reg inflight */
	if(uq_push && uq_uop.fp_dst_valid)
	  n_fp_prf_inflight[uq_uop.dst] = 1'b1;
	if(uq_push_two && uq_uop_two.fp_dst_valid)
	  n_fp_prf_inflight[uq_uop_two.dst] = 1'b1;

	if(mem_rsp_dst_valid)
	  begin
	     if(mem_rsp_fp_dst)
	       n_fp_prf_inflight[mem_rsp_dst_ptr] = 1'b0;
	     else
	       n_prf_inflight[mem_rsp_dst_ptr] = 1'b0;
	  end
	if(r_start_int && t_wr_int_prf)
	  begin
	     n_prf_inflight[int_uop.dst] = 1'b0;
	  end
     end // always_comb
   
   always_comb
     begin
	n_hilo_inflight = r_hilo_inflight;
	if(uq_push && uq_uop.hilo_dst_valid)
	  begin
	     n_hilo_inflight[uq_uop.hilo_dst] = 1'b1;
	  end
	
	if(uq_push_two && uq_uop_two.hilo_dst_valid)
	  begin
	     n_hilo_inflight[uq_uop_two.hilo_dst] = 1'b1;
	  end
	
	if(t_hilo_prf_ptr_val_out)
	  begin
	     n_hilo_inflight[t_hilo_prf_ptr_out] = 1'b0;
	  end
	if(t_div_complete)
	  begin
	     n_hilo_inflight[t_div_hilo_prf_ptr_out] = 1'b0;
	  end
	if(r_start_int && t_wr_hilo)
	  begin
	     n_hilo_inflight[int_uop.hilo_dst] = 1'b0;
	  end

     end // always_comb

   

   
`ifdef VERILATOR
   logic t_blocked_by_store;
   always_comb
     begin
	t_blocked_by_store = t_mem_uq_empty ? 1'b0 : !t_pop_mem_uq  & is_store(mem_uq.op) & 
			     !r_prf_inflight[mem_uq.srcA] &
			     !mem_q_full;
     end
   always_ff@(negedge clk)
     begin
	report_exec(t_uq_empty ? 32'd0 : 32'd1,
		    t_pop_uq ? 32'd1 : 32'd0,
		    t_mem_uq_empty ? 32'd0 : 32'd1,
		    t_pop_mem_uq ? 32'd1 : 32'd0,
		    32'd1,
		    32'd0,
		    t_uq_full ? 32'd1 : 32'd0,
		    t_mem_uq_full ? 32'd1 : 32'd0,
		    32'd0,
		    t_blocked_by_store ? 32'd1 : 32'd0,
		    {{(32-N_INT_SCHED_ENTRIES){1'b0}}, t_alu_entry_rdy}
		    );
     end
`endif //  `ifdef VERILATOR

   wire [31:0] w_s_sub32, w_c_sub32;

   wire [31:0] w_imm32 = { {16{int_uop.imm[15]}},int_uop.imm};
   csa #(.N(32)) csa0 (.a(t_srcA[31:0]),
		       .b((int_uop.op == SUBU|int_uop.op==SUB) ? ~t_srcB[31:0] : (((int_uop.op == ADDIU | int_uop.op == ADDI) ? w_imm32 : t_srcB[31:0]))), 
		       .cin((int_uop.op == SUBU|int_uop.op==SUB) ? 32'd1 : 32'd0), .s(w_s_sub32), .cout(w_c_sub32) );

   wire [31:0] w_add_srcA = {w_c_sub32[30:0], 1'b0};
   wire [31:0] w_add_srcB = w_s_sub32;

   wire [31:0] w_add32 = w_add_srcA + w_add_srcB;
   /* Overflow must use the SAME (forwarded) operands the adder used: t_srcA and
    * the effective addend (the immediate for ADDI/ADDIU, else t_srcB).  The raw
    * PRF reads w_srcA/w_srcB hold stale values on same-cycle forwarding. */
   wire [31:0] w_ovf_srcB = (int_uop.op == ADDIU | int_uop.op == ADDI) ? w_imm32 : t_srcB[31:0];
   wire	       w_add32_overflow = (w_add32[31] != w_ovf_srcB[31]) & (t_srcA[31] == w_ovf_srcB[31]);
   /* A - B overflows iff A,B differ in sign AND the result sign differs from A (the minuend). */
   wire	       w_sub32_overflow = (w_add32[31] != t_srcA[31]) & (t_srcA[31] != w_ovf_srcB[31]);

   wire [`M_WIDTH-1:0] w_add64;
   wire	       w_add64_overflow, w_sub64_overflow;

   generate
      if(`M_WIDTH==64)
	begin
	   wire [63:0] w_s_sub64, w_c_sub64;
	   wire [63:0] w_imm64 = { {48{int_uop.imm[15]}},int_uop.imm};
	   csa #(.N(64)) csa0 (.a(t_srcA),
			       .b((int_uop.op == DSUBU|int_uop.op==DSUB) ? ~t_srcB : (((int_uop.op == DADDIU | int_uop.op == DADDI) ? w_imm64 : t_srcB))), 
			       .cin((int_uop.op == DSUBU|int_uop.op==DSUB) ? 64'd1 : 64'd0), .s(w_s_sub64), .cout(w_c_sub64) );
	   
	   wire [63:0] w_add64_srcA = {w_c_sub64[62:0], 1'b0};
	   wire [63:0] w_add64_srcB = w_s_sub64;
	   assign w_add64 = w_add64_srcA + w_add64_srcB;
		   wire [63:0] w_ovf64_srcB = (int_uop.op == DADDIU | int_uop.op == DADDI) ? w_imm64 : t_srcB;
	   assign w_add64_overflow = (w_add64[63] != w_ovf64_srcB[63]) & (t_srcA[63] == w_ovf64_srcB[63]);
	   assign w_sub64_overflow = (w_add64[63] != t_srcA[63]) & (t_srcA[63] != w_ovf64_srcB[63]);   	   
	end
      else
	begin
	   assign w_add64 = 'd0;
	   assign w_add64_overflow = 1'b0;
	   assign w_sub64_overflow = 1'b0;
	end
   endgenerate

   logic [5:0] r_tlb_index, n_tlb_index;
   logic n_tlb_entry_out_valid, r_tlb_entry_out_valid;
   logic n_tlbr, r_tlbr;
   
   always_ff@(posedge clk)
     begin
	r_tlb_index <= reset ? 'd0 : n_tlb_index;
	r_tlb_entry_out_valid <= reset ? 1'b0 : n_tlb_entry_out_valid;
	r_tlbr <= reset ? 1'b0 : n_tlbr;
     end
   
   always_comb
     begin
	t_pc = int_uop.pc + zero_extend32(32'd4);  /* default restart = pc+4 */
	t_pc4 = int_uop.pc + zero_extend32(32'd4);
	t_pc8 = int_uop.pc + zero_extend32(32'd8);
	t_result = zero_extend32(32'd0);
	t_cpr0_result = zero_extend32(32'd0);
	t_unimp_op = 1'b0;
	t_fault = 1'b0;
	t_simm = {{E_BITS{int_uop.imm[15]}},int_uop.imm};
	t_wr_int_prf = 1'b0;
	t_wr_cpr0 = 1'b0;
	t_wr_cpr0_64 = 1'b0;
	t_wr_fcsr = 1'b0;
	t_take_br = 1'b0;
	t_mispred_br = 1'b0;
	t_jaddr = {int_uop.jmp_imm[9:0],int_uop.imm,2'd0};
	t_alu_valid = 1'b0;
	t_hilo_result = 'd0;
	t_wr_hilo = 1'b0;
	t_signed_shift = 1'b0;
	t_shift_amt = 'd0;
	t_start_mul = 1'b0;
	t_signed_div = 1'b0;
	t_start_div32 = 1'b0;
	t_start_div64 = 1'b0;	
	t_overflow = 1'b0;
	t_trap = 1'b0;
	n_tlb_index = r_tlb_index;
	n_tlb_entry_out_valid = 1'b0;
	n_tlbr = 1'b0;
	t_eret = 1'b0;
	t_32b_shift = 1'b0;
	t_shift_left = 1'b0;
	
	case(int_uop.op)
	  BREAK:
	    begin
	       t_alu_valid = 1'b1;
	       t_fault = 1'b1;
	    end
	  SYSCALL:
	    begin
	       t_alu_valid = 1'b1;
	       t_fault = 1'b1;
	    end
	  SLL:
	    begin
	       //t_result = sign_extend32(t_srcA[31:0] << int_uop.imm[4:0]);
	       t_shift_left = 1'b1;
	       t_32b_shift = 1'b1;	       	       
	       t_shift_amt = {{(`LG_M_WIDTH-5) {1'b0}}, int_uop.imm[4:0]};	       
	       t_result = {{HI_EBITS{w_shifter_out[31]}}, w_shifter_out[31:0]};
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  SRA:
	    begin
	       t_signed_shift = 1'b1;
	       t_32b_shift = 1'b1;	       
	       t_shift_amt = {{(`LG_M_WIDTH-5) {1'b0}}, int_uop.imm[4:0]};
	       t_result = {{HI_EBITS{w_shifter_out[31]}}, w_shifter_out[31:0]};
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end // case: SRA
	  SRL:
	    begin
	       t_32b_shift = 1'b1;
	       t_shift_amt = {{(`LG_M_WIDTH-5) {1'b0}}, int_uop.imm[4:0]};
	       t_result = {{HI_EBITS{w_shifter_out[31]}}, w_shifter_out[31:0]};
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  SRAV:
	    begin
	       t_signed_shift = 1'b1;
	       t_32b_shift = 1'b1;	       
	       t_shift_amt = {{(`LG_M_WIDTH-5) {1'b0}}, t_srcB[4:0]};
	       t_result = {{HI_EBITS{w_shifter_out[31]}}, w_shifter_out[31:0]}; 
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  SLLV:
	    begin
	       t_32b_shift = 1'b1;
	       t_shift_left = 1'b1;	       
	       t_result = {{HI_EBITS{w_shifter_out[31]}}, w_shifter_out[31:0]};
	       t_shift_amt = {{(`LG_M_WIDTH-5) {1'b0}}, t_srcB[4:0]};
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  SRLV:
	    begin
	       t_32b_shift = 1'b1;
	       t_shift_amt = {{(`LG_M_WIDTH-5) {1'b0}}, t_srcB[4:0]};
	       t_result = {{HI_EBITS{w_shifter_out[31]}}, w_shifter_out[31:0]};
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSLL:
	    begin
	       t_shift_left = 1'b1;
	       t_shift_amt = {{(`LG_M_WIDTH-5){1'b0}}, int_uop.imm[4:0]};
	       t_result = w_shifter_out;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSLL32:
	    begin
	       t_shift_left = 1'b1;
	       t_shift_amt = {1'b1, int_uop.imm[4:0]};
	       t_result = w_shifter_out;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSRL:
	    begin
	       t_shift_amt = {{(`LG_M_WIDTH-5){1'b0}}, int_uop.imm[4:0]};
	       t_result = w_shifter_out;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSRL32:
	    begin
	       t_shift_amt = {1'b1, int_uop.imm[4:0]};
	       t_result = w_shifter_out;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSRA:
	    begin
	       t_signed_shift = 1'b1;
	       t_shift_amt = {{(`LG_M_WIDTH-5){1'b0}}, int_uop.imm[4:0]};
	       t_result = w_shifter_out;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSRA32:
	    begin
	       t_signed_shift = 1'b1;
	       t_shift_amt = {1'b1, int_uop.imm[4:0]};
	       t_result = w_shifter_out;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSLLV:
	    begin
	       t_shift_left = 1'b1;
	       t_shift_amt = t_srcB[`LG_M_WIDTH-1:0];
	       t_result = w_shifter_out;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSRLV:
	    begin
	       t_shift_amt = t_srcB[`LG_M_WIDTH-1:0];
	       t_result = w_shifter_out;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSRAV:
	    begin
	       t_signed_shift = 1'b1;
	       t_shift_amt = t_srcB[`LG_M_WIDTH-1:0];
	       t_result = w_shifter_out;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  MTLO:
	    begin
	       t_hilo_result = {t_src_hilo[(2*`M_WIDTH)-1:`M_WIDTH], t_srcA[`M_WIDTH-1:0]};
	       t_wr_hilo = 1'b1;
	       t_alu_valid = 1'b1;	       
	    end
	  MTHI:
	    begin
	       t_hilo_result = {t_srcA[`M_WIDTH-1:0], t_src_hilo[`M_WIDTH-1:0] };
	       t_wr_hilo = 1'b1;
	       t_alu_valid = 1'b1;	       
	    end
	  MFLO:
	    begin
	       t_result = t_src_hilo[`M_WIDTH-1:0];
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  MFHI:
	    begin
	       t_result = t_src_hilo[(`M_WIDTH*2)-1:`M_WIDTH];
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  ADD:
	    begin
	       t_result = sign_extend32(w_add32);
	       t_overflow = w_add32_overflow;
	       t_fault = w_add32_overflow;	       	       
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  ADDU:
	    begin
	       t_result = sign_extend32(w_add32);
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DADD:
	    begin
	       t_result = w_add64;
	       t_overflow = w_add64_overflow;
	       t_fault = w_add64_overflow;	       	       
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DADDU:
	    begin
	       t_result = w_add64;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSUB:
	    begin
	       t_result = w_add64;
	       t_overflow = w_sub64_overflow;
	       t_fault = w_sub64_overflow;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  MULT:
	    begin
	       t_start_mul = r_start_int&!ds_done;
	    end
	  MULTU:
	    begin
	       t_start_mul = r_start_int&!ds_done;
	    end
	  DIV:
	    begin
	       t_signed_div = 1'b1;
	       t_start_div32 = r_start_int&!ds_done;	       
	    end
	  DIVU:
	    begin
	       t_start_div32 = r_start_int&!ds_done;
	    end
	  DMULT:
	    begin
	       t_start_mul = r_start_int&!ds_done;
	    end
	  DMULTU:
	    begin
	       t_start_mul = r_start_int&!ds_done;
	    end
	  DDIV:
	    begin
	       t_signed_div = 1'b1;
	       t_start_div64 = r_start_int&!ds_done;
	    end
	  DDIVU:
	    begin
	       t_start_div64 = r_start_int&!ds_done;
	    end
	  SUB:
	    begin
	       t_result = sign_extend32(w_add32);
	       t_overflow = w_sub32_overflow;
	       t_fault = w_sub32_overflow;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  SUBU:
	    begin
	       t_result = sign_extend32(w_add32);
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DSUBU:
	    begin
	       t_result = w_add64;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  AND:
	    begin
	       t_result = t_srcA & t_srcB;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  MOV:
	    begin
	       t_result = t_srcA;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  OR:
	    begin
	       t_result = t_srcA | t_srcB;
	       t_wr_int_prf = 1'b1;//int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  XOR:
	    begin
	       t_result = t_srcA ^ t_srcB;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  NOR:
	    begin
	       t_result = ~(t_srcA | t_srcB);
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  SLT:
	    begin
	       t_result = (($signed(t_srcB) <  $signed(t_srcA)) ? 'd1 : 'd0);
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end // case: SLT
	  SLTU:
	    begin
	       t_result = (t_srcB <  t_srcA) ? 'd1 : 'd0;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end // case: SLTU
	  BEQ:
	    begin
	       t_take_br = (t_srcA  == t_srcB);
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BEQL:
	    begin
	       t_take_br = (t_srcA  == t_srcB);
	       t_mispred_br = int_uop.br_pred != t_take_br || !t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BNE:
	    begin
	       t_take_br = (t_srcA  != t_srcB);
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end // case: BNE
	  BGEZ:
	    begin
	       t_take_br = (t_srcA[`M_WIDTH-1] == 1'b0);
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BGEZAL:
	    begin
	       t_take_br = (t_srcA[`M_WIDTH-1] == 1'b0);
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;	  
     	       t_result = t_take_br ?  int_uop.pc[`M_WIDTH-1:0] + 'd8 : t_srcB;
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end // case: BGEZAL
	  BAL:
	    begin
	       t_take_br = 1'b1;
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_result = int_uop.pc[`M_WIDTH-1:0] + 'd8;
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end
	  BLTZ:
	    begin
	       t_take_br = ($signed(t_srcA) < $signed({`M_WIDTH{1'b0}}));
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BLEZ:
	    begin
	       t_take_br = ($signed(t_srcA) <= $signed({`M_WIDTH{1'b0}}));
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BLEZL:
	    begin
	       t_take_br = ($signed(t_srcA) < $signed({`M_WIDTH{1'b0}})) || (t_srcA == {`M_WIDTH{1'b0}});
	       t_mispred_br = int_uop.br_pred != t_take_br || !t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BGTZ:
	    begin
	       t_take_br = ($signed(t_srcA) > $signed({`M_WIDTH{1'b0}}));
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;	       
	       t_alu_valid = 1'b1;
	    end
	  BNEL:
	    begin
	       t_take_br = (t_srcA  != t_srcB);
	       t_mispred_br = (int_uop.br_pred != t_take_br) /* || !t_take_br */;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BLTZL:
	    begin
	       t_take_br = $signed(t_srcA) < $signed({`M_WIDTH{1'b0}});
	       t_mispred_br = (int_uop.br_pred != t_take_br) || !t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BGTZL:
	    begin
	       t_take_br = ($signed(t_srcA) > $signed({`M_WIDTH{1'b0}}));
	       t_mispred_br = (int_uop.br_pred != t_take_br) || !t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BGEZL:
	    begin
	       t_take_br = ($signed(t_srcA) >= $signed({`M_WIDTH{1'b0}}));
	       t_mispred_br = (int_uop.br_pred != t_take_br) || !t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BLTZAL:
	    begin
	       t_take_br = ($signed(t_srcA) < $signed({`M_WIDTH{1'b0}}));
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_result = t_take_br ? int_uop.pc[`M_WIDTH-1:0] + 'd8 : t_srcB;
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end
	  BLTZALL:
	    begin
	       t_take_br = ($signed(t_srcA) < $signed({`M_WIDTH{1'b0}}));
	       t_mispred_br = (int_uop.br_pred != t_take_br) || !t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_result = t_take_br ? int_uop.pc[`M_WIDTH-1:0] + 'd8 : t_srcB;
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end
	  BGEZALL:
	    begin
	       t_take_br = (t_srcA[`M_WIDTH-1] == 1'b0);
	       t_mispred_br = (int_uop.br_pred != t_take_br) || !t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_result = t_take_br ? int_uop.pc[`M_WIDTH-1:0] + 'd8 : t_srcB;
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end
	  // J:
	  //   begin
	  //      t_take_br = 1'b1;
	  //      t_mispred_br = int_uop.br_pred != t_take_br;
	  //      t_pc = {t_pc4[`M_WIDTH-1:28],t_jaddr};
	  //      t_alu_valid = 1'b1;
	  //      t_srcs_rdy = 1'b1;	       
	  //   end
	  JAL:
	    begin
	       t_take_br = 1'b1;
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = {t_pc4[`M_WIDTH-1:28], t_jaddr};
	       t_result = int_uop.pc[`M_WIDTH-1:0] + 'd8;
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end
	  JR:
	    begin
	       t_take_br = 1'b1;
	       t_mispred_br = (t_srcA != {int_uop.jmp_imm,int_uop.imm});
	       t_pc = t_srcA;
	       t_alu_valid = 1'b1;
	    end
	  JALR:
	    begin
	       t_take_br = 1'b1;
	       t_mispred_br = (t_srcA != {int_uop.jmp_imm,int_uop.imm});
	       t_pc = t_srcA;
	       t_alu_valid = 1'b1;
	       t_result = int_uop.pc[`M_WIDTH-1:0] + 'd8;
	       t_wr_int_prf = 1'b1;
	    end
	  ANDI:
	    begin
	       t_result = t_srcA & {{E_BITS{1'b0}},int_uop.imm};
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  ORI:
	    begin
	       t_result = t_srcA | {{E_BITS{1'b0}},int_uop.imm};	       
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  XORI:
	    begin
	       t_result = t_srcA ^ {{E_BITS{1'b0}},int_uop.imm};
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  LUI:
	    begin
	       t_result = sign_extend32({int_uop.imm, 16'd0});
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  ADDI:
	    begin
	       t_result = sign_extend32(w_add32);
	       t_overflow = w_add32_overflow;
	       t_fault = w_add32_overflow;	       
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  ADDIU:
	    begin
	       t_result = sign_extend32(w_add32);
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DADDI:
	    begin
	       t_result = w_add64;
	       t_overflow = w_add64_overflow;
	       t_fault = w_add64_overflow;	       
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  DADDIU:
	    begin
	       t_result = w_add64;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  MOVI:
	    begin
	       t_result = {{HI_EBITS{t_simm[31]}}, t_simm[31:0]};
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  SLTI:
	    begin
	       t_result = (($signed(t_srcA) < $signed(t_simm)) ? 'd1 : 'd0);
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  SLTIU:
	    begin
	       t_result = (t_srcA < t_simm ? 'd1 : 'd0);
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  MFC0:
	    begin
	       t_result = t_csr0_val;
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end
	  MTC0:
	    begin
	       t_wr_cpr0 = 1'b1;
	       t_alu_valid = 1'b1;
	    end // case: MTC0
	  DMFC0:
	    begin
	       t_result = t_csr0_64_val;
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end
	  DMTC0:
	    begin
	       t_wr_cpr0 = 1'b1;
	       t_wr_cpr0_64 = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  CFC1:
	    begin
	       /* fs in srcA[4:0]: FCR0=FIR (read-only R4000 id), FCR31=FCSR */
	       t_result = (int_uop.srcA[4:0] == 5'd0) ?
			  sign_extend32(32'h00000500) : /* FIR: imp=0x05 (R4000 FPU), rev 0 */
			  sign_extend32(r_fcsr);
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end
	  CTC1:
	    begin
	       /* only FCR31 (FCSR) is writable; fs in dst */
	       t_wr_fcsr = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  ERET:
	    begin
	       t_eret = 1'b1;
	       t_alu_valid = 1'b1;
	       t_fault = 1'b1;
	       /* ERL takes precedence: error return uses ErrorEPC (not yet
		* implemented -> fall back to EPC); otherwise EPC. */
	       t_pc = r_epc;
	    end
	  /* traps: B operand is the register (srcB) or, for the immediate forms
	   * (srcB_valid=0), the sign-extended immediate. */
	  TEQ:
	    begin
	       t_trap = (t_srcA == (int_uop.srcB_valid ? t_srcB : t_simm));
	       t_fault = t_trap;
	       t_alu_valid = 1'b1;
	    end
	  TNE:
	    begin
	       t_trap = (t_srcA != (int_uop.srcB_valid ? t_srcB : t_simm));
	       t_fault = t_trap;
	       t_alu_valid = 1'b1;
	    end
	  TGE:
	    begin
	       t_trap = ($signed(t_srcA) >= $signed(int_uop.srcB_valid ? t_srcB : t_simm));
	       t_fault = t_trap;
	       t_alu_valid = 1'b1;
	    end
	  TGEU:
	    begin
	       t_trap = (t_srcA >= (int_uop.srcB_valid ? t_srcB : t_simm));
	       t_fault = t_trap;
	       t_alu_valid = 1'b1;
	    end
	  TLT:
	    begin
	       t_trap = ($signed(t_srcA) < $signed(int_uop.srcB_valid ? t_srcB : t_simm));
	       t_fault = t_trap;
	       t_alu_valid = 1'b1;
	    end
	  TLTU:
	    begin
	       t_trap = (t_srcA < (int_uop.srcB_valid ? t_srcB : t_simm));
	       t_fault = t_trap;
	       t_alu_valid = 1'b1;
	    end
	  TLBWI:
	    begin
	       t_alu_valid = 1'b1;
	       t_fault = 1'b1;
	       n_tlb_index = r_index;
	       n_tlb_entry_out_valid = 1'b1;
	       t_pc = t_pc4;
	    end
	  TLBWR:
	    begin
	       t_alu_valid = 1'b1;
	       t_fault = 1'b1;
	       n_tlb_index = r_random;
	       n_tlb_entry_out_valid = 1'b1;
	       t_pc = t_pc4;	       
	    end
	  TLBR:
	    begin
	       t_alu_valid = 1'b1;
	       t_fault = 1'b1;
	       n_tlbr = 1'b1;
	       t_pc = t_pc4;	       
	    end
	  II:
	    begin
	       t_unimp_op = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  CACHE_OP:
	    begin
	       /* CACHE: compute the effective address (base + signed offset) so the
		* serialize funnel can drive a per-line D flush at flush_cl_addr =
		* rob.data. No GPR writeback (CACHE has no architectural dst). */
	       t_result = t_srcA + t_simm;
	       t_alu_valid = 1'b1;
	    end
	  default:
	    begin
	       t_unimp_op = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	endcase // case (int_uop.op)

	
     end // always_comb


   wire [`M_WIDTH-1:0] w_agu = t_mem_srcA + {{E_BITS{mem_uq.imm[15]}},mem_uq.imm};

   wire w_mem_srcA_ready = t_mem_uq.srcA_valid ? (!r_prf_inflight[t_mem_uq.srcA] | t_fwd_int_mem_srcA | t_fwd_mem_mem_srcA) : 1'b1;

   /* mfc1's FP source is the registered FP read r_fp_rd_srcB (aligned with mem_uq).
    * mfc1 (FP src -> address/mem-pop) gates the address pop on its FP source; FP stores
    * read the FP PRF through the store-data queue instead, so they don't gate here. */
   wire w_mem_fp_srcB_ready = (t_mem_uq.fp_srcB_valid && !t_mem_uq.is_store) ? !r_fp_prf_inflight[t_mem_uq.srcB] : 1'b1;

   wire w_dq_ready = t_mem_dq.fp ? !r_fp_prf_inflight[t_mem_dq.src_ptr] :
		     (!r_prf_inflight[t_mem_dq.src_ptr] | t_fwd_int_mem_srcB | t_fwd_mem_mem_srcB);

   always_comb
     begin
	t_pop_mem_uq = (!t_mem_uq_empty) && (!(mem_q_next_full||mem_q_full)) && w_mem_srcA_ready && w_mem_fp_srcB_ready && !t_flash_clear;

	t_pop_mem_dq = (!t_mem_dq_empty) && !mem_dq_clr && w_dq_ready
		       && (!(mem_mdq_next_full||mem_mdq_full)) ;
     end


   //need another queue to hold store data
   
   always_comb
     begin
	t_core_store_data.rob_ptr = mem_dq.rob_ptr;
	t_core_store_data.data = mem_dq.fp ? r_fp_rd_dq : t_mem_srcB;
	core_store_data_ptr = mem_dq.rob_ptr;
	core_store_data_ptr_valid = r_dq_ready;
     end

   always_ff@(posedge clk)
     begin
	if(r_dq_ready)
	  begin
	     r_mdq[r_mdq_tail_ptr[`LG_MQ_ENTRIES-1:0]] <= t_core_store_data;
	  end
     end

   
   
   
   //always_ff@(negedge clk)
     //begin
   //if(r_dq_ready)
   //begin
   //$display("cycle %d : popping dq, rob ptr %d, src ptr %d, pc %x, tag %d", r_cycle, mem_dq.rob_ptr, mem_dq.src_ptr, mem_dq.pc, mem_dq.tag);
   //	  end
	//if(r_mem_ready)
	  //begin
	    // $display("cycle %d, popping aq , rob ptr %d, srcb ptr %d, srcB val %b", r_cycle, mem_uq.rob_ptr, mem_uq.srcB, mem_uq.srcB_valid);
	  //end
   //end

   //always_ff@(posedge clk)
   //begin
   //core_store_data <= t_core_store_data;
   //end
   
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_mem_ready <= 1'b0;
	     r_dq_ready <= 1'b0;
	  end
	else
	  begin
	     r_mem_ready <= t_pop_mem_uq;
	     r_dq_ready <= t_pop_mem_dq;
	  end
     end // always_ff@ (posedge clk)

   
   //$stop();
   //end

   wire [`M_WIDTH-1:0] w_agu_la;
   wire		       w_cached, w_mapped;
   wire [1:0]	       w_seg;
   
   mipsseg seg0 (.v_addr(w_agu),
		 .l_addr(w_agu_la),
		 .cache(w_cached),
		 .mapped(w_mapped),
		 .seg(w_seg),
		 .bad_perms(w_bad_seg_perms),
		 .in_kernel_mode(in_kernel_mode),
		 .in_supervisor_mode(in_supervisor_mode),
		 .in_user_mode(in_user_mode),
		 .in_64b_kernel_mode(in_64b_kernel_mode),
		 .in_64b_supervisor_mode(in_64b_supervisor_mode),
		 .in_64b_user_mode(in_64b_user_mode));

   wire w_bad_seg_perms;

   always_comb
     begin
	t_mem_simm = {{E_BITS{mem_uq.imm[15]}},mem_uq.imm};
	t_mem_tail.op = MEM_LW;
	t_mem_tail.addr = w_agu_la;
	t_mem_tail.rob_ptr = mem_uq.rob_ptr;
	t_mem_tail.dst_valid = 1'b0;
	t_mem_tail.fp_dst = 1'b0;
	t_mem_tail.dst_ptr = mem_uq.dst;
	t_mem_tail.is_store = 1'b0;
	t_mem_tail.is_atomic = 1'b0;
	t_mem_tail.data = zero_extend32(32'd0);
	t_mem_tail.bad_addr = 1'b0;
	t_mem_tail.cached = w_cached;
	t_mem_tail.mapped = w_mapped;
`ifdef VERILATOR
	t_mem_tail.pc = mem_uq.pc;
`endif	
	case(mem_uq.op)
	  SB:
	    begin
	       t_mem_tail.op = MEM_SB;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = w_bad_seg_perms;	       
	    end // case: SB
	  SH:
	    begin
	       t_mem_tail.op = MEM_SH;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = w_agu[0] | w_bad_seg_perms;
	    end // case: SW
	  SW:
	    begin
	       t_mem_tail.op = MEM_SW;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end // case: SW
	  SC:
	    begin
	       t_mem_tail.op = MEM_SC;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.is_atomic = 1'b1;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.dst_ptr = mem_uq.dst;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;		    
	    end // case: SW
	  SWR:
	    begin
	       t_mem_tail.op = MEM_SWR;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = w_bad_seg_perms;	       
	    end // case: SW
	  SWL:
	    begin
	       t_mem_tail.op = MEM_SWL;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = w_bad_seg_perms;	       
	    end // case: SW	  
	  LW:
	    begin
	       t_mem_tail.op = MEM_LW;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end // case: LW
	  LWU:
	    begin
	       t_mem_tail.op = MEM_LWU;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end
	  LWL:
	    begin
	       t_mem_tail.op = MEM_LWL;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.dst_ptr = mem_uq.dst;
	       t_mem_tail.bad_addr = w_bad_seg_perms;
	    end // case: LWL
	  LWR:
	    begin
	       t_mem_tail.op = MEM_LWR;
	       t_mem_tail.rob_ptr = mem_uq.rob_ptr;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = w_bad_seg_perms;	       
	    end // case: LWR
	  LB:
	    begin
	       t_mem_tail.op = MEM_LB;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = w_bad_seg_perms;	       
	    end
	  LBU:
	    begin
	       t_mem_tail.op = MEM_LBU;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = w_bad_seg_perms;
	    end // case: LBU
	  LHU:
	    begin
	       t_mem_tail.op = MEM_LHU;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = w_agu[0] | w_bad_seg_perms;
	    end // case: LBU
	  LH:
	    begin
	       t_mem_tail.op = MEM_LH;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = w_agu[0] | w_bad_seg_perms;
	    end // case: LH
	  LD:
	    begin
	       t_mem_tail.op = MEM_LD;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	    end
	  SD:
	    begin
	       t_mem_tail.op = MEM_SD;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	    end
	  LDL:
	    begin
	       t_mem_tail.op = MEM_LDL;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.dst_ptr = mem_uq.dst;
	       t_mem_tail.bad_addr = w_bad_seg_perms;
	    end
	  LDR:
	    begin
	       t_mem_tail.op = MEM_LDR;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.dst_ptr = mem_uq.dst;
	       t_mem_tail.bad_addr = w_bad_seg_perms;
	    end
	  SDL:
	    begin
	       t_mem_tail.op = MEM_SDL;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = w_bad_seg_perms;
	    end
	  SDR:
	    begin
	       t_mem_tail.op = MEM_SDR;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = w_bad_seg_perms;
	    end
	  LL:
	    begin
	       t_mem_tail.op = MEM_LL;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	       t_mem_tail.is_atomic = 1'b1;
	    end
	  LLD:
	    begin
	       t_mem_tail.op = MEM_LLD;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	       t_mem_tail.is_atomic = 1'b1;
	    end
	  SCD:
	    begin
	       t_mem_tail.op = MEM_SCD;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.dst_ptr = mem_uq.dst;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	       t_mem_tail.is_atomic = 1'b1;	       
	    end
	  TLBP:
	    begin
	       t_mem_tail.op = MEM_TLBP;
	       t_mem_tail.addr = {r_entryhi_r, 22'd0, r_entryhi_vpn2, 13'd0};
	       t_mem_tail.mapped = 1'b1;
	    end
	  MTC1:
	    begin
	       /* GPR->FPR move (mips3/4): FPR[fs] = sign_extend32(GPR[rt][31:0]) */
	       t_mem_tail.op = MEM_MOV;
	       t_mem_tail.addr = {{32{t_mem_srcA[31]}}, t_mem_srcA[31:0]};
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.fp_dst = 1'b1;
	       t_mem_tail.dst_ptr = mem_uq.dst;
	       t_mem_tail.mapped = 1'b0;
	       t_mem_tail.cached = 1'b1;
	    end
	  MFC1:
	    begin
	       /* FPR->GPR move (mips3/4): GPR[rt] = sign_extend32(FPR[fs][31:0]) */
	       t_mem_tail.op = MEM_MOV;
	       t_mem_tail.addr = {{32{r_fp_rd_srcB[31]}}, r_fp_rd_srcB[31:0]};
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.fp_dst = 1'b0;
	       t_mem_tail.dst_ptr = mem_uq.dst;
	       t_mem_tail.mapped = 1'b0;
	       t_mem_tail.cached = 1'b1;
	    end
	  DMTC1:
	    begin
	       /* GPR->FPR 64-bit move: FPR[fs] = GPR[rt] (full register, no sign-ext) */
	       t_mem_tail.op = MEM_MOV;
	       t_mem_tail.addr = t_mem_srcA;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.fp_dst = 1'b1;
	       t_mem_tail.dst_ptr = mem_uq.dst;
	       t_mem_tail.mapped = 1'b0;
	       t_mem_tail.cached = 1'b1;
	    end
	  DMFC1:
	    begin
	       /* FPR->GPR 64-bit move: GPR[rt] = FPR[fs] (full register) */
	       t_mem_tail.op = MEM_MOV;
	       t_mem_tail.addr = r_fp_rd_srcB;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.fp_dst = 1'b0;
	       t_mem_tail.dst_ptr = mem_uq.dst;
	       t_mem_tail.mapped = 1'b0;
	       t_mem_tail.cached = 1'b1;
	    end
	  LWC1:
	    begin
	       /* FP load (word): normal L1D load, result writes the FP PRF */
	       t_mem_tail.op = MEM_LW;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.fp_dst = 1'b1;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end
	  LDC1:
	    begin
	       /* FP load (dword): normal L1D load, result writes the FP PRF */
	       t_mem_tail.op = MEM_LD;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.fp_dst = 1'b1;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	    end
	  SWC1:
	    begin
	       /* FP store (word): store data comes from the FP PRF via the dq */
	       t_mem_tail.op = MEM_SW;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end
	  SDC1:
	    begin
	       /* FP store (dword): store data comes from the FP PRF via the dq */
	       t_mem_tail.op = MEM_SD;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	    end
	  default:
	    begin
	    end
	endcase // case (mem_uq.op)

     end // always_comb
   

   always_ff@(posedge clk)
     begin
	r_int_result <= t_result;
	r_mem_result <= mem_rsp_load_data;
	r_int_hilo <= t_hilo_result;
	r_mul_hilo <= t_mul_result;
	r_div_hilo <= t_div_result;
     end

   always_comb
     begin
	t_fwd_int_mem_srcA = r_start_int && t_wr_int_prf &&(t_mem_uq.srcA == int_uop.dst);
	t_fwd_int_mem_srcB = r_start_int && t_wr_int_prf &&(t_mem_dq.src_ptr == int_uop.dst);
	t_fwd_mem_mem_srcA = w_mem_rsp_int_valid && (t_mem_uq.srcA == mem_rsp_dst_ptr);
	t_fwd_mem_mem_srcB = w_mem_rsp_int_valid && (t_mem_dq.src_ptr == mem_rsp_dst_ptr);
     end
   
   always_ff@(posedge clk)
     begin
	r_fwd_int_mem_srcA <= t_fwd_int_mem_srcA;
	r_fwd_int_mem_srcB <= t_fwd_int_mem_srcB;
	r_fwd_mem_mem_srcA <= t_fwd_mem_mem_srcA;
	r_fwd_mem_mem_srcB <= t_fwd_mem_mem_srcB;
	
	r_fwd_int_srcA <= r_start_int && t_wr_int_prf && (t_picked_uop.srcA == int_uop.dst);
	r_fwd_int_srcB <= r_start_int && t_wr_int_prf && (t_picked_uop.srcB == int_uop.dst);
	
	r_fwd_mem_srcA <= w_mem_rsp_int_valid && (t_picked_uop.srcA == mem_rsp_dst_ptr);
	r_fwd_mem_srcB <= w_mem_rsp_int_valid && (t_picked_uop.srcB == mem_rsp_dst_ptr);

	r_fwd_hilo_int <= r_start_int && t_wr_hilo && (t_picked_uop.hilo_src == int_uop.hilo_dst);
	r_fwd_hilo_mul <= t_hilo_prf_ptr_val_out && (t_picked_uop.hilo_src == t_hilo_prf_ptr_out);
	r_fwd_hilo_div <= t_div_complete && (t_picked_uop.hilo_src == t_div_hilo_prf_ptr_out);
     end


   rf4r2w #(.WIDTH(`M_WIDTH), .LG_DEPTH(`LG_PRF_ENTRIES)) 
   intprf (.clk(clk),
	   .rdptr0(t_picked_uop.srcA),
	   .rdptr1(t_picked_uop.srcB),
	   .rdptr2(t_mem_uq.srcA),
	   .rdptr3(t_mem_dq.src_ptr),
	   .wrptr0(int_uop.dst),
	   .wrptr1(mem_rsp_dst_ptr),
	   .wen0(r_start_int && t_wr_int_prf),
	   .wen1(mem_rsp_dst_valid & ~mem_rsp_fp_dst),
	   .wr0(t_result),
	   .wr1(mem_rsp_load_data),
	   .rd0(w_srcA),
	   .rd1(w_srcB),
	   .rd2(w_mem_srcA),
	   .rd3(w_mem_srcB)
	   );
   
   

  
   always_ff@(posedge clk)
     begin
	r_src_hilo <= r_hilo_prf[t_picked_uop.hilo_src];
	
	if(r_start_int && t_wr_hilo)
	  begin
	     r_hilo_prf[int_uop.hilo_dst] <= t_hilo_result;
	  end
	else if(t_hilo_prf_ptr_val_out)
	  begin
	     r_hilo_prf[t_hilo_prf_ptr_out] <= t_mul_result;
	  end
	else if(t_div_complete)
	  begin
	     r_hilo_prf[t_div_hilo_prf_ptr_out] <= t_div_result;
	  end	     
     end // always_ff@ (posedge clk)

   
   
   always_comb
     begin
	n_wr_pc_idx = r_wr_pc_idx;
	n_rd_pc_idx = r_rd_pc_idx;
	t_push_putchar = t_wr_cpr0 & (int_uop.dst == 'd7);
	if(t_push_putchar)
	  begin
	     n_wr_pc_idx = r_wr_pc_idx + 'd1;
	  end
	if(putchar_fifo_pop)
	  begin
	     n_rd_pc_idx = r_rd_pc_idx + 'd1;
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	r_wr_pc_idx <= reset ? 'd0 : n_wr_pc_idx;
	r_rd_pc_idx <= reset ? 'd0 : n_rd_pc_idx;
     end

   always_ff@(posedge clk)
     begin
	if(t_push_putchar)
	  begin
	     r_pc_buf[r_wr_pc_idx[2:0]] <= t_srcA[7:0];
	  end
     end
   
   assign putchar_fifo_out = r_pc_buf[r_rd_pc_idx[2:0]];
   assign putchar_fifo_empty = r_wr_pc_idx == r_rd_pc_idx;
   wire w_putchar_fifo_full = (r_wr_pc_idx[2:0] == r_rd_pc_idx[2:0]) & (r_wr_pc_idx[3] != r_rd_pc_idx[3]);
   assign putchar_fifo_wptr = r_wr_pc_idx;
   assign putchar_fifo_rptr = r_rd_pc_idx;

   logic [7:0]  r_entryhi_asid, n_entryhi_asid;
   logic [1:0]  r_entryhi_r, n_entryhi_r;
   logic [26:0] n_entryhi_vpn2, r_entryhi_vpn2;
   logic [`PFN_WIDTH-1:0] n_entrylo0_pfn, r_entrylo0_pfn;
   logic [2:0]  n_entrylo0_c, r_entrylo0_c;
   logic n_entrylo0_d, r_entrylo0_d;
   logic n_entrylo0_v, r_entrylo0_v;
   logic n_entrylo0_g, r_entrylo0_g;
   
   logic [`PFN_WIDTH-1:0] n_entrylo1_pfn, r_entrylo1_pfn;
   logic [2:0]  n_entrylo1_c, r_entrylo1_c;
   logic n_entrylo1_d, r_entrylo1_d;
   logic n_entrylo1_v, r_entrylo1_v;
   logic n_entrylo1_g, r_entrylo1_g;

   logic [8:0]  r_ptebase, n_ptebase;
   logic [30:0] r_xptebase, n_xptebase;
   logic [26:0] r_badvpn2, n_badvpn2;
      
   logic [11:0]	n_pagemask, r_pagemask;
   
   assign asid = r_entryhi_asid;
   
   /* interrupt enable */
   logic r_sr_ie, n_sr_ie;
   /* interrupt mask IM[7:0] = SR[15:8] */
   logic [7:0] r_sr_im, n_sr_im;
   /* exception level */
   logic r_sr_exl, n_sr_exl;
   /* error level */
   logic r_sr_erl, n_sr_erl;

   /* FP control/status register FCR31 (FCSR). No FP arithmetic is implemented,
    * so this is a plain holding register: ctc1 writes it, cfc1 reads it. */
   logic [31:0] r_fcsr, n_fcsr;
   
   logic	r_toggle, n_toggle;
   
   /* CP0 register 9: Count (free-running, increments each cycle) */
   logic [31:0] r_count, n_count;
   /* CP0 register 11: Compare (timer fires when Count == Compare) */
   logic [31:0] r_compare, n_compare;
   /* WatchLo/WatchHi (CP0 r18/r19): functional register interface only —
    * store/read-back, no watch-match hardware, no Watch (ExcCode 23) delivery. */
   logic [31:0] r_watchlo, n_watchlo, r_watchhi, n_watchhi;
   /* timer interrupt pending: set when Count==Compare, cleared by MTC0 Compare */
   logic        r_timer_ip, n_timer_ip;
   /* kernel - 00, supervisor - 01, user - 10 */
   logic [1:0] r_sr_ksu, n_sr_ksu;
   /* 64b user */
   logic       r_sr_ux, n_sr_ux;
   /* 64b supervisor */
   logic       r_sr_sx, n_sr_sx;
   /* 64b kernel */
   logic       r_sr_kx, n_sr_kx;
   /* exception vector */
   logic       r_sr_bev, n_sr_bev;
   /* tlb shutdown */
   logic       r_sr_ts, n_sr_ts;
   /* wired and random */
   logic [5:0] r_wired, n_wired, r_random, n_random;
   
   logic       r_index_probe_failed, n_index_probe_failed;
   logic [5:0] r_index, n_index;
   tlb_stored_t r_tlb_entry;   /* TLBR read-back: stored type (no entry field) */
   
   
   logic [`M_WIDTH-1:0]	n_epc, r_epc, n_badvaddr, r_badvaddr;
   assign exec_epc = r_epc;
   assign sr_bev = r_sr_bev;
   assign sr_exl = r_sr_exl;
   

   logic		r_exc_in_ds, n_exc_in_ds;
   logic [4:0]		r_cause, n_cause;
   logic		r_ip1, r_ip0, n_ip1, n_ip0;
   
   always_comb
     begin
	n_exc_in_ds = r_exc_in_ds;
	n_cause = r_cause;
	n_ip0 = r_ip0;
	n_ip1 = r_ip1;
	
	if(core_wr_cause)
	  begin
	     n_cause = core_cause;                /* ExcCode always updates (handler needs it) */
	     /* Cause.BD accompanies EPC: only update when not already in an exception
	      * (EXL==0), so a nested exception preserves the original BD.  EPC itself
	      * is gated the same way at the n_epc mux (r_sr_exl==0). */
	     if(r_sr_exl == 1'b0)
	       begin
		  n_exc_in_ds = exc_in_delay;
	       end
	  end // if (core_wr_cause)
	else if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd13)
	  begin
	     n_ip0 = t_srcA[8];
	     n_ip1 = t_srcA[9];	     
	  end
     end

   always_comb
     begin
	n_badvaddr = r_badvaddr;
	if(core_wr_badvaddr)
	  begin
	     n_badvaddr = core_badvaddr;
	  end
     end
   
   always_comb
     begin
	n_epc = r_epc;
	if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd14)
	  begin
	     n_epc = t_srcA;
	  end
	else if(core_wr_epc & (r_sr_exl == 1'b0))
	  begin
	     n_epc = core_epc;
	  end
     end // always_comb
   
   
`ifdef EPC_TRACE
   always_ff@(posedge clk)
     if(!reset && (n_epc != r_epc))
       $display("[epc] %x -> %x  r_sr_exl=%b cwr_epc=%b mtc0epc=%b cwr_cause=%b srcA=%x",
		r_epc[31:0], n_epc[31:0], r_sr_exl, core_wr_epc,
		(r_start_int & t_wr_cpr0 & (int_uop.dst=='d14)), core_wr_cause, t_srcA[31:0]);
`endif
   always_ff@(posedge clk)
     begin
	r_epc <= reset ? 'd0 : n_epc;
	r_badvaddr <= reset ? 'd0 : n_badvaddr;
	r_cause <= reset ? 'd0 : n_cause;
	r_ip0 <= reset ? 1'b0 : n_ip0;
	r_ip1 <= reset ? 1'b0 : n_ip1;
	r_exc_in_ds <= reset ? 1'b0 : n_exc_in_ds;
	r_entryhi_asid <= reset ? 'd0 : n_entryhi_asid;
	r_entryhi_r    <= reset ? 'd0 : n_entryhi_r;
	r_entryhi_vpn2 <= reset ? 'd0 : n_entryhi_vpn2;
	r_pagemask <= reset ? 'd0 : n_pagemask;
	r_entrylo0_pfn <= reset ? 'd0 : n_entrylo0_pfn;
	r_entrylo0_c <= reset ? 'd0 : n_entrylo0_c;
	r_entrylo0_d <= reset ? 'd0 : n_entrylo0_d;
	r_entrylo0_v <= reset ? 'd0 : n_entrylo0_v;
	r_entrylo0_g <= reset ? 'd0 : n_entrylo0_g;
	r_entrylo1_pfn <= reset ? 'd0 : n_entrylo1_pfn;
	r_entrylo1_c <= reset ? 'd0 : n_entrylo1_c;
	r_entrylo1_d <= reset ? 'd0 : n_entrylo1_d;
	r_entrylo1_v <= reset ? 'd0 : n_entrylo1_v;
	r_entrylo1_g <= reset ? 'd0 : n_entrylo1_g;
	r_ptebase <= reset ? 'd0 : n_ptebase;
	r_xptebase <= reset ? 'd0 : n_xptebase;
	r_badvpn2 <= reset ? 'd0 : n_badvpn2;
     end // always_ff@ (posedge clk)

   

   always_comb
     begin
	tlb_entry_out_valid = r_tlb_entry_out_valid;
	tlb_entry_out.entry = r_tlb_index;
	tlb_entry_out.pfn0 = r_entrylo0_pfn;
	tlb_entry_out.pfn1 = r_entrylo1_pfn;
	tlb_entry_out.pagemask = r_pagemask;
	tlb_entry_out.asid = r_entryhi_asid;
	tlb_entry_out.r = r_entryhi_r;
	tlb_entry_out.vpn = r_entryhi_vpn2;
	
	tlb_entry_out.c0 = r_entrylo0_c;
	tlb_entry_out.c1 = r_entrylo1_c;
	tlb_entry_out.v0 = r_entrylo0_v;
	tlb_entry_out.v1 = r_entrylo1_v;	
	tlb_entry_out.d0 = r_entrylo0_d;
	tlb_entry_out.d1 = r_entrylo1_d;
	tlb_entry_out.g0 = r_entrylo0_g;
	tlb_entry_out.g1 = r_entrylo1_g;			
     end

   always_ff@(posedge clk)
     begin
	r_tlb_entry <= r_shadow_tlb[r_index];
	if(r_tlb_entry_out_valid)
	  begin
	     /* copy the stored fields (everything except the entry write-index) */
	     r_shadow_tlb[r_tlb_index].pagemask <= tlb_entry_out.pagemask;
	     r_shadow_tlb[r_tlb_index].asid     <= tlb_entry_out.asid;
	     r_shadow_tlb[r_tlb_index].r        <= tlb_entry_out.r;
	     r_shadow_tlb[r_tlb_index].vpn      <= tlb_entry_out.vpn;
	     r_shadow_tlb[r_tlb_index].pfn0     <= tlb_entry_out.pfn0;
	     r_shadow_tlb[r_tlb_index].d0       <= tlb_entry_out.d0;
	     r_shadow_tlb[r_tlb_index].v0       <= tlb_entry_out.v0;
	     r_shadow_tlb[r_tlb_index].g0       <= tlb_entry_out.g0;
	     r_shadow_tlb[r_tlb_index].c0       <= tlb_entry_out.c0;
	     r_shadow_tlb[r_tlb_index].pfn1     <= tlb_entry_out.pfn1;
	     r_shadow_tlb[r_tlb_index].d1       <= tlb_entry_out.d1;
	     r_shadow_tlb[r_tlb_index].v1       <= tlb_entry_out.v1;
	     r_shadow_tlb[r_tlb_index].g1       <= tlb_entry_out.g1;
	     r_shadow_tlb[r_tlb_index].c1       <= tlb_entry_out.c1;
	  end
     end

   always_comb
     begin
	n_index = r_index;
	n_index_probe_failed = r_index_probe_failed;
	if(core_wr_tlbp)
	  begin
	     n_index_probe_failed = (core_tlbp_hit==1'b0);
	     n_index = core_tlbp_index;
	  end
	else if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd0)
	  begin
	     n_index = t_srcA[5:0];
	     n_index_probe_failed = t_srcA[31];
	  end
     end

   always_ff@(posedge clk)
     begin
	r_index <= reset ? 'd0 : n_index;
	r_index_probe_failed <= reset ? 1'b0 : n_index_probe_failed;
     end
   
   always_comb
     begin
	n_entrylo0_pfn = r_entrylo0_pfn;
	n_entrylo0_c = r_entrylo0_c;
	n_entrylo0_d = r_entrylo0_d;
	n_entrylo0_v = r_entrylo0_v;
	n_entrylo0_g = r_entrylo0_g;
	if(r_tlbr)
	  begin
	     n_entrylo0_g = r_tlb_entry.g0;
	     n_entrylo0_v = r_tlb_entry.v0;
	     n_entrylo0_d = r_tlb_entry.d0;
	     n_entrylo0_c = r_tlb_entry.c0;	     
	     n_entrylo0_pfn = r_tlb_entry.pfn0;	     
	  end
	else if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd2)
	  begin
	     n_entrylo0_g = t_srcA[0];
	     n_entrylo0_v = t_srcA[1];
	     n_entrylo0_d = t_srcA[2];
	     n_entrylo0_c = t_srcA[5:3];
	     /* PFN = PA[PA_WIDTH-1:12] = EntryLo[PFN_WIDTH+5:6]; PA bits beyond
	      * PA_WIDTH (a 64b write past the 36-bit PA) are dropped (real 36-bit HW). */
	     n_entrylo0_pfn = t_srcA[(`PFN_WIDTH+5):6];
	  end
     end

   always_comb
     begin
	n_entrylo1_pfn = r_entrylo1_pfn;
	n_entrylo1_c = r_entrylo1_c;
	n_entrylo1_d = r_entrylo1_d;
	n_entrylo1_v = r_entrylo1_v;
	n_entrylo1_g = r_entrylo1_g;
	if(r_tlbr)
	  begin
	     n_entrylo1_g = r_tlb_entry.g1;
	     n_entrylo1_v = r_tlb_entry.v1;
	     n_entrylo1_d = r_tlb_entry.d1;
	     n_entrylo1_c = r_tlb_entry.c1;	     
	     n_entrylo1_pfn = r_tlb_entry.pfn1;	     
	  end	
	else if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd3)
	  begin
	     n_entrylo1_g = t_srcA[0];
	     n_entrylo1_v = t_srcA[1];
	     n_entrylo1_d = t_srcA[2];
	     n_entrylo1_c = t_srcA[5:3];
	     n_entrylo1_pfn = t_srcA[(`PFN_WIDTH+5):6];
	  end
     end

   always_comb
     begin
	n_badvpn2 = r_badvpn2;
	n_ptebase = r_ptebase;
	n_xptebase = r_xptebase;
	if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd4)
	  begin
	     n_ptebase = t_srcA[31:23];
	  end
	else if(r_start_int & t_wr_cpr0 & t_wr_cpr0_64 & int_uop.dst == 'd20)
	  begin
	     n_xptebase = t_srcA[63:33];
	  end
	if(save_to_tlb_regs)
	  begin
	     n_badvpn2 = core_badvaddr[39:13];
	  end
     end
   
   
   always_comb
     begin
	n_pagemask = r_pagemask;
	if(r_tlbr)
	  begin
	     n_pagemask = r_tlb_entry.pagemask;
	  end
	else if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd5)
	  begin
	     n_pagemask = t_srcA[24:13];
	  end
     end
   
   always_comb
     begin
	n_entryhi_asid = r_entryhi_asid;
	n_entryhi_r    = r_entryhi_r;
	n_entryhi_vpn2 = r_entryhi_vpn2;
	if(r_tlbr)
	  begin
	     n_entryhi_asid = r_tlb_entry.asid;
	     n_entryhi_r    = r_tlb_entry.r;
	     n_entryhi_vpn2 = r_tlb_entry.vpn;
	  end
	else if(save_to_tlb_regs)
	  begin
	     n_entryhi_r    = core_badvaddr[63:62];
	     n_entryhi_vpn2 = core_badvaddr[39:13];
	  end
	else if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd10)
	  begin
	     n_entryhi_asid = t_srcA[7:0];
	     /* Take the full VPN2 (va[39:13]) + region R (va[63:62]) from the
	      * sign-extended GPR for BOTH mtc0 and dmtc0.  The GPR already holds
	      * the full sign-extended VA, so a 32-bit mtc0 of a high kseg2/ckseg
	      * value (e.g. 0xffffffffffffa000) correctly yields R=11/VPN2[39:32]=ff
	      * -- needed so the 64b-mode TLB match (tlb.sv) hits entries written
	      * via mtc0 (IRIX tlbwired, etc.).  Zero-extending here was the companion
	      * workaround to the old low-19 loose match. In 32-bit addressing the
	      * TLB match ignores R/upper-VPN, so the extra stored bits are benign. */
	     n_entryhi_r    = t_srcA[63:62];
	     n_entryhi_vpn2 = t_srcA[39:13];
	  end
     end
   
   always_comb
     begin
	n_sr_ie = r_sr_ie;
	n_sr_exl = r_sr_exl;
	n_sr_erl = r_sr_erl;
	n_sr_ksu = r_sr_ksu;
	n_sr_ux = r_sr_ux;
	n_sr_sx = r_sr_sx;
	n_sr_kx = r_sr_kx;
	n_sr_bev = r_sr_bev;
	n_sr_ts = r_sr_ts;
	n_sr_im = r_sr_im;
	n_toggle = !r_toggle;
	/* Count increments every other cycle */
	n_count = r_toggle ? (r_count + 32'd1) : r_count;
	n_compare = r_compare;
	n_watchlo = r_watchlo;
	n_watchhi = r_watchhi;
	/* CTC1: write FCSR (FCR31) */
	n_fcsr = r_fcsr;
	if(r_start_int & t_wr_fcsr)
	  n_fcsr = t_srcA[31:0];
	/* Timer IP: set when Count wraps to Compare, cleared by MTC0 Compare */
	n_timer_ip = r_timer_ip | (n_count == r_compare);

	if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd12)
	  begin
	     n_sr_ie = t_srcA[0];
	     n_sr_exl = t_srcA[1];
	     n_sr_erl = t_srcA[2];
	     n_sr_ksu = t_srcA[4:3];
	     n_sr_ux = t_srcA[5];
	     n_sr_sx = t_srcA[6];
	     n_sr_kx = t_srcA[7];
	     n_sr_bev = t_srcA[22];
	     n_sr_ts = t_srcA[21];
	     n_sr_im = t_srcA[15:8];
	  end
	/* MTC0 reg 9: write Count */
	if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd9)
	  begin
	     n_count = t_srcA[31:0];
	  end
	/* MTC0 reg 18/19: WatchLo/WatchHi — functional register only (no watch hw) */
	if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd18)
	  n_watchlo = t_srcA[31:0];
	if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd19)
	  n_watchhi = t_srcA[31:0];
	/* MTC0 reg 11: write Compare and clear timer IP */
	if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd11)
	  begin
	     n_compare = t_srcA[31:0];
	     n_timer_ip = 1'b0;
	  end
	else if(core_wr_cause)
	  begin
	     /* normal exception entry sets EXL (not ERL); ERL is reserved
	      * for reset/NMI/cache-error. */
	     n_sr_exl = 1'b1;
	  end
	else if(t_eret)
	  begin
	     /* ERET: ERL takes precedence over EXL. */
	     if(r_sr_erl)
	       n_sr_erl = 1'b0;
	     else
	       n_sr_exl = 1'b0;
	  end
     end // always_comb

   always@(posedge clk)
     begin
	r_sr_ie <= reset ? 'd0 : n_sr_ie;
	r_sr_exl <= reset ? 'd0 : n_sr_exl;
	r_sr_erl <= reset ? 1'b1 : n_sr_erl;
	r_sr_ksu <= reset ? 'd0 : n_sr_ksu;
	r_sr_ux <= reset ? 'd0 : n_sr_ux;
	r_sr_sx <= reset ? 'd0 : n_sr_sx;
	r_sr_kx <= reset ? 'd0 : n_sr_kx;
	r_sr_bev <= reset ? 1'b1 : n_sr_bev;
	r_sr_ts <= reset ? 1'b0 : n_sr_ts;
	r_sr_im <= reset ? 8'd0 : n_sr_im;
	r_wired <= reset ? 'd0 :  n_wired;
	r_random <= reset ? 'd47 : n_random;
	r_count  <= reset ? 32'd0 : n_count;
	r_toggle <= reset ? 1'b0 : n_toggle;
	
	r_compare <= reset ? 32'd0 : n_compare;
	r_fcsr <= reset ? 32'd0 : n_fcsr;
	r_watchlo <= reset ? 32'd0 : n_watchlo;
	r_watchhi <= reset ? 32'd0 : n_watchhi;
	r_timer_ip <= reset ? 1'b0 : n_timer_ip;
     end

   assign in_kernel_mode = (r_sr_ksu=='d0) | r_sr_exl | r_sr_erl;
   assign in_supervisor_mode = (r_sr_ksu=='d1) & (r_sr_exl==1'b0) & (r_sr_erl==1'b0);
   assign in_user_mode = (r_sr_ksu=='d2) & (r_sr_exl==1'b0) & (r_sr_erl==1'b0);

   assign in_64b_user_mode = (in_user_mode) & r_sr_ux;
   assign in_64b_kernel_mode = in_kernel_mode & r_sr_kx;
   assign in_64b_supervisor_mode = in_supervisor_mode & r_sr_sx;

   /* IP[7] = timer; others not yet wired */
   logic r_ip6, r_ip5, r_ip4, r_ip3, r_ip2;

   
   always_ff@(posedge clk)
     begin
	r_ip6 <= reset ? 1'b0 : ip6;
	r_ip5 <= reset ? 1'b0 : ip5;
	r_ip4 <= reset ? 1'b0 : ip4;
	r_ip3 <= reset ? 1'b0 : ip3;
	r_ip2 <= reset ? 1'b0 : ip2;	
     end
   
   wire [7:0] w_ip = {r_timer_ip, r_ip6, r_ip5, r_ip4, r_ip3, r_ip2, r_ip1, r_ip0};
   /* interrupt is pending when IE=1, EXL=0, ERL=0, and any (IP & IM) bit set */
   assign irq_pending = r_sr_ie & ~r_sr_exl & ~r_sr_erl & |(w_ip & r_sr_im);
   assign cp0_count   = r_count;

   
   always_comb
     begin
	cpr0_status_reg = {
			     1'b0, /* XX */
			     1'b1, /* cu2 */
			     1'b1, /* cu1 */
			     1'b1, /* cu0 */
			     1'b0, /* reduced power */
			     1'b0, /* floating-point registers */
			     1'b0, /* reverse endian */
			     1'b0,  /* bit24 - must be zero */
			     1'b0,  /* bit23 - must be zero */
			     r_sr_bev,
			     r_sr_ts,
			     5'd0, /* other diagnostic bits */
			     r_sr_im, /* im field */
			     r_sr_kx, /* bit 7 */
			     r_sr_sx,
			     r_sr_ux,
			     r_sr_ksu,
			     r_sr_erl,
			     r_sr_exl,
			     r_sr_ie /* bit 0 */
			   };
     end
   
   always_comb
     begin
	t_csr0_val = sign_extend32(cpr0_status_reg);
	case(int_uop.srcA[4:0] )
	  'd0:
	    begin
	       t_csr0_val = sign_extend32({r_index_probe_failed,25'd0, r_index});
	    end
	  'd1:
	    begin
	       t_csr0_val = sign_extend32({26'd0, r_random});
	    end
	  'd2:
	    begin
	       t_csr0_val = sign_extend32({2'd0,
					   r_entrylo0_pfn[23:0],
					   r_entrylo0_c,
					   r_entrylo0_d,
					   r_entrylo0_v,
					   r_entrylo0_g});
	    end
	  'd3:
	    begin
	       t_csr0_val = sign_extend32({2'd0,
					   r_entrylo1_pfn[23:0],
					   r_entrylo1_c,
					   r_entrylo1_d,
					   r_entrylo1_v,
					   r_entrylo1_g});
	    end
	  'd4:
	    begin
	       t_csr0_val = sign_extend32({r_ptebase,r_badvpn2[18:0],4'd0});
	    end
	  'd5:
	    begin
	       t_csr0_val = sign_extend32({7'd0, r_pagemask, 13'd0});
	    end
	  'd6:
	    begin
	       t_csr0_val = sign_extend32({26'd0, r_wired});
	    end
	  'd7:
	    begin
	       t_csr0_val = sign_extend32({31'd0, w_putchar_fifo_full});
	    end
	  'd8:
	    begin
	       t_csr0_val = r_badvaddr;
	    end
	  'd10:
	    begin
	       t_csr0_val = sign_extend32({r_entryhi_vpn2[18:0], 5'd0, r_entryhi_asid});
	    end
	  'd12:
	    begin
	       t_csr0_val = sign_extend32(cpr0_status_reg);
	       //$display("reading cpr status reg %x", cpr0_status_reg);
	    end
	  'd9: /* Count */
	    begin
	       t_csr0_val = sign_extend32(r_count);
	    end
	  'd11: /* Compare */
	    begin
	       t_csr0_val = sign_extend32(r_compare);
	    end
	  'd13: /* cause */
	    begin
	       t_csr0_val = sign_extend32({r_exc_in_ds,
					   1'b0, /* must be zero */
					   2'd0, /* coproc field */
					   12'd0, /* must be zero */
					   w_ip, /* interrupt pending bits */
					   1'b0, /* must be zero */
					   r_cause,
					   2'd0 /* must be zero */});
	    end
	  'd14:
	    begin
	       t_csr0_val = r_epc;
	    end
	  'd18: /* WatchLo (functional register only; no watch hardware) */
	    begin
	       t_csr0_val = sign_extend32(r_watchlo);
	    end
	  'd19: /* WatchHi (functional register only; no watch hardware) */
	    begin
	       t_csr0_val = sign_extend32(r_watchhi);
	    end
	  'd15: /* PRId: read-only processor id */
	    begin
	       t_csr0_val = sign_extend32(`PRID_VALUE);
	    end
	  'd16:
	    begin
	       /* Config = R4600 value (0x0002e4b3): 16 KB I$ + 16 KB D$, 32-byte
		* lines, SC (bit 17) = no secondary cache.  IRIX's mlreset derives
		* cachecolormask from these cache-size fields; the R4600 value gives
		* cachecolormask=1 so pagecoloralign converges (MAME_QUESTIONS.md Q5
		* round-2).  SC=1 still makes the kernel skip the scache probe. */
	       t_csr0_val = 'h0002e4b3;
	    end
	  'd23:
	    begin
	       t_csr0_val = sign_extend32(r_cycle[31:0]);
	    end
	  'd24:
	    begin
	       t_csr0_val = sign_extend32(r_retired_insns[31:0]);
	    end
	endcase
     end

   always_comb
     begin
	t_csr0_64_val = t_csr0_val;
	case(int_uop.srcA[4:0])
	  'd2:
	    begin
	       t_csr0_64_val = {{(64-`PFN_WIDTH-6){1'b0}}, r_entrylo0_pfn, r_entrylo0_c,
				 r_entrylo0_d, r_entrylo0_v, r_entrylo0_g};
	    end
	  'd3:
	    begin
	       t_csr0_64_val = {{(64-`PFN_WIDTH-6){1'b0}}, r_entrylo1_pfn, r_entrylo1_c,
				 r_entrylo1_d, r_entrylo1_v, r_entrylo1_g};
	    end
	  'd10:
	    begin
	       t_csr0_64_val = {r_entryhi_r, 22'd0, r_entryhi_vpn2, 5'd0, r_entryhi_asid};
	    end
	  'd20:
	    begin
	       t_csr0_64_val = {r_xptebase, r_entryhi_r, r_badvpn2, 4'd0};
	    end
	endcase
     end

   
  
   always_comb
     begin
	n_random = r_random;
	n_wired = r_wired;
	/* write wired */
	if(r_start_int & t_wr_cpr0 & int_uop.dst == 'd6)
	  begin
	     n_wired = t_srcA[5:0];
	     n_random = 'd47;
	  end
	else if(retire)
	  begin
	     n_random = (r_random==r_wired) ? 'd47 : (r_random-'d1);
	  end
     end

   
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     complete_valid_1 <= 1'b0;
	  end
	else
	  begin
	     complete_valid_1 <= r_start_int && t_alu_valid || t_mul_complete || t_div_complete;
	  end
     end // always_ff@ (posedge clk)

   
   always_ff@(posedge clk)
     begin
	if(t_mul_complete || t_div_complete)
	  begin
	     complete_bundle_1.rob_ptr <= t_mul_complete ? t_rob_ptr_out : t_div_rob_ptr_out;
	     complete_bundle_1.complete <= 1'b1;
	     complete_bundle_1.faulted <= 1'b0;
	     complete_bundle_1.restart_pc <= 'd0;
	     complete_bundle_1.is_ii <= 1'b0;
	     complete_bundle_1.take_br <= 1'b0;
	     complete_bundle_1.overflow <= 1'b0;
	     complete_bundle_1.trap <= 1'b0;
	     complete_bundle_1.data <= t_mul_result[`M_WIDTH-1:0];
	  end
	else
	  begin
	     complete_bundle_1.rob_ptr <= int_uop.rob_ptr;
	     complete_bundle_1.complete <= t_alu_valid;
	     complete_bundle_1.faulted <= t_mispred_br || t_unimp_op || t_fault;
	     complete_bundle_1.restart_pc <= t_pc;
	     complete_bundle_1.is_ii <= t_unimp_op;
	     complete_bundle_1.take_br <= t_take_br;
	     complete_bundle_1.overflow <= t_overflow;
	     complete_bundle_1.trap <= t_trap;	     
	     complete_bundle_1.data <= t_result;
	  end
	//(uq.rob_ptr == 'd5) ? 1'b1 : 1'b0;
     end


endmodule
