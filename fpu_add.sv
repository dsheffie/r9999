// Unified single/double-precision FP adder -- 4-stage pipeline.
//
// One datapath, sized for double; single runs left-justified and is rounded
// once at single precision. fmt: 0=single (low 32 bits), 1=double. Pipeline:
//   S1 extract + align | S2 add | S3 leading-zero normalize | S4 round + pack
// Each phase is registered so no single combinational stage spans the whole
// align->add->normalize->round chain (the pre-pipeline timing wall).

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
   parameter ADD_LAT = 4;     // informational; pipeline below is 4 deep

   input logic 	      clk;
   input logic 	      sub;
   input logic [63:0] a;
   input logic [63:0] b;
   input logic 	      en;
   input logic [1:0]  rm;
   input logic 	      fmt;
   output logic [63:0] y;
   output logic        denorm;
   output logic [4:0]  fflags;

   localparam EW = 11;
   localparam FW = 52;
   localparam [EW-1:0] INF_EXP = 11'd2047;

   // ================= S1 comb: extract + special + align =================
   wire 	sgn_a  = fmt ? a[63] : a[31];
   wire 	sgn_b0 = fmt ? b[63] : b[31];
   wire 	sgn_b  = sub ? ~sgn_b0 : sgn_b0;
   wire [EW-1:0] exp_a = fmt ? a[62:52] : {3'b0, a[30:23]};
   wire [EW-1:0] exp_b = fmt ? b[62:52] : {3'b0, b[30:23]};
   wire [FW-1:0] frac_a = fmt ? a[51:0] : {a[22:0], 29'b0};
   wire [FW-1:0] frac_b = fmt ? b[51:0] : {b[22:0], 29'b0};
   wire 	a_is_zero = (exp_a == 'd0) & (frac_a == 'd0);
   wire 	b_is_zero = (exp_b == 'd0) & (frac_b == 'd0);
   wire [EW-1:0] INF_EXP_S = 11'd255;
   wire [EW-1:0] EXP_INF = fmt ? INF_EXP : INF_EXP_S;
   wire 	exp_all1_a = (exp_a == EXP_INF);
   wire 	exp_all1_b = (exp_b == EXP_INF);
   wire 	a_is_nan = exp_all1_a & (frac_a != 'd0);
   wire 	b_is_nan = exp_all1_b & (frac_b != 'd0);
   wire 	a_is_inf = exp_all1_a & (frac_a == 'd0);
   wire 	b_is_inf = exp_all1_b & (frac_b == 'd0);
   wire 	a_is_snan = a_is_nan & ~a[fmt ? 51 : 22];
   wire 	b_is_snan = b_is_nan & ~b[fmt ? 51 : 22];
   wire 	any_nan = a_is_nan | b_is_nan;
   wire 	special = any_nan | a_is_inf | b_is_inf;
   wire 	inf_sub_inf = a_is_inf & b_is_inf & (sgn_a ^ sgn_b);
   wire 	s1_invalid  = a_is_snan | b_is_snan | inf_sub_inf;

   localparam [63:0] DEF_NAN_D = {1'b1, 11'h7ff, 1'b1, 51'd0};
   localparam [63:0] DEF_NAN_S = {32'd0, 1'b1, 8'hff, 1'b1, 22'd0};
   wire [63:0] 	DEF_NAN = fmt ? DEF_NAN_D : DEF_NAN_S;
   wire [63:0] 	nan_src = a_is_nan ? a : b;
   wire [63:0] 	qnan = fmt ? {nan_src[63:52], 1'b1, nan_src[50:0]}
		           : {32'd0, nan_src[31:23], 1'b1, nan_src[21:0]};
   wire 	inf_sign = a_is_inf ? sgn_a : sgn_b;
   wire [63:0] 	specinf = fmt ? {inf_sign, 11'h7ff, 52'd0} : {32'd0, inf_sign, 8'hff, 23'd0};
   wire [63:0] 	special_y = any_nan ? qnan : inf_sub_inf ? DEF_NAN : specinf;

   wire [63:0] 	a_pass = fmt ? a : {32'd0, a[31:0]};
   wire [63:0] 	b_pass = fmt ? {sgn_b, b[62:0]} : {32'd0, sgn_b, b[30:0]};
   wire [63:0] 	s1_early_y = special ? special_y : a_is_zero ? b_pass : a_pass;  // b_zero -> a
   wire 	s1_early_valid = special | a_is_zero | b_is_zero;
   wire 	s1_in_denorm = ((exp_a == 'd0) & (frac_a != 'd0)) | ((exp_b == 'd0) & (frac_b != 'd0));

   // alignment
   wire [FW+3:0] t_a_mant = {1'b1, frac_a, 3'b0};
   wire [FW+3:0] t_b_mant = {1'b1, frac_b, 3'b0};
   wire [EW-1:0] t_dist_a = exp_a - exp_b;
   wire [EW-1:0] t_dist_b = exp_b - exp_a;
   wire a_shifted = |(t_a_mant & ~({(FW+4){1'b1}} << t_dist_b));
   wire b_shifted = |(t_b_mant & ~({(FW+4){1'b1}} << t_dist_a));
   logic [FW+3:0] t_a_align, t_b_align;
   logic [EW:0]   t_align_exp;
   always_comb
     begin
	t_a_align = t_a_mant;
	t_b_align = t_b_mant;
	t_align_exp = {1'b0, exp_a};
	if(exp_a > exp_b)
	  t_b_align = (t_b_mant >> t_dist_a) | {{(FW+3){1'b0}}, b_shifted};
	else if(exp_b > exp_a)
	  begin
	     t_a_align = (t_a_mant >> t_dist_b) | {{(FW+3){1'b0}}, a_shifted};
	     t_align_exp = {1'b0, exp_b};
	  end
     end

   // ---- S1 registers ----
   logic [FW+3:0] r1_a, r1_b;
   logic [EW:0]   r1_exp;
   logic 	  r1_sgn_a, r1_sgn_b;
   logic [63:0]   r1_early_y;
   logic 	  r1_early_valid, r1_special, r1_inv, r1_in_den, r1_fmt;
   logic [1:0] 	  r1_rm;
   always_ff @(posedge clk)
     begin
	r1_a <= t_a_align; r1_b <= t_b_align; r1_exp <= t_align_exp;
	r1_sgn_a <= sgn_a; r1_sgn_b <= sgn_b;
	r1_early_y <= s1_early_y; r1_early_valid <= s1_early_valid;
	r1_special <= special; r1_inv <= s1_invalid; r1_in_den <= s1_in_denorm;
	r1_fmt <= fmt; r1_rm <= rm;
     end

   // ================= S2 comb: add / subtract magnitudes =================
   logic [FW+4:0] t_align_sum;
   logic 	  t_align_sign;
   always_comb
     begin
	t_align_sum = {1'b0, r1_a} + r1_b;
	t_align_sign = r1_sgn_a;
	if(r1_sgn_a != r1_sgn_b)
	  begin
	     if(r1_a > r1_b) begin t_align_sum = {1'b0, r1_a} - r1_b; t_align_sign = r1_sgn_a; end
	     else            begin t_align_sum = {1'b0, r1_b} - r1_a; t_align_sign = r1_sgn_b; end
	  end
     end
   logic [FW:0] t_add_mant;
   logic [EW:0] t_add_exp;
   logic 	t_guard, t_round, t_sticky;
   always_comb
     begin
	t_add_mant = t_align_sum[FW+3:3];
	t_guard = t_align_sum[2]; t_round = t_align_sum[1]; t_sticky = t_align_sum[0];
	t_add_exp = r1_exp;
	if(t_align_sum[FW+4])
	  begin
	     t_add_mant = t_align_sum[FW+4:4];
	     t_guard = t_align_sum[3]; t_round = t_align_sum[2];
	     t_sticky = t_align_sum[1] | t_align_sum[0];
	     t_add_exp = r1_exp + 'd1;
	  end
     end

   logic [FW:0] r2_mant;
   logic [EW:0] r2_exp;
   logic 	r2_g, r2_r, r2_s, r2_sign;
   logic [63:0] r2_early_y;
   logic 	r2_early_valid, r2_special, r2_inv, r2_in_den, r2_fmt;
   logic [1:0] 	r2_rm;
   always_ff @(posedge clk)
     begin
	r2_mant <= t_add_mant; r2_exp <= t_add_exp;
	r2_g <= t_guard; r2_r <= t_round; r2_s <= t_sticky; r2_sign <= t_align_sign;
	r2_early_y <= r1_early_y; r2_early_valid <= r1_early_valid;
	r2_special <= r1_special; r2_inv <= r1_inv; r2_in_den <= r1_in_den;
	r2_fmt <= r1_fmt; r2_rm <= r1_rm;
     end

   // ================= S3 comb: leading-zero normalize =================
   localparam LG_FW = 6;
   localparam ZP = (EW+1) - LG_FW;
   wire [LG_FW-1:0] w_clz;
   fpu_zero_detector #(.LG_W(LG_FW), .W(FW)) zd (.distance(w_clz), .a(r2_mant));
   wire [EW:0] 	    w_shift = {{ZP{1'b0}}, w_clz};
   logic [FW:0] t_norm_mant;
   logic [EW:0] t_norm_exp;
   logic 	t_norm_g, t_norm_r, t_norm_s;
   always_comb
     begin
	t_norm_mant = r2_mant; t_norm_exp = r2_exp;
	t_norm_g = r2_g; t_norm_r = r2_r; t_norm_s = r2_s;
	if(r2_mant[FW] == 1'b0 && (r2_exp != 'd0))
	  begin
	     t_norm_exp = r2_exp - w_shift;
	     if(w_shift == 'd1)
	       begin
		  t_norm_g = r2_r; t_norm_r = 1'b0;
		  t_norm_mant = {r2_mant[FW-1:0], r2_g};
	       end
	     else
	       begin
		  t_norm_g = 1'b0; t_norm_r = 1'b0;
		  t_norm_mant = {r2_mant[FW-2:0], r2_g, r2_r} << (w_shift - 'd2);
	       end
	  end
     end
   // result-underflow exponent test (<= 0), for the denorm punt
   wire [EW:0] 	w_lead = (r2_mant[FW] == 1'b0) ? w_shift : {(EW+1){1'b0}};
   wire signed [EW+1:0] w_real_exp = $signed({1'b0, r2_exp}) - $signed({1'b0, w_lead});
   wire 	s3_exp_le0 = w_real_exp[EW+1] | ~(|w_real_exp);

   logic [FW:0] r3_mant;
   logic [EW:0] r3_exp;
   logic 	r3_g, r3_r, r3_s, r3_sign, r3_exp_le0;
   logic [63:0] r3_early_y;
   logic 	r3_early_valid, r3_special, r3_inv, r3_in_den, r3_fmt;
   logic [1:0] 	r3_rm;
   always_ff @(posedge clk)
     begin
	r3_mant <= t_norm_mant; r3_exp <= t_norm_exp;
	r3_g <= t_norm_g; r3_r <= t_norm_r; r3_s <= t_norm_s; r3_sign <= r2_sign;
	r3_exp_le0 <= s3_exp_le0;
	r3_early_y <= r2_early_y; r3_early_valid <= r2_early_valid;
	r3_special <= r2_special; r3_inv <= r2_inv; r3_in_den <= r2_in_den;
	r3_fmt <= r2_fmt; r3_rm <= r2_rm;
     end

   // ================= S4 comb: round + overflow + pack =================
   wire g_d = r3_g, r_d = r3_r, s_d = r3_s, lsb_d = r3_mant[0];
   wire g_s = r3_mant[28], r_s = r3_mant[27];
   wire s_s = (|r3_mant[26:0]) | r3_g | r3_r | r3_s;
   wire lsb_s = r3_mant[29];
   wire w_g = r3_fmt ? g_d : g_s;
   wire w_r = r3_fmt ? r_d : r_s;
   wire w_s = r3_fmt ? s_d : s_s;
   wire w_lsb = r3_fmt ? lsb_d : lsb_s;
   wire w_inexact = w_g | w_r | w_s;
   wire w_round_up =
	(r3_rm == 2'd0) ? (w_g & (w_r | w_s | w_lsb)) :
	(r3_rm == 2'd1) ? 1'b0 :
	(r3_rm == 2'd2) ? (~r3_sign & w_inexact) :
	                  ( r3_sign & w_inexact);
   wire [FW:0]  w_inc = r3_fmt ? {{(FW){1'b0}}, 1'b1} : ({{(FW){1'b0}}, 1'b1} << 29);
   wire [FW+1:0] w_sum_r = {1'b0, r3_mant} + (w_round_up ? {1'b0, w_inc} : {(FW+2){1'b0}});
   wire 	w_round_carry = w_sum_r[FW+1];
   wire [FW:0]  t_round_mant = w_round_carry ? w_sum_r[FW+1:1] : w_sum_r[FW:0];
   wire [EW:0]  t_round_exp  = w_round_carry ? (r3_exp + 'd1) : r3_exp;

   wire 	w_is_zero = (r3_sign & 1'b0) | (t_round_mant == 'd0);   // a-a etc -> +0
   wire [EW-1:0] INF_E = r3_fmt ? INF_EXP : 11'd255;
   wire 	w_overflow = (t_round_exp[EW-1:0] >= INF_E) | t_round_exp[EW];
   wire 	w_ovf_inf =
		(r3_rm == 2'd0) ? 1'b1 :
		(r3_rm == 2'd1) ? 1'b0 :
		(r3_rm == 2'd2) ? ~r3_sign :
		                   r3_sign;
   wire [63:0] 	ovf_inf = r3_fmt ? {r3_sign, 11'h7ff, 52'd0} : {32'd0, r3_sign, 8'hff, 23'd0};
   wire [63:0] 	ovf_max = r3_fmt ? {r3_sign, 11'h7fe, 52'hfffffffffffff} : {32'd0, r3_sign, 8'hfe, 23'h7fffff};
   wire [63:0] 	ovf_y = w_ovf_inf ? ovf_inf : ovf_max;
   wire [63:0] 	norm_y = r3_fmt ? {r3_sign, t_round_exp[10:0], t_round_mant[51:0]}
		              : {32'd0, r3_sign, t_round_exp[7:0], t_round_mant[51:29]};

   wire 	w_res_denorm = ~r3_early_valid & r3_exp_le0 & (t_round_mant != 'd0);
   wire [63:0] 	w_y = r3_early_valid ? r3_early_y :
		w_is_zero  ? 64'd0 :
		w_overflow ? ovf_y : norm_y;
   wire 	w_denorm = ~r3_special & (r3_in_den | w_res_denorm);
   wire 	w_f_inexact  = ~r3_early_valid & ~w_is_zero & (w_inexact | w_overflow);
   wire 	w_f_overflow = ~r3_early_valid & ~w_is_zero & w_overflow;
   wire 	w_f_underflow = ~r3_early_valid & w_res_denorm;
   wire [4:0] 	w_fflags = {r3_inv, 1'b0, w_f_overflow, w_f_underflow, w_f_inexact};

   logic [63:0] r4_y;
   logic 	r4_denorm;
   logic [4:0] 	r4_fflags;
   always_ff @(posedge clk)
     begin
	r4_y <= w_y; r4_denorm <= w_denorm; r4_fflags <= w_fflags;
     end
   assign y = r4_y;
   assign denorm = r4_denorm;
   assign fflags = r4_fflags;

endmodule // fpu_add
