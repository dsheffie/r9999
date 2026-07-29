`include "uop.vh"
`include "machine.vh"

/* CLZ-accelerated integer divider, ported from rv64core/nu_divider.sv into the
 * r9999 MIPS core.  Variable-latency non-restoring division: count_leading_zeros
 * on the partial remainder vs the divisor lets it SKIP the leading-zero quotient
 * iterations, so typical operands finish in a handful of cycles instead of a
 * fixed full 64.  Drop-in replacement for divider.sv (same MIPS HILO interface).
 *
 * MIPS adaptation vs the RISC-V original:
 *   - y = {HI=remainder, LO=quotient} -- BOTH produced in one op (no is_rem mux;
 *     MIPS div writes HI and LO together).
 *   - is_32b selects div/ddiv: 32-bit operands are sign/zero-extended up front,
 *     and BOTH result halves are sign-extended out.
 *   - is_signed_div selects signed/unsigned in the one module (unsigned_divider.sv
 *     is retired).
 *   - hilo_prf_ptr instead of the GPR prf pointer.
 *
 * wb_slot_used: the CLZ skip means the result is ready EARLY; hold it until a
 * writeback slot is free (wb_slot_used==0).  exec.sv reserves DIV32_LAT/DIV64_LAT
 * at issue as a backstop, so a free slot is guaranteed by the worst-case latency,
 * but the divider drains at the FIRST free slot -- improving throughput.
 *
 * (rv64core's repeat-operand cache is intentionally omitted in this first cut --
 * it has signed-magnitude reuse subtleties worth validating separately; the CLZ
 * skip is the primary win.)
 */
module nu_divider(clk,
		  reset,
		  wb_slot_used,
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

   parameter LG_W = 5;
   localparam W = 1<<LG_W;
   localparam W2 = 2*W;

   input logic clk;
   input logic reset;
   input logic wb_slot_used;
   input logic [W-1:0] srcA;
   input logic [W-1:0] srcB;
   input logic	       is_32b;

   input logic [`LG_ROB_ENTRIES-1:0] rob_ptr_in;
   input logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_in;

   input logic 	      is_signed_div;
   input logic 	      start_div;

   output logic [W2-1:0] y;

   output logic [`LG_ROB_ENTRIES-1:0] rob_ptr_out;
   output logic [`LG_HILO_PRF_ENTRIES-1:0] hilo_prf_ptr_out;

   output logic        ready;
   output logic        complete;

   typedef enum logic [2:0] {IDLE = 'd0,
			     CLZ = 'd1,
			     DIVIDE = 'd2,
			     PACK_OUTPUT = 'd3,
			     WAIT_FOR_WB = 'd4
			     } state_t;

   state_t r_state, n_state;
   logic 	r_is_signed, n_is_signed;
   logic 	r_sign, n_sign;
   logic 	r_rem_sign, n_rem_sign;

   logic [`LG_ROB_ENTRIES-1:0] r_rob_ptr, n_rob_ptr;
   logic [`LG_HILO_PRF_ENTRIES-1:0] r_hilo_prf_ptr, n_hilo_prf_ptr;

   logic [W-1:0] 		    r_A, n_A, r_B, n_B;
   logic [W2-1:0] 		    r_Y, n_Y;
   logic [W2-1:0] 		    r_D, n_D, r_R, n_R;
   logic [W-1:0] 		    t_ss;
   logic			    r_is_32b, n_is_32b;

   logic [LG_W+1:0] 		    r_idx, n_idx;
   logic 			    t_bit, t_valid, t_clr;

   /* MIPS div/ddiv: 32-bit operands sign/zero-extended to the full width first */
   logic [W-1:0] extA, extB;
   always_comb
     begin
	extA = srcA;
	extB = srcB;
	if(is_32b)
	  begin
	     extA = { {(W-32){is_signed_div ? srcA[31] : 1'b0}}, srcA[31:0] };
	     extB = { {(W-32){is_signed_div ? srcB[31] : 1'b0}}, srcB[31:0] };
	  end
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= IDLE;
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
	else
	  begin
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
     end // always_ff

   /* quotient accumulator: OR t_bit into position r_idx each DIVIDE step */
   always_ff@(posedge clk)
     begin
	if(reset | t_clr)
	  t_ss <= 'd0;
	else if(t_valid)
	  t_ss <= t_ss | ( {{(W-1){1'b0}}, t_bit} << r_idx[LG_W-1:0] );
     end

   wire [LG_W+1:0] w_clz_R, w_clz_D;
   count_leading_zeros #(.LG_N(LG_W+1)) clz0 (.in({r_R[W2-2:0], 1'b0}), .y(w_clz_R));
   count_leading_zeros #(.LG_N(LG_W+1)) clz1 (.in(r_D), .y(w_clz_D));
   wire [LG_W+1:0] w_clz_delta = w_clz_R - w_clz_D;

   always_comb
     begin
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
	t_clr = 1'b0;
	n_is_32b = r_is_32b;

	//output signals
	ready = (r_state == IDLE) & !start_div;
	rob_ptr_out = r_rob_ptr;
	hilo_prf_ptr_out = r_hilo_prf_ptr;
	y = r_Y;
	complete = 1'b0;

	unique case (r_state)
	  IDLE:
	    begin
	       t_clr = 1'b1;
	       n_is_32b = is_32b;
	       n_rob_ptr = rob_ptr_in;
	       n_hilo_prf_ptr = hilo_prf_ptr_in;
	       n_is_signed = is_signed_div;
	       n_state = start_div ? CLZ : IDLE;
	       n_idx = W-1;
	       n_sign = extA[W-1] ^ extB[W-1];
	       n_rem_sign = extA[W-1];
	       n_A = is_signed_div & extA[W-1] ? ((~extA) + 'd1) : extA;
	       n_B = is_signed_div & extB[W-1] ? ((~extB) + 'd1) : extB;
	       n_D = {n_B, {W{1'b0}}};
	       n_R = {{W{1'b0}}, n_A};
	    end // case: IDLE
	  CLZ:
	    begin
	       n_state = DIVIDE;
	       /* R has more leading zeros than D (R < D): shift R up to align and
		* skip that many quotient iterations (those bits are 0). */
	       if(w_clz_delta <= 'd64)
		 begin
		    n_R = r_R << (w_clz_R - w_clz_D);
		    n_idx = r_idx - (w_clz_R - w_clz_D);
		    /* underflow (idx wrapped all-ones) => quotient is done */
		    n_state = (n_idx == {(LG_W+2){1'b1}}) ? PACK_OUTPUT : DIVIDE;
		 end
	    end
	  DIVIDE:
	    begin
	       if({r_R[W2-2:0], 1'b0} >= r_D)
		 begin
		    n_R = {r_R[W2-2:0], 1'b0} - r_D;
		    t_bit = 1'b1;
		    t_valid = 1'b1;
		 end
	       else
		 begin
		    n_R = {r_R[W2-2:0], 1'b0};
		    t_bit = 1'b0;
		    t_valid = 1'b1;
		 end
	       n_state = (r_idx == 'd0) ? PACK_OUTPUT : DIVIDE;
	       n_idx = r_idx - 'd1;
	    end // case: DIVIDE
	  PACK_OUTPUT:
	    begin
	       n_state = WAIT_FOR_WB;
	       n_Y[W-1:0]  = t_ss;             /* LO = quotient  */
	       n_Y[W2-1:W] = n_R[W2-1:W];      /* HI = remainder */
	       if(r_is_signed && r_sign)
		 n_Y[W-1:0] = (~t_ss) + 'd1;
	       if(r_is_signed && r_rem_sign)
		 n_Y[W2-1:W] = (~n_R[W2-1:W]) + 'd1;
	       if(r_is_32b & (`M_WIDTH == 64))
		 begin
		    n_Y[63:0]   = { {32{n_Y[31]}}, n_Y[31:0]};   /* sign-extend quotient  */
		    n_Y[127:64] = { {32{n_Y[95]}}, n_Y[95:64]};  /* sign-extend remainder */
		 end
	    end // case: PACK_OUTPUT
	  WAIT_FOR_WB:
	    begin
	       /* result ready; drain at the first free writeback slot */
	       if(wb_slot_used == 1'b0)
		 begin
		    complete = 1'b1;
		    n_state = IDLE;
		 end
	    end
	  default:
	    begin
	    end
	endcase // case r_state
     end // always_comb

endmodule // nu_divider
