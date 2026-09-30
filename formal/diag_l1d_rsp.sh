#!/bin/bash
# diag_l1d_rsp.sh -- enumerate EVERY output cone of formal_l1d_rsp and report
# SAT/UNSAT, so a vacuous property cannot hide behind an unchecked control.
#
# Why this exists: run_l1d_rsp_formal.sh BMCs cones "1 2 3" and labels them
# "controls (all must assert)", but the output list gained `bad_p0' at index 1
# after that loop was written.  So it was BMC-ing a VIOLATION property as if it
# were a control, and never checking c_missrsp (4) or the non-vacuity control
# c_dstv (5) at all.  Output order is read from the AIGER map file rather than
# assumed, so this stays correct if the port list changes again.
set -e
cd "$(dirname "$0")"
D=$(mktemp -d)
cp ../*.sv ../*.vh ../convert_sv_to_v.py $D/ 2>/dev/null
cp formal_l1d_rsp.v $D/
cd $D
SV2V_DEFINES="FORMAL FORMAL_DPRELOAD LG_L1D_NUM_SETS=2 LG_L1I_NUM_SETS=2 LG_L2_NUM_SETS=2" \
  python3 convert_sv_to_v.py > conv.log 2>&1
sed -i 's/\$stop[ \t]*(\?[ \t]*)\?[ \t]*;/;/g; s/\$stop//g' mipscore.v
yosys -p "read_verilog mipscore.v formal_l1d_rsp.v; hierarchy -check -top formal_l1d_rsp; proc; flatten; delete t:\$print; memory_map; opt -fast; techmap; opt -fast; setundef -zero -init; dffunmap; opt_clean; abc -fast -g AND; write_aiger -zinit -map l1d.map l1d.aig" > yos.log 2>&1

# A driver-driver conflict is resolved by yosys "using constant", which silently
# ties a property to 0 and makes it vacuous.  This is how bad_p0 was dead for a
# week.  Never let it pass quietly again.
if grep -q "Driver-driver conflict" yos.log; then
  echo "*** DRIVER-DRIVER CONFLICT -- properties may be constant-folded ***"
  grep "Driver-driver conflict" yos.log | sed 's/^/  /'
fi

echo "=== AIG ==="
grep -m1 "^aig" l1d.aig || head -1 l1d.aig
# The FIRST column of a `output <idx> <bit> <name>' map line is the true AIGER
# output index -- NOT the line number.  yosys omits the map entry entirely for an
# output folded to a constant, so a gap in the indices IS the vacuity signal.
echo "=== named outputs (index from the map's own first column) ==="
awk '/^output/{printf "  idx %-3s %s\n",$2,$NF}' l1d.map
NOUT=$(sed -n '1s/^aig \([0-9]*\) \([0-9]*\) \([0-9]*\) \([0-9]*\).*/\4/p' l1d.aig)
echo "AIG declares $NOUT outputs; $(grep -cE '^output' l1d.map) are named."
echo "UNNAMED (=> constant-folded) indices:"
for i in $(seq 0 $((NOUT-1))); do
  awk -v n=$i '/^output/ && $2==n {f=1} END{exit !f}' l1d.map || printf "  %s\n" "$i"
done

# Declaration order of the module's output port list, used to attribute an index
# to a signal name even when the map omits it.
NAMES="bad0 bad_p0 c_ack c_rsp c_missrsp c_dstv c_ptr c_fpd c_rob c_dat c_any bad_dp c_dpchk c_two_dp"

echo
echo "=== per-cone BMC (F=80) -- all $NOUT outputs ==="
i=0
while [ $i -lt $NOUT ]; do
  nm=$(echo $NAMES | cut -d' ' -f$((i+1)))
  mapped=$(awk -v n=$i '/^output/ && $2==n {print $NF}' l1d.map)
  # Cone SIZE is the only sound test for "structurally dead".  `cone' alone keeps
  # every latch (abc says so), and `scl' is an abc.rc alias absent from
  # yosys-abc, so the sequence must be cone -> strash -> scleanup -> trim.
  # NOTE: do NOT use abc's "conf limit 0" text to infer a constant -- that string
  # appears in EVERY non-SAT message and says nothing about the cone.
  sz=$(yosys-abc -c "read_aiger l1d.aig; cone -O $i; strash; scleanup; trim; print_stats" 2>&1 \
        | sed 's/\x1b\[[0-9;]*m//g' | grep -m1 "i/o *=")
  lat=$(echo "$sz" | sed -n 's/.*lat *= *\([0-9]*\).*/\1/p')
  ands=$(echo "$sz" | sed -n 's/.*and *= *\([0-9]*\).*/\1/p')
  r=$(yosys-abc -c "read_aiger l1d.aig; cone -O $i; strash; bmc3 -F 80 -T 180" 2>&1 | tail -1)
  # ORDER MATTERS: "No output asserted" also contains "asserted", so the
  # negative case must be tested FIRST or every result classifies as SAT.
  case "$r" in
    *"No output asserted"*) v="no CEX to the depth reached";;
    *"was asserted"*)       v="SAT (reachable)";;
    *)                      v="?";;
  esac
  if [ "${lat:-0}" = "0" ] && [ "${ands:-0}" = "0" ]; then
    v="CONSTANT (structurally dead -- vacuous)"
  fi
  printf "  %-2d %-10s lat=%-5s and=%-6s %s\n      %s\n" \
    "$i" "$nm" "${lat:-?}" "${ands:-?}" "$v" "$(echo "$r" | cut -c1-100)"
  i=$((i+1))
done
echo
echo "l1d.map + l1d.aig kept in $D"
