// Unified integer -> float convert.
//   src_long : 0 = source is i32 (low 32 bits, signed), 1 = source is i64
//   fmt      : 0 = dest f32, 1 = dest f64 (in the low 32 bits when f32)
//   rm[1:0]  : 0=RN 1=RZ 2=RP(+inf) 3=RM(-inf)
// Covers CVT.S.W / CVT.D.W / CVT.S.L / CVT.D.L. Only Inexact (I) can be raised
// (int magnitudes never overflow the float exponent range).

module fpu_i2f(in, src_long, fmt, rm, out, fflags);
   input  logic [63:0] in;
   input  logic        src_long;
   input  logic        fmt;
   input  logic [1:0]  rm;
   output logic [63:0] out;
   output logic [4:0]  fflags;       // {V,Z,O,U,I}

   // ---- source sign + magnitude (64-bit) ----
   wire 	 sign = src_long ? in[63] : in[31];
   wire [63:0] 	 neg_l = ~in + 64'd1;
   wire [31:0] 	 neg_w = ~in[31:0] + 32'd1;
   wire [63:0] 	 mag = src_long ? (in[63] ? neg_l : in)
		                : (in[31] ? {32'd0, neg_w} : {32'd0, in[31:0]});
   wire 	 is_zero = (mag == 64'd0);

   // ---- normalize: leading-1 index = unbiased exponent ----
   wire [6:0] 	 ffs;                  // 0..64
   find_lowest_set_bit #(.LG_N(6)) z0 (.in(mag), .y(ffs));
   wire [63:0] 	 shifted = mag << (7'd64 - ffs);   // leading 1 -> bit 64 (out)

   // ---- rounding (fmt-dependent fraction width) ----
   // f64: frac=[63:12] guard=[11] sticky=|[10:0]; f32: frac=[63:41] g=[40] s=|[39:0]
   wire [51:0] 	frac_d = shifted[63:12];
   wire 	g_d = shifted[11], s_d = |shifted[10:0], lsb_d = shifted[12];
   wire [22:0] 	frac_s = shifted[63:41];
   wire 	g_s = shifted[40], s_s = |shifted[39:0], lsb_s = shifted[41];

   wire [51:0] 	frac = fmt ? frac_d : {29'd0, frac_s};
   wire 	w_g = fmt ? g_d : g_s;
   wire 	w_s = fmt ? s_d : s_s;
   wire 	w_lsb = fmt ? lsb_d : lsb_s;
   wire 	w_inexact = w_g | w_s;
   wire 	w_round_up =
		(rm == 2'd0) ? (w_g & (w_s | w_lsb)) :
		(rm == 2'd1) ? 1'b0 :
		(rm == 2'd2) ? (~sign & w_inexact) :
		               ( sign & w_inexact);

   // round the (fmt-width) fraction; carry rolls into the exponent
   wire [52:0] 	frac_rnd = {1'b0, frac} + {52'd0, w_round_up};   // 53-bit, but for f32 only low 23 used
   // for f32 the carry-out is at bit 23, for f64 at bit 52
   wire 	carry_d = frac_rnd[52];
   wire 	carry_s = frac_rnd[23];
   wire 	w_carry = fmt ? carry_d : carry_s;

   // ---- exponent ----
   wire [11:0] 	bias = fmt ? 12'd1023 : 12'd127;
   wire [11:0] 	exp = bias + {5'd0, ffs} + {11'd0, w_carry};

   // ---- pack ----
   wire [51:0] 	out_frac_d = frac_rnd[51:0];
   wire [22:0] 	out_frac_s = frac_rnd[22:0];
   wire [63:0] 	out_d = {sign, exp[10:0], out_frac_d};
   wire [63:0] 	out_s = {32'd0, sign, exp[7:0], out_frac_s};
   wire [63:0] 	val = fmt ? out_d : out_s;

   assign out    = is_zero ? 64'd0 : val;
   assign fflags = {1'b0, 1'b0, 1'b0, 1'b0, ~is_zero & w_inexact};

endmodule // fpu_i2f
