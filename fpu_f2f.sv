// Float <-> float format convert.
//   to_double : 1 = f32 -> f64 (CVT.D.S, widen, exact)
//               0 = f64 -> f32 (CVT.S.D, narrow, rounds; rm picks mode)
// Denormal operand or a narrowing result that underflows -> denorm (punt, R4000
// E-trap); narrowing overflow -> inf/max by rm (O,I); NaN propagated (V on sNaN).

module fpu_f2f(in, to_double, rm, out, denorm, fflags);
   input  logic [63:0] in;
   input  logic        to_double;
   input  logic [1:0]  rm;
   output logic [63:0] out;
   output logic        denorm;
   output logic [4:0]  fflags;          // {V,Z,O,U,I}

   // ---- source f32 fields (widen) ----
   wire 	 s_sign = in[31];
   wire [7:0] 	 s_exp  = in[30:23];
   wire [22:0] 	 s_frac = in[22:0];
   wire 	 s_nan  = (&s_exp) &  (|s_frac);
   wire 	 s_inf  = (&s_exp) & ~(|s_frac);
   wire 	 s_zero = (s_exp == 8'd0) & ~(|s_frac);
   wire 	 s_den  = (s_exp == 8'd0) &  (|s_frac);
   wire 	 s_snan = s_nan & ~s_frac[22];

   // ---- source f64 fields (narrow) ----
   wire 	 d_sign = in[63];
   wire [10:0] 	 d_exp  = in[62:52];
   wire [51:0] 	 d_frac = in[51:0];
   wire 	 d_nan  = (&d_exp) &  (|d_frac);
   wire 	 d_inf  = (&d_exp) & ~(|d_frac);
   wire 	 d_zero = (d_exp == 11'd0) & ~(|d_frac);
   wire 	 d_den  = (d_exp == 11'd0) &  (|d_frac);
   wire 	 d_snan = d_nan & ~d_frac[51];

   // ===== widen f32 -> f64 (exact) =====
   wire [63:0] 	 wide_nan  = {s_sign, 11'h7ff, 1'b1, s_frac[21:0], 29'd0};
   wire [63:0] 	 wide_inf  = {s_sign, 11'h7ff, 52'd0};
   wire [63:0] 	 wide_zero = {s_sign, 63'd0};
   wire [10:0] 	 wide_exp  = {3'd0, s_exp} + 11'd896;   // bias 1023 - 127
   wire [63:0] 	 wide_norm = {s_sign, wide_exp, s_frac, 29'd0};
   wire [63:0] 	 wide_y = s_nan ? wide_nan : s_inf ? wide_inf : s_zero ? wide_zero : wide_norm;

   // ===== narrow f64 -> f32 (round 52->23) =====
   wire [31:0] 	 narrow_nan  = {d_sign, 8'hff, 1'b1, d_frac[50:29]};
   wire [31:0] 	 narrow_inf  = {d_sign, 8'hff, 23'd0};
   wire [31:0] 	 narrow_zero = {d_sign, 31'd0};

   wire signed [12:0] n_e = $signed({2'b0, d_exp}) - 13'sd896;   // f32 biased exp (signed)
   wire 	 n_g = d_frac[28], n_s = |d_frac[27:0], n_lsb = d_frac[29];
   wire 	 n_inexact = n_g | n_s;
   wire 	 n_round_up =
		 (rm == 2'd0) ? (n_g & (n_s | n_lsb)) :
		 (rm == 2'd1) ? 1'b0 :
		 (rm == 2'd2) ? (~d_sign & n_inexact) :
		                ( d_sign & n_inexact);
   wire [23:0] 	 n_frac_rnd = {1'b0, d_frac[51:29]} + {23'd0, n_round_up};
   wire 	 n_carry = n_frac_rnd[23];
   wire signed [12:0] n_e_f = n_e + {12'd0, n_carry};
   wire 	 n_overflow  = (n_e_f >= 13'sd255);
   wire 	 n_underflow = (n_e_f <= 13'sd0);
   wire 	 n_ovf_inf =
		 (rm == 2'd0) ? 1'b1 :
		 (rm == 2'd1) ? 1'b0 :
		 (rm == 2'd2) ? ~d_sign :
		                 d_sign;
   wire [31:0] 	 n_ovf_y = n_ovf_inf ? {d_sign, 8'hff, 23'd0} : {d_sign, 8'hfe, 23'h7fffff};
   wire [31:0] 	 narrow_norm = {d_sign, n_e_f[7:0], n_frac_rnd[22:0]};
   wire [31:0] 	 narrow_y32 = d_nan  ? narrow_nan :
		 d_inf  ? narrow_inf  :
		 d_zero ? narrow_zero :
		 n_overflow ? n_ovf_y : narrow_norm;

   wire 	 n_is_special = d_nan | d_inf | d_zero;
   wire 	 narrow_denorm = d_den | (~n_is_special & n_underflow);

   // ===== select =====
   assign out = to_double ? wide_y : {32'd0, narrow_y32};
   assign denorm = to_double ? s_den : narrow_denorm;

   wire 	 w_invalid  = to_double ? s_snan : d_snan;
   wire 	 w_overflow = ~to_double & ~n_is_special & n_overflow;
   wire 	 w_inexact  = to_double ? 1'b0
		 : (~n_is_special & ~n_underflow & (n_inexact | n_overflow));
   assign fflags = {w_invalid, 1'b0, w_overflow, 1'b0, w_inexact};

endmodule // fpu_f2f
