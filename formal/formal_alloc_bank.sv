// formal_alloc_bank -- discharge the free-list half of the WRITE-SIDE BANKING
// invariant that rf4r2w depends on and formal_rf_p0 currently ASSUMES:
//
//     assume(wrptr0[LG-1] == 1'b0);   /* port0 = ALU bank */
//     assume(wrptr1[LG-1] == 1'b1);   /* port1 = MEM bank */
//
// rf4r2w picks the bank for a WRITE by PORT (port0->r_ram_alu, port1->r_ram_mem)
// but for a READ by the pointer MSB.  So if the allocator ever handed an
// ALU-completing uop a MEM-bank pointer (or vice versa) the value would be
// written to one bank and read back from the other -- a silently STALE operand,
// which is exactly the signature of the captured jr/branch faults.  core.sv has
// only a `ifdef VERILATOR $display for this; silicon has no check at all.
//
// The invariant decomposes as:
//   L1  INT_WRITER => ~is_mem                    -- PROVEN (formal_decode_p0 bad3)
//   L2  the pool the allocator reads from yields a pointer in the matching bank
//                                                -- THIS FILE
//   L3  completion port agrees with is_mem       -- still open
//
// L2 is purely COMBINATIONAL: the pool masks are built with a structural index
// predicate (bits >= N/2 forced to 0 in the ALU masks, bits < N/2 forced to 0 in
// the MEM masks), so a priority encoder over them cannot return an out-of-bank
// index -- PROVIDED it returns the index of a genuinely set bit.  That proviso is
// the whole content of the proof, because find_lowest_set_bit returns N (not a
// valid index) when its input is zero, and N has the bank bit SET.  Hence every
// property below is qualified on the pool being non-empty, which is exactly what
// the allocator's *_full gating enforces.  An unqualified assert would be false.
//
// Parity is proven too: the retire-time reader-agreement checker (ENABLE_RDCHK)
// pools its producer table by {ptr[MSB], ptr[0]} on the assumption that the
// even/odd free lists really do yield even/odd pointers.  Same encoders, so it
// costs nothing to close here.
//
// yosys `sat -set bad 1` must be UNSAT; `-set active 1` must be SAT (non-vacuous).
module formal_alloc_bank(
   input logic [127:0]  free,
   output logic         active,
   output logic         bad,
   // individually addressable so a failure names the pool and the reason
   output logic         bad_ae_bank, bad_ao_bank, bad_me_bank, bad_mo_bank,
   output logic         bad_ae_par,  bad_ao_par,  bad_me_par,  bad_mo_par
);
   localparam LG = 7;              /* `LG_PRF_ENTRIES */
   localparam N  = 1 << LG;        /* 128 physical registers */

   wire [N-1:0] w_alu_even, w_alu_odd, w_mem_even, w_mem_odd;

   /* mirrors core.sv prf_pool_split verbatim */
   generate
      for(genvar i = 0; i < N; i=i+1)
	begin : prf_pool_split
	   assign w_alu_even[i] = ((i <  N/2) && (i % 2 == 0)) ? free[i] : 1'b0;
	   assign w_alu_odd[i]  = ((i <  N/2) && (i % 2 == 1)) ? free[i] : 1'b0;
	   assign w_mem_even[i] = ((i >= N/2) && (i % 2 == 0)) ? free[i] : 1'b0;
	   assign w_mem_odd[i]  = ((i >= N/2) && (i % 2 == 1)) ? free[i] : 1'b0;
	end
   endgenerate

   wire [LG:0] w_ffs_alu_even, w_ffs_alu_odd, w_ffs_mem_even, w_ffs_mem_odd;
   find_lowest_set_bit#(LG) ffs_ae(.in(w_alu_even), .y(w_ffs_alu_even));
   find_lowest_set_bit#(LG) ffs_ao(.in(w_alu_odd),  .y(w_ffs_alu_odd));
   find_lowest_set_bit#(LG) ffs_me(.in(w_mem_even), .y(w_ffs_mem_even));
   find_lowest_set_bit#(LG) ffs_mo(.in(w_mem_odd),  .y(w_ffs_mem_odd));

   /* the allocator truncates to LG bits: n_prf_entry = t_gpr_ffs[LG-1:0] */
   wire [LG-1:0] w_ae = w_ffs_alu_even[LG-1:0];
   wire [LG-1:0] w_ao = w_ffs_alu_odd[LG-1:0];
   wire [LG-1:0] w_me = w_ffs_mem_even[LG-1:0];
   wire [LG-1:0] w_mo = w_ffs_mem_odd[LG-1:0];

   /* pool non-empty == the allocator's !*_full gate.  Every property is qualified
    * on it; without the qualification the ffs "none" encoding (N) makes them false. */
   wire w_ae_ok = |w_alu_even;
   wire w_ao_ok = |w_alu_odd;
   wire w_me_ok = |w_mem_even;
   wire w_mo_ok = |w_mem_odd;

   /* BANK: bit LG-1 of the pointer is what rf4r2w's READ path uses to pick the bank */
   assign bad_ae_bank = w_ae_ok & ( w_ae[LG-1]);   /* ALU pool must give MSB 0 */
   assign bad_ao_bank = w_ao_ok & ( w_ao[LG-1]);
   assign bad_me_bank = w_me_ok & (~w_me[LG-1]);   /* MEM pool must give MSB 1 */
   assign bad_mo_bank = w_mo_ok & (~w_mo[LG-1]);

   /* PARITY: the rdchk producer-table pooling assumes even/odd lists are honest */
   assign bad_ae_par  = w_ae_ok & ( w_ae[0]);
   assign bad_ao_par  = w_ao_ok & (~w_ao[0]);
   assign bad_me_par  = w_me_ok & ( w_me[0]);
   assign bad_mo_par  = w_mo_ok & (~w_mo[0]);

   assign bad = bad_ae_bank | bad_ao_bank | bad_me_bank | bad_mo_bank |
		bad_ae_par  | bad_ao_par  | bad_me_par  | bad_mo_par;

   /* vacuity: all four pools can be simultaneously non-empty */
   assign active = w_ae_ok & w_ao_ok & w_me_ok & w_mo_ok;
endmodule // formal_alloc_bank
