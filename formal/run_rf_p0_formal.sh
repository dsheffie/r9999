#!/bin/bash
# run_rf_p0_formal.sh -- P2d: UNBOUNDED proof (BMC base + temporal induction) that
# physreg 0 always reads as 0 in rf4r2w, given bank-legal writes and power-up-0.
# The FPGA read path has no rdptr==0->0 mux (rf4r2w.sv ~line 66): this invariant is
# the only thing that makes $0 read as zero on silicon.
#
# Assumption chain (each discharged elsewhere):
#   - port0 (int) writes carry a NONZERO ALU-bank ptr:
#       run_decode_p0_formal.sh   INT_WRITER => dst_valid  (no $0-dst writer)
#                                 INT_WRITER => ~is_mem    (no MEM-bank preg on wen0)
#       run_decode_formal.sh      dst_valid  => dst != 0
#       core.sv free list         p0 not free at reset; never freed (r0 never re-renamed)
#   - port1 (mem) writes carry a MEM-bank ptr: banked allocator (is_mem -> w_mem_* pool)
#   - power-up-0: LUTRAM/BRAM INIT (the rf4r2w.sv FPGA-path comment's own premise)
#
# The control run drops the assumes and MUST find the aliasing corruption
# (wen0 @ ptr HALF writes r_ram_alu[0] = p0's cell) -- proving non-vacuity.
set -e
cd "$(dirname "$0")"
D=$(mktemp -d)
# formal copy of rf4r2w: stub the include (RF_RAM_STYLE only), drop the DPI import,
# append the in-DUT inductive invariant
sed -e 's/`include "machine.vh"/`define RF_RAM_STYLE\n`define FPGA 1/' -e '/import "DPI-C"/d' ../rf4r2w.sv > $D/rf4r2w_formal.sv
python3 - "$D/rf4r2w_formal.sv" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read().rstrip()
assert s.endswith('endmodule')
s=s[:-len('endmodule')]+'''`ifdef FORMAL_RF_P0
   always @(posedge clk) assert(r_ram_alu[0] == '0);  /* p0-cell inductive invariant */
`endif
endmodule
'''
open(p,'w').write(s)
PY
Y="prep -top formal_rf_p0_smt; async2sync; opt_clean; memory; opt -keepdc -fast; setundef -zero -init; opt_clean; dffunmap"

yosys -p "read_verilog -sv -formal -DFORMAL_RF_P0 $D/rf4r2w_formal.sv formal_rf_p0.sv; $Y; write_smt2 -wires $D/p.smt2" > $D/y.log 2>&1
echo "=== proof: BMC base (25) ==="
yosys-smtbmc -t 25 $D/p.smt2 2>&1 | tail -1
echo "=== proof: temporal induction ==="
if ! yosys-smtbmc -i -t 25 $D/p.smt2 2>&1 | tail -1 | grep -q PASSED; then echo "FAIL: induction"; exit 1; fi
echo "PASS: p0 reads 0, unbounded (base + induction)"

echo "=== control: assumes OFF, BMC must FAIL with the alias corruption ==="
yosys -p "read_verilog -sv -formal -DFORMAL_RF_P0 -DRFP0_NO_ASSUME $D/rf4r2w_formal.sv formal_rf_p0.sv; $Y; write_smt2 -wires $D/c.smt2" > $D/y2.log 2>&1
if yosys-smtbmc -t 10 $D/c.smt2 2>&1 | grep -q "Status: FAILED"; then
  echo "CONTROL OK: without the bank-legal assumes the p0 cell is corrupted (harness non-vacuous)"
else
  echo "CONTROL FAILED: could not demonstrate the alias -- DO NOT trust the PASS"; exit 1
fi
