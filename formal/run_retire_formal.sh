#!/bin/bash
# run_retire_formal.sh -- the mispredicted-branch + delay-slot retire protocol
# (dsheffie 2026-09-04): after a mispredicted branch with a delay slot enters
# DRAIN, EXACTLY ONE instruction retires before the restart (the delay slot);
# a not-taken branch-likely's nullified slot contributes EXACTLY ZERO; a delay
# slot that arch-faults voids the window at ARCH_FAULT.  Guards "bug #3"
# (wrong-path retires after the ds -- see core.sv DRAIN comment ~2047).
#
# Monitor lives in core.sv under `ifdef FORMAL_RETIRE_MON (+FORMAL_RETIRE_PORTS
# for the formal outputs).  Model = -top core via a generated wrapper that ties
# the debug/driver pins (single_step/step/bp_*/fault_clear) to 0 and leaves
# resume + the fetch/L1D interfaces FREE -- an adversarial environment.
#
# RESULTS 2026-09-04 (abc pdr, unbounded unless noted):
#   fml_ret_badv[0] dual-retire in window      PROVED (24s)
#   fml_ret_badv[2] extra/nullified retire     PROVED (19s)
#   fml_ret_badv[3] count==expected at restart bounded-clean (bmc3); pdr UNDECIDED@3000s
#   fml_ret_badv[1] retiree is really the ds   NOT PROVABLE at -top core: fetch pc +
#     in_delay_slot are free inputs, the environment fabricates a frame-10 CEX. This is
#     the predecode-agreement property (the `be` bug class) -- needs -top core_l1d_l1i.
# Sim calibration: tests/cache/test_ds_plain_hammer.S (1914 windows) +
# test_ds_likely_hammer.S (4626 windows incl. nullified) -- 0 violations, PASS lines.
set -e
cd "$(dirname "$0")"
D=$(mktemp -d)
cp ../*.sv ../*.vh ../convert_sv_to_v.py $D/ 2>/dev/null
cd $D
SV2V_DEFINES="FORMAL FORMAL_RETIRE_MON FORMAL_RETIRE_PORTS" python3 convert_sv_to_v.py > conv.log 2>&1
sed -i 's/\$stop[ \t]*(\?[ \t]*)\?[ \t]*;/;/g; s/\$stop//g' mipscore.v
python3 - <<'PY'
import re
s=open('mipscore.v').read()
m=re.search(r'module core \((.*?)\);(.*?)(?=\n\s*(?:always|assign|wire|reg\s+\[?\s*\d|localparam|core_bank|genvar|function))', s, re.S)
ports=[p.strip() for p in m.group(1).split(',') if p.strip()]
decl={}
for dm in re.finditer(r'\n\s*(input|output)\s+(?:wire|reg)?\s*(\[[^\]]+\])?\s*([a-zA-Z_0-9,\s]+);', m.group(2)):
    d,w,names=dm.group(1),dm.group(2) or '',dm.group(3)
    for n in names.split(','):
        n=n.strip()
        if n: decl[n]=(d,w.strip())
decl['fml_ret_bad']=('output',''); decl['fml_ret_act']=('output',''); decl['fml_ret_badv']=('output','[3:0]')
TIE0={'single_step','step','bp_enable','fault_clear','bp_pc','bp_wp_addr','bp_wp_val'}
io=[]; conns=[]
for p in ports:
    d,w=decl[p]
    if p in TIE0 and d=='input':
        if w: conns.append(".%s({(%s+1){1'b0}})"%(p,w[1:-1].split(':')[0]))
        else: conns.append(".%s(1'b0)"%p)
    else:
        io.append((p,d,w)); conns.append(".%s(%s)"%(p,p))
lines=["module formal_core_top("]+["\t%s,"%p for p,_,_ in io]
lines[-1]=lines[-1].rstrip(',')
lines.append(");")
for p,d,w in io: lines.append("   %s %s %s;"%(d,w,p))
lines.append("   core dut (")
lines.append(",\n".join("      "+c for c in conns))
lines.append("   );")
lines.append("endmodule")
open('formal_core_top.v','w').write("\n".join(lines)+"\n")
PY
yosys -p "read_verilog mipscore.v formal_core_top.v; hierarchy -check -top formal_core_top; proc; flatten; delete t:\$print; memory_map; opt -fast; techmap; opt -fast; setundef -zero -init; dffunmap; opt_clean; abc -fast -g AND; write_aiger -zinit -map ret.map ret.aig" > yos.log 2>&1
ACT=$(grep -E "^output" ret.map | awk '$4=="fml_ret_act"{print $2}')
B0=$(grep -E "^output" ret.map | awk '$4=="fml_ret_badv" && $3==0 {print $2}')
B2=$(grep -E "^output" ret.map | awk '$4=="fml_ret_badv" && $3==2 {print $2}')
B3=$(grep -E "^output" ret.map | awk '$4=="fml_ret_badv" && $3==3 {print $2}')
echo "=== control: monitor must arm (bmc3 SAT) ==="
yosys-abc -c "read_aiger ret.aig; cone -O $ACT; strash; bmc3 -F 40" 2>&1 | tail -1
echo "=== proofs (pdr): dual-retire [$B0], extra/nullified [$B2] ==="
for O in $B0 $B2; do
  yosys-abc -c "read_aiger ret.aig; cone -O $O; strash; pdr -T 600" 2>&1 | grep -E "proved|asserted|timeout" | tail -1
done
echo "=== bounded: count-at-restart [$B3] (pdr is slow here; see header) ==="
yosys-abc -c "read_aiger ret.aig; cone -O $B3; strash; bmc3 -F 40 -T 300" 2>&1 | tail -1
