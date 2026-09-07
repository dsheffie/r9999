#!/bin/bash
# run_decode_p0_formal.sh -- prove no instruction encoding decodes to an op whose
# exec arm asserts t_wr_int_prf while dst_valid=0 (the physreg-0 bypass-poison
# closure; companion to run_decode_formal.sh which proves dst_valid |-> dst!=0).
#   ./run_decode_p0_formal.sh [decode_mips.sv override]   (override = positive control)
set -e
cd "$(dirname "$0")"
DEC=${1:-../decode_mips.sv}
V=$(mktemp -d)/formal_decode_p0.v
sv2v ../machine.vh ../uop.vh "$DEC" formal_decode_p0.sv > "$V" 2>/dev/null
COMMON="read_verilog $V; hierarchy -check -top formal_decode_p0; proc; flatten; opt -fast"

echo "=== sanity: an INT_WRITER op must be decodable (non-vacuous) ==="
yosys -p "$COMMON; sat -set active 1" 2>&1 | grep -iE "model found|no model" | head -1

echo "=== proof: bad = INT_WRITER & ~dst_valid -- must be UNSAT ==="
if yosys -p "$COMMON; sat -set bad 1" 2>&1 | grep -qi "no model found"; then
  echo "PASS: no encoding reaches exec as an int-PRF writer with dst_valid=0"
else
  echo "FAIL: counterexample below (insn hex)"
  yosys -p "$COMMON; sat -set bad 1 -show insn" 2>&1 | grep -A4 "insn" | head -8
  exit 1
fi

echo "=== proof: bad3 = INT_WRITER & is_mem (bank-alias closure) -- must be UNSAT ==="
if yosys -p "$COMMON; sat -set bad3 1" 2>&1 | grep -qi "no model found"; then
  echo "PASS: no encoding is an int-PRF writer with is_mem=1 (no MEM-bank preg can reach wen0)"
  exit 0
else
  echo "FAIL: counterexample below (insn hex)"
  yosys -p "$COMMON; sat -set bad3 1 -show insn" 2>&1 | grep -A4 "insn" | head -8
  exit 1
fi
