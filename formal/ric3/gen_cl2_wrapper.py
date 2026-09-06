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
# ip2..ip6 are the EXTERNAL interrupt inputs.  Tied off: with COP0 excluded from
# the fill set, MTC0 (and ERET) can never execute, so Status.IE / Status.IM can
# never leave their reset values (sr=0x54400004: IE=0, ERL=1) and
#   irq_pending = r_sr_ie & ~r_sr_exl & ~r_sr_erl & |(w_ip & r_sr_im)
# is already unreachable -- free ip* bits only wiggled five Cause.IP flops that
# nothing could act on.  Tie them anyway: it drops 5 free inputs and 5 latches,
# and it stops the model from silently gaining an interrupt path if the allowed
# instruction set is ever widened to include COP0.  For an "does the property hold
# under interrupts" variant, remove ip2..ip6 here AND admit MTC0 to the fill set --
# removing them here alone would achieve nothing.
TIE0 = {'single_step', 'step', 'bp_enable', 'fault_clear',
        'bp_pc', 'bp_wp_addr', 'bp_wp_val',
        'dma_inval_req', 'dma_inval_addr',
        'ip2', 'ip3', 'ip4', 'ip5', 'ip6'}

io = []      # free primary I/O to expose on the wrapper
conns = []   # dut connections
for p in ports:
    d, w = decl[p]
    if p in TIE0 and d == 'input':
        conns.append(".%s(1'b0)" % p if not w
                     else ".%s({(%s+1){1'b0}})" % (p, w[1:-1].split(':')[0]))
    elif p == 'reset':
        conns.append(".reset(w_rst)")
    elif p == 'mem_rsp_load_data':
        conns.append(".mem_rsp_load_data(w_fill_data)")   # constrained on i-fills
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
       if p not in ('mem_rsp_valid', 'mem_rsp_load_data', 'fml_diva_slot',
                    'fml_rda_preg', 'resume', 'resume_pc')]
L = ["module formal_cl2_top(", "\tmem_rsp_free,", "\tslot_seed,", "\tpreg_seed,", "\tfill_raw,"]
L += ["\t%s," % p for p in hdr]
L[-1] = L[-1].rstrip(',')
L.append(");")
L.append("   input clk;")
L.append("   input mem_rsp_free;")
SLOTW = decl.get('fml_diva_slot', (None, ''))[1] or ""   # e.g. "[1:0]"; macros do not
L.append("   input %s slot_seed;" % SLOTW)          # carry into this standalone file
PREGW = decl.get('fml_rda_preg', (None, ''))[1] or ""
L.append("   input %s preg_seed;" % PREGW)
L.append("   input [127:0] fill_raw;")
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
# ---- instruction-fill constraint -------------------------------------------
# EVERY DRAM fill is forced to 4 legal, non-FP MIPS words.  Free garbage in an
# icache fill makes the solver explore decode-fault paths irrelevant to the
# property and blows up the reachable state space.
# Applying the SAME constraint to data-side fills is deliberate (dsheffie): the
# legal-encoding set is huge (all opcodes x arbitrary reg/imm fields), and
# critically it INCLUDES 0x00000000 (= sll $0,$0,0), so a load returning ZERO --
# the exact value our bug produces -- stays reachable.  No i/d distinction is
# needed, which keeps the wrapper simple and adds no RTL port.
# This is an ENVIRONMENT RESTRICTION: a proof covers only legal-encoding fills.
L.append("   wire [127:0] w_fill_data;")
# Per-word legality, then an ARCHITECTURAL-UB pass across the 4 words.
for gi in range(4):
    hi, lo = gi*32+31, gi*32
    L.append("   wire [31:0] w_raw%d = fill_raw[%d:%d];" % (gi, hi, lo))
    L.append("   wire [5:0]  w_op%d  = w_raw%d[31:26];" % (gi, gi))
    L.append("   wire [5:0]  w_fn%d  = w_raw%d[5:0];" % (gi, gi))
    # JALR rd,rs is UNPREDICTABLE when rd == rs (MIPS spec) -- exclude it.
    L.append("   wire w_jalr_ok%d = (w_fn%d != 6'h09) || (w_raw%d[15:11] != w_raw%d[25:21]);"
             % (gi, gi, gi, gi))
    L.append("   wire w_special_ok%d = (w_op%d == 6'd0) && w_jalr_ok%d &&" % (gi, gi, gi))
    L.append("        ((w_fn%d == 6'h08) || (w_fn%d == 6'h09) ||" % (gi, gi))
    L.append("         (w_fn%d == 6'h21) || (w_fn%d == 6'h23) ||" % (gi, gi))
    L.append("         (w_fn%d == 6'h24) || (w_fn%d == 6'h25) ||" % (gi, gi))
    L.append("         (w_fn%d == 6'h26) || (w_fn%d == 6'h27) ||" % (gi, gi))
    L.append("         (w_fn%d == 6'h2a) || (w_fn%d == 6'h2b) ||" % (gi, gi))
    L.append("         (w_fn%d == 6'h00) || (w_fn%d == 6'h02) || (w_fn%d == 6'h03));" % (gi, gi, gi))
    L.append("   wire w_imm_ok%d = (w_op%d == 6'd4) || (w_op%d == 6'd5) || (w_op%d == 6'd6) ||"
             % (gi, gi, gi, gi))
    L.append("        (w_op%d == 6'd7) || (w_op%d == 6'd9) || (w_op%d == 6'd10) || (w_op%d == 6'd11) ||"
             % (gi, gi, gi, gi))
    L.append("        (w_op%d == 6'd12) || (w_op%d == 6'd13) || (w_op%d == 6'd14) || (w_op%d == 6'd15) ||"
             % (gi, gi, gi, gi))
    L.append("        (w_op%d == 6'd35) || (w_op%d == 6'd43);" % (gi, gi))
    L.append("   wire [31:0] w_ok%d = (w_special_ok%d | w_imm_ok%d) ? w_raw%d : 32'h00000000;"
             % (gi, gi, gi, gi))
    # control transfer = jr/jalr/beq/bne/blez/bgtz.  Tested on the LEGALISED word.
    L.append("   wire w_ctl%d = ((w_ok%d[31:26] == 6'd0) && ((w_ok%d[5:0] == 6'h08) || (w_ok%d[5:0] == 6'h09)))"
             % (gi, gi, gi, gi))
    L.append("        || (w_ok%d[31:26] == 6'd4) || (w_ok%d[31:26] == 6'd5)" % (gi, gi))
    L.append("        || (w_ok%d[31:26] == 6'd6) || (w_ok%d[31:26] == 6'd7);" % (gi, gi))
L.append("   /* ---- architectural UB: no control transfer in a DELAY SLOT ----")
L.append("    * A branch or jump in a branch delay slot is UNPREDICTABLE in MIPS, so the")
L.append("    * RTL has no defined obligation there and any counterexample built on one")
L.append("    * would be a bug in THIS ENVIRONMENT, not in the design.  Forbid it.")
L.append("    * Word 0 of every fill is never a control transfer.  That is what makes the")
L.append("    * CROSS-LINE case sound: the delay slot of a branch in word 3 is the first")
L.append("    * word of the next line, which is therefore guaranteed non-control -- and it")
L.append("    * keeps branch-at-end-of-line (the interesting fetch path) reachable, which")
L.append("    * banning control in word 3 instead would have thrown away.")
L.append("    * Within a line, word i is squashed to NOP if word i-1 is a control transfer. */")
L.append("   wire [31:0] w_f0 = w_ctl0 ? 32'h00000000 : w_ok0;")
L.append("   wire [31:0] w_f1 = w_ok1;   /* w_f0 is never control, so w_f1 is always safe */")
L.append("   wire w_ctlf1 = w_ctl1;")
L.append("   wire [31:0] w_f2 = (w_ctlf1 & w_ctl2) ? 32'h00000000 : w_ok2;")
L.append("   wire w_ctlf2 = (w_ctlf1 & w_ctl2) ? 1'b0 : w_ctl2;")
L.append("   wire [31:0] w_f3 = (w_ctlf2 & w_ctl3) ? 32'h00000000 : w_ok3;")
L.append("   assign w_fill_data = {w_f3, w_f2, w_f1, w_f0};")
L.append("   core_l1d_l1i dut (")
L.append(",\n".join("      " + c for c in conns))
L.append("   );")
L.append("endmodule")
open(out, 'w').write("\n".join(L) + "\n")
print("wrote %s: %d free ports" % (out, len(hdr)))
