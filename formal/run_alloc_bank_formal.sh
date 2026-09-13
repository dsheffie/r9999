#!/bin/bash
# run_alloc_bank_formal.sh -- prove the free-list pools yield bank- and
# parity-correct physreg pointers, discharging the L2 half of the write-side
# banking invariant that formal_rf_p0 assumes outright.
#   ./run_alloc_bank_formal.sh            # proof
#   ./run_alloc_bank_formal.sh -c         # positive control: break the mask,
#                                         # the proof MUST then fail
set -e
cd "$(dirname "$0")"
CTRL=0
[ "${1:-}" = "-c" ] && CTRL=1

SRC=formal_alloc_bank.sv
if [ "$CTRL" = 1 ]; then
  SRC=$(mktemp -d)/formal_alloc_bank.sv
  # Positive control: let ONE mem-bank index leak into the ALU-even pool.  If the
  # harness cannot see that, it is not testing anything.
  sed 's|assign w_alu_even\[i\] = ((i <  N/2) \&\& (i % 2 == 0)) ? free\[i\] : 1.b0;|assign w_alu_even[i] = (((i < N/2) \|\| (i == N-2)) \&\& (i % 2 == 0)) ? free[i] : 1'"'"'b0;|' \
      formal_alloc_bank.sv > "$SRC"
  grep -q "i == N-2" "$SRC" || { echo "control injection FAILED to apply"; exit 1; }
  echo "### POSITIVE CONTROL: mem index N-2 leaked into the alu_even pool"
fi

V=$(mktemp -d)/formal_alloc_bank.v
sv2v ../find_lowest_set_bit.sv "$SRC" > "$V" 2>/dev/null
COMMON="read_verilog $V; hierarchy -check -top formal_alloc_bank; proc; flatten; opt -fast"

echo "=== sanity: all four pools can be non-empty at once (non-vacuous) ==="
if yosys -p "$COMMON; sat -set active 1" 2>&1 | grep -qi "signal found"; then
  echo "  SAT (good: the properties are not vacuously true)"
else
  yosys -p "$COMMON; sat -set active 1" 2>&1 | grep -iE "model found|no model" | head -1
fi

fail=0
for p in bad_ae_bank bad_ao_bank bad_me_bank bad_mo_bank \
         bad_ae_par  bad_ao_par  bad_me_par  bad_mo_par; do
  if yosys -p "$COMMON; sat -set $p 1" 2>&1 | grep -qi "no model found"; then
    echo "PASS  $p unreachable"
  else
    echo "FAIL  $p is SATISFIABLE -- a pool can yield an out-of-bank/parity pointer"
    fail=1
  fi
done

echo "=== aggregate: bad -- must be UNSAT ==="
if yosys -p "$COMMON; sat -set bad 1" 2>&1 | grep -qi "no model found"; then
  echo "PASS: every non-empty pool yields a pointer in its own bank AND parity"
  [ "$CTRL" = 1 ] && { echo "BUT THE CONTROL SHOULD HAVE FAILED -- harness is blind"; exit 1; }
  exit $fail
else
  echo "FAIL: aggregate counterexample exists"
  [ "$CTRL" = 1 ] && { echo "(expected -- positive control works)"; exit 0; }
  exit 1
fi
