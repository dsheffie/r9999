`include "machine.vh"
module rf4r2w(clk,
	      rdptr0,rdptr1,rdptr2,rdptr3,
	      wrptr0,wrptr1,wen0,wen1,
	      wr0, wr1,
	      rd0, rd1, rd2, rd3);

   parameter WIDTH = 1;
   parameter LG_DEPTH = 1;
   input logic clk;
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
   `RF_RAM_STYLE logic [WIDTH-1:0] 	    r_ram_alu[HALF-1:0];
   `RF_RAM_STYLE logic [WIDTH-1:0] 	    r_ram_mem[HALF-1:0];

   always_ff@(posedge clk)
     begin
	rd0 <= rdptr0=='d0 ? 'd0 : (rdptr0[LG_DEPTH-1] ? r_ram_mem[rdptr0[LG_DEPTH-2:0]] : r_ram_alu[rdptr0[LG_DEPTH-2:0]]);
	rd1 <= rdptr1=='d0 ? 'd0 : (rdptr1[LG_DEPTH-1] ? r_ram_mem[rdptr1[LG_DEPTH-2:0]] : r_ram_alu[rdptr1[LG_DEPTH-2:0]]);
	rd2 <= rdptr2=='d0 ? 'd0 : (rdptr2[LG_DEPTH-1] ? r_ram_mem[rdptr2[LG_DEPTH-2:0]] : r_ram_alu[rdptr2[LG_DEPTH-2:0]]);
	rd3 <= rdptr3=='d0 ? 'd0 : (rdptr3[LG_DEPTH-1] ? r_ram_mem[rdptr3[LG_DEPTH-2:0]] : r_ram_alu[rdptr3[LG_DEPTH-2:0]]);
	if(wen0)
	  r_ram_alu[wrptr0[LG_DEPTH-2:0]] <= wr0;
	if(wen1)
	  r_ram_mem[wrptr1[LG_DEPTH-2:0]] <= wr1;
     end

endmodule
