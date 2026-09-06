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

# debug/driver inputs tied to 0 (not part of the formal environment).
# dma_inval_* is tied off too: the DIVA branch/ALU property is coherence-
# independent (a result is a function of its operands), so free DMA invalidation
# is pure input/state bloat here. For a "DIVA holds under adversarial concurrent
# DMA" coverage variant, remove dma_inval_req/addr from this set (leave the ack).
TIE0 = {'single_step', 'step', 'bp_enable', 'fault_clear',
        'bp_pc', 'bp_wp_addr', 'bp_wp_val',
        'dma_inval_req', 'dma_inval_addr'}

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
    elif p == 'resume':
        conns.append(".resume(w_resume)")                 # handshake, see below
    elif p == 'resume_pc':
        conns.append(".resume_pc(64'hffffffffbfc00000)")  # MIPS reset vector
    elif p == 'fml_diva_slot':
        conns.append(".fml_diva_slot(r_slot)")            # frozen slot (approach-1)
    elif p == 'fml_rda_preg':
        conns.append(".fml_rda_preg(r_preg)")             # frozen physreg (reader-agreement)
    else:
        io.append((p, d, w))
        conns.append(".%s(%s)" % (p, p))

hdr = [p for p, _, _ in io
       if p not in ('mem_rsp_valid', 'fml_diva_slot', 'fml_rda_preg', 'resume', 'resume_pc')]
L = ["module formal_cl2_top(", "\tmem_rsp_free,", "\tslot_seed,", "\tpreg_seed,"]
L += ["\t%s," % p for p in hdr]
L[-1] = L[-1].rstrip(',')
L.append(");")
L.append("   input clk;")
L.append("   input mem_rsp_free;")
SLOTW = decl.get('fml_diva_slot', (None, ''))[1] or ""   # e.g. "[1:0]"; macros do not
L.append("   input %s slot_seed;" % SLOTW)          # carry into this standalone file
PREGW = decl.get('fml_rda_preg', (None, ''))[1] or ""
L.append("   input %s preg_seed;" % PREGW)
for p, d, w in io:
    if p == 'clk':
        continue
    L.append("   %s %s %s;" % (d, w, p))
# reset: high for cycle 0 only (a free reset lets the solver toggle it mid-trace)
L.append("   reg [3:0] r_cnt = 4'd0;")
L.append("   always @(posedge clk) if(r_cnt != 4'hf) r_cnt <= r_cnt + 4'd1;")
L.append("   wire w_rst = (r_cnt == 4'd0);")
# frozen DIVA slot (approach-1 single-slot reduction): capture the seed at reset, hold
L.append("   reg %s r_slot = 'd0;" % SLOTW)
L.append("   always @(posedge clk) if(w_rst) r_slot <= slot_seed;")
# frozen physreg for reader-agreement: universal quantification over one arbitrary P
L.append("   reg %s r_preg = 'd0;" % PREGW)
L.append("   always @(posedge clk) if(w_rst) r_preg <= preg_seed;")
# resume handshake (mirrors top.cc): the core resets into FLUSH_FOR_HALT/HALT and does
# NOTHING until resume is pulsed. Wait for ready_for_resume, then assert resume once.
# Leaving resume free lets the solver simply never start the core -> every control is
# trivially unreachable and every property vacuously UNSAT.
L.append("   reg r_resumed = 1'b0;")
L.append("   wire w_resume = ready_for_resume & ~r_resumed & ~w_rst;")
L.append("   always @(posedge clk) if(w_resume) r_resumed <= 1'b1;")
# DRAM scoreboard: the core_l1d_l1i <-> DRAM interface has NO ack -- mem_req_valid is
# HELD until mem_rsp_valid comes back (valid-held-until-response), single outstanding.
# A response is legal only while a request is actually outstanding.
L.append("   reg r_dram_out = 1'b0;")
L.append("   wire w_mem_rsp_valid = mem_rsp_free & r_dram_out;")
L.append("   always @(posedge clk) begin")
L.append("     if(w_rst) r_dram_out <= 1'b0;")
L.append("     else if(mem_req_valid & ~r_dram_out & ~w_mem_rsp_valid) r_dram_out <= 1'b1;")
L.append("     else if(w_mem_rsp_valid) r_dram_out <= 1'b0;")
L.append("   end")
L.append("   core_l1d_l1i dut (")
L.append(",\n".join("      " + c for c in conns))
L.append("   );")
L.append("endmodule")
open(out, 'w').write("\n".join(L) + "\n")
print("wrote %s: %d free ports" % (out, len(hdr)))
