#!/bin/bash
# run_l2_pidx_formal.sh -- UNBOUNDED proof of the R10000 PIdx SINGLE-COPY contract
# via AIGER + ABC's IC3/PDR, plus an SMT cover run proving it is not vacuous.
#
# THE PROPERTY (stated in l2.sv under `ifdef FORMAL + `ifdef ENABLE_L2_PIDX):
#   the L2 never hands a primary cache a copy of a line that cache already holds in
#   a DIFFERENT set.  That is the whole synonym guarantee.  Violating it leaves two
#   copies of one line in one cache, one possibly dirty, and loses a store.
#
# GEOMETRY IS LOAD-BEARING -- READ THIS BEFORE TRUSTING A PASS.
# A VIPT synonym exists only when the cache is LARGER than a page.  The stock FORMAL
# geometry is a 4-line L1D against a 4KB page: L1D_ALIAS_BITS == 0, PIDX_W == 1, every
# PIdx is 0, the compare `w_l1d_pidx == r_req_pidx` is trivially true, and the proof
# passes having proved nothing.  So this script shrinks the PAGE alongside the caches:
#
#     LG_PG_SZ=6          64B pages
#     LG_L1D_NUM_SETS=4   16 sets x 16B = 256B L1D  -> IDX_STOP=8 > 6 -> 2 alias bits
#     LG_L1I_NUM_SETS=4   likewise
#     LG_L2_NUM_SETS=2    4-line L2 (state space; see the GEOM note below)
#
# The cache>page RATIO is what creates aliasing, and scaling both down preserves it
# while keeping the state space small enough for PDR.  LG_PG_SZ had to be made
# `ifndef-overridable in machine.vh for this (it was the one geometry knob that was
# not).  The ALIAS-BITS ASSERT below fails the run outright if the geometry ever
# collapses back to zero alias bits, because that is precisely the configuration in
# which this proof lies to you.
#
# WHY FORMAL RATHER THAN THE DIRECTED TEST.  tests/cache/test_l1_synonym.S drives one
# interleaving.  The real hazard is a synonym request landing concurrently with an
# eviction, a snoop, or an in-flight back-invalidate ack -- and every one of the four
# bugs found in this subsystem so far came from the statement order between two such
# paths in a shared always_comb.  Enumerating those by hand is what a model checker
# does for free.
#
# THE PROPERTIES LIVE IN l2.sv, NOT in the wrapper.  Yosys does not resolve
# cross-module hierarchical references: `dut.w_l1d_pidx` in formal_l2_pidx.sv would
# silently declare a floating wire that setundef -anyseq hands the solver as a free
# input -- constraining nothing while still reporting PASS.
#
# `chformal -early` is load-bearing in BOTH flows: modern yosys represents
# assert/assume/cover as a unified $check cell, which neither write_smt2 nor
# write_aiger translates.  Without it write_smt2 emits an assertion function that is
# the literal constant `true` and every proof passes vacuously.
set -e
cd "$(dirname "$0")"
DEPTH=${DEPTH:-30}
SOLVER=${SOLVER:-yices}     # SMT solver, cover run only.  Do NOT use z3 here.
WORK=$(mktemp -d)

# L2 stays at the credit proof's known-good 4 lines: the L2 array is what drives the
# state space (memory_map expands 128b x N data + tags into flops), while the alias
# bits depend ONLY on the L1-vs-page ratio, which just sets PIDX_W.  A 32-line L2 was
# the first attempt and did not finish in 900s.
GEOM="-DLG_PG_SZ=6 -DLG_L1D_NUM_SETS=4 -DLG_L1I_NUM_SETS=4 -DLG_L2_NUM_SETS=2"
# ENABLE_L2_EVICT_BACKINV IS REQUIRED, not optional.  Without it the L2 evicts
# WITHOUT back-invalidating, so the L1s can hold lines the L2 no longer tracks and
# presence goes stale-set by construction -- the L2 is simply not inclusive.  Every
# PIdx property is inclusion-dependent, so proving one against a non-inclusive build
# yields counterexamples that are true of that build and irrelevant to the design.
# (Cost a formal iteration to learn: a fill-path grant handed out a second copy while
# a probe for the same line was still in flight.)  The deadlock that got this knob
# parked in 2026-08 is fixed -- see the ~r_backinv_d guard on the eviction issue.
DEFS="-DFORMAL -DENABLE_L2_INCLUSION -DENABLE_L2_PIDX -DENABLE_L2_EVICT_BACKINV $GEOM"

COMMON="
  read_verilog -sv -formal $DEFS -I.. formal_l2_pidx.sv ../l2.sv ../ram2r1w_fwd.sv ../reg_ram1rw.sv ../ram1r1w.sv
  hierarchy -check -top formal_l2_pidx
"

# ---- GEOMETRY GUARD.  If the alias bits are zero this proof is vacuous no matter
# what PDR says, so refuse to run rather than emit a reassuring PASS.
ALIAS_BITS=$(( (4 + 4) > 6 ? (4 + 4) - 6 : 0 ))
echo "=== geometry: 64B page, 256B L1D, 4-line L2 -> ${ALIAS_BITS} alias bits ==="
if [ "$ALIAS_BITS" -eq 0 ]; then
  echo "ABORT: geometry yields ZERO alias bits -- no synonym is expressible and the"
  echo "       single-copy property would pass trivially.  Fix GEOM above."
  exit 1
fi

# NOTE the pass ORDER: `opt -fast` runs opt_dff, which RE-INFERS a sync-reset flop
# from the mux dffunmap just created -- so dffunmap must come AFTER it and immediately
# before abc, or write_aiger dies on $_SDFF_PP1_.
echo "=== bit-blasting to AIGER ==="
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
echo "=== PDR: unbounded proof of single-copy ==="
yosys-abc -c "read $WORK/l2.aig; fold; strash; print_stats; pdr" 2>&1 | tee $WORK/pdr.log | tail -6
if grep -q "Property proved" $WORK/pdr.log; then
  echo "  PDR PASS -- the L2 never grants a second copy at a different PIdx, in ANY"
  echo "              reachable state (inductive invariant found)"
elif grep -qiE "was asserted|counter-?example|Verification failed" $WORK/pdr.log; then
  echo "  *** PDR FOUND A COUNTEREXAMPLE -- see $WORK/pdr.log"
  echo "      A synonym CAN escape.  Do not ship the replay removal on this RTL."
  exit 1
else
  echo "  PDR did not conclude -- see $WORK/pdr.log (undecided is NOT a pass)"
fi

# VACUITY.  The single-copy assertion is trivially true in any state where no line is
# held at a conflicting PIdx, so the cover points -- w_alias_d, w_alias_i, and the
# conflict actually driving BACKINV_WAIT -- are what prove the state space contains
# the case at all.  Covers were removed from the PDR run, so check them over SMT.
echo
echo "=== cover: is a synonym reachable at all? ==="
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
if grep -qE 'define-fun \|formal_l2_pidx_a\| .*Bool true' $WORK/l2.smt2; then
  echo "ABORT: SMT assertion function is literally 'true' -- properties did not survive."
  exit 1
fi
yosys-smtbmc -s $SOLVER -c -t $DEPTH --dump-vcd $WORK/cover.vcd $WORK/l2.smt2 2>&1 | tee $WORK/cover.log | tail -12
if grep -qi "unreached" $WORK/cover.log; then
  echo "  *** UNREACHED COVER POINTS -- the PDR proof above is VACUOUS."
  echo "      If w_alias_d/w_alias_i were never reached, no synonym ever formed and"
  echo "      the proof says nothing about aliasing.  Do not report a proof."
else
  echo "  all cover points reached -- a synonym really does form, and is handled"
fi

echo
echo "artifacts in $WORK"
