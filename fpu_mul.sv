// Unified single/double-precision FP multiplier.
//
// One datapath, sized for double precision; single precision runs through it
// left-justified (the single significand sits in the top 24 bits of the 53-bit
// field, low bits zero) and is rounded ONCE at single precision -- no double
// rounding.  `fmt` selects the format at runtime: 0 = single (operand in the low
// 32 bits, MIPS style), 1 = double.
//
// Front end (extract) + back end (round / pack / flags) mirror fpu_add.sv so the
// two units share the same fmt-dependent rounding behaviour; only the core op
// differs: a 53x53 significand multiply normalized from the [1,4) product.

module fpu_mul(/*AUTOARG*/
   // Outputs
   y, denorm, fflags,
   // Inputs
   clk, a, b, en, rm, fmt
   );
   parameter MUL_LAT = 4;

   input logic 	      clk;
   input logic [63:0] a;
   input logic [63:0] b;
   input logic 	      en;
   input logic [1:0]  rm;     // 0=RN 1=RZ 2=RP(+inf) 3=RM(-inf)
   input logic 	      fmt;    // 0=single, 1=double
   output logic [63:0] y;
   output logic        denorm;
   output logic [4:0]  fflags; // {V,Z,O,U,I}

   localparam EW = 11;        // internal exponent width (double)
   localparam FW = 52;        // internal fraction width (double)

   // ---------------- field extraction (fmt-dependent) ----------------
   wire 	sgn_a  = fmt ? a[63] : a[31];
   wire 	sgn_b  = fmt ? b[63] : b[31];
   wire 	res_sgn = sgn_a ^ sgn_b;
   wire [EW-1:0] exp_a = fmt ? a[62:52] : {3'b0, a[30:23]};
   wire [EW-1:0] exp_b = fmt ? b[62:52] : {3'b0, b[30:23]};
   wire [FW-1:0] frac_a = fmt ? a[51:0] : {a[22:0], 29'b0};
   wire [FW-1:0] frac_b = fmt ? b[51:0] : {b[22:0], 29'b0};

   wire 	a_is_zero = (exp_a == 'd0) & (frac_a == 'd0);
   wire 	b_is_zero = (exp_b == 'd0) & (frac_b == 'd0);

   localparam [EW-1:0] INF_EXP_D = 11'd2047;
   localparam [EW-1:0] INF_EXP_S = 11'd255;
   wire [EW-1:0] INF_EXP = fmt ? INF_EXP_D : INF_EXP_S;
   wire [EW-1:0] BIAS = fmt ? 11'd1023 : 11'd127;

   // ---------------- special-value detection ----------------
   wire 	exp_all1_a = (exp_a == INF_EXP);
   wire 	exp_all1_b = (exp_b == INF_EXP);
   wire 	a_is_nan = exp_all1_a & (frac_a != 'd0);
   wire 	b_is_nan = exp_all1_b & (frac_b != 'd0);
   wire 	a_is_inf = exp_all1_a & (frac_a == 'd0);
   wire 	b_is_inf = exp_all1_b & (frac_b == 'd0);
   wire 	a_qbit = fmt ? a[51] : a[22];
   wire 	b_qbit = fmt ? b[51] : b[22];
   wire 	a_is_snan = a_is_nan & ~a_qbit;
   wire 	b_is_snan = b_is_nan & ~b_qbit;
   wire 	any_nan = a_is_nan | b_is_nan;
   wire 	inf_times_zero = (a_is_inf & b_is_zero) | (b_is_inf & a_is_zero);
   wire 	special = any_nan | a_is_inf | b_is_inf;
   wire 	w_invalid = a_is_snan | b_is_snan | inf_times_zero;

   // sign of the result feeds the directed-rounding / pack logic below
   wire 	t_align_sign = res_sgn;

   // ---------------- significand multiply (53 x 53 -> 106) ----------------
   wire [FW:0] 	     w_mant_a = {1'b1, frac_a};
   wire [FW:0] 	     w_mant_b = {1'b1, frac_b};
   wire [2*FW+1:0]   w_prod = w_mant_a * w_mant_b;   // 106-bit product, in [1,4)

   // exponent sum in the operand's own bias (signed -> detects under/overflow)
   wire signed [EW+2:0] s_exp_sum = $signed({2'b0, exp_a}) + $signed({2'b0, exp_b})
				    - $signed({2'b0, BIAS});

   // ---------------- normalize the [1,4) product to a 1.52 significand ------
   logic [FW:0] 	t_norm_mant;
   logic [EW:0] 	t_norm_exp;
   logic 		t_norm_guard, t_norm_round, t_norm_sticky;
   logic signed [EW+2:0] t_real_exp;
   always_comb
     begin
	if(w_prod[2*FW+1])
	  begin /* product in [2,4): take [105:53], exponent +1 */
	     t_norm_mant   = w_prod[2*FW+1:FW+1];
	     t_norm_guard  = w_prod[FW];
	     t_norm_round  = w_prod[FW-1];
	     t_norm_sticky = |w_prod[FW-2:0];
	     t_real_exp    = s_exp_sum + 'sd1;
	  end
	else
	  begin /* product in [1,2): take [104:52] */
	     t_norm_mant   = w_prod[2*FW:FW];
	     t_norm_guard  = w_prod[FW-1];
	     t_norm_round  = w_prod[FW-2];
	     t_norm_sticky = |w_prod[FW-3:0];
	     t_real_exp    = s_exp_sum;
	  end
	t_norm_exp = t_real_exp[EW:0];
     end

   // ---------------- rounding (fmt-dependent round point) -- mirrors fpu_add -
   wire g_d = t_norm_guard;
   wire r_d = t_norm_round;
   wire s_d = t_norm_sticky;
   wire lsb_d = t_norm_mant[0];
   wire g_s = t_norm_mant[28];
   wire r_s = t_norm_mant[27];
   wire s_s = (|t_norm_mant[26:0]) | t_norm_guard | t_norm_round | t_norm_sticky;
   wire lsb_s = t_norm_mant[29];

   wire w_g = fmt ? g_d : g_s;
   wire w_r = fmt ? r_d : r_s;
   wire w_s = fmt ? s_d : s_s;
   wire w_lsb = fmt ? lsb_d : lsb_s;
   wire w_inexact = w_g | w_r | w_s;
   wire w_round_up =
	(rm == 2'd0) ? (w_g & (w_r | w_s | w_lsb)) :
	(rm == 2'd1) ? 1'b0 :
	(rm == 2'd2) ? (~t_align_sign & w_inexact) :
	               ( t_align_sign & w_inexact);

   wire [FW:0]  w_inc = fmt ? {{(FW){1'b0}}, 1'b1} : ({{(FW){1'b0}}, 1'b1} << 29);
   wire [FW+1:0] w_sum_r = {1'b0, t_norm_mant} + (w_round_up ? {1'b0, w_inc} : {(FW+2){1'b0}});
   wire 	w_round_carry = w_sum_r[FW+1];
   wire [FW:0]  t_round_mant = w_round_carry ? w_sum_r[FW+1:1] : w_sum_r[FW:0];
   wire [EW:0]  t_round_exp  = w_round_carry ? (t_norm_exp + 'd1) : t_norm_exp;

   // ---------------- zero / overflow / underflow ----------------
   wire w_mul_is_zero = (a_is_zero | b_is_zero) & ~special;
   wire w_overflow = (t_round_exp[EW-1:0] >= INF_EXP) | t_round_exp[EW];
   wire w_ovf_inf =
	(rm == 2'd0) ? 1'b1 :
	(rm == 2'd1) ? 1'b0 :
	(rm == 2'd2) ? ~t_align_sign :
	                t_align_sign;

   wire w_a_denorm = (exp_a == 'd0) & (frac_a != 'd0);
   wire w_b_denorm = (exp_b == 'd0) & (frac_b != 'd0);
   wire w_res_denorm = (t_real_exp <= 'sd0) & ~w_mul_is_zero & ~special;

   // ---------------- pack result (fmt-dependent) ----------------
   wire [63:0] DEF_NAN = fmt ? {1'b1, 11'h7ff, 1'b1, 51'd0}
		             : {32'd0, 1'b1, 8'hff, 1'b1, 22'd0};
   wire [63:0] nan_src = (a_is_nan ? a : b);
   wire [63:0] qnan = fmt ? {nan_src[63:52], 1'b1, nan_src[50:0]}
		         : {32'd0, nan_src[31:23], 1'b1, nan_src[21:0]};
   wire [63:0] inf_y = fmt ? {res_sgn, 11'h7ff, 52'd0}
		          : {32'd0, res_sgn, 8'hff, 23'd0};
   wire [63:0] special_y = any_nan ? qnan : inf_times_zero ? DEF_NAN : inf_y;

   wire [63:0] ovf_inf = fmt ? {t_align_sign, 11'h7ff, 52'd0}
		            : {32'd0, t_align_sign, 8'hff, 23'd0};
   wire [63:0] ovf_max = fmt ? {t_align_sign, 11'h7fe, 52'hfffffffffffff}
		            : {32'd0, t_align_sign, 8'hfe, 23'h7fffff};
   wire [63:0] ovf_y = w_ovf_inf ? ovf_inf : ovf_max;

   wire [63:0] zero_y = fmt ? {res_sgn, 63'd0} : {32'd0, res_sgn, 31'd0};

   wire [63:0] norm_y = fmt ? {t_align_sign, t_round_exp[10:0], t_round_mant[51:0]}
		           : {32'd0, t_align_sign, t_round_exp[7:0], t_round_mant[51:29]};

   wire [63:0] w_y = special ? special_y :
		w_mul_is_zero ? zero_y :
		w_overflow ? ovf_y :
		norm_y;

   wire w_denorm = ~special & (w_a_denorm | w_b_denorm | w_res_denorm);

   // ---------------- IEEE flags ----------------
   wire w_exact_path = special | w_mul_is_zero;
   wire w_f_inexact   = ~w_exact_path & (w_inexact | w_overflow);
   wire w_f_overflow  = ~w_exact_path & w_overflow;
   wire w_f_underflow = ~w_exact_path & w_res_denorm;
   wire [4:0] w_fflags = {w_invalid, 1'b0, w_f_overflow, w_f_underflow, w_f_inexact};

   // ---------------- output pipeline ----------------
   logic [63+6:0] r_pipe [MUL_LAT-1:0];
   integer 	  i;
   always_ff @(posedge clk)
     begin
	r_pipe[0] <= {w_fflags, w_denorm, w_y};
	for(i = 1; i < MUL_LAT; i = i + 1)
	  r_pipe[i] <= r_pipe[i-1];
     end
   assign y      = r_pipe[MUL_LAT-1][63:0];
   assign denorm = r_pipe[MUL_LAT-1][64];
   assign fflags = r_pipe[MUL_LAT-1][69:65];

endmodule // fpu_mul
