// Unified float -> integer convert (with rounding).
//   fmt      : 0 = source f32, 1 = source f64
//   dst_long : 0 = dest i32, 1 = dest i64
//   rm[1:0]  : 0=RN 1=RZ(trunc) 2=RP(ceil/+inf) 3=RM(floor/-inf)
// Covers CVT.W/L (rm=FCSR.RM), TRUNC (RZ), ROUND (RN), CEIL (RP), FLOOR (RM).
// Out-of-range / NaN / inf -> Invalid (V), value don't-care (R4000 punt);
// non-integer source -> Inexact (I).

module fpu_f2i(in, fmt, dst_long, rm, out, fflags);
   input  logic [63:0] in;
   input  logic        fmt;
   input  logic        dst_long;
   input  logic [1:0]  rm;
   output logic [63:0] out;
   output logic [4:0]  fflags;          // {V,Z,O,U,I}

   localparam SW = 53 + 64;             // 117

   // ---- extract (fmt-dependent) ----
   wire 	 sign  = fmt ? in[63] : in[31];
   wire [10:0] 	 exp_d = in[62:52];
   wire [7:0] 	 exp_s = in[30:23];
   wire [51:0] 	 frac_d = in[51:0];
   wire [22:0] 	 frac_s = in[22:0];
   wire [10:0] 	 exp  = fmt ? exp_d : {3'b0, exp_s};
   wire [11:0] 	 bias = fmt ? 12'd1023 : 12'd127;
   wire 	 expo_all1 = fmt ? (&exp_d) : (&exp_s);
   wire 	 frac_nz   = fmt ? (|frac_d) : (|frac_s);
   wire 	 is_nan = expo_all1 &  frac_nz;
   wire 	 is_inf = expo_all1 & ~frac_nz;
   wire 	 is_zero = (exp == 11'd0) & ~frac_nz;
   // significand left-justified to 53 bits (denormal implicit-1 is wrong but the
   // value is then tiny -> rounds to 0/±1 which only needs sign + "nonzero")
   wire [52:0] 	 m53 = fmt ? {1'b1, frac_d} : {1'b1, frac_s, 29'd0};

   // ---- align: shift so integer part is fixed[116:53], fraction fixed[52:0] ----
   wire signed [12:0] E  = $signed({2'b0, exp}) - $signed({1'b0, bias});
   wire signed [13:0] E1 = {E[12], E} + 14'sd1;     // shift amount = E + 1
   wire 	 tiny = E1[13];                     // E1 < 0  -> |value| < 0.5
   wire 	 huge = (E1 > 14'sd64);             // way out of any int range
   wire [6:0] 	 sh = tiny ? 7'd0 : huge ? 7'd64 : E1[6:0];
   wire [SW-1:0] fixed = {64'd0, m53} << sh;

   wire [63:0] 	 w_intmag = tiny ? 64'd0 : fixed[SW-1:53];
   wire 	 w_guard  = tiny ? 1'b0 : fixed[52];
   wire 	 w_sticky = tiny ? ~is_zero : (|fixed[51:0]);
   wire 	 w_lsb    = w_intmag[0];

   // ---- rounding ----
   wire 	 w_inexact = w_guard | w_sticky;
   wire 	 w_round_up =
		 (rm == 2'd0) ? (w_guard & (w_sticky | w_lsb)) :
		 (rm == 2'd1) ? 1'b0 :
		 (rm == 2'd2) ? (~sign & w_inexact) :
		                ( sign & w_inexact);
   wire [64:0] 	 mag_rnd = {1'b0, w_intmag} + {64'd0, w_round_up};

   // ---- overflow (after rounding) ----
   wire [63:0] 	 lim_pos = dst_long ? 64'h7fffffffffffffff : 64'h000000007fffffff;
   wire [63:0] 	 lim_neg = dst_long ? 64'h8000000000000000 : 64'h0000000080000000;
   wire 	 w_overflow = is_nan | is_inf | huge |
		 (sign ? (mag_rnd > {1'b0, lim_neg}) : (mag_rnd > {1'b0, lim_pos}));

   // ---- pack ----
   wire [63:0] 	 mag = mag_rnd[63:0];
   wire [63:0] 	 signed_res = sign ? (~mag + 64'd1) : mag;
   wire [63:0] 	 val = dst_long ? signed_res : {32'd0, signed_res[31:0]};

   assign out    = w_overflow ? 64'd0 : val;   // value don't-care on overflow
   assign fflags = {w_overflow, 1'b0, 1'b0, 1'b0, ~w_overflow & w_inexact};

endmodule // fpu_f2i
