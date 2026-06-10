module core_l1d_l1i (
	clk,
	reset,
	retire_allowed,
	putchar_fifo_out,
	putchar_fifo_empty,
	putchar_fifo_pop,
	putchar_fifo_wptr,
	putchar_fifo_rptr,
	extern_irq,
	single_step,
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
	badvaddr,
	cause,
	l1i_flush_done,
	l1d_flush_done,
	l2_flush_done,
	took_irq,
	cp0_count
);
	reg _sv2v_0;
	localparam L1D_CL_LEN = 16;
	localparam L1D_CL_LEN_BITS = 128;
	input wire clk;
	input wire reset;
	input wire retire_allowed;
	output wire [7:0] putchar_fifo_out;
	output wire putchar_fifo_empty;
	input wire putchar_fifo_pop;
	output wire [3:0] putchar_fifo_wptr;
	output wire [3:0] putchar_fifo_rptr;
	input wire extern_irq;
	input wire single_step;
	input wire step;
	input wire resume;
	input wire [63:0] resume_pc;
	output wire in_flush_mode;
	output wire ready_for_resume;
	wire [63:0] restart_pc;
	wire [63:0] restart_src_pc;
	wire restart_src_is_indirect;
	wire restart_valid;
	wire clr_link_reg;
	wire restart_ack;
	wire [15:0] branch_pht_idx;
	wire took_branch;
	wire t_retire_delay_slot;
	wire [63:0] t_branch_pc;
	wire t_branch_pc_valid;
	wire t_branch_fault;
	output wire [63:0] branch_pc;
	output wire branch_pc_valid;
	output wire branch_fault;
	assign branch_pc = t_branch_pc;
	assign branch_pc_valid = t_branch_pc_valid;
	assign branch_fault = t_branch_fault;
	output wire [63:0] l1i_cache_accesses;
	output wire [63:0] l1i_cache_hits;
	output wire [63:0] l1d_cache_accesses;
	output wire [63:0] l1d_cache_hits;
	output wire [63:0] l2_cache_accesses;
	output wire [63:0] l2_cache_hits;
	output wire mem_req_valid;
	output wire [63:0] mem_req_addr;
	output wire [127:0] mem_req_store_data;
	output wire [4:0] mem_req_opcode;
	output wire [15:0] mem_req_mask;
	input wire mem_rsp_valid;
	input wire mem_rsp_bad;
	input wire [127:0] mem_rsp_load_data;
	output wire [4:0] retire_reg_ptr;
	output wire [63:0] retire_reg_data;
	output wire retire_reg_valid;
	output wire [4:0] retire_reg_two_ptr;
	output wire [63:0] retire_reg_two_data;
	output wire retire_reg_two_valid;
	output wire retire_valid;
	output wire retire_two_valid;
	output wire [63:0] retire_pc;
	output wire [63:0] retire_two_pc;
	output wire [6:0] retire_op;
	output wire [6:0] retire_two_op;
	wire retired_call;
	wire retired_ret;
	wire retired_rob_ptr_valid;
	wire retired_rob_ptr_two_valid;
	wire [4:0] retired_rob_ptr;
	wire [4:0] retired_rob_ptr_two;
	output wire got_break;
	output wire got_ud;
	output wire got_bad_addr;
	output wire [5:0] inflight;
	output wire [4:0] core_state;
	output wire [2:0] l1i_state;
	output wire [3:0] l1d_state;
	output wire [3:0] l2_state;
	output wire [3:0] l2_rsp_state;
	output wire [63:0] epc;
	output wire [63:0] badvaddr;
	output wire [4:0] cause;
	output wire l1d_flush_done;
	output wire l1i_flush_done;
	output wire l2_flush_done;
	output wire took_irq;
	output wire [31:0] cp0_count;
	wire head_of_rob_ptr_valid;
	wire [4:0] head_of_rob_ptr;
	wire head_of_rob_has_delay_slot;
	wire w_in_kernel_mode;
	wire w_in_supervisor_mode;
	wire w_in_user_mode;
	wire w_in_64b_kernel_mode;
	wire w_in_64b_supervisor_mode;
	wire w_in_64b_user_mode;
	wire flush_req_l1i;
	wire flush_req_l1d;
	wire flush_cl_req;
	wire [63:0] flush_cl_addr;
	wire l1d_flush_complete;
	wire l1i_flush_complete;
	wire [150:0] core_mem_req;
	wire [87:0] core_mem_rsp;
	wire [68:0] core_store_data;
	wire core_mem_req_valid;
	wire core_mem_req_ack;
	wire core_mem_rsp_valid;
	wire core_store_data_valid;
	wire core_store_data_ack;
	reg [2:0] n_flush_state;
	reg [2:0] r_flush_state;
	reg r_flush;
	reg n_flush;
	reg r_flush_l2;
	reg n_flush_l2;
	wire w_l2_flush_complete;
	wire w_l1_mem_rsp_valid;
	wire memq_empty;
	assign in_flush_mode = r_flush;
	wire [7:0] w_asid;
	always @(posedge clk)
		if (reset) begin
			r_flush_state <= 3'd0;
			r_flush <= 1'b0;
			r_flush_l2 <= 1'b0;
		end
		else begin
			r_flush_state <= n_flush_state;
			r_flush <= n_flush;
			r_flush_l2 <= n_flush_l2;
		end
	always @(*) begin
		if (_sv2v_0)
			;
		n_flush_state = r_flush_state;
		n_flush = r_flush;
		n_flush_l2 = 1'b0;
		case (r_flush_state)
			3'd0:
				if (flush_req_l1i && flush_req_l1d) begin
					n_flush_state = 3'd1;
					n_flush = 1'b1;
				end
				else if (flush_req_l1i && !flush_req_l1d) begin
					n_flush_state = 3'd2;
					n_flush = 1'b1;
				end
				else if (!flush_req_l1i && flush_req_l1d) begin
					n_flush_state = 3'd3;
					n_flush = 1'b1;
				end
			3'd1:
				if (l1d_flush_complete && !l1i_flush_complete)
					n_flush_state = 3'd2;
				else if (!l1d_flush_complete && l1i_flush_complete)
					n_flush_state = 3'd3;
				else if (l1d_flush_complete && l1i_flush_complete) begin
					$display("flush l2");
					n_flush_state = 3'd4;
					n_flush_l2 = 1'b1;
				end
			3'd2:
				if (l1i_flush_complete) begin
					$display("flush l2");
					n_flush_state = 3'd4;
					n_flush_l2 = 1'b1;
				end
			3'd3:
				if (l1d_flush_complete) begin
					$display("flush l2");
					n_flush_state = 3'd4;
					n_flush_l2 = 1'b1;
				end
			3'd4:
				if (w_l2_flush_complete) begin
					$display("L2 FLUSH COMPLETE");
					n_flush = 1'b0;
					n_flush_state = 3'd0;
				end
			default:
				;
		endcase
	end
	wire l1d_mem_req_ack;
	wire l1d_mem_req_valid;
	wire [63:0] l1d_mem_req_addr;
	wire [127:0] l1d_mem_req_store_data;
	wire [4:0] l1d_mem_req_opcode;
	wire l1d_mem_req_cacheable;
	wire [15:0] l1d_mem_req_mask;
	wire l1i_mem_req_ack;
	wire l1i_mem_req_valid;
	wire l1i_mem_req_cacheable;
	wire [63:0] l1i_mem_req_addr;
	wire [15:0] l1i_mem_req_mask;
	wire [127:0] l1i_mem_req_store_data;
	wire [4:0] l1i_mem_req_opcode;
	reg l1d_mem_rsp_valid;
	reg l1i_mem_rsp_valid;
	reg [1:0] r_state;
	reg [1:0] n_state;
	reg r_l1d_req;
	reg n_l1d_req;
	reg r_l1i_req;
	reg n_l1i_req;
	reg r_last_gnt;
	reg n_last_gnt;
	reg n_req;
	reg r_req;
	wire insn_valid;
	wire insn_valid2;
	wire insn_ack;
	wire insn_ack2;
	wire [180:0] insn;
	wire [180:0] insn2;
	reg [63:0] t_l2_req_addr;
	reg [4:0] t_l2_req_opcode;
	reg t_l2_req_cacheable;
	reg [15:0] t_l2_req_mask;
	wire [122:0] tlb_entry_out;
	wire tlb_entry_out_valid;
	wire w_l1_mem_req_ack;
	always @(*) begin
		if (_sv2v_0)
			;
		n_state = r_state;
		n_last_gnt = r_last_gnt;
		n_l1i_req = r_l1i_req || l1i_mem_req_valid;
		n_l1d_req = r_l1d_req || l1d_mem_req_valid;
		n_req = r_req;
		t_l2_req_addr = (r_state == 2'd2 ? l1i_mem_req_addr : l1d_mem_req_addr);
		t_l2_req_opcode = (r_state == 2'd2 ? l1i_mem_req_opcode : l1d_mem_req_opcode);
		t_l2_req_cacheable = (r_state == 2'd2 ? l1i_mem_req_cacheable : l1d_mem_req_cacheable);
		t_l2_req_mask = (r_state == 2'd2 ? l1i_mem_req_mask : l1d_mem_req_mask);
		l1d_mem_rsp_valid = 1'b0;
		l1i_mem_rsp_valid = 1'b0;
		case (r_state)
			2'd0:
				if (n_l1d_req && !n_l1i_req) begin
					n_state = 2'd1;
					n_req = 1'b1;
				end
				else if (!n_l1d_req && n_l1i_req) begin
					n_state = 2'd2;
					n_req = 1'b1;
				end
				else if (n_l1d_req && n_l1i_req) begin
					n_state = (r_last_gnt ? 2'd1 : 2'd2);
					n_req = 1'b1;
				end
			2'd1: begin
				n_last_gnt = 1'b0;
				n_l1d_req = 1'b0;
				if (w_l1_mem_req_ack)
					n_req = 1'b0;
				if (w_l1_mem_rsp_valid) begin
					n_req = 1'b0;
					n_state = 2'd0;
					l1d_mem_rsp_valid = 1'b1;
				end
			end
			2'd2: begin
				n_last_gnt = 1'b1;
				n_l1i_req = 1'b0;
				if (w_l1_mem_req_ack)
					n_req = 1'b0;
				if (w_l1_mem_rsp_valid) begin
					n_req = 1'b0;
					n_state = 2'd0;
					l1i_mem_rsp_valid = 1'b1;
				end
			end
			default:
				;
		endcase
	end
	wire [127:0] w_l1_mem_load_data;
	l2 l2cache(
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
		.cache_hits(l2_cache_hits)
	);
	always @(posedge clk)
		if (reset) begin
			r_state <= 2'd0;
			r_last_gnt <= 1'b0;
			r_l1d_req <= 1'b0;
			r_l1i_req <= 1'b0;
			r_req <= 1'b0;
		end
		else begin
			r_state <= n_state;
			r_last_gnt <= n_last_gnt;
			r_l1d_req <= n_l1d_req;
			r_l1i_req <= n_l1i_req;
			r_req <= n_req;
		end
	wire drain_ds_complete;
	wire [31:0] dead_rob_mask;
	l1d dcache(
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
	core cpu(
		.clk(clk),
		.reset(reset),
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
		.extern_irq(extern_irq),
		.single_step(single_step),
		.step(step),
		.resume(resume),
		.memq_empty(memq_empty),
		.drain_ds_complete(drain_ds_complete),
		.dead_rob_mask(dead_rob_mask),
		.head_of_rob_ptr_valid(head_of_rob_ptr_valid),
		.head_of_rob_ptr(head_of_rob_ptr),
		.head_of_rob_has_delay_slot(head_of_rob_has_delay_slot),
		.resume_pc(resume_pc),
		.ready_for_resume(ready_for_resume),
		.flush_req_l1d(flush_req_l1d),
		.flush_req_l1i(flush_req_l1i),
		.flush_cl_req(flush_cl_req),
		.flush_cl_addr(flush_cl_addr),
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
		.badvaddr(badvaddr),
		.cause(cause),
		.asid(w_asid),
		.tlb_entry_out_valid(tlb_entry_out_valid),
		.tlb_entry_out(tlb_entry_out),
		.l1i_flush_done(l1i_flush_done),
		.l1d_flush_done(l1d_flush_done),
		.l2_flush_done(l2_flush_done),
		.took_irq(took_irq),
		.cp0_count(cp0_count)
	);
	initial _sv2v_0 = 0;
endmodule

module shift_right (
	y,
	is_left,
	is_signed,
	is_circular,
	data,
	distance
);
	parameter LG_W = 5;
	localparam W = 1 << LG_W;
	input wire is_left;
	input wire is_signed;
	input wire is_circular;
	input wire [W - 1:0] data;
	input wire [LG_W - 1:0] distance;
	output wire [W - 1:0] y;
	wire w_sb = (is_signed ? data[W - 1] : 1'b0);
	wire [(2 * W) - 1:0] w_data = (is_circular ? {data, data} : (is_left ? {data, {W {1'b0}}} : {{W {w_sb}}, data}));
	wire [LG_W:0] w_inv_dist = W - {1'b0, distance};
	wire [LG_W:0] w_distance = (is_left ? w_inv_dist[LG_W:0] : {1'b0, distance});
	wire [(2 * W) - 1:0] w_shift = w_data >> w_distance;
	assign y = w_shift[W - 1:0];
endmodule

module reg_ram1rw (
	clk,
	addr,
	wr_data,
	wr_en,
	rd_data
);
	input wire clk;
	parameter WIDTH = 1;
	parameter LG_DEPTH = 1;
	input wire [LG_DEPTH - 1:0] addr;
	input wire [WIDTH - 1:0] wr_data;
	input wire wr_en;
	output reg [WIDTH - 1:0] rd_data;
	localparam DEPTH = 1 << LG_DEPTH;
	reg [WIDTH - 1:0] r_ram [DEPTH - 1:0];
	reg [LG_DEPTH - 1:0] r_addr;
	reg r_wr_en;
	reg [WIDTH - 1:0] r_wr_data;
	always @(posedge clk) begin
		r_addr <= addr;
		r_wr_en <= wr_en;
		r_wr_data <= wr_data;
		rd_data <= r_ram[r_addr];
		if (r_wr_en)
			r_ram[r_addr] <= r_wr_data;
	end
endmodule

module predecode (
	insn_,
	pd
);
	reg _sv2v_0;
	input wire [31:0] insn_;
	output reg [3:0] pd;
	reg [31:0] insn;
	function [31:0] bswap32;
		input reg [31:0] in;
		bswap32 = {in[7:0], in[15:8], in[23:16], in[31:24]};
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		pd = 4'd0;
		insn = bswap32(insn_);
		case (insn[31:26])
			6'd0:
				if (insn[5:0] == 6'd8)
					pd = (insn[25:21] == 5'd31 ? 4'd7 : 4'd4);
				else if (insn[5:0] == 6'd9)
					pd = 4'd6;
			6'd1:
				case (insn[20:16])
					'd0: pd = 4'd1;
					'd1: pd = 4'd1;
					'd2: pd = 4'd2;
					'd3: pd = 4'd2;
					'd17: pd = 4'd9;
					default:
						;
				endcase
			6'd2: pd = 4'd3;
			6'd3: pd = 4'd5;
			6'd4: pd = ((insn[25:21] == 'd0) && (insn[20:16] == 'd0) ? 4'd8 : 4'd1);
			6'd5: pd = 4'd1;
			6'd6: pd = 4'd1;
			6'd7: pd = 4'd1;
			6'd17:
				if (insn[25:21] == 5'd8)
					case (insn[17:16])
						2'b00: pd = 4'd1;
						2'b01: pd = 4'd1;
						2'b10: pd = 4'd2;
						2'b11: pd = 4'd2;
					endcase
			6'd20: pd = 4'd2;
			6'd21: pd = 4'd2;
			6'd22: pd = 4'd2;
			6'd23: pd = 4'd2;
			default: pd = 4'd0;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule

module mipsseg (
	v_addr,
	l_addr,
	cache,
	mapped,
	seg,
	in_kernel_mode,
	in_supervisor_mode,
	in_user_mode,
	in_64b_kernel_mode,
	in_64b_supervisor_mode,
	in_64b_user_mode
);
	reg _sv2v_0;
	input wire [63:0] v_addr;
	output reg [63:0] l_addr;
	output reg cache;
	output reg mapped;
	output reg [1:0] seg;
	input wire in_kernel_mode;
	input wire in_supervisor_mode;
	input wire in_user_mode;
	input wire in_64b_kernel_mode;
	input wire in_64b_supervisor_mode;
	input wire in_64b_user_mode;
	wire [3:0] w_seg = v_addr[31:28];
	localparam ZP = 35;
	wire w_in_64b_mode;
	generate
		if (1) begin : genblk1
			assign w_in_64b_mode = (in_64b_kernel_mode | in_64b_supervisor_mode) | in_64b_user_mode;
		end
	endgenerate
	always @(*) begin
		if (_sv2v_0)
			;
		cache = 1'b0;
		mapped = 1'b0;
		seg = 2'd0;
		l_addr = v_addr;
		if (!(!w_in_64b_mode) && (v_addr[63:62] == 2'b10)) begin
			mapped = 1'b0;
			cache = v_addr[61:59] == 3'b011;
			l_addr = {5'b00000, v_addr[58:0]};
			seg = 2'd0;
		end
		else if (!(!(!w_in_64b_mode)) || (v_addr[63:32] == 32'hffffffff)) begin
			if (w_seg[3] == 1'b0) begin
				cache = 1'b1;
				mapped = 1'b1;
				l_addr = v_addr;
				seg = 'd3;
			end
			else if (w_seg[3:1] == 3'b100) begin
				mapped = 1'b0;
				cache = 1'b1;
				l_addr = {{ZP {1'b0}}, v_addr[28:0]};
				seg = 'd0;
			end
			else if (w_seg[3:1] == 3'b101) begin
				mapped = 1'b0;
				cache = 1'b0;
				l_addr = {{ZP {1'b0}}, v_addr[28:0]};
				seg = 'd1;
			end
			else begin
				mapped = 1'b1;
				cache = 1'b0;
				l_addr = v_addr;
				seg = 'd2;
			end
		end
		else if (v_addr[63:62] == 2'b00) begin
			cache = 1'b1;
			mapped = 1'b1;
			l_addr = v_addr;
			seg = 2'd3;
		end
		else begin
			mapped = 1'b1;
			cache = 1'b0;
			l_addr = v_addr;
			seg = 2'd2;
		end
	end
	initial _sv2v_0 = 0;
endmodule

module dffen (
	q,
	d,
	clk,
	reset,
	en
);
	parameter N = 1;
	input wire [N - 1:0] d;
	input wire clk;
	input wire reset;
	input wire en;
	output reg [N - 1:0] q;
	always @(posedge clk)
		if (reset)
			q <= 1'b0;
		else
			q <= (en ? d : q);
endmodule
module shiftregbit (
	clk,
	reset,
	b,
	valid,
	out
);
	input wire clk;
	input wire reset;
	input wire b;
	input wire valid;
	parameter W = 32;
	output wire [W - 1:0] out;
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < W; _gv_i_1 = _gv_i_1 + 1) begin : sr
			localparam i = _gv_i_1;
			if (i == 0) begin : genblk1
				dffen #(.N(1)) ff(
					.clk(clk),
					.reset(reset),
					.en(valid),
					.d(b),
					.q(out[0])
				);
			end
			else begin : genblk1
				dffen #(.N(1)) ff(
					.clk(clk),
					.reset(reset),
					.en(valid),
					.d(out[i - 1]),
					.q(out[i])
				);
			end
		end
	endgenerate
endmodule

module divider (
	clk,
	reset,
	srcA,
	srcB,
	is_32b,
	rob_ptr_in,
	hilo_prf_ptr_in,
	is_signed_div,
	start_div,
	y,
	rob_ptr_out,
	hilo_prf_ptr_out,
	ready,
	complete
);
	reg _sv2v_0;
	parameter LG_W = 5;
	localparam W = 1 << LG_W;
	localparam W2 = 2 * W;
	input wire clk;
	input wire reset;
	input wire [W - 1:0] srcA;
	input wire [W - 1:0] srcB;
	input wire is_32b;
	input wire [4:0] rob_ptr_in;
	input wire [1:0] hilo_prf_ptr_in;
	input wire is_signed_div;
	input wire start_div;
	output reg [W2 - 1:0] y;
	output reg [4:0] rob_ptr_out;
	output reg [1:0] hilo_prf_ptr_out;
	output reg ready;
	output reg complete;
	reg [1:0] r_state;
	reg [1:0] n_state;
	reg r_is_signed;
	reg n_is_signed;
	reg r_sign;
	reg n_sign;
	reg r_rem_sign;
	reg n_rem_sign;
	reg [4:0] r_rob_ptr;
	reg [4:0] n_rob_ptr;
	reg [1:0] r_hilo_prf_ptr;
	reg [1:0] n_hilo_prf_ptr;
	reg [W - 1:0] r_A;
	reg [W - 1:0] n_A;
	reg [W - 1:0] r_B;
	reg [W - 1:0] n_B;
	reg [W2 - 1:0] r_Y;
	reg [W2 - 1:0] n_Y;
	reg [W2 - 1:0] r_D;
	reg [W2 - 1:0] n_D;
	reg [W2 - 1:0] r_R;
	reg [W2 - 1:0] n_R;
	wire [W - 1:0] t_ss;
	reg r_is_32b;
	reg n_is_32b;
	reg [LG_W - 1:0] r_idx;
	reg [LG_W - 1:0] n_idx;
	reg t_bit;
	reg t_valid;
	always @(posedge clk)
		if (reset) begin
			r_state <= 2'd0;
			r_rob_ptr <= 'd0;
			r_hilo_prf_ptr <= 'd0;
			r_is_signed <= 1'b0;
			r_sign <= 1'b0;
			r_rem_sign <= 1'b0;
			r_A <= 'd0;
			r_B <= 'd0;
			r_Y <= 'd0;
			r_D <= 'd0;
			r_R <= 'd0;
			r_idx <= 'd0;
			r_is_32b <= 1'b0;
		end
		else begin
			r_state <= n_state;
			r_rob_ptr <= n_rob_ptr;
			r_hilo_prf_ptr <= n_hilo_prf_ptr;
			r_is_signed <= n_is_signed;
			r_sign <= n_sign;
			r_rem_sign <= n_rem_sign;
			r_A <= n_A;
			r_B <= n_B;
			r_Y <= n_Y;
			r_D <= n_D;
			r_R <= n_R;
			r_idx <= n_idx;
			r_is_32b <= n_is_32b;
		end
	shiftregbit #(.W(W)) ss(
		.clk(clk),
		.reset(reset),
		.b(t_bit),
		.valid(t_valid),
		.out(t_ss)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		n_rob_ptr = r_rob_ptr;
		n_hilo_prf_ptr = r_hilo_prf_ptr;
		n_state = r_state;
		n_is_signed = r_is_signed;
		n_sign = r_sign;
		n_rem_sign = r_rem_sign;
		n_A = r_A;
		n_B = r_B;
		n_Y = r_Y;
		n_D = r_D;
		n_R = r_R;
		n_idx = r_idx;
		t_bit = 1'b0;
		t_valid = 1'b0;
		n_is_32b = r_is_32b;
		ready = (r_state == 2'd0) & !start_div;
		rob_ptr_out = r_rob_ptr;
		hilo_prf_ptr_out = r_hilo_prf_ptr;
		y = r_Y;
		complete = 1'b0;
		(* full_case, parallel_case *)
		case (r_state)
			2'd0: begin
				n_rob_ptr = rob_ptr_in;
				n_hilo_prf_ptr = hilo_prf_ptr_in;
				n_is_signed = is_signed_div;
				n_state = (start_div ? 2'd1 : 2'd0);
				n_idx = W - 1;
				n_sign = srcA[W - 1] ^ srcB[W - 1];
				n_is_32b = is_32b;
				n_rem_sign = srcA[W - 1];
				n_A = srcA;
				n_B = srcB;
				if (is_32b) begin
					n_A = {{32 {(is_signed_div ? srcA[31] : 1'b0)}}, srcA[31:0]};
					n_B = {{32 {(is_signed_div ? srcB[31] : 1'b0)}}, srcB[31:0]};
				end
				n_A = (is_signed_div & srcA[W - 1] ? ~srcA + 'd1 : n_A);
				n_B = (is_signed_div & srcB[W - 1] ? ~srcB + 'd1 : n_B);
				n_D = {n_B, {W {1'b0}}};
				n_R = {{W {1'b0}}, n_A};
			end
			2'd1: begin
				if ({r_R[W2 - 2:0], 1'b0} >= r_D) begin
					n_R = {r_R[W2 - 2:0], 1'b0} - r_D;
					t_bit = 1'b1;
					t_valid = 1'b1;
				end
				else begin
					n_R = {r_R[W2 - 2:0], 1'b0};
					t_bit = 1'b0;
					t_valid = 1'b1;
				end
				n_state = (r_idx == 'd0 ? 2'd2 : 2'd1);
				n_idx = r_idx - 'd1;
			end
			2'd2: begin
				n_state = 2'd3;
				n_Y[W - 1:0] = t_ss;
				n_Y[W2 - 1:W] = n_R[W2 - 1:W];
				if (r_is_signed && r_sign)
					n_Y[W - 1:0] = ~t_ss + 'd1;
				if (r_is_signed && r_rem_sign)
					n_Y[W2 - 1:W] = ~n_R[W2 - 1:W] + 'd1;
				if (r_is_32b & 1'd1) begin
					n_Y[63:0] = {{32 {n_Y[31]}}, n_Y[31:0]};
					n_Y[127:64] = {{32 {n_Y[95]}}, n_Y[95:64]};
				end
			end
			2'd3: begin
				complete = 1'b1;
				n_state = 2'd0;
			end
			default:
				;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule

module ppa32 (
	A,
	B,
	Y
);
	input [31:0] A;
	input [31:0] B;
	output wire [31:0] Y;
	assign Y = A + B;
endmodule

module rf4r2w (
	clk,
	rdptr0,
	rdptr1,
	rdptr2,
	rdptr3,
	wrptr0,
	wrptr1,
	wen0,
	wen1,
	wr0,
	wr1,
	rd0,
	rd1,
	rd2,
	rd3
);
	parameter WIDTH = 1;
	parameter LG_DEPTH = 1;
	input wire clk;
	input wire [LG_DEPTH - 1:0] rdptr0;
	input wire [LG_DEPTH - 1:0] rdptr1;
	input wire [LG_DEPTH - 1:0] rdptr2;
	input wire [LG_DEPTH - 1:0] rdptr3;
	input wire [LG_DEPTH - 1:0] wrptr0;
	input wire [LG_DEPTH - 1:0] wrptr1;
	input wire wen0;
	input wire wen1;
	input wire [WIDTH - 1:0] wr0;
	input wire [WIDTH - 1:0] wr1;
	output reg [WIDTH - 1:0] rd0;
	output reg [WIDTH - 1:0] rd1;
	output reg [WIDTH - 1:0] rd2;
	output reg [WIDTH - 1:0] rd3;
	localparam HALF = 1 << (LG_DEPTH - 1);
	reg [WIDTH - 1:0] r_ram_alu [HALF - 1:0];
	reg [WIDTH - 1:0] r_ram_mem [HALF - 1:0];
	always @(posedge clk) begin
		rd0 <= (rdptr0 == 'd0 ? 'd0 : (rdptr0[LG_DEPTH - 1] ? r_ram_mem[rdptr0[LG_DEPTH - 2:0]] : r_ram_alu[rdptr0[LG_DEPTH - 2:0]]));
		rd1 <= (rdptr1 == 'd0 ? 'd0 : (rdptr1[LG_DEPTH - 1] ? r_ram_mem[rdptr1[LG_DEPTH - 2:0]] : r_ram_alu[rdptr1[LG_DEPTH - 2:0]]));
		rd2 <= (rdptr2 == 'd0 ? 'd0 : (rdptr2[LG_DEPTH - 1] ? r_ram_mem[rdptr2[LG_DEPTH - 2:0]] : r_ram_alu[rdptr2[LG_DEPTH - 2:0]]));
		rd3 <= (rdptr3 == 'd0 ? 'd0 : (rdptr3[LG_DEPTH - 1] ? r_ram_mem[rdptr3[LG_DEPTH - 2:0]] : r_ram_alu[rdptr3[LG_DEPTH - 2:0]]));
		if (wen0)
			r_ram_alu[wrptr0[LG_DEPTH - 2:0]] <= wr0;
		if (wen1)
			r_ram_mem[wrptr1[LG_DEPTH - 2:0]] <= wr1;
	end
endmodule

module compute_pht_idx (
	pc,
	hist,
	idx
);
	input wire [63:0] pc;
	input wire [63:0] hist;
	output wire [15:0] idx;
	wire [31:0] w_fold_0 = hist[31:0] ^ hist[63:32];
	wire [15:0] w_fold_1 = w_fold_0[31:16] ^ w_fold_0[15:0];
	assign idx = w_fold_1[15:0] ^ pc[18:3];
endmodule
module l1i (
	clk,
	state,
	asid,
	reset,
	in_kernel_mode,
	in_supervisor_mode,
	in_user_mode,
	in_64b_kernel_mode,
	in_64b_supervisor_mode,
	in_64b_user_mode,
	flush_req,
	flush_complete,
	restart_pc,
	restart_src_pc,
	restart_src_is_indirect,
	restart_valid,
	restart_ack,
	retire_valid,
	retired_call,
	retired_ret,
	retire_reg_ptr,
	retire_reg_data,
	retire_reg_valid,
	branch_pc_valid,
	branch_pc,
	took_branch,
	branch_fault,
	branch_pht_idx,
	insn,
	insn_valid,
	insn_ack,
	insn_two,
	insn_valid_two,
	insn_ack_two,
	mem_req_ack,
	mem_req_valid,
	mem_req_addr,
	mem_req_opcode,
	mem_req_cacheable,
	mem_req_mask,
	mem_rsp_valid,
	mem_rsp_load_data,
	cache_accesses,
	cache_hits,
	tlb_entry_in_valid,
	tlb_entry_in
);
	reg _sv2v_0;
	input wire clk;
	output wire [2:0] state;
	input wire [7:0] asid;
	input wire reset;
	input wire in_kernel_mode;
	input wire in_supervisor_mode;
	input wire in_user_mode;
	input wire in_64b_kernel_mode;
	input wire in_64b_supervisor_mode;
	input wire in_64b_user_mode;
	input wire flush_req;
	output wire flush_complete;
	input wire [63:0] restart_pc;
	input wire [63:0] restart_src_pc;
	input wire restart_src_is_indirect;
	input wire restart_valid;
	output wire restart_ack;
	input wire retire_valid;
	input wire retired_call;
	input wire retired_ret;
	input wire [4:0] retire_reg_ptr;
	input wire [63:0] retire_reg_data;
	input wire retire_reg_valid;
	input wire branch_pc_valid;
	input wire [63:0] branch_pc;
	input wire took_branch;
	input wire branch_fault;
	input wire [15:0] branch_pht_idx;
	output reg [180:0] insn;
	output wire insn_valid;
	input wire insn_ack;
	output reg [180:0] insn_two;
	output wire insn_valid_two;
	input wire insn_ack_two;
	input wire mem_req_ack;
	output wire mem_req_valid;
	localparam L1I_NUM_SETS = 256;
	localparam L1I_CL_LEN = 16;
	localparam L1I_CL_LEN_BITS = 128;
	localparam LG_WORDS_PER_CL = 2;
	localparam WORDS_PER_CL = 4;
	localparam N_TAG_BITS = 52;
	localparam IDX_START = 4;
	localparam IDX_STOP = 12;
	localparam WORD_START = 2;
	localparam WORD_STOP = 4;
	localparam N_FQ_ENTRIES = 8;
	localparam RETURN_STACK_ENTRIES = 4;
	localparam PHT_ENTRIES = 65536;
	localparam BTB_ENTRIES = 128;
	output wire [63:0] mem_req_addr;
	output wire [4:0] mem_req_opcode;
	output wire mem_req_cacheable;
	output wire [15:0] mem_req_mask;
	input wire mem_rsp_valid;
	input wire [127:0] mem_rsp_load_data;
	output wire [63:0] cache_accesses;
	output wire [63:0] cache_hits;
	input wire tlb_entry_in_valid;
	input wire [122:0] tlb_entry_in;
	reg [51:0] t_cache_tag;
	reg [51:0] r_cache_tag;
	wire [51:0] r_tag_out;
	reg r_pht_update;
	wire [1:0] r_pht_out;
	wire [1:0] r_pht_update_out;
	reg [1:0] t_pht_val;
	reg t_do_pht_wr;
	wire [15:0] n_pht_idx;
	reg [15:0] r_pht_idx;
	reg [15:0] r_pht_update_idx;
	reg [15:0] t_retire_pht_idx;
	reg r_take_br;
	reg [63:0] r_btb [127:0];
	reg [127:0] r_btb_valid;
	wire [15:0] r_jump_out;
	reg [7:0] t_cache_idx;
	reg [7:0] r_cache_idx;
	wire [127:0] r_array_out;
	reg r_mem_req_valid;
	reg n_mem_req_valid;
	reg [63:0] r_mem_req_addr;
	reg [63:0] n_mem_req_addr;
	reg r_mem_req_cacheable;
	reg n_mem_req_cacheable;
	reg [180:0] r_fq [7:0];
	reg [3:0] r_fq_head_ptr;
	reg [3:0] n_fq_head_ptr;
	reg [3:0] r_fq_next_head_ptr;
	reg [3:0] n_fq_next_head_ptr;
	reg [3:0] r_fq_next_tail_ptr;
	reg [3:0] n_fq_next_tail_ptr;
	reg [3:0] r_fq_next3_tail_ptr;
	reg [3:0] n_fq_next3_tail_ptr;
	reg [3:0] r_fq_next4_tail_ptr;
	reg [3:0] n_fq_next4_tail_ptr;
	reg [3:0] r_fq_tail_ptr;
	reg [3:0] n_fq_tail_ptr;
	reg r_resteer_bubble;
	reg n_resteer_bubble;
	reg fq_full;
	reg fq_next_empty;
	reg fq_empty;
	reg fq_full2;
	reg fq_full3;
	reg fq_full4;
	reg [255:0] r_spec_return_stack;
	reg [255:0] r_arch_return_stack;
	reg [1:0] n_arch_rs_tos;
	reg [1:0] r_arch_rs_tos;
	reg [1:0] n_spec_rs_tos;
	reg [1:0] r_spec_rs_tos;
	reg [1:0] t_next_spec_rs_tos;
	reg [63:0] n_arch_gbl_hist;
	reg [63:0] r_arch_gbl_hist;
	reg [63:0] n_spec_gbl_hist;
	reg [63:0] r_spec_gbl_hist;
	reg [63:0] r_last_spec_gbl_hist;
	reg [1:0] t_insn_idx;
	reg [63:0] n_cache_accesses;
	reg [63:0] r_cache_accesses;
	reg [63:0] n_cache_hits;
	reg [63:0] r_cache_hits;
	function [31:0] select_cl32;
		input reg [127:0] cl;
		input reg [1:0] pos;
		reg [31:0] w32;
		begin
			case (pos)
				2'd0: w32 = cl[31:0];
				2'd1: w32 = cl[63:32];
				2'd2: w32 = cl[95:64];
				2'd3: w32 = cl[127:96];
			endcase
			select_cl32 = w32;
		end
	endfunction
	function [3:0] select_pd;
		input reg [15:0] cl;
		input reg [1:0] pos;
		reg [3:0] j;
		begin
			case (pos)
				2'd0: j = cl[3:0];
				2'd1: j = cl[7:4];
				2'd2: j = cl[11:8];
				2'd3: j = cl[15:12];
			endcase
			select_pd = j;
		end
	endfunction
	reg [63:0] r_pc;
	reg [63:0] n_pc;
	reg [63:0] r_miss_pc;
	reg [63:0] n_miss_pc;
	reg [63:0] r_cache_pc;
	reg [63:0] n_cache_pc;
	reg [63:0] r_btb_pc;
	wire [63:0] w_la_pc;
	reg [63:0] r_la_pc;
	reg [63:0] r_tlb_pc;
	wire [63:0] w_tlb_pc;
	wire [1:0] w_seg;
	wire w_cached;
	wire w_mapped;
	reg r_cached;
	reg r_mapped;
	reg [2:0] n_state;
	reg [2:0] r_state;
	assign state = r_state;
	reg r_restart_req;
	reg n_restart_req;
	reg r_restart_ack;
	reg n_restart_ack;
	reg r_req;
	reg n_req;
	wire r_valid_out;
	reg t_miss;
	reg t_hit;
	reg t_push_insn;
	reg t_push_insn2;
	reg t_push_insn3;
	reg t_push_insn4;
	reg t_clear_fq;
	reg r_flush_req;
	reg n_flush_req;
	reg r_flush_complete;
	reg n_flush_complete;
	reg n_delay_slot;
	reg r_delay_slot;
	reg t_take_br;
	reg t_is_cflow;
	reg t_update_spec_hist;
	reg [31:0] t_insn_data;
	reg [31:0] t_insn_data2;
	reg [31:0] t_insn_data3;
	reg [31:0] t_insn_data4;
	reg [63:0] t_simm;
	reg t_is_call;
	reg t_is_ret;
	reg [2:0] t_branch_cnt;
	reg [4:0] t_branch_marker;
	reg [4:0] t_spec_branch_marker;
	reg [2:0] t_first_branch;
	reg t_init_pht;
	reg [15:0] r_init_pht_idx;
	reg [15:0] n_init_pht_idx;
	localparam SEXT = 48;
	reg [180:0] t_insn;
	reg [180:0] t_insn2;
	reg [180:0] t_insn3;
	reg [180:0] t_insn4;
	reg [3:0] t_pd;
	reg [3:0] r_pd;
	reg [63:0] r_cycle;
	always @(posedge clk) r_cycle <= (reset ? 'd0 : r_cycle + 'd1);
	assign flush_complete = r_flush_complete;
	assign insn_valid = !fq_empty;
	assign insn_valid_two = !(fq_next_empty || fq_empty);
	assign restart_ack = r_restart_ack;
	assign mem_req_valid = r_mem_req_valid;
	assign mem_req_addr = r_mem_req_addr;
	assign mem_req_opcode = 5'd4;
	assign mem_req_cacheable = r_mem_req_cacheable;
	assign mem_req_mask = 16'hffff;
	assign cache_hits = r_cache_hits;
	assign cache_accesses = r_cache_accesses;
	always @(*) begin
		if (_sv2v_0)
			;
		n_fq_tail_ptr = r_fq_tail_ptr;
		n_fq_head_ptr = r_fq_head_ptr;
		n_fq_next_head_ptr = r_fq_next_head_ptr;
		n_fq_next_tail_ptr = r_fq_next_tail_ptr;
		n_fq_next3_tail_ptr = r_fq_next3_tail_ptr;
		n_fq_next4_tail_ptr = r_fq_next4_tail_ptr;
		fq_empty = r_fq_head_ptr == r_fq_tail_ptr;
		fq_next_empty = r_fq_next_head_ptr == r_fq_tail_ptr;
		fq_full = (r_fq_head_ptr != r_fq_tail_ptr) && (r_fq_head_ptr[2:0] == r_fq_tail_ptr[2:0]);
		fq_full2 = ((r_fq_head_ptr != r_fq_next_tail_ptr) && (r_fq_head_ptr[2:0] == r_fq_next_tail_ptr[2:0])) || fq_full;
		fq_full3 = ((r_fq_head_ptr != r_fq_next3_tail_ptr) && (r_fq_head_ptr[2:0] == r_fq_next3_tail_ptr[2:0])) || fq_full2;
		fq_full4 = ((r_fq_head_ptr != r_fq_next4_tail_ptr) && (r_fq_head_ptr[2:0] == r_fq_next4_tail_ptr[2:0])) || fq_full3;
		insn = r_fq[r_fq_head_ptr[2:0]];
		insn_two = r_fq[r_fq_next_head_ptr[2:0]];
		if (t_push_insn4) begin
			n_fq_tail_ptr = r_fq_tail_ptr + 'd4;
			n_fq_next_tail_ptr = r_fq_next_tail_ptr + 'd4;
			n_fq_next3_tail_ptr = r_fq_next3_tail_ptr + 'd4;
			n_fq_next4_tail_ptr = r_fq_next4_tail_ptr + 'd4;
		end
		else if (t_push_insn3) begin
			n_fq_tail_ptr = r_fq_tail_ptr + 'd3;
			n_fq_next_tail_ptr = r_fq_next_tail_ptr + 'd3;
			n_fq_next3_tail_ptr = r_fq_next3_tail_ptr + 'd3;
			n_fq_next4_tail_ptr = r_fq_next4_tail_ptr + 'd3;
		end
		else if (t_push_insn2) begin
			n_fq_tail_ptr = r_fq_tail_ptr + 'd2;
			n_fq_next_tail_ptr = r_fq_next_tail_ptr + 'd2;
			n_fq_next3_tail_ptr = r_fq_next3_tail_ptr + 'd2;
			n_fq_next4_tail_ptr = r_fq_next4_tail_ptr + 'd2;
		end
		else if (t_push_insn) begin
			n_fq_tail_ptr = r_fq_tail_ptr + 'd1;
			n_fq_next_tail_ptr = r_fq_next_tail_ptr + 'd1;
			n_fq_next3_tail_ptr = r_fq_next3_tail_ptr + 'd1;
			n_fq_next4_tail_ptr = r_fq_next4_tail_ptr + 'd1;
		end
		if (insn_ack && !insn_ack_two) begin
			n_fq_head_ptr = r_fq_head_ptr + 'd1;
			n_fq_next_head_ptr = r_fq_next_head_ptr + 'd1;
		end
		else if (insn_ack && insn_ack_two) begin
			n_fq_head_ptr = r_fq_head_ptr + 'd2;
			n_fq_next_head_ptr = r_fq_next_head_ptr + 'd2;
		end
	end
	always @(posedge clk)
		if (t_push_insn)
			r_fq[r_fq_tail_ptr[2:0]] <= t_insn;
		else if (t_push_insn2) begin
			r_fq[r_fq_tail_ptr[2:0]] <= t_insn;
			r_fq[r_fq_next_tail_ptr[2:0]] <= t_insn2;
		end
		else if (t_push_insn3) begin
			r_fq[r_fq_tail_ptr[2:0]] <= t_insn;
			r_fq[r_fq_next_tail_ptr[2:0]] <= t_insn2;
			r_fq[r_fq_next3_tail_ptr[2:0]] <= t_insn3;
		end
		else if (t_push_insn4) begin
			r_fq[r_fq_tail_ptr[2:0]] <= t_insn;
			r_fq[r_fq_next_tail_ptr[2:0]] <= t_insn2;
			r_fq[r_fq_next3_tail_ptr[2:0]] <= t_insn3;
			r_fq[r_fq_next4_tail_ptr[2:0]] <= t_insn4;
		end
	always @(posedge clk)
		if (reset)
			r_btb_valid <= 'd0;
		else if (restart_valid && restart_src_is_indirect)
			r_btb_valid[restart_src_pc[8:2]] <= 1'b1;
	always @(posedge clk)
		if (restart_valid && restart_src_is_indirect)
			r_btb[restart_src_pc[8:2]] <= restart_pc;
	always @(posedge clk) r_btb_pc <= (reset ? 'd0 : (r_btb_valid[n_cache_pc[8:2]] ? r_btb[n_cache_pc[8:2]] : 'd0));
	mipsseg seg0(
		.v_addr(n_cache_pc),
		.l_addr(w_la_pc),
		.cache(w_cached),
		.mapped(w_mapped),
		.seg(w_seg),
		.in_kernel_mode(in_kernel_mode),
		.in_supervisor_mode(in_supervisor_mode),
		.in_user_mode(in_user_mode),
		.in_64b_kernel_mode(in_64b_kernel_mode),
		.in_64b_supervisor_mode(in_64b_supervisor_mode),
		.in_64b_user_mode(in_64b_user_mode)
	);
	wire [63:0] w_itlb_pa;
	wire w_itlb_hit;
	wire w_itlb_valid;
	tlb #(.ISIDE(1)) itlb(
		.clk(clk),
		.reset(reset),
		.asid(asid),
		.active(w_mapped),
		.req(1'b1),
		.va(w_la_pc),
		.pa(w_itlb_pa),
		.hit(w_itlb_hit),
		.hit_index(),
		.dirty(),
		.valid(w_itlb_valid),
		.tlb_entry_in_valid(tlb_entry_in_valid),
		.tlb_entry_in(tlb_entry_in)
	);
	always @(posedge clk) begin
		r_tlb_pc <= (reset ? 'd0 : w_la_pc);
		r_la_pc <= (reset ? 'd0 : w_la_pc);
		r_cached <= (reset ? 1'b0 : w_cached);
		r_mapped <= (reset ? 1'b0 : w_mapped);
	end
	assign w_tlb_pc = (r_mapped && w_itlb_hit ? w_itlb_pa : r_la_pc);
	wire w_hit = r_tag_out == w_tlb_pc[63:IDX_STOP];
	always @(*) begin
		if (_sv2v_0)
			;
		n_pc = r_pc;
		n_miss_pc = r_miss_pc;
		n_cache_pc = 'd0;
		n_state = r_state;
		n_restart_ack = 1'b0;
		n_flush_req = r_flush_req | flush_req;
		n_flush_complete = 1'b0;
		n_delay_slot = r_delay_slot;
		t_cache_idx = 'd0;
		t_cache_tag = 'd0;
		n_req = 1'b0;
		n_mem_req_valid = 1'b0;
		n_mem_req_addr = r_mem_req_addr;
		n_mem_req_cacheable = r_mem_req_cacheable;
		n_resteer_bubble = 1'b0;
		t_next_spec_rs_tos = r_spec_rs_tos + 'd1;
		n_restart_req = restart_valid | r_restart_req;
		if (r_mapped && !(w_itlb_hit && w_itlb_valid)) begin
			t_miss = 1'b0;
			t_hit = 1'b0;
		end
		else begin
			t_miss = r_req & !(r_valid_out & (r_tag_out == w_tlb_pc[63:IDX_STOP]));
			t_hit = r_req & (r_valid_out & (r_tag_out == w_tlb_pc[63:IDX_STOP]));
		end
		t_insn_idx = r_cache_pc[3:WORD_START];
		t_pd = select_pd(r_jump_out, t_insn_idx);
		t_insn_data = select_cl32(r_array_out, t_insn_idx);
		t_insn_data2 = select_cl32(r_array_out, t_insn_idx + 2'd1);
		t_insn_data3 = select_cl32(r_array_out, t_insn_idx + 2'd2);
		t_insn_data4 = select_cl32(r_array_out, t_insn_idx + 2'd3);
		t_branch_marker = {1'b1, select_pd(r_jump_out, 'd3) != 4'd0, select_pd(r_jump_out, 'd2) != 4'd0, select_pd(r_jump_out, 'd1) != 4'd0, select_pd(r_jump_out, 'd0) != 4'd0} >> t_insn_idx;
		t_spec_branch_marker = ({1'b1, select_pd(r_jump_out, 'd3) != 4'd0, select_pd(r_jump_out, 'd2) != 4'd0, select_pd(r_jump_out, 'd1) != 4'd0, select_pd(r_jump_out, 'd0) != 4'd0} >> t_insn_idx) & {4'b1111, !((t_pd == 4'd1) && !r_pht_out[1])};
		t_first_branch = 'd7;
		casez (t_spec_branch_marker)
			5'bzzzz1: t_first_branch = 'd0;
			5'bzzz10: t_first_branch = 'd1;
			5'bzz100: t_first_branch = 'd2;
			5'bz1000: t_first_branch = 'd3;
			5'b10000: t_first_branch = 'd4;
			default: t_first_branch = 'd7;
		endcase
		t_branch_cnt = (({2'd0, select_pd(r_jump_out, 'd0) != 4'd0} + {2'd0, select_pd(r_jump_out, 'd1) != 4'd0}) + {2'd0, select_pd(r_jump_out, 'd2) != 4'd0}) + {2'd0, select_pd(r_jump_out, 'd3) != 4'd0};
		t_simm = {{SEXT {t_insn_data[15]}}, t_insn_data[15:0]};
		t_clear_fq = 1'b0;
		t_push_insn = 1'b0;
		t_push_insn2 = 1'b0;
		t_push_insn3 = 1'b0;
		t_push_insn4 = 1'b0;
		t_take_br = 1'b0;
		t_is_cflow = 1'b0;
		t_update_spec_hist = 1'b0;
		t_is_call = 1'b0;
		t_is_ret = 1'b0;
		t_init_pht = 1'b0;
		n_init_pht_idx = r_init_pht_idx;
		case (r_state)
			3'd0: n_state = 3'd7;
			3'd7: begin
				t_init_pht = 1'b1;
				n_init_pht_idx = r_init_pht_idx + 'd1;
				if (r_init_pht_idx == 65535) begin
					n_state = 3'd5;
					t_cache_idx = 0;
				end
			end
			3'd1:
				if (n_restart_req) begin
					n_restart_ack = 1'b1;
					n_restart_req = 1'b0;
					n_pc = restart_pc;
					n_state = 3'd2;
					t_clear_fq = 1'b1;
				end
			3'd2: begin
				t_cache_idx = r_pc[11:IDX_START];
				t_cache_tag = r_pc[63:IDX_STOP];
				n_cache_pc = r_pc;
				n_req = 1'b1;
				n_pc = r_pc + 'd4;
				if (r_resteer_bubble)
					;
				else if (n_flush_req) begin
					n_flush_req = 1'b0;
					t_clear_fq = 1'b1;
					n_state = 3'd5;
					t_cache_idx = 0;
				end
				else if (n_restart_req) begin
					n_restart_ack = 1'b1;
					n_restart_req = 1'b0;
					n_delay_slot = 1'b0;
					n_pc = restart_pc;
					n_req = 1'b0;
					n_state = 3'd2;
					t_clear_fq = 1'b1;
				end
				else if ((r_req && (r_cache_pc[1:0] != 2'b00)) && !fq_full) begin
					t_push_insn = 1'b1;
					n_pc = r_cache_pc + 'd4;
				end
				else if ((r_req && (r_cache_pc[1:0] != 2'b00)) && fq_full) begin
					n_pc = r_pc;
					n_miss_pc = r_cache_pc;
					n_state = 3'd6;
				end
				else if (((r_req && r_mapped) && !(w_itlb_hit && w_itlb_valid)) && !fq_full) begin
					t_push_insn = 1'b1;
					n_pc = r_cache_pc + 'd4;
				end
				else if (((r_req && r_mapped) && !(w_itlb_hit && w_itlb_valid)) && fq_full) begin
					n_pc = r_pc;
					n_miss_pc = r_cache_pc;
					n_state = 3'd6;
				end
				else if (t_miss) begin
					n_state = 3'd3;
					n_mem_req_addr = {w_tlb_pc[63:4], {4 {1'b0}}};
					n_mem_req_cacheable = r_cached;
					n_mem_req_valid = 1'b1;
					n_miss_pc = r_cache_pc;
					n_pc = r_pc;
				end
				else if (t_hit && !fq_full) begin
					t_update_spec_hist = t_pd != 4'd0;
					if ((t_pd == 4'd5) || (t_pd == 4'd3)) begin
						t_is_cflow = 1'b1;
						n_delay_slot = 1'b1;
						t_take_br = 1'b1;
						t_is_call = t_pd == 4'd5;
						n_pc = {r_cache_pc[63:28], t_insn_data[25:0], 2'd0};
					end
					else if (t_pd == 4'd8) begin
						t_is_cflow = 1'b1;
						n_delay_slot = 1'b1;
						t_take_br = 1'b1;
						n_pc = (r_cache_pc + 'd4) + {t_simm[61:0], 2'd0};
					end
					else if (t_pd == 4'd2) begin
						t_is_cflow = 1'b1;
						n_delay_slot = 1'b1;
						t_take_br = 1'b1;
						n_pc = (r_cache_pc + 'd4) + {t_simm[61:0], 2'd0};
					end
					else if (t_pd == 4'd9) begin
						if (r_pht_out[1] || (t_insn_data[25:21] == 5'd0)) begin
							t_is_cflow = 1'b1;
							n_delay_slot = 1'b1;
							n_pc = (r_cache_pc + 'd4) + {t_simm[61:0], 2'd0};
							t_is_call = 1'b1;
							t_take_br = 1'b1;
						end
					end
					else if ((t_pd == 4'd1) && r_pht_out[1]) begin
						t_is_cflow = 1'b1;
						n_delay_slot = 1'b1;
						t_take_br = 1'b1;
						n_pc = (r_cache_pc + 'd4) + {t_simm[61:0], 2'd0};
					end
					else if (t_pd == 4'd7) begin
						t_is_cflow = 1'b1;
						t_is_ret = 1'b1;
						n_delay_slot = 1'b1;
						t_take_br = 1'b1;
						n_pc = r_spec_return_stack[t_next_spec_rs_tos * 64+:64];
					end
					else if ((t_pd == 4'd4) || (t_pd == 4'd6)) begin
						t_is_cflow = 1'b1;
						n_delay_slot = 1'b1;
						t_take_br = 1'b1;
						t_is_call = t_pd == 4'd6;
						n_pc = r_btb_pc;
					end
					if (r_delay_slot)
						n_delay_slot = 1'b0;
					if (!(t_is_cflow || r_delay_slot)) begin
						if ((t_first_branch == 'd4) && !fq_full4) begin
							t_push_insn4 = 1'b1;
							t_cache_idx = r_cache_idx + 'd1;
							n_cache_pc = r_cache_pc + 'd16;
							t_cache_tag = n_cache_pc[63:IDX_STOP];
							n_pc = r_cache_pc + 'd20;
						end
						else if ((t_first_branch == 'd3) && !fq_full3) begin
							t_push_insn3 = 1'b1;
							n_cache_pc = r_cache_pc + 'd12;
							n_pc = r_cache_pc + 'd16;
							t_cache_tag = n_cache_pc[63:IDX_STOP];
							if (t_insn_idx != 0)
								t_cache_idx = r_cache_idx + 'd1;
						end
						else if ((t_first_branch == 'd2) && !fq_full2) begin
							t_push_insn2 = 1'b1;
							n_pc = r_cache_pc + 'd8;
							n_cache_pc = r_cache_pc + 'd8;
							t_cache_tag = n_cache_pc[63:IDX_STOP];
							n_pc = r_cache_pc + 'd12;
							if (t_insn_idx == 2)
								t_cache_idx = r_cache_idx + 'd1;
						end
						else
							t_push_insn = 1'b1;
					end
					else
						t_push_insn = 1'b1;
				end
				else if (t_hit && fq_full) begin
					n_pc = r_pc;
					n_miss_pc = r_cache_pc;
					n_state = 3'd6;
				end
			end
			3'd3:
				if (mem_rsp_valid)
					n_state = 3'd4;
			3'd4: begin
				t_cache_idx = r_miss_pc[11:IDX_START];
				t_cache_tag = r_miss_pc[63:IDX_STOP];
				if (n_flush_req) begin
					n_flush_req = 1'b0;
					t_clear_fq = 1'b1;
					n_state = 3'd5;
					t_cache_idx = 0;
				end
				else if (n_restart_req) begin
					n_restart_ack = 1'b1;
					n_restart_req = 1'b0;
					n_delay_slot = 1'b0;
					n_pc = restart_pc;
					n_req = 1'b0;
					n_state = 3'd2;
					t_clear_fq = 1'b1;
				end
				else if (!fq_full) begin
					n_cache_pc = r_miss_pc;
					n_req = 1'b1;
					n_state = 3'd2;
				end
			end
			3'd5: begin
				if (r_cache_idx == 255) begin
					n_flush_complete = 1'b1;
					n_state = 3'd1;
				end
				t_cache_idx = r_cache_idx + 'd1;
			end
			3'd6: begin
				t_cache_idx = r_miss_pc[11:IDX_START];
				t_cache_tag = r_miss_pc[63:IDX_STOP];
				n_cache_pc = r_miss_pc;
				if (!fq_full) begin
					n_req = 1'b1;
					n_state = 3'd2;
				end
				else if (n_flush_req) begin
					n_flush_req = 1'b0;
					t_clear_fq = 1'b1;
					n_state = 3'd5;
					t_cache_idx = 0;
				end
				else if (n_restart_req) begin
					n_restart_ack = 1'b1;
					n_restart_req = 1'b0;
					n_delay_slot = 1'b0;
					n_pc = restart_pc;
					n_req = 1'b0;
					n_state = 3'd2;
					t_clear_fq = 1'b1;
				end
			end
			default:
				;
		endcase
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_cache_accesses = r_cache_accesses;
		n_cache_hits = r_cache_hits;
		if (t_hit)
			n_cache_hits = r_cache_hits + 'd1;
		if (r_req)
			n_cache_accesses = r_cache_accesses + 'd1;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_insn[180-:32] = t_insn_data;
		t_insn[3] = r_req & (r_cache_pc[1:0] != 2'b00);
		t_insn[2] = ((r_mapped & r_req) & !w_itlb_hit) & (r_cache_pc[1:0] == 2'b00);
		t_insn[1] = ((r_mapped & r_req) & w_itlb_hit) & !w_itlb_valid;
		t_insn[148-:64] = r_cache_pc;
		t_insn[84-:64] = n_pc;
		t_insn[20] = t_take_br;
		t_insn[19-:16] = r_pht_idx;
		t_insn[0] = t_pd != 4'd0;
		t_insn2[180-:32] = t_insn_data2;
		t_insn2[3] = 1'b0;
		t_insn2[2] = 1'b0;
		t_insn2[1] = 1'b0;
		t_insn2[148-:64] = r_cache_pc + 'd4;
		t_insn2[84-:64] = 'd0;
		t_insn2[20] = 1'b0;
		t_insn2[19-:16] = 'd0;
		t_insn2[0] = 1'b0;
		t_insn3[180-:32] = t_insn_data3;
		t_insn3[3] = 1'b0;
		t_insn3[2] = 1'b0;
		t_insn3[1] = 1'b0;
		t_insn3[148-:64] = r_cache_pc + 'd8;
		t_insn3[84-:64] = 'd0;
		t_insn3[20] = 1'b0;
		t_insn3[19-:16] = 'd0;
		t_insn3[0] = 1'b0;
		t_insn4[180-:32] = t_insn_data4;
		t_insn4[3] = 1'b0;
		t_insn4[2] = 1'b0;
		t_insn4[1] = 1'b0;
		t_insn4[148-:64] = r_cache_pc + 'd12;
		t_insn4[84-:64] = 'd0;
		t_insn4[20] = 1'b0;
		t_insn4[19-:16] = 'd0;
		t_insn4[0] = 1'b0;
	end
	reg t_wr_valid_ram_en;
	reg t_valid_ram_value;
	reg [7:0] t_valid_ram_idx;
	compute_pht_idx cpi0(
		.pc(n_cache_pc),
		.hist(r_spec_gbl_hist),
		.idx(n_pht_idx)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		t_retire_pht_idx = branch_pht_idx;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_wr_valid_ram_en = mem_rsp_valid || (r_state == 3'd5);
		t_valid_ram_value = r_state != 3'd5;
		t_valid_ram_idx = (mem_rsp_valid ? r_mem_req_addr[11:IDX_START] : r_cache_idx);
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_pht_val = r_pht_update_out;
		t_do_pht_wr = r_pht_update;
		case (r_pht_update_out)
			2'd0:
				if (r_take_br)
					t_pht_val = 2'd1;
				else
					t_do_pht_wr = 1'b0;
			2'd1: t_pht_val = (r_take_br ? 2'd2 : 2'd0);
			2'd2: t_pht_val = (r_take_br ? 2'd3 : 2'd1);
			2'd3:
				if (!r_take_br)
					t_pht_val = 2'd2;
				else
					t_do_pht_wr = 1'b0;
		endcase
	end
	always @(posedge clk)
		if (reset) begin
			r_pht_idx <= 'd0;
			r_last_spec_gbl_hist <= 'd0;
			r_pht_update <= 1'b0;
			r_pht_update_idx <= 'd0;
			r_take_br <= 1'b0;
			r_pd <= 'd0;
		end
		else begin
			r_pht_idx <= n_pht_idx;
			r_last_spec_gbl_hist <= r_spec_gbl_hist;
			r_pht_update <= branch_pc_valid;
			r_pht_update_idx <= t_retire_pht_idx;
			r_take_br <= took_branch;
			r_pd <= t_pd;
		end
	ram2r1w #(
		.WIDTH(2),
		.LG_DEPTH(16)
	) pht(
		.clk(clk),
		.rd_addr0(n_pht_idx),
		.rd_addr1(t_retire_pht_idx),
		.wr_addr((t_init_pht ? r_init_pht_idx : r_pht_update_idx)),
		.wr_data((t_init_pht ? 2'd1 : t_pht_val)),
		.wr_en(t_init_pht || t_do_pht_wr),
		.rd_data0(r_pht_out),
		.rd_data1(r_pht_update_out)
	);
	ram1r1w #(
		.WIDTH(1),
		.LG_DEPTH(8)
	) valid_array(
		.clk(clk),
		.rd_addr(t_cache_idx),
		.wr_addr(t_valid_ram_idx),
		.wr_data(t_valid_ram_value),
		.wr_en(t_wr_valid_ram_en),
		.rd_data(r_valid_out)
	);
	ram1r1w #(
		.WIDTH(N_TAG_BITS),
		.LG_DEPTH(8)
	) tag_array(
		.clk(clk),
		.rd_addr(t_cache_idx),
		.wr_addr(r_mem_req_addr[11:IDX_START]),
		.wr_data(r_mem_req_addr[63:IDX_STOP]),
		.wr_en(mem_rsp_valid),
		.rd_data(r_tag_out)
	);
	function [31:0] bswap32;
		input reg [31:0] in;
		bswap32 = {in[7:0], in[15:8], in[23:16], in[31:24]};
	endfunction
	ram1r1w #(
		.WIDTH(L1I_CL_LEN_BITS),
		.LG_DEPTH(8)
	) insn_array(
		.clk(clk),
		.rd_addr(t_cache_idx),
		.wr_addr(r_mem_req_addr[11:IDX_START]),
		.wr_data({bswap32(mem_rsp_load_data[127:96]), bswap32(mem_rsp_load_data[95:64]), bswap32(mem_rsp_load_data[63:32]), bswap32(mem_rsp_load_data[31:0])}),
		.wr_en(mem_rsp_valid),
		.rd_data(r_array_out)
	);
	wire [3:0] w_pd0;
	wire [3:0] w_pd1;
	wire [3:0] w_pd2;
	wire [3:0] w_pd3;
	predecode pd0(
		.insn_(mem_rsp_load_data[31:0]),
		.pd(w_pd0)
	);
	predecode pd1(
		.insn_(mem_rsp_load_data[63:32]),
		.pd(w_pd1)
	);
	predecode pd2(
		.insn_(mem_rsp_load_data[95:64]),
		.pd(w_pd2)
	);
	predecode pd3(
		.insn_(mem_rsp_load_data[127:96]),
		.pd(w_pd3)
	);
	ram1r1w #(
		.WIDTH(16),
		.LG_DEPTH(8)
	) pd_data(
		.clk(clk),
		.rd_addr(t_cache_idx),
		.wr_addr(r_mem_req_addr[11:IDX_START]),
		.wr_data({w_pd3, w_pd2, w_pd1, w_pd0}),
		.wr_en(mem_rsp_valid),
		.rd_data(r_jump_out)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		n_spec_rs_tos = r_spec_rs_tos;
		if (n_restart_ack)
			n_spec_rs_tos = r_arch_rs_tos;
		else if (t_is_call)
			n_spec_rs_tos = r_spec_rs_tos - 'd1;
		else if (t_is_ret)
			n_spec_rs_tos = r_spec_rs_tos + 'd1;
	end
	always @(posedge clk)
		if (t_is_call)
			r_spec_return_stack[r_spec_rs_tos * 64+:64] <= r_cache_pc + 'd8;
		else if (n_restart_ack)
			r_spec_return_stack <= r_arch_return_stack;
	always @(posedge clk)
		if ((retire_reg_valid && retire_valid) && retired_call)
			r_arch_return_stack[r_arch_rs_tos * 64+:64] <= retire_reg_data;
	always @(*) begin
		if (_sv2v_0)
			;
		n_arch_rs_tos = r_arch_rs_tos;
		if (retire_valid && retired_call)
			n_arch_rs_tos = r_arch_rs_tos - 'd1;
		else if (retire_valid && retired_ret)
			n_arch_rs_tos = r_arch_rs_tos + 'd1;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_spec_gbl_hist = r_spec_gbl_hist;
		if (n_restart_ack)
			n_spec_gbl_hist = n_arch_gbl_hist;
		else if (t_update_spec_hist)
			n_spec_gbl_hist = {r_spec_gbl_hist[62:0], t_take_br};
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_arch_gbl_hist = r_arch_gbl_hist;
		if (branch_pc_valid)
			n_arch_gbl_hist = {r_arch_gbl_hist[62:0], took_branch};
	end
	always @(posedge clk)
		if (reset) begin
			r_state <= 3'd0;
			r_init_pht_idx <= 'd0;
			r_pc <= 'd0;
			r_miss_pc <= 'd0;
			r_cache_pc <= 'd0;
			r_restart_ack <= 1'b0;
			r_cache_idx <= 'd0;
			r_cache_tag <= 'd0;
			r_req <= 1'b0;
			r_mem_req_valid <= 1'b0;
			r_mem_req_addr <= 'd0;
			r_mem_req_cacheable <= 1'b0;
			r_fq_head_ptr <= 'd0;
			r_fq_next_head_ptr <= 'd1;
			r_fq_next_tail_ptr <= 'd1;
			r_fq_next3_tail_ptr <= 'd1;
			r_fq_next4_tail_ptr <= 'd1;
			r_fq_tail_ptr <= 'd0;
			r_restart_req <= 1'b0;
			r_flush_req <= 1'b0;
			r_flush_complete <= 1'b0;
			r_delay_slot <= 1'b0;
			r_spec_rs_tos <= 3;
			r_arch_rs_tos <= 3;
			r_arch_gbl_hist <= 'd0;
			r_spec_gbl_hist <= 'd0;
			r_cache_hits <= 'd0;
			r_cache_accesses <= 'd0;
			r_resteer_bubble <= 1'b0;
		end
		else begin
			r_state <= n_state;
			r_init_pht_idx <= n_init_pht_idx;
			r_pc <= n_pc;
			r_miss_pc <= n_miss_pc;
			r_cache_pc <= n_cache_pc;
			r_restart_ack <= n_restart_ack;
			r_cache_idx <= t_cache_idx;
			r_cache_tag <= t_cache_tag;
			r_req <= n_req;
			r_mem_req_valid <= n_mem_req_valid;
			r_mem_req_addr <= n_mem_req_addr;
			r_mem_req_cacheable <= n_mem_req_cacheable;
			r_fq_head_ptr <= (t_clear_fq ? 'd0 : n_fq_head_ptr);
			r_fq_next_head_ptr <= (t_clear_fq ? 'd1 : n_fq_next_head_ptr);
			r_fq_next_tail_ptr <= (t_clear_fq ? 'd1 : n_fq_next_tail_ptr);
			r_fq_next3_tail_ptr <= (t_clear_fq ? 'd2 : n_fq_next3_tail_ptr);
			r_fq_next4_tail_ptr <= (t_clear_fq ? 'd3 : n_fq_next4_tail_ptr);
			r_fq_tail_ptr <= (t_clear_fq ? 'd0 : n_fq_tail_ptr);
			r_restart_req <= n_restart_req;
			r_flush_req <= n_flush_req;
			r_flush_complete <= n_flush_complete;
			r_delay_slot <= n_delay_slot;
			r_spec_rs_tos <= n_spec_rs_tos;
			r_arch_rs_tos <= n_arch_rs_tos;
			r_arch_gbl_hist <= n_arch_gbl_hist;
			r_spec_gbl_hist <= n_spec_gbl_hist;
			r_cache_hits <= n_cache_hits;
			r_cache_accesses <= n_cache_accesses;
			r_resteer_bubble <= n_resteer_bubble;
		end
	initial _sv2v_0 = 0;
endmodule

module ram2r1w (
	clk,
	rd_addr0,
	rd_addr1,
	wr_addr,
	wr_data,
	wr_en,
	rd_data0,
	rd_data1
);
	input wire clk;
	parameter WIDTH = 1;
	parameter LG_DEPTH = 1;
	input wire [LG_DEPTH - 1:0] rd_addr0;
	input wire [LG_DEPTH - 1:0] rd_addr1;
	input wire [LG_DEPTH - 1:0] wr_addr;
	input wire [WIDTH - 1:0] wr_data;
	input wire wr_en;
	output wire [WIDTH - 1:0] rd_data0;
	output wire [WIDTH - 1:0] rd_data1;
	ram1r1w #(
		.WIDTH(WIDTH),
		.LG_DEPTH(LG_DEPTH)
	) b0(
		.clk(clk),
		.rd_addr(rd_addr0),
		.wr_addr(wr_addr),
		.wr_data(wr_data),
		.wr_en(wr_en),
		.rd_data(rd_data0)
	);
	ram1r1w #(
		.WIDTH(WIDTH),
		.LG_DEPTH(LG_DEPTH)
	) b1(
		.clk(clk),
		.rd_addr(rd_addr1),
		.wr_addr(wr_addr),
		.wr_data(wr_data),
		.wr_en(wr_en),
		.rd_data(rd_data1)
	);
endmodule

module unsigned_divider (
	clk,
	reset,
	srcA,
	srcB,
	start_div,
	y,
	ready,
	complete
);
	reg _sv2v_0;
	parameter LG_W = 5;
	parameter W = 1 << LG_W;
	localparam W2 = 2 * W;
	input wire clk;
	input wire reset;
	input wire [W - 1:0] srcA;
	input wire [W - 1:0] srcB;
	input wire start_div;
	output reg [W - 1:0] y;
	output reg ready;
	output reg complete;
	reg [2:0] r_state;
	reg [2:0] n_state;
	reg [W - 1:0] r_A;
	reg [W - 1:0] n_A;
	reg [W - 1:0] r_B;
	reg [W - 1:0] n_B;
	reg [W - 1:0] r_Y;
	reg [W - 1:0] n_Y;
	reg [W2 - 1:0] r_D;
	reg [W2 - 1:0] n_D;
	reg [W2 - 1:0] r_R;
	reg [W2 - 1:0] n_R;
	wire [W - 1:0] t_ss;
	reg [LG_W - 1:0] r_idx;
	reg [LG_W - 1:0] n_idx;
	reg t_bit;
	reg t_valid;
	reg [31:0] n_bits;
	always @(*) begin
		if (_sv2v_0)
			;
		n_bits = W - 1;
	end
	always @(posedge clk)
		if (reset) begin
			r_state <= 3'd0;
			r_A <= 'd0;
			r_B <= 'd0;
			r_Y <= 'd0;
			r_D <= 'd0;
			r_R <= 'd0;
			r_idx <= 'd0;
		end
		else begin
			r_state <= n_state;
			r_A <= n_A;
			r_B <= n_B;
			r_Y <= n_Y;
			r_D <= n_D;
			r_R <= n_R;
			r_idx <= n_idx;
		end
	shiftregbit #(.W(W)) ss(
		.clk(clk),
		.reset(reset),
		.b(t_bit),
		.valid(t_valid),
		.out(t_ss)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		n_state = r_state;
		n_A = r_A;
		n_B = r_B;
		n_Y = r_Y;
		n_D = r_D;
		n_R = r_R;
		n_idx = r_idx;
		t_bit = 1'b0;
		t_valid = 1'b0;
		ready = r_state == 3'd0;
		y = r_Y;
		complete = 1'b0;
		(* full_case, parallel_case *)
		case (r_state)
			3'd0: begin
				if (start_div)
					n_state = 3'd2;
				n_A = srcA;
				n_B = srcB;
				n_D = {srcB, {W {1'b0}}};
				n_R = {{W {1'b0}}, srcA};
				n_idx = n_bits[LG_W - 1:0];
			end
			3'd2: begin
				if ({r_R[W2 - 2:0], 1'b0} >= r_D) begin
					n_R = {r_R[W2 - 2:0], 1'b0} - r_D;
					t_bit = 1'b1;
					t_valid = 1'b1;
				end
				else begin
					n_R = {r_R[W2 - 2:0], 1'b0};
					t_bit = 1'b0;
					t_valid = 1'b1;
				end
				n_state = (r_idx == 'd0 ? 3'd3 : 3'd2);
				n_idx = r_idx - 'd1;
			end
			3'd3: begin
				n_state = 3'd4;
				n_Y = t_ss;
			end
			3'd4: begin
				complete = 1'b1;
				n_state = 3'd0;
			end
			default:
				;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule

module csa (
	a,
	b,
	cin,
	s,
	cout
);
	parameter N = 64;
	input [N - 1:0] a;
	input [N - 1:0] b;
	input [N - 1:0] cin;
	output wire [N - 1:0] s;
	output wire [N - 1:0] cout;
	wire [N - 1:0] w_xor_ab = a ^ b;
	assign s = w_xor_ab ^ cin;
	assign cout = (a & b) | (cin & w_xor_ab);
endmodule

module find_first_set (
	in,
	y
);
	reg _sv2v_0;
	parameter LG_N = 2;
	localparam N = 1 << LG_N;
	localparam N2 = 1 << (LG_N - 1);
	input wire [N - 1:0] in;
	output reg [LG_N:0] y;
	wire [LG_N - 1:0] t0;
	wire [LG_N - 1:0] t1;
	wire lo_z = in[N2 - 1:0] == 'd0;
	wire hi_z = in[N - 1:N2] == 'd0;
	generate
		if (LG_N == 2) begin : genblk1
			always @(*) begin
				if (_sv2v_0)
					;
				y = 3'b111;
				casez (in)
					4'b0001: y = 3'd0;
					4'b001z: y = 3'd1;
					4'b01zz: y = 3'd2;
					4'b1zzz: y = 3'd3;
					default: y = 3'b111;
				endcase
			end
		end
		else begin : genblk1
			find_first_set #(.LG_N(LG_N - 1)) f0(
				.in(in[N2 - 1:0]),
				.y(t0)
			);
			find_first_set #(.LG_N(LG_N - 1)) f1(
				.in(in[N - 1:N2]),
				.y(t1)
			);
			always @(*) begin
				if (_sv2v_0)
					;
				y = N;
				if (lo_z && hi_z)
					y = N;
				else if (!hi_z)
					y = N2 + t1;
				else if (!lo_z)
					y = {1'b0, t0};
			end
		end
	endgenerate
	initial _sv2v_0 = 0;
endmodule

module exec (
	clk,
	reset,
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
	core_store_data_ptr,
	core_store_data_ptr_valid,
	mem_rsp_dst_ptr,
	mem_rsp_dst_valid,
	mem_rsp_rob_ptr,
	mem_rsp_load_data,
	tlb_entry_out,
	tlb_entry_out_valid,
	irq_pending,
	cp0_count
);
	reg _sv2v_0;
	input wire clk;
	input wire reset;
	input wire retire;
	input wire retire_two;
	input wire [63:0] core_epc;
	input wire core_wr_epc;
	input wire [4:0] core_cause;
	input wire core_wr_cause;
	input wire core_wr_badvaddr;
	input wire [63:0] core_badvaddr;
	output wire [63:0] exec_epc;
	input wire save_to_tlb_regs;
	input wire core_wr_tlbp;
	input wire core_tlbp_hit;
	input wire [5:0] core_tlbp_index;
	output wire [7:0] asid;
	output wire sr_bev;
	output wire sr_exl;
	input wire exc_in_delay;
	output wire in_kernel_mode;
	output wire in_supervisor_mode;
	output wire in_user_mode;
	output wire in_64b_kernel_mode;
	output wire in_64b_supervisor_mode;
	output wire in_64b_user_mode;
	output wire irq_pending;
	output wire [31:0] cp0_count;
	output wire [7:0] putchar_fifo_out;
	output wire putchar_fifo_empty;
	input wire putchar_fifo_pop;
	output wire [3:0] putchar_fifo_wptr;
	output wire [3:0] putchar_fifo_rptr;
	output wire divide_ready;
	input wire ds_done;
	input wire mem_dq_clr;
	input wire restart_complete;
	input wire head_of_rob_ptr_valid;
	input wire [4:0] head_of_rob_ptr;
	output reg [31:0] cpr0_status_reg;
	localparam N_ROB_ENTRIES = 32;
	output wire [31:0] uq_wait;
	output wire [31:0] mq_wait;
	output reg uq_full;
	output reg uq_next_full;
	input wire [198:0] uq_uop;
	input wire [198:0] uq_uop_two;
	input wire uq_push;
	input wire uq_push_two;
	output reg [138:0] complete_bundle_1;
	output reg complete_valid_1;
	output wire [150:0] mem_req;
	output wire mem_req_valid;
	input wire mem_req_ack;
	output wire core_store_data_valid;
	output reg [68:0] core_store_data;
	input wire core_store_data_ack;
	output reg [4:0] core_store_data_ptr;
	output reg core_store_data_ptr_valid;
	input wire [6:0] mem_rsp_dst_ptr;
	input wire mem_rsp_dst_valid;
	input wire [63:0] mem_rsp_load_data;
	input wire [4:0] mem_rsp_rob_ptr;
	output reg [122:0] tlb_entry_out;
	output reg tlb_entry_out_valid;
	reg [122:0] r_shadow_tlb [47:0];
	localparam N_INT_SCHED_ENTRIES = 8;
	localparam N_MQ_ENTRIES = 4;
	localparam N_INT_PRF_ENTRIES = 128;
	localparam N_HILO_PRF_ENTRIES = 4;
	localparam N_UQ_ENTRIES = 8;
	localparam N_MEM_UQ_ENTRIES = 4;
	localparam N_MEM_DQ_ENTRIES = 4;
	reg [127:0] r_hilo_prf [3:0];
	reg [127:0] r_prf_inflight;
	reg [127:0] n_prf_inflight;
	reg [3:0] r_hilo_inflight;
	reg [3:0] n_hilo_inflight;
	reg t_wr_int_prf;
	reg t_wr_cpr0;
	reg t_wr_cpr0_64;
	reg [63:0] t_csr0_val;
	reg [63:0] t_csr0_64_val;
	reg t_wr_hilo;
	reg t_overflow;
	reg t_eret;
	reg t_trap;
	wire t_clr_erl;
	reg t_take_br;
	reg t_mispred_br;
	reg t_alu_valid;
	reg [150:0] r_mem_q [3:0];
	reg [2:0] r_mq_head_ptr;
	reg [2:0] n_mq_head_ptr;
	reg [2:0] r_mq_tail_ptr;
	reg [2:0] n_mq_tail_ptr;
	reg [2:0] r_mq_next_tail_ptr;
	reg [2:0] n_mq_next_tail_ptr;
	reg [150:0] t_mem_tail;
	reg [150:0] t_mem_head;
	reg mem_q_full;
	reg mem_q_next_full;
	reg mem_q_empty;
	reg [68:0] r_mdq [3:0];
	wire [68:0] t_mdq_tail;
	wire [68:0] t_mdq_head;
	reg [2:0] r_mdq_head_ptr;
	reg [2:0] n_mdq_head_ptr;
	reg [2:0] r_mdq_tail_ptr;
	reg [2:0] n_mdq_tail_ptr;
	reg [2:0] r_mdq_next_tail_ptr;
	reg [2:0] n_mdq_next_tail_ptr;
	reg mem_mdq_full;
	reg mem_mdq_next_full;
	reg mem_mdq_empty;
	reg [3:0] r_rd_pc_idx;
	reg [3:0] n_rd_pc_idx;
	reg [3:0] r_wr_pc_idx;
	reg [3:0] n_wr_pc_idx;
	reg [7:0] r_pc_buf [7:0];
	reg t_push_putchar;
	reg t_pop_uq;
	reg t_pop_mem_uq;
	reg t_pop_mem_dq;
	reg r_mem_ready;
	reg r_dq_ready;
	localparam E_BITS = 48;
	localparam HI_EBITS = 32;
	reg [63:0] t_simm;
	reg [63:0] t_mem_simm;
	reg [63:0] t_result;
	reg [63:0] t_cpr0_result;
	reg [127:0] t_hilo_result;
	reg [63:0] t_pc;
	reg [63:0] t_pc4;
	reg [63:0] t_pc8;
	reg [27:0] t_jaddr;
	wire t_srcs_rdy;
	wire [63:0] w_srcA;
	wire [63:0] w_srcB;
	wire [63:0] w_mem_srcA;
	wire [63:0] w_mem_srcB;
	reg [63:0] r_mem_result;
	reg [63:0] r_int_result;
	reg r_fwd_int_srcA;
	reg r_fwd_int_srcB;
	reg r_fwd_mem_srcA;
	reg r_fwd_mem_srcB;
	reg t_fwd_int_mem_srcA;
	reg t_fwd_int_mem_srcB;
	reg t_fwd_mem_mem_srcA;
	reg t_fwd_mem_mem_srcB;
	reg r_fwd_int_mem_srcA;
	reg r_fwd_int_mem_srcB;
	reg r_fwd_mem_mem_srcA;
	reg r_fwd_mem_mem_srcB;
	reg [127:0] r_int_hilo;
	reg [127:0] r_mul_hilo;
	reg [127:0] r_div_hilo;
	reg [127:0] r_src_hilo;
	reg r_fwd_hilo_int;
	reg r_fwd_hilo_mul;
	reg r_fwd_hilo_div;
	reg [63:0] t_srcA;
	reg [63:0] t_srcB;
	reg [63:0] t_mem_srcA;
	reg [63:0] t_mem_srcB;
	reg [127:0] t_src_hilo;
	wire [63:0] t_cpr0_srcA;
	reg t_unimp_op;
	reg t_fault;
	reg t_signed_shift;
	reg [5:0] t_shift_amt;
	wire [31:0] t_shift_right;
	reg t_start_mul;
	wire t_mul_complete;
	wire [127:0] t_mul_result;
	wire t_hilo_prf_ptr_val_out;
	wire [4:0] t_rob_ptr_out;
	wire [1:0] t_hilo_prf_ptr_out;
	reg [65:0] r_wb_bitvec;
	reg [65:0] n_wb_bitvec;
	wire t_div_ready;
	reg t_signed_div;
	reg t_start_div32;
	reg t_start_div64;
	wire [4:0] t_div_rob_ptr_out;
	wire [127:0] t_div_result;
	wire [1:0] t_div_hilo_prf_ptr_out;
	wire t_div_complete;
	reg [31:0] r_uq_wait;
	reg [31:0] r_mq_wait;
	reg [198:0] r_uq [0:7];
	reg [198:0] uq;
	reg [198:0] int_uop;
	reg r_start_int;
	wire t_uq_read;
	reg t_uq_empty;
	reg t_uq_full;
	reg t_uq_next_full;
	reg [3:0] r_uq_head_ptr;
	reg [3:0] n_uq_head_ptr;
	reg [3:0] r_uq_tail_ptr;
	reg [3:0] n_uq_tail_ptr;
	reg [3:0] r_uq_next_head_ptr;
	reg [3:0] n_uq_next_head_ptr;
	reg [3:0] r_uq_next_tail_ptr;
	reg [3:0] n_uq_next_tail_ptr;
	reg [198:0] r_mem_uq [0:3];
	reg [198:0] t_mem_uq;
	reg [198:0] mem_uq;
	wire t_mem_uq_read;
	reg t_mem_uq_empty;
	reg t_mem_uq_full;
	reg t_mem_uq_next_full;
	reg [2:0] r_mem_uq_head_ptr;
	reg [2:0] n_mem_uq_head_ptr;
	reg [2:0] r_mem_uq_tail_ptr;
	reg [2:0] n_mem_uq_tail_ptr;
	reg [2:0] r_mem_uq_next_head_ptr;
	reg [2:0] n_mem_uq_next_head_ptr;
	reg [2:0] r_mem_uq_next_tail_ptr;
	reg [2:0] n_mem_uq_next_tail_ptr;
	reg [11:0] r_mem_dq [0:3];
	reg [11:0] t_dq0;
	reg [11:0] t_dq1;
	reg [11:0] t_mem_dq;
	reg [11:0] mem_dq;
	reg [68:0] t_core_store_data;
	wire t_mem_dq_read;
	reg t_mem_dq_empty;
	reg t_mem_dq_full;
	reg t_mem_dq_next_full;
	reg [2:0] r_mem_dq_head_ptr;
	reg [2:0] n_mem_dq_head_ptr;
	reg [2:0] r_mem_dq_tail_ptr;
	reg [2:0] n_mem_dq_tail_ptr;
	reg [2:0] r_mem_dq_next_head_ptr;
	reg [2:0] n_mem_dq_next_head_ptr;
	reg [2:0] r_mem_dq_next_tail_ptr;
	reg [2:0] n_mem_dq_next_tail_ptr;
	reg t_push_two_mem;
	reg t_push_two_int;
	reg t_push_one_mem;
	reg t_push_one_int;
	reg t_push_two_dq;
	reg t_push_one_dq;
	reg t_flash_clear;
	always @(*) begin
		if (_sv2v_0)
			;
		t_flash_clear = ds_done;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		uq_full = (t_uq_full || t_mem_uq_full) || t_mem_dq_full;
		uq_next_full = (t_uq_next_full || t_mem_uq_next_full) || t_mem_dq_next_full;
	end
	always @(posedge clk)
		if (reset || t_flash_clear) begin
			r_uq_head_ptr <= 'd0;
			r_uq_tail_ptr <= 'd0;
			r_uq_next_head_ptr <= 'd1;
			r_uq_next_tail_ptr <= 'd1;
		end
		else begin
			r_uq_head_ptr <= n_uq_head_ptr;
			r_uq_tail_ptr <= n_uq_tail_ptr;
			r_uq_next_head_ptr <= n_uq_next_head_ptr;
			r_uq_next_tail_ptr <= n_uq_next_tail_ptr;
		end
	always @(posedge clk)
		if (reset || t_flash_clear) begin
			r_mem_uq_head_ptr <= 'd0;
			r_mem_uq_tail_ptr <= 'd0;
			r_mem_uq_next_head_ptr <= 'd1;
			r_mem_uq_next_tail_ptr <= 'd1;
		end
		else begin
			r_mem_uq_head_ptr <= n_mem_uq_head_ptr;
			r_mem_uq_tail_ptr <= n_mem_uq_tail_ptr;
			r_mem_uq_next_head_ptr <= n_mem_uq_next_head_ptr;
			r_mem_uq_next_tail_ptr <= n_mem_uq_next_tail_ptr;
		end
	always @(posedge clk)
		if (reset || mem_dq_clr) begin
			r_mem_dq_head_ptr <= 'd0;
			r_mem_dq_tail_ptr <= 'd0;
			r_mem_dq_next_head_ptr <= 'd1;
			r_mem_dq_next_tail_ptr <= 'd1;
		end
		else begin
			r_mem_dq_head_ptr <= n_mem_dq_head_ptr;
			r_mem_dq_tail_ptr <= n_mem_dq_tail_ptr;
			r_mem_dq_next_head_ptr <= n_mem_dq_next_head_ptr;
			r_mem_dq_next_tail_ptr <= n_mem_dq_next_tail_ptr;
		end
	always @(*) begin
		if (_sv2v_0)
			;
		n_mem_uq_head_ptr = r_mem_uq_head_ptr;
		n_mem_uq_tail_ptr = r_mem_uq_tail_ptr;
		n_mem_uq_next_head_ptr = r_mem_uq_next_head_ptr;
		n_mem_uq_next_tail_ptr = r_mem_uq_next_tail_ptr;
		n_mem_dq_head_ptr = r_mem_dq_head_ptr;
		n_mem_dq_tail_ptr = r_mem_dq_tail_ptr;
		n_mem_dq_next_head_ptr = r_mem_dq_next_head_ptr;
		n_mem_dq_next_tail_ptr = r_mem_dq_next_tail_ptr;
		t_mem_uq_empty = r_mem_uq_head_ptr == r_mem_uq_tail_ptr;
		t_mem_uq_full = (r_mem_uq_head_ptr != r_mem_uq_tail_ptr) && (r_mem_uq_head_ptr[1:0] == r_mem_uq_tail_ptr[1:0]);
		t_mem_uq_next_full = (r_mem_uq_head_ptr != r_mem_uq_next_tail_ptr) && (r_mem_uq_head_ptr[1:0] == r_mem_uq_next_tail_ptr[1:0]);
		t_mem_dq_empty = r_mem_dq_head_ptr == r_mem_dq_tail_ptr;
		t_mem_dq_full = (r_mem_dq_head_ptr != r_mem_dq_tail_ptr) && (r_mem_dq_head_ptr[1:0] == r_mem_dq_tail_ptr[1:0]);
		t_mem_dq_next_full = (r_mem_dq_head_ptr != r_mem_dq_next_tail_ptr) && (r_mem_dq_head_ptr[1:0] == r_mem_dq_next_tail_ptr[1:0]);
		t_mem_uq = r_mem_uq[r_mem_uq_head_ptr[1:0]];
		t_mem_dq = r_mem_dq[r_mem_dq_head_ptr[1:0]];
		t_push_two_mem = ((uq_push && uq_push_two) && uq_uop[17]) && uq_uop_two[17];
		t_push_one_mem = ((uq_push && uq_uop[17]) || (uq_push_two && uq_uop_two[17])) && !t_push_two_mem;
		t_push_two_dq = ((((uq_push && uq_push_two) && uq_uop[17]) && uq_uop[175]) && uq_uop_two[17]) && uq_uop_two[175];
		t_push_one_dq = ((uq_push_two && uq_uop_two[17]) && uq_uop_two[175]) || ((uq_push && uq_uop[17]) && uq_uop[175]);
		if (t_push_two_dq) begin
			n_mem_dq_tail_ptr = r_mem_dq_tail_ptr + 'd2;
			n_mem_dq_next_tail_ptr = r_mem_dq_next_tail_ptr + 'd2;
		end
		else if (t_push_one_dq) begin
			n_mem_dq_tail_ptr = r_mem_dq_tail_ptr + 'd1;
			n_mem_dq_next_tail_ptr = r_mem_dq_next_tail_ptr + 'd1;
		end
		if (t_push_two_mem) begin
			n_mem_uq_tail_ptr = r_mem_uq_tail_ptr + 'd2;
			n_mem_uq_next_tail_ptr = r_mem_uq_next_tail_ptr + 'd2;
		end
		else if ((uq_push_two && uq_uop_two[17]) || (uq_push && uq_uop[17])) begin
			n_mem_uq_tail_ptr = r_mem_uq_tail_ptr + 'd1;
			n_mem_uq_next_tail_ptr = r_mem_uq_next_tail_ptr + 'd1;
		end
		if (t_pop_mem_uq)
			n_mem_uq_head_ptr = r_mem_uq_head_ptr + 'd1;
		if (t_pop_mem_dq)
			n_mem_dq_head_ptr = r_mem_dq_head_ptr + 'd1;
	end
	always @(posedge clk) begin
		mem_uq <= t_mem_uq;
		mem_dq <= t_mem_dq;
	end
	always @(posedge clk)
		if (reset) begin
			r_mq_wait <= 'd0;
			r_uq_wait <= 'd0;
		end
		else if (restart_complete) begin
			r_mq_wait <= 'd0;
			r_uq_wait <= 'd0;
		end
		else begin
			if (t_push_two_mem) begin
				r_mq_wait[uq_uop_two[28-:5]] <= 1'b1;
				r_mq_wait[uq_uop[28-:5]] <= 1'b1;
			end
			else if (t_push_one_mem)
				r_mq_wait[(uq_uop[17] ? uq_uop[28-:5] : uq_uop_two[28-:5])] <= 1'b1;
			if (t_pop_mem_uq)
				r_mq_wait[t_mem_uq[28-:5]] <= 1'b0;
			if (t_push_two_int) begin
				r_uq_wait[uq_uop[28-:5]] <= 1'b1;
				r_uq_wait[uq_uop_two[28-:5]] <= 1'b1;
			end
			else if (t_push_one_int)
				r_uq_wait[(uq_uop[19] ? uq_uop[28-:5] : uq_uop_two[28-:5])] <= 1'b1;
			if (r_start_int)
				r_uq_wait[int_uop[28-:5]] <= 1'b0;
		end
	always @(posedge clk)
		if (t_push_two_mem) begin
			r_mem_uq[r_mem_uq_next_tail_ptr[1:0]] <= uq_uop_two;
			r_mem_uq[r_mem_uq_tail_ptr[1:0]] <= uq_uop;
		end
		else if (t_push_one_mem)
			r_mem_uq[r_mem_uq_tail_ptr[1:0]] <= (uq_uop[17] ? uq_uop : uq_uop_two);
	always @(*) begin
		if (_sv2v_0)
			;
		t_dq0[11-:5] = uq_uop[28-:5];
		t_dq0[6-:7] = uq_uop[182-:7];
		t_dq1[11-:5] = uq_uop_two[28-:5];
		t_dq1[6-:7] = uq_uop_two[182-:7];
	end
	always @(posedge clk)
		if (t_push_two_dq) begin
			r_mem_dq[r_mem_dq_next_tail_ptr[1:0]] <= t_dq1;
			r_mem_dq[r_mem_dq_tail_ptr[1:0]] <= t_dq0;
		end
		else if (t_push_one_dq)
			r_mem_dq[r_mem_dq_tail_ptr[1:0]] <= (uq_uop[17] && uq_uop[175] ? t_dq0 : t_dq1);
	always @(*) begin
		if (_sv2v_0)
			;
		n_uq_head_ptr = r_uq_head_ptr;
		n_uq_tail_ptr = r_uq_tail_ptr;
		n_uq_next_head_ptr = r_uq_next_head_ptr;
		n_uq_next_tail_ptr = r_uq_next_tail_ptr;
		t_uq_empty = r_uq_head_ptr == r_uq_tail_ptr;
		t_uq_full = (r_uq_head_ptr != r_uq_tail_ptr) && (r_uq_head_ptr[2:0] == r_uq_tail_ptr[2:0]);
		t_uq_next_full = (r_uq_head_ptr != r_uq_next_tail_ptr) && (r_uq_head_ptr[2:0] == r_uq_next_tail_ptr[2:0]);
		t_push_two_int = ((uq_push && uq_push_two) && uq_uop[19]) && uq_uop_two[19];
		t_push_one_int = ((uq_push && uq_uop[19]) || (uq_push_two && uq_uop_two[19])) && !t_push_two_int;
		uq = r_uq[r_uq_head_ptr[2:0]];
		if (t_push_two_int) begin
			n_uq_tail_ptr = r_uq_tail_ptr + 'd2;
			n_uq_next_tail_ptr = r_uq_next_tail_ptr + 'd2;
		end
		else if ((uq_push_two && uq_uop_two[19]) || (uq_push && uq_uop[19])) begin
			n_uq_tail_ptr = r_uq_tail_ptr + 'd1;
			n_uq_next_tail_ptr = r_uq_next_tail_ptr + 'd1;
		end
		if (t_pop_uq)
			n_uq_head_ptr = r_uq_head_ptr + 'd1;
	end
	always @(posedge clk)
		if (t_push_two_int) begin
			r_uq[r_uq_tail_ptr[2:0]] <= uq_uop;
			r_uq[r_uq_next_tail_ptr[2:0]] <= uq_uop_two;
		end
		else if (t_push_one_int)
			r_uq[r_uq_tail_ptr[2:0]] <= (uq_uop[19] ? uq_uop : uq_uop_two);
	reg [31:0] r_cycle;
	reg [31:0] r_retired_insns;
	always @(posedge clk) r_cycle <= (reset ? 'd0 : r_cycle + 'd1);
	always @(posedge clk)
		if (reset)
			r_retired_insns <= 'd0;
		else if (retire_two)
			r_retired_insns <= r_retired_insns + 'd2;
		else if (retire)
			r_retired_insns <= r_retired_insns + 'd1;
	always @(posedge clk)
		if (reset)
			r_wb_bitvec <= 'd0;
		else
			r_wb_bitvec <= n_wb_bitvec;
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			integer i;
			for (i = 64; i > -1; i = i - 1)
				n_wb_bitvec[i] = r_wb_bitvec[i + 1];
		end
		n_wb_bitvec[65] = (t_start_div32 | t_start_div64) & r_start_int;
		if (t_start_mul & r_start_int)
			n_wb_bitvec[3] = 1'b1;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_srcA = (r_fwd_int_srcA ? r_int_result : (r_fwd_mem_srcA ? r_mem_result : w_srcA));
		t_srcB = (r_fwd_int_srcB ? r_int_result : (r_fwd_mem_srcB ? r_mem_result : w_srcB));
		t_mem_srcA = (r_fwd_int_mem_srcA ? r_int_result : (r_fwd_mem_mem_srcA ? r_mem_result : w_mem_srcA));
		t_mem_srcB = (r_fwd_int_mem_srcB ? r_int_result : (r_fwd_mem_mem_srcB ? r_mem_result : w_mem_srcB));
		t_src_hilo = (r_fwd_hilo_int ? r_int_hilo : (r_fwd_hilo_mul ? r_mul_hilo : (r_fwd_hilo_div ? r_div_hilo : r_src_hilo)));
	end
	reg [7:0] r_alu_sched_valid;
	wire [3:0] t_alu_sched_alloc_ptr;
	reg t_alu_sched_full;
	reg [7:0] t_alu_alloc_entry;
	reg [7:0] t_alu_select_entry;
	reg [198:0] r_alu_sched_uops [7:0];
	reg [198:0] t_picked_uop;
	reg [7:0] t_alu_entry_rdy;
	wire [3:0] t_alu_sched_select_ptr;
	reg [7:0] r_alu_srcA_rdy;
	reg [7:0] r_alu_srcB_rdy;
	reg [7:0] r_alu_hilo_rdy;
	reg [7:0] t_alu_srcA_match;
	reg [7:0] t_alu_srcB_match;
	reg [7:0] t_alu_hilo_match;
	reg t_alu_alloc_srcA_match;
	reg t_alu_alloc_srcB_match;
	reg t_alu_alloc_hilo_match;
	wire [7:0] w_alu_sched_oldest_ready;
	find_first_set #(3) ffs_int_sched_alloc(
		.in(~r_alu_sched_valid),
		.y(t_alu_sched_alloc_ptr)
	);
	find_first_set #(3) ffs_int_sched_select(
		.in(w_alu_sched_oldest_ready),
		.y(t_alu_sched_select_ptr)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		t_alu_alloc_entry = 'd0;
		t_alu_select_entry = 'd0;
		if (t_pop_uq)
			t_alu_alloc_entry[t_alu_sched_alloc_ptr[2:0]] = 1'b1;
		if (t_alu_entry_rdy != 'd0)
			t_alu_select_entry[t_alu_sched_select_ptr[2:0]] = 1'b1;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_picked_uop = r_alu_sched_uops[t_alu_sched_select_ptr[2:0]];
	end
	always @(posedge clk) int_uop <= t_picked_uop;
	always @(posedge clk) r_start_int <= (reset ? 1'b0 : (t_alu_entry_rdy != 'd0) & !ds_done);
	always @(*) begin
		if (_sv2v_0)
			;
		t_alu_alloc_srcA_match = uq[184] && ((mem_rsp_dst_valid & (mem_rsp_dst_ptr == uq[191-:7])) || (r_start_int && (t_wr_int_prf & (int_uop[173-:7] == uq[191-:7]))));
		t_alu_alloc_srcB_match = uq[175] && ((mem_rsp_dst_valid & (mem_rsp_dst_ptr == uq[182-:7])) || (r_start_int && (t_wr_int_prf & (int_uop[173-:7] == uq[182-:7]))));
		t_alu_alloc_hilo_match = uq[161] && (((t_hilo_prf_ptr_val_out & (t_hilo_prf_ptr_out == uq[160-:2])) || (t_div_complete && (t_div_hilo_prf_ptr_out == uq[160-:2]))) || ((r_start_int && t_wr_hilo) && (int_uop[163-:2] == uq[160-:2])));
	end
	reg [7:0] t_alu_sched_mask_valid;
	reg [7:0] r_alu_sched_matrix [7:0];
	always @(*) begin
		if (_sv2v_0)
			;
		t_alu_sched_mask_valid = r_alu_sched_valid & ~t_alu_select_entry;
	end
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < N_INT_SCHED_ENTRIES; _gv_i_1 = _gv_i_1 + 1) begin : genblk1
			localparam i = _gv_i_1;
			assign w_alu_sched_oldest_ready[i] = t_alu_entry_rdy[i] & ~(|(t_alu_entry_rdy & r_alu_sched_matrix[i]));
			always @(posedge clk)
				if (reset || t_flash_clear)
					r_alu_sched_matrix[i] <= 'd0;
				else if (t_alu_alloc_entry[i])
					r_alu_sched_matrix[i] <= t_alu_sched_mask_valid;
				else if (t_alu_entry_rdy != 'd0)
					r_alu_sched_matrix[i] <= r_alu_sched_matrix[i] & ~t_alu_select_entry;
		end
	endgenerate
	genvar _gv_i_2;
	function is_div;
		input reg [6:0] op;
		reg x;
		begin
			case (op)
				7'd12: x = 1'b1;
				7'd13: x = 1'b1;
				7'd104: x = 1'b1;
				7'd105: x = 1'b1;
				default: x = 1'b0;
			endcase
			is_div = x;
		end
	endfunction
	function is_mult;
		input reg [6:0] op;
		reg x;
		begin
			case (op)
				7'd10: x = 1'b1;
				7'd11: x = 1'b1;
				7'd102: x = 1'b1;
				7'd103: x = 1'b1;
				default: x = 1'b0;
			endcase
			is_mult = x;
		end
	endfunction
	generate
		for (_gv_i_2 = 0; _gv_i_2 < N_INT_SCHED_ENTRIES; _gv_i_2 = _gv_i_2 + 1) begin : genblk2
			localparam i = _gv_i_2;
			always @(*) begin
				if (_sv2v_0)
					;
				t_alu_srcA_match[i] = r_alu_sched_uops[i][184] && ((mem_rsp_dst_valid & (mem_rsp_dst_ptr == r_alu_sched_uops[i][191-:7])) || (r_start_int && (t_wr_int_prf & (int_uop[173-:7] == r_alu_sched_uops[i][191-:7]))));
				t_alu_srcB_match[i] = r_alu_sched_uops[i][175] && ((mem_rsp_dst_valid & (mem_rsp_dst_ptr == r_alu_sched_uops[i][182-:7])) || (r_start_int && (t_wr_int_prf & (int_uop[173-:7] == r_alu_sched_uops[i][182-:7]))));
				t_alu_hilo_match[i] = r_alu_sched_uops[i][161] && (((t_hilo_prf_ptr_val_out & (t_hilo_prf_ptr_out == r_alu_sched_uops[i][160-:2])) || (t_div_complete && (t_div_hilo_prf_ptr_out == r_alu_sched_uops[i][160-:2]))) || ((r_start_int && t_wr_hilo) && (int_uop[163-:2] == r_alu_sched_uops[i][160-:2])));
				t_alu_entry_rdy[i] = (r_alu_sched_valid[i] && (is_div(r_alu_sched_uops[i][198-:7]) ? t_div_ready : (is_mult(r_alu_sched_uops[i][198-:7]) ? !r_wb_bitvec[5] : !r_wb_bitvec[1])) ? (((t_alu_srcA_match[i] | r_alu_srcA_rdy[i]) & (t_alu_srcB_match[i] | r_alu_srcB_rdy[i])) & (t_alu_hilo_match[i] | r_alu_hilo_rdy[i])) & (!r_alu_sched_uops[i][21] || (head_of_rob_ptr_valid && (r_alu_sched_uops[i][28-:5] == head_of_rob_ptr))) : 1'b0);
			end
			always @(posedge clk)
				if (reset) begin
					r_alu_srcA_rdy[i] <= 1'b0;
					r_alu_srcB_rdy[i] <= 1'b0;
					r_alu_hilo_rdy[i] <= 1'b0;
				end
				else if (t_alu_alloc_entry[i]) begin
					r_alu_srcA_rdy[i] <= (uq[184] ? !r_prf_inflight[uq[191-:7]] | t_alu_alloc_srcA_match : 1'b1);
					r_alu_srcB_rdy[i] <= (uq[175] ? !r_prf_inflight[uq[182-:7]] | t_alu_alloc_srcB_match : 1'b1);
					r_alu_hilo_rdy[i] <= (uq[161] ? !r_hilo_inflight[uq[160-:2]] | t_alu_alloc_hilo_match : 1'b1);
				end
				else if (t_alu_select_entry[i]) begin
					r_alu_srcA_rdy[i] <= 1'b0;
					r_alu_srcB_rdy[i] <= 1'b0;
					r_alu_hilo_rdy[i] <= 1'b0;
				end
				else if (r_alu_sched_valid[i]) begin
					r_alu_srcA_rdy[i] <= r_alu_srcA_rdy[i] | t_alu_srcA_match[i];
					r_alu_srcB_rdy[i] <= r_alu_srcB_rdy[i] | t_alu_srcB_match[i];
					r_alu_hilo_rdy[i] <= r_alu_hilo_rdy[i] | t_alu_hilo_match[i];
				end
		end
	endgenerate
	always @(*) begin
		if (_sv2v_0)
			;
		t_pop_uq = 1'b0;
		t_alu_sched_full = &r_alu_sched_valid;
		t_pop_uq = !((t_flash_clear || t_uq_empty) || t_alu_sched_full);
	end
	always @(posedge clk)
		if (reset || t_flash_clear)
			r_alu_sched_valid <= 'd0;
		else begin
			if (t_pop_uq) begin
				r_alu_sched_valid[t_alu_sched_alloc_ptr[2:0]] <= 1'b1;
				r_alu_sched_uops[t_alu_sched_alloc_ptr[2:0]] <= uq;
			end
			if (t_alu_entry_rdy != 'd0)
				r_alu_sched_valid[t_alu_sched_select_ptr[2:0]] <= 1'b0;
		end
	reg t_32b_shift;
	reg t_shift_left;
	wire [63:0] w_shifter_out;
	generate
		if (1) begin : genblk3
			wire [63:0] w_shift_src = (t_32b_shift ? {{32 {(t_signed_shift ? t_srcA[31] : 1'b0)}}, t_srcA[31:0]} : t_srcA);
			shift_right #(.LG_W(6)) s0(
				.is_left(t_shift_left),
				.is_signed(t_signed_shift),
				.is_circular(1'b0),
				.data(w_shift_src),
				.distance(t_shift_amt),
				.y(w_shifter_out)
			);
		end
	endgenerate
	mul #(.W(64)) m(
		.clk(clk),
		.reset(reset),
		.is_signed((int_uop[198-:7] != 7'd11) && (int_uop[198-:7] != 7'd103)),
		.go(t_start_mul & r_start_int),
		.is_32b((int_uop[198-:7] == 7'd10) || (int_uop[198-:7] == 7'd11)),
		.src_A(t_srcA),
		.src_B(t_srcB),
		.rob_ptr_in(int_uop[28-:5]),
		.hilo_prf_ptr_in(int_uop[163-:2]),
		.y(t_mul_result),
		.complete(t_mul_complete),
		.rob_ptr_out(t_rob_ptr_out),
		.hilo_prf_ptr_val_out(t_hilo_prf_ptr_val_out),
		.hilo_prf_ptr_out(t_hilo_prf_ptr_out)
	);
	divider #(.LG_W(6)) d0(
		.clk(clk),
		.reset(reset),
		.is_32b(t_start_div32),
		.srcA(t_srcA),
		.srcB(t_srcB),
		.rob_ptr_in(int_uop[28-:5]),
		.hilo_prf_ptr_in(int_uop[163-:2]),
		.is_signed_div(t_signed_div),
		.start_div(t_start_div32 | t_start_div64),
		.y(t_div_result),
		.rob_ptr_out(t_div_rob_ptr_out),
		.hilo_prf_ptr_out(t_div_hilo_prf_ptr_out),
		.complete(t_div_complete),
		.ready(t_div_ready)
	);
	assign divide_ready = t_div_ready;
	always @(*) begin
		if (_sv2v_0)
			;
		n_mq_head_ptr = r_mq_head_ptr;
		n_mq_tail_ptr = r_mq_tail_ptr;
		n_mq_next_tail_ptr = r_mq_next_tail_ptr;
		if (r_mem_ready) begin
			n_mq_tail_ptr = r_mq_tail_ptr + 'd1;
			n_mq_next_tail_ptr = r_mq_next_tail_ptr + 'd1;
		end
		if (mem_req_ack)
			n_mq_head_ptr = r_mq_head_ptr + 'd1;
		t_mem_head = r_mem_q[r_mq_head_ptr[1:0]];
		mem_q_empty = r_mq_head_ptr == r_mq_tail_ptr;
		mem_q_full = (r_mq_head_ptr != r_mq_tail_ptr) && (r_mq_head_ptr[1:0] == r_mq_tail_ptr[1:0]);
		mem_q_next_full = (r_mq_head_ptr != r_mq_next_tail_ptr) && (r_mq_head_ptr[1:0] == r_mq_next_tail_ptr[1:0]);
	end
	always @(posedge clk)
		if (r_mem_ready)
			r_mem_q[r_mq_tail_ptr[1:0]] <= t_mem_tail;
	always @(*) begin
		if (_sv2v_0)
			;
		n_mdq_head_ptr = r_mdq_head_ptr;
		n_mdq_tail_ptr = r_mdq_tail_ptr;
		n_mdq_next_tail_ptr = r_mdq_next_tail_ptr;
		if (r_dq_ready) begin
			n_mdq_tail_ptr = r_mdq_tail_ptr + 'd1;
			n_mdq_next_tail_ptr = r_mdq_next_tail_ptr + 'd1;
		end
		if (core_store_data_ack)
			n_mdq_head_ptr = r_mdq_head_ptr + 'd1;
		core_store_data = r_mdq[r_mdq_head_ptr[1:0]];
		mem_mdq_empty = r_mdq_head_ptr == r_mdq_tail_ptr;
		mem_mdq_full = (r_mdq_head_ptr != r_mdq_tail_ptr) && (r_mdq_head_ptr[1:0] == r_mdq_tail_ptr[1:0]);
		mem_mdq_next_full = (r_mdq_head_ptr != r_mdq_next_tail_ptr) && (r_mdq_head_ptr[1:0] == r_mdq_next_tail_ptr[1:0]);
	end
	assign mem_req = t_mem_head;
	assign mem_req_valid = !mem_q_empty;
	assign uq_wait = r_uq_wait;
	assign mq_wait = r_mq_wait;
	assign core_store_data_valid = !mem_mdq_empty;
	always @(posedge clk) begin
		r_mq_head_ptr <= (reset ? 'd0 : n_mq_head_ptr);
		r_mq_tail_ptr <= (reset ? 'd0 : n_mq_tail_ptr);
		r_mq_next_tail_ptr <= (reset ? 'd1 : n_mq_next_tail_ptr);
		r_mdq_head_ptr <= (reset || mem_dq_clr ? 'd0 : n_mdq_head_ptr);
		r_mdq_tail_ptr <= (reset || mem_dq_clr ? 'd0 : n_mdq_tail_ptr);
		r_mdq_next_tail_ptr <= (reset || mem_dq_clr ? 'd1 : n_mdq_next_tail_ptr);
	end
	always @(posedge clk)
		if (reset) begin
			r_prf_inflight <= 'd0;
			r_hilo_inflight <= 'd0;
		end
		else begin
			r_prf_inflight <= (ds_done ? 'd0 : n_prf_inflight);
			r_hilo_inflight <= (ds_done ? 'd0 : n_hilo_inflight);
		end
	always @(*) begin
		if (_sv2v_0)
			;
		n_prf_inflight = r_prf_inflight;
		if (uq_push && uq_uop[166])
			n_prf_inflight[uq_uop[173-:7]] = 1'b1;
		if (uq_push_two && uq_uop_two[166])
			n_prf_inflight[uq_uop_two[173-:7]] = 1'b1;
		if (mem_rsp_dst_valid)
			n_prf_inflight[mem_rsp_dst_ptr] = 1'b0;
		if (r_start_int && t_wr_int_prf)
			n_prf_inflight[int_uop[173-:7]] = 1'b0;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_hilo_inflight = r_hilo_inflight;
		if (uq_push && uq_uop[164])
			n_hilo_inflight[uq_uop[163-:2]] = 1'b1;
		if (uq_push_two && uq_uop_two[164])
			n_hilo_inflight[uq_uop_two[163-:2]] = 1'b1;
		if (t_hilo_prf_ptr_val_out)
			n_hilo_inflight[t_hilo_prf_ptr_out] = 1'b0;
		if (t_div_complete)
			n_hilo_inflight[t_div_hilo_prf_ptr_out] = 1'b0;
		if (r_start_int && t_wr_hilo)
			n_hilo_inflight[int_uop[163-:2]] = 1'b0;
	end
	wire [31:0] w_s_sub32;
	wire [31:0] w_c_sub32;
	wire [31:0] w_imm32 = {{16 {int_uop[156]}}, int_uop[156-:16]};
	csa #(.N(32)) csa0(
		.a(t_srcA[31:0]),
		.b(((int_uop[198-:7] == 7'd17) | (int_uop[198-:7] == 7'd16) ? ~t_srcB[31:0] : ((int_uop[198-:7] == 7'd31) | (int_uop[198-:7] == 7'd30) ? w_imm32 : t_srcB[31:0]))),
		.cin(((int_uop[198-:7] == 7'd17) | (int_uop[198-:7] == 7'd16) ? 32'd1 : 32'd0)),
		.s(w_s_sub32),
		.cout(w_c_sub32)
	);
	wire [31:0] w_add_srcA = {w_c_sub32[30:0], 1'b0};
	wire [31:0] w_add_srcB = w_s_sub32;
	wire [31:0] w_add32 = w_add_srcA + w_add_srcB;
	wire w_add32_overflow = (w_add32[31] != w_srcB[31]) & (w_srcA[31] == w_srcB[31]);
	wire w_sub32_overflow = (w_add32[31] != w_srcB[31]) & (w_srcA[31] != w_srcB[31]);
	wire [63:0] w_add64;
	wire w_add64_overflow;
	wire w_sub64_overflow;
	generate
		if (1) begin : genblk4
			wire [63:0] w_s_sub64;
			wire [63:0] w_c_sub64;
			wire [63:0] w_imm64 = {{48 {int_uop[156]}}, int_uop[156-:16]};
			csa #(.N(64)) csa0(
				.a(t_srcA),
				.b(((int_uop[198-:7] == 7'd85) | (int_uop[198-:7] == 7'd84) ? ~t_srcB : ((int_uop[198-:7] == 7'd86) | (int_uop[198-:7] == 7'd87) ? w_imm64 : t_srcB))),
				.cin(((int_uop[198-:7] == 7'd85) | (int_uop[198-:7] == 7'd84) ? 64'd1 : 64'd0)),
				.s(w_s_sub64),
				.cout(w_c_sub64)
			);
			wire [63:0] w_add64_srcA = {w_c_sub64[62:0], 1'b0};
			wire [63:0] w_add64_srcB = w_s_sub64;
			assign w_add64 = w_add64_srcA + w_add64_srcB;
			assign w_add64_overflow = (w_add64[63] != w_srcB[63]) & (w_srcA[63] == w_srcB[63]);
			assign w_sub64_overflow = (w_add64[63] != w_srcB[63]) & (w_srcA[63] != w_srcB[63]);
		end
	endgenerate
	reg [5:0] r_tlb_index;
	reg [5:0] n_tlb_index;
	reg n_tlb_entry_out_valid;
	reg r_tlb_entry_out_valid;
	reg n_tlbr;
	reg r_tlbr;
	always @(posedge clk) begin
		r_tlb_index <= (reset ? 'd0 : n_tlb_index);
		r_tlb_entry_out_valid <= (reset ? 1'b0 : n_tlb_entry_out_valid);
		r_tlbr <= (reset ? 1'b0 : n_tlbr);
	end
	reg [63:0] r_epc;
	reg [5:0] r_index;
	reg [5:0] r_random;
	function [63:0] sign_extend32;
		input reg [31:0] in;
		reg [63:0] x;
		begin
			x = {{32 {in[31]}}, in};
			sign_extend32 = x;
		end
	endfunction
	function [63:0] zero_extend32;
		input reg [31:0] in;
		reg [63:0] x;
		begin
			x = {{32 {1'b0}}, in};
			zero_extend32 = x;
		end
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		t_pc = int_uop[92-:64];
		t_pc4 = int_uop[92-:64] + zero_extend32(32'd4);
		t_pc8 = int_uop[92-:64] + zero_extend32(32'd8);
		t_result = zero_extend32(32'd0);
		t_cpr0_result = zero_extend32(32'd0);
		t_unimp_op = 1'b0;
		t_fault = 1'b0;
		t_simm = {{E_BITS {int_uop[156]}}, int_uop[156-:16]};
		t_wr_int_prf = 1'b0;
		t_wr_cpr0 = 1'b0;
		t_wr_cpr0_64 = 1'b0;
		t_take_br = 1'b0;
		t_mispred_br = 1'b0;
		t_jaddr = {int_uop[102:93], int_uop[156-:16], 2'd0};
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
		case (int_uop[198-:7])
			7'd69: begin
				t_alu_valid = 1'b1;
				t_fault = 1'b1;
			end
			7'd77: begin
				t_alu_valid = 1'b1;
				t_fault = 1'b1;
			end
			7'd0: begin
				t_shift_left = 1'b1;
				t_32b_shift = 1'b1;
				t_shift_amt = {1'b0, int_uop[145:141]};
				t_result = {{HI_EBITS {w_shifter_out[31]}}, w_shifter_out[31:0]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd2: begin
				t_signed_shift = 1'b1;
				t_32b_shift = 1'b1;
				t_shift_amt = {1'b0, int_uop[145:141]};
				t_result = {{HI_EBITS {w_shifter_out[31]}}, w_shifter_out[31:0]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd1: begin
				t_32b_shift = 1'b1;
				t_shift_amt = {1'b0, int_uop[145:141]};
				t_result = {{HI_EBITS {w_shifter_out[31]}}, w_shifter_out[31:0]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd5: begin
				t_signed_shift = 1'b1;
				t_32b_shift = 1'b1;
				t_shift_amt = {1'b0, t_srcB[4:0]};
				t_result = {{HI_EBITS {w_shifter_out[31]}}, w_shifter_out[31:0]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd3: begin
				t_32b_shift = 1'b1;
				t_shift_left = 1'b1;
				t_result = {{HI_EBITS {w_shifter_out[31]}}, w_shifter_out[31:0]};
				t_shift_amt = {1'b0, t_srcB[4:0]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd4: begin
				t_32b_shift = 1'b1;
				t_shift_amt = {1'b0, t_srcB[4:0]};
				t_result = {{HI_EBITS {w_shifter_out[31]}}, w_shifter_out[31:0]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd90: begin
				t_shift_left = 1'b1;
				t_shift_amt = {1'b0, int_uop[145:141]};
				t_result = w_shifter_out;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd93: begin
				t_shift_left = 1'b1;
				t_shift_amt = {1'b1, int_uop[145:141]};
				t_result = w_shifter_out;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd91: begin
				t_shift_amt = {1'b0, int_uop[145:141]};
				t_result = w_shifter_out;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd94: begin
				t_shift_amt = {1'b1, int_uop[145:141]};
				t_result = w_shifter_out;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd92: begin
				t_signed_shift = 1'b1;
				t_shift_amt = {1'b0, int_uop[145:141]};
				t_result = w_shifter_out;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd95: begin
				t_signed_shift = 1'b1;
				t_shift_amt = {1'b1, int_uop[145:141]};
				t_result = w_shifter_out;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd96: begin
				t_shift_left = 1'b1;
				t_shift_amt = t_srcB[5:0];
				t_result = w_shifter_out;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd97: begin
				t_shift_amt = t_srcB[5:0];
				t_result = w_shifter_out;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd98: begin
				t_signed_shift = 1'b1;
				t_shift_amt = t_srcB[5:0];
				t_result = w_shifter_out;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd25: begin
				t_hilo_result = {t_src_hilo[127:64], t_srcA[63:0]};
				t_wr_hilo = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd9: begin
				t_hilo_result = {t_srcA[63:0], t_src_hilo[63:0]};
				t_wr_hilo = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd24: begin
				t_result = t_src_hilo[63:0];
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd8: begin
				t_result = t_src_hilo[127:64];
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd14: begin
				t_result = sign_extend32(w_add32);
				t_overflow = w_add32_overflow;
				t_fault = w_add32_overflow;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd15: begin
				t_result = sign_extend32(w_add32);
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd82: begin
				t_result = w_add64;
				t_overflow = w_add64_overflow;
				t_fault = w_add64_overflow;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd83: begin
				t_result = w_add64;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd84: begin
				t_result = w_add64;
				t_overflow = w_sub64_overflow;
				t_fault = w_sub64_overflow;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd10: t_start_mul = r_start_int & !ds_done;
			7'd11: t_start_mul = r_start_int & !ds_done;
			7'd12: begin
				t_signed_div = 1'b1;
				t_start_div32 = r_start_int & !ds_done;
			end
			7'd13: t_start_div32 = r_start_int & !ds_done;
			7'd102: t_start_mul = r_start_int & !ds_done;
			7'd103: t_start_mul = r_start_int & !ds_done;
			7'd104: begin
				t_signed_div = 1'b1;
				t_start_div64 = r_start_int & !ds_done;
			end
			7'd105: t_start_div64 = r_start_int & !ds_done;
			7'd16: begin
				t_result = sign_extend32(w_add32);
				t_overflow = w_sub32_overflow;
				t_fault = w_sub32_overflow;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd17: begin
				t_result = sign_extend32(w_add32);
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd85: begin
				t_result = w_add64;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd18: begin
				t_result = t_srcA & t_srcB;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd73: begin
				t_result = t_srcA;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd19: begin
				t_result = t_srcA | t_srcB;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd20: begin
				t_result = t_srcA ^ t_srcB;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd21: begin
				t_result = ~(t_srcA | t_srcB);
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd22: begin
				t_result = ($signed(t_srcB) < $signed(t_srcA) ? 'd1 : 'd0);
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd23: begin
				t_result = (t_srcB < t_srcA ? 'd1 : 'd0);
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd26: begin
				t_take_br = t_srcA == t_srcB;
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd52: begin
				t_take_br = t_srcA == t_srcB;
				t_mispred_br = (int_uop[20] != t_take_br) || !t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd27: begin
				t_take_br = t_srcA != t_srcB;
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd55: begin
				t_take_br = t_srcA[63] == 1'b0;
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd66: begin
				t_take_br = t_srcA[63] == 1'b0;
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_result = (t_take_br ? int_uop[92:29] + 'd8 : t_srcB);
				t_alu_valid = 1'b1;
				t_wr_int_prf = 1'b1;
			end
			7'd65: begin
				t_take_br = 1'b1;
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_result = int_uop[92:29] + 'd8;
				t_alu_valid = 1'b1;
				t_wr_int_prf = 1'b1;
			end
			7'd54: begin
				t_take_br = $signed(t_srcA) < $signed({64 {1'b0}});
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd28: begin
				t_take_br = $signed(t_srcA) <= $signed({64 {1'b0}});
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd59: begin
				t_take_br = ($signed(t_srcA) < $signed({64 {1'b0}})) || (t_srcA == {64 {1'b0}});
				t_mispred_br = (int_uop[20] != t_take_br) || !t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd29: begin
				t_take_br = $signed(t_srcA) > $signed({64 {1'b0}});
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd53: begin
				t_take_br = t_srcA != t_srcB;
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd56: begin
				t_take_br = $signed(t_srcA) < $signed({64 {1'b0}});
				t_mispred_br = (int_uop[20] != t_take_br) || !t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd58: begin
				t_take_br = $signed(t_srcA) > $signed({64 {1'b0}});
				t_mispred_br = (int_uop[20] != t_take_br) || !t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd57: begin
				t_take_br = $signed(t_srcA) >= $signed({64 {1'b0}});
				t_mispred_br = (int_uop[20] != t_take_br) || !t_take_br;
				t_pc = (t_take_br ? t_pc4 + {t_simm[61:0], 2'd0} : t_pc8);
				t_alu_valid = 1'b1;
			end
			7'd39: begin
				t_take_br = 1'b1;
				t_mispred_br = int_uop[20] != t_take_br;
				t_pc = {t_pc4[63:28], t_jaddr};
				t_result = int_uop[92:29] + 'd8;
				t_alu_valid = 1'b1;
				t_wr_int_prf = 1'b1;
			end
			7'd6: begin
				t_take_br = 1'b1;
				t_mispred_br = t_srcA != {int_uop[140-:48], int_uop[156-:16]};
				t_pc = t_srcA;
				t_alu_valid = 1'b1;
			end
			7'd7: begin
				t_take_br = 1'b1;
				t_mispred_br = t_srcA != {int_uop[140-:48], int_uop[156-:16]};
				t_pc = t_srcA;
				t_alu_valid = 1'b1;
				t_result = int_uop[92:29] + 'd8;
				t_wr_int_prf = 1'b1;
			end
			7'd34: begin
				t_result = t_srcA & {{E_BITS {1'b0}}, int_uop[156-:16]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd35: begin
				t_result = t_srcA | {{E_BITS {1'b0}}, int_uop[156-:16]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd36: begin
				t_result = t_srcA ^ {{E_BITS {1'b0}}, int_uop[156-:16]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd37: begin
				t_result = sign_extend32({int_uop[156-:16], 16'd0});
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd30: begin
				t_result = sign_extend32(w_add32);
				t_overflow = w_add32_overflow;
				t_fault = w_add32_overflow;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd31: begin
				t_result = sign_extend32(w_add32);
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd87: begin
				t_result = w_add64;
				t_overflow = w_add64_overflow;
				t_fault = w_add64_overflow;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd86: begin
				t_result = w_add64;
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd72: begin
				t_result = {{HI_EBITS {t_simm[31]}}, t_simm[31:0]};
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd32: begin
				t_result = ($signed(t_srcA) < $signed(t_simm) ? 'd1 : 'd0);
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd33: begin
				t_result = (t_srcA < t_simm ? 'd1 : 'd0);
				t_wr_int_prf = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd40: begin
				t_result = t_csr0_val;
				t_alu_valid = 1'b1;
				t_wr_int_prf = 1'b1;
			end
			7'd41: begin
				t_wr_cpr0 = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd99: begin
				t_result = t_csr0_64_val;
				t_alu_valid = 1'b1;
				t_wr_int_prf = 1'b1;
			end
			7'd100: begin
				t_wr_cpr0 = 1'b1;
				t_wr_cpr0_64 = 1'b1;
				t_alu_valid = 1'b1;
			end
			7'd76: begin
				t_eret = 1'b1;
				t_alu_valid = 1'b1;
				t_fault = 1'b1;
				t_pc = r_epc;
			end
			7'd60: begin
				t_trap = t_srcA == t_srcB;
				t_fault = t_srcA == t_srcB;
				t_alu_valid = 1'b1;
			end
			7'd113: begin
				t_trap = t_srcA != t_srcB;
				t_fault = t_srcA != t_srcB;
				t_alu_valid = 1'b1;
			end
			7'd79: begin
				t_alu_valid = 1'b1;
				t_fault = 1'b1;
				n_tlb_index = r_index;
				n_tlb_entry_out_valid = 1'b1;
				t_pc = t_pc4;
			end
			7'd80: begin
				t_alu_valid = 1'b1;
				t_fault = 1'b1;
				n_tlb_index = r_random;
				n_tlb_entry_out_valid = 1'b1;
				t_pc = t_pc4;
			end
			7'd78: begin
				t_alu_valid = 1'b1;
				t_fault = 1'b1;
				n_tlbr = 1'b1;
				t_pc = t_pc4;
			end
			7'd117: begin
				t_unimp_op = 1'b1;
				t_alu_valid = 1'b1;
			end
			default: begin
				t_unimp_op = 1'b1;
				t_alu_valid = 1'b1;
			end
		endcase
	end
	wire [63:0] w_agu = t_mem_srcA + {{E_BITS {mem_uq[156]}}, mem_uq[156-:16]};
	wire w_mem_srcA_ready = (t_mem_uq[184] ? (!r_prf_inflight[t_mem_uq[191-:7]] | t_fwd_int_mem_srcA) | t_fwd_mem_mem_srcA : 1'b1);
	wire w_dq_ready = (!r_prf_inflight[t_mem_dq[6-:7]] | t_fwd_int_mem_srcB) | t_fwd_mem_mem_srcB;
	always @(*) begin
		if (_sv2v_0)
			;
		t_pop_mem_uq = ((!t_mem_uq_empty && !(mem_q_next_full || mem_q_full)) && w_mem_srcA_ready) && !t_flash_clear;
		t_pop_mem_dq = ((!t_mem_dq_empty && !mem_dq_clr) && w_dq_ready) && !(mem_mdq_next_full || mem_mdq_full);
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_core_store_data[4-:5] = mem_dq[11-:5];
		t_core_store_data[68-:64] = t_mem_srcB;
		core_store_data_ptr = mem_dq[11-:5];
		core_store_data_ptr_valid = r_dq_ready;
	end
	always @(posedge clk)
		if (r_dq_ready)
			r_mdq[r_mdq_tail_ptr[1:0]] <= t_core_store_data;
	always @(posedge clk)
		if (reset) begin
			r_mem_ready <= 1'b0;
			r_dq_ready <= 1'b0;
		end
		else begin
			r_mem_ready <= t_pop_mem_uq;
			r_dq_ready <= t_pop_mem_dq;
		end
	wire [63:0] w_agu_la;
	wire w_cached;
	wire w_mapped;
	wire [1:0] w_seg;
	mipsseg seg0(
		.v_addr(w_agu),
		.l_addr(w_agu_la),
		.cache(w_cached),
		.mapped(w_mapped),
		.seg(w_seg),
		.in_kernel_mode(in_kernel_mode),
		.in_supervisor_mode(in_supervisor_mode),
		.in_user_mode(in_user_mode),
		.in_64b_kernel_mode(in_64b_kernel_mode),
		.in_64b_supervisor_mode(in_64b_supervisor_mode),
		.in_64b_user_mode(in_64b_user_mode)
	);
	wire w_bad_seg_perms = (w_seg != 2'd3) & in_user_mode;
	always @(negedge clk)
		if (w_bad_seg_perms)
			$display("trying to access segment %d in bad mode", w_seg);
	reg [1:0] r_entryhi_r;
	reg [26:0] r_entryhi_vpn2;
	always @(*) begin
		if (_sv2v_0)
			;
		t_mem_simm = {{E_BITS {mem_uq[156]}}, mem_uq[156-:16]};
		t_mem_tail[84-:5] = 5'd4;
		t_mem_tail[150-:64] = w_agu_la;
		t_mem_tail[76-:5] = mem_uq[28-:5];
		t_mem_tail[64] = 1'b0;
		t_mem_tail[71-:7] = mem_uq[173-:7];
		t_mem_tail[86] = 1'b0;
		t_mem_tail[85] = 1'b0;
		t_mem_tail[63-:64] = zero_extend32(32'd0);
		t_mem_tail[79] = 1'b0;
		t_mem_tail[77] = w_cached;
		t_mem_tail[78] = w_mapped;
		case (mem_uq[198-:7])
			7'd49: begin
				t_mem_tail[84-:5] = 5'd5;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[64] = 1'b0;
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd50: begin
				t_mem_tail[84-:5] = 5'd6;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[64] = 1'b0;
				t_mem_tail[79] = w_agu[0] | w_bad_seg_perms;
			end
			7'd51: begin
				t_mem_tail[84-:5] = 5'd7;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[64] = 1'b0;
				t_mem_tail[79] = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
			end
			7'd68: begin
				t_mem_tail[84-:5] = 5'd12;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[85] = 1'b1;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[71-:7] = mem_uq[173-:7];
				t_mem_tail[79] = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
			end
			7'd64: begin
				t_mem_tail[84-:5] = 5'd8;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[64] = 1'b0;
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd63: begin
				t_mem_tail[84-:5] = 5'd9;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[64] = 1'b0;
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd44: begin
				t_mem_tail[84-:5] = 5'd4;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
			end
			7'd101: begin
				t_mem_tail[84-:5] = 5'd16;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
			end
			7'd61: begin
				t_mem_tail[84-:5] = 5'd11;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[71-:7] = mem_uq[173-:7];
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd62: begin
				t_mem_tail[84-:5] = 5'd10;
				t_mem_tail[76-:5] = mem_uq[28-:5];
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd45: begin
				t_mem_tail[84-:5] = 5'd0;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd46: begin
				t_mem_tail[84-:5] = 5'd1;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd48: begin
				t_mem_tail[84-:5] = 5'd3;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = w_agu[0] | w_bad_seg_perms;
			end
			7'd47: begin
				t_mem_tail[84-:5] = 5'd2;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = w_agu[0] | w_bad_seg_perms;
			end
			7'd88: begin
				t_mem_tail[84-:5] = 5'd14;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
			end
			7'd89: begin
				t_mem_tail[84-:5] = 5'd15;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[64] = 1'b0;
				t_mem_tail[79] = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
			end
			7'd106: begin
				t_mem_tail[84-:5] = 5'd17;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[71-:7] = mem_uq[173-:7];
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd107: begin
				t_mem_tail[84-:5] = 5'd18;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[71-:7] = mem_uq[173-:7];
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd108: begin
				t_mem_tail[84-:5] = 5'd19;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[64] = 1'b0;
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd109: begin
				t_mem_tail[84-:5] = 5'd20;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[64] = 1'b0;
				t_mem_tail[79] = w_bad_seg_perms;
			end
			7'd110: begin
				t_mem_tail[84-:5] = 5'd21;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
				t_mem_tail[85] = 1'b1;
			end
			7'd111: begin
				t_mem_tail[84-:5] = 5'd22;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[79] = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
				t_mem_tail[85] = 1'b1;
			end
			7'd112: begin
				t_mem_tail[84-:5] = 5'd23;
				t_mem_tail[86] = 1'b1;
				t_mem_tail[64] = 1'b1;
				t_mem_tail[71-:7] = mem_uq[173-:7];
				t_mem_tail[79] = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
				t_mem_tail[85] = 1'b1;
			end
			7'd81: begin
				t_mem_tail[84-:5] = 5'd13;
				t_mem_tail[150-:64] = {r_entryhi_r, 22'd0, r_entryhi_vpn2, 13'd0};
				t_mem_tail[78] = 1'b1;
			end
			default:
				;
		endcase
	end
	always @(posedge clk) begin
		r_int_result <= t_result;
		r_mem_result <= mem_rsp_load_data;
		r_int_hilo <= t_hilo_result;
		r_mul_hilo <= t_mul_result;
		r_div_hilo <= t_div_result;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_fwd_int_mem_srcA = (r_start_int && t_wr_int_prf) && (t_mem_uq[191-:7] == int_uop[173-:7]);
		t_fwd_int_mem_srcB = (r_start_int && t_wr_int_prf) && (t_mem_dq[6-:7] == int_uop[173-:7]);
		t_fwd_mem_mem_srcA = mem_rsp_dst_valid && (t_mem_uq[191-:7] == mem_rsp_dst_ptr);
		t_fwd_mem_mem_srcB = mem_rsp_dst_valid && (t_mem_dq[6-:7] == mem_rsp_dst_ptr);
	end
	always @(posedge clk) begin
		r_fwd_int_mem_srcA <= t_fwd_int_mem_srcA;
		r_fwd_int_mem_srcB <= t_fwd_int_mem_srcB;
		r_fwd_mem_mem_srcA <= t_fwd_mem_mem_srcA;
		r_fwd_mem_mem_srcB <= t_fwd_mem_mem_srcB;
		r_fwd_int_srcA <= (r_start_int && t_wr_int_prf) && (t_picked_uop[191-:7] == int_uop[173-:7]);
		r_fwd_int_srcB <= (r_start_int && t_wr_int_prf) && (t_picked_uop[182-:7] == int_uop[173-:7]);
		r_fwd_mem_srcA <= mem_rsp_dst_valid && (t_picked_uop[191-:7] == mem_rsp_dst_ptr);
		r_fwd_mem_srcB <= mem_rsp_dst_valid && (t_picked_uop[182-:7] == mem_rsp_dst_ptr);
		r_fwd_hilo_int <= (r_start_int && t_wr_hilo) && (t_picked_uop[160-:2] == int_uop[163-:2]);
		r_fwd_hilo_mul <= t_hilo_prf_ptr_val_out && (t_picked_uop[160-:2] == t_hilo_prf_ptr_out);
		r_fwd_hilo_div <= t_div_complete && (t_picked_uop[160-:2] == t_div_hilo_prf_ptr_out);
	end
	rf4r2w #(
		.WIDTH(64),
		.LG_DEPTH(7)
	) intprf(
		.clk(clk),
		.rdptr0(t_picked_uop[191-:7]),
		.rdptr1(t_picked_uop[182-:7]),
		.rdptr2(t_mem_uq[191-:7]),
		.rdptr3(t_mem_dq[6-:7]),
		.wrptr0(int_uop[173-:7]),
		.wrptr1(mem_rsp_dst_ptr),
		.wen0(r_start_int && t_wr_int_prf),
		.wen1(mem_rsp_dst_valid),
		.wr0(t_result),
		.wr1(mem_rsp_load_data),
		.rd0(w_srcA),
		.rd1(w_srcB),
		.rd2(w_mem_srcA),
		.rd3(w_mem_srcB)
	);
	always @(posedge clk) begin
		r_src_hilo <= r_hilo_prf[t_picked_uop[160-:2]];
		if (r_start_int && t_wr_hilo)
			r_hilo_prf[int_uop[163-:2]] <= t_hilo_result;
		else if (t_hilo_prf_ptr_val_out)
			r_hilo_prf[t_hilo_prf_ptr_out] <= t_mul_result;
		else if (t_div_complete)
			r_hilo_prf[t_div_hilo_prf_ptr_out] <= t_div_result;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_wr_pc_idx = r_wr_pc_idx;
		n_rd_pc_idx = r_rd_pc_idx;
		t_push_putchar = t_wr_cpr0 & (int_uop[173-:7] == 'd7);
		if (t_push_putchar)
			n_wr_pc_idx = r_wr_pc_idx + 'd1;
		if (putchar_fifo_pop)
			n_rd_pc_idx = r_rd_pc_idx + 'd1;
	end
	always @(posedge clk) begin
		r_wr_pc_idx <= (reset ? 'd0 : n_wr_pc_idx);
		r_rd_pc_idx <= (reset ? 'd0 : n_rd_pc_idx);
	end
	always @(posedge clk)
		if (t_push_putchar)
			r_pc_buf[r_wr_pc_idx[2:0]] <= t_srcA[7:0];
	assign putchar_fifo_out = r_pc_buf[r_rd_pc_idx[2:0]];
	assign putchar_fifo_empty = r_wr_pc_idx == r_rd_pc_idx;
	wire w_putchar_fifo_full = (r_wr_pc_idx[2:0] == r_rd_pc_idx[2:0]) & (r_wr_pc_idx[3] != r_rd_pc_idx[3]);
	assign putchar_fifo_wptr = r_wr_pc_idx;
	assign putchar_fifo_rptr = r_rd_pc_idx;
	reg [7:0] r_entryhi_asid;
	reg [7:0] n_entryhi_asid;
	reg [1:0] n_entryhi_r;
	reg [26:0] n_entryhi_vpn2;
	reg [27:0] n_entrylo0_pfn;
	reg [27:0] r_entrylo0_pfn;
	reg [2:0] n_entrylo0_c;
	reg [2:0] r_entrylo0_c;
	reg n_entrylo0_d;
	reg r_entrylo0_d;
	reg n_entrylo0_v;
	reg r_entrylo0_v;
	reg n_entrylo0_g;
	reg r_entrylo0_g;
	reg [27:0] n_entrylo1_pfn;
	reg [27:0] r_entrylo1_pfn;
	reg [2:0] n_entrylo1_c;
	reg [2:0] r_entrylo1_c;
	reg n_entrylo1_d;
	reg r_entrylo1_d;
	reg n_entrylo1_v;
	reg r_entrylo1_v;
	reg n_entrylo1_g;
	reg r_entrylo1_g;
	reg [8:0] r_ptebase;
	reg [8:0] n_ptebase;
	reg [30:0] r_xptebase;
	reg [30:0] n_xptebase;
	reg [26:0] r_badvpn2;
	reg [26:0] n_badvpn2;
	reg [11:0] n_pagemask;
	reg [11:0] r_pagemask;
	assign asid = r_entryhi_asid;
	reg r_sr_ie;
	reg n_sr_ie;
	reg [7:0] r_sr_im;
	reg [7:0] n_sr_im;
	reg r_sr_exl;
	reg n_sr_exl;
	reg r_sr_erl;
	reg n_sr_erl;
	reg [31:0] r_count;
	reg [31:0] n_count;
	reg [31:0] r_compare;
	reg [31:0] n_compare;
	reg r_timer_ip;
	reg n_timer_ip;
	reg [1:0] r_sr_ksu;
	reg [1:0] n_sr_ksu;
	reg r_sr_ux;
	reg n_sr_ux;
	reg r_sr_sx;
	reg n_sr_sx;
	reg r_sr_kx;
	reg n_sr_kx;
	reg r_sr_bev;
	reg n_sr_bev;
	reg r_sr_ts;
	reg n_sr_ts;
	reg [5:0] r_wired;
	reg [5:0] n_wired;
	reg [5:0] n_random;
	reg r_index_probe_failed;
	reg n_index_probe_failed;
	reg [5:0] n_index;
	reg [122:0] r_tlb_entry;
	reg [63:0] n_epc;
	reg [63:0] n_badvaddr;
	reg [63:0] r_badvaddr;
	assign exec_epc = r_epc;
	assign sr_bev = r_sr_bev;
	assign sr_exl = r_sr_exl;
	reg r_exc_in_ds;
	reg n_exc_in_ds;
	reg [4:0] r_cause;
	reg [4:0] n_cause;
	always @(*) begin
		if (_sv2v_0)
			;
		n_exc_in_ds = r_exc_in_ds;
		n_cause = r_cause;
		if (core_wr_cause) begin
			n_cause = core_cause;
			n_exc_in_ds = exc_in_delay;
		end
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_badvaddr = r_badvaddr;
		if (core_wr_badvaddr)
			n_badvaddr = core_badvaddr;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_epc = r_epc;
		if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd14))
			n_epc = t_srcA;
		else if (core_wr_epc & (r_sr_exl == 1'b0))
			n_epc = core_epc;
	end
	always @(posedge clk) begin
		r_epc <= (reset ? 'd0 : n_epc);
		r_badvaddr <= (reset ? 'd0 : n_badvaddr);
		r_cause <= (reset ? 'd0 : n_cause);
		r_exc_in_ds <= (reset ? 1'b0 : n_exc_in_ds);
		r_entryhi_asid <= (reset ? 'd0 : n_entryhi_asid);
		r_entryhi_r <= (reset ? 'd0 : n_entryhi_r);
		r_entryhi_vpn2 <= (reset ? 'd0 : n_entryhi_vpn2);
		r_pagemask <= (reset ? 'd0 : n_pagemask);
		r_entrylo0_pfn <= (reset ? 'd0 : n_entrylo0_pfn);
		r_entrylo0_c <= (reset ? 'd0 : n_entrylo0_c);
		r_entrylo0_d <= (reset ? 'd0 : n_entrylo0_d);
		r_entrylo0_v <= (reset ? 'd0 : n_entrylo0_v);
		r_entrylo0_g <= (reset ? 'd0 : n_entrylo0_g);
		r_entrylo1_pfn <= (reset ? 'd0 : n_entrylo1_pfn);
		r_entrylo1_c <= (reset ? 'd0 : n_entrylo1_c);
		r_entrylo1_d <= (reset ? 'd0 : n_entrylo1_d);
		r_entrylo1_v <= (reset ? 'd0 : n_entrylo1_v);
		r_entrylo1_g <= (reset ? 'd0 : n_entrylo1_g);
		r_ptebase <= (reset ? 'd0 : n_ptebase);
		r_xptebase <= (reset ? 'd0 : n_xptebase);
		r_badvpn2 <= (reset ? 'd0 : n_badvpn2);
	end
	always @(*) begin
		if (_sv2v_0)
			;
		tlb_entry_out_valid = r_tlb_entry_out_valid;
		tlb_entry_out[122-:6] = r_tlb_index;
		tlb_entry_out[67-:28] = r_entrylo0_pfn;
		tlb_entry_out[33-:28] = r_entrylo1_pfn;
		tlb_entry_out[116-:12] = r_pagemask;
		tlb_entry_out[104-:8] = r_entryhi_asid;
		tlb_entry_out[96-:2] = r_entryhi_r;
		tlb_entry_out[94-:27] = r_entryhi_vpn2;
		tlb_entry_out[36-:3] = r_entrylo0_c;
		tlb_entry_out[2-:3] = r_entrylo1_c;
		tlb_entry_out[38] = r_entrylo0_v;
		tlb_entry_out[4] = r_entrylo1_v;
		tlb_entry_out[39] = r_entrylo0_d;
		tlb_entry_out[5] = r_entrylo1_d;
		tlb_entry_out[37] = r_entrylo0_g;
		tlb_entry_out[3] = r_entrylo1_g;
	end
	always @(posedge clk) begin
		r_tlb_entry <= r_shadow_tlb[r_index];
		if (r_tlb_entry_out_valid)
			r_shadow_tlb[r_tlb_index] <= tlb_entry_out;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_index = r_index;
		n_index_probe_failed = r_index_probe_failed;
		if (core_wr_tlbp) begin
			n_index_probe_failed = core_tlbp_hit == 1'b0;
			n_index = core_tlbp_index;
		end
		else if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd0)) begin
			n_index = t_srcA[5:0];
			n_index_probe_failed = t_srcA[31];
		end
	end
	always @(posedge clk) begin
		r_index <= (reset ? 'd0 : n_index);
		r_index_probe_failed <= (reset ? 1'b0 : n_index_probe_failed);
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_entrylo0_pfn = r_entrylo0_pfn;
		n_entrylo0_c = r_entrylo0_c;
		n_entrylo0_d = r_entrylo0_d;
		n_entrylo0_v = r_entrylo0_v;
		n_entrylo0_g = r_entrylo0_g;
		if (r_tlbr) begin
			n_entrylo0_g = r_tlb_entry[37];
			n_entrylo0_v = r_tlb_entry[38];
			n_entrylo0_d = r_tlb_entry[39];
			n_entrylo0_c = r_tlb_entry[36-:3];
			n_entrylo0_pfn = r_tlb_entry[67-:28];
		end
		else if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd2)) begin
			n_entrylo0_g = t_srcA[0];
			n_entrylo0_v = t_srcA[1];
			n_entrylo0_d = t_srcA[2];
			n_entrylo0_c = t_srcA[5:3];
			n_entrylo0_pfn = (t_wr_cpr0_64 ? t_srcA[33:6] : {4'd0, t_srcA[29:6]});
		end
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_entrylo1_pfn = r_entrylo1_pfn;
		n_entrylo1_c = r_entrylo1_c;
		n_entrylo1_d = r_entrylo1_d;
		n_entrylo1_v = r_entrylo1_v;
		n_entrylo1_g = r_entrylo1_g;
		if (r_tlbr) begin
			n_entrylo1_g = r_tlb_entry[3];
			n_entrylo1_v = r_tlb_entry[4];
			n_entrylo1_d = r_tlb_entry[5];
			n_entrylo1_c = r_tlb_entry[2-:3];
			n_entrylo1_pfn = r_tlb_entry[33-:28];
		end
		else if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd3)) begin
			n_entrylo1_g = t_srcA[0];
			n_entrylo1_v = t_srcA[1];
			n_entrylo1_d = t_srcA[2];
			n_entrylo1_c = t_srcA[5:3];
			n_entrylo1_pfn = (t_wr_cpr0_64 ? t_srcA[33:6] : {4'd0, t_srcA[29:6]});
		end
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_badvpn2 = r_badvpn2;
		n_ptebase = r_ptebase;
		n_xptebase = r_xptebase;
		if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd4))
			n_ptebase = t_srcA[31:23];
		else if (((r_start_int & t_wr_cpr0) & t_wr_cpr0_64) & (int_uop[173-:7] == 'd20))
			n_xptebase = t_srcA[63:33];
		if (save_to_tlb_regs)
			n_badvpn2 = core_badvaddr[39:13];
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_pagemask = r_pagemask;
		if (r_tlbr)
			n_pagemask = r_tlb_entry[116-:12];
		else if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd5))
			n_pagemask = t_srcA[24:13];
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_entryhi_asid = r_entryhi_asid;
		n_entryhi_r = r_entryhi_r;
		n_entryhi_vpn2 = r_entryhi_vpn2;
		if (r_tlbr) begin
			n_entryhi_asid = r_tlb_entry[104-:8];
			n_entryhi_r = r_tlb_entry[96-:2];
			n_entryhi_vpn2 = r_tlb_entry[94-:27];
		end
		else if (save_to_tlb_regs) begin
			n_entryhi_r = core_badvaddr[63:62];
			n_entryhi_vpn2 = core_badvaddr[39:13];
		end
		else if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd10)) begin
			n_entryhi_asid = t_srcA[7:0];
			if (t_wr_cpr0_64) begin
				n_entryhi_r = t_srcA[63:62];
				n_entryhi_vpn2 = t_srcA[39:13];
			end
			else begin
				n_entryhi_r = 2'd0;
				n_entryhi_vpn2 = {8'd0, t_srcA[31:13]};
			end
		end
	end
	always @(posedge clk) begin
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
		n_count = r_count + 32'd1;
		n_compare = r_compare;
		n_timer_ip = r_timer_ip | (n_count == r_compare);
		if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd12)) begin
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
		if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd9))
			n_count = t_srcA[31:0];
		if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd11)) begin
			n_compare = t_srcA[31:0];
			n_timer_ip = 1'b0;
		end
		else if (core_wr_cause)
			n_sr_exl = 1'b1;
		else if (t_eret) begin
			if (r_sr_erl)
				n_sr_erl = 1'b0;
			else
				n_sr_exl = 1'b0;
		end
	end
	always @(posedge clk) begin
		r_sr_ie = (reset ? 'd0 : n_sr_ie);
		r_sr_exl <= (reset ? 'd0 : n_sr_exl);
		r_sr_erl <= (reset ? 1'b1 : n_sr_erl);
		r_sr_ksu <= (reset ? 'd0 : n_sr_ksu);
		r_sr_ux <= (reset ? 'd0 : n_sr_ux);
		r_sr_sx <= (reset ? 'd0 : n_sr_sx);
		r_sr_kx <= (reset ? 'd0 : n_sr_kx);
		r_sr_bev <= (reset ? 1'b1 : n_sr_bev);
		r_sr_ts <= (reset ? 1'b0 : n_sr_ts);
		r_sr_im <= (reset ? 8'd0 : n_sr_im);
		r_wired <= (reset ? 'd0 : n_wired);
		r_random <= (reset ? 'd47 : n_random);
		r_count <= (reset ? 32'd0 : n_count);
		r_compare <= (reset ? 32'd0 : n_compare);
		r_timer_ip <= (reset ? 1'b0 : n_timer_ip);
	end
	assign in_kernel_mode = ((r_sr_ksu == 'd0) | r_sr_exl) | r_sr_erl;
	assign in_supervisor_mode = ((r_sr_ksu == 'd1) & (r_sr_exl == 1'b0)) & (r_sr_erl == 1'b0);
	assign in_user_mode = ((r_sr_ksu == 'd2) & (r_sr_exl == 1'b0)) & (r_sr_erl == 1'b0);
	assign in_64b_user_mode = in_user_mode & r_sr_ux;
	assign in_64b_kernel_mode = in_kernel_mode & r_sr_kx;
	assign in_64b_supervisor_mode = in_supervisor_mode & r_sr_sx;
	wire [7:0] w_ip = {r_timer_ip, 7'd0};
	assign irq_pending = ((r_sr_ie & ~r_sr_exl) & ~r_sr_erl) & |(w_ip & r_sr_im);
	assign cp0_count = r_count;
	always @(*) begin
		if (_sv2v_0)
			;
		cpr0_status_reg = {9'b011100000, r_sr_bev, r_sr_ts, 5'd0, r_sr_im, r_sr_kx, r_sr_sx, r_sr_ux, r_sr_ksu, r_sr_erl, r_sr_exl, r_sr_ie};
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_csr0_val = sign_extend32(cpr0_status_reg);
		case (int_uop[189:185])
			'd0: t_csr0_val = sign_extend32({r_index_probe_failed, 25'd0, r_index});
			'd1: t_csr0_val = sign_extend32({26'd0, r_random});
			'd2: t_csr0_val = sign_extend32({2'd0, r_entrylo0_pfn[23:0], r_entrylo0_c, r_entrylo0_d, r_entrylo0_v, r_entrylo0_g});
			'd3: t_csr0_val = sign_extend32({2'd0, r_entrylo1_pfn[23:0], r_entrylo1_c, r_entrylo1_d, r_entrylo1_v, r_entrylo1_g});
			'd4: t_csr0_val = sign_extend32({r_ptebase, r_badvpn2[18:0], 4'd0});
			'd5: t_csr0_val = sign_extend32({7'd0, r_pagemask, 13'd0});
			'd6: t_csr0_val = sign_extend32({26'd0, r_wired});
			'd7: t_csr0_val = sign_extend32({31'd0, w_putchar_fifo_full});
			'd8: t_csr0_val = r_badvaddr;
			'd10: t_csr0_val = sign_extend32({r_entryhi_vpn2[18:0], 5'd0, r_entryhi_asid});
			'd12: t_csr0_val = sign_extend32(cpr0_status_reg);
			'd9: t_csr0_val = sign_extend32(r_count);
			'd11: t_csr0_val = sign_extend32(r_compare);
			'd13: t_csr0_val = sign_extend32({r_exc_in_ds, 15'h0000, w_ip, 1'b0, r_cause, 2'd0});
			'd14: t_csr0_val = r_epc;
			'd15: t_csr0_val = sign_extend32(32'h00000400);
			'd16: t_csr0_val = 'ha8200;
			'd23: t_csr0_val = sign_extend32(r_cycle[31:0]);
			'd24: t_csr0_val = sign_extend32(r_retired_insns[31:0]);
		endcase
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_csr0_64_val = t_csr0_val;
		case (int_uop[189:185])
			'd2: t_csr0_64_val = {30'd0, r_entrylo0_pfn, r_entrylo0_c, r_entrylo0_d, r_entrylo0_v, r_entrylo0_g};
			'd3: t_csr0_64_val = {30'd0, r_entrylo1_pfn, r_entrylo1_c, r_entrylo1_d, r_entrylo1_v, r_entrylo1_g};
			'd10: t_csr0_64_val = {r_entryhi_r, 22'd0, r_entryhi_vpn2, 5'd0, r_entryhi_asid};
			'd20: t_csr0_64_val = {r_xptebase, r_entryhi_r, r_badvpn2, 4'd0};
		endcase
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_random = r_random;
		n_wired = r_wired;
		if ((r_start_int & t_wr_cpr0) & (int_uop[173-:7] == 'd6)) begin
			n_wired = t_srcA[5:0];
			n_random = 'd47;
		end
		else if (retire)
			n_random = (r_random == r_wired ? 'd47 : r_random - 'd1);
	end
	always @(posedge clk)
		if (reset)
			complete_valid_1 <= 1'b0;
		else
			complete_valid_1 <= ((r_start_int && t_alu_valid) || t_mul_complete) || t_div_complete;
	always @(posedge clk)
		if (t_mul_complete || t_div_complete) begin
			complete_bundle_1[138-:5] <= (t_mul_complete ? t_rob_ptr_out : t_div_rob_ptr_out);
			complete_bundle_1[133] <= 1'b1;
			complete_bundle_1[132] <= 1'b0;
			complete_bundle_1[131-:64] <= 'd0;
			complete_bundle_1[66] <= 1'b0;
			complete_bundle_1[67] <= 1'b0;
			complete_bundle_1[65] <= 1'b0;
			complete_bundle_1[64] <= 1'b0;
			complete_bundle_1[63-:64] <= t_mul_result[63:0];
		end
		else begin
			complete_bundle_1[138-:5] <= int_uop[28-:5];
			complete_bundle_1[133] <= t_alu_valid;
			complete_bundle_1[132] <= (t_mispred_br || t_unimp_op) || t_fault;
			complete_bundle_1[131-:64] <= t_pc;
			complete_bundle_1[66] <= t_unimp_op;
			complete_bundle_1[67] <= t_take_br;
			complete_bundle_1[65] <= t_overflow;
			complete_bundle_1[64] <= t_trap;
			complete_bundle_1[63-:64] <= t_result;
		end
	initial _sv2v_0 = 0;
endmodule

module decode_mips (
	in_kernel_mode,
	in_supervisor_mode,
	in_user_mode,
	in_64b_kernel_mode,
	in_64b_supervisor_mode,
	in_64b_user_mode,
	irq,
	tlb_miss,
	tlb_invalid,
	misaligned,
	insn,
	pc,
	insn_pred,
	pht_idx,
	insn_pred_target,
	uop
);
	reg _sv2v_0;
	input wire in_kernel_mode;
	input wire in_supervisor_mode;
	input wire in_user_mode;
	input wire in_64b_kernel_mode;
	input wire in_64b_supervisor_mode;
	input wire in_64b_user_mode;
	input wire irq;
	input wire tlb_miss;
	input wire tlb_invalid;
	input wire misaligned;
	input wire [31:0] insn;
	input wire [63:0] pc;
	input wire insn_pred;
	input wire [15:0] pht_idx;
	input wire [63:0] insn_pred_target;
	output reg [198:0] uop;
	wire [5:0] opcode = insn[31:26];
	wire is_nop = insn == 32'd0;
	wire is_ehb = insn == 32'd192;
	localparam ZP = 2;
	wire w_in_64b_mode;
	generate
		if (1) begin : genblk1
			assign w_in_64b_mode = (in_64b_kernel_mode | in_64b_user_mode) | in_64b_supervisor_mode;
		end
	endgenerate
	wire [6:0] rs = {{ZP {1'b0}}, insn[25:21]};
	wire [6:0] rt = {{ZP {1'b0}}, insn[20:16]};
	wire [6:0] rd = {{ZP {1'b0}}, insn[15:11]};
	wire [6:0] fs = {{ZP {1'b0}}, insn[15:11]};
	wire [6:0] ft = {{ZP {1'b0}}, insn[20:16]};
	wire [6:0] fd = {{ZP {1'b0}}, insn[10:6]};
	wire [5:0] shamt = {1'b0, insn[10:6]};
	always @(*) begin
		if (_sv2v_0)
			;
		uop[198-:7] = 7'd117;
		uop[191-:7] = 'd0;
		uop[182-:7] = 'd0;
		uop[173-:7] = 'd0;
		uop[184] = 1'b0;
		uop[175] = 1'b0;
		uop[183] = 1'b0;
		uop[174] = 1'b0;
		uop[164] = 1'b0;
		uop[161] = 1'b0;
		uop[163-:2] = 'd0;
		uop[160-:2] = 'd0;
		uop[166] = 1'b0;
		uop[165] = 1'b0;
		uop[158] = 1'b0;
		uop[157] = 1'b0;
		uop[156-:16] = 16'd0;
		uop[140-:48] = {48 {1'b0}};
		uop[92-:64] = pc;
		uop[23] = 1'b0;
		uop[22] = 1'b0;
		uop[21] = 1'b0;
		uop[28-:5] = 'd0;
		uop[20] = 1'b0;
		uop[18] = 1'b0;
		uop[15-:16] = pht_idx;
		uop[17] = 1'b0;
		uop[19] = 1'b0;
		uop[16] = 1'b0;
		if (irq)
			uop[198-:7] = 7'd118;
		else if (misaligned)
			uop[198-:7] = 7'd114;
		else if (tlb_miss)
			uop[198-:7] = 7'd115;
		else if (tlb_invalid)
			uop[198-:7] = 7'd116;
		else
			case (opcode)
				6'd0:
					case (insn[5:0])
						6'd0: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (is_nop || is_ehb ? 7'd75 : 7'd0);
							uop[19] = 1'b1;
							uop[156-:16] = {10'b0000000000, shamt};
						end
						6'd2: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[156-:16] = {10'b0000000000, shamt};
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd1);
							uop[19] = 1'b1;
						end
						6'd3: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[156-:16] = {10'b0000000000, shamt};
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd2);
							uop[19] = 1'b1;
						end
						6'd4: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd3);
							uop[19] = 1'b1;
						end
						6'd6: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd4);
							uop[19] = 1'b1;
						end
						6'd7: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd5);
							uop[19] = 1'b1;
						end
						6'd20:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[182-:7] = rs;
								uop[175] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd96);
								uop[19] = 1'b1;
							end
						6'd22:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[182-:7] = rs;
								uop[175] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd97);
								uop[19] = 1'b1;
							end
						6'd23:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[182-:7] = rs;
								uop[175] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd98);
								uop[19] = 1'b1;
							end
						6'd56:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd90);
								uop[156-:16] = {10'b0000000000, shamt};
								uop[19] = 1'b1;
							end
						6'd58:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd91);
								uop[156-:16] = {10'b0000000000, shamt};
								uop[19] = 1'b1;
							end
						6'd59:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd92);
								uop[156-:16] = {10'b0000000000, shamt};
								uop[19] = 1'b1;
							end
						6'd60:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd93);
								uop[156-:16] = {10'b0000000000, shamt};
								uop[19] = 1'b1;
							end
						6'd62:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd94);
								uop[156-:16] = {10'b0000000000, shamt};
								uop[19] = 1'b1;
							end
						6'd63:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd95);
								uop[156-:16] = {10'b0000000000, shamt};
								uop[19] = 1'b1;
							end
						6'd8: begin
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[158] = 1'b1;
							uop[198-:7] = 7'd6;
							uop[156-:16] = insn_pred_target[15:0];
							uop[140-:48] = insn_pred_target[63:16];
							uop[18] = 1'b1;
							uop[19] = 1'b1;
						end
						6'd9: begin
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[158] = 1'b1;
							uop[198-:7] = 7'd7;
							uop[166] = rd != 'd0;
							uop[173-:7] = rd;
							uop[156-:16] = insn_pred_target[15:0];
							uop[140-:48] = insn_pred_target[63:16];
							uop[18] = 1'b1;
							uop[19] = 1'b1;
						end
						6'd12: begin
							uop[198-:7] = 7'd77;
							uop[21] = 1'b1;
							uop[19] = 1'b1;
						end
						6'd13: begin
							uop[198-:7] = 7'd69;
							uop[21] = 1'b1;
							uop[19] = 1'b1;
						end
						6'd15: begin
							uop[198-:7] = 7'd75;
							uop[19] = 1'b1;
						end
						6'd16: begin
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd8);
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[161] = 1'b1;
							uop[19] = 1'b1;
						end
						6'd17: begin
							uop[198-:7] = 7'd9;
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[161] = 1'b1;
							uop[164] = 1'b1;
							uop[19] = 1'b1;
						end
						6'd18: begin
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd24);
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[161] = 1'b1;
							uop[19] = 1'b1;
						end
						6'd19: begin
							uop[198-:7] = 7'd25;
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[161] = 1'b1;
							uop[164] = 1'b1;
							uop[19] = 1'b1;
						end
						6'd24: begin
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[182-:7] = rt;
							uop[175] = 1'b1;
							uop[164] = 1'b1;
							uop[198-:7] = 7'd10;
							uop[19] = 1'b1;
						end
						6'd25: begin
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[182-:7] = rt;
							uop[175] = 1'b1;
							uop[164] = 1'b1;
							uop[198-:7] = 7'd11;
							uop[19] = 1'b1;
						end
						6'd26: begin
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[182-:7] = rt;
							uop[175] = 1'b1;
							uop[164] = 1'b1;
							uop[198-:7] = 7'd12;
							uop[19] = 1'b1;
						end
						6'd27: begin
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[182-:7] = rt;
							uop[175] = 1'b1;
							uop[164] = 1'b1;
							uop[198-:7] = 7'd13;
							uop[19] = 1'b1;
						end
						6'd28:
							if (w_in_64b_mode) begin
								uop[191-:7] = rs;
								uop[184] = 1'b1;
								uop[182-:7] = rt;
								uop[175] = 1'b1;
								uop[164] = 1'b1;
								uop[198-:7] = 7'd102;
								uop[19] = 1'b1;
							end
						6'd29:
							if (w_in_64b_mode) begin
								uop[191-:7] = rs;
								uop[184] = 1'b1;
								uop[182-:7] = rt;
								uop[175] = 1'b1;
								uop[164] = 1'b1;
								uop[198-:7] = 7'd103;
								uop[19] = 1'b1;
							end
						6'd30:
							if (w_in_64b_mode) begin
								uop[191-:7] = rs;
								uop[184] = 1'b1;
								uop[182-:7] = rt;
								uop[175] = 1'b1;
								uop[164] = 1'b1;
								uop[198-:7] = 7'd104;
								uop[19] = 1'b1;
							end
						6'd31:
							if (w_in_64b_mode) begin
								uop[191-:7] = rs;
								uop[184] = 1'b1;
								uop[182-:7] = rt;
								uop[175] = 1'b1;
								uop[164] = 1'b1;
								uop[198-:7] = 7'd105;
								uop[19] = 1'b1;
							end
						6'd32: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = 7'd14;
							uop[19] = 1'b1;
						end
						6'd33: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd15);
							uop[19] = 1'b1;
						end
						6'd34: begin
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[182-:7] = rt;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd16);
							uop[19] = 1'b1;
						end
						6'd35: begin
							uop[191-:7] = rs;
							uop[184] = 1'b1;
							uop[182-:7] = rt;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd17);
							uop[19] = 1'b1;
						end
						6'd36: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd18);
							uop[19] = 1'b1;
						end
						6'd37:
							if (rs == 'd0) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd73);
								uop[19] = 1'b1;
							end
							else begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[182-:7] = rs;
								uop[175] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd19);
								uop[19] = 1'b1;
							end
						6'd38: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd20);
							uop[19] = 1'b1;
						end
						6'd39: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd21);
							uop[19] = 1'b1;
						end
						6'd42: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd22);
							uop[19] = 1'b1;
						end
						6'd43: begin
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[173-:7] = rd;
							uop[166] = rd != 'd0;
							uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd23);
							uop[19] = 1'b1;
						end
						6'd44:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[182-:7] = rs;
								uop[175] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd82);
								uop[19] = 1'b1;
							end
						6'd45:
							if (w_in_64b_mode) begin
								uop[191-:7] = rt;
								uop[184] = 1'b1;
								uop[182-:7] = rs;
								uop[175] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd83);
								uop[19] = 1'b1;
							end
						6'd46:
							if (w_in_64b_mode) begin
								uop[191-:7] = rs;
								uop[184] = 1'b1;
								uop[182-:7] = rt;
								uop[175] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd84);
								uop[19] = 1'b1;
							end
						6'd47:
							if (w_in_64b_mode) begin
								uop[191-:7] = rs;
								uop[184] = 1'b1;
								uop[182-:7] = rt;
								uop[175] = 1'b1;
								uop[173-:7] = rd;
								uop[166] = rd != 'd0;
								uop[198-:7] = (rd == 'd0 ? 7'd75 : 7'd85);
								uop[19] = 1'b1;
							end
						6'd52: begin
							uop[198-:7] = 7'd60;
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[19] = 1'b1;
						end
						6'd54: begin
							uop[198-:7] = 7'd113;
							uop[191-:7] = rt;
							uop[184] = 1'b1;
							uop[182-:7] = rs;
							uop[175] = 1'b1;
							uop[19] = 1'b1;
						end
						default:
							;
					endcase
				6'd1: begin
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[158] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[18] = 1'b1;
					uop[19] = 1'b1;
					uop[20] = insn_pred;
					case (rt[4:0])
						'd0: uop[198-:7] = 7'd54;
						'd1: uop[198-:7] = 7'd55;
						'd2: begin
							uop[198-:7] = 7'd56;
							uop[157] = 1'b1;
						end
						'd3: begin
							uop[198-:7] = 7'd57;
							uop[157] = 1'b1;
						end
						'd17: begin
							uop[198-:7] = (rs == 'd0 ? 7'd65 : 7'd66);
							uop[166] = 1'b1;
							uop[173-:7] = 'd31;
							uop[182-:7] = 'd31;
							uop[175] = (rs == 'd0 ? 1'b0 : 1'b1);
						end
						default: uop[198-:7] = 7'd117;
					endcase
				end
				6'd2: begin
					uop[198-:7] = 7'd38;
					uop[18] = 1'b1;
					uop[19] = 1'b1;
					uop[158] = 1'b1;
				end
				6'd3: begin
					uop[198-:7] = 7'd39;
					uop[158] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[140-:48] = {{38 {1'b0}}, insn[25:16]};
					uop[166] = 1'b1;
					uop[173-:7] = 'd31;
					uop[20] = 1'b1;
					uop[18] = 1'b1;
					uop[19] = 1'b1;
				end
				6'd4: begin
					uop[198-:7] = 7'd26;
					uop[166] = 1'b0;
					uop[173-:7] = 'd0;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[158] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[20] = insn_pred;
					uop[18] = 1'b1;
					uop[19] = 1'b1;
				end
				6'd5: begin
					uop[198-:7] = 7'd27;
					uop[166] = 1'b0;
					uop[173-:7] = 'd0;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[158] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[20] = insn_pred;
					uop[18] = 1'b1;
					uop[19] = 1'b1;
				end
				6'd6: begin
					uop[198-:7] = 7'd28;
					uop[166] = 1'b0;
					uop[173-:7] = 'd0;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[158] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[20] = insn_pred;
					uop[18] = 1'b1;
					uop[19] = 1'b1;
				end
				6'd7: begin
					uop[198-:7] = 7'd29;
					uop[166] = 1'b0;
					uop[173-:7] = 'd0;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[158] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[20] = insn_pred;
					uop[18] = 1'b1;
					uop[19] = 1'b1;
				end
				6'd8: begin
					uop[198-:7] = 7'd30;
					uop[184] = 1'b1;
					uop[191-:7] = rs;
					uop[166] = rt != 'd0;
					uop[19] = 1'b1;
					uop[173-:7] = rt;
					uop[156-:16] = insn[15:0];
				end
				6'd9:
					if (rs == 'd0) begin
						uop[198-:7] = (rt == 'd0 ? 7'd75 : 7'd72);
						uop[166] = rt != 'd0;
						uop[19] = 1'b1;
						uop[173-:7] = rt;
						uop[156-:16] = insn[15:0];
					end
					else begin
						uop[198-:7] = (rt == 'd0 ? 7'd75 : 7'd31);
						uop[184] = 1'b1;
						uop[191-:7] = rs;
						uop[166] = rt != 'd0;
						uop[19] = 1'b1;
						uop[173-:7] = rt;
						uop[156-:16] = insn[15:0];
					end
				6'd10: begin
					uop[198-:7] = (rt == 'd0 ? 7'd75 : 7'd32);
					uop[184] = 1'b1;
					uop[191-:7] = rs;
					uop[166] = rt != 'd0;
					uop[173-:7] = rt;
					uop[19] = 1'b1;
					uop[156-:16] = insn[15:0];
				end
				6'd11: begin
					uop[198-:7] = (rt == 'd0 ? 7'd75 : 7'd33);
					uop[184] = 1'b1;
					uop[191-:7] = rs;
					uop[166] = rt != 'd0;
					uop[173-:7] = rt;
					uop[19] = 1'b1;
					uop[156-:16] = insn[15:0];
				end
				6'd12: begin
					uop[198-:7] = (rt == 'd0 ? 7'd75 : 7'd34);
					uop[184] = 1'b1;
					uop[191-:7] = rs;
					uop[166] = rt != 'd0;
					uop[173-:7] = rt;
					uop[19] = 1'b1;
					uop[156-:16] = insn[15:0];
				end
				6'd13: begin
					uop[198-:7] = (rt == 'd0 ? 7'd75 : 7'd35);
					uop[184] = 1'b1;
					uop[191-:7] = rs;
					uop[166] = rt != 'd0;
					uop[173-:7] = rt;
					uop[19] = 1'b1;
					uop[156-:16] = insn[15:0];
				end
				6'd14: begin
					uop[198-:7] = (rt == 'd0 ? 7'd75 : 7'd36);
					uop[184] = 1'b1;
					uop[191-:7] = rs;
					uop[166] = rt != 'd0;
					uop[173-:7] = rt;
					uop[19] = 1'b1;
					uop[156-:16] = insn[15:0];
				end
				6'd15: begin
					uop[198-:7] = (rt == 'd0 ? 7'd75 : 7'd37);
					uop[166] = rt != 'd0;
					uop[173-:7] = rt;
					uop[19] = 1'b1;
					uop[156-:16] = insn[15:0];
				end
				6'd16:
					if (((insn[25] == 1'b1) & (insn[24:6] == 19'd0)) & (insn[5:0] == 6'd1)) begin
						uop[198-:7] = 7'd78;
						uop[19] = 1'b1;
						uop[21] = 1'b1;
					end
					else if (((insn[25] == 1'b1) & (insn[24:6] == 19'd0)) & (insn[5:0] == 6'd2)) begin
						uop[198-:7] = 7'd79;
						uop[19] = 1'b1;
						uop[21] = 1'b1;
					end
					else if (((insn[25] == 1'b1) & (insn[24:6] == 19'd0)) & (insn[5:0] == 6'd6)) begin
						uop[198-:7] = 7'd80;
						uop[19] = 1'b1;
						uop[21] = 1'b1;
					end
					else if (((insn[25] == 1'b1) & (insn[24:6] == 19'd0)) & (insn[5:0] == 6'd8)) begin
						uop[198-:7] = 7'd81;
						uop[17] = 1'b1;
					end
					else if ((insn[25:21] == 5'd0) & (insn[10:0] == 'd0)) begin
						uop[198-:7] = 7'd40;
						uop[173-:7] = rt;
						uop[166] = 1'b1;
						uop[191-:7] = rd;
						uop[19] = 1'b1;
						uop[21] = 1'b1;
					end
					else if ((insn[25:21] == 5'd1) & (insn[10:0] == 'd0)) begin
						uop[198-:7] = 7'd99;
						uop[173-:7] = rt;
						uop[166] = 1'b1;
						uop[191-:7] = rd;
						uop[19] = 1'b1;
						uop[21] = 1'b1;
					end
					else if ((insn[25:21] == 5'd4) & (insn[10:0] == 'd0)) begin
						uop[198-:7] = 7'd41;
						uop[173-:7] = rd;
						uop[191-:7] = rt;
						uop[184] = 1'b1;
						uop[158] = 1'b0;
						uop[19] = 1'b1;
						uop[21] = 1'b1;
					end
					else if ((insn[25:21] == 5'd5) & (insn[10:0] == 'd0)) begin
						uop[198-:7] = 7'd100;
						uop[173-:7] = rd;
						uop[191-:7] = rt;
						uop[184] = 1'b1;
						uop[158] = 1'b0;
						uop[19] = 1'b1;
						uop[21] = 1'b1;
					end
					else if (insn[25:0] == 26'b10000000000000000000011000) begin
						uop[198-:7] = 7'd76;
						uop[21] = 1'b1;
						uop[158] = 1'b0;
						uop[19] = 1'b1;
					end
				6'd17:
					if ((insn[25:21] == 5'd0) && (insn[10:0] == 11'd0)) begin
						uop[173-:7] = rt;
						uop[166] = 1'b1;
						uop[198-:7] = 7'd71;
						uop[182-:7] = {{ZP {1'b0}}, rd[4:1], 1'b0};
						uop[140-:48] = {{47 {1'b0}}, rd[0]};
						uop[174] = 1'b1;
						uop[17] = 1'b1;
					end
					else if ((insn[25:21] == 5'd4) && (insn[10:0] == 11'd0)) begin
						uop[191-:7] = rt;
						uop[184] = 1'b1;
						uop[198-:7] = 7'd70;
						uop[173-:7] = {{ZP {1'b0}}, rd[4:1], 1'b0};
						uop[182-:7] = {{ZP {1'b0}}, rd[4:1], 1'b0};
						uop[140-:48] = {{47 {1'b0}}, rd[0]};
						uop[174] = 1;
						uop[165] = 1'b1;
						uop[17] = 1'b1;
					end
				6'd20: begin
					uop[198-:7] = 7'd52;
					uop[166] = 1'b0;
					uop[173-:7] = 'd0;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[158] = 1'b1;
					uop[157] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[18] = 1'b1;
					uop[20] = insn_pred;
					uop[19] = 1'b1;
				end
				6'd21: begin
					uop[198-:7] = 7'd53;
					uop[166] = 1'b0;
					uop[173-:7] = 'd0;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[158] = 1'b1;
					uop[157] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[18] = 1'b1;
					uop[20] = insn_pred;
					uop[19] = 1'b1;
				end
				6'd22: begin
					uop[198-:7] = 7'd59;
					uop[166] = 1'b0;
					uop[173-:7] = 'd0;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[158] = 1'b1;
					uop[157] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[18] = 1'b1;
					uop[20] = insn_pred;
					uop[19] = 1'b1;
				end
				6'd23: begin
					uop[198-:7] = 7'd58;
					uop[166] = 1'b0;
					uop[173-:7] = 'd0;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[158] = 1'b1;
					uop[157] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[18] = 1'b1;
					uop[20] = insn_pred;
					uop[19] = 1'b1;
				end
				6'd25:
					if (w_in_64b_mode) begin
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[173-:7] = rt;
						uop[166] = rt != 'd0;
						uop[198-:7] = 7'd86;
						uop[156-:16] = insn[15:0];
						uop[19] = 1'b1;
					end
				6'd32: begin
					uop[198-:7] = 7'd45;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[173-:7] = rt;
					uop[166] = rt != 'd0;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
				end
				6'd33: begin
					uop[198-:7] = 7'd47;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[173-:7] = rt;
					uop[166] = rt != 'd0;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
				end
				6'd26:
					if (w_in_64b_mode) begin
						uop[198-:7] = 7'd106;
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[182-:7] = rt;
						uop[175] = 1'b1;
						uop[173-:7] = rt;
						uop[166] = rt != 'd0;
						uop[156-:16] = insn[15:0];
						uop[17] = 1'b1;
					end
				6'd27:
					if (w_in_64b_mode) begin
						uop[198-:7] = 7'd107;
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[182-:7] = rt;
						uop[175] = 1'b1;
						uop[173-:7] = rt;
						uop[166] = rt != 'd0;
						uop[156-:16] = insn[15:0];
						uop[17] = 1'b1;
					end
				6'd34: begin
					uop[198-:7] = 7'd61;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[173-:7] = rt;
					uop[166] = rt != 'd0;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
				end
				6'd35: begin
					uop[198-:7] = 7'd44;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[173-:7] = rt;
					uop[166] = rt != 'd0;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
				end
				6'd36: begin
					uop[198-:7] = 7'd46;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[173-:7] = rt;
					uop[166] = rt != 'd0;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
				end
				6'd37: begin
					uop[198-:7] = 7'd48;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[173-:7] = rt;
					uop[166] = rt != 'd0;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
				end
				6'd38: begin
					uop[198-:7] = 7'd62;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[173-:7] = rt;
					uop[166] = rt != 'd0;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
				end
				6'd39:
					if (w_in_64b_mode) begin
						uop[198-:7] = 7'd101;
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[173-:7] = rt;
						uop[166] = rt != 'd0;
						uop[156-:16] = insn[15:0];
						uop[17] = 1'b1;
					end
				6'd40: begin
					uop[198-:7] = 7'd49;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
					uop[16] = 1'b1;
				end
				6'd41: begin
					uop[198-:7] = 7'd50;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
					uop[16] = 1'b1;
				end
				6'd42: begin
					uop[198-:7] = 7'd63;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
					uop[16] = 1'b1;
				end
				6'd43: begin
					uop[198-:7] = 7'd51;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
					uop[16] = 1'b1;
				end
				6'd44:
					if (w_in_64b_mode) begin
						uop[198-:7] = 7'd108;
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[182-:7] = rt;
						uop[175] = 1'b1;
						uop[156-:16] = insn[15:0];
						uop[17] = 1'b1;
						uop[16] = 1'b1;
					end
				6'd45:
					if (w_in_64b_mode) begin
						uop[198-:7] = 7'd109;
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[182-:7] = rt;
						uop[175] = 1'b1;
						uop[156-:16] = insn[15:0];
						uop[17] = 1'b1;
						uop[16] = 1'b1;
					end
				6'd46: begin
					uop[198-:7] = 7'd64;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
					uop[16] = 1'b1;
				end
				6'd47: begin
					uop[198-:7] = 7'd75;
					uop[19] = 1'b1;
				end
				6'd48: begin
					uop[198-:7] = 7'd110;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[173-:7] = rt;
					uop[166] = rt != 'd0;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
					uop[21] = 1'b1;
				end
				6'd52:
					if (w_in_64b_mode) begin
						uop[198-:7] = 7'd111;
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[173-:7] = rt;
						uop[166] = rt != 'd0;
						uop[156-:16] = insn[15:0];
						uop[17] = 1'b1;
						uop[21] = 1'b1;
					end
				6'd56: begin
					uop[198-:7] = 7'd68;
					uop[191-:7] = rs;
					uop[184] = 1'b1;
					uop[182-:7] = rt;
					uop[175] = 1'b1;
					uop[173-:7] = rt;
					uop[166] = rt != 'd0;
					uop[156-:16] = insn[15:0];
					uop[17] = 1'b1;
					uop[16] = 1'b1;
					uop[21] = 1'b1;
				end
				6'd60:
					if (w_in_64b_mode) begin
						uop[198-:7] = 7'd112;
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[182-:7] = rt;
						uop[175] = 1'b1;
						uop[173-:7] = rt;
						uop[166] = rt != 'd0;
						uop[156-:16] = insn[15:0];
						uop[17] = 1'b1;
						uop[16] = 1'b1;
						uop[21] = 1'b1;
					end
				6'd51: begin
					uop[198-:7] = 7'd75;
					uop[19] = 1'b1;
				end
				6'd55:
					if (w_in_64b_mode) begin
						uop[198-:7] = 7'd88;
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[173-:7] = rt;
						uop[166] = rt != 'd0;
						uop[156-:16] = insn[15:0];
						uop[17] = 1'b1;
					end
				6'd63:
					if (w_in_64b_mode) begin
						uop[198-:7] = 7'd89;
						uop[191-:7] = rs;
						uop[184] = 1'b1;
						uop[182-:7] = rt;
						uop[175] = 1'b1;
						uop[156-:16] = insn[15:0];
						uop[17] = 1'b1;
						uop[16] = 1'b1;
					end
				default:
					;
			endcase
	end
	initial _sv2v_0 = 0;
endmodule

module l1d (
	clk,
	reset,
	asid,
	tlb_entry_in,
	tlb_entry_in_valid,
	state,
	in_kernel_mode,
	in_supervisor_mode,
	in_user_mode,
	head_of_rob_ptr,
	head_of_rob_ptr_valid,
	head_of_rob_has_delay_slot,
	retired_rob_ptr_valid,
	retired_rob_ptr_two_valid,
	retired_rob_ptr,
	retired_rob_ptr_two,
	restart_valid,
	clr_link_reg,
	memq_empty,
	drain_ds_complete,
	dead_rob_mask,
	flush_req,
	flush_complete,
	flush_cl_req,
	flush_cl_addr,
	core_mem_req_valid,
	core_mem_req,
	core_store_data_valid,
	core_store_data,
	core_store_data_ack,
	core_mem_req_ack,
	core_mem_rsp,
	core_mem_rsp_valid,
	mem_req_ack,
	mem_req_valid,
	mem_req_addr,
	mem_req_store_data,
	mem_req_opcode,
	mem_req_cacheable,
	mem_req_mask,
	mem_rsp_valid,
	mem_rsp_load_data,
	cache_accesses,
	cache_hits
);
	reg _sv2v_0;
	localparam L1D_NUM_SETS = 256;
	localparam L1D_CL_LEN = 16;
	localparam L1D_CL_LEN_BITS = 128;
	input wire clk;
	input wire reset;
	input wire [7:0] asid;
	input wire [122:0] tlb_entry_in;
	input wire tlb_entry_in_valid;
	output wire [3:0] state;
	input wire in_kernel_mode;
	input wire in_supervisor_mode;
	input wire in_user_mode;
	input wire [4:0] head_of_rob_ptr;
	input wire head_of_rob_ptr_valid;
	input wire head_of_rob_has_delay_slot;
	input wire retired_rob_ptr_valid;
	input wire retired_rob_ptr_two_valid;
	input wire [4:0] retired_rob_ptr;
	input wire [4:0] retired_rob_ptr_two;
	input wire restart_valid;
	input wire clr_link_reg;
	output reg memq_empty;
	input wire drain_ds_complete;
	input wire [31:0] dead_rob_mask;
	reg [63:0] r_tlb_addr;
	reg [63:0] n_tlb_addr;
	input wire flush_cl_req;
	input wire [63:0] flush_cl_addr;
	input wire flush_req;
	output wire flush_complete;
	input wire core_mem_req_valid;
	input wire [150:0] core_mem_req;
	input wire core_store_data_valid;
	input wire [68:0] core_store_data;
	output reg core_store_data_ack;
	output reg core_mem_req_ack;
	output wire [87:0] core_mem_rsp;
	output wire core_mem_rsp_valid;
	input wire mem_req_ack;
	output wire mem_req_valid;
	output wire [63:0] mem_req_addr;
	output wire [127:0] mem_req_store_data;
	output wire [4:0] mem_req_opcode;
	output wire mem_req_cacheable;
	output wire [15:0] mem_req_mask;
	input wire mem_rsp_valid;
	input wire [127:0] mem_rsp_load_data;
	output wire [63:0] cache_accesses;
	output wire [63:0] cache_hits;
	localparam LG_WORDS_PER_CL = 2;
	localparam LG_DWORDS_PER_CL = 1;
	localparam WORDS_PER_CL = 4;
	localparam N_TAG_BITS = 52;
	localparam IDX_START = 4;
	localparam IDX_STOP = 12;
	localparam WORD_START = 2;
	localparam WORD_STOP = 4;
	localparam DWORD_START = 3;
	localparam DWORD_STOP = 4;
	localparam N_MQ_ENTRIES = 8;
	function [15:0] make_mask;
		input reg [150:0] r;
		reg [15:0] t_m;
		reg [15:0] m;
		reg b;
		reg s;
		reg w;
		reg d;
		reg lwl_lwr;
		reg swl_swr;
		reg [3:0] swl;
		reg [3:0] swr;
		reg [0:1] _sv2v_jump;
		begin
			_sv2v_jump = 2'b00;
			swr = (r[88:87] == 'd0 ? 4'b0001 : (r[88:87] == 'd1 ? 4'b0011 : (r[88:87] == 'd2 ? 4'b0111 : 4'b1111)));
			swl = (r[88:87] == 'd3 ? 4'b1000 : (r[88:87] == 'd2 ? 4'b1100 : (r[88:87] == 'd1 ? 4'b1110 : 4'b0000)));
			swl_swr = (r[84-:5] == 5'd8) | (r[84-:5] == 5'd9);
			lwl_lwr = (r[84-:5] == 5'd10) | (r[84-:5] == 5'd11);
			if ((((((((r[84-:5] == 5'd17) || (r[84-:5] == 5'd18)) || (r[84-:5] == 5'd19)) || (r[84-:5] == 5'd20)) || (r[84-:5] == 5'd22)) || (r[84-:5] == 5'd23)) || (r[84-:5] == 5'd14)) || (r[84-:5] == 5'd15)) begin
				make_mask = 16'h00ff << {r[90], 3'b000};
				_sv2v_jump = 2'b11;
			end
			if (_sv2v_jump == 2'b00) begin
				b = ((r[84-:5] == 5'd5) | (r[84-:5] == 5'd0)) | (r[84-:5] == 5'd1);
				s = ((r[84-:5] == 5'd6) | (r[84-:5] == 5'd2)) | (r[84-:5] == 5'd3);
				w = ((((r[84-:5] == 5'd7) | (r[84-:5] == 5'd4)) | (r[84-:5] == 5'd21)) | (r[84-:5] == 5'd12)) | lwl_lwr;
				t_m = (b ? 16'h0001 : (s ? 16'h0003 : (w ? 16'h000f : (r[84-:5] == 5'd9 ? {12'd0, swl} : (r[84-:5] == 5'd8 ? {12'd0, swr} : 16'hffff)))));
				m = t_m << (lwl_lwr | swl_swr ? {r[90:89], 2'd0} : r[90:87]);
				make_mask = m;
				_sv2v_jump = 2'b11;
			end
		end
	endfunction
	function [127:0] merge_cl32;
		input reg [127:0] cl;
		input reg [31:0] w32;
		input reg [1:0] pos;
		reg [127:0] cl_out;
		begin
			case (pos)
				2'd0: cl_out = {cl[127:32], w32};
				2'd1: cl_out = {cl[127:64], w32, cl[31:0]};
				2'd2: cl_out = {cl[127:96], w32, cl[63:0]};
				2'd3: cl_out = {w32, cl[95:0]};
			endcase
			merge_cl32 = cl_out;
		end
	endfunction
	function [31:0] select_cl32;
		input reg [127:0] cl;
		input reg [1:0] pos;
		reg [31:0] w32;
		begin
			case (pos)
				2'd0: w32 = cl[31:0];
				2'd1: w32 = cl[63:32];
				2'd2: w32 = cl[95:64];
				2'd3: w32 = cl[127:96];
			endcase
			select_cl32 = w32;
		end
	endfunction
	function [63:0] bswap64;
		input reg [63:0] x;
		bswap64 = {x[7:0], x[15:8], x[23:16], x[31:24], x[39:32], x[47:40], x[55:48], x[63:56]};
	endfunction
	function [127:0] merge_cl64;
		input reg [127:0] cl;
		input reg [63:0] w64;
		input reg [0:0] pos;
		reg [127:0] cl_out;
		begin
			case (pos)
				1'd0: cl_out = {cl[127:64], w64};
				1'd1: cl_out = {w64, cl[63:0]};
			endcase
			merge_cl64 = cl_out;
		end
	endfunction
	function [63:0] select_cl64;
		input reg [127:0] cl;
		input reg [0:0] pos;
		reg [63:0] w64;
		begin
			case (pos)
				1'd0: w64 = cl[63:0];
				1'd1: w64 = cl[127:64];
			endcase
			select_cl64 = w64;
		end
	endfunction
	reg r_got_req;
	reg r_last_wr;
	reg n_last_wr;
	reg r_last_rd;
	reg n_last_rd;
	reg r_got_req2;
	reg r_last_wr2;
	reg n_last_wr2;
	reg r_last_rd2;
	reg n_last_rd2;
	reg rr_got_req;
	reg rr_last_wr;
	reg rr_is_retry;
	reg rr_did_reload;
	reg r_lock_cache;
	reg n_lock_cache;
	reg [3:0] r_n_inflight;
	reg [7:0] t_cache_idx;
	reg [7:0] r_cache_idx;
	reg [7:0] rr_cache_idx;
	reg [51:0] t_cache_tag;
	reg [51:0] r_cache_tag;
	wire [51:0] r_tag_out;
	reg [51:0] rr_cache_tag;
	wire r_valid_out;
	wire r_dirty_out;
	wire [127:0] r_array_out;
	reg [127:0] t_data;
	reg [127:0] t_data2;
	reg [7:0] t_cache_idx2;
	reg [7:0] r_cache_idx2;
	reg [51:0] t_cache_tag2;
	reg [51:0] r_cache_tag2;
	wire [51:0] r_tag_out2;
	wire r_valid_out2;
	wire r_dirty_out2;
	wire [127:0] r_array_out2;
	reg [7:0] t_miss_idx;
	reg [7:0] r_miss_idx;
	reg [63:0] t_miss_addr;
	reg [63:0] r_miss_addr;
	reg [7:0] t_array_wr_addr;
	reg [127:0] t_array_wr_data;
	reg [127:0] r_array_wr_data;
	reg t_array_wr_en;
	reg r_flush_req;
	reg n_flush_req;
	reg r_flush_cl_req;
	reg n_flush_cl_req;
	reg r_flush_complete;
	reg n_flush_complete;
	wire [31:0] t_array_out_b32 [3:0];
	reg [31:0] t_w32;
	reg [31:0] t_bswap_w32;
	reg [31:0] t_w32_2;
	reg [31:0] t_bswap_w32_2;
	reg t_got_rd_retry;
	reg t_port2_hit_cache;
	reg t_mark_invalid;
	reg t_wr_array;
	reg t_hit_cache;
	reg t_rsp_dst_valid;
	reg t_rsp_fp_dst_valid;
	reg [63:0] t_rsp_data;
	reg t_hit_cache2;
	reg t_rsp_dst_valid2;
	reg t_rsp_fp_dst_valid2;
	reg [63:0] t_rsp_data2;
	reg [127:0] t_array_data;
	reg [63:0] t_addr;
	reg t_got_req;
	reg t_got_req2;
	reg t_got_miss;
	reg t_push_miss;
	reg t_mh_block;
	reg t_cm_block;
	wire t_cm_block2;
	reg t_cm_block_stall;
	reg r_must_forward;
	reg r_must_forward2;
	reg n_inhibit_write;
	reg r_inhibit_write;
	reg t_got_non_mem;
	reg r_got_non_mem;
	reg t_incr_busy;
	reg t_force_clear_busy;
	reg n_stall_store;
	reg r_stall_store;
	reg n_is_retry;
	reg r_is_retry;
	reg r_q_priority;
	reg n_q_priority;
	reg n_core_mem_rsp_valid;
	reg r_core_mem_rsp_valid;
	reg [87:0] n_core_mem_rsp;
	reg [87:0] r_core_mem_rsp;
	wire [5:0] w_tlb_index;
	wire w_tlb_dirty;
	wire w_tlb_valid;
	wire w_tlb_hit;
	reg [150:0] n_req;
	reg [150:0] r_req;
	wire [150:0] t_req;
	reg [150:0] n_req2;
	reg [150:0] r_req2;
	reg [150:0] r_mem_q [7:0];
	reg [3:0] r_mq_head_ptr;
	reg [3:0] n_mq_head_ptr;
	reg [3:0] r_mq_tail_ptr;
	reg [3:0] n_mq_tail_ptr;
	reg [3:0] t_mq_tail_ptr_plus_one;
	reg [7:0] r_mq_addr_valid;
	reg [7:0] r_mq_addr [7:0];
	wire [150:0] t_mem_tail;
	reg [150:0] t_mem_head;
	reg mem_q_full;
	reg mem_q_empty;
	reg mem_q_almost_full;
	reg [3:0] r_state;
	reg [3:0] n_state;
	reg t_pop_mq;
	reg n_reload_issue;
	reg r_reload_issue;
	reg n_did_reload;
	reg r_did_reload;
	reg n_uncache_wb_dirty;
	reg r_uncache_wb_dirty;
	assign state = r_state;
	reg r_mem_req_cacheable;
	reg n_mem_req_cacheable;
	reg [15:0] t_mem_req_mask;
	reg [15:0] r_mem_req_mask;
	reg [15:0] n_mem_req_mask;
	reg r_mem_req_valid;
	reg n_mem_req_valid;
	reg [63:0] r_mem_req_addr;
	reg [63:0] n_mem_req_addr;
	reg [127:0] r_mem_req_store_data;
	reg [127:0] n_mem_req_store_data;
	reg [4:0] r_mem_req_opcode;
	reg [4:0] n_mem_req_opcode;
	reg [63:0] n_cache_accesses;
	reg [63:0] r_cache_accesses;
	reg [63:0] n_cache_hits;
	reg [63:0] r_cache_hits;
	wire [63:0] w_mapped_addr;
	reg [31:0] r_cycle;
	assign flush_complete = r_flush_complete;
	assign mem_req_addr = r_mem_req_addr;
	assign mem_req_store_data = r_mem_req_store_data;
	assign mem_req_opcode = r_mem_req_opcode;
	assign mem_req_valid = r_mem_req_valid;
	assign mem_req_cacheable = r_mem_req_cacheable;
	assign mem_req_mask = r_mem_req_mask;
	assign core_mem_rsp_valid = n_core_mem_rsp_valid;
	assign core_mem_rsp = n_core_mem_rsp;
	assign cache_accesses = r_cache_accesses;
	assign cache_hits = r_cache_hits;
	wire w_cacheable_mem_rsp_valid = (r_state == 4'd3) & mem_rsp_valid;
	always @(posedge clk) r_cycle <= (reset ? 'd0 : r_cycle + 'd1);
	always @(posedge clk)
		if (reset) begin
			r_mq_head_ptr <= 'd0;
			r_mq_tail_ptr <= 'd0;
		end
		else begin
			r_mq_head_ptr <= n_mq_head_ptr;
			r_mq_tail_ptr <= n_mq_tail_ptr;
		end
	localparam N_ROB_ENTRIES = 32;
	reg [1:0] r_graduated [31:0];
	reg [31:0] r_missed;
	reg [31:0] r_rob_inflight;
	reg r_link_reg_val;
	reg [63:0] r_link_reg;
	wire w_match_link = r_link_reg_val && (r_link_reg == {r_req[150:91], {4 {1'b0}}});
	wire w_match_link2 = r_link_reg_val && (r_link_reg == {r_req2[150:91], {4 {1'b0}}});
	reg r_sc_should_write;
	reg t_reset_graduated;
	always @(posedge clk)
		if (reset) begin : sv2v_autoblock_1
			integer i;
			for (i = 0; i < N_ROB_ENTRIES; i = i + 1)
				r_graduated[i] <= 2'b00;
		end
		else begin
			if (retired_rob_ptr_valid && (r_graduated[retired_rob_ptr] == 2'b01))
				r_graduated[retired_rob_ptr] <= 2'b10;
			if (retired_rob_ptr_two_valid && (r_graduated[retired_rob_ptr_two] == 2'b01))
				r_graduated[retired_rob_ptr_two] <= 2'b10;
			if (t_incr_busy)
				r_graduated[r_req2[76-:5]] <= 2'b01;
			if (t_reset_graduated)
				r_graduated[r_req[76-:5]] <= 2'b00;
			if (t_force_clear_busy)
				r_graduated[t_mem_head[76-:5]] <= 2'b00;
		end
	always @(posedge clk)
		if (reset || clr_link_reg) begin
			r_link_reg_val <= 1'b0;
			r_link_reg <= 'd0;
		end
		else if ((n_core_mem_rsp_valid && r_got_req2) && ((r_req2[84-:5] == 5'd21) || (r_req2[84-:5] == 5'd22))) begin
			r_link_reg_val <= 1'b1;
			r_link_reg <= {r_req2[150:91], {4 {1'b0}}};
		end
		else if ((n_core_mem_rsp_valid && r_got_req2) && ((r_req2[84-:5] == 5'd12) || (r_req2[84-:5] == 5'd23)))
			r_link_reg_val <= 1'b0;
		else if (n_core_mem_rsp_valid && ((r_req[84-:5] == 5'd21) || (r_req[84-:5] == 5'd22))) begin
			r_link_reg_val <= 1'b1;
			r_link_reg <= {r_req[150:91], {4 {1'b0}}};
		end
	always @(posedge clk)
		if (reset)
			r_sc_should_write <= 1'b0;
		else if ((n_core_mem_rsp_valid && r_got_req2) && ((r_req2[84-:5] == 5'd12) || (r_req2[84-:5] == 5'd23)))
			r_sc_should_write <= w_match_link2;
	always @(posedge clk)
		if (reset)
			r_n_inflight <= 'd0;
		else if ((core_mem_req_valid && core_mem_req_ack) && !core_mem_rsp_valid)
			r_n_inflight <= r_n_inflight + 'd1;
		else if (!(core_mem_req_valid && core_mem_req_ack) && core_mem_rsp_valid)
			r_n_inflight <= r_n_inflight - 'd1;
	always @(*) begin
		if (_sv2v_0)
			;
		n_mq_head_ptr = r_mq_head_ptr;
		n_mq_tail_ptr = r_mq_tail_ptr;
		t_mq_tail_ptr_plus_one = r_mq_tail_ptr + 'd1;
		if (t_push_miss)
			n_mq_tail_ptr = r_mq_tail_ptr + 'd1;
		if (t_pop_mq)
			n_mq_head_ptr = r_mq_head_ptr + 'd1;
		t_mem_head = r_mem_q[r_mq_head_ptr[2:0]];
		mem_q_empty = r_mq_head_ptr == r_mq_tail_ptr;
		mem_q_full = (r_mq_head_ptr != r_mq_tail_ptr) && (r_mq_head_ptr[2:0] == r_mq_tail_ptr[2:0]);
		mem_q_almost_full = (r_mq_head_ptr != t_mq_tail_ptr_plus_one) && (r_mq_head_ptr[2:0] == t_mq_tail_ptr_plus_one[2:0]);
	end
	always @(posedge clk)
		if (reset)
			r_missed <= 'd0;
		else if (t_push_miss)
			r_missed[r_req2[76-:5]] <= !t_port2_hit_cache;
	always @(posedge clk)
		if (reset)
			r_rob_inflight <= 'd0;
		else begin
			if ((r_got_req2 && !drain_ds_complete) && t_push_miss) begin
				if (r_rob_inflight[r_req2[76-:5]] == 1'b1)
					$display("entry %d should not be inflight\n", r_req2[76-:5]);
				r_rob_inflight[r_req2[76-:5]] <= 1'b1;
			end
			if ((r_got_req && r_valid_out) && (r_tag_out == r_cache_tag))
				r_rob_inflight[r_req[76-:5]] <= 1'b0;
			else if (((r_state == 4'd11) | (r_state == 4'd12)) & mem_rsp_valid)
				r_rob_inflight[r_req[76-:5]] <= 1'b0;
			if (t_force_clear_busy)
				r_rob_inflight[t_mem_head[76-:5]] <= 1'b0;
		end
	reg [150:0] t_remapped_req2;
	always @(*) begin
		if (_sv2v_0)
			;
		t_remapped_req2 = r_req2;
		t_remapped_req2[150-:64] = w_mapped_addr;
	end
	always @(posedge clk)
		if (t_push_miss) begin
			r_mem_q[r_mq_tail_ptr[2:0]] <= r_req2;
			r_mq_addr[r_mq_tail_ptr[2:0]] <= t_remapped_req2[98:91];
		end
	always @(posedge clk)
		if (reset)
			r_mq_addr_valid <= 'd0;
		else begin
			if (t_push_miss)
				r_mq_addr_valid[r_mq_tail_ptr[2:0]] <= 1'b1;
			if (t_pop_mq)
				r_mq_addr_valid[r_mq_head_ptr[2:0]] <= 1'b0;
		end
	wire [7:0] w_hit_busy_addrs;
	reg [7:0] r_hit_busy_addrs;
	reg r_hit_busy_addr;
	wire [7:0] w_hit_busy_addrs2;
	reg [7:0] r_hit_busy_addrs2;
	reg r_hit_busy_addr2;
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < N_MQ_ENTRIES; _gv_i_1 = _gv_i_1 + 1) begin : genblk1
			localparam i = _gv_i_1;
			assign w_hit_busy_addrs[i] = (t_pop_mq && (r_mq_head_ptr[2:0] == i) ? 1'b0 : (r_mq_addr_valid[i] ? r_mq_addr[i] == t_cache_idx : 1'b0));
			assign w_hit_busy_addrs2[i] = (r_mq_addr_valid[i] ? r_mq_addr[i] == t_cache_idx2 : 1'b0);
		end
	endgenerate
	always @(posedge clk) begin
		r_hit_busy_addr <= (reset ? 1'b0 : |w_hit_busy_addrs);
		r_hit_busy_addrs <= (t_got_req ? w_hit_busy_addrs : {N_MQ_ENTRIES {1'b1}});
		r_hit_busy_addr2 <= (reset ? 1'b0 : |w_hit_busy_addrs2);
		r_hit_busy_addrs2 <= (t_got_req2 ? w_hit_busy_addrs2 : {N_MQ_ENTRIES {1'b1}});
	end
	always @(posedge clk) r_array_wr_data <= t_array_wr_data;
	always @(posedge clk)
		if (reset) begin
			r_reload_issue <= 1'b0;
			r_did_reload <= 1'b0;
			r_stall_store <= 1'b0;
			r_is_retry <= 1'b0;
			r_flush_complete <= 1'b0;
			r_flush_req <= 1'b0;
			r_flush_cl_req <= 1'b0;
			r_tlb_addr <= 'd0;
			r_cache_idx <= 'd0;
			r_cache_tag <= 'd0;
			r_cache_idx2 <= 'd0;
			r_cache_tag2 <= 'd0;
			rr_cache_idx <= 'd0;
			rr_cache_tag <= 'd0;
			r_miss_addr <= 'd0;
			r_miss_idx <= 'd0;
			r_got_req <= 1'b0;
			r_got_req2 <= 1'b0;
			rr_got_req <= 1'b0;
			r_lock_cache <= 1'b0;
			rr_is_retry <= 1'b0;
			rr_did_reload <= 1'b0;
			rr_last_wr <= 1'b0;
			r_got_non_mem <= 1'b0;
			r_last_wr <= 1'b0;
			r_last_rd <= 1'b0;
			r_last_wr2 <= 1'b0;
			r_last_rd2 <= 1'b0;
			r_state <= 4'd0;
			r_mem_req_valid <= 1'b0;
			r_mem_req_cacheable <= 1'b0;
			r_mem_req_mask <= 'd0;
			r_mem_req_addr <= 'd0;
			r_mem_req_store_data <= 'd0;
			r_mem_req_opcode <= 'd0;
			r_core_mem_rsp_valid <= 1'b0;
			r_cache_hits <= 'd0;
			r_cache_accesses <= 'd0;
			r_inhibit_write <= 1'b0;
			r_uncache_wb_dirty <= 1'b0;
			memq_empty <= 1'b1;
			r_q_priority <= 1'b0;
			r_must_forward <= 1'b0;
			r_must_forward2 <= 1'b0;
		end
		else begin
			r_reload_issue <= n_reload_issue;
			r_did_reload <= n_did_reload;
			r_uncache_wb_dirty <= n_uncache_wb_dirty;
			r_stall_store <= n_stall_store;
			r_is_retry <= n_is_retry;
			r_flush_complete <= n_flush_complete;
			r_flush_req <= n_flush_req;
			r_flush_cl_req <= n_flush_cl_req;
			r_cache_idx <= t_cache_idx;
			r_tlb_addr <= n_tlb_addr;
			r_cache_tag <= t_cache_tag;
			r_cache_idx2 <= t_cache_idx2;
			r_cache_tag2 <= t_cache_tag2;
			rr_cache_idx <= r_cache_idx;
			rr_cache_tag <= r_cache_tag;
			r_miss_idx <= t_miss_idx;
			r_miss_addr <= t_miss_addr;
			r_got_req <= t_got_req;
			r_got_req2 <= t_got_req2;
			rr_got_req <= r_got_req;
			r_lock_cache <= n_lock_cache;
			rr_is_retry <= r_is_retry;
			rr_did_reload <= r_did_reload;
			rr_last_wr <= r_last_wr;
			r_got_non_mem <= t_got_non_mem;
			r_last_wr <= n_last_wr;
			r_last_rd <= n_last_rd;
			r_last_wr2 <= n_last_wr2;
			r_last_rd2 <= n_last_rd2;
			r_state <= n_state;
			r_mem_req_valid <= n_mem_req_valid;
			r_mem_req_cacheable <= n_mem_req_cacheable;
			r_mem_req_mask <= n_mem_req_mask;
			r_mem_req_addr <= n_mem_req_addr;
			r_mem_req_store_data <= n_mem_req_store_data;
			r_mem_req_opcode <= n_mem_req_opcode;
			r_core_mem_rsp_valid <= n_core_mem_rsp_valid;
			r_cache_hits <= n_cache_hits;
			r_cache_accesses <= n_cache_accesses;
			r_inhibit_write <= n_inhibit_write;
			memq_empty <= (((((mem_q_empty && drain_ds_complete) && !core_mem_req_valid) && !t_got_req) && !t_got_req2) && !t_push_miss) && (r_n_inflight == 'd0);
			r_q_priority <= n_q_priority;
			r_must_forward <= t_mh_block & t_pop_mq;
			r_must_forward2 <= t_cm_block & core_mem_req_ack;
		end
	always @(posedge clk) begin
		r_req <= n_req;
		r_req2 <= n_req2;
		r_core_mem_rsp <= n_core_mem_rsp;
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_array_wr_addr = (mem_rsp_valid ? r_mem_req_addr[11:IDX_START] : r_cache_idx);
		t_array_wr_data = (mem_rsp_valid ? mem_rsp_load_data : t_array_data);
		t_array_wr_en = w_cacheable_mem_rsp_valid || t_wr_array;
	end
	ram2r1w #(
		.WIDTH(N_TAG_BITS),
		.LG_DEPTH(8)
	) dc_tag(
		.clk(clk),
		.rd_addr0(t_cache_idx),
		.rd_addr1(t_cache_idx2),
		.wr_addr(r_mem_req_addr[11:IDX_START]),
		.wr_data(r_mem_req_addr[63:IDX_STOP]),
		.wr_en(w_cacheable_mem_rsp_valid),
		.rd_data0(r_tag_out),
		.rd_data1(r_tag_out2)
	);
	ram2r1w #(
		.WIDTH(L1D_CL_LEN_BITS),
		.LG_DEPTH(8)
	) dc_data(
		.clk(clk),
		.rd_addr0(t_cache_idx),
		.rd_addr1(t_cache_idx2),
		.wr_addr(t_array_wr_addr),
		.wr_data(t_array_wr_data),
		.wr_en(t_array_wr_en),
		.rd_data0(r_array_out),
		.rd_data1(r_array_out2)
	);
	reg t_dirty_value;
	reg t_write_dirty_en;
	reg [7:0] t_dirty_wr_addr;
	always @(*) begin
		if (_sv2v_0)
			;
		t_dirty_value = 1'b0;
		t_write_dirty_en = 1'b0;
		t_dirty_wr_addr = r_cache_idx;
		if (t_mark_invalid)
			t_write_dirty_en = 1'b1;
		else if (w_cacheable_mem_rsp_valid) begin
			t_dirty_wr_addr = r_mem_req_addr[11:IDX_START];
			t_write_dirty_en = 1'b1;
		end
		else if (t_wr_array) begin
			t_dirty_value = 1'b1;
			t_write_dirty_en = 1'b1;
		end
	end
	ram2r1w #(
		.WIDTH(1),
		.LG_DEPTH(8)
	) dc_dirty(
		.clk(clk),
		.rd_addr0(t_cache_idx),
		.rd_addr1(t_cache_idx2),
		.wr_addr(t_dirty_wr_addr),
		.wr_data(t_dirty_value),
		.wr_en(t_write_dirty_en),
		.rd_data0(r_dirty_out),
		.rd_data1(r_dirty_out2)
	);
	reg t_valid_value;
	reg t_write_valid_en;
	reg [7:0] t_valid_wr_addr;
	always @(*) begin
		if (_sv2v_0)
			;
		t_valid_value = 1'b0;
		t_write_valid_en = 1'b0;
		t_valid_wr_addr = r_cache_idx;
		if (t_mark_invalid)
			t_write_valid_en = 1'b1;
		else if (w_cacheable_mem_rsp_valid) begin
			t_valid_wr_addr = r_mem_req_addr[11:IDX_START];
			t_valid_value = !r_inhibit_write;
			t_write_valid_en = 1'b1;
		end
	end
	ram2r1w #(
		.WIDTH(1),
		.LG_DEPTH(8)
	) dc_valid(
		.clk(clk),
		.rd_addr0(t_cache_idx),
		.rd_addr1(t_cache_idx2),
		.wr_addr(t_valid_wr_addr),
		.wr_data(t_valid_value),
		.wr_en(t_write_valid_en),
		.rd_data0(r_valid_out),
		.rd_data1(r_valid_out2)
	);
	genvar _gv_i_2;
	function [31:0] bswap32;
		input reg [31:0] in;
		bswap32 = {in[7:0], in[15:8], in[23:16], in[31:24]};
	endfunction
	generate
		for (_gv_i_2 = 0; _gv_i_2 < WORDS_PER_CL; _gv_i_2 = _gv_i_2 + 1) begin : genblk2
			localparam i = _gv_i_2;
			assign t_array_out_b32[i] = bswap32(t_data[((i + 1) * 32) - 1:i * 32]);
		end
	endgenerate
	function [15:0] bswap16;
		input reg [15:0] in;
		bswap16 = {in[7:0], in[15:8]};
	endfunction
	function sext16;
		input reg [15:0] in;
		sext16 = in[7];
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		t_data2 = (r_got_req2 && r_must_forward2 ? r_array_wr_data : r_array_out2);
		t_w32_2 = select_cl32(t_data2, r_req2[90:89]);
		t_bswap_w32_2 = bswap32(t_w32_2);
		t_hit_cache2 = ((r_valid_out2 && (r_tag_out2 == r_cache_tag2)) && r_got_req2) && (r_state == 4'd2);
		t_rsp_dst_valid2 = 1'b0;
		t_rsp_fp_dst_valid2 = 1'b0;
		t_rsp_data2 = 'd0;
		case (r_req2[84-:5])
			5'd0: begin
				case (r_req2[88:87])
					2'd0: t_rsp_data2 = {{56 {t_w32_2[7]}}, t_w32_2[7:0]};
					2'd1: t_rsp_data2 = {{56 {t_w32_2[15]}}, t_w32_2[15:8]};
					2'd2: t_rsp_data2 = {{56 {t_w32_2[23]}}, t_w32_2[23:16]};
					2'd3: t_rsp_data2 = {{56 {t_w32_2[31]}}, t_w32_2[31:24]};
				endcase
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd1: begin
				case (r_req2[88:87])
					2'd0: t_rsp_data2 = {56'd0, t_w32_2[7:0]};
					2'd1: t_rsp_data2 = {56'd0, t_w32_2[15:8]};
					2'd2: t_rsp_data2 = {56'd0, t_w32_2[23:16]};
					2'd3: t_rsp_data2 = {56'd0, t_w32_2[31:24]};
				endcase
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd2: begin
				case (r_req2[88])
					1'b0: t_rsp_data2 = {{48 {sext16(t_w32_2[15:0])}}, bswap16(t_w32_2[15:0])};
					1'b1: t_rsp_data2 = {{48 {sext16(t_w32_2[31:16])}}, bswap16(t_w32_2[31:16])};
				endcase
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd3: begin
				t_rsp_data2 = {48'd0, bswap16((r_req2[88] ? t_w32_2[31:16] : t_w32_2[15:0]))};
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd4: begin
				t_rsp_data2 = {{32 {t_bswap_w32_2[31]}}, t_bswap_w32_2};
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd16: begin
				t_rsp_data2 = {32'd0, t_bswap_w32_2};
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd21: begin
				t_rsp_data2 = {{32 {t_bswap_w32_2[31]}}, t_bswap_w32_2};
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd22: begin
				t_rsp_data2 = bswap64(select_cl64(t_data2, r_req2[90]));
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd14: begin
				t_rsp_data2 = bswap64(select_cl64(t_data2, r_req2[90]));
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd10: begin
				case (r_req2[88:87])
					2'd0: t_rsp_data2 = {{32 {r_req2[31]}}, r_req2[31:8], t_bswap_w32_2[31:24]};
					2'd1: t_rsp_data2 = {{32 {r_req2[31]}}, r_req2[31:16], t_bswap_w32_2[31:16]};
					2'd2: t_rsp_data2 = {{32 {r_req2[31]}}, r_req2[31:24], t_bswap_w32_2[31:8]};
					2'd3: t_rsp_data2 = {{32 {t_bswap_w32_2[31]}}, t_bswap_w32_2};
				endcase
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			5'd11: begin
				case (r_req2[88:87])
					2'd0: t_rsp_data2 = {{32 {t_bswap_w32_2[31]}}, t_bswap_w32_2};
					2'd1: t_rsp_data2 = {{32 {t_bswap_w32_2[23]}}, t_bswap_w32_2[23:0], r_req2[7:0]};
					2'd2: t_rsp_data2 = {{32 {t_bswap_w32_2[15]}}, t_bswap_w32_2[15:0], r_req2[15:0]};
					2'd3: t_rsp_data2 = {{32 {t_bswap_w32_2[7]}}, t_bswap_w32_2[7:0], r_req2[23:0]};
				endcase
				t_rsp_dst_valid2 = r_req2[64] & t_hit_cache2;
			end
			default:
				;
		endcase
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_data = (r_state == 4'd12 ? mem_rsp_load_data : (r_got_req & r_must_forward ? r_array_wr_data : r_array_out));
		t_w32 = select_cl32(t_data, r_req[90:89]);
		t_bswap_w32 = bswap32(t_w32);
		t_hit_cache = ((r_valid_out && (r_tag_out == r_cache_tag)) && r_got_req) && ((r_state == 4'd2) || (r_state == 4'd3));
		t_array_data = 'd0;
		t_wr_array = 1'b0;
		t_rsp_dst_valid = 1'b0;
		t_rsp_fp_dst_valid = 1'b0;
		t_rsp_data = 'd0;
		case (r_req[84-:5])
			5'd0: begin
				case (r_req[88:87])
					2'd0: t_rsp_data = {{56 {t_w32[7]}}, t_w32[7:0]};
					2'd1: t_rsp_data = {{56 {t_w32[15]}}, t_w32[15:8]};
					2'd2: t_rsp_data = {{56 {t_w32[23]}}, t_w32[23:16]};
					2'd3: t_rsp_data = {{56 {t_w32[31]}}, t_w32[31:24]};
				endcase
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd1: begin
				case (r_req[88:87])
					2'd0: t_rsp_data = {56'd0, t_w32[7:0]};
					2'd1: t_rsp_data = {56'd0, t_w32[15:8]};
					2'd2: t_rsp_data = {56'd0, t_w32[23:16]};
					2'd3: t_rsp_data = {56'd0, t_w32[31:24]};
				endcase
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd2: begin
				case (r_req[88])
					1'b0: t_rsp_data = {{48 {sext16(t_w32[15:0])}}, bswap16(t_w32[15:0])};
					1'b1: t_rsp_data = {{48 {sext16(t_w32[31:16])}}, bswap16(t_w32[31:16])};
				endcase
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd3: begin
				t_rsp_data = {48'd0, bswap16((r_req[88] ? t_w32[31:16] : t_w32[15:0]))};
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd4: begin
				t_rsp_data = {{32 {t_bswap_w32[31]}}, t_bswap_w32};
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd16: begin
				t_rsp_data = {32'd0, t_bswap_w32};
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd21: begin
				t_rsp_data = {{32 {t_bswap_w32[31]}}, t_bswap_w32};
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd22: begin
				t_rsp_data = bswap64(select_cl64(t_data, r_req[90]));
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd14: begin
				t_rsp_data = bswap64(select_cl64(t_data, r_req[90]));
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd10: begin
				case (r_req[88:87])
					2'd0: t_rsp_data = {{32 {r_req[31]}}, r_req[31:8], t_bswap_w32[31:24]};
					2'd1: t_rsp_data = {{32 {r_req[31]}}, r_req[31:16], t_bswap_w32[31:16]};
					2'd2: t_rsp_data = {{32 {r_req[31]}}, r_req[31:24], t_bswap_w32[31:8]};
					2'd3: t_rsp_data = {{32 {t_bswap_w32[31]}}, t_bswap_w32};
				endcase
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd11: begin
				case (r_req[88:87])
					2'd0: t_rsp_data = {{32 {t_bswap_w32[31]}}, t_bswap_w32};
					2'd1: t_rsp_data = {{32 {t_bswap_w32[23]}}, t_bswap_w32[23:0], r_req[7:0]};
					2'd2: t_rsp_data = {{32 {t_bswap_w32[15]}}, t_bswap_w32[15:0], r_req[15:0]};
					2'd3: t_rsp_data = {{32 {t_bswap_w32[7]}}, t_bswap_w32[7:0], r_req[23:0]};
				endcase
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd17: begin
				begin : sv2v_autoblock_2
					reg [63:0] t_dword;
					t_dword = bswap64(select_cl64(t_data, r_req[90]));
					case (r_req[89:87])
						3'd0: t_rsp_data = t_dword;
						3'd1: t_rsp_data = {t_dword[55:0], r_req[7:0]};
						3'd2: t_rsp_data = {t_dword[47:0], r_req[15:0]};
						3'd3: t_rsp_data = {t_dword[39:0], r_req[23:0]};
						3'd4: t_rsp_data = {t_dword[31:0], r_req[31:0]};
						3'd5: t_rsp_data = {t_dword[23:0], r_req[39:0]};
						3'd6: t_rsp_data = {t_dword[15:0], r_req[47:0]};
						3'd7: t_rsp_data = {t_dword[7:0], r_req[55:0]};
					endcase
				end
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd18: begin
				begin : sv2v_autoblock_3
					reg [63:0] t_dword;
					t_dword = bswap64(select_cl64(t_data, r_req[90]));
					case (r_req[89:87])
						3'd0: t_rsp_data = {r_req[63:8], t_dword[63:56]};
						3'd1: t_rsp_data = {r_req[63:16], t_dword[63:48]};
						3'd2: t_rsp_data = {r_req[63:24], t_dword[63:40]};
						3'd3: t_rsp_data = {r_req[63:32], t_dword[63:32]};
						3'd4: t_rsp_data = {r_req[63:40], t_dword[63:24]};
						3'd5: t_rsp_data = {r_req[63:48], t_dword[63:16]};
						3'd6: t_rsp_data = {r_req[63:56], t_dword[63:8]};
						3'd7: t_rsp_data = t_dword;
					endcase
				end
				t_rsp_dst_valid = r_req[64] & t_hit_cache;
			end
			5'd19: begin
				begin : sv2v_autoblock_4
					reg [63:0] t_dword;
					reg [63:0] t_sdl_merged;
					t_dword = bswap64(select_cl64(t_data, r_req[90]));
					case (r_req[89:87])
						3'd0: t_sdl_merged = r_req[63-:64];
						3'd1: t_sdl_merged = {t_dword[63:56], r_req[63:8]};
						3'd2: t_sdl_merged = {t_dword[63:48], r_req[63:16]};
						3'd3: t_sdl_merged = {t_dword[63:40], r_req[63:24]};
						3'd4: t_sdl_merged = {t_dword[63:32], r_req[63:32]};
						3'd5: t_sdl_merged = {t_dword[63:24], r_req[63:40]};
						3'd6: t_sdl_merged = {t_dword[63:16], r_req[63:48]};
						3'd7: t_sdl_merged = {t_dword[63:8], r_req[63:56]};
					endcase
					t_array_data = merge_cl64(t_data, bswap64(t_sdl_merged), r_req[90]);
				end
				t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
			end
			5'd20: begin
				begin : sv2v_autoblock_5
					reg [63:0] t_dword;
					reg [63:0] t_sdr_merged;
					t_dword = bswap64(select_cl64(t_data, r_req[90]));
					case (r_req[89:87])
						3'd0: t_sdr_merged = {r_req[7:0], t_dword[55:0]};
						3'd1: t_sdr_merged = {r_req[15:0], t_dword[47:0]};
						3'd2: t_sdr_merged = {r_req[23:0], t_dword[39:0]};
						3'd3: t_sdr_merged = {r_req[31:0], t_dword[31:0]};
						3'd4: t_sdr_merged = {r_req[39:0], t_dword[23:0]};
						3'd5: t_sdr_merged = {r_req[47:0], t_dword[15:0]};
						3'd6: t_sdr_merged = {r_req[55:0], t_dword[7:0]};
						3'd7: t_sdr_merged = r_req[63-:64];
					endcase
					t_array_data = merge_cl64(t_data, bswap64(t_sdr_merged), r_req[90]);
				end
				t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
			end
			5'd5: begin
				case (r_req[88:87])
					2'd0: t_array_data = merge_cl32(t_data, {t_w32[31:8], r_req[7:0]}, r_req[90:89]);
					2'd1: t_array_data = merge_cl32(t_data, {t_w32[31:16], r_req[7:0], t_w32[7:0]}, r_req[90:89]);
					2'd2: t_array_data = merge_cl32(t_data, {t_w32[31:24], r_req[7:0], t_w32[15:0]}, r_req[90:89]);
					2'd3: t_array_data = merge_cl32(t_data, {r_req[7:0], t_w32[23:0]}, r_req[90:89]);
				endcase
				t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
			end
			5'd6: begin
				case (r_req[88])
					1'b0: t_array_data = merge_cl32(t_data, {t_w32[31:16], bswap16(r_req[15:0])}, r_req[90:89]);
					1'b1: t_array_data = merge_cl32(t_data, {bswap16(r_req[15:0]), t_w32[15:0]}, r_req[90:89]);
				endcase
				t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
			end
			5'd7: begin
				t_array_data = merge_cl32(t_data, bswap32(r_req[31:0]), r_req[90:89]);
				t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
			end
			5'd15: begin
				t_array_data = merge_cl64(t_data, bswap64(r_req[63:0]), r_req[90]);
				t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
			end
			5'd12: begin
				t_array_data = merge_cl32(t_data, bswap32(r_req[31:0]), r_req[90:89]);
				t_rsp_data = 'd0;
				t_rsp_dst_valid = 1'b0;
				t_wr_array = (t_hit_cache && (r_is_retry || r_did_reload)) && r_sc_should_write;
			end
			5'd23: begin
				t_array_data = merge_cl64(t_data, bswap64(r_req[63:0]), r_req[90]);
				t_rsp_data = 'd0;
				t_rsp_dst_valid = 1'b0;
				t_wr_array = (t_hit_cache && (r_is_retry || r_did_reload)) && r_sc_should_write;
			end
			5'd8: begin
				case (r_req[88:87])
					2'd0: t_array_data = merge_cl32(t_data, bswap32({r_req[7:0], t_bswap_w32[23:0]}), r_req[90:89]);
					2'd1: t_array_data = merge_cl32(t_data, bswap32({r_req[15:0], t_bswap_w32[15:0]}), r_req[90:89]);
					2'd2: t_array_data = merge_cl32(t_data, bswap32({r_req[23:0], t_bswap_w32[7:0]}), r_req[90:89]);
					2'd3: t_array_data = merge_cl32(t_data, bswap32(r_req[31:0]), r_req[90:89]);
				endcase
				t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
			end
			5'd9: begin
				case (r_req[88:87])
					2'd0: t_array_data = merge_cl32(t_data, t_bswap_w32, r_req[90:89]);
					2'd1: t_array_data = merge_cl32(t_data, bswap32({t_bswap_w32[31:24], r_req[31:8]}), r_req[90:89]);
					2'd2: t_array_data = merge_cl32(t_data, bswap32({t_bswap_w32[31:16], r_req[31:16]}), r_req[90:89]);
					2'd3: t_array_data = merge_cl32(t_data, bswap32({t_bswap_w32[31:8], r_req[31:24]}), r_req[90:89]);
				endcase
				t_wr_array = t_hit_cache && (r_is_retry || r_did_reload);
			end
			default:
				;
		endcase
	end
	reg [31:0] r_fwd_cnt;
	always @(posedge clk) r_fwd_cnt <= (reset ? 'd0 : (r_got_req && r_must_forward ? r_fwd_cnt + 'd1 : r_fwd_cnt));
	wire w_memq_empty = (mem_q_empty & (r_n_inflight == 'd0)) & (r_state == 4'd2);
	wire w_uncachable_req = (core_mem_req_valid & (core_mem_req[77] == 1'b0) ? (head_of_rob_ptr_valid ? head_of_rob_ptr == core_mem_req[76-:5] : 1'b0) | drain_ds_complete : 1'b1);
	tlb dtlb(
		.clk(clk),
		.reset(reset),
		.asid(asid),
		.active(core_mem_req[78]),
		.req(t_got_req2),
		.va(n_tlb_addr),
		.pa(w_mapped_addr),
		.hit(w_tlb_hit),
		.hit_index(w_tlb_index),
		.dirty(w_tlb_dirty),
		.valid(w_tlb_valid),
		.tlb_entry_in_valid(tlb_entry_in_valid),
		.tlb_entry_in(tlb_entry_in)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		t_got_rd_retry = 1'b0;
		t_port2_hit_cache = r_valid_out2 && (r_tag_out2 == r_cache_tag2);
		t_mem_req_mask = make_mask(r_req);
		n_state = r_state;
		t_miss_idx = r_miss_idx;
		t_miss_addr = r_miss_addr;
		t_cache_idx = 'd0;
		t_cache_tag = 'd0;
		t_cache_idx2 = 'd0;
		t_cache_tag2 = 'd0;
		n_tlb_addr = r_tlb_addr;
		t_got_req = 1'b0;
		t_got_req2 = 1'b0;
		t_got_non_mem = 1'b0;
		n_last_wr = 1'b0;
		n_last_rd = 1'b0;
		n_last_wr2 = 1'b0;
		n_last_rd2 = 1'b0;
		t_got_miss = 1'b0;
		t_push_miss = 1'b0;
		n_req = r_req;
		n_req2 = r_req2;
		core_mem_req_ack = 1'b0;
		core_store_data_ack = 1'b0;
		n_mem_req_valid = 1'b0;
		n_mem_req_cacheable = r_mem_req_cacheable;
		n_mem_req_mask = r_mem_req_mask;
		n_mem_req_addr = r_mem_req_addr;
		n_mem_req_store_data = r_mem_req_store_data;
		n_mem_req_opcode = r_mem_req_opcode;
		t_pop_mq = 1'b0;
		n_core_mem_rsp_valid = 1'b0;
		n_core_mem_rsp[87-:64] = r_req[150-:64];
		n_core_mem_rsp[23-:5] = r_req[76-:5];
		n_core_mem_rsp[18-:7] = r_req[71-:7];
		n_core_mem_rsp[11] = 1'b0;
		n_core_mem_rsp[10] = 1'b0;
		n_core_mem_rsp[9] = 1'b0;
		n_core_mem_rsp[8] = 1'b0;
		n_core_mem_rsp[7] = 1'b0;
		n_core_mem_rsp[6] = 1'b0;
		n_core_mem_rsp[5-:6] = 6'd0;
		n_cache_accesses = r_cache_accesses;
		n_cache_hits = r_cache_hits;
		n_flush_req = r_flush_req | flush_req;
		n_flush_cl_req = r_flush_cl_req | flush_cl_req;
		n_flush_complete = 1'b0;
		t_addr = 'd0;
		n_inhibit_write = r_inhibit_write;
		t_mark_invalid = 1'b0;
		n_is_retry = 1'b0;
		t_reset_graduated = 1'b0;
		t_force_clear_busy = 1'b0;
		t_incr_busy = 1'b0;
		n_stall_store = 1'b0;
		n_q_priority = !r_q_priority;
		n_reload_issue = r_reload_issue;
		n_did_reload = 1'b0;
		n_uncache_wb_dirty = r_uncache_wb_dirty;
		n_lock_cache = r_lock_cache;
		t_mh_block = (r_got_req && r_last_wr) && (r_cache_idx == t_mem_head[98:91]);
		t_cm_block = ((r_got_req && r_last_wr) && (r_cache_idx == core_mem_req[98:91])) && (r_cache_tag == core_mem_req[150:99]);
		t_cm_block_stall = t_cm_block && !(r_did_reload || r_is_retry);
		case (r_state)
			4'd0: begin
				n_state = 4'd1;
				t_cache_idx = 'd0;
			end
			4'd1: begin
				t_cache_idx = r_cache_idx + 'd1;
				if (r_cache_idx == 255) begin
					n_state = 4'd2;
					n_flush_complete = 1'b1;
				end
				else begin
					t_mark_invalid = 1'b1;
					t_cache_idx = r_cache_idx + 'd1;
				end
			end
			4'd2: begin
				if (r_got_req2) begin
					n_core_mem_rsp[87-:64] = r_req2[150-:64];
					n_core_mem_rsp[23-:5] = r_req2[76-:5];
					n_core_mem_rsp[18-:7] = r_req2[71-:7];
					if (drain_ds_complete) begin
						n_core_mem_rsp[11] = r_req2[64];
						n_core_mem_rsp[10] = r_req2[79];
						n_core_mem_rsp_valid = 1'b1;
					end
					else if (r_req2[84-:5] == 5'd13) begin
						n_core_mem_rsp[11] = 1'b0;
						n_core_mem_rsp[6] = w_tlb_hit;
						n_core_mem_rsp[5-:6] = w_tlb_index;
						n_core_mem_rsp_valid = 1'b1;
					end
					else if (r_req2[79]) begin
						n_core_mem_rsp[87-:64] = r_req2[150-:64];
						n_core_mem_rsp[11] = r_req2[64];
						n_core_mem_rsp[10] = r_req2[79];
						n_core_mem_rsp_valid = 1'b1;
					end
					else if (w_tlb_hit == 1'b0) begin
						n_core_mem_rsp[87-:64] = w_mapped_addr;
						n_core_mem_rsp[11] = 1'b0;
						n_core_mem_rsp[10] = 1'b0;
						n_core_mem_rsp[9] = 1'b1;
						n_core_mem_rsp_valid = 1'b1;
					end
					else if (w_tlb_valid == 1'b0) begin
						n_core_mem_rsp[87-:64] = w_mapped_addr;
						n_core_mem_rsp[11] = 1'b0;
						n_core_mem_rsp[10] = 1'b0;
						n_core_mem_rsp[8] = 1'b1;
						n_core_mem_rsp[6] = w_tlb_hit;
						n_core_mem_rsp[5-:6] = w_tlb_index;
						n_core_mem_rsp_valid = 1'b1;
					end
					else if (r_req2[86] && (w_tlb_dirty == 1'b0)) begin
						n_core_mem_rsp[87-:64] = w_mapped_addr;
						n_core_mem_rsp[11] = 1'b0;
						n_core_mem_rsp[10] = 1'b0;
						n_core_mem_rsp[7] = 1'b1;
						n_core_mem_rsp[6] = w_tlb_hit;
						n_core_mem_rsp[5-:6] = w_tlb_index;
						n_core_mem_rsp_valid = 1'b1;
					end
					else if (r_req2[86]) begin
						t_push_miss = 1'b1;
						t_incr_busy = 1'b1;
						n_stall_store = 1'b1;
						if ((r_req2[84-:5] != 5'd12) && (r_req2[84-:5] != 5'd23)) begin
							n_core_mem_rsp[11] = 1'b0;
							n_core_mem_rsp[6] = w_tlb_hit;
							n_core_mem_rsp[5-:6] = w_tlb_index;
							if (t_port2_hit_cache)
								n_cache_hits = r_cache_hits + 'd1;
							n_core_mem_rsp_valid = 1'b1;
							n_core_mem_rsp[10] = r_req2[79];
						end
						else begin
							n_core_mem_rsp[87-:64] = {{63 {1'b0}}, w_match_link2};
							n_core_mem_rsp[11] = r_req2[64];
							n_core_mem_rsp[10] = r_req2[79];
							if (t_port2_hit_cache)
								n_cache_hits = r_cache_hits + 'd1;
							n_core_mem_rsp_valid = 1'b1;
						end
					end
					else if ((((r_req2[84-:5] == 5'd11) || (r_req2[84-:5] == 5'd10)) || (r_req2[84-:5] == 5'd17)) || (r_req2[84-:5] == 5'd18)) begin
						t_push_miss = 1'b1;
						n_core_mem_rsp[10] = r_req2[79];
						n_core_mem_rsp[6] = w_tlb_hit;
						n_core_mem_rsp[5-:6] = w_tlb_index;
					end
					else if (t_port2_hit_cache && !r_hit_busy_addr2) begin
						n_core_mem_rsp[87-:64] = t_rsp_data2[63:0];
						n_core_mem_rsp[11] = t_rsp_dst_valid2;
						n_cache_hits = r_cache_hits + 'd1;
						n_core_mem_rsp_valid = 1'b1;
						n_core_mem_rsp[10] = r_req2[79];
						n_core_mem_rsp[6] = w_tlb_hit;
						n_core_mem_rsp[5-:6] = w_tlb_index;
					end
					else begin
						t_push_miss = 1'b1;
						if (t_port2_hit_cache)
							n_cache_hits = r_cache_hits + 'd1;
					end
				end
				if (r_got_req) begin
					if (r_req[77] == 1'b0) begin
						if (r_valid_out && (r_tag_out == r_cache_tag)) begin
							t_got_miss = 1'b1;
							t_mark_invalid = 1'b1;
							n_uncache_wb_dirty = r_dirty_out;
							n_state = 4'd13;
							if (r_dirty_out) begin
								n_mem_req_addr = {r_tag_out, r_cache_idx, {4 {1'b0}}};
								n_mem_req_cacheable = 1'b1;
								n_mem_req_opcode = 5'd7;
								n_mem_req_store_data = t_data;
								n_mem_req_mask = 16'hffff;
								n_mem_req_valid = 1'b1;
								n_inhibit_write = 1'b1;
							end
						end
						else begin
							n_mem_req_cacheable = 1'b0;
							n_mem_req_mask = t_mem_req_mask;
							if (r_req[84-:5] == 5'd8)
								$display("SWR addr[3:0] = %x, {addr[3:2],2'd0} = %x, bits %x, mask = %b", r_req[90:87], {r_req[90:89], 2'd0}, r_req[88:87], n_mem_req_mask);
							if (r_req[84-:5] == 5'd9)
								$display("SWL addr[3:0] = %x, {addr[3:2],2'd0} = %x, bits %x, mask = %b", r_req[90:87], {r_req[90:89], 2'd0}, r_req[88:87], n_mem_req_mask);
							n_state = (r_req[86] ? 4'd11 : 4'd12);
							n_mem_req_valid = 1'b1;
							n_mem_req_opcode = (r_req[86] ? 5'd7 : 5'd4);
							n_mem_req_addr = {r_req[150:91], {4 {1'b0}}};
							n_mem_req_store_data = t_array_data;
							t_got_miss = 1'b1;
							if (r_req[86])
								t_reset_graduated = 1'b1;
						end
					end
					else if (r_valid_out && (r_tag_out == r_cache_tag)) begin
						if (r_req[86])
							t_reset_graduated = 1'b1;
						else begin
							n_core_mem_rsp[87-:64] = t_rsp_data[63:0];
							n_core_mem_rsp[11] = t_rsp_dst_valid;
							n_core_mem_rsp_valid = 1'b1;
							n_core_mem_rsp[10] = r_req[79];
						end
					end
					else if ((r_valid_out && r_dirty_out) && (r_tag_out != r_cache_tag)) begin
						n_reload_issue = 1'b1;
						t_got_miss = 1'b1;
						n_inhibit_write = 1'b1;
						if ((r_hit_busy_addr && r_is_retry) || !r_hit_busy_addr) begin
							n_reload_issue = 1'b1;
							n_mem_req_addr = {r_tag_out, r_cache_idx, {4 {1'b0}}};
							n_mem_req_cacheable = 1'b1;
							n_mem_req_opcode = 5'd7;
							n_mem_req_store_data = t_data;
							n_mem_req_mask = 16'hffff;
							n_inhibit_write = 1'b1;
							t_miss_idx = r_cache_idx;
							t_miss_addr = r_req[150-:64];
							n_lock_cache = 1'b1;
							if ((rr_cache_idx == r_cache_idx) && rr_last_wr) begin
								t_cache_idx = r_cache_idx;
								n_state = 4'd4;
								n_mem_req_valid = 1'b0;
							end
							else begin
								n_state = 4'd3;
								n_mem_req_valid = 1'b1;
							end
						end
					end
					else begin
						t_got_miss = 1'b1;
						n_inhibit_write = 1'b0;
						if (((r_hit_busy_addr && r_is_retry) || !r_hit_busy_addr) || r_lock_cache) begin
							n_reload_issue = 1'b1;
							t_miss_idx = r_cache_idx;
							t_miss_addr = r_req[150-:64];
							n_mem_req_cacheable = 1'b1;
							n_mem_req_mask = 16'hffff;
							t_cache_idx = r_cache_idx;
							if ((rr_cache_idx == r_cache_idx) && rr_last_wr) begin
								n_mem_req_addr = {r_tag_out, r_cache_idx, {4 {1'b0}}};
								n_lock_cache = 1'b1;
								n_mem_req_opcode = 5'd7;
								n_state = 4'd4;
								n_mem_req_valid = 1'b0;
							end
							else begin
								n_lock_cache = 1'b0;
								n_mem_req_addr = {r_req[150:91], {4 {1'b0}}};
								n_mem_req_opcode = 5'd4;
								n_state = 4'd3;
								n_mem_req_valid = 1'b1;
							end
						end
					end
				end
				if ((!mem_q_empty && !t_got_miss) && !r_lock_cache) begin
					if (!t_mh_block) begin
						if (t_mem_head[86]) begin
							if ((r_graduated[t_mem_head[76-:5]] == 2'b10) && (core_store_data_valid ? t_mem_head[76-:5] == core_store_data[4-:5] : 1'b0)) begin
								t_pop_mq = 1'b1;
								core_store_data_ack = 1'b1;
								n_req = t_mem_head;
								n_req[63-:64] = core_store_data[68-:64];
								t_cache_idx = t_mem_head[98:91];
								t_cache_tag = t_mem_head[150:99];
								t_addr = t_mem_head[150-:64];
								t_got_req = 1'b1;
								n_is_retry = 1'b1;
								n_last_wr = 1'b1;
							end
							else if (drain_ds_complete && dead_rob_mask[t_mem_head[76-:5]]) begin
								t_pop_mq = 1'b1;
								t_force_clear_busy = 1'b1;
							end
						end
						else if ((((t_mem_head[84-:5] == 5'd11) || (t_mem_head[84-:5] == 5'd10)) || (t_mem_head[84-:5] == 5'd17)) || (t_mem_head[84-:5] == 5'd18)) begin
							if ((core_store_data_valid ? t_mem_head[76-:5] == core_store_data[4-:5] : 1'b0) || drain_ds_complete) begin
								t_pop_mq = 1'b1;
								n_req = t_mem_head;
								n_req[63-:64] = core_store_data[68-:64];
								core_store_data_ack = 1'b1;
								t_cache_idx = t_mem_head[98:91];
								t_cache_tag = t_mem_head[150:99];
								t_addr = t_mem_head[150-:64];
								t_got_req = 1'b1;
								n_is_retry = 1'b1;
								n_last_rd = 1'b1;
								t_got_rd_retry = 1'b1;
							end
						end
						else begin
							t_pop_mq = 1'b1;
							n_req = t_mem_head;
							t_cache_idx = t_mem_head[98:91];
							t_cache_tag = t_mem_head[150:99];
							t_addr = t_mem_head[150-:64];
							t_got_req = 1'b1;
							n_is_retry = 1'b1;
							n_last_rd = 1'b1;
							t_got_rd_retry = 1'b1;
						end
					end
				end
				if ((((((((core_mem_req_valid && !t_got_miss) && !(mem_q_almost_full || mem_q_full)) && !t_got_rd_retry) && !((r_last_wr2 && (r_cache_idx2 == core_mem_req[98:91])) && !core_mem_req[86])) && !t_cm_block_stall) && w_uncachable_req) && (core_mem_req[85] ? mem_q_empty : 1'b1)) && !r_rob_inflight[core_mem_req[76-:5]]) begin
					t_cache_idx2 = core_mem_req[98:91];
					t_cache_tag2 = core_mem_req[150:99];
					n_tlb_addr = core_mem_req[150-:64];
					n_req2 = core_mem_req;
					core_mem_req_ack = 1'b1;
					t_got_req2 = 1'b1;
					n_last_wr2 = core_mem_req[86];
					n_last_rd2 = !core_mem_req[86];
					n_cache_accesses = r_cache_accesses + 'd1;
				end
				else if ((r_flush_req && mem_q_empty) && !(r_got_req && r_last_wr)) begin
					n_state = 4'd5;
					n_mem_req_mask = 16'hffff;
					n_mem_req_cacheable = 1'b1;
					t_cache_idx = 'd0;
					n_flush_req = 1'b0;
				end
				else if ((r_flush_cl_req && mem_q_empty) && !(r_got_req && r_last_wr)) begin
					t_cache_idx = flush_cl_addr[11:IDX_START];
					n_flush_cl_req = 1'b0;
					n_state = 4'd8;
				end
			end
			4'd4: begin
				n_mem_req_valid = 1'b1;
				n_state = 4'd3;
				n_mem_req_store_data = t_data;
			end
			4'd3:
				if (mem_rsp_valid) begin
					n_state = (r_reload_issue ? 4'd10 : 4'd2);
					n_inhibit_write = 1'b0;
					n_reload_issue = 1'b0;
				end
			4'd11:
				if (mem_rsp_valid)
					n_state = 4'd2;
			4'd12:
				if (mem_rsp_valid) begin
					n_core_mem_rsp[87-:64] = t_rsp_data[63:0];
					n_core_mem_rsp[11] = r_req[64];
					n_core_mem_rsp[10] = r_req[79];
					n_core_mem_rsp_valid = 1'b1;
					n_state = 4'd2;
				end
			4'd13:
				if (!r_uncache_wb_dirty || mem_rsp_valid) begin
					n_inhibit_write = 1'b0;
					n_uncache_wb_dirty = 1'b0;
					t_got_req = 1'b1;
					t_cache_idx = r_req[98:91];
					t_cache_tag = r_req[150:99];
					t_addr = r_req[150-:64];
					n_state = 4'd2;
				end
			4'd10: begin
				t_cache_idx = r_req[98:91];
				t_cache_tag = r_req[150:99];
				n_last_wr = n_req[86];
				t_got_req = 1'b1;
				t_addr = r_req[150-:64];
				n_did_reload = 1'b1;
				n_state = 4'd2;
			end
			4'd8:
				if (r_dirty_out) begin
					n_mem_req_addr = {r_tag_out, r_cache_idx, {4 {1'b0}}};
					n_mem_req_opcode = 5'd7;
					n_mem_req_store_data = t_data;
					n_state = 4'd9;
					n_inhibit_write = 1'b1;
					n_mem_req_valid = 1'b1;
				end
				else begin
					n_state = 4'd2;
					t_mark_invalid = 1'b1;
					n_flush_complete = 1'b1;
				end
			4'd9:
				if (mem_rsp_valid) begin
					n_state = 4'd2;
					n_inhibit_write = 1'b0;
					n_flush_complete = 1'b1;
				end
			4'd5: begin
				t_cache_idx = r_cache_idx + 'd1;
				if (!r_dirty_out) begin
					t_mark_invalid = 1'b1;
					t_cache_idx = r_cache_idx + 'd1;
					if (r_cache_idx == 255) begin
						n_state = 4'd2;
						n_flush_complete = 1'b1;
					end
				end
				else begin
					n_mem_req_addr = {r_tag_out, r_cache_idx, {4 {1'b0}}};
					n_mem_req_opcode = 5'd7;
					n_mem_req_store_data = t_data;
					n_state = (r_cache_idx == 255 ? 4'd7 : 4'd6);
					n_inhibit_write = 1'b1;
					n_mem_req_valid = 1'b1;
				end
			end
			4'd7: begin
				t_cache_idx = r_cache_idx;
				if (mem_rsp_valid) begin
					n_state = 4'd2;
					n_inhibit_write = 1'b0;
					n_flush_complete = 1'b1;
				end
			end
			4'd6: begin
				t_cache_idx = r_cache_idx;
				if (mem_rsp_valid) begin
					n_state = 4'd5;
					n_inhibit_write = 1'b0;
				end
			end
			default:
				;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule

module popcount (
	in,
	out
);
	reg _sv2v_0;
	parameter LG_N = 2;
	localparam N = 1 << LG_N;
	localparam N2 = 1 << (LG_N - 1);
	input wire [N - 1:0] in;
	output reg [LG_N:0] out;
	generate
		if (LG_N == 2) begin : genblk1
			always @(*) begin
				if (_sv2v_0)
					;
				out = 'd0;
				case (in)
					4'b0000: out = 'd0;
					4'b0001: out = 'd1;
					4'b0010: out = 'd1;
					4'b0011: out = 'd2;
					4'b0100: out = 'd1;
					4'b0101: out = 'd2;
					4'b0110: out = 'd2;
					4'b0111: out = 'd3;
					4'b1000: out = 'd1;
					4'b1001: out = 'd2;
					4'b1010: out = 'd2;
					4'b1011: out = 'd3;
					4'b1100: out = 'd2;
					4'b1101: out = 'd3;
					4'b1110: out = 'd3;
					4'b1111: out = 'd4;
				endcase
			end
		end
		else begin : genblk1
			wire [LG_N - 1:0] t0;
			wire [LG_N - 1:0] t1;
			popcount #(.LG_N(LG_N - 1)) u0(
				.in(in[N2 - 1:0]),
				.out(t0)
			);
			popcount #(.LG_N(LG_N - 1)) u1(
				.in(in[N - 1:N2]),
				.out(t1)
			);
			wire [(LG_N >= 0 ? LG_N + 1 : 1 - LG_N):1] sv2v_tmp_53C6C;
			assign sv2v_tmp_53C6C = {1'b0, t0} + {1'b0, t1};
			always @(*) out = sv2v_tmp_53C6C;
		end
	endgenerate
	initial _sv2v_0 = 0;
endmodule

module ram1r1w (
	clk,
	rd_addr,
	wr_addr,
	wr_data,
	wr_en,
	rd_data
);
	input wire clk;
	parameter WIDTH = 1;
	parameter LG_DEPTH = 1;
	input wire [LG_DEPTH - 1:0] rd_addr;
	input wire [LG_DEPTH - 1:0] wr_addr;
	input wire [WIDTH - 1:0] wr_data;
	input wire wr_en;
	output reg [WIDTH - 1:0] rd_data;
	localparam DEPTH = 1 << LG_DEPTH;
	reg [WIDTH - 1:0] r_ram [DEPTH - 1:0];
	always @(posedge clk) begin
		rd_data <= r_ram[rd_addr];
		if (wr_en)
			r_ram[wr_addr] <= wr_data;
	end
endmodule

module ff (
	q,
	d,
	clk
);
	parameter N = 1;
	input wire [N - 1:0] d;
	input wire clk;
	output reg [N - 1:0] q;
	always @(posedge clk) q <= d;
endmodule
module mul (
	clk,
	reset,
	is_signed,
	go,
	src_A,
	src_B,
	is_32b,
	rob_ptr_in,
	hilo_prf_ptr_in,
	y,
	complete,
	rob_ptr_out,
	hilo_prf_ptr_val_out,
	hilo_prf_ptr_out
);
	reg _sv2v_0;
	parameter W = 32;
	input wire clk;
	input wire reset;
	input wire is_signed;
	input wire go;
	input wire [W - 1:0] src_A;
	input wire [W - 1:0] src_B;
	input wire is_32b;
	input wire [4:0] rob_ptr_in;
	input wire [1:0] hilo_prf_ptr_in;
	output wire [(2 * W) - 1:0] y;
	output wire complete;
	output wire [4:0] rob_ptr_out;
	output wire hilo_prf_ptr_val_out;
	output wire [1:0] hilo_prf_ptr_out;
	reg [3:0] r_complete;
	reg [3:0] r_is_32b;
	reg [3:0] r_hilo_val;
	reg [1:0] r_hilo_ptr [3:0];
	reg [4:0] r_rob_ptr [3:0];
	assign complete = r_complete[3];
	assign rob_ptr_out = r_rob_ptr[3];
	assign hilo_prf_ptr_val_out = r_hilo_val[3];
	assign hilo_prf_ptr_out = r_hilo_ptr[3];
	reg [(2 * W) - 1:0] t_mul;
	reg [(2 * W) - 1:0] r_mul [3:0];
	wire [63:0] w_mul32b_lo = {{32 {r_mul[3][31]}}, r_mul[3][31:0]};
	wire [63:0] w_mul32b_hi = {{32 {r_mul[3][63]}}, r_mul[3][63:32]};
	wire [63:0] w_src_A;
	wire [63:0] w_src_B;
	generate
		if (1) begin : genblk1
			assign w_src_A = (is_32b ? {32'd0, src_A[31:0]} : src_A);
			assign w_src_B = (is_32b ? {32'd0, src_B[31:0]} : src_B);
		end
	endgenerate
	wire signed [(2 * W) - 1:0] w_signed_A = {{W {src_A[W - 1]}}, src_A};
	wire signed [(2 * W) - 1:0] w_signed_B = {{W {src_B[W - 1]}}, src_B};
	wire [(2 * W) - 1:0] w_unsigned_A = {{W {1'b0}}, w_src_A};
	wire [(2 * W) - 1:0] w_unsigned_B = {{W {1'b0}}, w_src_B};
	wire [127:0] w_mul32b = {w_mul32b_hi, w_mul32b_lo};
	always @(*) begin
		if (_sv2v_0)
			;
		t_mul = (is_signed ? w_signed_A * w_signed_B : w_unsigned_A * w_unsigned_B);
	end
	generate
		if (1) begin : genblk2
			assign y = (r_is_32b[3] ? w_mul32b : r_mul[3]);
		end
	endgenerate
	always @(posedge clk) begin
		r_mul[0] <= t_mul;
		begin : sv2v_autoblock_1
			integer i;
			for (i = 1; i <= 3; i = i + 1)
				r_mul[i] <= r_mul[i - 1];
		end
	end
	always @(posedge clk)
		if (reset) begin
			begin : sv2v_autoblock_2
				integer i;
				for (i = 0; i <= 3; i = i + 1)
					begin
						r_rob_ptr[i] <= 'd0;
						r_hilo_ptr[i] <= 'd0;
					end
			end
			r_complete <= 'd0;
			r_hilo_val <= 'd0;
			r_is_32b <= 'd0;
		end
		else begin : sv2v_autoblock_3
			integer i;
			for (i = 0; i <= 3; i = i + 1)
				if (i == 0) begin
					r_complete[0] <= go;
					r_rob_ptr[0] <= rob_ptr_in;
					r_hilo_val[0] <= go;
					r_hilo_ptr[0] <= hilo_prf_ptr_in;
					r_is_32b[0] <= is_32b;
				end
				else begin
					r_complete[i] <= r_complete[i - 1];
					r_rob_ptr[i] <= r_rob_ptr[i - 1];
					r_hilo_val[i] <= r_hilo_val[i - 1];
					r_hilo_ptr[i] <= r_hilo_ptr[i - 1];
					r_is_32b[i] <= r_is_32b[i - 1];
				end
		end
	initial _sv2v_0 = 0;
endmodule

module count_leading_zeros (
	in,
	y
);
	reg _sv2v_0;
	parameter LG_N = 2;
	localparam N = 1 << LG_N;
	localparam N2 = 1 << (LG_N - 1);
	input wire [N - 1:0] in;
	output reg [LG_N:0] y;
	wire [LG_N - 1:0] t0;
	wire [LG_N - 1:0] t1;
	wire lo_z = in[N2 - 1:0] == 'd0;
	wire hi_z = in[N - 1:N2] == 'd0;
	generate
		if (LG_N == 2) begin : genblk1
			always @(*) begin
				if (_sv2v_0)
					;
				y = 'd0;
				casez (in)
					4'b0000: y = 3'd4;
					4'b0001: y = 3'd3;
					4'b001z: y = 3'd2;
					4'b01zz: y = 3'd1;
					4'b1zzz: y = 3'd0;
					default: y = 3'd0;
				endcase
			end
		end
		else begin : genblk1
			count_leading_zeros #(.LG_N(LG_N - 1)) f0(
				.in(in[N2 - 1:0]),
				.y(t0)
			);
			count_leading_zeros #(.LG_N(LG_N - 1)) f1(
				.in(in[N - 1:N2]),
				.y(t1)
			);
			always @(*) begin
				if (_sv2v_0)
					;
				y = N;
				if (hi_z)
					y = N2 + t0;
				else
					y = {1'b0, t1};
			end
		end
	endgenerate
	initial _sv2v_0 = 0;
endmodule

module core (
	clk,
	single_step,
	step,
	reset,
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
	badvaddr,
	cause,
	asid,
	tlb_entry_out,
	tlb_entry_out_valid,
	took_irq,
	cp0_count,
	l1i_flush_done,
	l1d_flush_done,
	l2_flush_done
);
	reg _sv2v_0;
	input wire clk;
	input wire reset;
	output wire in_kernel_mode;
	output wire in_supervisor_mode;
	output wire in_user_mode;
	output wire in_64b_kernel_mode;
	output wire in_64b_supervisor_mode;
	output wire in_64b_user_mode;
	output wire [7:0] putchar_fifo_out;
	output wire putchar_fifo_empty;
	input wire putchar_fifo_pop;
	output wire [3:0] putchar_fifo_wptr;
	output wire [3:0] putchar_fifo_rptr;
	input wire extern_irq;
	output wire head_of_rob_ptr_valid;
	output wire [4:0] head_of_rob_ptr;
	output wire head_of_rob_has_delay_slot;
	input wire resume;
	input wire single_step;
	input wire step;
	input wire memq_empty;
	output reg drain_ds_complete;
	output wire [31:0] dead_rob_mask;
	input wire [63:0] resume_pc;
	output wire ready_for_resume;
	output wire flush_req_l1d;
	output wire flush_req_l1i;
	output wire flush_cl_req;
	output wire [63:0] flush_cl_addr;
	input wire l1d_flush_complete;
	input wire l1i_flush_complete;
	input wire l2_flush_complete;
	input wire [180:0] insn;
	input wire insn_valid;
	output wire insn_ack;
	input wire [180:0] insn_two;
	input wire insn_valid_two;
	output wire insn_ack_two;
	output wire [63:0] restart_pc;
	output wire [63:0] restart_src_pc;
	output wire restart_src_is_indirect;
	output wire restart_valid;
	output wire clr_link_reg;
	input wire restart_ack;
	output wire [63:0] branch_pc;
	output wire branch_pc_valid;
	output wire branch_fault;
	output wire took_branch;
	output wire [15:0] branch_pht_idx;
	input wire core_mem_req_ack;
	output reg core_mem_req_valid;
	output reg [150:0] core_mem_req;
	output wire core_store_data_valid;
	output wire [68:0] core_store_data;
	input wire core_store_data_ack;
	input wire [87:0] core_mem_rsp;
	input wire core_mem_rsp_valid;
	output reg [4:0] retire_reg_ptr;
	output reg [63:0] retire_reg_data;
	output reg retire_reg_valid;
	output reg [4:0] retire_reg_two_ptr;
	output reg [63:0] retire_reg_two_data;
	output reg retire_reg_two_valid;
	output reg retire_valid;
	output reg retire_two_valid;
	output reg retire_delay_slot;
	output reg [63:0] retire_pc;
	output reg [63:0] retire_two_pc;
	output reg [6:0] retire_op;
	output reg [6:0] retire_two_op;
	output reg retired_call;
	output reg retired_ret;
	output reg retired_rob_ptr_valid;
	output reg retired_rob_ptr_two_valid;
	output reg [4:0] retired_rob_ptr;
	output reg [4:0] retired_rob_ptr_two;
	output wire got_break;
	output wire got_ud;
	output wire got_bad_addr;
	output wire [5:0] inflight;
	output reg [4:0] core_state;
	output wire [63:0] epc;
	output wire [63:0] badvaddr;
	output wire [4:0] cause;
	output wire [7:0] asid;
	output wire [122:0] tlb_entry_out;
	output wire tlb_entry_out_valid;
	output wire took_irq;
	output wire [31:0] cp0_count;
	output wire l1i_flush_done;
	output wire l1d_flush_done;
	output wire l2_flush_done;
	wire w_in_64b_kernel_mode;
	assign in_64b_kernel_mode = w_in_64b_kernel_mode;
	wire w_in_64b_supervisor_mode;
	assign in_64b_supervisor_mode = w_in_64b_supervisor_mode;
	wire w_in_64b_user_mode;
	assign in_64b_user_mode = w_in_64b_user_mode;
	wire w_irq_pending;
	wire [31:0] w_cp0_count;
	reg [63:0] r_epc;
	reg [63:0] n_epc;
	reg [63:0] r_badvaddr;
	reg [63:0] n_badvaddr;
	wire [63:0] w_exec_epc;
	wire w_sr_bev;
	wire w_sr_exl;
	reg r_exc_in_delay;
	reg n_exc_in_delay;
	localparam N_PRF_ENTRIES = 128;
	localparam N_ROB_ENTRIES = 32;
	localparam N_UQ_ENTRIES = 8;
	localparam N_HILO_ENTRIES = 4;
	localparam N_DQ_ENTRIES = 4;
	localparam HI_EBITS = 32;
	reg t_push_dq_one;
	reg t_push_dq_two;
	reg [198:0] r_dq [3:0];
	reg [2:0] r_dq_head_ptr;
	reg [2:0] n_dq_head_ptr;
	reg [2:0] r_dq_next_head_ptr;
	reg [2:0] n_dq_next_head_ptr;
	reg [2:0] r_dq_next_tail_ptr;
	reg [2:0] n_dq_next_tail_ptr;
	reg [2:0] r_dq_cnt;
	reg [2:0] n_dq_cnt;
	reg [2:0] r_dq_tail_ptr;
	reg [2:0] n_dq_tail_ptr;
	reg t_dq_empty;
	reg t_dq_full;
	reg t_dq_next_empty;
	reg t_dq_next_full;
	reg r_got_restart_ack;
	reg n_got_restart_ack;
	reg [264:0] r_rob [31:0];
	reg [63:0] r_addrs [31:0];
	reg [31:0] r_rob_complete;
	reg [31:0] r_rob_sd_complete;
	wire t_core_store_data_ptr_valid;
	wire [4:0] t_core_store_data_ptr;
	reg t_rob_head_complete;
	reg t_rob_next_head_complete;
	reg [31:0] r_rob_inflight;
	reg [31:0] r_rob_dead_insns;
	reg [31:0] t_clr_mask;
	reg [264:0] t_rob_head;
	reg [264:0] t_rob_next_head;
	reg [264:0] t_rob_tail;
	reg [264:0] t_rob_next_tail;
	reg [127:0] n_prf_free;
	reg [127:0] r_prf_free;
	reg r_bank_sel;
	reg [127:0] n_retire_prf_free;
	reg [127:0] r_retire_prf_free;
	reg [3:0] n_hilo_prf_free;
	reg [3:0] r_hilo_prf_free;
	reg [3:0] n_retire_hilo_prf_free;
	reg [3:0] r_retire_hilo_prf_free;
	reg [1:0] n_hilo_prf_entry;
	wire [2:0] t_hilo_prf_idx;
	reg [6:0] n_prf_entry;
	reg [6:0] n_prf_entry2;
	reg [5:0] r_rob_head_ptr;
	reg [5:0] n_rob_head_ptr;
	reg [5:0] r_rob_next_head_ptr;
	reg [5:0] n_rob_next_head_ptr;
	reg [5:0] r_rob_tail_ptr;
	reg [5:0] n_rob_tail_ptr;
	reg [5:0] r_rob_next_tail_ptr;
	reg [5:0] n_rob_next_tail_ptr;
	reg t_rob_empty;
	reg t_rob_full;
	reg t_rob_next_full;
	reg t_rob_next_empty;
	reg [223:0] r_alloc_rat;
	reg [223:0] n_alloc_rat;
	reg [223:0] r_retire_rat;
	reg [223:0] n_retire_rat;
	reg [1:0] r_hilo_alloc_rat;
	reg [1:0] n_hilo_alloc_rat;
	reg [1:0] r_hilo_retire_rat;
	reg [1:0] n_hilo_retire_rat;
	wire [31:0] uq_wait;
	wire [31:0] mq_wait;
	reg t_alloc;
	reg t_alloc_two;
	reg t_retire;
	reg t_retire_two;
	reg t_rat_copy;
	reg t_clr_rob;
	reg t_possible_to_alloc;
	reg t_fold_uop;
	reg t_fold_uop2;
	reg n_in_delay_slot;
	reg r_in_delay_slot;
	reg t_clr_dq;
	reg t_enough_iprfs;
	reg t_enough_hlprfs;
	reg t_enough_next_iprfs;
	reg t_enough_next_hlprfs;
	reg t_bump_rob_head;
	reg [63:0] n_restart_pc;
	reg [63:0] r_restart_pc;
	reg [63:0] n_restart_src_pc;
	reg [63:0] r_restart_src_pc;
	reg n_restart_src_is_indirect;
	reg r_restart_src_is_indirect;
	reg [63:0] n_branch_pc;
	reg [63:0] r_branch_pc;
	reg n_took_branch;
	reg r_took_branch;
	reg n_branch_valid;
	reg r_branch_valid;
	reg n_branch_fault;
	reg r_branch_fault;
	reg [15:0] n_branch_pht_idx;
	reg [15:0] r_branch_pht_idx;
	reg n_restart_valid;
	reg r_restart_valid;
	reg n_has_delay_slot;
	reg r_has_delay_slot;
	reg n_has_nullifying_delay_slot;
	reg r_has_nullifying_delay_slot;
	reg n_take_br;
	reg r_take_br;
	reg n_got_break;
	reg r_got_break;
	reg n_pending_break;
	reg r_pending_break;
	reg n_pending_ud;
	reg r_pending_ud;
	reg n_pending_bad_addr;
	reg r_pending_bad_addr;
	reg n_got_ud;
	reg r_got_ud;
	reg n_got_bad_addr;
	reg r_got_bad_addr;
	reg n_l1i_flush_complete;
	reg r_l1i_flush_complete;
	reg n_l1d_flush_complete;
	reg r_l1d_flush_complete;
	reg n_l2_flush_complete;
	reg r_l2_flush_complete;
	wire [31:0] t_cpr0_status_reg;
	reg [31:0] r_arch_a0;
	reg [4:0] n_cause;
	reg [4:0] r_cause;
	reg r_tlb_refill;
	reg n_tlb_refill;
	reg r_xtlb_refill;
	reg n_xtlb_refill;
	reg n_save_to_tlb_regs;
	reg r_save_to_tlb_regs;
	reg n_has_badvaddr;
	reg r_has_badvaddr;
	wire [138:0] t_complete_bundle_1;
	wire t_complete_valid_1;
	reg t_any_complete;
	reg t_free_reg;
	reg [6:0] t_free_reg_ptr;
	reg t_free_reg_two;
	reg [6:0] t_free_reg_two_ptr;
	reg t_free_hilo;
	reg [1:0] t_free_hilo_ptr;
	wire [2:0] t_hilo_ffs;
	reg [7:0] t_gpr_ffs;
	reg [7:0] t_gpr_ffs2;
	reg t_gpr_ffs_full;
	reg t_gpr_ffs2_full;
	wire [127:0] w_alu_even;
	wire [127:0] w_alu_odd;
	wire [127:0] w_mem_even;
	wire [127:0] w_mem_odd;
	wire w_alu_even_full;
	wire w_alu_odd_full;
	wire w_mem_even_full;
	wire w_mem_odd_full;
	wire [7:0] w_ffs_alu_even;
	wire [7:0] w_ffs_alu_odd;
	wire [7:0] w_ffs_mem_even;
	wire [7:0] w_ffs_mem_odd;
	wire t_uq_full;
	wire t_uq_next_full;
	wire t_uq_read;
	reg n_ready_for_resume;
	reg r_ready_for_resume;
	wire [150:0] t_mem_req;
	wire t_mem_req_valid;
	reg n_machine_clr;
	reg r_machine_clr;
	reg n_flush_req_l1d;
	reg r_flush_req_l1d;
	reg n_flush_req_l1i;
	reg r_flush_req_l1i;
	reg n_flush_cl_req;
	reg r_flush_cl_req;
	reg [63:0] n_flush_cl_addr;
	reg [63:0] r_flush_cl_addr;
	reg r_ds_done;
	reg n_ds_done;
	reg t_can_retire_rob_head;
	reg t_faulted_head_and_serializing_delay;
	reg t_arch_fault;
	reg [4:0] r_state;
	reg [4:0] n_state;
	reg r_pending_fault;
	reg n_pending_fault;
	reg r_oldest_first_pending;
	reg n_oldest_first_pending;
	reg r_step_d;
	reg r_step_credit;
	reg n_step_credit;
	wire w_step_edge = step & ~r_step_d;
	wire w_step_ok = ~single_step | r_step_credit;
	always @(*) begin
		if (_sv2v_0)
			;
		n_step_credit = r_step_credit;
		if (w_step_edge)
			n_step_credit = 1'b1;
		else if (t_retire)
			n_step_credit = 1'b0;
	end
	always @(posedge clk)
		if (reset) begin
			r_step_d <= 1'b0;
			r_step_credit <= 1'b0;
		end
		else begin
			r_step_d <= step;
			r_step_credit <= n_step_credit;
		end
	reg [31:0] r_restart_cycles;
	reg [31:0] n_restart_cycles;
	wire t_divide_ready;
	always @(*) begin
		if (_sv2v_0)
			;
		core_mem_req_valid = t_mem_req_valid;
		core_mem_req = t_mem_req;
		core_state = r_state;
	end
	assign ready_for_resume = r_ready_for_resume;
	assign head_of_rob_ptr_valid = (r_state == 5'd2) | ((r_state == 5'd3) && !r_ds_done);
	assign head_of_rob_ptr = r_rob_head_ptr[4:0];
	assign head_of_rob_has_delay_slot = t_rob_head[252] | t_rob_head[251];
	assign flush_req_l1d = r_flush_req_l1d;
	assign flush_req_l1i = r_flush_req_l1i;
	assign flush_cl_req = r_flush_cl_req;
	assign flush_cl_addr = r_flush_cl_addr;
	assign got_break = r_got_break;
	assign got_ud = r_got_ud;
	assign got_bad_addr = r_got_bad_addr;
	assign epc = r_epc;
	assign badvaddr = r_badvaddr;
	assign cause = r_cause;
	reg t_wr_epc;
	assign took_irq = t_wr_epc & (r_cause == 5'd0);
	assign cp0_count = w_cp0_count;
	assign l1i_flush_done = n_l1i_flush_complete;
	assign l1d_flush_done = n_l1d_flush_complete;
	assign l2_flush_done = n_l2_flush_complete;
	popcount #(5) inflight0(
		.in(r_rob_inflight),
		.out(inflight)
	);
	reg [198:0] t_uop;
	wire [198:0] t_dec_uop;
	reg [198:0] t_alloc_uop;
	reg [198:0] t_uop2;
	wire [198:0] t_dec_uop2;
	reg [198:0] t_alloc_uop2;
	assign insn_ack = ((!t_dq_full && insn_valid) && (r_state == 5'd2)) && !r_oldest_first_pending;
	assign insn_ack_two = ((((!t_dq_full && insn_valid) && !t_dq_next_full) && insn_valid_two) && (r_state == 5'd2)) && !r_oldest_first_pending;
	assign restart_pc = r_restart_pc;
	assign restart_src_pc = r_restart_src_pc;
	assign restart_src_is_indirect = r_restart_src_is_indirect;
	assign dead_rob_mask = r_rob_dead_insns;
	assign restart_valid = r_restart_valid;
	assign clr_link_reg = (r_state == 5'd10) || (((((r_state == 5'd2) && t_can_retire_rob_head) && t_rob_head[264]) && !t_arch_fault) && (t_rob_head[33-:7] == 7'd76));
	assign branch_pc = r_branch_pc;
	assign branch_pc_valid = r_branch_valid;
	assign branch_fault = r_branch_fault;
	assign branch_pht_idx = r_branch_pht_idx;
	assign took_branch = r_took_branch;
	reg [63:0] r_cycle;
	always @(posedge clk) r_cycle <= (reset ? 'd0 : r_cycle + 'd1);
	always @(posedge clk)
		if (reset) begin
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
		else begin
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
	always @(posedge clk)
		if (reset) begin
			r_state <= 5'd0;
			r_restart_cycles <= 'd0;
			r_machine_clr <= 1'b0;
			r_got_restart_ack <= 1'b0;
			r_cause <= 5'd0;
			r_tlb_refill <= 1'b0;
			r_xtlb_refill <= 1'b0;
			r_save_to_tlb_regs <= 1'b0;
			r_has_badvaddr <= 1'b0;
			r_pending_fault <= 1'b0;
			r_oldest_first_pending <= 1'b0;
		end
		else begin
			r_state <= n_state;
			r_restart_cycles <= n_restart_cycles;
			r_machine_clr <= n_machine_clr;
			r_got_restart_ack <= n_got_restart_ack;
			r_cause <= n_cause;
			r_tlb_refill <= n_tlb_refill;
			r_xtlb_refill <= n_xtlb_refill;
			r_save_to_tlb_regs <= n_save_to_tlb_regs;
			r_has_badvaddr <= n_has_badvaddr;
			r_pending_fault <= n_pending_fault;
			r_oldest_first_pending <= n_oldest_first_pending;
		end
	always @(posedge clk)
		if (reset)
			r_arch_a0 <= 'd0;
		else if ((t_rob_head[254] && t_retire) && (t_rob_head[249-:5] == 'd4))
			r_arch_a0 <= t_rob_head[65:34];
	always @(posedge clk)
		if (reset) begin
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
		else begin
			retire_reg_ptr <= t_rob_head[249-:5];
			retire_reg_data <= t_rob_head[97-:64];
			retire_reg_valid <= t_rob_head[254] && t_retire;
			retire_reg_two_ptr <= t_rob_next_head[249-:5];
			retire_reg_two_data <= t_rob_next_head[97-:64];
			retire_reg_two_valid <= t_rob_next_head[254] && t_retire_two;
			retire_valid <= t_retire;
			retire_two_valid <= t_retire_two;
			retire_pc <= t_rob_head[230-:64];
			retire_two_pc <= t_rob_next_head[230-:64];
			retire_delay_slot <= t_rob_head[250] && t_retire;
			retired_ret <= t_rob_head[259] && t_retire;
			retired_call <= t_rob_head[258] && t_retire;
			retire_op <= t_rob_head[33-:7];
			retire_two_op <= t_rob_next_head[33-:7];
			retired_rob_ptr_valid <= t_retire;
			retired_rob_ptr_two_valid <= t_retire_two;
			retired_rob_ptr <= r_rob_head_ptr[4:0];
			retired_rob_ptr_two <= r_rob_next_head_ptr[4:0];
		end
	reg t_wr_cause;
	reg t_wr_badvaddr;
	reg t_restart_complete;
	reg t_clr_extern_irq;
	reg r_extern_irq;
	always @(posedge clk)
		if (reset)
			r_extern_irq <= 1'b0;
		else if (t_clr_extern_irq)
			r_extern_irq <= 1'b0;
		else if (extern_irq)
			r_extern_irq <= 1'b1;
	function [63:0] sign_extend32;
		input reg [31:0] in;
		reg [63:0] x;
		begin
			x = {{32 {in[31]}}, in};
			sign_extend32 = x;
		end
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		t_wr_epc = 1'b0;
		t_wr_cause = 1'b0;
		t_wr_badvaddr = 1'b0;
		n_has_badvaddr = r_has_badvaddr;
		t_clr_extern_irq = 1'b0;
		t_restart_complete = 1'b0;
		n_cause = r_cause;
		n_tlb_refill = r_tlb_refill;
		n_xtlb_refill = r_xtlb_refill;
		n_machine_clr = r_machine_clr;
		t_alloc = 1'b0;
		t_alloc_two = 1'b0;
		t_possible_to_alloc = 1'b0;
		n_save_to_tlb_regs = r_save_to_tlb_regs;
		n_oldest_first_pending = r_oldest_first_pending;
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
		t_enough_iprfs = !(t_uop[166] && t_gpr_ffs_full);
		t_enough_hlprfs = !(t_uop[164] && (r_hilo_prf_free == 'd0));
		t_enough_next_iprfs = !(t_uop2[166] && t_gpr_ffs2_full);
		t_enough_next_hlprfs = !t_uop2[164];
		t_fold_uop = ((((((t_uop[198-:7] == 7'd75) | (t_uop[198-:7] == 7'd38)) | (t_uop[198-:7] == 7'd118)) | (t_uop[198-:7] == 7'd114)) | (t_uop[198-:7] == 7'd115)) | (t_uop[198-:7] == 7'd116)) | (t_uop[198-:7] == 7'd117);
		t_fold_uop2 = ((((((t_uop2[198-:7] == 7'd75) | (t_uop2[198-:7] == 7'd38)) | (t_uop2[198-:7] == 7'd118)) | (t_uop2[198-:7] == 7'd114)) | (t_uop2[198-:7] == 7'd115)) | (t_uop2[198-:7] == 7'd116)) | (t_uop2[198-:7] == 7'd117);
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
		if (r_state == 5'd2)
			n_got_restart_ack = 1'b0;
		else if (!r_got_restart_ack)
			n_got_restart_ack = restart_ack;
		t_can_retire_rob_head = 1'b0;
		t_faulted_head_and_serializing_delay = 1'b0;
		if (t_rob_head_complete && !t_rob_empty) begin
			t_can_retire_rob_head = ((t_rob_head[252] || t_rob_head[251]) && t_rob_head[264] ? !t_rob_next_empty : 1'b1) & w_step_ok;
			t_faulted_head_and_serializing_delay = ((((t_rob_head[252] || t_rob_head[251]) && t_rob_head[264]) && !t_dq_empty) && t_rob_next_empty) && t_uop[23];
		end
		if (t_complete_valid_1)
			n_pending_fault = r_pending_fault | t_complete_bundle_1[132];
		t_arch_fault = t_rob_head[264] & (((((((((((t_rob_head[99] | t_rob_head[98]) | t_rob_head[263]) | t_rob_head[260]) | t_rob_head[262]) | t_rob_head[261]) | t_rob_head[257]) | (t_rob_head[33-:7] == 7'd115)) | (t_rob_head[33-:7] == 7'd114)) | t_rob_head[9]) | t_rob_head[8]) | t_rob_head[7]);
		(* full_case, parallel_case *)
		case (r_state)
			5'd2:
				if (t_faulted_head_and_serializing_delay)
					n_state = 5'd12;
				else if (t_can_retire_rob_head) begin
					if (t_rob_head[264]) begin
						if (t_arch_fault)
							n_state = 5'd9;
						else begin
							n_ds_done = !t_rob_head[252];
							n_state = 5'd3;
							n_restart_cycles = 'd1;
							n_restart_valid = 1'b1;
							t_bump_rob_head = 1'b1;
						end
						n_machine_clr = 1'b1;
						n_restart_pc = t_rob_head[166-:64];
						n_restart_src_pc = t_rob_head[230-:64];
						n_restart_src_is_indirect = t_rob_head[101] && !t_rob_head[259];
						n_has_delay_slot = t_rob_head[252];
						n_has_nullifying_delay_slot = t_rob_head[251];
						n_take_br = t_rob_head[100];
					end
					else if (!t_dq_empty) begin
						if (t_uop[23]) begin
							if (t_rob_empty)
								n_state = 5'd6;
						end
						else begin
							t_possible_to_alloc = (!t_rob_full && !t_uq_full) && !t_dq_empty;
							t_alloc = (((((!t_rob_full && !t_uq_full) && !t_dq_empty) && t_enough_iprfs) && t_enough_hlprfs) && !r_oldest_first_pending) && (r_pending_fault ? r_in_delay_slot : 1'b1);
							t_alloc_two = ((((((((t_alloc && !t_uop[18]) && !t_uop[21]) && !t_uop2[23]) && !t_uop2[21]) && !t_dq_next_empty) && !t_rob_next_full) && !t_uq_next_full) && t_enough_next_iprfs) && t_enough_next_hlprfs;
						end
					end
					t_retire = t_rob_head_complete & !t_arch_fault;
					t_retire_two = ((((((((!t_rob_next_empty & !t_rob_head[264]) & !t_rob_next_head[264]) & t_rob_head_complete) & t_rob_next_head_complete) & !t_rob_head[102]) & !t_rob_next_head[259]) & !t_rob_next_head[258]) & !t_rob_next_head[253]) & ~single_step;
				end
				else if (!t_dq_empty) begin
					if (t_uop[23] && t_rob_empty)
						n_state = 5'd6;
					else if (!t_uop[23]) begin
						t_possible_to_alloc = (!t_rob_full && !t_uq_full) && !t_dq_empty;
						t_alloc = ((((((!t_rob_full && !t_uop[23]) && !t_uq_full) && !t_dq_empty) && t_enough_iprfs) && t_enough_hlprfs) && !r_oldest_first_pending) && (r_pending_fault ? r_in_delay_slot : 1'b1);
						t_alloc_two = ((((((((t_alloc && !t_uop[18]) && !t_uop[21]) && !t_uop2[23]) && !t_uop2[21]) && !t_dq_next_empty) && !t_rob_next_full) && !t_uq_next_full) && t_enough_next_iprfs) && t_enough_next_hlprfs;
					end
				end
			5'd3: begin
				if ((r_has_nullifying_delay_slot && t_rob_head_complete) && !r_ds_done) begin
					if (r_take_br) begin
						if (t_arch_fault)
							n_state = 5'd9;
						else
							t_retire = 1'b1;
					end
					else
						t_retire = 1'b0;
					n_ds_done = 1'b1;
				end
				else if ((r_has_delay_slot && t_rob_head_complete) && !r_ds_done) begin
					n_ds_done = 1'b1;
					if (t_arch_fault)
						n_state = 5'd9;
					else
						t_retire = 1'b1;
				end
				if ((((r_rob_inflight == 'd0) && r_ds_done) && memq_empty) && t_divide_ready)
					n_state = 5'd4;
			end
			5'd11:
				if (((r_rob_inflight == 'd0) && memq_empty) && t_divide_ready)
					n_state = 5'd4;
			5'd4: begin
				t_rat_copy = 1'b1;
				t_clr_rob = 1'b1;
				t_clr_dq = 1'b1;
				n_machine_clr = 1'b0;
				if (n_got_restart_ack) begin
					n_state = 5'd2;
					n_pending_fault = 1'b0;
					n_ds_done = 1'b0;
					t_restart_complete = 1'b1;
				end
			end
			5'd6: begin
				t_alloc = ((!t_rob_full && !t_uq_full) && (r_prf_free != 'd0)) && !t_dq_empty;
				n_state = (t_alloc ? 5'd8 : 5'd6);
			end
			5'd8:
				if (t_rob_head_complete) begin
					t_clr_dq = 1'b1;
					n_restart_pc = t_rob_head[166-:64];
					n_restart_src_pc = t_rob_head[230-:64];
					n_restart_src_is_indirect = 1'b0;
					n_restart_valid = 1'b1;
					n_pending_fault = 1'b0;
					if (n_got_restart_ack)
						n_state = 5'd2;
				end
			5'd0:
				if ((n_l1i_flush_complete && n_l1d_flush_complete) && n_l2_flush_complete) begin
					n_state = 5'd1;
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
			5'd1:
				if (resume) begin
					n_restart_pc = resume_pc;
					n_restart_src_pc = t_rob_head[230-:64];
					n_restart_src_is_indirect = 1'b0;
					n_restart_valid = 1'b1;
					n_state = 5'd7;
					n_got_break = 1'b0;
					n_got_ud = 1'b0;
					t_clr_dq = 1'b1;
				end
				else
					n_ready_for_resume = 1'b1;
			5'd7: begin
				n_pending_fault = 1'b0;
				if (n_got_restart_ack)
					n_state = 5'd2;
			end
			5'd9: begin
				n_tlb_refill = 1'b0;
				n_xtlb_refill = 1'b0;
				n_has_badvaddr = 1'b0;
				n_save_to_tlb_regs = 1'b0;
				n_badvaddr = r_addrs[r_rob_head_ptr[4:0]];
				if (t_rob_head[99]) begin
					n_pending_break = 1'b1;
					n_cause = 5'd9;
				end
				else if (t_rob_head[98])
					n_cause = 5'd8;
				else if (t_rob_head[263]) begin
					n_pending_ud = 1'b1;
					n_cause = 5'd10;
				end
				else if (t_rob_head[33-:7] == 7'd114) begin
					n_pending_bad_addr = 1'b1;
					n_has_badvaddr = 1'b1;
					n_cause = 5'd4;
				end
				else if (t_rob_head[260]) begin
					n_pending_bad_addr = 1'b1;
					n_has_badvaddr = 1'b1;
					n_cause = (t_rob_head[256] ? 5'd5 : 5'd4);
				end
				else if (t_rob_head[257])
					n_cause = 5'd0;
				else if (t_rob_head[262])
					n_cause = 5'd12;
				else if (t_rob_head[261])
					n_cause = 5'd13;
				else if (t_rob_head[9] | t_rob_head[8]) begin
					n_tlb_refill = t_rob_head[9] & ~w_sr_exl;
					n_xtlb_refill = (t_rob_head[9] & ~w_sr_exl) & ((w_in_64b_kernel_mode | w_in_64b_supervisor_mode) | w_in_64b_user_mode);
					n_save_to_tlb_regs = 1'b1;
					n_cause = (t_rob_head[256] ? 5'd3 : 5'd2);
					n_pending_bad_addr = 1'b1;
					n_has_badvaddr = 1'b1;
				end
				else if (t_rob_head[7]) begin
					n_cause = 5'd1;
					n_save_to_tlb_regs = 1'b1;
					n_pending_bad_addr = 1'b1;
					n_has_badvaddr = 1'b1;
				end
				t_bump_rob_head = 1'b1;
				n_state = 5'd10;
				n_epc = (t_rob_head[250] ? t_rob_head[230-:64] - 'd4 : t_rob_head[230-:64]);
				n_exc_in_delay = t_rob_head[250];
			end
			5'd10: begin
				t_wr_epc = 1'b1;
				t_wr_cause = 1'b1;
				t_wr_badvaddr = r_has_badvaddr;
				n_machine_clr = 1'b1;
				n_restart_pc = sign_extend32((w_sr_bev ? 32'hbfc00000 : 32'h80000000) | (r_tlb_refill ? (r_xtlb_refill ? 32'h00000080 : 32'h00000000) : 32'h00000180));
				n_restart_src_pc = 'd0;
				n_restart_src_is_indirect = 1'b0;
				n_restart_valid = 1'b1;
				n_got_break = 1'b0;
				n_got_ud = 1'b0;
				t_clr_dq = 1'b1;
				n_ds_done = 1'b1;
				n_state = 5'd11;
			end
			5'd12: begin
				t_alloc = ((!t_rob_full && !t_uq_full) && (r_prf_free != 'd0)) && !t_dq_empty;
				n_state = (t_alloc ? 5'd13 : 5'd12);
			end
			5'd13:
				if (t_rob_next_head_complete) begin
					if (t_rob_next_head[264]) begin
						$display("hello???");
						if (t_rob_next_head[99]) begin
							n_cause = 5'd9;
							n_state = 5'd10;
						end
						else if (t_rob_head[98]) begin
							n_cause = 5'd8;
							n_state = 5'd10;
						end
						else if (t_rob_head[261]) begin
							n_cause = 5'd13;
							n_state = 5'd10;
						end
					end
					else begin
						n_pending_fault = 1'b0;
						n_state = 5'd2;
					end
				end
			default:
				;
		endcase
		if (t_clr_rob)
			n_oldest_first_pending = 1'b0;
		else if ((t_retire && t_rob_head[10]) || (t_retire_two && t_rob_next_head[10]))
			n_oldest_first_pending = 1'b0;
		else if (t_alloc && t_uop[21])
			n_oldest_first_pending = 1'b1;
		if (t_alloc)
			n_in_delay_slot = (t_alloc_two ? t_uop2[158] : t_uop[158]);
		else if (t_clr_dq || t_clr_rob)
			n_in_delay_slot = 1'b0;
	end
	always @(posedge clk)
		if (reset) begin
			r_rob_head_ptr <= 'd0;
			r_rob_tail_ptr <= 'd0;
			r_rob_next_head_ptr <= 'd1;
			r_rob_next_tail_ptr <= 'd1;
		end
		else begin
			r_rob_head_ptr <= n_rob_head_ptr;
			r_rob_tail_ptr <= n_rob_tail_ptr;
			r_rob_next_head_ptr <= n_rob_next_head_ptr;
			r_rob_next_tail_ptr <= n_rob_next_tail_ptr;
		end
	always @(posedge clk)
		if (reset) begin
			r_hilo_alloc_rat <= 'd0;
			r_hilo_retire_rat <= 'd0;
		end
		else begin
			r_hilo_alloc_rat <= (t_rat_copy ? r_hilo_retire_rat : n_hilo_alloc_rat);
			r_hilo_retire_rat <= n_hilo_retire_rat;
		end
	always @(posedge clk)
		if (reset) begin : sv2v_autoblock_1
			reg [6:0] i_rat;
			for (i_rat = 'd0; i_rat < 'd32; i_rat = i_rat + 'd1)
				begin
					r_alloc_rat[i_rat[4:0] * 7+:7] <= i_rat;
					r_retire_rat[i_rat[4:0] * 7+:7] <= i_rat;
				end
		end
		else begin
			r_alloc_rat <= (t_rat_copy ? r_retire_rat : n_alloc_rat);
			r_retire_rat <= n_retire_rat;
		end
	always @(*) begin
		if (_sv2v_0)
			;
		n_alloc_rat = r_alloc_rat;
		n_hilo_alloc_rat = r_hilo_alloc_rat;
		t_alloc_uop = t_uop;
		t_alloc_uop2 = t_uop2;
		if (t_uop[184])
			t_alloc_uop[191-:7] = r_alloc_rat[t_uop[189:185] * 7+:7];
		if (t_uop[175])
			t_alloc_uop[182-:7] = r_alloc_rat[t_uop[180:176] * 7+:7];
		if (t_uop[161])
			t_alloc_uop[160-:2] = r_hilo_alloc_rat;
		if (t_uop2[184])
			t_alloc_uop2[191-:7] = (t_uop[166] && (t_uop2[189:185] == t_uop[171:167]) ? n_prf_entry : r_alloc_rat[t_uop2[189:185] * 7+:7]);
		if (t_uop2[175])
			t_alloc_uop2[182-:7] = (t_uop[166] && (t_uop2[180:176] == t_uop[171:167]) ? n_prf_entry : r_alloc_rat[t_uop2[180:176] * 7+:7]);
		if (t_uop2[161])
			t_alloc_uop2[160-:2] = (t_uop[164] ? n_hilo_prf_entry : r_hilo_alloc_rat);
		if (t_alloc) begin
			if (t_uop[166]) begin
				n_alloc_rat[t_uop[171:167] * 7+:7] = n_prf_entry;
				t_alloc_uop[173-:7] = n_prf_entry;
			end
			else if (t_uop[164]) begin
				n_hilo_alloc_rat = n_hilo_prf_entry;
				t_alloc_uop[163-:2] = n_hilo_prf_entry;
			end
			t_alloc_uop[28-:5] = r_rob_tail_ptr[4:0];
		end
		if (t_alloc_two) begin
			if (t_uop2[166]) begin
				n_alloc_rat[t_uop2[171:167] * 7+:7] = n_prf_entry2;
				t_alloc_uop2[173-:7] = n_prf_entry2;
			end
			t_alloc_uop2[28-:5] = r_rob_next_tail_ptr[4:0];
		end
	end
	always @(*) begin
		if (_sv2v_0)
			;
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
		n_branch_pc = {{HI_EBITS {1'b0}}, 32'd0};
		n_took_branch = 1'b0;
		n_branch_valid = 1'b0;
		n_branch_fault = 1'b0;
		n_branch_pht_idx = 'd0;
		if (t_retire) begin
			if (t_rob_head[254]) begin
				t_free_reg = 1'b1;
				t_free_reg_ptr = t_rob_head[237-:7];
				n_retire_rat[t_rob_head[249-:5] * 7+:7] = t_rob_head[244-:7];
				n_retire_prf_free[t_rob_head[244-:7]] = 1'b0;
				n_retire_prf_free[t_rob_head[237-:7]] = 1'b1;
			end
			else if (t_rob_head[253]) begin
				t_free_hilo = 1'b1;
				t_free_hilo_ptr = t_rob_head[232:231];
				n_hilo_retire_rat = t_rob_head[239:238];
				n_retire_hilo_prf_free[t_rob_head[239:238]] = 1'b0;
				n_retire_hilo_prf_free[t_rob_head[232:231]] = 1'b1;
			end
			if (t_retire_two && t_rob_next_head[254]) begin
				t_free_reg_two = 1'b1;
				t_free_reg_two_ptr = t_rob_next_head[237-:7];
				n_retire_rat[t_rob_next_head[249-:5] * 7+:7] = t_rob_next_head[244-:7];
				n_retire_prf_free[t_rob_next_head[244-:7]] = 1'b0;
				n_retire_prf_free[t_rob_next_head[237-:7]] = 1'b1;
			end
			n_branch_pc = (t_retire_two ? t_rob_next_head[230-:64] : t_rob_head[230-:64]);
			n_took_branch = (t_retire_two ? t_rob_next_head[100] : t_rob_head[100]);
			n_branch_valid = (t_retire_two ? t_rob_next_head[102] : t_rob_head[102]);
			n_branch_fault = t_rob_head[264];
			n_branch_pht_idx = (t_retire_two ? t_rob_next_head[26-:16] : t_rob_head[26-:16]);
		end
	end
	function is_store;
		input reg [6:0] op;
		reg x;
		begin
			case (op)
				7'd49: x = 1'b1;
				7'd50: x = 1'b1;
				7'd51: x = 1'b1;
				7'd68: x = 1'b1;
				7'd64: x = 1'b1;
				7'd63: x = 1'b1;
				7'd89: x = 1'b1;
				7'd108: x = 1'b1;
				7'd109: x = 1'b1;
				7'd112: x = 1'b1;
				default: x = 1'b0;
			endcase
			is_store = x;
		end
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		t_rob_tail[264] = 1'b0;
		t_rob_tail[254] = 1'b0;
		t_rob_tail[253] = 1'b0;
		t_rob_tail[249-:5] = 'd0;
		t_rob_tail[244-:7] = 'd0;
		t_rob_tail[237-:7] = 'd0;
		t_rob_tail[230-:64] = t_alloc_uop[92-:64];
		t_rob_tail[166-:64] = 'd0;
		t_rob_tail[258] = ((t_alloc_uop[198-:7] == 7'd39) || (t_alloc_uop[198-:7] == 7'd7)) || (t_alloc_uop[198-:7] == 7'd65);
		t_rob_tail[257] = t_alloc_uop[198-:7] == 7'd118;
		t_rob_tail[259] = (t_alloc_uop[198-:7] == 7'd6) && (t_uop[191-:7] == 'd31);
		t_rob_tail[99] = t_alloc_uop[198-:7] == 7'd69;
		t_rob_tail[98] = t_alloc_uop[198-:7] == 7'd77;
		t_rob_tail[101] = (t_alloc_uop[198-:7] == 7'd7) || (t_alloc_uop[198-:7] == 7'd6);
		t_rob_tail[255] = t_alloc_uop[198-:7] == 7'd81;
		t_rob_tail[263] = 1'b0;
		t_rob_tail[262] = 1'b0;
		t_rob_tail[261] = 1'b0;
		t_rob_tail[9] = 1'b0;
		t_rob_tail[8] = 1'b0;
		t_rob_tail[7] = 1'b0;
		t_rob_tail[6] = 1'b0;
		t_rob_tail[5-:6] = 6'd0;
		t_rob_tail[260] = 1'b0;
		t_rob_tail[100] = 1'b0;
		t_rob_tail[102] = t_alloc_uop[18];
		t_rob_tail[256] = is_store(t_alloc_uop[198-:7]);
		t_rob_tail[250] = r_in_delay_slot;
		t_rob_tail[97-:64] = 'd0;
		t_rob_tail[33-:7] = t_alloc_uop[198-:7];
		t_rob_tail[26-:16] = t_alloc_uop[15-:16];
		t_rob_tail[10] = t_uop[21];
		t_rob_next_tail[264] = 1'b0;
		t_rob_next_tail[254] = 1'b0;
		t_rob_next_tail[253] = 1'b0;
		t_rob_next_tail[249-:5] = 'd0;
		t_rob_next_tail[244-:7] = 'd0;
		t_rob_next_tail[237-:7] = 'd0;
		t_rob_next_tail[230-:64] = t_alloc_uop2[92-:64];
		t_rob_next_tail[166-:64] = 'd0;
		t_rob_next_tail[33-:7] = t_alloc_uop2[198-:7];
		t_rob_next_tail[258] = ((t_alloc_uop2[198-:7] == 7'd39) || (t_alloc_uop2[198-:7] == 7'd7)) || (t_alloc_uop2[198-:7] == 7'd65);
		t_rob_next_tail[257] = t_alloc_uop2[198-:7] == 7'd118;
		t_rob_next_tail[259] = (t_alloc_uop2[198-:7] == 7'd6) && (t_uop[191-:7] == 'd31);
		t_rob_next_tail[99] = t_alloc_uop2[198-:7] == 7'd69;
		t_rob_next_tail[98] = t_alloc_uop2[198-:7] == 7'd77;
		t_rob_next_tail[255] = t_alloc_uop2[198-:7] == 7'd81;
		t_rob_next_tail[101] = (t_alloc_uop2[198-:7] == 7'd7) || (t_alloc_uop2[198-:7] == 7'd6);
		t_rob_next_tail[262] = 1'b0;
		t_rob_next_tail[261] = 1'b0;
		t_rob_next_tail[9] = 1'b0;
		t_rob_next_tail[8] = 1'b0;
		t_rob_next_tail[7] = 1'b0;
		t_rob_next_tail[6] = 1'b0;
		t_rob_next_tail[5-:6] = 6'd0;
		t_rob_next_tail[263] = 1'b0;
		t_rob_next_tail[260] = 1'b0;
		t_rob_next_tail[100] = 1'b0;
		t_rob_next_tail[102] = t_alloc_uop2[18];
		t_rob_next_tail[256] = is_store(t_alloc_uop2[198-:7]);
		t_rob_next_tail[250] = r_in_delay_slot;
		t_rob_next_tail[97-:64] = 'd0;
		t_rob_next_tail[26-:16] = t_alloc_uop2[15-:16];
		t_rob_next_tail[10] = t_uop2[21];
		t_rob_tail[252] = t_alloc_uop[158];
		t_rob_tail[251] = t_alloc_uop[157];
		t_rob_next_tail[252] = t_uop2[158];
		t_rob_next_tail[251] = t_uop2[157];
		if (t_alloc) begin
			if (t_uop[166]) begin
				t_rob_tail[254] = 1'b1;
				t_rob_tail[249-:5] = t_uop[171:167];
				t_rob_tail[244-:7] = n_prf_entry;
				t_rob_tail[237-:7] = r_alloc_rat[t_uop[171:167] * 7+:7];
			end
			else if (t_uop[164]) begin
				t_rob_tail[253] = 1'b1;
				t_rob_tail[244-:7] = {{5 {1'b0}}, n_hilo_prf_entry};
				t_rob_tail[237-:7] = {{5 {1'b0}}, r_hilo_alloc_rat};
			end
			if (t_fold_uop) begin
				if (t_uop[198-:7] == 7'd117) begin
					t_rob_tail[264] = 1'b1;
					t_rob_tail[263] = 1'b1;
				end
				else if (t_uop[198-:7] == 7'd115) begin
					t_rob_tail[264] = 1'b1;
					t_rob_tail[9] = 1'b1;
				end
				else if (t_uop[198-:7] == 7'd116) begin
					t_rob_tail[264] = 1'b1;
					t_rob_tail[8] = 1'b1;
				end
				else if (t_uop[198-:7] == 7'd114)
					t_rob_tail[264] = 1'b1;
				else if (t_uop[198-:7] == 7'd118)
					t_rob_tail[264] = 1'b1;
				else if (t_uop[198-:7] == 7'd38)
					t_rob_tail[100] = 1'b1;
			end
		end
		if (t_alloc_two) begin
			t_rob_next_tail[250] = t_uop[158];
			if (t_uop2[166]) begin
				t_rob_next_tail[254] = 1'b1;
				t_rob_next_tail[249-:5] = t_uop2[171:167];
				t_rob_next_tail[244-:7] = n_prf_entry2;
				t_rob_next_tail[237-:7] = (t_uop[166] && (t_uop[173-:7] == t_uop2[173-:7]) ? t_rob_tail[244-:7] : r_alloc_rat[t_uop2[171:167] * 7+:7]);
			end
			if (t_fold_uop2) begin
				if (t_uop2[198-:7] == 7'd117) begin
					t_rob_next_tail[264] = 1'b1;
					t_rob_next_tail[263] = 1'b1;
				end
				else if (t_uop2[198-:7] == 7'd115) begin
					t_rob_next_tail[264] = 1'b1;
					t_rob_next_tail[9] = 1'b1;
				end
				else if (t_uop2[198-:7] == 7'd116) begin
					t_rob_next_tail[264] = 1'b1;
					t_rob_next_tail[8] = 1'b1;
				end
				else if (t_uop2[198-:7] == 7'd114)
					t_rob_next_tail[264] = 1'b1;
				else if (t_uop2[198-:7] == 7'd118)
					t_rob_next_tail[264] = 1'b1;
				else if (t_uop2[198-:7] == 7'd38)
					t_rob_next_tail[100] = 1'b1;
			end
		end
	end
	always @(posedge clk)
		if (reset || t_clr_rob) begin
			r_rob_complete <= 'd0;
			r_rob_sd_complete <= 'd0;
		end
		else begin
			if (t_alloc) begin
				r_rob_complete[r_rob_tail_ptr[4:0]] <= t_fold_uop;
				r_rob_sd_complete[r_rob_tail_ptr[4:0]] <= !(t_uop[17] & t_uop[175]);
			end
			if (t_alloc_two) begin
				r_rob_complete[r_rob_next_tail_ptr[4:0]] <= t_fold_uop2;
				r_rob_sd_complete[r_rob_next_tail_ptr[4:0]] <= !(t_uop2[17] & t_uop2[175]);
			end
			if (t_complete_valid_1)
				r_rob_complete[t_complete_bundle_1[138:134]] <= t_complete_bundle_1[133];
			if (core_mem_rsp_valid)
				r_rob_complete[core_mem_rsp[23-:5]] <= 1'b1;
			if (t_core_store_data_ptr_valid)
				r_rob_sd_complete[t_core_store_data_ptr] <= 1'b1;
		end
	always @(posedge clk)
		if (reset || t_clr_rob) begin : sv2v_autoblock_2
			integer i;
			for (i = 0; i < N_ROB_ENTRIES; i = i + 1)
				r_rob[i][264] <= 1'b0;
		end
		else begin
			if (t_alloc)
				r_rob[r_rob_tail_ptr[4:0]] <= t_rob_tail;
			if (t_alloc_two)
				r_rob[r_rob_next_tail_ptr[4:0]] <= t_rob_next_tail;
			if (t_complete_valid_1) begin
				r_rob[t_complete_bundle_1[138:134]][264] <= t_complete_bundle_1[132];
				r_rob[t_complete_bundle_1[138:134]][166-:64] <= t_complete_bundle_1[131-:64];
				r_rob[t_complete_bundle_1[138:134]][263] <= t_complete_bundle_1[66];
				r_rob[t_complete_bundle_1[138:134]][100] <= t_complete_bundle_1[67];
				r_rob[t_complete_bundle_1[138:134]][97-:64] <= t_complete_bundle_1[63-:64];
				r_rob[t_complete_bundle_1[138:134]][262] <= t_complete_bundle_1[65];
				r_rob[t_complete_bundle_1[138:134]][261] <= t_complete_bundle_1[64];
			end
			if (core_mem_rsp_valid) begin
				r_rob[core_mem_rsp[23-:5]][97-:64] <= core_mem_rsp[87-:64];
				r_rob[core_mem_rsp[23-:5]][264] <= ((core_mem_rsp[10] | core_mem_rsp[9]) | core_mem_rsp[8]) | core_mem_rsp[7];
				r_rob[core_mem_rsp[23-:5]][9] <= core_mem_rsp[9];
				r_rob[core_mem_rsp[23-:5]][8] <= core_mem_rsp[8];
				r_rob[core_mem_rsp[23-:5]][7] <= core_mem_rsp[7];
				r_rob[core_mem_rsp[23-:5]][6] <= core_mem_rsp[6];
				r_rob[core_mem_rsp[23-:5]][5-:6] <= core_mem_rsp[5-:6];
				r_rob[core_mem_rsp[23-:5]][260] <= core_mem_rsp[10];
				r_addrs[core_mem_rsp[23-:5]] <= core_mem_rsp[87:24];
				if (t_alloc && (((t_uop[198-:7] == 7'd115) || (t_uop[198-:7] == 7'd116)) || (t_uop[198-:7] == 7'd114)))
					r_addrs[r_rob_tail_ptr[4:0]] <= t_alloc_uop[92-:64];
				if (t_alloc_two && (((t_uop2[198-:7] == 7'd115) || (t_uop2[198-:7] == 7'd116)) || (t_uop2[198-:7] == 7'd114)))
					r_addrs[r_rob_next_tail_ptr[4:0]] <= t_alloc_uop2[92-:64];
			end
		end
	always @(posedge clk)
		if (reset || t_clr_rob)
			r_rob_dead_insns <= 'd0;
		else begin
			if (t_retire)
				r_rob_dead_insns[r_rob_head_ptr[4:0]] <= 1'b0;
			if (t_retire_two)
				r_rob_dead_insns[r_rob_next_head_ptr[4:0]] <= 1'b0;
			if (t_alloc)
				r_rob_dead_insns[r_rob_tail_ptr[4:0]] <= 1'b1;
			if (t_alloc_two)
				r_rob_dead_insns[r_rob_next_tail_ptr[4:0]] <= 1'b1;
		end
	always @(*) begin
		if (_sv2v_0)
			;
		t_clr_mask = uq_wait | mq_wait;
		if (t_complete_valid_1)
			t_clr_mask[t_complete_bundle_1[138-:5]] = 1'b1;
		if (core_mem_rsp_valid)
			t_clr_mask[core_mem_rsp[23-:5]] = 1'b1;
	end
	always @(posedge clk)
		if (reset)
			r_rob_inflight <= 'd0;
		else if (r_ds_done)
			r_rob_inflight <= r_rob_inflight & ~t_clr_mask;
		else begin
			if (t_complete_valid_1)
				r_rob_inflight[t_complete_bundle_1[138-:5]] <= 1'b0;
			if (core_mem_rsp_valid)
				r_rob_inflight[core_mem_rsp[23-:5]] <= 1'b0;
			if (t_alloc && !t_fold_uop)
				r_rob_inflight[r_rob_tail_ptr[4:0]] <= 1'b1;
			if (t_alloc_two && !t_fold_uop2)
				r_rob_inflight[r_rob_next_tail_ptr[4:0]] <= 1'b1;
		end
	always @(*) begin
		if (_sv2v_0)
			;
		n_rob_head_ptr = r_rob_head_ptr;
		n_rob_tail_ptr = r_rob_tail_ptr;
		n_rob_next_head_ptr = r_rob_next_head_ptr;
		n_rob_next_tail_ptr = r_rob_next_tail_ptr;
		if (t_clr_rob) begin
			n_rob_head_ptr = 'd0;
			n_rob_tail_ptr = 'd0;
			n_rob_next_head_ptr = 'd1;
			n_rob_next_tail_ptr = 'd1;
		end
		else begin
			if (t_alloc && !t_alloc_two) begin
				n_rob_tail_ptr = r_rob_tail_ptr + 'd1;
				n_rob_next_tail_ptr = r_rob_next_tail_ptr + 'd1;
			end
			else if (t_alloc && t_alloc_two) begin
				n_rob_tail_ptr = r_rob_tail_ptr + 'd2;
				n_rob_next_tail_ptr = r_rob_next_tail_ptr + 'd2;
			end
			if (t_retire || t_bump_rob_head) begin
				n_rob_head_ptr = (t_retire_two ? r_rob_head_ptr + 'd2 : r_rob_head_ptr + 'd1);
				n_rob_next_head_ptr = (t_retire_two ? r_rob_next_head_ptr + 'd2 : r_rob_next_head_ptr + 'd1);
			end
		end
		t_rob_empty = r_rob_head_ptr == r_rob_tail_ptr;
		t_rob_next_empty = r_rob_next_head_ptr == r_rob_tail_ptr;
		t_rob_full = (r_rob_head_ptr[4:0] == r_rob_tail_ptr[4:0]) && (r_rob_head_ptr != r_rob_tail_ptr);
		t_rob_next_full = (r_rob_head_ptr[4:0] == r_rob_next_tail_ptr[4:0]) && (r_rob_head_ptr != r_rob_next_tail_ptr);
	end
	always @(*) begin
		if (_sv2v_0)
			;
		t_rob_head = r_rob[r_rob_head_ptr[4:0]];
		t_rob_next_head = r_rob[r_rob_next_head_ptr[4:0]];
		t_rob_head_complete = r_rob_sd_complete[r_rob_head_ptr[4:0]] & r_rob_complete[r_rob_head_ptr[4:0]];
		t_rob_next_head_complete = r_rob_sd_complete[r_rob_next_head_ptr[4:0]] & r_rob_complete[r_rob_next_head_ptr[4:0]];
	end
	always @(posedge clk)
		if (reset) begin : sv2v_autoblock_3
			integer i;
			for (i = 0; i < N_HILO_ENTRIES; i = i + 1)
				begin
					r_hilo_prf_free[i] <= (i == 0 ? 1'b0 : 1'b1);
					r_retire_hilo_prf_free[i] <= (i == 0 ? 1'b0 : 1'b1);
				end
		end
		else begin
			r_hilo_prf_free <= (t_rat_copy ? r_retire_hilo_prf_free : n_hilo_prf_free);
			r_retire_hilo_prf_free <= n_retire_hilo_prf_free;
		end
	always @(posedge clk)
		if (reset) begin : sv2v_autoblock_4
			integer i;
			for (i = 0; i < N_PRF_ENTRIES; i = i + 1)
				begin
					r_prf_free[i] <= (i < 32 ? 1'b0 : 1'b1);
					r_retire_prf_free[i] <= (i < 32 ? 1'b0 : 1'b1);
				end
		end
		else begin
			r_prf_free <= (t_rat_copy ? r_retire_prf_free : n_prf_free);
			r_retire_prf_free <= n_retire_prf_free;
		end
	find_first_set #(2) ffs_hilo(
		.in(r_hilo_prf_free),
		.y(t_hilo_ffs)
	);
	always @(*) begin
		if (_sv2v_0)
			;
		n_hilo_prf_free = r_hilo_prf_free;
		n_hilo_prf_entry = t_hilo_ffs[1:0];
		if (t_alloc & t_uop[164])
			n_hilo_prf_free[n_hilo_prf_entry] = 1'b0;
		if (t_free_hilo)
			n_hilo_prf_free[t_free_hilo_ptr] = 1'b1;
	end
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < N_PRF_ENTRIES; _gv_i_1 = _gv_i_1 + 1) begin : prf_pool_split
			localparam i = _gv_i_1;
			assign w_alu_even[i] = ((i < 64) && ((i % 2) == 0) ? r_prf_free[i] : 1'b0);
			assign w_alu_odd[i] = ((i < 64) && ((i % 2) == 1) ? r_prf_free[i] : 1'b0);
			assign w_mem_even[i] = ((i >= 64) && ((i % 2) == 0) ? r_prf_free[i] : 1'b0);
			assign w_mem_odd[i] = ((i >= 64) && ((i % 2) == 1) ? r_prf_free[i] : 1'b0);
		end
	endgenerate
	assign w_alu_even_full = |w_alu_even == 1'b0;
	assign w_alu_odd_full = |w_alu_odd == 1'b0;
	assign w_mem_even_full = |w_mem_even == 1'b0;
	assign w_mem_odd_full = |w_mem_odd == 1'b0;
	find_first_set #(7) ffs_ae(
		.in(w_alu_even),
		.y(w_ffs_alu_even)
	);
	find_first_set #(7) ffs_ao(
		.in(w_alu_odd),
		.y(w_ffs_alu_odd)
	);
	find_first_set #(7) ffs_me(
		.in(w_mem_even),
		.y(w_ffs_mem_even)
	);
	find_first_set #(7) ffs_mo(
		.in(w_mem_odd),
		.y(w_ffs_mem_odd)
	);
	always @(posedge clk) r_bank_sel <= (reset ? 1'b0 : ~r_bank_sel);
	always @(*) begin
		if (_sv2v_0)
			;
		if (t_uop[17]) begin
			t_gpr_ffs = (r_bank_sel ? w_ffs_mem_even : w_ffs_mem_odd);
			t_gpr_ffs_full = (r_bank_sel ? w_mem_even_full : w_mem_odd_full);
		end
		else begin
			t_gpr_ffs = (r_bank_sel ? w_ffs_alu_even : w_ffs_alu_odd);
			t_gpr_ffs_full = (r_bank_sel ? w_alu_even_full : w_alu_odd_full);
		end
		if (t_uop2[17]) begin
			t_gpr_ffs2 = (r_bank_sel ? w_ffs_mem_odd : w_ffs_mem_even);
			t_gpr_ffs2_full = (r_bank_sel ? w_mem_odd_full : w_mem_even_full);
		end
		else begin
			t_gpr_ffs2 = (r_bank_sel ? w_ffs_alu_odd : w_ffs_alu_even);
			t_gpr_ffs2_full = (r_bank_sel ? w_alu_odd_full : w_alu_even_full);
		end
	end
	always @(*) begin
		if (_sv2v_0)
			;
		n_prf_free = r_prf_free;
		n_prf_entry = t_gpr_ffs[6:0];
		n_prf_entry2 = t_gpr_ffs2[6:0];
		if (t_alloc & t_uop[166])
			n_prf_free[n_prf_entry] = 1'b0;
		if (t_alloc_two && t_uop2[166])
			n_prf_free[n_prf_entry2] = 1'b0;
		if (t_free_reg)
			n_prf_free[t_free_reg_ptr] = 1'b1;
		if (t_free_reg_two)
			n_prf_free[t_free_reg_two_ptr] = 1'b1;
	end
	reg t_dec0_in_delay_slot;
	reg t_dec1_in_delay_slot;
	reg n_dec_delay_slot;
	reg r_dec_delay_slot;
	always @(*) begin
		if (_sv2v_0)
			;
		n_dec_delay_slot = r_dec_delay_slot;
		t_dec0_in_delay_slot = 1'b0;
		t_dec1_in_delay_slot = 1'b0;
		if (t_push_dq_two) begin
			if (r_dec_delay_slot) begin
				t_dec0_in_delay_slot = 1'b1;
				n_dec_delay_slot = insn_two[0];
			end
			else if (insn[0])
				t_dec1_in_delay_slot = 1'b1;
			else if (insn_two[0])
				n_dec_delay_slot = 1'b1;
		end
		else if (t_push_dq_one) begin
			if (r_dec_delay_slot) begin
				t_dec0_in_delay_slot = 1'b1;
				n_dec_delay_slot = 1'b0;
			end
			else if (insn[0])
				n_dec_delay_slot = 1'b1;
		end
	end
	always @(posedge clk)
		if (reset)
			r_dec_delay_slot <= 1'b0;
		else
			r_dec_delay_slot <= (t_clr_rob ? 1'b0 : n_dec_delay_slot);
	decode_mips dec0(
		.in_kernel_mode(in_kernel_mode),
		.in_supervisor_mode(in_supervisor_mode),
		.in_user_mode(in_user_mode),
		.in_64b_kernel_mode(w_in_64b_kernel_mode),
		.in_64b_supervisor_mode(w_in_64b_supervisor_mode),
		.in_64b_user_mode(w_in_64b_user_mode),
		.irq(w_irq_pending & (t_dec0_in_delay_slot == 1'b0)),
		.tlb_miss(insn[2]),
		.tlb_invalid(insn[1]),
		.misaligned(insn[3]),
		.insn(insn[180-:32]),
		.pc(insn[148-:64]),
		.insn_pred(insn[20]),
		.pht_idx(insn[19-:16]),
		.insn_pred_target(insn[84-:64]),
		.uop(t_dec_uop)
	);
	decode_mips dec1(
		.in_kernel_mode(in_kernel_mode),
		.in_supervisor_mode(in_supervisor_mode),
		.in_user_mode(in_user_mode),
		.in_64b_kernel_mode(w_in_64b_kernel_mode),
		.in_64b_supervisor_mode(w_in_64b_supervisor_mode),
		.in_64b_user_mode(w_in_64b_user_mode),
		.irq(w_irq_pending & (t_dec1_in_delay_slot == 1'b0)),
		.tlb_miss(insn_two[2]),
		.tlb_invalid(insn_two[1]),
		.misaligned(insn_two[3]),
		.insn(insn_two[180-:32]),
		.pc(insn_two[148-:64]),
		.insn_pred(insn_two[20]),
		.pht_idx(insn_two[19-:16]),
		.insn_pred_target(insn_two[84-:64]),
		.uop(t_dec_uop2)
	);
	reg t_push_1;
	reg t_push_2;
	always @(*) begin
		if (_sv2v_0)
			;
		t_any_complete = t_complete_valid_1 | core_mem_rsp_valid;
		t_push_1 = t_alloc && !t_fold_uop;
		t_push_2 = t_alloc_two && !t_fold_uop2;
	end
	reg t_wr_tlbp;
	reg t_tlbp_hit;
	reg [5:0] t_tlbp_index;
	always @(*) begin
		if (_sv2v_0)
			;
		t_wr_tlbp = 1'b0;
		t_tlbp_hit = 1'b0;
		t_tlbp_index = 6'd0;
		if (t_retire_two & t_rob_next_head[255]) begin
			t_wr_tlbp = 1'b1;
			t_tlbp_hit = t_rob_next_head[6];
			t_tlbp_index = t_rob_next_head[5-:6];
		end
		else if (t_retire & t_rob_head[255]) begin
			t_wr_tlbp = 1'b1;
			t_tlbp_hit = t_rob_head[6];
			t_tlbp_index = t_rob_head[5-:6];
		end
	end
	exec e(
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
		.sr_exl(w_sr_exl),
		.core_wr_cause(t_wr_cause),
		.core_wr_badvaddr(t_wr_badvaddr),
		.core_badvaddr(r_badvaddr),
		.save_to_tlb_regs(r_save_to_tlb_regs),
		.exc_in_delay(r_exc_in_delay),
		.in_kernel_mode(in_kernel_mode),
		.in_supervisor_mode(in_supervisor_mode),
		.in_user_mode(in_user_mode),
		.in_64b_kernel_mode(w_in_64b_kernel_mode),
		.in_64b_supervisor_mode(w_in_64b_supervisor_mode),
		.in_64b_user_mode(w_in_64b_user_mode),
		.putchar_fifo_out(putchar_fifo_out),
		.putchar_fifo_empty(putchar_fifo_empty),
		.putchar_fifo_pop(putchar_fifo_pop),
		.putchar_fifo_wptr(putchar_fifo_wptr),
		.putchar_fifo_rptr(putchar_fifo_rptr),
		.divide_ready(t_divide_ready),
		.ds_done(r_ds_done),
		.mem_dq_clr(t_clr_rob),
		.restart_complete(t_restart_complete),
		.head_of_rob_ptr_valid(head_of_rob_ptr_valid),
		.head_of_rob_ptr(head_of_rob_ptr),
		.cpr0_status_reg(t_cpr0_status_reg),
		.mq_wait(mq_wait),
		.uq_wait(uq_wait),
		.uq_full(t_uq_full),
		.uq_next_full(t_uq_next_full),
		.uq_uop((t_push_1 ? t_alloc_uop : t_alloc_uop2)),
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
		.mem_rsp_dst_ptr(core_mem_rsp[18-:7]),
		.mem_rsp_dst_valid(core_mem_rsp[11]),
		.mem_rsp_load_data(core_mem_rsp[87-:64]),
		.mem_rsp_rob_ptr(core_mem_rsp[23-:5]),
		.irq_pending(w_irq_pending),
		.cp0_count(w_cp0_count)
	);
	always @(posedge clk)
		if (reset) begin
			r_dq_head_ptr <= 'd0;
			r_dq_next_head_ptr <= 'd1;
			r_dq_next_tail_ptr <= 'd1;
			r_dq_tail_ptr <= 'd0;
			r_dq_cnt <= 'd0;
		end
		else begin
			r_dq_head_ptr <= (t_clr_rob ? 'd0 : n_dq_head_ptr);
			r_dq_tail_ptr <= (t_clr_rob ? 'd0 : n_dq_tail_ptr);
			r_dq_next_head_ptr <= (t_clr_rob ? 'd1 : n_dq_next_head_ptr);
			r_dq_next_tail_ptr <= (t_clr_rob ? 'd1 : n_dq_next_tail_ptr);
			r_dq_cnt <= (t_clr_rob ? 'd0 : n_dq_cnt);
		end
	always @(posedge clk) begin
		if (t_push_dq_one)
			r_dq[r_dq_tail_ptr[1:0]] <= t_dec_uop;
		if (t_push_dq_two)
			r_dq[r_dq_next_tail_ptr[1:0]] <= t_dec_uop2;
	end
	always @(negedge clk)
		if ((insn_ack && insn_ack_two) && 1'b0)
			$display("ack two insns in cycle %d, valid %b, %b, pc %x %x", r_cycle, insn_valid, insn_valid_two, insn[148-:64], insn_two[148-:64]);
		else if ((insn_ack && !insn_ack_two) && 1'b0)
			$display("ack one insn in cycle %d, valid %b, pc %x ", r_cycle, insn_valid, insn[148-:64]);
	always @(*) begin
		if (_sv2v_0)
			;
		t_push_dq_one = 1'b0;
		t_push_dq_two = 1'b0;
		n_dq_tail_ptr = r_dq_tail_ptr;
		n_dq_head_ptr = r_dq_head_ptr;
		n_dq_next_head_ptr = r_dq_next_head_ptr;
		n_dq_next_tail_ptr = r_dq_next_tail_ptr;
		t_dq_empty = r_dq_tail_ptr == r_dq_head_ptr;
		t_dq_next_empty = r_dq_tail_ptr == r_dq_next_head_ptr;
		t_dq_full = (r_dq_tail_ptr[1:0] == r_dq_head_ptr[1:0]) && (r_dq_tail_ptr != r_dq_head_ptr);
		t_dq_next_full = (r_dq_next_tail_ptr[1:0] == r_dq_head_ptr[1:0]) && (r_dq_next_tail_ptr != r_dq_head_ptr);
		n_dq_cnt = r_dq_cnt;
		t_uop = r_dq[r_dq_head_ptr[1:0]];
		t_uop2 = r_dq[r_dq_next_head_ptr[1:0]];
		if (t_clr_dq) begin
			n_dq_tail_ptr = 'd0;
			n_dq_head_ptr = 'd0;
			n_dq_next_head_ptr = 'd1;
			n_dq_next_tail_ptr = 'd1;
			n_dq_cnt = 'd0;
		end
		else begin
			if (((insn_valid && !t_dq_full) && !(!t_dq_next_full && insn_valid_two)) && !r_oldest_first_pending) begin
				t_push_dq_one = 1'b1;
				n_dq_tail_ptr = r_dq_tail_ptr + 'd1;
				n_dq_next_tail_ptr = r_dq_next_tail_ptr + 'd1;
				n_dq_cnt = n_dq_cnt + 'd1;
			end
			else if ((((insn_valid && !t_dq_full) && !t_dq_next_full) && insn_valid_two) && !r_oldest_first_pending) begin
				t_push_dq_one = 1'b1;
				t_push_dq_two = 1'b1;
				n_dq_tail_ptr = r_dq_tail_ptr + 'd2;
				n_dq_next_tail_ptr = r_dq_next_tail_ptr + 'd2;
				n_dq_cnt = n_dq_cnt + 'd2;
			end
			if (t_alloc && !t_alloc_two) begin
				n_dq_head_ptr = r_dq_head_ptr + 'd1;
				n_dq_next_head_ptr = r_dq_next_head_ptr + 'd1;
				n_dq_cnt = n_dq_cnt - 'd1;
			end
			else if (t_alloc && t_alloc_two) begin
				n_dq_head_ptr = r_dq_head_ptr + 'd2;
				n_dq_next_head_ptr = r_dq_next_head_ptr + 'd2;
				n_dq_cnt = n_dq_cnt - 'd2;
			end
		end
	end
	initial _sv2v_0 = 0;
endmodule

module tlb (
	clk,
	reset,
	asid,
	active,
	req,
	va,
	pa,
	hit,
	hit_index,
	dirty,
	valid,
	tlb_entry_in_valid,
	tlb_entry_in
);
	input wire clk;
	input wire reset;
	input [7:0] asid;
	input wire active;
	input wire req;
	input wire [63:0] va;
	output reg [63:0] pa;
	output reg hit;
	output reg [5:0] hit_index;
	output reg dirty;
	output reg valid;
	input wire tlb_entry_in_valid;
	input wire [122:0] tlb_entry_in;
	parameter ISIDE = 0;
	localparam N = 48;
	localparam LG_N = 6;
	localparam NN = 64;
	wire [63:0] w_hits4k;
	wire [63:0] w_hits64k;
	wire [63:0] w_hits2m;
	wire [63:0] w_hits1g;
	wire [63:0] w_hits;
	reg [122:0] r_tlb [47:0];
	wire [63:0] w_addr_space_match;
	wire [63:0] w_hit8k;
	always @(posedge clk)
		if (tlb_entry_in_valid)
			r_tlb[tlb_entry_in[122-:6]] <= tlb_entry_in;
	wire [LG_N:0] w_idx;
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = N; _gv_i_1 < NN; _gv_i_1 = _gv_i_1 + 1) begin : genblk1
			localparam i = _gv_i_1;
			assign w_addr_space_match[i] = 1'b0;
			assign w_hit8k[i] = 1'b0;
			assign w_hits[i] = 1'b0;
		end
	endgenerate
	genvar _gv_i_2;
	generate
		for (_gv_i_2 = 0; _gv_i_2 < N; _gv_i_2 = _gv_i_2 + 1) begin : hits
			localparam i = _gv_i_2;
			assign w_addr_space_match[i] = (r_tlb[i][104-:8] == asid) | (r_tlb[i][37] & r_tlb[i][3]);
			assign w_hit8k[i] = (r_tlb[i][94-:27] == va[39:13]) && (r_tlb[i][96-:2] == va[63:62]);
			assign w_hits[i] = w_addr_space_match[i] & w_hit8k[i];
		end
	endgenerate
	find_first_set #(.LG_N(LG_N)) ffs(
		.in(w_hits),
		.y(w_idx)
	);
	wire [5:0] w_hit_idx = w_idx[5:0];
	wire w_odd = va[12];
	wire [27:0] w_pfn = (w_odd ? r_tlb[w_hit_idx][33-:28] : r_tlb[w_hit_idx][67-:28]);
	wire w_dirty = (w_odd ? r_tlb[w_hit_idx][5] : r_tlb[w_hit_idx][39]);
	wire w_valid = (w_odd ? r_tlb[w_hit_idx][4] : r_tlb[w_hit_idx][38]);
	wire [39:0] w_pa4k = {w_pfn, va[11:0]};
	always @(posedge clk) begin
		hit <= (reset ? 1'b0 : (active ? req & |w_hits : 1'b1));
		hit_index <= (reset ? 'd0 : w_hit_idx);
		dirty <= (reset ? 1'b0 : (active ? w_dirty : 1'b1));
		valid <= (reset ? 1'b0 : (active ? w_valid : 1'b1));
		pa <= (active ? {{24 {1'b0}}, w_pa4k} : va);
	end
endmodule

module fair_sched (
	clk,
	rst,
	in,
	y
);
	reg _sv2v_0;
	parameter LG_N = 2;
	localparam N = 1 << LG_N;
	input wire clk;
	input wire rst;
	input wire [N - 1:0] in;
	output reg [LG_N:0] y;
	wire any_valid = |in;
	reg [LG_N - 1:0] r_cnt;
	wire [LG_N - 1:0] n_cnt;
	reg [(2 * N) - 1:0] t_in2;
	reg [(2 * N) - 1:0] t_in_shift;
	reg [N - 1:0] t_in;
	wire [LG_N:0] t_y;
	always @(*) begin
		if (_sv2v_0)
			;
		t_in2 = {in, in};
		t_in_shift = t_in2 << r_cnt;
		t_in = t_in_shift[(2 * N) - 1:N];
	end
	always @(posedge clk)
		if (rst)
			r_cnt <= 'd0;
		else
			r_cnt <= (any_valid ? r_cnt + 'd1 : r_cnt);
	find_first_set #(LG_N) f(
		.in(t_in),
		.y(t_y)
	);
	wire [LG_N - 1:0] w_yy = t_y[LG_N - 1:0] - r_cnt;
	always @(*) begin
		if (_sv2v_0)
			;
		y = {LG_N + 1 {1'b1}};
		if (any_valid)
			y = {1'b0, w_yy};
	end
	initial _sv2v_0 = 0;
endmodule

module l2 (
	clk,
	reset,
	state,
	rsp_state,
	l1i_flush_req,
	l1d_flush_req,
	l1i_flush_complete,
	l1d_flush_complete,
	flush_complete,
	l1_mem_req_valid,
	l1_mem_req_ack,
	l1_mem_req_addr,
	l1_mem_req_cacheable,
	l1_mem_req_mask,
	l1_mem_req_store_data,
	l1_mem_req_opcode,
	l1_mem_rsp_valid,
	l1_mem_load_data,
	mem_req_ack,
	mem_req_valid,
	mem_req_addr,
	mem_req_store_data,
	mem_req_opcode,
	mem_req_mask,
	mem_rsp_valid,
	mem_rsp_bad,
	mem_rsp_load_data,
	cache_hits,
	cache_accesses
);
	reg _sv2v_0;
	input wire clk;
	input wire reset;
	output wire [3:0] state;
	output wire [3:0] rsp_state;
	input wire l1i_flush_req;
	input wire l1d_flush_req;
	input wire l1i_flush_complete;
	input wire l1d_flush_complete;
	output wire flush_complete;
	input wire l1_mem_req_valid;
	output wire l1_mem_req_ack;
	input wire [63:0] l1_mem_req_addr;
	input wire l1_mem_req_cacheable;
	input wire [15:0] l1_mem_req_mask;
	input wire [127:0] l1_mem_req_store_data;
	input wire [4:0] l1_mem_req_opcode;
	output wire l1_mem_rsp_valid;
	output wire [127:0] l1_mem_load_data;
	input wire mem_req_ack;
	output wire mem_req_valid;
	output wire [63:0] mem_req_addr;
	output wire [127:0] mem_req_store_data;
	output wire [4:0] mem_req_opcode;
	output wire [15:0] mem_req_mask;
	input wire mem_rsp_valid;
	input wire mem_rsp_bad;
	input wire [127:0] mem_rsp_load_data;
	output wire [63:0] cache_hits;
	output wire [63:0] cache_accesses;
	localparam LG_L2_LINES = 10;
	localparam L2_LINES = 1024;
	localparam TAG_BITS = 50;
	reg t_wr_dirty;
	reg t_wr_valid;
	reg t_wr_d0;
	reg t_wr_tag;
	reg t_valid;
	reg t_dirty;
	reg [9:0] t_idx;
	reg [9:0] r_idx;
	reg [49:0] n_tag;
	reg [49:0] r_tag;
	reg [63:0] n_addr;
	reg [63:0] r_addr;
	reg [63:0] n_saveaddr;
	reg [63:0] r_saveaddr;
	reg [4:0] n_opcode;
	reg [4:0] r_opcode;
	reg r_mem_req;
	reg n_mem_req;
	reg [4:0] r_mem_opcode;
	reg [4:0] n_mem_opcode;
	reg r_req_ack;
	reg n_req_ack;
	reg r_rsp_valid;
	reg n_rsp_valid;
	reg [127:0] r_rsp_data;
	reg [127:0] n_rsp_data;
	reg [127:0] r_store_data;
	reg [127:0] n_store_data;
	reg [15:0] r_store_mask;
	reg [15:0] n_store_mask;
	reg n_is_uncache;
	reg r_is_uncache;
	reg [15:0] n_uncache_mask;
	reg [15:0] r_uncache_mask;
	reg r_reload;
	reg n_reload;
	reg r_need_l1i;
	reg n_need_l1i;
	reg r_need_l1d;
	reg n_need_l1d;
	reg t_l2_flush_req;
	reg n_flush_state;
	reg r_flush_state;
	reg [3:0] n_state;
	reg [3:0] r_state;
	reg n_flush_complete;
	reg r_flush_complete;
	reg r_flush_req;
	reg n_flush_req;
	reg [127:0] r_mem_req_store_data;
	reg [127:0] n_mem_req_store_data;
	reg [63:0] r_cache_hits;
	reg [63:0] n_cache_hits;
	reg [63:0] r_cache_accesses;
	reg [63:0] n_cache_accesses;
	reg n_got_mem_rsp_valid;
	reg r_got_mem_rsp_valid;
	reg [3:0] r_rsp_state;
	assign state = r_state;
	assign rsp_state = r_rsp_state;
	always @(posedge clk)
		if (n_got_mem_rsp_valid & (r_got_mem_rsp_valid == 1'b0))
			r_rsp_state <= r_state;
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
	reg [127:0] t_d0;
	wire [127:0] w_d0;
	wire [49:0] w_tag;
	wire w_valid;
	wire w_dirty;
	reg_ram1rw #(
		.WIDTH(128),
		.LG_DEPTH(LG_L2_LINES)
	) data_ram0(
		.clk(clk),
		.addr(t_idx),
		.wr_data(t_d0),
		.wr_en(t_wr_d0),
		.rd_data(w_d0)
	);
	reg_ram1rw #(
		.WIDTH(TAG_BITS),
		.LG_DEPTH(LG_L2_LINES)
	) tag_ram(
		.clk(clk),
		.addr(t_idx),
		.wr_data(r_tag),
		.wr_en(t_wr_tag),
		.rd_data(w_tag)
	);
	reg_ram1rw #(
		.WIDTH(1),
		.LG_DEPTH(LG_L2_LINES)
	) valid_ram(
		.clk(clk),
		.addr(t_idx),
		.wr_data(t_valid),
		.wr_en(t_wr_valid),
		.rd_data(w_valid)
	);
	reg_ram1rw #(
		.WIDTH(1),
		.LG_DEPTH(LG_L2_LINES)
	) dirty_ram(
		.clk(clk),
		.addr(t_idx),
		.wr_data(t_dirty),
		.wr_en(t_wr_dirty),
		.rd_data(w_dirty)
	);
	wire w_hit = (w_valid ? r_tag == w_tag : 1'b0);
	wire w_need_wb = (w_valid ? w_dirty : 1'b0);
	always @(posedge clk)
		if (reset) begin
			r_state <= 4'd0;
			r_flush_state <= 1'd0;
			r_flush_complete <= 1'b0;
			r_idx <= 'd0;
			r_tag <= 'd0;
			r_opcode <= 5'd0;
			r_addr <= 'd0;
			r_saveaddr <= 'd0;
			r_mem_req <= 1'b0;
			r_mem_opcode <= 5'd0;
			r_rsp_data <= 'd0;
			r_rsp_valid <= 1'b0;
			r_reload <= 1'b0;
			r_req_ack <= 1'b0;
			r_store_data <= 'd0;
			r_store_mask <= 'd0;
			r_is_uncache <= 1'b0;
			r_uncache_mask <= 'd0;
			r_flush_req <= 1'b0;
			r_need_l1d <= 1'b0;
			r_need_l1i <= 1'b0;
			r_got_mem_rsp_valid <= 1'b0;
			r_cache_hits <= 'd0;
			r_cache_accesses <= 'd0;
		end
		else begin
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
			r_is_uncache <= n_is_uncache;
			r_uncache_mask <= n_uncache_mask;
			r_flush_req <= n_flush_req;
			r_need_l1i <= n_need_l1i;
			r_need_l1d <= n_need_l1d;
			r_got_mem_rsp_valid <= n_got_mem_rsp_valid;
			r_cache_hits <= n_cache_hits;
			r_cache_accesses <= n_cache_accesses;
		end
	always @(posedge clk) r_mem_req_store_data <= n_mem_req_store_data;
	always @(*) begin
		if (_sv2v_0)
			;
		n_flush_state = r_flush_state;
		n_need_l1d = r_need_l1d | l1d_flush_req;
		n_need_l1i = r_need_l1i | l1i_flush_req;
		t_l2_flush_req = 1'b0;
		case (r_flush_state)
			1'd0:
				if (n_need_l1i | n_need_l1d)
					n_flush_state = 1'd1;
			1'd1: begin
				if (r_need_l1d && l1d_flush_complete)
					n_need_l1d = 1'b0;
				if (r_need_l1i && l1i_flush_complete)
					n_need_l1i = 1'b0;
				if ((n_need_l1d == 1'b0) && (n_need_l1i == 1'b0)) begin
					n_flush_state = 1'd0;
					t_l2_flush_req = 1'b1;
				end
			end
		endcase
	end
	reg [31:0] r_cycle;
	always @(posedge clk) r_cycle <= (reset ? 'd0 : r_cycle + 'd1);
	reg [3:0] r_last_state;
	always @(posedge clk) r_last_state <= r_state;
	always @(negedge clk)
		if ((r_state == 4'd1) & r_mem_req) begin
			$display("l2 protocol busted, last state %d", r_last_state);
			$stop;
		end
	always @(*) begin
		if (_sv2v_0)
			;
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
		n_is_uncache = r_is_uncache;
		n_uncache_mask = r_uncache_mask;
		n_flush_req = r_flush_req | t_l2_flush_req;
		n_mem_req_store_data = r_mem_req_store_data;
		n_cache_hits = r_cache_hits;
		n_cache_accesses = r_cache_accesses;
		n_got_mem_rsp_valid = r_got_mem_rsp_valid | mem_rsp_valid;
		case (r_state)
			4'd0: begin
				t_valid = 1'b0;
				t_dirty = 1'b0;
				t_wr_valid = 1'b1;
				t_wr_dirty = 1'b1;
				t_idx = r_idx + 'd1;
				if (r_idx == 1023) begin
					n_state = 4'd1;
					n_flush_complete = 1'b1;
				end
			end
			4'd1: begin
				t_idx = l1_mem_req_addr[13:4];
				n_tag = l1_mem_req_addr[63:14];
				n_addr = {l1_mem_req_addr[63:4], 4'd0};
				n_saveaddr = {l1_mem_req_addr[63:4], 4'd0};
				n_opcode = l1_mem_req_opcode;
				n_store_data = l1_mem_req_store_data;
				n_store_mask = 16'h0000;
				if (n_flush_req) begin
					t_idx = 'd0;
					n_state = 4'd10;
					n_store_mask = 16'hffff;
				end
				else if (l1_mem_req_valid) begin
					if (l1_mem_req_cacheable == 1'b0) begin
						n_uncache_mask = l1_mem_req_mask;
						n_store_mask = l1_mem_req_mask;
						n_mem_opcode = l1_mem_req_opcode;
						n_mem_req_store_data = l1_mem_req_store_data;
						n_req_ack = 1'b1;
						n_is_uncache = 1'b1;
						n_state = 4'd2;
					end
					else begin
						n_req_ack = 1'b1;
						n_state = 4'd2;
						n_rsp_valid = l1_mem_req_opcode == 5'd7;
						n_is_uncache = 1'b0;
						n_cache_accesses = r_cache_accesses + 64'd1;
						n_cache_hits = r_cache_hits + 64'd1;
					end
				end
			end
			4'd2: n_state = 4'd3;
			4'd3:
				if (r_is_uncache) begin
					n_is_uncache = 1'b0;
					if (w_hit) begin
						t_wr_valid = 1'b1;
						t_valid = 1'b0;
						t_wr_dirty = 1'b1;
						t_dirty = 1'b0;
						if (w_dirty) begin
							n_mem_req_store_data = w_d0;
							n_addr = {w_tag, t_idx, 4'd0};
							n_mem_opcode = 5'd7;
							n_store_mask = 16'hffff;
							n_mem_req = 1'b1;
							n_got_mem_rsp_valid = 1'b0;
							n_state = 4'd15;
						end
						else begin
							n_addr = r_saveaddr;
							n_mem_opcode = r_opcode;
							n_store_mask = r_uncache_mask;
							n_mem_req_store_data = r_store_data;
							n_mem_req = 1'b1;
							n_got_mem_rsp_valid = 1'b0;
							n_state = (r_opcode == 5'd7 ? 4'd12 : 4'd13);
						end
					end
					else begin
						n_addr = r_saveaddr;
						n_mem_opcode = r_opcode;
						n_store_mask = r_uncache_mask;
						n_mem_req_store_data = r_store_data;
						n_mem_req = 1'b1;
						n_got_mem_rsp_valid = 1'b0;
						n_state = (r_opcode == 5'd7 ? 4'd12 : 4'd13);
					end
				end
				else if (w_hit) begin
					n_reload = 1'b0;
					if (r_opcode == 5'd4) begin
						n_rsp_data = w_d0;
						n_state = 4'd1;
						n_rsp_valid = 1'b1;
					end
					else if (r_opcode == 5'd7) begin
						t_wr_dirty = 1'b1;
						t_dirty = 1'b1;
						n_state = 4'd8;
						t_d0 = r_store_data;
						t_wr_d0 = 1'b1;
					end
				end
				else begin
					n_cache_hits = r_cache_hits - 64'd1;
					if (w_dirty) begin
						n_mem_req_store_data = w_d0;
						n_addr = {w_tag, t_idx, 4'd0};
						n_mem_opcode = 5'd7;
						n_store_mask = 16'hffff;
						n_mem_req = 1'b1;
						n_got_mem_rsp_valid = 1'b0;
						n_state = 4'd5;
					end
					else begin
						n_reload = 1'b1;
						n_state = 4'd4;
						n_mem_opcode = 5'd4;
						n_store_mask = 16'hffff;
						n_mem_req = 1'b1;
						n_got_mem_rsp_valid = 1'b0;
					end
				end
			4'd5: begin
				if (mem_req_ack)
					n_mem_req = 1'b0;
				if (mem_rsp_valid) begin
					n_addr = r_saveaddr;
					n_mem_opcode = 5'd4;
					n_store_mask = 16'hffff;
					n_state = 4'd6;
					n_mem_req = 1'b0;
				end
			end
			4'd6: begin
				n_state = 4'd4;
				n_reload = 1'b1;
				n_mem_req = 1'b1;
				n_got_mem_rsp_valid = 1'b0;
			end
			4'd4: begin
				if (mem_req_ack)
					n_mem_req = 1'b0;
				if (mem_rsp_valid) begin
					n_mem_req = 1'b0;
					t_valid = 1'b1;
					t_wr_valid = 1'b1;
					t_wr_tag = 1'b1;
					t_wr_d0 = 1'b1;
					n_state = 4'd7;
				end
			end
			4'd7: n_state = 4'd2;
			4'd8: n_state = 4'd1;
			4'd10: begin
				n_state = 4'd11;
				t_valid = 1'b0;
				t_dirty = 1'b0;
				t_wr_valid = 1'b1;
				t_wr_dirty = 1'b1;
			end
			4'd11:
				if (w_need_wb) begin
					n_mem_req_store_data = w_d0;
					n_addr = {w_tag, t_idx, 4'd0};
					n_mem_opcode = 5'd7;
					n_mem_req = 1'b1;
					n_got_mem_rsp_valid = 1'b0;
					n_state = 4'd9;
				end
				else begin
					t_idx = r_idx + 'd1;
					if (r_idx == 1023) begin
						n_state = 4'd1;
						n_flush_complete = 1'b1;
						n_flush_req = 1'b0;
					end
					else
						n_state = 4'd10;
				end
			4'd9: begin
				if (mem_req_ack)
					n_mem_req = 1'b0;
				if (mem_rsp_valid) begin
					n_mem_req = 1'b0;
					t_idx = r_idx + 'd1;
					if (r_idx == 1023) begin
						n_state = 4'd1;
						n_flush_complete = 1'b1;
						n_flush_req = 1'b0;
					end
					else
						n_state = 4'd10;
				end
			end
			4'd12: begin
				if (mem_req_ack)
					n_mem_req = 1'b0;
				if (mem_rsp_valid) begin
					n_state = 4'd1;
					n_rsp_valid = 1'b1;
					n_mem_req = 1'b0;
				end
			end
			4'd13: begin
				if (mem_req_ack)
					n_mem_req = 1'b0;
				if (mem_rsp_valid) begin
					n_rsp_valid = 1'b1;
					n_rsp_data = mem_rsp_load_data;
					n_state = 4'd1;
					n_mem_req = 1'b0;
				end
			end
			4'd15: begin
				if (mem_req_ack)
					n_mem_req = 1'b0;
				if (mem_rsp_valid) begin
					n_addr = r_saveaddr;
					n_mem_opcode = r_opcode;
					n_store_mask = r_uncache_mask;
					n_mem_req_store_data = r_store_data;
					n_mem_req = 1'b1;
					n_got_mem_rsp_valid = 1'b0;
					n_state = (r_opcode == 5'd7 ? 4'd12 : 4'd13);
				end
			end
			default:
				;
		endcase
	end
	initial _sv2v_0 = 0;
endmodule

