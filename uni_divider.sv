`include "uop.vh"
`include "machine.vh"

/* Unified iterative divider: MIPS integer div/divu/ddiv/ddivu + IEEE-754 FP
 * divide + FP square root (SP/DP) on ONE restoring recurrence and ONE subtractor.
 *
 * Why: nu_divider (integer only) is 2.3K LUTs, almost all of it the CLZ trees and
 * the 128-bit barrel shifter of its exact leading-zero skip -- a dhrystone-era
 * optimisation.  Meanwhile FP div/sqrt had NO datapath (fpu.sv raises the
 * Unimplemented bit and the OS emulates every one: applu spends 83% of its time
 * in the kernel).  fpu_iter.sv proved the FP recurrences bit-exact vs SoftFloat;
 * this module keeps that front end (unpack/specials) and back end (round/pack)
 * and shares the datapath with the integer divide.
 *
 * The recurrence, "shift first, then compare" so all three ops look the same:
 *	lhs  = r_rem					(partial remainder, already shifted)
 *	rhs  = divisor			(int, FP div)	| {root, 2'b01}		(sqrt)
 *	bit  = (lhs >= rhs);	sel = bit ? lhs - rhs : lhs;	q = {q, bit}
 *	r_rem <= {sel, next 1 src bit}	(int, FP div)	| {sel, next 2 src bits} (sqrt)
 * r_src feeds the dividend bits (int), the radicand bit pairs (sqrt), zeros (FP div).
 *
 * The dhrystone "cheat": instead of an exact CLZ skip, a COARSE one -- if the top
 * 56/48/32 bits of |A| are zero run only 8/16/32 steps (a 4:1 mux, not a barrel
 * shifter).  Skipped steps would have produced quotient bit 0, EXCEPT when the
 * divisor is 0 (every bit is 1 there), so the skip is off for B==0: results are
 * bit-identical to nu_divider for ALL operands, including the div-by-zero and
 * INT_MIN/-1 conventions the co-sim reference was matched to.
 *
 * Integer-side ports are nu_divider's (drop-in for exec.sv's d0).  One op in
 * flight.  Both users pick one cycle and start the next, so: `ready` drops while
 * fp_start is asserted (an FP op is taking the unit THIS cycle) and fp_ready drops
 * while start_div is; exec.sv additionally blocks the integer pick in the cycle an
 * FP div/sqrt pops.  If both ever start together the integer side wins and the
 * sim-only check below fires.  `flush` abandons a squashed op early (see the port).
 */

module uni_divider(clk,
		   reset,
		   flush,
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
		   complete,
		   fp_opcode,
		   fp_start,
		   fp_src_a,
		   fp_src_b,
		   fp_rm,
		   fp_rob_ptr_in,
		   fp_dst_ptr_in,
		   fp_wb_slot_used,
		   fp_ready,
		   fp_complete,
		   fp_y,
		   fp_fflags,
		   fp_denorm,
		   fp_rob_ptr_out,
		   fp_dst_ptr_out
		   );

   parameter LG_W = 6;
   localparam W = 1<<LG_W;
   localparam W2 = 2*W;
   localparam RW = W+2;		/* partial-remainder width: int needs W+1, sqrt 58 */

   input logic clk;
   input logic reset;
   /* machine clear with the delay slot (if any) already done (= the core's ds_done):
    * whatever is in the unit is a SQUASHED op.  Stop iterating and go straight to the
    * writeback wait -- the op must still "complete" so its ROB inflight bit clears
    * (the drain waits on that and on `ready`), but its value is dead, so a stale
    * result is fine.  A divide that IS the delay slot holds ds_done low until it
    * completes normally, so it is never cut short. */
   input logic flush;
   /* ---- integer side (== nu_divider) ---- */
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
   /* ---- FP side (== fpu_iter minus multiply) ---- */
   input opcode_t      fp_opcode;
   input logic 	       fp_start;
   input logic [63:0]  fp_src_a;
   input logic [63:0]  fp_src_b;
   input logic [1:0]   fp_rm;		/* FCSR.RM (0=RN 1=RZ 2=RP 3=RM) */
   input logic [`LG_ROB_ENTRIES-1:0] fp_rob_ptr_in;
   input logic [`LG_PRF_ENTRIES-1:0] fp_dst_ptr_in;
   input logic 			     fp_wb_slot_used;
   output logic 		     fp_ready;
   output logic 		     fp_complete;
   output logic [63:0] 		     fp_y;
   output logic [4:0] 		     fp_fflags;	/* {V,Z,O,U,I} */
   output logic 		     fp_denorm;	/* denormal operand/result -> E (trap) */
   output logic [`LG_ROB_ENTRIES-1:0] fp_rob_ptr_out;
   output logic [`LG_PRF_ENTRIES-1:0] fp_dst_ptr_out;

   localparam EW = 11;
   localparam FW = 52;

   typedef enum logic [2:0] {IDLE = 'd0,
			     ITER = 'd1,
			     INT_PACK = 'd2,
			     INT_WAITWB = 'd3,
			     FP_NORM = 'd4,
			     FP_ROUND = 'd5,
			     FP_WAITWB = 'd6
			     } state_t;
   state_t r_state, n_state;

   /* ---- shared recurrence state ---- */
   logic [RW-1:0] 		     r_rem, n_rem;	/* partial remainder (the step's lhs) */
   logic [W-1:0] 		     r_q, n_q;		/* quotient / root, MSB first from bit 0 */
   logic [W-1:0] 		     r_opb, n_opb;	/* divisor (|B| or sig_b) */
   logic [W-1:0] 		     r_src, n_src;	/* dividend bits / radicand bit pairs */
   logic [LG_W-1:0] 		     r_cnt, n_cnt;
   logic [LG_W-1:0] 		     r_last, n_last;	/* index of the final step */
   logic 			     r_is_fp, n_is_fp;
   logic 			     r_is_sqrt, n_is_sqrt;
   logic [`LG_ROB_ENTRIES-1:0] 	     r_rob_ptr, n_rob_ptr;

   /* ---- integer metadata ---- */
   logic [`LG_HILO_PRF_ENTRIES-1:0]  r_hilo_prf_ptr, n_hilo_prf_ptr;
   logic 			     r_is_signed, n_is_signed;
   logic 			     r_sign, n_sign;
   logic 			     r_rem_sign, n_rem_sign;
   logic 			     r_is_32b, n_is_32b;

   /* ---- FP metadata ---- */
   logic [`LG_PRF_ENTRIES-1:0] 	     r_fp_dst, n_fp_dst;
   logic [1:0] 			     r_rm, n_rm;
   logic 			     r_fmt, n_fmt;
   logic 			     r_fp_sign, n_fp_sign;
   logic signed [EW+2:0] 	     r_ebase, n_ebase;	/* biased result exponent (pre round-carry) */
   logic 			     r_special, n_special;
   logic [63:0] 		     r_early_y, n_early_y;
   logic 			     r_inv, n_inv;
   logic 			     r_dz, n_dz;
   logic 			     r_inden, n_inden;
   /* normalized significand + guard/round/sticky handed to the round/pack stage */
   logic [FW:0] 		     r_sig, n_sig;
   logic 			     r_gd, n_gd, r_rd, n_rd, r_sd, n_sd;

   /* =====================================================================
    * Integer operand conditioning (nu_divider): extend, take magnitudes.
    * ===================================================================== */
   logic [W-1:0] 		     t_extA, t_extB, t_absA, t_absB, t_int_src;
   logic 			     t_skip8, t_skip16, t_skip32;
   logic [LG_W-1:0] 		     t_int_last;
   always_comb
     begin
	t_extA = srcA;
	t_extB = srcB;
	if(is_32b)
	  begin
	     t_extA = { {(W-32){is_signed_div ? srcA[31] : 1'b0}}, srcA[31:0] };
	     t_extB = { {(W-32){is_signed_div ? srcB[31] : 1'b0}}, srcB[31:0] };
	  end
	t_absA = (is_signed_div & t_extA[W-1]) ? ((~t_extA) + 'd1) : t_extA;
	t_absB = (is_signed_div & t_extB[W-1]) ? ((~t_extB) + 'd1) : t_extB;
	/* coarse leading-zero skip on the dividend; NOT when B==0 (see header) */
	t_skip8  = (t_absA[W-1:8]  == 'd0) & (t_absB != 'd0);
	t_skip16 = (t_absA[W-1:16] == 'd0) & (t_absB != 'd0);
	t_skip32 = (t_absA[W-1:32] == 'd0) & (t_absB != 'd0);
	t_int_src = t_skip8  ? {t_absA[7:0],  {(W-8){1'b0}}}  :
		    t_skip16 ? {t_absA[15:0], {(W-16){1'b0}}} :
		    t_skip32 ? {t_absA[31:0], {(W-32){1'b0}}} :
		    t_absA;
	t_int_last = t_skip8  ? 'd7  :
		     t_skip16 ? 'd15 :
		     t_skip32 ? 'd31 :
		     (W-1);
     end // always_comb

   /* =====================================================================
    * FP unpack + special-case detection (from fpu_iter / fpu_mul), evaluated
    * on the INCOMING operands at fp_start and latched.
    * ===================================================================== */
   wire        w_is_sqrt_op = (fp_opcode == SP_SQRT) || (fp_opcode == DP_SQRT);
   wire        w_fmt_op     = (fp_opcode == DP_DIV)  || (fp_opcode == DP_SQRT);

   wire        sgn_a = w_fmt_op ? fp_src_a[63] : fp_src_a[31];
   wire        sgn_b = w_fmt_op ? fp_src_b[63] : fp_src_b[31];
   wire [EW-1:0] exp_a = w_fmt_op ? fp_src_a[62:52] : {3'b0, fp_src_a[30:23]};
   wire [EW-1:0] exp_b = w_fmt_op ? fp_src_b[62:52] : {3'b0, fp_src_b[30:23]};
   wire [FW-1:0] frac_a = w_fmt_op ? fp_src_a[51:0] : {fp_src_a[22:0], 29'b0};
   wire [FW-1:0] frac_b = w_fmt_op ? fp_src_b[51:0] : {fp_src_b[22:0], 29'b0};
   wire [EW-1:0] INF_EXP = w_fmt_op ? 11'd2047 : 11'd255;
   wire [EW-1:0] BIAS = w_fmt_op ? 11'd1023 : 11'd127;

   wire        a_is_zero = (exp_a == 'd0) & (frac_a == 'd0);
   wire        b_is_zero = (exp_b == 'd0) & (frac_b == 'd0);
   wire        a_is_nan = (exp_a == INF_EXP) & (frac_a != 'd0);
   wire        b_is_nan = (exp_b == INF_EXP) & (frac_b != 'd0);
   wire        a_is_inf = (exp_a == INF_EXP) & (frac_a == 'd0);
   wire        b_is_inf = (exp_b == INF_EXP) & (frac_b == 'd0);
/* MIPS legacy NaN semantics (the R4400 predates IEEE-754-2008 and has no FCSR.NAN2008 bit):
 *   - a NaN is SIGNALING when its fraction MSB is SET (the inverse of the 2008 rule);
 *   - default-NaN mode is always on: ANY NaN result is the architectural default NaN,
 *     the input NaN's payload is NOT propagated;
 *   - default NaN = 0x7FF7FFFFFFFFFFFF (double) / 0x7FBFFFFF (single): sign 0, exponent all
 *     ones, fraction = 0 followed by all ones.
 * Verified against a MIPS-legacy Berkeley SoftFloat specialization via TestFloat. */
   wire        a_is_snan = a_is_nan & (w_fmt_op ? fp_src_a[51] : fp_src_a[22]);
   wire        b_is_snan = b_is_nan & (w_fmt_op ? fp_src_b[51] : fp_src_b[22]);
   /* denormal operand -> raise E, trap to the emulator (HW path is normalized-only) */
   wire        w_in_denorm = ((exp_a == 'd0) & (frac_a != 'd0)) |
			     (~w_is_sqrt_op & (exp_b == 'd0) & (frac_b != 'd0));

   /* result sign: div = a^b; sqrt = a (sqrt(-0)=-0) */
   wire        w_sign = w_is_sqrt_op ? sgn_a : (sgn_a ^ sgn_b);

   wire [63:0] DEF_NAN = w_fmt_op ? {1'b0, 11'h7ff, 1'b0, 51'h7ffffffffffff} : {32'd0, 1'b0, 8'hff, 1'b0, 22'h3fffff};
   wire [63:0] inf_y  = w_fmt_op ? {w_sign, 11'h7ff, 52'd0} : {32'd0, w_sign, 8'hff, 23'd0};
   wire [63:0] zero_y = w_fmt_op ? {w_sign, 63'd0} : {32'd0, w_sign, 31'd0};

   /* DIV specials: 0/0 & inf/inf invalid; x/0 (x!=0) -> DZ + inf; inf/x -> inf;
    * x/inf -> 0; nan -> the default NaN */
   wire        any_nan   = a_is_nan | b_is_nan;
   wire        div_dz    = ~a_is_nan & ~a_is_inf & ~b_is_nan & ~b_is_inf & b_is_zero & ~a_is_zero;
   wire        div_inv   = a_is_snan | b_is_snan | (a_is_zero & b_is_zero) | (a_is_inf & b_is_inf);
   wire        div_early = any_nan | a_is_inf | b_is_inf | a_is_zero | b_is_zero;
   wire [63:0] div_early_y = any_nan ? DEF_NAN
			   : ((a_is_zero & b_is_zero) | (a_is_inf & b_is_inf)) ? DEF_NAN
			   : (a_is_inf | b_is_zero) ? inf_y
			   : zero_y;
   /* SQRT specials: negative (nonzero, non-nan) -> invalid qNaN; sqrt(+-0)=+-0;
    * +inf -> +inf; nan -> the default NaN.  A normal operand never over/underflows. */
   wire        sqrt_inv   = a_is_snan | (sgn_a & ~a_is_zero & ~a_is_nan);
   wire        sqrt_early = a_is_nan | a_is_inf | a_is_zero | sqrt_inv;
   wire [63:0] sqrt_inf_y = w_fmt_op ? {1'b0, 11'h7ff, 52'd0} : {32'd0, 1'b0, 8'hff, 23'd0};
   wire [63:0] sqrt_early_y = (a_is_nan | sqrt_inv) ? DEF_NAN
			    : a_is_inf ? sqrt_inf_y : zero_y;

   wire        w_op_inv     = w_is_sqrt_op ? sqrt_inv     : div_inv;
   wire        w_op_dz      = w_is_sqrt_op ? 1'b0         : div_dz;
   wire        w_op_early   = w_is_sqrt_op ? sqrt_early   : div_early;
   wire [63:0] w_op_early_y = w_is_sqrt_op ? sqrt_early_y : div_early_y;

   /* significands (hidden bit) */
   wire [FW:0] sig_a = {1'b1, frac_a};
   wire [FW:0] sig_b = {1'b1, frac_b};

   /* biased result exponents: div = ea - eb + BIAS; sqrt = floor((ea-BIAS)/2)+BIAS.
    * When (ea-BIAS) is odd the radicand is doubled so the root exponent is integral. */
   wire signed [EW+2:0] w_div_ebase = $signed({3'b0, exp_a}) - $signed({3'b0, exp_b})
					+ $signed({3'b0, BIAS});
   wire signed [EW+2:0] w_e_unb = $signed({3'b0, exp_a}) - $signed({3'b0, BIAS});
   wire signed [EW+2:0] w_sqrt_ebase = (w_e_unb >>> 1) + $signed({3'b0, BIAS});
   wire        w_exp_odd = exp_a[0] ^ BIAS[0];
   /* radicand = X*2^108 (55 root bits), two bits consumed per step, MSB first */
   wire [109:0] w_rad = w_exp_odd ? {sig_a, 57'd0} : {1'b0, sig_a, 56'd0};

   /* =====================================================================
    * The ONE recurrence step.
    * ===================================================================== */
   wire [RW-1:0] w_rhs = r_is_sqrt ? {{(RW-58){1'b0}}, r_q[55:0], 2'b01} : {{(RW-W){1'b0}}, r_opb};
   wire [RW:0] 	 w_diff = {1'b0, r_rem} - {1'b0, w_rhs};
   wire 	 w_bit = ~w_diff[RW];			/* lhs >= rhs */
   wire [RW-1:0] w_sel = w_bit ? w_diff[RW-1:0] : r_rem;
   wire 	 w_last_step = (r_cnt == r_last);

   /* ---- FP normalize (fpu_iter) ---- */
   wire 	 w_rem_nz = (r_rem != 'd0);
   /* divide quotient q in (0.5,2), bit55 = 2^0: if set sig=Q[55:3], else shift up 1, exp-1 */
   wire 	 w_div_ge1 = r_q[55];
   wire [FW:0] 	 w_div_sig = w_div_ge1 ? r_q[55:3] : r_q[54:2];
   wire 	 w_div_gd  = w_div_ge1 ? r_q[2] : r_q[1];
   wire 	 w_div_rd  = w_div_ge1 ? r_q[1] : r_q[0];
   wire 	 w_div_sd  = w_div_ge1 ? (r_q[0] | w_rem_nz) : w_rem_nz;
   wire signed [EW+2:0] w_div_ebase_norm = r_ebase - $signed({{(EW+2){1'b0}}, ~w_div_ge1});
   /* sqrt root Q (55b) = Y*2^54, Q[54] = hidden 1; always normalized */
   wire [FW:0] 	 w_sqrt_sig = r_q[54:2];
   wire 	 w_sqrt_gd  = r_q[1];
   wire 	 w_sqrt_rd  = r_q[0];
   wire 	 w_sqrt_sd  = w_rem_nz;

   /* ---- integer pack (nu_divider PACK_OUTPUT): signs, then 32b sign-extension ---- */
   logic [W-1:0] t_lo, t_hi;
   always_comb
     begin
	t_lo = (r_is_signed & r_sign)     ? ((~r_q) + 'd1)            : r_q;
	t_hi = (r_is_signed & r_rem_sign) ? ((~r_rem[W-1:0]) + 'd1)  : r_rem[W-1:0];
	if(r_is_32b & (`M_WIDTH == 64))
	  begin
	     t_lo = { {32{t_lo[31]}}, t_lo[31:0] };
	     t_hi = { {32{t_hi[31]}}, t_hi[31:0] };
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= IDLE;
	  end
	else
	  begin
	     r_state <= n_state;
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	r_rem <= n_rem;
	r_q <= n_q;
	r_opb <= n_opb;
	r_src <= n_src;
	r_cnt <= n_cnt;
	r_last <= n_last;
	r_is_fp <= n_is_fp;
	r_is_sqrt <= n_is_sqrt;
	r_rob_ptr <= n_rob_ptr;
	r_hilo_prf_ptr <= n_hilo_prf_ptr;
	r_is_signed <= n_is_signed;
	r_sign <= n_sign;
	r_rem_sign <= n_rem_sign;
	r_is_32b <= n_is_32b;
	r_fp_dst <= n_fp_dst;
	r_rm <= n_rm;
	r_fmt <= n_fmt;
	r_fp_sign <= n_fp_sign;
	r_ebase <= n_ebase;
	r_special <= n_special;
	r_early_y <= n_early_y;
	r_inv <= n_inv;
	r_dz <= n_dz;
	r_inden <= n_inden;
	r_sig <= n_sig;
	r_gd <= n_gd;
	r_rd <= n_rd;
	r_sd <= n_sd;
     end // always_ff@ (posedge clk)

   always_comb
     begin
	n_state = r_state;
	n_rem = r_rem;
	n_q = r_q;
	n_opb = r_opb;
	n_src = r_src;
	n_cnt = r_cnt;
	n_last = r_last;
	n_is_fp = r_is_fp;
	n_is_sqrt = r_is_sqrt;
	n_rob_ptr = r_rob_ptr;
	n_hilo_prf_ptr = r_hilo_prf_ptr;
	n_is_signed = r_is_signed;
	n_sign = r_sign;
	n_rem_sign = r_rem_sign;
	n_is_32b = r_is_32b;
	n_fp_dst = r_fp_dst;
	n_rm = r_rm;
	n_fmt = r_fmt;
	n_fp_sign = r_fp_sign;
	n_ebase = r_ebase;
	n_special = r_special;
	n_early_y = r_early_y;
	n_inv = r_inv;
	n_dz = r_dz;
	n_inden = r_inden;
	n_sig = r_sig;
	n_gd = r_gd;
	n_rd = r_rd;
	n_sd = r_sd;

	/* the integer side has priority; fp_start is only legal when fp_ready */
	ready = (r_state == IDLE) & !start_div & !fp_start;
	fp_ready = (r_state == IDLE) & !start_div & !fp_start;
	complete = 1'b0;
	fp_complete = 1'b0;
	rob_ptr_out = r_rob_ptr;
	hilo_prf_ptr_out = r_hilo_prf_ptr;
	fp_rob_ptr_out = r_rob_ptr;
	fp_dst_ptr_out = r_fp_dst;
	y = {r_rem[W-1:0], r_q};		/* {HI = remainder, LO = quotient} */

	unique case (r_state)
	  IDLE:
	    begin
	       n_cnt = 'd0;
	       n_q = 'd0;
	       if(start_div)
		 begin
		    n_state = ITER;
		    n_is_fp = 1'b0;
		    n_is_sqrt = 1'b0;
		    n_rob_ptr = rob_ptr_in;
		    n_hilo_prf_ptr = hilo_prf_ptr_in;
		    n_is_signed = is_signed_div;
		    n_is_32b = is_32b;
		    n_sign = t_extA[W-1] ^ t_extB[W-1];
		    n_rem_sign = t_extA[W-1];
		    n_opb = t_absB;
		    /* shift-first: the first dividend bit is already in the remainder */
		    n_rem = {{(RW-1){1'b0}}, t_int_src[W-1]};
		    n_src = {t_int_src[W-2:0], 1'b0};
		    n_last = t_int_last;
		 end
	       else if(fp_start)
		 begin
		    n_is_fp = 1'b1;
		    n_is_sqrt = w_is_sqrt_op;
		    n_rob_ptr = fp_rob_ptr_in;
		    n_fp_dst = fp_dst_ptr_in;
		    n_rm = fp_rm;
		    n_fmt = w_fmt_op;
		    n_fp_sign = w_sign;
		    n_special = w_op_early | w_in_denorm;
		    n_early_y = w_op_early_y;
		    n_inv = w_op_inv;
		    n_dz = w_op_dz;
		    n_inden = w_in_denorm;
		    n_ebase = w_is_sqrt_op ? w_sqrt_ebase : w_div_ebase;
		    n_opb = {{(W-FW-1){1'b0}}, sig_b};
		    if(w_is_sqrt_op)
		      begin
			 n_rem = {{(RW-2){1'b0}}, w_rad[109:108]};
			 n_src = w_rad[107:44];
			 n_last = 'd54;		/* 55 root bits: 2^0 .. 2^-54 */
		      end
		    else
		      begin
			 n_rem = {{(RW-FW-1){1'b0}}, sig_a};
			 n_src = 'd0;
			 n_last = 'd55;		/* 56 quotient bits: 2^0 .. 2^-55 */
		      end
		    /* special/denorm short-circuit straight to the round/pack stage */
		    n_state = flush ? FP_WAITWB : (w_op_early | w_in_denorm) ? FP_ROUND : ITER;
		 end
	    end // case: IDLE
	  ITER:
	    begin
	       if(flush)
		 begin
		    n_state = r_is_fp ? FP_WAITWB : INT_WAITWB;
		 end
	       n_q = {r_q[W-2:0], w_bit};
	       n_cnt = r_cnt + 'd1;
	       n_src = r_is_sqrt ? {r_src[W-3:0], 2'b00} : {r_src[W-2:0], 1'b0};
	       if(w_last_step)
		 begin
		    /* keep the remainder UNshifted: it is HI (int) / the sticky source (FP) */
		    n_rem = w_sel;
		    if(!flush)
		      begin
			 n_state = r_is_fp ? FP_NORM : INT_PACK;
		      end
		 end
	       else
		 begin
		    n_rem = r_is_sqrt ? {w_sel[RW-3:0], r_src[W-1:W-2]} : {w_sel[RW-2:0], r_src[W-1]};
		 end
	    end // case: ITER
	  INT_PACK:
	    begin
	       /* results are held in the recurrence registers themselves (no r_Y) */
	       n_q = t_lo;
	       n_rem = {{(RW-W){1'b0}}, t_hi};
	       n_state = INT_WAITWB;
	    end
	  INT_WAITWB:
	    begin
	       /* result ready; drain at the first free writeback slot */
	       if(wb_slot_used == 1'b0)
		 begin
		    complete = 1'b1;
		    n_state = IDLE;
		 end
	    end
	  FP_NORM:
	    begin
	       n_sig = r_is_sqrt ? w_sqrt_sig : w_div_sig;
	       n_gd = r_is_sqrt ? w_sqrt_gd : w_div_gd;
	       n_rd = r_is_sqrt ? w_sqrt_rd : w_div_rd;
	       n_sd = r_is_sqrt ? w_sqrt_sd : w_div_sd;
	       n_ebase = r_is_sqrt ? r_ebase : w_div_ebase_norm;
	       n_state = FP_ROUND;
	    end
	  FP_ROUND:
	    begin
	       /* result registered by the round/pack flop below; advance to WB */
	       n_state = FP_WAITWB;
	    end
	  FP_WAITWB:
	    begin
	       if(fp_wb_slot_used == 1'b0)
		 begin
		    fp_complete = 1'b1;
		    n_state = IDLE;
		 end
	    end
	  default:
	    begin
	       n_state = IDLE;
	    end
	endcase // unique case (r_state)
     end // always_comb

   /* =====================================================================
    * Round + overflow + pack + flags (fpu_iter's S4 back end, from fpu_mul).
    * Operates on the registered {r_sig,r_gd,r_rd,r_sd,r_ebase,r_fp_sign,r_fmt,
    * r_rm} plus the special/early path; registered during FP_ROUND so the
    * result is stable in FP_WAITWB.
    * ===================================================================== */
   wire g_s = r_sig[28], r_s = r_sig[27];
   wire s_s = (|r_sig[26:0]) | r_gd | r_rd | r_sd;
   wire w_g = r_fmt ? r_gd : g_s;
   wire w_r = r_fmt ? r_rd : r_s;
   wire w_s = r_fmt ? r_sd : s_s;
   wire w_lsb = r_fmt ? r_sig[0] : r_sig[29];
   wire w_inexact = w_g | w_r | w_s;
   wire w_round_up =
	(r_rm == 2'd0) ? (w_g & (w_r | w_s | w_lsb)) :
	(r_rm == 2'd1) ? 1'b0 :
	(r_rm == 2'd2) ? (~r_fp_sign & w_inexact) :
	                 ( r_fp_sign & w_inexact);
   wire [FW:0]  w_inc = r_fmt ? {{(FW){1'b0}}, 1'b1} : ({{(FW){1'b0}}, 1'b1} << 29);
   wire [FW+1:0] w_sum_r = {1'b0, r_sig} + (w_round_up ? {1'b0, w_inc} : {(FW+2){1'b0}});
   wire        w_round_carry = w_sum_r[FW+1];
   wire [FW:0] w_final_sig = w_round_carry ? w_sum_r[FW+1:1] : w_sum_r[FW:0];

   wire signed [EW+2:0] w_exp_real = r_ebase + {{(EW+2){1'b0}}, w_round_carry};
   wire [EW-1:0] INF_E = r_fmt ? 11'd2047 : 11'd255;
   wire        w_arith = ~r_special;
   wire        w_overflow  = w_arith & (w_exp_real >= $signed({3'b0, INF_E}));
   wire        w_underflow = w_arith & (w_exp_real[EW+2] | ~(|w_exp_real));
   wire        w_ovf_inf =
	       (r_rm == 2'd0) ? 1'b1 :
	       (r_rm == 2'd1) ? 1'b0 :
	       (r_rm == 2'd2) ? ~r_fp_sign :
	                         r_fp_sign;
   wire [EW-1:0] w_pack_exp = w_exp_real[EW-1:0];
   wire [63:0] ovf_inf = r_fmt ? {r_fp_sign, 11'h7ff, 52'd0} : {32'd0, r_fp_sign, 8'hff, 23'd0};
   wire [63:0] ovf_max = r_fmt ? {r_fp_sign, 11'h7fe, 52'hfffffffffffff} : {32'd0, r_fp_sign, 8'hfe, 23'h7fffff};
   wire [63:0] ovf_y = w_ovf_inf ? ovf_inf : ovf_max;
   wire [63:0] norm_y = r_fmt ? {r_fp_sign, w_pack_exp[10:0], w_final_sig[51:0]}
		              : {32'd0, r_fp_sign, w_pack_exp[7:0], w_final_sig[51:29]};

   /* special/early result (NaN/Inf/zero/DZ-inf) bypasses the arithmetic pack;
    * a denormal operand or an underflowing result raises E so the op traps. */
   wire [63:0] w_y = r_special ? r_early_y : w_overflow ? ovf_y : norm_y;
   wire        w_denorm = r_inden | (~r_special & w_underflow);
   wire        w_f_inexact = w_arith & (w_inexact | w_overflow);
   wire [4:0]  w_fflags = {r_inv, r_dz, w_arith & w_overflow, w_arith & w_underflow, w_f_inexact};

   logic [63:0] r_fp_y;
   logic [4:0] 	r_fp_fflags;
   logic 	r_fp_denorm;
   always_ff@(posedge clk)
     begin
	if(r_state == FP_ROUND)
	  begin
	     r_fp_y <= w_y;
	     r_fp_fflags <= w_fflags;
	     r_fp_denorm <= w_denorm;
	  end
     end // always_ff@ (posedge clk)
   assign fp_y = r_fp_y;
   assign fp_fflags = r_fp_fflags;
   assign fp_denorm = r_fp_denorm;

`ifdef VERILATOR
   always_ff@(negedge clk)
     begin
	if(!reset & fp_start & ((r_state != IDLE) | start_div))
	  begin
	     $display("uni_divider: fp_start while not fp_ready (state %d, start_div %b)", r_state, start_div);
	     $stop();
	  end
     end // always_ff@ (negedge clk)
`endif

endmodule // uni_divider
