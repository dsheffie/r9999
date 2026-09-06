#!/bin/bash
# build_and_run.sh -- reproduce the DIVA formal model at -top core_l1d_l1i and
# run rIC3 on it.  See HANDOFF.md for the full story (results, the ceiling, the
# vacuity trap).  Run from the r9999 checkout root.
#
#   formal/ric3/build_and_run.sh <workdir> <liveness|control|property> [engine]
#     liveness : reach fml_retire_any (ANY instruction retires) -- MUST be SAT.
#                RUN THIS FIRST, ALWAYS. If it is not SAT the harness is modelling
#                a DEAD CORE (resume never pulsed / memory never responds) and every
#                other result is meaningless. This exact failure cost a full session:
#                a phantom mem_req_ack and undriven resume made the core never run,
#                and the unreachable controls got misdiagnosed three different ways.
#     control  : reach fml_diva_act[0] (a DIVA-checked branch retired) -- MUST be SAT
#                for a property UNSAT to be non-vacuous. (dsheffie: SAT at depth 31;
#                act[1] ALU at depth 37.)
#     property : prove fml_diva_bad[0] (branch) -- UNSAT only means something if
#                BOTH liveness and control are SAT.
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
#    FORMAL             : shrinks ROB=4, PHT=4, BTB=4 (see machine.vh).  It does
#                         NOT shrink the PRF: LG_PRF_ENTRIES must stay 7 (=128)
#                         because the PRF is banked by pointer MSB and the 32
#                         arch regs fill the whole low bank at LG=6, leaving the
#                         ALU free list EMPTY.  To cut the pool, add
#                         FORMAL_PRF_SMALL (free list restricted to 32..47 and
#                         64..111, plus shrunk rf4r2w arrays: 37413 latches vs
#                         39461).  Do NOT shrink those ranges further -- a bank
#                         needs >= 32 + ROB live entries or it drains and
#                         deadlocks.  See HANDOFF.md.
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
case "$WHAT" in
  liveness) PO=$(awk '$1=="output" && $4=="fml_retire_any" {print $2}' cl2.map) ;;
  control)  PO=$(awk '$1=="output" && $4=="fml_diva_act" && $3==0 {print $2}' cl2.map) ;;
  property) PO=$(awk '$1=="output" && $4=="fml_diva_bad" && $3==0 {print $2}' cl2.map) ;;
  *) echo "unknown target: $WHAT (liveness|control|property)"; exit 2 ;;
esac
[ -n "$PO" ] || { echo "FATAL: no PO for $WHAT -- is the monitor gated in? check SV2V_DEFINES"; exit 2; }
yosys-abc -c "read_aiger cl2.aig; cone -O $PO; strash; write_aiger prop.aig"
echo "=== rIC3 $ENGINE on $WHAT (PO $PO) ==="
"$RIC3" check prop.aig "$ENGINE"
