# exec'd by make_incl.py (operates on its string `s` and helper `rep`).
# Same-cycle response delivery (RSP_DECOUPLED=0): the RTL installs a fill in the cycle the
# L2 responds, so the response is delivered INSIDE the L2 step.  The separate response slot
# and the L1 response rules remain for RSP_DECOUPLED=1.

a = s.index('rule "L1D: response"')
hdr = '  d := rsp[S_D].d; rsp[S_D].full := false;\n'
b = s.index(hdr, a) + len(hdr)
e = s.index('\nend;', b)
dbody = s[b:e]
s = s[:a] + (
    'rule "L1D: response"\n'
    '  rsp[S_D].full\n'
    '==>\n'
    'var d: Ver;\n'
    'begin\n'
    '  d := rsp[S_D].d; rsp[S_D].full := false;\n'
    '  d_rsp(d);\n'
    'end;') + s[e + len('\nend;'):]

rep('rule "L1I: fill"\n'
    '  rsp[S_I].full\n'
    '==>\n'
    'begin\n'
    '  assert ifill "L1I response without a miss";\n'
    '  l1i.st := L_V; l1i.tag := ia; l1i.d := rsp[S_I].d;\n'
    '  rsp[S_I].full := false; ifill := false;\n'
    'end;',
    'rule "L1I: fill"\n'
    '  rsp[S_I].full\n'
    '==>\n'
    'var d: Ver;\n'
    'begin\n'
    '  d := rsp[S_I].d; rsp[S_I].full := false;\n'
    '  i_rsp(d);\n'
    'end;')

rep('procedure respond(s: Src; d: Ver);\n'
    'begin\n'
    '  assert !rsp[s].full "response slot overrun";\n'
    '  rsp[s].full := true; rsp[s].dst := s; rsp[s].d := d;\n'
    'end;\n', '')

a = s.index('procedure core_write(a: Addr);')
e = s.index('\nend;', a) + len('\nend;')
s = s[:e] + (
    '\n\n'
    '-- the L1D\'s handling of an L2 response (l1d.sv: mem_rsp_valid)\n'
    'procedure d_rsp(d: Ver);\n'
    'begin\n' + dbody + '\n'
    'end;\n'
    '\n'
    '-- the L1I fill\n'
    'procedure i_rsp(d: Ver);\n'
    'begin\n'
    '  assert ifill "L1I response without a miss";\n'
    '  l1i.st := L_V; l1i.tag := ia; l1i.d := d;\n'
    '  ifill := false;\n'
    'end;\n'
    '\n'
    '-- RSP_DECOUPLED=0: delivered in this same step (the RTL installs the fill in the\n'
    '-- response cycle); =1: queued in the per-L1 response slot\n'
    'procedure respond(s: Src; d: Ver);\n'
    'begin\n'
    '  if RSP_DECOUPLED = 0 then\n'
    '    if s = S_D then d_rsp(d); else i_rsp(d); endif;\n'
    '  else\n'
    '    assert !rsp[s].full "response slot overrun";\n'
    '    rsp[s].full := true; rsp[s].dst := s; rsp[s].d := d;\n'
    '  endif;\n'
    'end;') + s[e:]
