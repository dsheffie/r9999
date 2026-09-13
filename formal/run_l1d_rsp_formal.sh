#!/bin/bash
# run_l1d_rsp_formal.sh -- l1d response integrity at -top l1d.  TWO properties:
#   bad0   : a core response never fires for a rob_ptr with no outstanding
#            accepted request (covers BOTH spurious and double responses).
#   bad_p0 : the l1d never fabricates or corrupts a response into
#            dst_valid & dst_ptr == 0 (physreg-0 closure through the L1D --
#            rf4r2w gates the WRITE of p0, nothing gates the forward).
# Env: cacheable unmapped loads only (mapped=0 => no TLB), requests held until
# ack, never reusing an outstanding rob_ptr (mirrors the core's one-op-per-slot
# invariant); mem side = single-outstanding scoreboarded free responses (the
# exhaustive version of randomized DRAM latency).
#
# PROVED UNBOUNDED 2026-09-12 (pdr): bad0 190.7s (invariant F[34], 6073 clauses),
# bad_p0 23.6s (F[26], 1086 clauses).  Controls c_ack/c_rsp/c_missrsp/c_dstv/
# c_dpchk/c_two_dp all SAT, so neither property is vacuous.
# bad_dp (L3b): UNDECIDED -- pdr hit frame 36 / 1000s without proving or refuting.
#
# THREE TRAPS this script now guards, all of which silently faked a pass before:
#  1. FORMAL_DPRELOAD must be defined -- formal_l1d_rsp.v wires .fml_pre_tag /
#     .fml_pre_data unconditionally, and those l1d ports exist only under that
#     define.  Without it yosys dies "does not have a port named fml_pre_data"
#     and, under `set -e', the script exited having proved NOTHING.
#  2. A driver-driver conflict makes a property CONSTANT-0 and therefore vacuous.
#     Seven diagnostics plus bad_p0 were dead this way (reset in one always block,
#     updated in another; yosys "Resolved using constant").  Checked below.
#  3. Cone indices follow the module's OUTPUT PORT ORDER, and `bad_p0' was
#     inserted at index 1 after the old loop was written -- so that loop BMC-ed a
#     violation property as if it were a control and never checked c_missrsp or
#     c_dstv.  Indices are named explicitly here.
#
# NOTE: FORMAL_DPRELOAD is an OVER-APPROXIMATION (a free tag lets a cache line
# claim any address, so states arise that no real fill sequence produces).  UNSAT
# stays sound, so the two proofs above are valid; a SAT counterexample would have
# to be checked for realizability before being believed.
#
# NOT yet covered (the expansion ladder): stores/graduation, mapped/TLB,
# restart_valid, dma_inval, multi-outstanding mem.
set -e
cd "$(dirname "$0")"
D=$(mktemp -d)
cp ../*.sv ../*.vh ../convert_sv_to_v.py $D/ 2>/dev/null
cp formal_l1d_rsp.v $D/
cd $D
SV2V_DEFINES="FORMAL FORMAL_DPRELOAD LG_L1D_NUM_SETS=2 LG_L1I_NUM_SETS=2 LG_L2_NUM_SETS=2" python3 convert_sv_to_v.py > conv.log 2>&1
sed -i 's/\$stop[ \t]*(\?[ \t]*)\?[ \t]*;/;/g; s/\$stop//g' mipscore.v
yosys -p "read_verilog mipscore.v formal_l1d_rsp.v; hierarchy -check -top formal_l1d_rsp; proc; flatten; delete t:\$print; memory_map; opt -fast; techmap; opt -fast; setundef -zero -init; dffunmap; opt_clean; abc -fast -g AND; write_aiger -zinit -map l1d.map l1d.aig" > yos.log 2>&1

# TRAP 2: a conflict is resolved "using constant" and silently voids a property.
if grep -q "Driver-driver conflict" yos.log; then
  echo "FAIL: driver-driver conflict -- a property is constant-folded and vacuous"
  grep "Driver-driver conflict" yos.log | sed 's/^/  /'
  exit 1
fi

# Output cone indices = module output port order:
#   0 bad0  1 bad_p0  2 c_ack  3 c_rsp  4 c_missrsp  5 c_dstv
#   6 c_ptr 7 c_fpd   8 c_rob  9 c_dat  10 c_any
#   11 bad_dp  12 c_dpchk  13 c_two_dp
# c_fpd (7) is legitimately constant: the harness pins the request's
# fp_dst/fp_merge/fp_hi field to 0, so no response can carry fp_dst.  It is a
# diagnostic for an FP environment we do not build here -- do NOT "fix" it.
echo "=== controls: each must be SAT, else the properties are vacuous ==="
fail=0
for spec in "2:c_ack" "3:c_rsp" "4:c_missrsp" "5:c_dstv" "12:c_dpchk" "13:c_two_dp"; do
  i=${spec%%:*}; nm=${spec##*:}
  # "No output asserted" contains "asserted", so match the positive form exactly.
  if yosys-abc -c "read_aiger l1d.aig; cone -O $i; strash; bmc3 -F 80 -T 180" 2>&1 | grep -q "was asserted"; then
    echo "  SAT   $nm"
  else
    echo "  DEAD  $nm  <== control unreachable: properties below prove nothing"
    fail=1
  fi
done
[ $fail -eq 0 ] || { echo "FAIL: a control is dead"; exit 1; }

echo "=== properties: both must be proved unbounded ==="
for spec in "0:bad0" "1:bad_p0"; do
  i=${spec%%:*}; nm=${spec##*:}
  if yosys-abc -c "read_aiger l1d.aig; cone -O $i; strash; scleanup; trim; pdr -T 700" 2>&1 | grep -q "Property proved"; then
    echo "  PROVED $nm"
  else
    echo "  FAIL or undecided: $nm"
    exit 1
  fi
done
echo "PASS: l1d never spurious/double-responds AND never emits dst_valid with dst_ptr==0 (loads, unbounded)"

# bad_dp (L3b, dst_ptr round trip) is NOT gating: pdr reached frame 36 and timed
# out at 1000s -- UNDECIDED, neither proved nor refuted.  BMC found no CEX to 40
# frames, so there is no evidence of a violation, but that is not a proof.  Run it
# explicitly when you want to spend the time:
#   yosys-abc -c "read_aiger l1d.aig; cone -O 11; strash; scleanup; trim; pdr -T <big>"
# Clause counts were still growing at timeout, so a longer budget may close it.
# The state space is 4 rob slots x 7-bit dst_ptr; narrowing dp_free would shrink it
# but WEAKENS coverage (fewer request scenarios explored), so decide deliberately.
echo "NOTE: bad_dp (dst_ptr round trip) is UNDECIDED -- not checked here, see comments"
