#!/bin/bash
# run_decode_formal.sh -- formally prove the decoder never emits a valid integer
# destination of logical register 0 (dst_valid |-> dst != 0).  This is the
# invariant that makes the physreg-0 write impossible (see rf4r2w.sv $0 gate);
# it caught the SSNOP (sll $0) + the mfc0/mfc1/cfc1/dmfc0/dmfc1 $0 moves.
#
#   ./run_decode_formal.sh
#
# Uses sv2v (comments/enums flatten fine) + yosys `sat`.  sv2v drops immediate
# `assert`s, so the property is exposed as an output `bad` and proven UNSAT.
set -e
cd "$(dirname "$0")"
V=$(mktemp -d)/formal_decode.v
sv2v ../machine.vh ../uop.vh ../decode_mips.sv formal_decode.sv > "$V" 2>/dev/null

echo "=== sanity: dst_valid must be reachable (flow non-vacuous) ==="
yosys -p "read_verilog $V; hierarchy -check -top formal_decode; proc; flatten; opt -fast; sat -set dv 1" \
  2>&1 | grep -iE "model found|no model" | head -1

echo "=== proof: bad = dst_valid & (dst==0) -- must be UNSAT (no model) ==="
if yosys -p "read_verilog $V; hierarchy -check -top formal_decode; proc; flatten; opt -fast; sat -set bad 1" \
     2>&1 | grep -qi "no model found"; then
  echo "PASS: dst_valid |-> dst != 0 holds across all 2^32 insns x all modes"
  exit 0
else
  echo "FAIL: found an insn with dst_valid & dst==0 (see the model above)"
  exit 1
fi
