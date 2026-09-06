#!/bin/bash
# run_rdagree.sh -- reader-agreement proof, with the vacuity covers GATED IN FRONT.
#
#   formal/ric3/run_rdagree.sh <workdir> [engine] [extra defines...]
#
#   engine   : engine for the PROPERTY (default ic3).  The COVERS always run under
#              bmc, overridable with COVER_ENGINE=.  This matters a lot: a cover is
#              an EXISTENTIAL question ("is there a trace reaching this?"), which is
#              what bmc does, while ic3 is built to prove UNreachability and only
#              stumbles onto witnesses.  Measured on c_rda_act0 (37413 latches):
#              bmc SAT in 49s / 3.0GB, ic3 still running at 37 MINUTES on the same
#              cone.  Do not gate covers with ic3.
#
# The property is "every reader of physreg P sees the same value, modulo
# recycling", checked on ONE physreg frozen by a free input (universal
# quantification over P).  FORMAL_RDA_BRANCH_ONLY narrows the assertion to
# branch operands, which is the failure mode actually seen on silicon.
#
# WHY THE COVERS ARE GATED (2026-09-06, cost a full session):
#   Covers going SAT proves the model is not DEAD.  It does NOT prove the model
#   is not CRIPPLED.  With LG_PRF_ENTRIES=6 the ALU free list was empty at reset
#   and the machine could not allocate an ALU destination at all -- Verilator
#   retired ZERO instructions -- yet all three covers still returned SAT, because
#   loads allocate from the MEM bank and branches/stores need no destination.
#   So this script ALSO runs the Verilator smoke test: if the same defines cannot
#   retire instructions in simulation, no formal result from them means anything.
set -e
WORK=${1:?workdir}; ENGINE=${2:-ic3}; shift 2 || true
EXTRA="$*"
RIC3=${RIC3:-$HOME/scratch/rIC3/target/release/ric3}
COVER_ENGINE=${COVER_ENGINE:-bmc}   # covers are existential -- bmc, not ic3 (see header)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEFS="FORMAL FORMAL_MINSTATE FORMAL_DIVA FORMAL_DIVA_TRUSTED_RSP FORMAL_ROBWR_MON \
FORMAL_RDAGREE FORMAL_RDA_BRANCH_ONLY LG_L1D_NUM_SETS=2 LG_L1I_NUM_SETS=2 LG_L2_NUM_SETS=2 $EXTRA"

# ---- 0. SMOKE TEST: can this define set actually run a program? --------------
echo "=== smoke: verilator retire check ==="
VDEFS=$(for d in $DEFS; do printf '+define+%s ' "$d"; done)
( cd "$ROOT" && rm -rf obj_dir && make ooo_core VFLAGS_EXTRA="$VDEFS" ) > "$WORK".smoke.log 2>&1 \
  || { echo "FATAL: verilator build failed, see $WORK.smoke.log"; exit 2; }
RET=$( cd "$ROOT" && ./ooo_core -f tests/cache/test_ds_plain_hammer.elf 2>&1 \
       | grep -aoE 'total_retire = [0-9]+' | grep -oE '[0-9]+' )
echo "total_retire = ${RET:-0}"
[ "${RET:-0}" -gt 1000 ] || { echo "FATAL: model retires ${RET:-0} instructions -- it is crippled, not just small. Fix the config before running any solver."; exit 2; }

mkdir -p "$WORK"; cd "$WORK"

# ---- 1. RTL -> AIGER ---------------------------------------------------------
cp "$ROOT"/*.sv "$ROOT"/*.vh "$ROOT"/convert_sv_to_v.py .
SV2V_DEFINES="$DEFS" python3 convert_sv_to_v.py > conv.log 2>&1
sed -i 's/\$stop[ \t]*(\?[ \t]*)\?[ \t]*;/;/g; s/\$stop//g' mipscore.v
"$ROOT"/formal/ric3/gen_cl2_wrapper.py mipscore.v formal_cl2_top.v
yosys -p "read_verilog mipscore.v formal_cl2_top.v; \
  hierarchy -check -top formal_cl2_top; proc; flatten; delete t:\$print; \
  memory_map; opt -fast; techmap; opt -fast; \
  setundef -zero -init; setundef -zero -undriven; dffunmap; opt_clean; \
  abc -fast -g AND; write_aiger -zinit -map cl2.map cl2.aig" > yos.log 2>&1
echo "latches: $(head -1 cl2.aig | awk '{print $4}')  ands: $(head -1 cl2.aig | awk '{print $6}')"

cone() { # $1 = aig out name, $2..= awk match on cl2.map
	local out=$1 po=$2
	yosys-abc -c "read_aiger cl2.aig; cone -O $po; strash; write_aiger $out" > /dev/null 2>&1
}

# ---- 2. COVERS FIRST: all three MUST be SAT ---------------------------------
for C in "retire_any:fml_retire_any:-" "rda_act0:fml_rda_act:0" "rda_act1:fml_rda_act:1"; do
	NAME=${C%%:*}; REST=${C#*:}; SIG=${REST%%:*}; IDX=${REST##*:}
	if [ "$IDX" = "-" ]; then
		PO=$(awk -v s="$SIG" '$1=="output" && $4==s {print $2}' cl2.map)
	else
		PO=$(awk -v s="$SIG" -v i="$IDX" '$1=="output" && $4==s && $3==i {print $2}' cl2.map)
	fi
	[ -n "$PO" ] || { echo "FATAL: no PO for $NAME -- monitor not gated in?"; exit 2; }
	cone "c_$NAME.aig" "$PO"
	echo "=== cover $NAME (PO $PO), engine $COVER_ENGINE ==="
	R=$("$RIC3" check "c_$NAME.aig" "$COVER_ENGINE" 2>&1 | tail -5)
	echo "$R"
	echo "$R" | grep -q "^SAT" || { echo "FATAL: cover $NAME is not SAT -- every property result below would be vacuous. STOP."; exit 2; }
done

# ---- 3. only now, the property ----------------------------------------------
PO=$(awk '$1=="output" && $4=="fml_rda_bad" {print $2}' cl2.map)
[ -n "$PO" ] || { echo "FATAL: no PO for fml_rda_bad"; exit 2; }
cone rda_bad.aig "$PO"
echo "=== property fml_rda_bad (PO $PO), engine $ENGINE ==="
exec "$RIC3" check rda_bad.aig "$ENGINE"
