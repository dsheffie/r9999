`include "machine.vh"

`ifdef VERILATOR
/* checkpoint resume: seed the integer PRF from the ISS state at reset (Verilator
 * only -- stripped from synth). Mirrors rv64core rf6r3w. */
import "DPI-C" function longint loadgpr(input int regid);
`endif
`ifdef SECOND_EXEC_PORT

/* rf4r2w plus the SECOND_EXEC_PORT cheap ALU: read ports 4/5 for its operands and
 * write port 2 for its result (rv64core rf6r3w).  The cheap ALU's pdsts come from the
 * ALU bank like the main ALU's, so that bank takes two write ports and can no longer
 * be a single-write-port RAM: it is left to synthesis (flops), as in rv64core. */
module rf6r3w(clk, reset,
	      rdptr0,rdptr1,rdptr2,rdptr3,rdptr4,rdptr5,
	      wrptr0,wrptr1,wrptr2,wen0,wen1,wen2,
	      wr0, wr1, wr2,
	      rd0, rd1, rd2, rd3, rd4, rd5);

   parameter WIDTH = 1;
   parameter LG_DEPTH = 1;
   input logic clk;
   input logic reset;   /* only consumed by the VERILATOR checkpoint seed below */
   input logic [LG_DEPTH-1:0] rdptr0;
   input logic [LG_DEPTH-1:0] rdptr1;
   input logic [LG_DEPTH-1:0] rdptr2;
   input logic [LG_DEPTH-1:0] rdptr3;
   input logic [LG_DEPTH-1:0] rdptr4;
   input logic [LG_DEPTH-1:0] rdptr5;

   input logic [LG_DEPTH-1:0] wrptr0;
   input logic [LG_DEPTH-1:0] wrptr1;
   input logic [LG_DEPTH-1:0] wrptr2;

   input logic 		      wen0;
   input logic 		      wen1;
   input logic 		      wen2;
   input logic [WIDTH-1:0]    wr0;
   input logic [WIDTH-1:0]    wr1;
   input logic [WIDTH-1:0]    wr2;

   output logic [WIDTH-1:0]   rd0;
   output logic [WIDTH-1:0]   rd1;
   output logic [WIDTH-1:0]   rd2;
   output logic [WIDTH-1:0]   rd3;
   output logic [WIDTH-1:0]   rd4;
   output logic [WIDTH-1:0]   rd5;

   /* Clustered (banked) register file (Henry Wong clustered RF).
    * Pointer MSB selects the ALU bank (0) or MEM bank (1); the low LG_DEPTH-1
    * bits index within a bank.  Write port 0 = ALU results -> ALU bank,
    * write port 1 = MEM (load) results -> MEM bank, so each bank has a single
    * write port.  Reads pick the bank by the source pointer's MSB. */
   localparam HALF = 1 << (LG_DEPTH-1);
   logic [WIDTH-1:0] 		    r_ram_alu[HALF-1:0];
   `RF_RAM_STYLE logic [WIDTH-1:0] 	    r_ram_mem[HALF-1:0];

   always_ff@(posedge clk)
     begin
`ifdef VERILATOR
	if(reset)
	  begin
	     /* seed phys reg i = arch reg i (initial RAT is identity); both banks
	      * so whichever the RAT points at carries the value. i=0 stays 0. */
	     for(integer i = 1; i < 32; i=i+1)
	       begin
		  r_ram_alu[i] <= loadgpr(i);
		  r_ram_mem[i] <= loadgpr(i);
	       end
	  end
	else
	  begin
`endif //  `ifdef VERILATOR
`ifdef FPGA
	/* FPGA/sim: the RF powers up to 0 (BRAM/bitstream INIT; Verilator zeroes
	 * state) and phys reg 0 ($0) is provably never written (dst_valid=(rd!=0);
	 * phys 0 reserved in the free list + never freed), so reading it returns 0
	 * directly -- no rdptr==0 mux.  Dropping the conditional read removes a 2:1
	 * mux per port AND lets the banks infer block RAM. */
	rd0 <= rdptr0[LG_DEPTH-1] ? r_ram_mem[rdptr0[LG_DEPTH-2:0]] : r_ram_alu[rdptr0[LG_DEPTH-2:0]];
	rd1 <= rdptr1[LG_DEPTH-1] ? r_ram_mem[rdptr1[LG_DEPTH-2:0]] : r_ram_alu[rdptr1[LG_DEPTH-2:0]];
	rd2 <= rdptr2[LG_DEPTH-1] ? r_ram_mem[rdptr2[LG_DEPTH-2:0]] : r_ram_alu[rdptr2[LG_DEPTH-2:0]];
	rd3 <= rdptr3[LG_DEPTH-1] ? r_ram_mem[rdptr3[LG_DEPTH-2:0]] : r_ram_alu[rdptr3[LG_DEPTH-2:0]];
	rd4 <= rdptr4[LG_DEPTH-1] ? r_ram_mem[rdptr4[LG_DEPTH-2:0]] : r_ram_alu[rdptr4[LG_DEPTH-2:0]];
	rd5 <= rdptr5[LG_DEPTH-1] ? r_ram_mem[rdptr5[LG_DEPTH-2:0]] : r_ram_alu[rdptr5[LG_DEPTH-2:0]];
`else
	/* No power-up-zero guarantee (e.g. ASIC SRAM): the rdptr==0 -> 0 mux IS the
	 * mechanism that makes $0 read as 0.  Such a target must keep this (or add an
	 * explicit RF zero/clear sequence at reset). */
	rd0 <= rdptr0=='d0 ? 'd0 : (rdptr0[LG_DEPTH-1] ? r_ram_mem[rdptr0[LG_DEPTH-2:0]] : r_ram_alu[rdptr0[LG_DEPTH-2:0]]);
	rd1 <= rdptr1=='d0 ? 'd0 : (rdptr1[LG_DEPTH-1] ? r_ram_mem[rdptr1[LG_DEPTH-2:0]] : r_ram_alu[rdptr1[LG_DEPTH-2:0]]);
	rd2 <= rdptr2=='d0 ? 'd0 : (rdptr2[LG_DEPTH-1] ? r_ram_mem[rdptr2[LG_DEPTH-2:0]] : r_ram_alu[rdptr2[LG_DEPTH-2:0]]);
	rd3 <= rdptr3=='d0 ? 'd0 : (rdptr3[LG_DEPTH-1] ? r_ram_mem[rdptr3[LG_DEPTH-2:0]] : r_ram_alu[rdptr3[LG_DEPTH-2:0]]);
	rd4 <= rdptr4=='d0 ? 'd0 : (rdptr4[LG_DEPTH-1] ? r_ram_mem[rdptr4[LG_DEPTH-2:0]] : r_ram_alu[rdptr4[LG_DEPTH-2:0]]);
	rd5 <= rdptr5=='d0 ? 'd0 : (rdptr5[LG_DEPTH-1] ? r_ram_mem[rdptr5[LG_DEPTH-2:0]] : r_ram_alu[rdptr5[LG_DEPTH-2:0]]);
`endif
	/* NEVER write phys reg 0 ($0): the FPGA read path dropped the rdptr==0->0 mux
	 * on the invariant that $0 is never written, but an r0-dest op (e.g. ssnop =
	 * sll $0,$0,1) reaches here with wrptr0==0 & wen0.  This gate enforces it. */
	if(wen0 & (wrptr0 != 'd0))
	  r_ram_alu[wrptr0[LG_DEPTH-2:0]] <= wr0;
	if(wen2 & (wrptr2 != 'd0))
	  r_ram_alu[wrptr2[LG_DEPTH-2:0]] <= wr2;
	if(wen1)
	  r_ram_mem[wrptr1[LG_DEPTH-2:0]] <= wr1;
`ifdef VERILATOR
	/* BANK INVARIANT.  Writes choose the bank by PORT (port0->alu, port1->mem) and
	 * ignore the pointer MSB; reads choose it by the pointer MSB.  So an ALU result
	 * whose pdst has MSB=1, or a load result whose pdst has MSB=0, is written into
	 * one bank and read from the other -- the reader silently gets a STALE value.
	 * The allocator is supposed to guarantee this (core.sv steers the free list by
	 * t_uop.is_mem), but nothing checks that the steering and the completion port
	 * agree.  That disagreement would look exactly like the captured jr bug: correct
	 * value in the ROB, correct completion order, stale operand at the consumer. */
	if(wen0 & (wrptr0 != 'd0) & (wrptr0[LG_DEPTH-1] != 1'b0))
	  begin
	     $display("[RF-BANK] ALU-port write to MEM-bank pdst: wrptr0=%d", wrptr0);
	  end
	if(wen2 & (wrptr2 != 'd0) & (wrptr2[LG_DEPTH-1] != 1'b0))
	  begin
	     $display("[RF-BANK] ALU2-port write to MEM-bank pdst: wrptr2=%d", wrptr2);
	  end
	if(wen1 & (wrptr1[LG_DEPTH-1] != 1'b1))
	  begin
	     $display("[RF-BANK] MEM-port write to ALU-bank pdst: wrptr1=%d", wrptr1);
	  end
`endif
`ifdef VERILATOR
	  end // else: !if(reset)
`endif
     end

endmodule
`endif // SECOND_EXEC_PORT
