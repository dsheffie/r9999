`include "machine.vh"
// Clustered FP register file (Henry Wong clustered-RF scheme, FP variant).
//
// 4 read / 2 write, banked by the physical-pointer MSB:
//   bank 0 (ptr MSB = 0) = FPU-arith results   -> write port 0 (wr0)
//   bank 1 (ptr MSB = 1) = mem-pipe FP results -> write port 1 (wr1)
//                          (FP loads lwc1/ldc1 + mtc1)
// so each bank has a single write port and reads pick the bank by the source
// pointer's MSB.  Reads are SYNCHRONOUS (registered) so the banks infer
// LUTRAM/BRAM instead of a flop array + combinational mux tree.
//
// Unlike the integer rf4r2w there is NO $0 zero-mux: FP f0 is an ordinary
// register, and the rename/inflight logic already guarantees a source is read
// only after its producer has written it (so an un-written entry is never
// architecturally consumed).  The free-list allocates fp dsts into the bank
// matching their producing write port, so the ptr MSB is meaningful.
module fp_regfile(clk,
		  rdptr0, rdptr1, rdptr2, rdptr3,
		  wrptr0, wrptr1, wen0, wen1,
		  wr0, wr1,
		  rd0, rd1, rd2, rd3);

   parameter WIDTH = 64;
   parameter LG_DEPTH = 7;
   input logic 		      clk;
   input logic [LG_DEPTH-1:0] rdptr0;
   input logic [LG_DEPTH-1:0] rdptr1;
   input logic [LG_DEPTH-1:0] rdptr2;
   input logic [LG_DEPTH-1:0] rdptr3;

   input logic [LG_DEPTH-1:0] wrptr0;   // fpu-arith result ptr (bank 0)
   input logic [LG_DEPTH-1:0] wrptr1;   // mem/load result ptr (bank 1)
   input logic 		      wen0;
   input logic 		      wen1;
   input logic [WIDTH-1:0]    wr0;
   input logic [WIDTH-1:0]    wr1;

   output logic [WIDTH-1:0]   rd0;
   output logic [WIDTH-1:0]   rd1;
   output logic [WIDTH-1:0]   rd2;
   output logic [WIDTH-1:0]   rd3;

   localparam HALF = 1 << (LG_DEPTH-1);
   `RF_RAM_STYLE logic [WIDTH-1:0] r_ram_fpu[HALF-1:0];   // bank 0 (MSB=0)
   `RF_RAM_STYLE logic [WIDTH-1:0] r_ram_mem[HALF-1:0];   // bank 1 (MSB=1)

   always_ff@(posedge clk)
     begin
	rd0 <= rdptr0[LG_DEPTH-1] ? r_ram_mem[rdptr0[LG_DEPTH-2:0]] : r_ram_fpu[rdptr0[LG_DEPTH-2:0]];
	rd1 <= rdptr1[LG_DEPTH-1] ? r_ram_mem[rdptr1[LG_DEPTH-2:0]] : r_ram_fpu[rdptr1[LG_DEPTH-2:0]];
	rd2 <= rdptr2[LG_DEPTH-1] ? r_ram_mem[rdptr2[LG_DEPTH-2:0]] : r_ram_fpu[rdptr2[LG_DEPTH-2:0]];
	rd3 <= rdptr3[LG_DEPTH-1] ? r_ram_mem[rdptr3[LG_DEPTH-2:0]] : r_ram_fpu[rdptr3[LG_DEPTH-2:0]];
	if(wen0)
	  r_ram_fpu[wrptr0[LG_DEPTH-2:0]] <= wr0;
	if(wen1)
	  r_ram_mem[wrptr1[LG_DEPTH-2:0]] <= wr1;
     end

endmodule