`include "fp_compare.vh"

// Unified single/double-precision FP comparator (fmt-selected at runtime).
// fmt: 0 = single (operand in low 32 bits), 1 = double.
//
// A compare needs no wide datapath: for a given sign, the IEEE encoding is
// monotonic in its bit pattern, so the magnitude compare is just an unsigned
// compare of the low W-1 bits.  Extract {sign, magnitude} per fmt and the rest
// is format-independent.  D-deep pipeline (matches fp_compare).

module fpu_compare(clk, a, b, start, cmp_type, fmt, y, fflags);
   parameter D = 4;

   input logic 	      clk;
   input logic [63:0] a;
   input logic [63:0] b;
   input logic 	      start;          // unused (interface parity)
   input 	      fp_cmp_t cmp_type;
   input logic 	      fmt;            // 0 = single, 1 = double
   output logic       y;
   output logic [4:0] fflags;          // {V,Z,O,U,I}; a compare only raises V

   // ---------------- field extraction (fmt-dependent) ----------------
   wire 	sgn_a = fmt ? a[63] : a[31];
   wire 	sgn_b = fmt ? b[63] : b[31];
   wire [62:0] 	mag_a = fmt ? a[62:0] : {32'b0, a[30:0]};   // exp:mant, zero-extended
   wire [62:0] 	mag_b = fmt ? b[62:0] : {32'b0, b[30:0]};

   wire 	a_is_zero = (mag_a == 63'd0);
   wire 	b_is_zero = (mag_b == 63'd0);
   wire 	s_a = a_is_zero ? 1'b0 : sgn_a;   // treat -0 as +0
   wire 	s_b = b_is_zero ? 1'b0 : sgn_b;

   // ---------------- NaN detection ----------------
   wire 	exp1_a = fmt ? (&a[62:52]) : (&a[30:23]);
   wire 	exp1_b = fmt ? (&b[62:52]) : (&b[30:23]);
   wire 	frac_nz_a = fmt ? (|a[51:0]) : (|a[22:0]);
   wire 	frac_nz_b = fmt ? (|b[51:0]) : (|b[22:0]);
   wire 	a_is_nan = exp1_a & frac_nz_a;
   wire 	b_is_nan = exp1_b & frac_nz_b;
   wire 	a_qbit = fmt ? a[51] : a[22];     // quiet bit = frac MSB
   wire 	b_qbit = fmt ? b[51] : b[22];
   wire 	a_snan = a_is_nan & ~a_qbit;
   wire 	b_snan = b_is_nan & ~b_qbit;
   wire 	w_unordered = a_is_nan | b_is_nan;
   wire 	w_any_snan  = a_snan | b_snan;

   // ---------------- sign / magnitude compare ----------------
   wire 	sign_eq   = (s_a == s_b);
   wire 	w_sign_lt = (s_a ^ s_b) & s_a;          // a negative, b positive
   wire 	w_sign_gt = (s_a ^ s_b) & s_b;
   wire 	w_mag_lt  = (mag_a < mag_b) & sign_eq;
   wire 	w_mag_gt  = (mag_a > mag_b) & sign_eq;
   wire 	w_both_neg = s_a & s_b;
   wire 	w_lt_t = w_sign_lt | w_mag_lt;
   wire 	w_gt_t = w_sign_gt | w_mag_gt;
   wire 	w_lt = w_both_neg ? w_gt_t : w_lt_t;     // both negative -> order flips
   wire 	w_eq = (mag_a == mag_b) & (s_a == s_b);  // +0 == -0 falls out (s forced 0)
   wire 	w_le = w_lt | w_eq;

   // ---------------- result + invalid flag ----------------
   logic 	t_y, t_invalid;
   always_comb
     begin
	t_y = 1'b0;
	if(!w_unordered)               // NaN -> unordered -> false
	  case(cmp_type)
	    CMP_LT:  t_y = w_lt;
	    CMP_LE:  t_y = w_le;
	    CMP_EQ:  t_y = w_eq;
	    default: t_y = 1'b0;
	  endcase
     end
   always_comb
     begin
	// LT/LE signaling -> invalid on any NaN; EQ quiet -> invalid on sNaN only
	t_invalid = 1'b0;
	case(cmp_type)
	  CMP_LT, CMP_LE: t_invalid = w_unordered;
	  CMP_EQ:         t_invalid = w_any_snan;
	  default:        t_invalid = 1'b0;
	endcase
     end

   // ---------------- D-deep output pipeline ----------------
   logic [D-1:0]      r_d, r_v;
   wire [D-1:0]       w_d, w_v;
   assign y = r_d[D-1];
   assign fflags = {r_v[D-1], 4'b0};
   generate
      assign w_d[0] = t_y;
      assign w_v[0] = t_invalid;
      for(genvar i = 1; i < D; i=i+1)
	begin
	   assign w_d[i] = r_d[i-1];
	   assign w_v[i] = r_v[i-1];
	end
   endgenerate
   always_ff@(posedge clk)
     begin
	r_d <= w_d;
	r_v <= w_v;
     end

endmodule // fpu_compare
