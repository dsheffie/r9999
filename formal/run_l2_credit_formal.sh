#!/bin/bash
# run_l2_credit_formal.sh -- UNBOUNDED proof of the L2's holding-slot and credit
# invariants via AIGER + ABC's IC3/PDR, plus an SMT cover run proving it is not
# vacuous.
#
# WHY THESE INVARIANTS EXIST.  The bug that motivated them was a store that reached
# the L2 and never reached DRAM.  The back-invalidate ack handler latches a recovered
# dirty line into the single holding slot (n_wb_pend/n_wb_addr/n_wb_data) EARLY in an
# always_comb, and the main FSM's BACKINV_WB state cleared n_wb_pend unconditionally
# LOWER DOWN in the same block -- so a writeback completing on the same cycle as an
# ack silently destroyed the recovered line.  Blocking assignments run in order and
# nothing in the design objected; simulation found it only as a wrong value tens of
# millions of cycles later.  `assert(n_wb_pend)` on a dirty ack is a two-line proof.
#
# ENGINE CHOICE -- MEASURED, and the spread is not subtle.  Same property, same box:
#
#     ABC PDR (AIG -> SAT)     0.05 s      37 MB   UNBOUNDED proof, invariant found
#     yices BMC depth 24       6.5  s     488 MB   bounded only
#     z3    k-induction      493    s  32,699 MB   killed at a 32 GB cap
#
# ~10,000x faster and ~900x leaner than the SMT/z3 route, and strictly STRONGER: PDR
# returns a real inductive invariant (19 clauses here) rather than a depth-N result,
# and it strengthens that invariant itself -- no hand-written auxiliary invariants,
# which is what k-induction would otherwise demand.  RTL is finite-state and
# bit-level, so SMT's word-level theories are a detour on the way to the bit-blasting
# that has to happen anyway; going straight to AIG/CNF also avoids a theory solver
# deciding to allocate 32 GB on a problem whose state is 523 latches.  This is how
# commercial FV tools do it (Jasper drives CaDiCaL; Kissat cannot serve as an engine
# there because it is deliberately non-incremental).
#
# Earlier versions of this script used `-s z3` -- an unjustified override of
# yosys-smtbmc's own default -- and then blamed k-induction for "unbounded" memory
# growth after it twice exhausted this 64 GB machine, once taking the desktop session
# with it.  That was the solver, not the proof.
#
# THE PROPERTIES LIVE IN l2.sv under `ifdef FORMAL, NOT in the wrapper.  Yosys's
# Verilog frontend does NOT resolve cross-module hierarchical references:
# `dut.r_wb_credits` here does not reach into the instance, it silently declares a
# floating wire whose name contains a dot, which setundef -anyseq then hands to the
# solver as a free input.  The assertions would constrain nothing and still report
# PASS; the only hint is an easily-missed "used but has no driver" warning.  This file
# supplies the ENVIRONMENT only.
#
# `chformal -early` is load-bearing in BOTH flows: modern yosys represents
# assert/assume/cover as a unified $check cell, which neither write_smt2 nor
# write_aiger translates.  Without it write_smt2 emits an assertion function that is
# the literal constant `true` and every proof passes vacuously.
#
# FORMAL geometry (machine.vh): LG_L2_NUM_SETS 2 => a 4-line L2.
set -e
cd "$(dirname "$0")"
DEPTH=${DEPTH:-30}
SOLVER=${SOLVER:-yices}     # SMT solver, cover run only.  Do NOT use z3 here.
WORK=$(mktemp -d)

COMMON="
  read_verilog -sv -formal -DFORMAL -DENABLE_L2_INCLUSION -I.. formal_l2_credit.sv ../l2.sv ../ram2r1w_fwd.sv ../reg_ram1rw.sv ../ram1r1w.sv
  hierarchy -check -top formal_l2_credit
"

# NOTE the pass ORDER: `opt -fast` runs opt_dff, which RE-INFERS a sync-reset flop
# from the mux dffunmap just created -- so dffunmap must come AFTER it and immediately
# before abc, or write_aiger dies on $_SDFF_PP1_.  AIGER also needs a flat netlist,
# no $print cells ($display), and no $cover (PDR proves assertions; covers are
# checked separately below).
echo "=== bit-blasting to AIGER (FORMAL geometry: 4-line L2) ==="
yosys -q -p "$COMMON
  flatten
  proc
  async2sync
  opt_clean
  chformal -early
  chformal -cover -remove
  delete t:\$print
  memory_map
  opt -full
  techmap
  opt -fast
  dffunmap
  abc -fast -g AND
  setundef -undriven -anyseq
  write_aiger -zinit -map $WORK/l2.aim $WORK/l2.aig" || { echo "AIGER GEN FAILED"; exit 1; }
HDR=$(head -1 $WORK/l2.aig)
echo "  $HDR   (M I L O A B C : B = assertions, C = environment constraints)"

# B == 0 means no assertions survived -- the AIGER analogue of write_smt2's `Bool
# true`, and PDR would cheerfully "prove" nothing at all.
NBAD=$(echo $HDR | awk '{print $7}')
if [ -z "$NBAD" ] || [ "$NBAD" = "0" ]; then
  echo "ABORT: AIGER has NO bad states -- no assertions reached the engine."
  echo "       (did chformal -early get dropped?)"
  exit 1
fi

echo
echo "=== PDR: unbounded proof ==="
yosys-abc -c "read $WORK/l2.aig; fold; strash; print_stats; pdr" 2>&1 | tee $WORK/pdr.log | tail -6
if grep -q "Property proved" $WORK/pdr.log; then
  echo "  PDR PASS -- invariants hold for ALL reachable states (inductive invariant found)"
elif grep -qiE "was asserted|counter-?example|Verification failed" $WORK/pdr.log; then
  echo "  *** PDR FOUND A COUNTEREXAMPLE -- see $WORK/pdr.log"
  exit 1
else
  echo "  PDR did not conclude -- see $WORK/pdr.log (undecided is NOT a pass)"
fi

# VACUITY.  A proof over an unreachable state space is worthless.  The L1D and DRAM
# are left FREE precisely so the interesting interleavings CAN happen, but an
# over-tight environment assumption would silently prevent them.  Covers were removed
# from the PDR run, so check them over SMT.  Same discipline as `active` in
# formal_l1d_fwd.sv: check BEFORE believing the proof.
echo
echo "=== cover: are the interesting states reachable at all? ==="
yosys -q -p "$COMMON
  proc
  async2sync
  opt_clean
  chformal -early
  memory_nordff
  opt -keepdc -fast
  setundef -anyseq
  opt_clean
  check
  dffunmap
  write_smt2 -wires $WORK/l2.smt2" || { echo "SMT GEN FAILED"; exit 1; }
if grep -qE 'define-fun \|formal_l2_credit_a\| .*Bool true' $WORK/l2.smt2; then
  echo "ABORT: SMT assertion function is literally 'true' -- properties did not survive."
  exit 1
fi
yosys-smtbmc -s $SOLVER -c -t $DEPTH --dump-vcd $WORK/cover.vcd $WORK/l2.smt2 2>&1 | tee $WORK/cover.log | tail -12
if grep -qi "unreached" $WORK/cover.log; then
  echo "  *** UNREACHED COVER POINTS -- the PDR proof above may be VACUOUS."
  echo "      Do not report a proof until every cover point is reached."
else
  echo "  all cover points reached -- the proof is about a live state space"
fi

echo
echo "artifacts in $WORK"
