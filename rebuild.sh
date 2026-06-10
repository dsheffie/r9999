#!/bin/bash
# One command: SV -> mipscore.v (s2v) -> IP hdl/ -> headless Vivado (update IP + synth + impl + bitstream).
# Run from /home/dsheffie/code/r9999.   Usage: ./rebuild.sh [impl_run]
set -e
VIVADO=/storage2/Xilinx/2025.1/Vivado/bin/vivado
cd "$(dirname "$0")"
echo "[1/3] s2v: SystemVerilog -> mipscore.v"
./convert_sv_to_v.py
echo "[2/3] copy mipscore.v -> hdl/  (symlinked into the axi_is_the_worst IP)"
cp mipscore.v hdl/
echo "[3/3] Vivado headless: update IP -> synth -> impl -> bitstream"
"$VIVADO" -mode batch -notrace -source rebuild.tcl -tclargs "$@"
echo "done."
