#!/usr/bin/env python3
# gen_cl2_wrapper.py -- generate the formal top wrapper for the DIVA proof at
# -top core_l1d_l1i.  Parses the flattened mipscore.v port list, ties the
# debug/driver pins to 0, freezes fml_diva_slot at reset, scoreboards the DRAM
# response to single-outstanding legality, and leaves everything else a free
# primary input.  Writes formal_cl2_top.v.
#
#   ./gen_cl2_wrapper.py mipscore.v formal_cl2_top.v
#
# Regenerate this whenever the core_l1d_l1i port list changes (a new debug port,
# etc).  Mirrors what was run inline during the 2026-09-05 session; see HANDOFF.md.
import re, sys

src, out = sys.argv[1], sys.argv[2]
s = open(src).read()
mstart = s.index('module core_l1d_l1i (')
mend = s.index('endmodule', mstart)
body = s[mstart:mend]
m = re.search(r'module core_l1d_l1i \((.*?)\);', body, re.S)
ports = [p.strip() for p in m.group(1).split(',') if p.strip()]

decl = {}
for dm in re.finditer(r'\n\s*(input|output)\s+(?:wire|reg)?\s*(\[[^\]]+\])?\s*([a-zA-Z_0-9,\s]+);', body):
    d, w, names = dm.group(1), dm.group(2) or '', dm.group(3)
    for n in names.split(','):
        n = n.strip()
        if n and n in ports:
            decl[n] = (d, w.strip())
missing = [p for p in ports if p not in decl]
assert not missing, "undeclared ports: %s" % missing

# debug/driver inputs tied to 0 (not part of the formal environment)
TIE0 = {'single_step', 'step', 'bp_enable', 'fault_clear',
        'bp_pc', 'bp_wp_addr', 'bp_wp_val'}

io = []      # free primary I/O to expose on the wrapper
conns = []   # dut connections
for p in ports:
    d, w = decl[p]
    if p in TIE0 and d == 'input':
        conns.append(".%s(1'b0)" % p if not w
                     else ".%s({(%s+1){1'b0}})" % (p, w[1:-1].split(':')[0]))
    elif p == 'reset':
        conns.append(".reset(w_rst)")
    elif p == 'mem_rsp_valid':
        conns.append(".mem_rsp_valid(w_mem_rsp_valid)")   # DRAM scoreboard drives it
    elif p == 'fml_diva_slot':
        conns.append(".fml_diva_slot(r_slot)")            # frozen slot (approach-1)
    else:
        io.append((p, d, w))
        conns.append(".%s(%s)" % (p, p))

hdr = [p for p, _, _ in io if p not in ('mem_rsp_valid', 'fml_diva_slot')]
L = ["module formal_cl2_top(", "\tmem_rsp_free,", "\tslot_seed,"]
L += ["\t%s," % p for p in hdr]
L[-1] = L[-1].rstrip(',')
L.append(");")
L.append("   input clk;")
L.append("   input mem_rsp_free;")
L.append("   input [`LG_ROB_ENTRIES-1:0] slot_seed;")
for p, d, w in io:
    if p == 'clk':
        continue
    L.append("   %s %s %s;" % (d, w, p))
# reset: high for cycle 0 only (a free reset lets the solver toggle it mid-trace)
L.append("   reg [3:0] r_cnt = 4'd0;")
L.append("   always @(posedge clk) if(r_cnt != 4'hf) r_cnt <= r_cnt + 4'd1;")
L.append("   wire w_rst = (r_cnt == 4'd0);")
# frozen DIVA slot (approach-1 single-slot reduction): capture the seed at reset, hold
L.append("   reg [`LG_ROB_ENTRIES-1:0] r_slot = 'd0;")
L.append("   always @(posedge clk) if(w_rst) r_slot <= slot_seed;")
# DRAM scoreboard: single outstanding; a response is legal only when a request is pending
L.append("   reg r_dram_out = 1'b0;")
L.append("   wire w_mem_rsp_valid = mem_rsp_free & r_dram_out;")
L.append("   always @(posedge clk) begin")
L.append("     if(w_rst) r_dram_out <= 1'b0;")
L.append("     else if(mem_req_valid & mem_req_ack & ~w_mem_rsp_valid) r_dram_out <= 1'b1;")
L.append("     else if(w_mem_rsp_valid) r_dram_out <= 1'b0;")
L.append("   end")
L.append("   core_l1d_l1i dut (")
L.append(",\n".join("      " + c for c in conns))
L.append("   );")
L.append("endmodule")
open(out, 'w').write("\n".join(L) + "\n")
print("wrote %s: %d free ports" % (out, len(hdr)))
