/* ram2r1w_fwd -- reg_ram1rw with a second, independent read port.
 *
 * WHY THIS EXISTS.  The L2's metadata arrays (tag/valid/presence) are reg_ram1rw,
 * which fuses the read and write address into one port.  That is why a DMA snoop
 * can only be admitted from IDLE: not because the main FSM is conceptually busy,
 * but because it owns the only address port.  A snoop stuck behind a fill is the
 * DMA-coherence ordering bug.
 *
 * PORT 0 IS BIT-IDENTICAL TO reg_ram1rw.  Same two-stage pipeline (address
 * registered, then output registered -- which is what WAIT_FOR_RAM exists to
 * cover), and the same read-OLD-data-on-collision behaviour, because rd_data0
 * samples r_ram before the non-blocking write commits.  Swapping reg_ram1rw for
 * this must not move a single main-path edge; if it does, the 18-state FSM's
 * read-after-write hazards would all need re-proving, which is how you wedge a
 * kernel that currently boots.  ram2r1w was rejected for exactly that reason: it
 * is ONE cycle and writes on the unregistered address.
 *
 * PORT 1 FORWARDS.  Port 1 is read-only and independent.  It DOES forward the
 * in-flight write, and that is a correctness requirement rather than a nicety:
 * if the main FSM sets a line's presence bit in the same cycle a snoop reads that
 * line, an unforwarded read returns the stale bit and the snoop skips a
 * back-invalidate it owed -- a missed invalidate, i.e. the stale-data corruption
 * this whole inclusion effort exists to remove.  Only one forwarding term is
 * needed: the write and both reads pass through the same stage-1 register, so a
 * collision is always visible on the registered signals, and a write presented
 * one cycle earlier has already committed to the array.
 *
 * The write address is separate from rd_addr0 so the snoop engine can drive its
 * own invalidate.  Driving wr_addr and rd_addr0 from the same signal reproduces
 * reg_ram1rw exactly.
 */
module ram2r1w_fwd(clk, rd_addr0, rd_addr1, wr_addr, wr_data, wr_en, rd_data0, rd_data1);
   input logic 		      clk;
   parameter WIDTH = 1;
   parameter LG_DEPTH = 1;
   input logic [LG_DEPTH-1:0] rd_addr0;
   input logic [LG_DEPTH-1:0] rd_addr1;
   input logic [LG_DEPTH-1:0] wr_addr;
   input logic [WIDTH-1:0]    wr_data;
   input logic 		      wr_en;
   output logic [WIDTH-1:0]   rd_data0;
   output logic [WIDTH-1:0]   rd_data1;

   localparam DEPTH = 1<<LG_DEPTH;
   logic [WIDTH-1:0] 	      r_ram[DEPTH-1:0];

   logic [LG_DEPTH-1:0]       r_rd_addr0, r_rd_addr1, r_wr_addr;
   logic 		      r_wr_en;
   logic [WIDTH-1:0] 	      r_wr_data;

   /* stage 1: register addresses and write payload, exactly as reg_ram1rw does */
   always_ff@(posedge clk)
     begin
	r_rd_addr0 <= rd_addr0;
	r_rd_addr1 <= rd_addr1;
	r_wr_addr  <= wr_addr;
	r_wr_en    <= wr_en;
	r_wr_data  <= wr_data;
     end // always_ff

   /* The write commits below using r_wr_addr.  A port-1 read of that same line in
    * the same cycle would otherwise sample the pre-write contents. */
   wire 		      w_fwd1 = r_wr_en & (r_rd_addr1 == r_wr_addr);

   /* stage 2: read out, and commit the write.  rd_data0 deliberately does NOT
    * forward -- reg_ram1rw returns old data on a collision and port 0 must match
    * it exactly. */
   always_ff@(posedge clk)
     begin
	rd_data0 <= r_ram[r_rd_addr0];
	rd_data1 <= w_fwd1 ? r_wr_data : r_ram[r_rd_addr1];
	if(r_wr_en)
	  begin
	     r_ram[r_wr_addr] <= r_wr_data;
	  end
     end // always_ff

endmodule // ram2r1w_fwd
