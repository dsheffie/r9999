// Unified single/double-precision FP multiplier -- 4-stage pipeline.
//
// One datapath, sized for double (a 53x53 significand multiply); single runs
// left-justified and is rounded once at single precision. fmt: 0=single (low 32
// bits), 1=double. Pipeline:
//   S1 extract + special | S2 53x53 multiply | S3 normalize | S4 round + pack
// Giving the multiply its own stage lets the S1->S2 and S2->S3 registers pack
// into the DSP48 (AREG/BREG/MREG/PREG) and keeps each phase short.

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
   input logic [1:0]  rm;
   input logic 	      fmt;
   output logic [63:0] y;
   output logic        denorm;
   output logic [4:0]  fflags;

   localparam EW = 11;
   localparam FW = 52;

   // ================= S1 comb: extract + special + early result =================
   wire 	sgn_a = fmt ? a[63] : a[31];
   wire 	sgn_b = fmt ? b[63] : b[31];
   wire 	w_sign = sgn_a ^ sgn_b;
   wire [EW-1:0] exp_a = fmt ? a[62:52] : {3'b0, a[30:23]};
   wire [EW-1:0] exp_b = fmt ? b[62:52] : {3'b0, b[30:23]};
   wire [FW-1:0] frac_a = fmt ? a[51:0] : {a[22:0], 29'b0};
   wire [FW-1:0] frac_b = fmt ? b[51:0] : {b[22:0], 29'b0};
   wire [EW-1:0] INF_EXP = fmt ? 11'd2047 : 11'd255;

   wire 	a_is_zero = (exp_a == 'd0) & (frac_a == 'd0);
   wire 	b_is_zero = (exp_b == 'd0) & (frac_b == 'd0);
   wire 	exp_all1_a = (exp_a == INF_EXP);
   wire 	exp_all1_b = (exp_b == INF_EXP);
   wire 	a_is_nan = exp_all1_a & (frac_a != 'd0);
   wire 	b_is_nan = exp_all1_b & (frac_b != 'd0);
   wire 	a_is_inf = exp_all1_a & (frac_a == 'd0);
   wire 	b_is_inf = exp_all1_b & (frac_b == 'd0);
   wire 	a_is_snan = a_is_nan & ~a[fmt ? 51 : 22];
   wire 	b_is_snan = b_is_nan & ~b[fmt ? 51 : 22];
   wire 	any_nan = a_is_nan | b_is_nan;
   wire 	special = any_nan | a_is_inf | b_is_inf;
   wire 	inf_x_zero = (a_is_inf & b_is_zero) | (b_is_inf & a_is_zero);
   wire 	s1_invalid = a_is_snan | b_is_snan | inf_x_zero;
   wire 	s1_in_denorm = ((exp_a == 'd0) & (frac_a != 'd0)) | ((exp_b == 'd0) & (frac_b != 'd0));

   wire [63:0] 	DEF_NAN = fmt ? {1'b1, 11'h7ff, 1'b1, 51'd0} : {32'd0, 1'b1, 8'hff, 1'b1, 22'd0};
   wire [63:0] 	nan_src = a_is_nan ? a : b;
   wire [63:0] 	qnan = fmt ? {nan_src[63:52], 1'b1, nan_src[50:0]} : {32'd0, nan_src[31:23], 1'b1, nan_src[21:0]};
   wire [63:0] 	inf_y = fmt ? {w_sign, 11'h7ff, 52'd0} : {32'd0, w_sign, 8'hff, 23'd0};
   wire [63:0] 	special_y = any_nan ? qnan : inf_x_zero ? DEF_NAN : inf_y;
   wire [63:0] 	zero_y = fmt ? {w_sign, 63'd0} : {32'd0, w_sign, 31'd0};
   wire 	s1_early_valid = special | a_is_zero | b_is_zero;
   wire [63:0] 	s1_early_y = special ? special_y : zero_y;

   wire [FW:0] 	sig_a = {1'b1, frac_a};
   wire [FW:0] 	sig_b = {1'b1, frac_b};

   logic [FW:0] r1_siga, r1_sigb;
   logic [EW-1:0] r1_expa, r1_expb;
   logic 	r1_sign, r1_fmt, r1_evalid, r1_special, r1_inv, r1_inden;
   logic [1:0] 	r1_rm;
   logic [63:0] r1_early;
   always_ff @(posedge clk)
     begin
	r1_siga <= sig_a; r1_sigb <= sig_b; r1_expa <= exp_a; r1_expb <= exp_b;
	r1_sign <= w_sign; r1_fmt <= fmt; r1_rm <= rm;
	r1_evalid <= s1_early_valid; r1_special <= special; r1_inv <= s1_invalid;
	r1_inden <= s1_in_denorm; r1_early <= s1_early_y;
     end

   // ================= S2 comb: 53x53 multiply =================
   wire [2*FW+1:0] s2_prod = r1_siga * r1_sigb;     // 106-bit, value in [1,4)

   logic [2*FW+1:0] r2_prod;
   logic [EW-1:0]   r2_expa, r2_expb;
   logic 	    r2_sign, r2_fmt, r2_evalid, r2_special, r2_inv, r2_inden;
   logic [1:0] 	    r2_rm;
   logic [63:0]     r2_early;
   always_ff @(posedge clk)
     begin
	r2_prod <= s2_prod; r2_expa <= r1_expa; r2_expb <= r1_expb;
	r2_sign <= r1_sign; r2_fmt <= r1_fmt; r2_rm <= r1_rm;
	r2_evalid <= r1_evalid; r2_special <= r1_special; r2_inv <= r1_inv;
	r2_inden <= r1_inden; r2_early <= r1_early;
     end

   // ================= S3 comb: normalize + base exponent =================
   wire 	s3_top = r2_prod[2*FW+1];
   wire [FW:0] 	s3_sig = s3_top ? r2_prod[2*FW+1:FW+1] : r2_prod[2*FW:FW];
   wire 	s3_gd = s3_top ? r2_prod[FW]   : r2_prod[FW-1];
   wire 	s3_rd = s3_top ? r2_prod[FW-1] : r2_prod[FW-2];
   wire 	s3_sd = s3_top ? (|r2_prod[FW-2:0]) : (|r2_prod[FW-3:0]);
   wire [EW-1:0] BIAS = r2_fmt ? 11'd1023 : 11'd127;
   // base exponent (signed) = exp_a + exp_b + prod_top - bias  (round-carry added in S4)
   wire [EW+2:0] s3_esum = {3'b0, r2_expa} + {3'b0, r2_expb} + {{(EW+2){1'b0}}, s3_top};
   wire signed [EW+2:0] s3_ebase = $signed(s3_esum) - $signed({3'b0, BIAS});

   logic [FW:0] r3_sig;
   logic 	r3_gd, r3_rd, r3_sd, r3_sign, r3_fmt, r3_evalid, r3_special, r3_inv, r3_inden;
   logic [1:0] 	r3_rm;
   logic signed [EW+2:0] r3_ebase;
   logic [63:0] r3_early;
   always_ff @(posedge clk)
     begin
	r3_sig <= s3_sig; r3_gd <= s3_gd; r3_rd <= s3_rd; r3_sd <= s3_sd;
	r3_sign <= r2_sign; r3_fmt <= r2_fmt; r3_rm <= r2_rm; r3_ebase <= s3_ebase;
	r3_evalid <= r2_evalid; r3_special <= r2_special; r3_inv <= r2_inv;
	r3_inden <= r2_inden; r3_early <= r2_early;
     end

   // ================= S4 comb: round + overflow + pack =================
   wire g_s = r3_sig[28], r_s = r3_sig[27];
   wire s_s = (|r3_sig[26:0]) | r3_gd | r3_rd | r3_sd;
   wire lsb_d = r3_sig[0], lsb_s = r3_sig[29];
   wire w_g = r3_fmt ? r3_gd : g_s;
   wire w_r = r3_fmt ? r3_rd : r_s;
   wire w_s = r3_fmt ? r3_sd : s_s;
   wire w_lsb = r3_fmt ? lsb_d : lsb_s;
   wire w_inexact = w_g | w_r | w_s;
   wire w_round_up =
	(r3_rm == 2'd0) ? (w_g & (w_r | w_s | w_lsb)) :
	(r3_rm == 2'd1) ? 1'b0 :
	(r3_rm == 2'd2) ? (~r3_sign & w_inexact) :
	                  ( r3_sign & w_inexact);
   wire [FW:0]  w_inc = r3_fmt ? {{(FW){1'b0}}, 1'b1} : ({{(FW){1'b0}}, 1'b1} << 29);
   wire [FW+1:0] w_sum_r = {1'b0, r3_sig} + (w_round_up ? {1'b0, w_inc} : {(FW+2){1'b0}});
   wire 	w_round_carry = w_sum_r[FW+1];
   wire [FW:0] 	w_final_sig = w_round_carry ? w_sum_r[FW+1:1] : w_sum_r[FW:0];

   wire signed [EW+2:0] w_exp_real = r3_ebase + {{(EW+2){1'b0}}, w_round_carry};
   wire [EW-1:0] INF_E = r3_fmt ? 11'd2047 : 11'd255;
   wire 	w_arith = ~r3_evalid;
   wire 	w_overflow  = w_arith & (w_exp_real >= $signed({3'b0, INF_E}));
   wire 	w_underflow = w_arith & (w_exp_real[EW+2] | ~(|w_exp_real));
   wire 	w_ovf_inf =
		(r3_rm == 2'd0) ? 1'b1 :
		(r3_rm == 2'd1) ? 1'b0 :
		(r3_rm == 2'd2) ? ~r3_sign :
		                   r3_sign;
   wire [EW-1:0] w_pack_exp = w_exp_real[EW-1:0];
   wire [63:0] 	ovf_inf = r3_fmt ? {r3_sign, 11'h7ff, 52'd0} : {32'd0, r3_sign, 8'hff, 23'd0};
   wire [63:0] 	ovf_max = r3_fmt ? {r3_sign, 11'h7fe, 52'hfffffffffffff} : {32'd0, r3_sign, 8'hfe, 23'h7fffff};
   wire [63:0] 	ovf_y = w_ovf_inf ? ovf_inf : ovf_max;
   wire [63:0] 	norm_y = r3_fmt ? {r3_sign, w_pack_exp[10:0], w_final_sig[51:0]}
		              : {32'd0, r3_sign, w_pack_exp[7:0], w_final_sig[51:29]};

   wire [63:0] 	w_y = r3_evalid ? r3_early : w_overflow ? ovf_y : norm_y;
   wire 	w_denorm = ~r3_special & (r3_inden | w_underflow);
   wire 	w_f_inexact  = w_arith & (w_inexact | w_overflow);
   wire 	w_f_overflow = w_overflow;
   wire 	w_f_underflow = w_underflow;
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

endmodule // fpu_mul
