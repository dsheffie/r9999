#!/bin/bash
# run_l1d_fwd_formal.sh -- prove the L1D store->load forward DATA PATH is
# byte-exact for every store/load width & offset (the "SD->LW and similar"
# audit).  Combinational; uses yosys `sat` like run_decode_formal.sh.
#   bad    = (RTL forwarded-load result != independent big-endian oracle)
#   active = property applicable (aligned, load bytes subset of store bytes)
set -e
cd "$(dirname "$0")"
V=$(mktemp -d)/formal_l1d_fwd.v
sv2v formal_l1d_fwd.sv > "$V" 2>/dev/null
COMMON="read_verilog $V; hierarchy -check -top formal_l1d_fwd; proc; flatten; opt -fast"

echo "=== sanity: property must be reachable (active=1 SAT, non-vacuous) ==="
yosys -p "$COMMON; sat -set active 1" 2>&1 | grep -iE "SAT proof|model found|no model" | head -1

echo "=== proof: bad = (forward result != oracle) -- must be UNSAT (no model) ==="
if yosys -p "$COMMON; sat -set bad 1" 2>&1 | grep -qi "no model found"; then
  echo "PASS: L1D store->load forward is byte-exact for ALL mem ops (aligned + unaligned) at every offset"
  exit 0
else
  echo "FAIL: found a store->load forward that mismatches the oracle (model above)"
  yosys -p "$COMMON; sat -set bad 1 -show st_op -show st_off -show ld_op -show ld_off -show st_data -show ld_res -show oracle_res" 2>&1 | tail -30
  exit 1
fi
