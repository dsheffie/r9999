`include "machine.vh"

`ifdef VERILATOR
/* checkpoint resume: seed the integer PRF from the ISS state at reset (Verilator
 * only -- stripped from synth). Mirrors rv64core rf6r3w. */
import "DPI-C" function longint loadgpr(input int regid);
`endif

module rf4r2w(clk, reset,
	      rdptr0,rdptr1,rdptr2,rdptr3,
	      wrptr0,wrptr1,wen0,wen1,
	      wr0, wr1,
	      rd0, rd1, rd2, rd3);

   parameter WIDTH = 1;
   parameter LG_DEPTH = 1;
   input logic clk;
   input logic reset;   /* only consumed by the VERILATOR checkpoint seed below */
   input logic [LG_DEPTH-1:0] rdptr0;
   input logic [LG_DEPTH-1:0] rdptr1;
   input logic [LG_DEPTH-1:0] rdptr2;
   input logic [LG_DEPTH-1:0] rdptr3;

   input logic [LG_DEPTH-1:0] wrptr0;
   input logic [LG_DEPTH-1:0] wrptr1;

   input logic 		      wen0;
   input logic 		      wen1;
   input logic [WIDTH-1:0]    wr0;
   input logic [WIDTH-1:0]    wr1;

   output logic [WIDTH-1:0]   rd0;
   output logic [WIDTH-1:0]   rd1;
   output logic [WIDTH-1:0]   rd2;
   output logic [WIDTH-1:0]   rd3;

   /* Clustered (banked) register file (Henry Wong clustered RF).
    * Pointer MSB selects the ALU bank (0) or MEM bank (1); the low LG_DEPTH-1
    * bits index within a bank.  Write port 0 = ALU results -> ALU bank,
    * write port 1 = MEM (load) results -> MEM bank, so each bank has a single
    * write port.  Reads pick the bank by the source pointer's MSB. */
   localparam HALF = 1 << (LG_DEPTH-1);
`ifdef FORMAL_PRF_SMALL
   /* Formal-only "hacked PRF": FORMAL_PRF_SMALL restricts the core.sv free list
    * to phys 32..47 (ALU bank) and 64..111 (MEM bank), so the only entries that
    * can ever hold a value are ALU-bank 0..47 (arch 0..31 + allocatable 32..47)
    * and MEM-bank 0..47 (phys 64..111).  Marking them unallocatable is NOT enough
    * to shrink the model -- the write index is data-dependent, so yosys cannot
    * prove the dead entries are never written and opt_clean keeps every flop
    * (measured: 39461 latches with and without the free-list restriction alone).
    * So physically shrink the arrays here and read the dead range as zero, which
    * takes the model to 37413 latches / 855538 ands (-5.2% / -3.3%).
    * A dead entry is unreachable by construction: the RAT only ever points at a
    * reserved reg or one the free list handed out.  The VERILATOR check below
    * fails loudly if that ever stops being true, rather than silently masking it
    * -- and masking would be the dangerous outcome here, since a consistently
    * zero read still SATISFIES a reader-agreement property.
    * See core.sv for why the pool cannot be shrunk below 32 + ROB per bank. */
   localparam ALU_LIVE = 48;
   localparam MEM_LIVE = 48;
   localparam LG_ALU_LIVE = 6;
   localparam LG_MEM_LIVE = 6;
`else
   localparam ALU_LIVE = HALF;
   localparam MEM_LIVE = HALF;
   localparam LG_ALU_LIVE = LG_DEPTH-1;
   localparam LG_MEM_LIVE = LG_DEPTH-1;
`endif
   `RF_RAM_STYLE logic [WIDTH-1:0] 	    r_ram_alu[ALU_LIVE-1:0];
   `RF_RAM_STYLE logic [WIDTH-1:0] 	    r_ram_mem[MEM_LIVE-1:0];

`ifdef FORMAL_PRF_SMALL
   wire [WIDTH-1:0] w_rf_rd0 = rdptr0[LG_DEPTH-1]
	? ((rdptr0[LG_DEPTH-2:0] < MEM_LIVE) ? r_ram_mem[rdptr0[LG_MEM_LIVE-1:0]] : {WIDTH{1'b0}})
	: ((rdptr0[LG_DEPTH-2:0] < ALU_LIVE) ? r_ram_alu[rdptr0[LG_ALU_LIVE-1:0]] : {WIDTH{1'b0}});
   wire [WIDTH-1:0] w_rf_rd1 = rdptr1[LG_DEPTH-1]
	? ((rdptr1[LG_DEPTH-2:0] < MEM_LIVE) ? r_ram_mem[rdptr1[LG_MEM_LIVE-1:0]] : {WIDTH{1'b0}})
	: ((rdptr1[LG_DEPTH-2:0] < ALU_LIVE) ? r_ram_alu[rdptr1[LG_ALU_LIVE-1:0]] : {WIDTH{1'b0}});
   wire [WIDTH-1:0] w_rf_rd2 = rdptr2[LG_DEPTH-1]
	? ((rdptr2[LG_DEPTH-2:0] < MEM_LIVE) ? r_ram_mem[rdptr2[LG_MEM_LIVE-1:0]] : {WIDTH{1'b0}})
	: ((rdptr2[LG_DEPTH-2:0] < ALU_LIVE) ? r_ram_alu[rdptr2[LG_ALU_LIVE-1:0]] : {WIDTH{1'b0}});
   wire [WIDTH-1:0] w_rf_rd3 = rdptr3[LG_DEPTH-1]
	? ((rdptr3[LG_DEPTH-2:0] < MEM_LIVE) ? r_ram_mem[rdptr3[LG_MEM_LIVE-1:0]] : {WIDTH{1'b0}})
	: ((rdptr3[LG_DEPTH-2:0] < ALU_LIVE) ? r_ram_alu[rdptr3[LG_ALU_LIVE-1:0]] : {WIDTH{1'b0}});
`endif

   always_ff@(posedge clk)
     begin
`ifdef VERILATOR
	if(reset)
	  begin
	     /* seed phys reg i = arch reg i (initial RAT is identity); both banks
	      * so whichever the RAT points at carries the value. i=0 stays 0. */
	     for(integer i = 1; i < 32; i=i+1)
	       begin
		  if(i < ALU_LIVE)
		    begin
		       r_ram_alu[i] <= loadgpr(i);
		    end
		  /* the initial RAT is identity, so it never points into the MEM
		   * bank; seeding it is defensive.  Skip what the shrunk bank
		   * cannot hold (FORMAL_PRF_SMALL) instead of writing past its end. */
		  if(i < MEM_LIVE)
		    begin
		       r_ram_mem[i] <= loadgpr(i);
		    end
	       end
	  end
	else
	  begin
`endif //  `ifdef VERILATOR
`ifdef FORMAL_PRF_SMALL
	/* shrunk banks: dead entries read as zero (see the note at the decls) */
	rd0 <= rdptr0=='d0 ? 'd0 : w_rf_rd0;
	rd1 <= rdptr1=='d0 ? 'd0 : w_rf_rd1;
	rd2 <= rdptr2=='d0 ? 'd0 : w_rf_rd2;
	rd3 <= rdptr3=='d0 ? 'd0 : w_rf_rd3;
`elsif FPGA
	/* FPGA/sim: the RF powers up to 0 (BRAM/bitstream INIT; Verilator zeroes
	 * state) and phys reg 0 ($0) is provably never written (dst_valid=(rd!=0);
	 * phys 0 reserved in the free list + never freed), so reading it returns 0
	 * directly -- no rdptr==0 mux.  Dropping the conditional read removes a 2:1
	 * mux per port AND lets the banks infer block RAM. */
	rd0 <= rdptr0[LG_DEPTH-1] ? r_ram_mem[rdptr0[LG_DEPTH-2:0]] : r_ram_alu[rdptr0[LG_DEPTH-2:0]];
	rd1 <= rdptr1[LG_DEPTH-1] ? r_ram_mem[rdptr1[LG_DEPTH-2:0]] : r_ram_alu[rdptr1[LG_DEPTH-2:0]];
	rd2 <= rdptr2[LG_DEPTH-1] ? r_ram_mem[rdptr2[LG_DEPTH-2:0]] : r_ram_alu[rdptr2[LG_DEPTH-2:0]];
	rd3 <= rdptr3[LG_DEPTH-1] ? r_ram_mem[rdptr3[LG_DEPTH-2:0]] : r_ram_alu[rdptr3[LG_DEPTH-2:0]];
`else
	/* No power-up-zero guarantee (e.g. ASIC SRAM): the rdptr==0 -> 0 mux IS the
	 * mechanism that makes $0 read as 0.  Such a target must keep this (or add an
	 * explicit RF zero/clear sequence at reset). */
	rd0 <= rdptr0=='d0 ? 'd0 : (rdptr0[LG_DEPTH-1] ? r_ram_mem[rdptr0[LG_DEPTH-2:0]] : r_ram_alu[rdptr0[LG_DEPTH-2:0]]);
	rd1 <= rdptr1=='d0 ? 'd0 : (rdptr1[LG_DEPTH-1] ? r_ram_mem[rdptr1[LG_DEPTH-2:0]] : r_ram_alu[rdptr1[LG_DEPTH-2:0]]);
	rd2 <= rdptr2=='d0 ? 'd0 : (rdptr2[LG_DEPTH-1] ? r_ram_mem[rdptr2[LG_DEPTH-2:0]] : r_ram_alu[rdptr2[LG_DEPTH-2:0]]);
	rd3 <= rdptr3=='d0 ? 'd0 : (rdptr3[LG_DEPTH-1] ? r_ram_mem[rdptr3[LG_DEPTH-2:0]] : r_ram_alu[rdptr3[LG_DEPTH-2:0]]);
`endif
	/* NEVER write phys reg 0 ($0): the FPGA read path dropped the rdptr==0->0 mux
	 * on the invariant that $0 is never written, but an r0-dest op (e.g. ssnop =
	 * sll $0,$0,1) reaches here with wrptr0==0 & wen0.  This gate enforces it. */
	if(wen0 & (wrptr0 != 'd0) & (wrptr0[LG_DEPTH-2:0] < ALU_LIVE))
	  begin
	     r_ram_alu[wrptr0[LG_ALU_LIVE-1:0]] <= wr0;
	  end
	if(wen1 & (wrptr1[LG_DEPTH-2:0] < MEM_LIVE))
	  begin
	     r_ram_mem[wrptr1[LG_MEM_LIVE-1:0]] <= wr1;
	  end
`ifdef VERILATOR
	/* The shrink above is only sound if a dead entry is never actually used.
	 * Fail loudly rather than silently returning zero. */
	if(wen0 & (wrptr0 != 'd0) & (wrptr0[LG_DEPTH-2:0] >= ALU_LIVE))
	  begin
	     $display("[PRF-SMALL] write to DEAD alu entry wrptr0=%d", wrptr0);
	     $stop();
	  end
	if(wen1 & (wrptr1[LG_DEPTH-2:0] >= MEM_LIVE))
	  begin
	     $display("[PRF-SMALL] write to DEAD mem entry wrptr1=%d", wrptr1);
	     $stop();
	  end
`endif
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
	if(wen1 & (wrptr1[LG_DEPTH-1] != 1'b1))
	  begin
	     $display("[RF-BANK] MEM-port write to ALU-bank pdst: wrptr1=%d", wrptr1);
	  end
`endif
`ifdef VERILATOR
	  end // else: !if(reset)
`endif
     end


`ifdef VERILATOR
   /* READ-DURING-WRITE COLLISION COUNTER (sim-only).
    * Are we even EXERCISING the hazard?  Reads select the bank by pointer MSB
    * (line ~68) while writes select it by PORT (port0 -> r_ram_alu, port1 ->
    * r_ram_mem), and neither array forwards a same-cycle write to a read.  If
    * these counters stay at zero, simulation never visits the window the
    * silicon captures point at -- which would by itself explain why 1.24e9
    * cycles reproduce nothing. */
   longint unsigned r_rdw_alu, r_rdw_mem, r_cyc_rf;
   /* POSITIVE CONTROLS: a zero collision count means nothing unless writes and
    * reads are demonstrably happening on both banks. */
   longint unsigned r_w0, r_w1, r_rd_alu_bank, r_rd_mem_bank;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_rdw_alu <= 'd0; r_rdw_mem <= 'd0; r_cyc_rf <= 'd0;
	     r_w0 <= 'd0; r_w1 <= 'd0; r_rd_alu_bank <= 'd0; r_rd_mem_bank <= 'd0;
	  end
	else
	  begin
	     r_cyc_rf <= r_cyc_rf + 'd1;
	     if(wen0 & (wrptr0 != 'd0)) begin r_w0 <= r_w0 + 'd1; end
	     if(wen1 & (wrptr1 != 'd0)) begin r_w1 <= r_w1 + 'd1; end
	     if(~rdptr0[LG_DEPTH-1]) begin r_rd_alu_bank <= r_rd_alu_bank + 'd1; end
	     else begin r_rd_mem_bank <= r_rd_mem_bank + 'd1; end
	     /* port 0 writes r_ram_alu; a read collides if it selects that bank
	      * (ptr MSB == 0) and hits the same offset */
	     if(wen0 & (wrptr0 != 'd0))
	       begin
		  if((~rdptr0[LG_DEPTH-1]) & (rdptr0[LG_DEPTH-2:0] == wrptr0[LG_DEPTH-2:0])) r_rdw_alu <= r_rdw_alu + 'd1;
		  else if((~rdptr1[LG_DEPTH-1]) & (rdptr1[LG_DEPTH-2:0] == wrptr0[LG_DEPTH-2:0])) r_rdw_alu <= r_rdw_alu + 'd1;
		  else if((~rdptr2[LG_DEPTH-1]) & (rdptr2[LG_DEPTH-2:0] == wrptr0[LG_DEPTH-2:0])) r_rdw_alu <= r_rdw_alu + 'd1;
		  else if((~rdptr3[LG_DEPTH-1]) & (rdptr3[LG_DEPTH-2:0] == wrptr0[LG_DEPTH-2:0])) r_rdw_alu <= r_rdw_alu + 'd1;
	       end
	     /* port 1 writes r_ram_mem; read must select that bank (ptr MSB == 1) */
	     if(wen1 & (wrptr1 != 'd0))
	       begin
		  if(rdptr0[LG_DEPTH-1] & (rdptr0[LG_DEPTH-2:0] == wrptr1[LG_DEPTH-2:0])) r_rdw_mem <= r_rdw_mem + 'd1;
		  else if(rdptr1[LG_DEPTH-1] & (rdptr1[LG_DEPTH-2:0] == wrptr1[LG_DEPTH-2:0])) r_rdw_mem <= r_rdw_mem + 'd1;
		  else if(rdptr2[LG_DEPTH-1] & (rdptr2[LG_DEPTH-2:0] == wrptr1[LG_DEPTH-2:0])) r_rdw_mem <= r_rdw_mem + 'd1;
		  else if(rdptr3[LG_DEPTH-1] & (rdptr3[LG_DEPTH-2:0] == wrptr1[LG_DEPTH-2:0])) r_rdw_mem <= r_rdw_mem + 'd1;
	       end
	     if(r_cyc_rf[23:0] == 24'hffffff)
	       begin
		  $display("[RDW] %m cyc=%0d COLL alu=%0d mem=%0d | writes p0=%0d p1=%0d | rd0bank alu=%0d mem=%0d",
			   r_cyc_rf, r_rdw_alu, r_rdw_mem, r_w0, r_w1, r_rd_alu_bank, r_rd_mem_bank);
	       end
	  end
     end
`endif

endmodule
