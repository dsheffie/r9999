// Unified single/double-precision FP adder.
//
// One datapath, sized for double precision; single precision runs through it
// left-justified (the single significand sits in the top 24 bits of the 53-bit
// field, low bits zero) and is rounded ONCE at single precision -- no double
// rounding. `fmt` selects the format at runtime: 0 = single (operand in the low
// 32 bits, MIPS style), 1 = double.
//
// Mirrors fp_add's algorithm (align / add / normalize / round) but with the
// field extraction (front) and rounding+packing (back) made fmt-dependent.

module fpu_zero_detector(distance, a);
   parameter LG_W = 6;
   parameter W = 52;
   input logic [W:0] a;
   output logic [LG_W-1:0] distance;
   localparam WW = 1 << LG_W;
   localparam ZP = WW - W - 1;
   wire [ZP-1:0]    w_zp = {ZP{1'b0}};
   wire [WW-1:0]    w_a_pad = {a, w_zp};
   logic [LG_W:0]   t_ffs;
   count_leading_zeros #(.LG_N(LG_W)) zffs (w_a_pad, t_ffs);
   always_comb
     begin
	distance = t_ffs[LG_W-1:0];
	if(t_ffs >= W) distance = W;
     end
endmodule

module fpu_add(/*AUTOARG*/
   // Outputs
   y, denorm, fflags,
   // Inputs
   clk, sub, a, b, en, rm, fmt
   );
   parameter ADD_LAT = 2;

   input logic 	      clk;
   input logic 	      sub;
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
   wire 	sgn_b0 = fmt ? b[63] : b[31];
   wire 	sgn_b  = sub ? ~sgn_b0 : sgn_b0;        // sub == add with b negated
   wire [EW-1:0] exp_a = fmt ? a[62:52] : {3'b0, a[30:23]};
   wire [EW-1:0] exp_b = fmt ? b[62:52] : {3'b0, b[30:23]};
   wire [FW-1:0] frac_a = fmt ? a[51:0] : {a[22:0], 29'b0};
   wire [FW-1:0] frac_b = fmt ? b[51:0] : {b[22:0], 29'b0};

   wire 	a_is_zero = (exp_a == 'd0) & (frac_a == 'd0);
   wire 	b_is_zero = (exp_b == 'd0) & (frac_b == 'd0);

   localparam [EW-1:0] INF_EXP_D = 11'd2047;
   localparam [EW-1:0] INF_EXP_S = 11'd255;
   wire [EW-1:0] INF_EXP = fmt ? INF_EXP_D : INF_EXP_S;

   // ---------------- special-value detection ----------------
   wire 	exp_all1_a = (exp_a == INF_EXP);
   wire 	exp_all1_b = (exp_b == INF_EXP);
   wire 	a_is_nan = exp_all1_a & (frac_a != 'd0);
   wire 	b_is_nan = exp_all1_b & (frac_b != 'd0);
   wire 	a_is_inf = exp_all1_a & (frac_a == 'd0);
   wire 	b_is_inf = exp_all1_b & (frac_b == 'd0);
   // quiet bit = frac MSB (in the operand's own format)
   wire 	a_qbit = fmt ? a[51] : a[22];
   wire 	b_qbit = fmt ? b[51] : b[22];
   wire 	a_is_snan = a_is_nan & ~a_qbit;
   wire 	b_is_snan = b_is_nan & ~b_qbit;
   wire 	any_nan = a_is_nan | b_is_nan;
   wire 	special = any_nan | a_is_inf | b_is_inf;
   wire 	inf_sub_inf = a_is_inf & b_is_inf & (sgn_a ^ sgn_b);
   wire 	w_invalid = a_is_snan | b_is_snan | inf_sub_inf;

   // ---------------- alignment ----------------
   wire [FW+3:0] t_a_mant = {1'b1, frac_a, 3'b0};   // 56 bits: [55]=1, [54:3]=frac, [2:0]=GRS
   wire [FW+3:0] t_b_mant = {1'b1, frac_b, 3'b0};
   wire [EW-1:0] t_dist_a = exp_a - exp_b;
   wire [EW-1:0] t_dist_b = exp_b - exp_a;

   // sticky = OR of the bits shifted out of the smaller operand
   wire a_shifted = |(t_a_mant & ~({(FW+4){1'b1}} << t_dist_b));
   wire b_shifted = |(t_b_mant & ~({(FW+4){1'b1}} << t_dist_a));

   logic [FW+3:0] t_a_align_mant, t_b_align_mant;
   logic [EW:0]   t_align_exp;
   always_comb
     begin
	t_a_align_mant = t_a_mant;
	t_b_align_mant = t_b_mant;
	t_align_exp = {1'b0, exp_a};
	if(exp_a > exp_b)
	  t_b_align_mant = (t_b_mant >> t_dist_a) | {{(FW+3){1'b0}}, b_shifted};
	else if(exp_b > exp_a)
	  begin
	     t_a_align_mant = (t_a_mant >> t_dist_b) | {{(FW+3){1'b0}}, a_shifted};
	     t_align_exp = {1'b0, exp_b};
	  end
     end

   // ---------------- add / subtract magnitudes ----------------
   logic [FW+4:0] t_align_sum;
   logic 	  t_align_sign;
   always_comb
     begin
	t_align_sum = {1'b0, t_a_align_mant} + t_b_align_mant;
	t_align_sign = sgn_a;
	if(sgn_a != sgn_b)
	  begin
	     if(t_a_align_mant > t_b_align_mant)
	       begin
		  t_align_sum = {1'b0, t_a_align_mant} - t_b_align_mant;
		  t_align_sign = sgn_a;
	       end
	     else
	       begin
		  t_align_sum = {1'b0, t_b_align_mant} - t_a_align_mant;
		  t_align_sign = sgn_b;
	       end
	  end
     end

   // ---------------- post-add carry ----------------
   logic [FW:0] t_add_mant;     // 53-bit significand
   logic [EW:0] t_add_exp;
   logic 	t_guard, t_round, t_sticky;
   always_comb
     begin
	t_add_mant = t_align_sum[FW+3:3];
	t_guard = t_align_sum[2];
	t_round = t_align_sum[1];
	t_sticky = t_align_sum[0];
	t_add_exp = t_align_exp;
	if(t_align_sum[FW+4])
	  begin
	     t_add_mant = t_align_sum[FW+4:4];
	     t_guard = t_align_sum[3];
	     t_round = t_align_sum[2];
	     t_sticky = t_align_sum[1] | t_align_sum[0];
	     t_add_exp = t_align_exp + 'd1;
	  end
     end

   // ---------------- leading-zero normalize (cancellation) ----------------
   localparam LG_FW = 6;
   wire [LG_FW-1:0] w_shft_lft_dist;
   localparam ZP = (EW+1) - LG_FW;
   fpu_zero_detector #(.LG_W(LG_FW), .W(FW)) zd (.distance(w_shft_lft_dist), .a(t_add_mant));
   wire [EW:0] 	    w_shift_dist = {{ZP{1'b0}}, w_shft_lft_dist};

   logic [FW:0] t_norm_mant;
   logic [EW:0] t_norm_exp;
   logic 	t_norm_guard, t_norm_round, t_norm_sticky;
   always_comb
     begin
	t_norm_mant = t_add_mant;
	t_norm_exp = t_add_exp;
	t_norm_guard = t_guard;
	t_norm_round = t_round;
	t_norm_sticky = t_sticky;
	if(t_add_mant[FW] == 1'b0 && (t_add_exp != 'd0))
	  begin
	     t_norm_exp = t_add_exp - w_shift_dist;
	     if(w_shift_dist == 'd1)
	       begin
		  t_norm_guard = t_round;
		  t_norm_round = 1'b0;
		  t_norm_mant = {t_add_mant[FW-1:0], t_guard};
	       end
	     else
	       begin
		  t_norm_guard = 1'b0;
		  t_norm_round = 1'b0;
		  t_norm_mant = {t_add_mant[FW-2:0], t_guard, t_round} << (w_shift_dist - 'd2);
	       end
	  end
     end

   // ---------------- rounding (fmt-dependent round point) ----------------
   // double: LSB=t_norm_mant[0], G/R/S = t_norm_guard/round/sticky
   // single: LSB=t_norm_mant[29], G=[28], R=[27], S=|[26:0]|G_d|R_d|S_d
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

   // ---------------- exact zero result ----------------
   wire w_is_zero = (sgn_a ^ sgn_b) & (t_round_mant == 'd0);

   // ---------------- overflow ----------------
   wire w_overflow = (t_round_exp[EW-1:0] >= INF_EXP) | t_round_exp[EW];
   wire w_ovf_inf =
	(rm == 2'd0) ? 1'b1 :
	(rm == 2'd1) ? 1'b0 :
	(rm == 2'd2) ? ~t_align_sign :
	                t_align_sign;

   // ---------------- result underflow (subnormal) -> punt via denorm ----------------
   wire [EW:0] 		w_lead = (t_add_mant[FW] == 1'b0) ? w_shift_dist : {(EW+1){1'b0}};
   wire signed [EW+1:0] w_real_exp = $signed({1'b0, t_add_exp}) - $signed({1'b0, w_lead});
   wire 		w_a_denorm = (exp_a == 'd0) & (frac_a != 'd0);
   wire 		w_b_denorm = (exp_b == 'd0) & (frac_b != 'd0);
   wire 		w_res_denorm = (w_real_exp[EW+1] | ~(|w_real_exp)) & (t_round_mant != 'd0) & ~w_is_zero;

   // ---------------- pack result (fmt-dependent) ----------------
   // NaN default + propagation, in the output format
   wire [63:0] DEF_NAN = fmt ? {1'b1, 11'h7ff, 1'b1, 51'd0}
		             : {32'd0, 1'b1, 8'hff, 1'b1, 22'd0};
   wire [63:0] nan_src = (a_is_nan ? a : b);
   wire [63:0] qnan = fmt ? {nan_src[63:52], 1'b1, nan_src[50:0]}
		         : {32'd0, nan_src[31:23], 1'b1, nan_src[21:0]};
   wire        inf_sign = a_is_inf ? sgn_a : sgn_b;
   wire [63:0] inf_y = fmt ? {inf_sign, 11'h7ff, 52'd0}
		          : {32'd0, inf_sign, 8'hff, 23'd0};
   wire [63:0] special_y = any_nan ? qnan : inf_sub_inf ? DEF_NAN : inf_y;

   // overflow default: inf or max-finite, by mode/sign
   wire [63:0] ovf_inf = fmt ? {t_align_sign, 11'h7ff, 52'd0}
		            : {32'd0, t_align_sign, 8'hff, 23'd0};
   wire [63:0] ovf_max = fmt ? {t_align_sign, 11'h7fe, 52'hfffffffffffff}
		            : {32'd0, t_align_sign, 8'hfe, 23'h7fffff};
   wire [63:0] ovf_y = w_ovf_inf ? ovf_inf : ovf_max;

   // normal result, packed per format
   wire [63:0] norm_y = fmt ? {t_align_sign, t_round_exp[10:0], t_round_mant[51:0]}
		           : {32'd0, t_align_sign, t_round_exp[7:0], t_round_mant[51:29]};

   wire [63:0] w_y = special ? special_y :
		w_is_zero ? 64'd0 :
		a_is_zero ? (fmt ? {sgn_b, b[62:0]} : {32'd0, sgn_b, b[30:0]}) :
		b_is_zero ? (fmt ? a : {32'd0, a[31:0]}) :
		w_overflow ? ovf_y :
		norm_y;

   wire w_denorm = ~special & (w_a_denorm | w_b_denorm | w_res_denorm);

   // ---------------- IEEE flags ----------------
   wire w_exact_path = special | w_is_zero | a_is_zero | b_is_zero;
   wire w_f_inexact   = ~w_exact_path & (w_inexact | w_overflow);
   wire w_f_overflow  = ~w_exact_path & w_overflow;
   wire w_f_underflow = ~w_exact_path & w_res_denorm;
   wire [4:0] w_fflags = {w_invalid, 1'b0, w_f_overflow, w_f_underflow, w_f_inexact};

   // ---------------- output pipeline ----------------
   logic [63+6:0] r_pipe [ADD_LAT-1:0];
   integer 	  i;
   always_ff @(posedge clk)
     begin
	r_pipe[0] <= {w_fflags, w_denorm, w_y};
	for(i = 1; i < ADD_LAT; i = i + 1)
	  r_pipe[i] <= r_pipe[i-1];
     end
   assign y      = r_pipe[ADD_LAT-1][63:0];
   assign denorm = r_pipe[ADD_LAT-1][64];
   assign fflags = r_pipe[ADD_LAT-1][69:65];

endmodule // fpu_add
