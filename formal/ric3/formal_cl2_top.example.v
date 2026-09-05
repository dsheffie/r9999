module formal_cl2_top(
	mem_rsp_free,
	clk,
	fml_diva_bad,
	fml_diva_act,
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
	in_flush_mode,
	resume,
	resume_pc,
	ready_for_resume,
	mem_req_valid,
	mem_req_addr,
	mem_req_store_data,
	mem_req_opcode,
	mem_req_mask,
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
	ext_flush_req,
	ext_flush_done,
	dbg_flush,
	dma_inval_req,
	dma_inval_addr,
	dma_inval_ack,
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
   input clk;
   input mem_rsp_free;
   output [1:0] fml_diva_bad;
   output [1:0] fml_diva_act;
   input  ip6;
   input  ip5;
   input  ip4;
   input  ip3;
   input  ip2;
   input  retire_allowed;
   output [7:0] putchar_fifo_out;
   output  putchar_fifo_empty;
   input  putchar_fifo_pop;
   output [3:0] putchar_fifo_wptr;
   output [3:0] putchar_fifo_rptr;
   output  in_flush_mode;
   input  resume;
   input [63:0] resume_pc;
   output  ready_for_resume;
   output  mem_req_valid;
   output [35:0] mem_req_addr;
   output [127:0] mem_req_store_data;
   output [4:0] mem_req_opcode;
   output [15:0] mem_req_mask;
   input  mem_rsp_bad;
   input [127:0] mem_rsp_load_data;
   output [4:0] retire_reg_ptr;
   output [63:0] retire_reg_data;
   output  retire_reg_valid;
   output [4:0] retire_reg_two_ptr;
   output [63:0] retire_reg_two_data;
   output  retire_reg_two_valid;
   output  retire_valid;
   output  retire_two_valid;
   output [63:0] retire_pc;
   output [63:0] retire_two_pc;
   output [7:0] retire_op;
   output [7:0] retire_two_op;
   output [63:0] branch_pc;
   output  branch_pc_valid;
   output  branch_fault;
   output [63:0] l1i_cache_accesses;
   output [63:0] l1i_cache_hits;
   output [63:0] l1d_cache_accesses;
   output [63:0] l1d_cache_hits;
   output [63:0] l2_cache_accesses;
   output [63:0] l2_cache_hits;
   output  got_break;
   output  got_ud;
   output  got_bad_addr;
   output [4:0] core_state;
   output [3:0] l1i_state;
   output [3:0] l1d_state;
   output [3:0] l2_state;
   output [3:0] l2_rsp_state;
   output [2:0] inflight;
   output [63:0] epc;
   output [31:0] status_reg;
   output [63:0] badvaddr;
   output [4:0] cause;
   output [2:0] dbg_frozen;
   output [31:0] dbg_wp_data;
   output [7:0] cause_ip;
   output  l1i_flush_done;
   output  l1d_flush_done;
   output  l2_flush_done;
   input  ext_flush_req;
   output  ext_flush_done;
   output [31:0] dbg_flush;
   input  dma_inval_req;
   input [35:0] dma_inval_addr;
   output  dma_inval_ack;
   input  snoop_req_valid;
   input [35:0] snoop_req_addr;
   output  snoop_req_ack;
   output  took_irq;
   output [31:0] cp0_count;
   output [31:0] dbg_head_pc;
   output [31:0] dbg_head_status;
   output [31:0] dbg_head_fetch_cycle;
   output [31:0] dbg_head_alloc_cycle;
   output [31:0] dbg_serialize_cycle;
   output [31:0] dbg_cycle;
   output  dbg_oldest_first_pending;
   input [19:0] dbg_trace_index;
   output [31:0] dbg_trace_data;
   output [15:0] dbg_trace_wptr;
   reg [3:0] r_cnt = 4'd0;
   always @(posedge clk) if(r_cnt != 4'hf) r_cnt <= r_cnt + 4'd1;
   wire w_rst = (r_cnt == 4'd0);
   reg r_dram_out = 1'b0;
   wire w_mem_rsp_valid = mem_rsp_free & r_dram_out;
   always @(posedge clk) begin
     if(w_rst) r_dram_out <= 1'b0;
     else begin
       if(mem_req_valid & mem_req_ack & ~w_mem_rsp_valid) r_dram_out <= 1'b1;
       else if(w_mem_rsp_valid) r_dram_out <= 1'b0;
     end
   end

   core_l1d_l1i dut (
      .clk(clk),
      .fml_diva_bad(fml_diva_bad),
      .fml_diva_act(fml_diva_act),
      .reset(w_rst),
      .ip6(ip6),
      .ip5(ip5),
      .ip4(ip4),
      .ip3(ip3),
      .ip2(ip2),
      .retire_allowed(retire_allowed),
      .putchar_fifo_out(putchar_fifo_out),
      .putchar_fifo_empty(putchar_fifo_empty),
      .putchar_fifo_pop(putchar_fifo_pop),
      .putchar_fifo_wptr(putchar_fifo_wptr),
      .putchar_fifo_rptr(putchar_fifo_rptr),
      .single_step(1'b0),
      .bp_enable(1'b0),
      .fault_clear(1'b0),
      .bp_pc({(31+1){1'b0}}),
      .bp_wp_addr({(31+1){1'b0}}),
      .bp_wp_val({(31+1){1'b0}}),
      .step(1'b0),
      .in_flush_mode(in_flush_mode),
      .resume(resume),
      .resume_pc(resume_pc),
      .ready_for_resume(ready_for_resume),
      .mem_req_valid(mem_req_valid),
      .mem_req_addr(mem_req_addr),
      .mem_req_store_data(mem_req_store_data),
      .mem_req_opcode(mem_req_opcode),
      .mem_req_mask(mem_req_mask),
      .mem_rsp_valid(w_mem_rsp_valid),
      .mem_rsp_bad(mem_rsp_bad),
      .mem_rsp_load_data(mem_rsp_load_data),
      .retire_reg_ptr(retire_reg_ptr),
      .retire_reg_data(retire_reg_data),
      .retire_reg_valid(retire_reg_valid),
      .retire_reg_two_ptr(retire_reg_two_ptr),
      .retire_reg_two_data(retire_reg_two_data),
      .retire_reg_two_valid(retire_reg_two_valid),
      .retire_valid(retire_valid),
      .retire_two_valid(retire_two_valid),
      .retire_pc(retire_pc),
      .retire_two_pc(retire_two_pc),
      .retire_op(retire_op),
      .retire_two_op(retire_two_op),
      .branch_pc(branch_pc),
      .branch_pc_valid(branch_pc_valid),
      .branch_fault(branch_fault),
      .l1i_cache_accesses(l1i_cache_accesses),
      .l1i_cache_hits(l1i_cache_hits),
      .l1d_cache_accesses(l1d_cache_accesses),
      .l1d_cache_hits(l1d_cache_hits),
      .l2_cache_accesses(l2_cache_accesses),
      .l2_cache_hits(l2_cache_hits),
      .got_break(got_break),
      .got_ud(got_ud),
      .got_bad_addr(got_bad_addr),
      .core_state(core_state),
      .l1i_state(l1i_state),
      .l1d_state(l1d_state),
      .l2_state(l2_state),
      .l2_rsp_state(l2_rsp_state),
      .inflight(inflight),
      .epc(epc),
      .status_reg(status_reg),
      .badvaddr(badvaddr),
      .cause(cause),
      .dbg_frozen(dbg_frozen),
      .dbg_wp_data(dbg_wp_data),
      .cause_ip(cause_ip),
      .l1i_flush_done(l1i_flush_done),
      .l1d_flush_done(l1d_flush_done),
      .l2_flush_done(l2_flush_done),
      .ext_flush_req(ext_flush_req),
      .ext_flush_done(ext_flush_done),
      .dbg_flush(dbg_flush),
      .dma_inval_req(dma_inval_req),
      .dma_inval_addr(dma_inval_addr),
      .dma_inval_ack(dma_inval_ack),
      .snoop_req_valid(snoop_req_valid),
      .snoop_req_addr(snoop_req_addr),
      .snoop_req_ack(snoop_req_ack),
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
      .dbg_trace_data(dbg_trace_data),
      .dbg_trace_wptr(dbg_trace_wptr)
   );
endmodule
