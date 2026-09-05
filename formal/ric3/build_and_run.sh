#!/bin/bash
# build_and_run.sh -- reproduce the DIVA formal model at -top core_l1d_l1i and
# run rIC3 on it.  See HANDOFF.md for the full story (results, the ceiling, the
# vacuity trap).  Run from the r9999 checkout root.
#
#   formal/ric3/build_and_run.sh <workdir> <property|control> [engine]
#     property : prove fml_diva_bad[0] (branch)   -- expect UNSAT if it closes
#     control  : reach fml_diva_act[0] (branch retired) -- MUST be SAT for the
#                property proof to be non-vacuous.  RUN THIS FIRST.
#     engine   : ic3 (default) | bmc | wl-kind | cegar   (NEVER portfolio -- see below)
#
# MEMORY WARNING (learned the hard way, 4 OOMs in one session):
#   * rIC3 `portfolio` fans out to ~19 processes -- it WILL OOM a 60G box. Never use it here.
#   * even single ic3/bmc can exceed 60G on this 30.5K-latch model with the wide
#     DIVA property. This model did NOT close on a 60G box. Bigger RAM or a
#     stronger tool (commercial, with datapath abstraction) is the real fix.
#   * after launching, verify the process count: pgrep -cf 'target/release/ric3'
set -e
WORK=${1:?workdir}; WHAT=${2:?property|control}; ENGINE=${3:-ic3}
RIC3=${RIC3:-$HOME/scratch/rIC3/target/release/ric3}   # adjust: your rIC3 1.5.2 build
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$WORK"; cd "$WORK"

# 1. flatten the RTL to one Verilog with the formal gates active.
#    FORMAL             : shrinks ROB=16, PHT=4, PRF=64, BTB=4 (see machine.vh)
#    FORMAL_MINSTATE    : FP off (cu1=0), identity translation, TLB CAM writes gated
#    FORMAL_DIVA        : the retirement recompute checker (rob.vh operand save + core.sv monitor)
#    FORMAL_DIVA_TRUSTED_RSP : drop the env_ok gate (core_mem_rsp is internal here, not free)
#    FORMAL_ROBWR_MON   : ROB write-integrity monitor (provides r_fml_env_ok, act bits)
#    FORMAL_DIVA_SLOT   : optional single-slot reduction (gate check on frozen r_slot)
cp "$ROOT"/*.sv "$ROOT"/*.vh "$ROOT"/convert_sv_to_v.py .
SV2V_DEFINES="FORMAL FORMAL_MINSTATE FORMAL_DIVA FORMAL_DIVA_TRUSTED_RSP FORMAL_ROBWR_MON LG_L1D_NUM_SETS=2 LG_L1I_NUM_SETS=2 LG_L2_NUM_SETS=2" \
  python3 convert_sv_to_v.py
sed -i 's/\$stop[ \t]*(\?[ \t]*)\?[ \t]*;/;/g; s/\$stop//g' mipscore.v

# 2. generate the environment wrapper (ties debug pins, freezes slot, DRAM scoreboard)
"$ROOT"/formal/ric3/gen_cl2_wrapper.py mipscore.v formal_cl2_top.v

# 3. yosys -> AIGER.  memory_map blasts arrays to FFs; dffunmap is LAST (an opt
#    after it re-infers $sdffe and write_aiger fails); setundef -zero -init/-undriven.
yosys -p "read_verilog mipscore.v formal_cl2_top.v; \
  hierarchy -check -top formal_cl2_top; proc; flatten; delete t:\$print; \
  memory_map; opt -fast; techmap; opt -fast; \
  setundef -zero -init; setundef -zero -undriven; dffunmap; opt_clean; \
  abc -fast -g AND; write_aiger -zinit -map cl2.map cl2.aig"
echo "latches: $(grep -oE 'aig [0-9]+ [0-9]+ [0-9]+' cl2.aig | head -1 | awk '{print $4}')"

# 4. extract the requested single-output cone and run rIC3
if [ "$WHAT" = property ]; then
  PO=$(awk '$1=="output" && $4=="fml_diva_bad" && $3==0 {print $2}' cl2.map)
else
  PO=$(awk '$1=="output" && $4=="fml_diva_act" && $3==0 {print $2}' cl2.map)
fi
yosys-abc -c "read_aiger cl2.aig; cone -O $PO; strash; write_aiger prop.aig"
echo "=== rIC3 $ENGINE on $WHAT (PO $PO) ==="
"$RIC3" check prop.aig "$ENGINE"
